#!/usr/bin/env python3
"""Build Odyssey.app for the Builder, and for build_app.py, which hands a Super Mario Odyssey file to this script with the
same arguments:

    python3.14 build.py <game.xci|nsp> -k <prod.keys> [--firmware DIR | --shared-fonts DIR] [-o OUT] [--work DIR]

It runs the eight steps of scripts/build_odyssey.py (README.md "Build your own copy"; its own command line is
unchanged) in a Python environment of requirements.txt, and speaks build_app.py's --json-progress events
(ui/README.md) and its --inspect. The game file holds the base game and the 1.3.0 update together; the app is
self-contained, and its saves, shader cache and log are in "Odyssey Data" next to it. Nothing here reads games/totk.
"""
import argparse
import json
import os
import platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE / 'scripts'))
import build_odyssey   # noqa: E402  (the steps; it imports only the standard library)

GAME = json.loads((HERE / 'game.json').read_text())
APP_NAME = GAME['name']
VERSION, DISPLAY_VERSION = 'v130', '1.3.0'
BASE_TITLE, UPDATE_TITLE = '0100000000010000', '0100000000010800'
SPACE_GB = 12   # scripts/build_odyssey.py preflight: about 12 GB in all
DATA = 'Odyssey Data'   # next to the app (scripts/odyssey_app_launcher.c)
XCODE = '/Applications/Xcode.app/Contents/Developer'
BUILD_INFO = 'Contents/Resources/build-info.json'
BUILD_INFO_SCHEMA = 1
# build_odyssey.build's steps 1-8, as the Builder's stage names (BuildSteps titles)
STAGES = {1: 'check', 2: 'data', 3: 'fonts', 4: 'code', 5: 'tables', 6: 'runtime', 7: 'shaders', 8: 'app'}
# a failed tool's step -> the error code the Builder explains (ui/README.md)
STEP_CODES = {1: 'keys_or_dump', 3: 'fonts', 5: 'hash_mismatch'}

EVENTS = False
EVENT_SCHEMA = 2   # build_app.py EVENT_SCHEMA: the same events
stage = {'stage': 'prepare', 'step': 0, 'of': len(STAGES)}


class BuildError(Exception):
    """As build_app.BuildError: a message for the player, a code for the Builder, the failed tool's log."""
    def __init__(self, message, code='build', log=None):
        super().__init__(message)
        self.code, self.log = code, log


def event(kind, /, **fields):
    print(json.dumps({'type': kind, 'time': round(time.time(), 3), **fields}), flush=True)


def say(msg):
    if not EVENTS:
        print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)
    elif msg.lstrip().startswith('... still running'):
        event('heartbeat', **stage, message=msg.strip())
    else:
        event('progress', **stage, message=msg.strip())


# ---- build_odyssey.build's reporting, as events and logs ----
def step(n, title):
    stage.update(stage=STAGES[n], step=n)
    say(title)
    return time.monotonic()


def done(t0, note=''):
    say(f'done in {time.monotonic() - t0:.0f} s' + (f' ({note})' if note else ''))


def run(cmd, env=None, cwd=HERE):
    """A step's tool with its whole output in <work>/logs, a line a minute while it runs. A failure raises
    CalledProcessError as build_odyssey.run does (its fonts and seed steps catch it), with the log on it."""
    cmd = [str(c) for c in cmd]
    tool = Path(cmd[1] if Path(cmd[0]).name.startswith('python') else cmd[0]).stem
    log = LOGS / f'{stage["step"]}-{tool}.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    finished = threading.Event()

    def beat():
        t0 = time.time()
        while not finished.wait(60):
            say(f'   ... still running ({(time.time() - t0) / 60:.0f} min)')
    threading.Thread(target=beat, daemon=True).start()
    try:
        with open(log, 'w') as f:
            p = subprocess.run(cmd, cwd=cwd, env={**os.environ, **(env or {})}, stdout=f, stderr=subprocess.STDOUT)
    finally:
        finished.set()
    if p.returncode:
        error = subprocess.CalledProcessError(p.returncode, cmd)
        error.log, error.step = log, stage['step']
        raise error


LOGS = Path('logs')   # set to <work>/logs by main


# ---- the game file, read without keys ----
TICKET_BODIES = {0x10000: 0x240, 0x10001: 0x140, 0x10002: 0x80, 0x10003: 0x240, 0x10004: 0x140, 0x10005: 0x80}


