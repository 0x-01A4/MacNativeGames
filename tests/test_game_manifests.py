"""games/<name>/game.json, which the Builder reads to know the games; build_app.py's hand-off to a game's own build
script (games/by3/build.py, games/dread/build.py); and those scripts' --inspect and argument checks. Synthetic PFS0 files only; no game data
and no keys.
"""
import contextlib
import importlib.util
import io
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT)]
import build_app

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


by3 = load('by3_build', 'games/by3/build.py')
smo = load('odyssey_build', 'games/odyssey/build.py')
dread = load('dread_build', 'games/dread/build.py')

FIELDS = {'schema', 'id', 'name', 'title_id', 'bundle_id', 'build', 'sources'}   # and data_folder or data_beside_app


def ticket(title_id):
    """A 0x2C0-byte RSA-2048 ticket (signature type 04 00 01 00), the rights ID at 0x140 + 0x160, a zero key."""
    data = bytearray(0x2C0)
    data[0:4] = bytes([4, 0, 1, 0])
    data[0x2A0:0x2A8] = bytes.fromhex(title_id)
    return bytes(data)


def nsp(path, title_id, nca=None):
    """A PFS0 with the title's ticket, and an NCA entry that claims `nca` = (name, size) without holding the bytes."""
    entries = [(f'{title_id.lower()}0000000000000000.tik', ticket(title_id), None)]
    if nca:
        entries.append((nca[0], b'', nca[1]))
    strings, table, payload = b'', bytearray(), b''
    for name, data, size in entries:
        table += struct.pack('<QQII', len(payload), len(data) if size is None else size, len(strings), 0)
        strings += name.encode() + b'\0'
        payload += data
    path.write_bytes(b'PFS0' + struct.pack('<III', len(entries), len(strings), 0) + bytes(table) + strings + payload)
    return path


def events(argv, script=None):
    """A game build script's (by3 by default) JSON events from main, and its BuildError (or None)."""
    script = script or by3
    out, error = io.StringIO(), None
    with contextlib.redirect_stdout(out), mock.patch.object(script, 'EVENTS', False), \
            mock.patch.object(script.signal, 'signal'):
        try:
            script.main(argv + ['--json-progress'])
        except script.BuildError as e:
            error = e
    return [json.loads(line) for line in out.getvalue().splitlines() if line.startswith('{')], error


class Manifests(unittest.TestCase):
    def test_every_game_folder(self):
        self.assertEqual({g['id'] for g in build_app.GAMES}, {'totk', 'botw', 'by3', 'odyssey', 'dread'})
        for g in build_app.GAMES:
            self.assertLessEqual(FIELDS, set(g), g['id'])
            self.assertTrue({'data_folder', 'data_beside_app'} & set(g), g['id'])
            self.assertEqual(g['schema'], 1)
            self.assertTrue((ROOT / 'games' / g['id'] / 'game.json').is_file())
            self.assertTrue((ROOT / g['build']).is_file(), g['build'])
            for source in g['sources']:
                self.assertTrue((ROOT / source).exists(), source)
            self.assertRegex(g['title_id'], r'^[0-9A-F]{13}000$')
            for ext in g.get('files', {}).get('game', []) + g.get('files', {}).get('update', []):
                self.assertIn(ext, ('xci', 'nsp', 'nsz'))
            self.assertLessEqual(set(g.get('needs', [])), {'xcode'}, g['id'])   # what the Builder checks before a build
            self.assertIn(g.get('work_holds_game_data', False), (True, False), g['id'])
            if 'install_tool' in g:
                self.assertTrue((ROOT / g['install_tool']).is_file(), g['install_tool'])
            if 'shader_contribution' in g:
                self.assertGreater(g['shader_contribution']['step'], 0)
                self.assertTrue(g['shader_contribution']['form'].startswith('https://github.com/'))

    def test_build_app_games_agree(self):
        # the games build_app.py builds itself: the same title, name, bundle identifier and data folder as its tables
        mine = {g['id']: g for g in build_app.GAMES if g['build'] == 'build_app.py'}
        self.assertEqual(set(mine), set(build_app.APPS))
        self.assertEqual({g['title_id']: i for i, g in mine.items()}, build_app.TITLES)
        for i, g in mine.items():
            self.assertEqual((g['name'], g['bundle_id'], g['data_folder']), build_app.APPS[i])

    def test_by3_agrees(self):
        g = by3.GAME
        self.assertEqual(g['title_id'], by3.EXPECTED['title_id'])
        self.assertIn(f"<string>{g['bundle_id']}</string>", (ROOT / 'games/by3/Makefile').read_text())
        self.assertIn(f"MacNativeGames/{g['data_folder']}", (ROOT / 'games/by3/app/launcher.m').read_text())


