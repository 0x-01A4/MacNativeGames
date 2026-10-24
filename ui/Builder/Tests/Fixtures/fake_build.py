#!/usr/bin/env python3
"""A stand-in for build_app.py --json-progress: the same events, no game files, and nothing written but the failed tool's
log in the temporary folder (FAKE_BUILD=fail). For the Builder's tests and for trying the app:
BUILDER_SCRIPT=<this file> "MacNativeGames Builder.app/Contents/MacOS/MacNativeGamesBuilder".
FAKE_BUILD=ok (default) | fail | slow | noheader | schema1 (an older script); FAKE_GAME=totk (default) | botw (1.9.0, with
DLC) | by3 (needs its update, Mac only) | odyssey (one file with its update, eight steps);
FAKE_DELAY: seconds between events (default 0.4)."""
import json, os, signal, sys, tempfile, time

mode, delay = os.environ.get('FAKE_BUILD', 'ok'), float(os.environ.get('FAKE_DELAY', '0.4'))
GAME = os.environ.get('FAKE_GAME', 'totk')
botw, by3, odyssey = GAME == 'botw', GAME == 'by3', GAME == 'odyssey'
APP = {'totk': 'Tears of the Kingdom', 'botw': 'Breath of the Wild', 'by3': 'Bayonetta 3', 'odyssey': 'Super Mario Odyssey'}[GAME]


def event(kind, /, **fields):
    print(json.dumps({'type': kind, 'time': round(time.time(), 3), **fields}), flush=True)


def cancelled(signum, frame):
    event('cancelled')
    sys.exit(130)


signal.signal(signal.SIGTERM, cancelled)
argv = sys.argv[1:]
game = argv[0] if argv else 'game.xci'
folder = os.path.dirname(os.path.abspath(game))
if mode != 'noheader':
    event('hello', schema=1 if mode == 'schema1' else 2)
print('a line that is not an event', file=sys.stderr, flush=True)
if '--inspect' in argv:
    time.sleep(delay)
    update = '--update' in argv
    if (botw or by3) and '--mod' in argv:
        event('error', code='input', message="--mod: merging a mod's main-module patches is only wired for Tears of the Kingdom so far", log=None)
        sys.exit(1)
    if odyssey:
        event('inspect', game='odyssey', app_name=APP, version='v130', display_version='1.3.0', kind='xci', needs_fonts=False,
              needs_update=False, platforms=['macos'], dlc=False, mod=False, space_gb={'macos': 12},
              work=os.path.join(folder, 'Odyssey_build'), default_out=os.path.join(folder, 'Odyssey_build', 'Odyssey.app'))
        sys.exit(0)
    if by3:
        event('inspect', game='by3', app_name=APP, version='v120' if update else None, display_version='1.2.0' if update else None,
              kind='nsp', needs_fonts=False, needs_update=not update, platforms=['macos'], dlc=False, mod=False,
              space_gb={'macos': 20}, work=os.path.join(folder, 'BY3_build'), default_out=os.path.join(folder, APP + '.app'))
        sys.exit(0)
    version = ('botw190' if update else 'botw160') if botw else ('v143' if update else 'v0')
    event('inspect', game=GAME, app_name=APP, version=version,
          display_version={'botw190': '1.9.0', 'botw160': '1.6.0', 'v143': '1.4.3', 'v0': '1.0.0'}[version],
          kind='nsp' if game.endswith('.nsp') else 'xci',
          needs_fonts=(botw or game.endswith('.nsp')) and '--firmware' not in argv and '--shared-fonts' not in argv,
          needs_update=False, platforms=['macos', 'ios'] if botw else ['macos', 'ios', 'visionos'], dlc=version == 'botw190',
          dlc_max=2 if version == 'botw190' else 0, mod=not botw,
          space_gb={'macos': 22, 'ios': 22} if botw else {'macos': 40 if update else 25, 'ios': 60 if update else 45, 'visionos': 60 if update else 45},
          work=os.path.join(folder, 'BotW_build' if botw else 'TOTK_build'), default_out=os.path.join(folder, APP + '.app'))
    sys.exit(0)
steps = [(0, 'prepare', 'fetching the pinned SPIRV-Cross sources'), (1, 'code', 'extracting the ExeFS from the game file'),
         (1, 'code', 'rewriting main for Apple silicon (the big one: about a minute)'),
         (2, 'data', 'extracting and verifying the RomFS (17 GB, a minute or two)'),
         (3, 'shaders', 'discovering and translating startup shaders from your game data'),
         (4, 'app', 'building the game binary and the launcher'), (4, 'app', 'assembling the app')]
if odyssey:
    steps = [(0, 'prepare', 'creating the Python environment')] + [(n, name, f'step {n}') for n, name in enumerate(
        ['check', 'data', 'fonts', 'code', 'tables', 'runtime', 'shaders', 'app'], 1)]
for i, (step, stage, message) in enumerate(steps):
    time.sleep(delay * (20 if mode == 'slow' and i == 2 else 1))
    event('progress', stage=stage, step=step, of=8 if odyssey else 4, message=message)
    if i == 1:
        event('notice', stage=stage, step=step, of=4, code='npdm_signed',
              message='main.npdm is a Nintendo-signed 1.0.0 file from another dump; using it')
    if step == 2:
        event('heartbeat', stage=stage, step=step, of=4, message='... still running (1 min)')
    if mode == 'fail' and step == 2:
        tool_log = os.path.join(tempfile.gettempdir(), 'fake_build-hactool-romfs.log')   # the failed tool's log
        with open(tool_log, 'w') as f:
            f.write('hactool: a stand-in log for the Builder\'s "Show Tool Log"\n')
        event('error', code='hash_mismatch', message='RomFS: SHA-256 0123456789abcdef... is not the expected fedcba9876543210... '
              '(is this the supported game version, and the dump complete?)', log=tool_log)
        print('\nERROR: RomFS: SHA-256 mismatch', file=sys.stderr)
        sys.exit(1)
platform = argv[argv.index('--platform') + 1] if '--platform' in argv else 'macos'
out = argv[argv.index('-o') + 1] if '-o' in argv else os.path.join(folder, APP + ('.ipa' if platform == 'ios' else '.app'))
event('done', out=out, game=GAME, version='v0', platform=platform)
