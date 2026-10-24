#!/usr/bin/env python3
"""Build the Bayonetta 3 Mac app in one command: the steps of README.md ("Build and play"), each checked against
assets/expected-v1.2.0.json, with the work folder reused across runs.

    python3.14 build.py <base.nsp> --update <update-1.2.0.nsp> -k <prod.keys> [--firmware DIR | --shared-fonts DIR] [-o OUT]

build_app.py at the top of the repository hands a Bayonetta 3 NSP to this script with the same arguments, so either
works. It speaks build_app.py's --json-progress events (ui/README.md) for the Builder, and takes its --inspect. The app it
writes runs the game from the work folder (Info.plist BY3WorkFolder): do not move or delete that folder. Nothing here
reads games/totk.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
GAME = json.loads((HERE / 'game.json').read_text())
EXPECTED = json.loads((HERE / 'assets/expected-v1.2.0.json').read_text())
VERSION = 'v120'
APP_NAME = GAME['name']
SPACE_GB = 20   # the merged RomFS (15 GB) and the rest of the work folder; the app itself is small
TOOL_PATHS = ['/opt/homebrew/bin', '/usr/local/bin']
BUILD_INFO = 'Contents/Resources/build-info.json'
BUILD_INFO_SCHEMA = 1

EVENTS = False
EVENT_SCHEMA = 2   # build_app.py EVENT_SCHEMA: the same events
STAGE = re.compile(r'(\d+)/(\d+) (\w+): ')
stage = {'stage': 'prepare', 'step': 0, 'of': 4}


class BuildError(Exception):
    """As build_app.BuildError: a message for the player, a code for the Builder (ui/README.md), the failed tool's log."""
    def __init__(self, message, code='build', log=None):
        super().__init__(message)
        self.code, self.log = code, log


def event(kind, /, **fields):
    print(json.dumps({'type': kind, 'time': round(time.time(), 3), **fields}), flush=True)


def say(msg):
    if not EVENTS:
        print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)
        return
    if msg.lstrip().startswith('... still running'):
        return event('heartbeat', **stage, message=msg.strip())
    if m := STAGE.match(msg):
        stage.update(stage=m[3], step=int(m[1]), of=int(m[2]))
        msg = msg[m.end():]
    event('progress', **stage, message=msg.strip())


def notice(code, msg):
    if not EVENTS:
        return say(msg)
    if m := STAGE.match(msg):
        msg = msg[m.end():]
    event('notice', **stage, code=code, message=msg.strip())


def run(cmd, log, cwd=HERE, env=None):
    """A step's tool with its whole output in log, a line a minute while it runs; on failure the end of the log."""
    cmd = [str(c) for c in cmd]
    log.parent.mkdir(parents=True, exist_ok=True)
    done = threading.Event()

    def beat():
        t0 = time.time()
        while not done.wait(60):
            say(f'   ... still running ({(time.time() - t0) / 60:.0f} min)')
    threading.Thread(target=beat, daemon=True).start()
    try:
        with open(log, 'w') as f:
            p = subprocess.run(cmd, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT)
    finally:
        done.set()
    if p.returncode:
        tail = log.read_text(errors='replace').splitlines()[-25:]
        tool = Path(cmd[1] if Path(cmd[0]).name.startswith('python') else cmd[0]).name
        raise BuildError(f'{tool} failed (exit {p.returncode}); full output: {log}\n' + '\n'.join(tail), log=log)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def matches(path, digest):
    return path.is_file() and sha256(path) == digest


# ---- the game files, read without keys ----
def pfs0_entries(path):
    """(name, offset, size) of each file in a PFS0 package (NSP); [] for anything else."""
    try:
        with path.open('rb') as f:
            head = f.read(16)
            if len(head) < 16 or head[:4] != b'PFS0':
                return []
            count, strings_size = struct.unpack_from('<II', head, 4)
            table, strings = f.read(count * 24), f.read(strings_size)
            if len(table) < count * 24 or len(strings) < strings_size:
                return []
            start = 16 + count * 24 + strings_size
            entries = []
            for i in range(count):
                offset, size, name_at, _ = struct.unpack_from('<QQII', table, i * 24)
                end = strings.find(b'\0', name_at)
                entries.append((strings[name_at:end if end >= 0 else None].decode(errors='replace'), start + offset, size))
            return entries
    except (OSError, struct.error):
        return []


