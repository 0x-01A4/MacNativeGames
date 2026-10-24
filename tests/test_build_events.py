"""build_app.py --json-progress and --inspect: the events a front end (ui/Builder) reads, and that the text output and the
build steps are unchanged without the flags.

The build steps are mocked; no game data and no keys.
"""
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'games/totk/ios/tools')]   # xcode_dir: build_app.ios_prerequisites
import build_app


class Stop(Exception):
    pass


def events(text):
    return [json.loads(line) for line in text.splitlines() if line.strip()]


class Say(unittest.TestCase):
    def setUp(self):
        build_app.stage.update(stage='prepare', step=0, of=4)
        self.addCleanup(setattr, build_app, 'EVENTS', False)

    def said(self, *messages):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            for m in messages:
                build_app.say(m)
        return out.getvalue()

    def test_text_is_unchanged_without_the_flag(self):
        text = self.said('1/4 code: extracting the ExeFS from the game file')
        self.assertRegex(text, r'^\[\d\d:\d\d:\d\d\] 1/4 code: extracting the ExeFS from the game file\n$')

    def test_stage_comes_from_the_prefix_and_carries_over(self):
        build_app.EVENTS = True
        got = events(self.said('fetching the pinned SPIRV-Cross sources', '2/4 data: extracting and verifying the RomFS',
                               '   checked in 3 s', '   ... still running (2 min)'))
        self.assertEqual([(e['type'], e['stage'], e['step']) for e in got],
                         [('progress', 'prepare', 0), ('progress', 'data', 2), ('progress', 'data', 2), ('heartbeat', 'data', 2)])
        self.assertEqual(got[1]['message'], 'extracting and verifying the RomFS')
        self.assertEqual(got[1]['of'], 4)
        self.assertEqual(got[2]['message'], 'checked in 3 s')

    def test_update_stage(self):
        build_app.EVENTS = True
        got = events(self.said('2/4 update: merging base + 1.4.3 and verifying all IVFC levels'))
        self.assertEqual(got[0]['stage'], 'update')


    def test_notice_is_its_own_event_and_plain_text_without_the_flag(self):
        with mock.patch.object(build_app, 'say') as say:
            build_app.notice('npdm_signed', '1/4 code: main.npdm is a Nintendo-signed 1.0.0 file from another dump; using it')
        say.assert_called_once_with('1/4 code: main.npdm is a Nintendo-signed 1.0.0 file from another dump; using it')
        build_app.EVENTS = True
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            build_app.notice('npdm_signed', '1/4 code: main.npdm is a Nintendo-signed 1.0.0 file from another dump; using it')
        got = events(out.getvalue())
        self.assertEqual((got[0]['type'], got[0]['code'], got[0]['stage'], got[0]['step']), ('notice', 'npdm_signed', 'code', 1))
        self.assertEqual(got[0]['message'], 'main.npdm is a Nintendo-signed 1.0.0 file from another dump; using it')


class IOSPrerequisites(unittest.TestCase):
    def test_no_xcode_stops_before_the_build(self):
        with mock.patch('xcode_dir.developer_dir', side_effect=RuntimeError('no Xcode with the iOS SDK found')):
            with self.assertRaises(build_app.BuildError) as e:
                build_app.ios_prerequisites()
        self.assertEqual(e.exception.code, 'toolchain')
        self.assertIn('Xcode 26', str(e.exception))

    def test_missing_brew_tools_are_named(self):
        with mock.patch('xcode_dir.developer_dir', return_value='/Applications/Xcode.app/Contents/Developer'), \
                mock.patch.object(build_app.shutil, 'which', side_effect=lambda t, path=None: None if t != 'cmake' else '/x/cmake'):
            with self.assertRaises(build_app.BuildError) as e:
                build_app.ios_prerequisites()
        self.assertIn('brew install xcodegen ninja', str(e.exception))


class SDKChoice(unittest.TestCase):
    """An SDK newer than the linker (MacOSX27.0.sdk next to ld from command line tools 26.6, 2026-10-23)."""
    def setUp(self):
        self.addCleanup(setattr, build_app, 'EVENTS', False)
        self.enterContext(mock.patch.dict(build_app.os.environ))
        build_app.os.environ.pop('SDKROOT', None)
        self.enterContext(mock.patch.object(build_app.subprocess, 'run', return_value=mock.Mock(stdout='/SDKs/MacOSX27.0.sdk\n')))
        self.enterContext(mock.patch.object(build_app, 'say'))

    def test_default_that_links_is_left_alone(self):
        with mock.patch.object(build_app, 'links', return_value=(True, '')):
            self.assertIsNone(build_app.choose_sdk())
        self.assertNotIn('SDKROOT', build_app.os.environ)

    def test_newest_sdk_that_links(self):
        new, mid, old = Path('/SDKs/MacOSX27.0.sdk'), Path('/SDKs/MacOSX26.5.sdk'), Path('/SDKs/MacOSX26.0.sdk')
        with mock.patch.object(build_app, 'links', side_effect=lambda sdk=None: (sdk in (mid, old), 'unknown architecture')), \
                mock.patch.object(build_app, 'sdk_candidates', return_value=[new, mid, old]), \
                mock.patch.object(build_app.Path, 'resolve', lambda self: self):
            self.assertEqual(build_app.choose_sdk(), mid)
        self.assertEqual(build_app.os.environ['SDKROOT'], str(mid))

    def test_none_links(self):
        with mock.patch.object(build_app, 'links', return_value=(False, 'tapi error: malformed file')), \
                mock.patch.object(build_app, 'sdk_candidates', return_value=[Path('/SDKs/MacOSX26.5.sdk')]):
            with self.assertRaises(build_app.BuildError) as e:
                build_app.choose_sdk()
        self.assertEqual(e.exception.code, 'toolchain')
        self.assertIn('tapi error', str(e.exception))


