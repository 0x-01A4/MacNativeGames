"""games/<name>/game.json, which the Builder reads to know the games; build_app.py's hand-off to a game's own build
script (games/by3/build.py); and that script's --inspect and argument checks. Synthetic PFS0 files only; no game data
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

spec = importlib.util.spec_from_file_location('by3_build', ROOT / 'games/by3/build.py')
by3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(by3)

FIELDS = {'schema', 'id', 'name', 'title_id', 'bundle_id', 'data_folder', 'build', 'sources'}


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


def events(argv):
    """by3.main's JSON events and its BuildError (or None)."""
    out, error = io.StringIO(), None
    with contextlib.redirect_stdout(out), mock.patch.object(by3, 'EVENTS', False), \
            mock.patch.object(by3.signal, 'signal'):
        try:
            by3.main(argv + ['--json-progress'])
        except by3.BuildError as e:
            error = e
    return [json.loads(line) for line in out.getvalue().splitlines() if line.startswith('{')], error


class Manifests(unittest.TestCase):
    def test_every_game_folder(self):
        self.assertEqual({g['id'] for g in build_app.GAMES}, {'totk', 'botw', 'by3'})
        for g in build_app.GAMES:
            self.assertLessEqual(FIELDS, set(g), g['id'])
            self.assertEqual(g['schema'], 1)
            self.assertTrue((ROOT / 'games' / g['id'] / 'game.json').is_file())
            self.assertTrue((ROOT / g['build']).is_file(), g['build'])
            for source in g['sources']:
                self.assertTrue((ROOT / source).exists(), source)
            self.assertRegex(g['title_id'], r'^[0-9A-F]{13}000$')
            for ext in g.get('files', {}).get('game', []) + g.get('files', {}).get('update', []):
                self.assertIn(ext, ('xci', 'nsp', 'nsz'))
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
            info = by3.build_info(dict(game=self.base, update=self.update, firmware=None, shared_fonts=None))
        self.assertEqual((info['game'], info['version'], info['platform']), ('by3', 'v120', 'macos'))
        self.assertEqual(info['inputs'], {'game': str(self.base), 'update': str(self.update)})
        self.assertNotIn('keys', json.dumps(info))


if __name__ == '__main__':
    unittest.main()