# Ticket body offsets by signature type (build_app.py TICKET_BODIES); only the rights ID is read, never the title key.
TICKET_BODIES = {0x10000: 0x240, 0x10001: 0x140, 0x10002: 0x80, 0x10003: 0x240, 0x10004: 0x140, 0x10005: 0x80}


def ticket_titles(path):
    """The title IDs in the rights IDs of the package's .tik files."""
    ids = []
    with path.open('rb') as f:
        for name, offset, size in pfs0_entries(path):
            if not name.lower().endswith('.tik') or size < 4:
                continue
            f.seek(offset)
            body = TICKET_BODIES.get(struct.unpack('<I', f.read(4))[0])
            if body is None or size < body + 0x168:
                continue
            f.seek(offset + body + 0x160)
            ids.append(f.read(8).hex().upper())
    return ids


def check_package(path, role):
    """The base NSP or the 1.2.0 update NSP this build knows: its title from the tickets, its Program NCA by name (an
    NCA's name is its content ID, so the reference dump's name identifies the version)."""
    title = EXPECTED['title_id'] if role == 'base' else EXPECTED['update_title_id']
    nca = EXPECTED['base_program_nca' if role == 'base' else 'update_program_nca']
    if not pfs0_entries(path):
        raise BuildError(f'{path.name}: expected an NSP; {APP_NAME} is built from NSPs only', code='input')
    titles = ticket_titles(path)
    if title not in titles:
        other = EXPECTED['update_title_id'] if role == 'base' else EXPECTED['title_id']
        if other in titles:
            raise BuildError(f'{path.name} is the {APP_NAME} {"update" if role == "base" else "base game"}, not the '
                             f'{role}: pass the base NSP as the game file and the update with --update', code='wrong_game')
        raise BuildError(f'{path.name} is not the {APP_NAME} {role} ({title}); its tickets name {titles or "no title"}',
                         code='wrong_game')
    names = {name.lower(): size for name, _, size in pfs0_entries(path)}
    if names.get(nca['name']) != nca['size']:
        raise BuildError(f'{path.name}: not the {APP_NAME} {"base game" if role == "base" else EXPECTED["display_version"] + " update"} '
                         f'this build supports (its Program NCA is not {nca["name"]})',
                         code='unsupported_version' if role == 'update' else 'hash_mismatch')


# ---- the Mac ----
def links(sdk=None):
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run(['xcrun', 'clang++', '-std=c++11', '-arch', 'arm64', '-x', 'c++', '-', '-o', Path(tmp) / 'probe'],
                           input='#include <string>\nint main() { return std::string("x").size() - 1; }\n',
                           capture_output=True, text=True, env=dict(os.environ, SDKROOT=str(sdk)) if sdk else None)
        return r.returncode == 0, r.stderr


def choose_sdk():
    """As build_app.choose_sdk: when the default SDK does not link (an SDK newer than the linker), the newest macOS 26+
    SDK that does."""
    ok, why = links()
    if ok:
        return
    developer = Path(subprocess.run(['xcode-select', '-p'], capture_output=True, text=True).stdout.strip())
    found = {}
    for folder in (developer / 'SDKs', developer / 'Platforms/MacOSX.platform/Developer/SDKs'):
        for sdk in folder.glob('MacOSX*.sdk'):
            try:
                key = tuple(int(x) for x in sdk.name[len('MacOSX'):-len('.sdk')].split('.'))
            except ValueError:
                continue
            if key[0] >= 26:
                found.setdefault(sdk.resolve(), key)
    for sdk in sorted(found, key=found.get, reverse=True):
        if links(sdk)[0]:
            os.environ['SDKROOT'] = str(sdk)
            notice('sdk_fallback', f'the default macOS SDK does not link C++ programs, so the build uses {sdk}')
            return
    raise BuildError(f'clang++ links no C++ program with any macOS SDK here: {why.strip()[:300]}', code='toolchain')