class Errors(unittest.TestCase):
    def test_codes(self):
        self.assertEqual(build_app.BuildError('x').code, 'build')
        with self.assertRaises(build_app.BuildError) as e:
            build_app.check('main', 'a' * 64, 'b' * 64)
        self.assertEqual(e.exception.code, 'hash_mismatch')

    def test_failed_step_names_its_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'step.log'
            with self.assertRaises(build_app.BuildError) as e:
                build_app.run(['/bin/sh', '-c', 'echo boom; exit 3'], log, quiet=False)
            self.assertEqual(e.exception.log, log)
            self.assertIn('boom', str(e.exception))

    def run_script(self, *argv):
        return subprocess.run([sys.executable, ROOT / 'build_app.py', *argv], capture_output=True, text=True, timeout=60)

    def test_error_event_from_the_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = self.run_script(str(Path(tmp) / 'missing.xci'), '-k', str(Path(tmp) / 'prod.keys'), '--json-progress')
        self.assertEqual(r.returncode, 1)
        got = events(r.stdout)
        self.assertEqual(got[0], {'type': 'hello', 'time': got[0]['time'], 'schema': build_app.EVENT_SCHEMA})
        self.assertEqual((got[-1]['type'], got[-1]['code'], got[-1]['log']), ('error', 'input', None))
        self.assertIn('ERROR: no such file', r.stderr)

    def test_text_error_without_the_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = self.run_script(str(Path(tmp) / 'missing.xci'), '-k', str(Path(tmp) / 'prod.keys'))
        self.assertEqual((r.returncode, r.stdout), (1, ''))
        self.assertIn('ERROR: no such file', r.stderr)


class Inspect(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, build_app, 'EVENTS', False)
        build_app.stage.update(stage='prepare', step=0, of=4)
        self.folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.keys = self.folder / 'prod.keys'
        self.keys.write_text('')

    def main(self, game_file, *extra, game='totk', update_version='v143'):
        def prepare_work(work, py, logs):
            work.mkdir(parents=True, exist_ok=True)
            return work / 'totk'
        patches = [
            mock.patch.object(build_app, 'prerequisites', return_value=Path('/usr/bin/python3')),
            mock.patch.object(build_app, 'prepare_work', side_effect=prepare_work),
            mock.patch.object(build_app, 'identify_game', return_value=game),
            mock.patch.object(build_app, 'identify_update', side_effect=lambda tree, u, keys, logs: (update_version, u)),
            mock.patch.object(build_app, 'prepare_update_container', side_effect=lambda tree, u, keys, logs: u),
            mock.patch.object(build_app, 'identify_botw_update', return_value='botw190'),
            mock.patch.object(build_app, 'check_package'),   # the package roles: tests/test_game_selection.py
            mock.patch.object(build_app, 'signal'),
        ] + [mock.patch.object(build_app, step, side_effect=Stop) for step in
             ('step_code', 'step_data', 'step_code_botw', 'step_data_botw', 'step_app')]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            build_app.main([str(game_file), '-k', str(self.keys), '--inspect', '--json-progress', *extra])
        return events(out.getvalue())

    def nsp(self, name):
        path = self.folder / name
        path.write_bytes(b'PFS0' + bytes(12))
        return path

    def xci(self, name):
        path = self.folder / name
        path.write_bytes(bytes(0x100) + b'HEAD' + bytes(0x200))
        return path

    def test_totk_card_image(self):
        got = self.main(self.xci('totk.xci'))
        self.assertEqual(got[0]['type'], 'hello')
        report = got[-1]
        self.assertEqual(report['type'], 'inspect')
        self.assertEqual((report['game'], report['version'], report['display_version'], report['kind']), ('totk', 'v0', '1.0.0', 'xci'))
        self.assertEqual((report['needs_fonts'], report['platforms'], report['dlc']), (False, ['macos', 'ios'], False))
        self.assertEqual((report['needs_update'], report['mod'], report['space_gb']), (False, True, {'macos': 25, 'ios': 45}))
        self.assertEqual(report['work'], str(self.folder.resolve() / 'TOTK_build'))
        self.assertEqual(report['default_out'], str(self.folder.resolve() / 'Tears of the Kingdom.app'))

    def test_totk_nsp_with_update_reports_the_missing_fonts_instead_of_failing(self):
        got = self.main(self.nsp('totk.nsp'), '--update', str(self.nsp('update.nsp')))
        self.assertEqual((got[-1]['version'], got[-1]['display_version'], got[-1]['needs_fonts']), ('v143', '1.4.3', True))
        self.assertEqual(got[-1]['space_gb'], {'macos': 40, 'ios': 60})

    def test_botw_base_with_update(self):
        got = self.main(self.nsp('botw.nsp'), '--update', str(self.nsp('update.nsp')), game='botw')
        self.assertEqual((got[-1]['game'], got[-1]['version'], got[-1]['platforms'], got[-1]['dlc']),
                         ('botw', 'botw190', ['macos'], True))
        self.assertEqual((got[-1]['mod'], got[-1]['space_gb']), (False, {'macos': 22}))
        self.assertEqual(got[-1]['default_out'], str(self.folder.resolve() / 'Breath of the Wild.app'))


if __name__ == '__main__':
    unittest.main()