class HandOff(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()

    def hand_off(self, game):
        argv = [str(game), '-k', 'prod.keys', '--json-progress']
        with mock.patch.object(build_app.os, 'execve') as execve:
            build_app.hand_off(build_app.parse_args(argv), argv)
        return execve

    def test_by3_goes_to_its_script(self):
        execv = self.hand_off(nsp(self.tmp / 'b.nsp', by3.EXPECTED['title_id']))
        execv.assert_called_once()
        self.assertEqual(execv.call_args[0][1][1:], [str(ROOT / 'games/by3/build.py'), str(self.tmp / 'b.nsp'),
                                                    '-k', 'prod.keys', '--json-progress'])

    def test_its_update_too(self):
        # the update as the game file goes to the same script, which says what to pass instead
        self.hand_off(nsp(self.tmp / 'u.nsp', by3.EXPECTED['update_title_id'])).assert_called_once()

    def test_a_card_image_after_identification(self):
        # an XCI has no tickets: identify_game finds the title with the keys, and main hands it over without a second hello
        report = {'titles': [by3.EXPECTED['title_id']]}
        with mock.patch.object(build_app, 'run'), mock.patch.object(build_app, 'last_json', return_value=report):
            self.assertEqual(build_app.identify_game(self.tmp, self.tmp / 'g.xci', self.tmp / 'k', self.tmp), 'by3')
        with mock.patch.object(build_app.os, 'execve') as execve:
            build_app.hand_over('by3', ['g.xci'], hello_sent=True)
        self.assertEqual(execve.call_args[0][2]['MACNATIVEGAMES_HELLO_SENT'], '1')
        out = io.StringIO()
        with mock.patch.dict(by3.os.environ, MACNATIVEGAMES_HELLO_SENT='1'), contextlib.redirect_stdout(out), \
                mock.patch.object(by3, 'EVENTS', False), mock.patch.object(by3.signal, 'signal'), self.assertRaises(by3.BuildError):
            by3.main([str(self.tmp / 'missing.xci'), '-k', 'k', '--json-progress'])
        self.assertNotIn('"hello"', out.getvalue())
        self.assertNotIn('MACNATIVEGAMES_HELLO_SENT', by3.os.environ)   # not passed on to the tools

    def test_others_stay(self):
        self.hand_off(nsp(self.tmp / 't.nsp', '0100F2C0115B6000')).assert_not_called()
        self.hand_off(self.tmp / 'missing.nsp').assert_not_called()
        (self.tmp / 'junk.nsp').write_bytes(b'not a game')
        self.hand_off(self.tmp / 'junk.nsp').assert_not_called()   # main reports it after its event header


class By3Inspect(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        e = by3.EXPECTED
        self.keys = self.tmp / 'prod.keys'
        self.keys.write_text('')
        self.base = nsp(self.tmp / 'base.nsp', e['title_id'], (e['base_program_nca']['name'], e['base_program_nca']['size']))
        self.update = nsp(self.tmp / 'up.nsp', e['update_title_id'], (e['update_program_nca']['name'], e['update_program_nca']['size']))

    def test_base_only_needs_the_update(self):
        got, error = events([str(self.base), '-k', str(self.keys), '--inspect'])
        self.assertIsNone(error)
        self.assertEqual(got[0], {'type': 'hello', 'schema': build_app.EVENT_SCHEMA, 'time': got[0]['time']})
        inspect = got[-1]
        self.assertEqual((inspect['type'], inspect['game'], inspect['needs_update'], inspect['version']), ('inspect', 'by3', True, None))
        self.assertEqual((inspect['platforms'], inspect['dlc'], inspect['mod'], inspect['needs_fonts']), (['macos'], False, False, False))
        self.assertEqual(inspect['work'], str(self.tmp / 'BY3_build'))
        self.assertEqual(inspect['default_out'], str(self.tmp / 'Bayonetta 3.app'))

    def test_with_the_update(self):
        got, error = events([str(self.base), '--update', str(self.update), '-k', str(self.keys), '--inspect'])
        self.assertIsNone(error)
        self.assertEqual((got[-1]['version'], got[-1]['display_version'], got[-1]['needs_update']), ('v120', '1.2.0', False))

    def test_swapped(self):
        _, error = events([str(self.update), '--update', str(self.base), '-k', str(self.keys), '--inspect'])
        self.assertEqual(error.code, 'wrong_game')

    def test_another_update(self):
        other = nsp(self.tmp / 'other.nsp', by3.EXPECTED['update_title_id'], ('0' * 32 + '.nca', 5))
        _, error = events([str(self.base), '--update', str(other), '-k', str(self.keys), '--inspect'])
        self.assertEqual(error.code, 'unsupported_version')

    def test_refused_options(self):
        for extra, code in ((['--platform', 'ios'], 'platform'), (['--dlc', str(self.update)], 'input'),
                            (['--mod', str(self.tmp)], 'input'), ([], 'input')):   # [] : a build without the update
            _, error = events([str(self.base), '-k', str(self.keys)] + extra)
            self.assertEqual(error.code, code, extra)

    def test_build_info_never_names_the_keys(self):
        with mock.patch.object(by3, 'checkout_commit', return_value=(None, None)):
            info = by3.build_info(dict(game=self.base, update=self.update, firmware=None, shared_fonts=None), self.tmp / 'BY3_build')
        self.assertEqual((info['game'], info['version'], info['platform']), ('by3', 'v120', 'macos'))
        self.assertEqual(info['inputs'], {'game': str(self.base), 'update': str(self.update)})
        self.assertEqual(info['work'], str(self.tmp / 'BY3_build'))
        self.assertNotIn('keys', json.dumps(info))


class DreadBuild(unittest.TestCase):
    """games/dread/build.py: one card image or NSP of the base game 1.0.0, no update."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.keys = self.tmp / 'prod.keys'
        self.keys.write_text('')
        self.nsp = nsp(self.tmp / 'dread.nsp', dread.EXPECTED['title_id'])
        self.xci = self.tmp / 'dread.xci'
        self.xci.write_bytes(bytes(0x100) + b'HEAD' + bytes(0x100))

    def test_manifest_agrees(self):
        g = dread.GAME
        self.assertEqual(g['title_id'], dread.EXPECTED['title_id'])
        self.assertIn(f"<string>{g['bundle_id']}</string>", (ROOT / 'games/dread/Makefile').read_text())
        self.assertIn(f"MacNativeGames/{g['data_folder']}", (ROOT / 'games/dread/app/launcher.m').read_text())

    def test_build_app_hands_it_over(self):
        argv = [str(self.nsp), '-k', 'prod.keys', '--json-progress']
        with mock.patch.object(build_app.os, 'execve') as execve:
            build_app.hand_off(build_app.parse_args(argv), argv)
        self.assertEqual(execve.call_args[0][1][1], str(ROOT / 'games/dread/build.py'))
        report = {'titles': [dread.EXPECTED['title_id']]}   # a card image: identify_game reads the title with the keys
        with mock.patch.object(build_app, 'run'), mock.patch.object(build_app, 'last_json', return_value=report):
            self.assertEqual(build_app.identify_game(self.tmp, self.xci, self.keys, self.tmp), 'dread')

    def test_inspect(self):
        for game, kind in ((self.nsp, 'nsp'), (self.xci, 'xci')):
            got, error = events([str(game), '-k', str(self.keys), '--inspect'], dread)
            self.assertIsNone(error)
            i = got[-1]
            self.assertEqual((i['type'], i['game'], i['kind'], i['version'], i['display_version']), ('inspect', 'dread', kind, 'v100', '1.0.0'))
            self.assertEqual((i['needs_update'], i['needs_fonts'], i['platforms'], i['dlc'], i['mod']), (False, False, ['macos'], False, False))
            self.assertEqual((i['work'], i['default_out']), (str(self.tmp / 'Dread_build'), str(self.tmp / 'Metroid Dread.app')))

    def test_refused(self):
        update = nsp(self.tmp / 'up.nsp', '010093801237C800')
        dlc = nsp(self.tmp / 'dlc.nsp', '010093801237D001')
        other = nsp(self.tmp / 'other.nsp', '0100F2C0115B6000')
        junk = self.tmp / 'junk.xci'
        junk.write_bytes(b'not a game' * 100)
        for argv, code in (([str(update)], 'wrong_game'), ([str(dlc)], 'wrong_game'), ([str(other)], 'wrong_game'),
                           ([str(junk)], 'input'), ([str(self.nsp), '--update', str(update)], 'unsupported_version'),
                           ([str(self.nsp), '--dlc', str(dlc)], 'input'), ([str(self.nsp), '--mod', str(self.tmp)], 'input'),
                           ([str(self.nsp), '--platform', 'ios'], 'platform')):
            _, error = events(argv + ['-k', str(self.keys), '--inspect'], dread)
            self.assertEqual(error.code if error else None, code, argv)

    def test_build_info_never_names_the_keys(self):
        with mock.patch.object(dread, 'checkout_commit', return_value=(None, None)):
            info = dread.build_info(dict(game=self.xci, firmware=None, shared_fonts=None), self.tmp / 'Dread_build')
        self.assertEqual((info['game'], info['version'], info['display_version'], info['platform']), ('dread', 'v100', '1.0.0', 'macos'))
        self.assertEqual(info['inputs'], {'game': str(self.xci)})
        self.assertNotIn('keys', json.dumps(info))


class OdysseyBuild(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.keys = self.tmp / 'prod.keys'
        self.keys.write_text('')
        self.game = self.tmp / 'smo.nsp'
        entries = [(f'{t.lower()}0000000000000000.tik', ticket(t)) for t in (smo.BASE_TITLE, smo.UPDATE_TITLE)]
        strings, table, payload = b'', bytearray(), b''
        for name, data in entries:
            table += struct.pack('<QQII', len(payload), len(data), len(strings), 0)
            strings += name.encode() + b'\0'
            payload += data
        self.game.write_bytes(b'PFS0' + struct.pack('<III', len(entries), len(strings), 0) + bytes(table) + strings + payload)

    def test_manifest_agrees(self):
        self.assertEqual((smo.GAME['title_id'], smo.BASE_TITLE), ('0100000000010000', '0100000000010000'))
        self.assertIn(f'"CFBundleIdentifier": "{smo.GAME["bundle_id"]}"', (ROOT / 'games/odyssey/scripts/package_native_app.py').read_text())
        self.assertIn(smo.GAME['data_beside_app'], (ROOT / 'games/odyssey/scripts/odyssey_app_launcher.c').read_text())

    def test_build_app_hands_it_over(self):
        argv = [str(self.game), '-k', str(self.keys)]
        with mock.patch.object(build_app.os, 'execve') as execve:
            build_app.hand_off(build_app.parse_args(argv), argv)
        self.assertEqual(execve.call_args[0][1][1], str(ROOT / 'games/odyssey/build.py'))

    def test_inspect_an_nsp(self):
        got, error = events([str(self.game), '-k', str(self.keys), '--work', str(self.tmp / 'w'), '--inspect'], smo)
        self.assertIsNone(error)
        i = got[-1]
        self.assertEqual((i['game'], i['display_version'], i['needs_fonts'], i['platforms'], i['mod']), ('odyssey', '1.3.0', True, ['macos'], False))
        self.assertEqual(i['default_out'], str(self.tmp / 'w/Odyssey.app'))
        got, _ = events([str(self.game), '-k', str(self.keys), '--firmware', str(self.tmp), '--work', str(self.tmp / 'w'), '--inspect'], smo)
        self.assertFalse(got[-1]['needs_fonts'])
        self.assertFalse((self.tmp / 'w').exists())   # an NSP is read without the Python environment

    def test_refused(self):
        for extra, code in ((['--update', str(self.game)], 'input'), (['--platform', 'ios'], 'platform'),
                            (['--mod', str(self.tmp)], 'input'), ([], 'fonts')):   # []: an NSP build without fonts
            _, error = events([str(self.game), '-k', str(self.keys), '--work', str(self.tmp / 'w')] + extra, smo)
            self.assertEqual(error.code, code, extra)
        other = self.tmp / 'other.nsp'
        other.write_bytes(self.game.read_bytes().replace(bytes.fromhex(smo.BASE_TITLE), bytes(8)).replace(bytes.fromhex(smo.UPDATE_TITLE), bytes(8)))
        _, error = events([str(other), '-k', str(self.keys), '--work', str(self.tmp / 'w'), '--inspect'], smo)
        self.assertEqual(error.code, 'wrong_game')

    def test_place_replaces_only_its_own_app(self):
        app = self.tmp / 'w/Odyssey.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_text(smo.GAME['bundle_id'])
        (self.tmp / 'w' / smo.DATA).mkdir()
        foreign = self.tmp / 'Mine.app'
        (foreign / 'Contents').mkdir(parents=True)
        (foreign / 'Contents/Info.plist').write_text('com.example.other')
        with self.assertRaises(smo.BuildError):
            smo.place(app, foreign)
        self.assertTrue(foreign.exists() and app.exists())
        with mock.patch.object(smo, 'EVENTS', False), contextlib.redirect_stdout(io.StringIO()):
            smo.place(app, self.tmp / 'Games/Odyssey.app')
        self.assertTrue((self.tmp / 'Games/Odyssey.app/Contents/Info.plist').is_file() and not app.exists())
        self.assertTrue((self.tmp / 'Games' / smo.DATA).is_dir())   # the saves go with it

    def test_steps_report_through_the_caller(self):
        # build_odyssey.build takes the caller's step/run/note; its own main still prints as before
        import inspect as introspect
        self.assertEqual(list(introspect.signature(smo.build_odyssey.build).parameters), ['args', 'py', 'step', 'done', 'run', 'note'])
        self.assertNotIn('print(', introspect.getsource(smo.build_odyssey.build))
        self.assertEqual(set(smo.STAGES), set(range(1, 9)))


if __name__ == '__main__':
    unittest.main()