def ticket_titles(path):
    """The title IDs in the rights IDs of a PFS0 package's .tik files (build_app.ticket_title_ids); [] otherwise."""
    ids = []
    try:
        with path.open('rb') as f:
            head = f.read(16)
            if len(head) < 16 or head[:4] != b'PFS0':
                return []
            count, strings_size = struct.unpack_from('<II', head, 4)
            table, strings = f.read(count * 24), f.read(strings_size)
            start = 16 + count * 24 + strings_size
            for i in range(count):
                offset, size, name_at, _ = struct.unpack_from('<QQII', table, i * 24)
                if not strings[name_at:strings.find(b'\0', name_at)].lower().endswith(b'.tik') or size < 4:
                    continue
                f.seek(start + offset)
                body = TICKET_BODIES.get(struct.unpack('<I', f.read(4))[0])
                if body is None or size < body + 0x168:
                    continue
                f.seek(start + offset + body + 0x160)
                ids.append(f.read(8).hex().upper())
    except (OSError, struct.error):
        return []
    return ids


def kind_of(path):
    with path.open('rb') as f:
        if f.read(4) == b'PFS0':
            return 'nsp'
        f.seek(0x100)
        if f.read(4) == b'HEAD':
            return 'xci'
    raise BuildError(f'{path.name}: expected an XCI or NSP holding {APP_NAME} and its {DISPLAY_VERSION} update', code='input')


def identify(game, kind, keys, py):
    """The game file holds Super Mario Odyssey: from the tickets of an NSP, or (a card image has none) from the title IDs
    of its NCAs with the keys (scripts/inspect_input.py). The version is checked by hash in step 5."""
    if kind == 'nsp' and (titles := ticket_titles(game)):
        found = {t for t in titles if t in (BASE_TITLE, UPDATE_TITLE)}
    else:
        r = subprocess.run([py, 'scripts/inspect_input.py', game, '--keys', keys], cwd=HERE, capture_output=True, text=True)
        if r.returncode == 2:
            raise BuildError(f'{game.name} could not be read: {(r.stderr or r.stdout).strip()[-300:]}', code='keys_or_dump')
        found = {t for t in (BASE_TITLE, UPDATE_TITLE) if f'Title ID: {t}' in r.stdout}
    if not found:
        raise BuildError(f'{game.name} is not {APP_NAME} ({BASE_TITLE})', code='wrong_game')
    if found == {UPDATE_TITLE}:
        raise BuildError(f'{game.name} holds only the {APP_NAME} update: use a file with the base game and its '
                         f'{DISPLAY_VERSION} update together', code='input')


# ---- the Mac ----
def developer_dir():
    """An Xcode: DEVELOPER_DIR, the selected developer folder, or /Applications/Xcode.app (the runtime needs its Metal 4
    toolchain; the command line tools are not enough)."""
    selected = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True).stdout.strip()
    for folder in (os.environ.get('DEVELOPER_DIR'), selected, XCODE):
        if folder and Path(folder, 'usr/bin/xcodebuild').exists():
            return folder
    raise BuildError(f'{APP_NAME} needs Xcode 26 or later with the Metal 4 SDK (the command line tools are not enough): '
                     'install it from the App Store, then sudo xcode-select -s /Applications/Xcode.app', code='toolchain')


def prerequisites(work):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise BuildError('needs a Mac with Apple silicon', code='toolchain')
    if int(platform.mac_ver()[0].split('.')[0] or 0) < 26:
        raise BuildError(f'needs macOS 26 or later (Metal 4); this is macOS {platform.mac_ver()[0]}', code='toolchain')
    developer = developer_dir()
    missing = [p for p in ('opus', 'libvpx') if not Path(f'/opt/homebrew/opt/{p}/lib').is_dir()]
    if missing:
        raise BuildError(f'Homebrew packages missing: brew install {" ".join(missing)}', code='toolchain')
    for tool in ('git', 'make'):
        if not shutil.which(tool, path='/opt/homebrew/bin:/usr/local/bin:/usr/bin'):
            raise BuildError(f'{tool} not found: xcode-select --install', code='toolchain')
    if ' ' in os.path.relpath(work, HERE):   # build_odyssey.build: make splits such a path
        raise BuildError(f'the work folder\'s path below games/odyssey has a space, which make cannot build into: {work}; '
                         'pick another --work', code='input')
    need = 5 if (work / 'extracted/local/romfs/index.json').is_file() else SPACE_GB
    probe = work if work.exists() else work.parent
    free = shutil.disk_usage(probe).free / 2**30
    if free < need:
        raise BuildError(f'needs about {need} GB free for the work folder ({free:.0f} GB free)', code='disk_space')
    return developer