def prerequisites():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise BuildError('needs a Mac with Apple silicon', code='toolchain')
    if int(platform.mac_ver()[0].split('.')[0] or 0) < 26:
        raise BuildError(f'needs macOS 26 or later (Metal 4); this is macOS {platform.mac_ver()[0]}', code='toolchain')
    if subprocess.run(['xcrun', '--find', 'clang'], capture_output=True).returncode:
        raise BuildError('the Xcode command line tools are missing: xcode-select --install', code='toolchain')
    choose_sdk()
    missing = [p for p in ('opus', 'libvpx') if not Path(f'/opt/homebrew/opt/{p}/lib').is_dir()]
    if missing:
        raise BuildError(f'Homebrew packages missing: brew install {" ".join(missing)}', code='toolchain')
    for tool in ('git', 'make'):
        if not shutil.which(tool, path=os.pathsep.join(TOOL_PATHS + ['/usr/bin'])):
            raise BuildError(f'{tool} not found: xcode-select --install', code='toolchain')


def checkout_commit():
    try:
        commit = subprocess.run(['git', '-C', REPO, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
        dirty = bool(subprocess.run(['git', '-C', REPO, 'status', '--porcelain', '--untracked-files=no'],
                                    capture_output=True, text=True, check=True).stdout.strip())
        return commit, dirty
    except (OSError, subprocess.CalledProcessError):
        return None, None


def build_info(inputs, work):
    """build_app.build_info's record (schema 1): what the app was built from, for the Builder's library. Never the keys."""
    commit, dirty = checkout_commit()
    return dict(schema=BUILD_INFO_SCHEMA, game=GAME['id'], app_name=APP_NAME, version=VERSION,
                display_version=EXPECTED['display_version'], platform='macos',
                built=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), commit=commit, dirty=dirty, work=str(work),
                inputs={k: str(v) for k, v in inputs.items() if v})


# ---- the steps ----
def prepare_venv(work, logs):
    """<work>/venv with requirements.txt: the Python packages the scripts import."""
    venv = work / 'venv'
    if not (venv / 'bin/python').exists():
        say(f'creating the Python environment in {venv}')
        run([sys.executable, '-m', 'venv', venv], logs / 'venv.log')
    run([venv / 'bin/python', '-m', 'pip', 'install', '-q', '-r', HERE / 'requirements.txt'], logs / 'pip.log')
    return venv / 'bin/python'


def step_code(py, work, update, keys, logs):
    exefs = work / f'extracted/{VERSION}/exefs'
    if all(matches(exefs / n, h) for n, h in EXPECTED['exefs_sha256'].items()):
        say('1/4 code: the 1.2.0 code is already extracted and verified')
    else:
        say('1/4 code: extracting and verifying the 1.2.0 code from the update')
        shutil.rmtree(exefs, ignore_errors=True)
        run([py, 'scripts/extract_code.py', update, '--keys', keys, '--output', exefs], logs / 'extract-code.log')
        bad = [n for n, h in EXPECTED['exefs_sha256'].items() if not matches(exefs / n, h)]
        if bad:
            raise BuildError(f'the extracted code differs from the reference 1.2.0: {", ".join(bad)}', code='hash_mismatch')
    rewritten = work / f'rewritten/{VERSION}'
    env = dict(os.environ, DM_RULESET='native', DM_PRIVATE_GATES='0')
    for module in ('sdk', 'subsdk0', 'main'):
        target = rewritten / f'{module}.patched.bin'
        want = EXPECTED['rewritten_sha256'][target.name]
        if matches(target, want):
            continue
        say(f'1/4 code: rewriting {module} for Apple silicon')
        rewritten.mkdir(parents=True, exist_ok=True)
        run([py, 'third_party/d2r/patch_nso.py', exefs / module, rewritten, module], logs / f'rewrite-{module}.log', env=env)
        if not matches(target, want):
            raise BuildError(f'the rewritten {module} differs from the reference rewrite (assets/expected-v1.2.0.json)', code='hash_mismatch')
    elf = work / f'extracted/{VERSION}/elf'
    if not (elf / 'modules.json').is_file():
        run([py, 'scripts/prepare_modules.py', exefs, '--output', elf], logs / 'prepare-modules.log')
    say('1/4 code: verified (ExeFS and rewrite match assets/expected-v1.2.0.json)')


def romfs_done(romfs):
    try:
        index = json.loads((romfs / 'index.json').read_text())
    except (OSError, ValueError):
        return False
    return (index.get('status') == 'pass' and index.get('romfs_sha256') == EXPECTED['romfs']['sha256']
            and (romfs / 'romfs.bin').stat().st_size == EXPECTED['romfs']['size'])


def step_data(py, work, base, update, keys, fonts, logs):
    romfs = work / f'extracted/{VERSION}/romfs'
    if romfs_done(romfs):
        say('2/4 data: the merged RomFS is already verified')
    else:
        say('2/4 data: merging the base game and the update into one RomFS and verifying all six IVFC levels '
            '(15 GB; tens of minutes)')
        shutil.rmtree(romfs, ignore_errors=True)
        run([py, 'scripts/merge_romfs.py', base, update, '--keys', keys, '--output', romfs], logs / 'merge-romfs.log')
        if not romfs_done(romfs):
            raise BuildError('the merged RomFS differs from the reference 1.2.0 (assets/expected-v1.2.0.json)', code='hash_mismatch')
    folder = work / 'extracted/firmware/shared-fonts'
    firmware, shared = fonts
    if firmware:
        say(f'2/4 data: extracting the system shared fonts from {firmware}')
        shutil.rmtree(folder, ignore_errors=True)
        try:
            run([py, 'scripts/extract_shared_fonts.py', '--keys', keys, '--firmware', firmware, '--output', folder],
                logs / 'shared-fonts.log')
        except BuildError as e:
            e.code = 'fonts'
            raise
    elif shared:
        if not fonts_valid(shared):
            raise BuildError(f'{shared}: expected the extracted shared fonts with their manifest.json '
                             '(scripts/extract_shared_fonts.py writes both)', code='fonts')
        if shared.resolve() != folder.resolve():
            shutil.rmtree(folder, ignore_errors=True)
            shutil.copytree(shared, folder)
    if fonts_valid(folder):
        say('2/4 data: shared fonts ready')
    else:
        say('2/4 data: no shared fonts (optional: the NSPs have none; pass --firmware to add them)')


def fonts_valid(folder):
    try:
        return json.loads((folder / 'manifest.json').read_text()).get('status') == 'pass'
    except (OSError, ValueError):
        return False


def step_shaders(py, work, logs):
    say('3/4 shaders: the shader translator (checked against its SHA-256) and SPIRV-Cross')
    run(['make', 'shader-tools', f'WORK={work}', f'PY={py}'], logs / 'shader-tools.log')


def step_app(py, work, update, keys, out, logs, inputs):
    say('4/4 app: generating the runtime tables, compiling the runtime and the launcher')
    partial = out.with_name(out.name + '.partial')
    shutil.rmtree(partial, ignore_errors=True)
    run(['make', 'prepare', 'patches', 'mods', 'app', f'WORK={work}', f'PY={py}', f'APP={partial}', f'GAME={update}',
         f'KEYS={keys}'], logs / 'app.log')
    (partial / BUILD_INFO).parent.mkdir(parents=True, exist_ok=True)
    (partial / BUILD_INFO).write_text(json.dumps(build_info(inputs, work), indent=2) + '\n')
    run(['codesign', '--force', '--sign', '-', partial], logs / 'codesign.log')
    if out.exists():
        old = out.with_name(f'{out.name}.replaced-{os.getpid()}')
        out.rename(old)
        partial.rename(out)
        shutil.rmtree(old, ignore_errors=True)
    else:
        partial.rename(out)
    say(f'4/4 app: {out}')


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('game', type=Path, help='the base game NSP (01004A4010FEA000)')
    ap.add_argument('--update', type=Path, help='the 1.2.0 update NSP (01004A4010FEA800); needed: the code comes from it')
    ap.add_argument('-k', '--keys', type=Path, required=True, help='your prod.keys')
    ap.add_argument('-o', '--out', type=Path, help='the app to write (default: next to the game file)')
    ap.add_argument('--work', type=Path, help='work folder (default: BY3_build next to the game file); the app runs the game from it')
    ap.add_argument('--platform', choices=('macos', 'ios', 'visionos'), default='macos', help='macos only')
    fonts = ap.add_mutually_exclusive_group()
    fonts.add_argument('--firmware', type=Path, help='optional: an unpacked firmware NCA directory for the system shared fonts')
    fonts.add_argument('--shared-fonts', type=Path, help='optional: shared fonts extracted before, with their manifest.json')
    # build_app.py's options for other games: refused with a reason, so a hand-off never ignores one
    ap.add_argument('--dlc', type=Path, action='append', help=argparse.SUPPRESS)
    ap.add_argument('--mod', type=Path, help=argparse.SUPPRESS)
    ap.add_argument('--install-mod-romfs', action='store_true', help=argparse.SUPPRESS)
    ap.add_argument('--no-shader-reminder', action='store_true', help=argparse.SUPPRESS)
    ap.add_argument('--json-progress', action='store_true', help='one JSON event per line on stdout (ui/README.md)')
    ap.add_argument('--inspect', action='store_true', help='identify the game files and what the build needs, then stop')
    return ap.parse_args(argv)


def cancelled(signum, frame):
    raise KeyboardInterrupt


def main(argv):
    global EVENTS
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
    if args.dlc:
        raise BuildError(f'{APP_NAME} has no DLC support: leave out --dlc', code='input')
    if args.mod or args.install_mod_romfs:
        raise BuildError(f'{APP_NAME} takes its mods from games/by3/mods (README.md), not --mod', code='input')
    update = args.update.expanduser().resolve() if args.update else None
    if update and not update.is_file():
        raise BuildError(f'no such file: {update}', code='input')
    firmware = args.firmware.expanduser().resolve() if args.firmware else None
    shared = args.shared_fonts.expanduser().resolve() if args.shared_fonts else None
    for folder in (firmware, shared):
        if folder and not folder.is_dir():
            raise BuildError(f'no such folder: {folder}', code='input')
    out = args.out.expanduser().resolve() if args.out else game.parent / f'{APP_NAME}.app'
    if out.suffix.lower() != '.app':
        raise BuildError(f'the output must end in .app: {out}', code='input')
    work = args.work.expanduser().resolve() if args.work else game.parent / 'BY3_build'
    check_package(game, 'base')
    if update:
        check_package(update, 'update')
    if args.inspect:
        if EVENTS:
            event('inspect', game=GAME['id'], app_name=APP_NAME, version=VERSION if update else None,
                  display_version=EXPECTED['display_version'] if update else None, kind='nsp', needs_fonts=False,
                  needs_update=update is None, platforms=['macos'], dlc=False, mod=False, space_gb={'macos': SPACE_GB},
                  work=str(work), default_out=str(out))
        else:
            say(f'{APP_NAME} {EXPECTED["display_version"] + " (nsp)" if update else "base game: needs --update <the 1.2.0 update NSP>"}; '
                f'work folder {work}; output {out}')
        return
    if not update:
        raise BuildError(f'{APP_NAME} needs its {EXPECTED["display_version"]} update: the base NSP holds no code. '
                         'Pass it with --update <update.nsp>', code='input')
    prerequisites()
    t0 = time.time()
    logs = work / 'logs'
    work.mkdir(parents=True, exist_ok=True)
    if not (work / f'extracted/{VERSION}/romfs/romfs.bin').exists():
        free = shutil.disk_usage(work).free / 2**30
        if free < SPACE_GB:
            raise BuildError(f'needs about {SPACE_GB} GB free for the work folder ({free:.0f} GB free)', code='disk_space')
    say(f'work folder {work}')
    py = prepare_venv(work, logs)
    step_code(py, work, update, keys, logs)
    step_data(py, work, game, update, keys, (firmware, shared), logs)
    step_shaders(py, work, logs)
    step_app(py, work, update, keys, out, logs,
             dict(game=game, update=update, firmware=firmware, shared_fonts=shared))
    say(f'done in {(time.time() - t0) / 60:.0f} min: {out}. It runs the game from {work}: keep that folder where it is.')
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