def prepare_venv(work):
    venv = work / 'venv'
    try:
        if not (venv / 'bin/python').exists():
            say(f'creating the Python environment in {venv}')
            run([sys.executable, '-m', 'venv', venv], cwd=HERE)
        run([venv / 'bin/python', '-m', 'pip', 'install', '-q', '-r', HERE / 'requirements.txt'], cwd=HERE)
    except subprocess.CalledProcessError as e:
        raise BuildError(f'the Python environment could not be made (see {e.log})', code='toolchain', log=e.log) from None
    return venv / 'bin/python'


def checkout_commit():
    try:
        commit = subprocess.run(['git', '-C', REPO, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
        dirty = bool(subprocess.run(['git', '-C', REPO, 'status', '--porcelain', '--untracked-files=no'],
                                    capture_output=True, text=True, check=True).stdout.strip())
        return commit, dirty
    except (OSError, subprocess.CalledProcessError):
        return None, None


def build_info(inputs):
    """build_app.build_info's record (schema 1), for the Builder's library. Never the keys."""
    commit, dirty = checkout_commit()
    return dict(schema=BUILD_INFO_SCHEMA, game=GAME['id'], app_name=APP_NAME, version=VERSION,
                display_version=DISPLAY_VERSION, platform='macos',
                built=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), commit=commit, dirty=dirty,
                inputs={k: str(v) for k, v in inputs.items() if v})


def place(app, out):
    """The app where the player asked for it, with its "Odyssey Data" when nothing is there yet (the launcher reads the
    folder next to the app). Only an app of this game is replaced."""
    if out == app:
        return
    if out.exists():
        info = out / 'Contents/Info.plist'
        if not info.is_file() or GAME['bundle_id'] not in info.read_text(errors='replace'):
            raise BuildError(f'{out} exists and is not an {APP_NAME} app: pick another place with -o', code='input')
        old = out.with_name(f'{out.name}.replaced-{os.getpid()}')
        out.rename(old)
        shutil.move(app, out)
        shutil.rmtree(old, ignore_errors=True)
    else:
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(app, out)
    data, moved = app.with_name(DATA), out.with_name(DATA)
    if data.is_dir() and not moved.exists():
        shutil.move(data, moved)
        say(f'8/8 app: {DATA} is next to it, at {moved}')


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('game', type=Path, help=f'your {APP_NAME} XCI or NSP holding the base game and the {DISPLAY_VERSION} update')
    ap.add_argument('-k', '--keys', type=Path, required=True, help='your prod.keys')
    ap.add_argument('-o', '--out', type=Path, help='the app to write (default: Odyssey.app in the work folder)')
    ap.add_argument('--work', type=Path, help='work folder (default: games/odyssey/Odyssey_build); no space in its path below games/odyssey')
    ap.add_argument('--platform', choices=('macos', 'ios', 'visionos'), default='macos', help='macos only')
    fonts = ap.add_mutually_exclusive_group()
    fonts.add_argument('--firmware', type=Path, help='unpacked firmware NCA directory for the system fonts (needed for an NSP)')
    fonts.add_argument('--shared-fonts', type=Path, help='the six shared fonts (.bfttf) extracted before')
    # build_app.py's options for other games: refused with a reason, so a hand-off never ignores one
    ap.add_argument('--update', type=Path, help=argparse.SUPPRESS)
    ap.add_argument('--dlc', type=Path, action='append', help=argparse.SUPPRESS)
    ap.add_argument('--mod', type=Path, help=argparse.SUPPRESS)
    ap.add_argument('--install-mod-romfs', action='store_true', help=argparse.SUPPRESS)
    ap.add_argument('--no-shader-reminder', action='store_true', help=argparse.SUPPRESS)
    ap.add_argument('--ios-game-data', help=argparse.SUPPRESS)
    ap.add_argument('--json-progress', action='store_true', help='one JSON event per line on stdout (ui/README.md)')
    ap.add_argument('--inspect', action='store_true', help='identify the game file and what the build needs, then stop')
    return ap.parse_args(argv)


def cancelled(signum, frame):
    raise KeyboardInterrupt


def main(argv):
    global EVENTS, LOGS
    args = parse_args(argv)
    if args.json_progress:
        EVENTS = True
        signal.signal(signal.SIGTERM, cancelled)
        if not os.environ.pop('MACNATIVEGAMES_HELLO_SENT', None):   # build_app.py wrote it before handing a card image over
            event('hello', schema=EVENT_SCHEMA)
    game, keys = args.game.expanduser().resolve(), args.keys.expanduser().resolve()
    for path in (game, keys):
        if not path.is_file():
            raise BuildError(f'no such file: {path}', code='input')
    if args.platform != 'macos':
        raise BuildError(f'{APP_NAME} has no iPhone / iPad or Vision Pro build: build the Mac app (leave out --platform)', code='platform')
    if args.update:
        raise BuildError(f'{APP_NAME} is built from one file holding the base game and its {DISPLAY_VERSION} update: '
                         'leave out --update', code='input')
    if args.dlc or args.mod or args.install_mod_romfs:
        raise BuildError(f'{APP_NAME} takes no add-on content or mod here: leave out --dlc and --mod', code='input')
    firmware = args.firmware.expanduser().resolve() if args.firmware else None
    shared = args.shared_fonts.expanduser().resolve() if args.shared_fonts else None
    for folder in (firmware, shared):
        if folder and not folder.is_dir():
            raise BuildError(f'no such folder: {folder}', code='input')
    work = args.work.expanduser().resolve() if args.work else HERE / 'Odyssey_build'
    out = args.out.expanduser().resolve() if args.out else work / 'Odyssey.app'
    if out.suffix.lower() != '.app':
        raise BuildError(f'the output must end in .app: {out}', code='input')
    LOGS = work / 'logs'
    kind = kind_of(game)
    fonts = work / 'extracted/firmware/shared-fonts'
    cached_fonts = len(list(fonts.glob('*.bfttf'))) >= 6
    if args.inspect:
        # an NSP is read from its tickets; a card image needs the Python environment to read its NCAs with the keys
        py = prepare_venv(work) if kind == 'xci' or not ticket_titles(game) else sys.executable
        identify(game, kind, keys, py)
        needs_fonts = kind == 'nsp' and not (firmware or shared or cached_fonts)
        if EVENTS:
            event('inspect', game=GAME['id'], app_name=APP_NAME, version=VERSION, display_version=DISPLAY_VERSION,
                  kind=kind, needs_fonts=needs_fonts, needs_update=False, platforms=['macos'], dlc=False, mod=False,
                  space_gb={'macos': SPACE_GB}, work=str(work), default_out=str(out))
        else:
            say(f'{APP_NAME} {DISPLAY_VERSION} ({kind}); {"needs --firmware" if needs_fonts else "fonts available"}; '
                f'work folder {work}; output {out}')
        return
    if kind == 'nsp' and not (firmware or shared or cached_fonts):
        raise BuildError('an NSP carries no system fonts: pass --firmware <unpacked firmware NCA directory> or '
                         '--shared-fonts <the six extracted .bfttf>', code='fonts')
    t0 = time.time()
    developer = prerequisites(work)
    work.mkdir(parents=True, exist_ok=True)
    say(f'work folder {work}')
    py = prepare_venv(work)
    identify(game, kind, keys, py)
    if shared and shared.resolve() != fonts.resolve():
        if len(list(shared.glob('*.bfttf'))) < 6:
            raise BuildError(f'{shared}: expected the six shared fonts (.bfttf)', code='fonts')
        shutil.rmtree(fonts, ignore_errors=True)
        shutil.copytree(shared, fonts)
    steps = SimpleNamespace(game=game, keys=keys, work=work, firmware=firmware, developer_dir=developer,
                            skip_seed=False, jobs=os.cpu_count() or 8)
    try:
        build_odyssey.build(steps, py, step=step, done=done, run=run, note=say)
    except subprocess.CalledProcessError as e:
        log = getattr(e, 'log', None)
        tail = '\n'.join(log.read_text(errors='replace').splitlines()[-25:]) if log else ''
        raise BuildError(f'{Path(e.cmd[1] if Path(e.cmd[0]).name.startswith("python") else e.cmd[0]).name} failed '
                         f'(exit {e.returncode}); full output: {log}\n{tail}', code=STEP_CODES.get(getattr(e, 'step', 0), 'build'),
                         log=log) from None
    except SystemExit as e:   # build_odyssey's own stops: a card without fonts, a work path make can't use
        message = str(e.code)
        raise BuildError(message, code='fonts' if 'font' in message else 'build') from None
    app = work / 'Odyssey.app'
    (app / BUILD_INFO).write_text(json.dumps(build_info(dict(game=game, firmware=firmware, shared_fonts=shared)), indent=2) + '\n')
    run(['codesign', '--force', '--sign', '-', app])
    place(app, out)
    say(f'done in {(time.time() - t0) / 60:.0f} min: {out}. It holds game data from your own dump: do not share it.')
    if EVENTS:
        event('done', out=str(out), game=GAME['id'], version=VERSION, platform='macos')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except BuildError as e:
        if EVENTS:
            event('error', code=e.code, message=str(e), log=str(e.log) if e.log else None)
        print(f'\nERROR: {e}', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        if EVENTS:
            event('cancelled')
        sys.exit(130)
