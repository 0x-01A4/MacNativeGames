"""build_app.build_info: the record an app keeps of what it was built from (Contents/Resources/build-info.json), which the
Builder's library reads. No game data and no keys.
"""
import ast
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT)]
import build_app


class BuildInfo(unittest.TestCase):
    def test_fields_and_inputs(self):
        with mock.patch.object(build_app, 'checkout_commit', return_value=('a' * 40, False)):
            info = build_app.build_info('totk', 'v143', 'macos', inputs=dict(
                game=Path('/Games/totk.nsp'), update=Path('/Games/1.4.3.nsz'), firmware=None, shared_fonts=Path('/F'),
                mod=None, install_mod_romfs=False, dlc=[]))
        self.assertEqual(info['schema'], build_app.BUILD_INFO_SCHEMA)
        self.assertEqual((info['game'], info['app_name'], info['version'], info['display_version'], info['platform']),
                         ('totk', 'Tears of the Kingdom', 'v143', '1.4.3', 'macos'))
        self.assertEqual((info['commit'], info['dirty']), ('a' * 40, False))
        self.assertRegex(info['built'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        # what was not given is left out, paths are strings
        self.assertEqual(info['inputs'], {'game': '/Games/totk.nsp', 'update': '/Games/1.4.3.nsz', 'shared_fonts': '/F'})

    def test_dlc_list(self):
        with mock.patch.object(build_app, 'checkout_commit', return_value=(None, None)):
            info = build_app.build_info('botw', 'botw190', 'macos', inputs=dict(game=Path('/b.nsp'), dlc=[Path('/d1.nsp'), Path('/d2.nsp')]))
        self.assertEqual(info['inputs']['dlc'], ['/d1.nsp', '/d2.nsp'])
        self.assertIsNone(info['commit'])
        self.assertNotIn('work', info)   # given only when the build knows it
        with mock.patch.object(build_app, 'checkout_commit', return_value=(None, None)):
            info = build_app.build_info('botw', 'botw190', 'macos', work=Path('/g/BotW_build'), inputs=dict(game=Path('/b.nsp')))
        self.assertEqual(info['work'], '/g/BotW_build')

    def test_never_names_the_keys(self):
        # main() passes only these inputs; a keys argument would be a mistake in a later change
        source = (ROOT / 'build_app.py').read_text()
        for call in source.split('build_info(')[2:]:   # the two calls in main, after the definition
            self.assertNotIn('keys', call.split(')))')[0])

    def test_step_app_writes_the_record_it_is_given(self):
        # step_app once reused `info` for the Info.plist dict, so every app's build-info.json held its plist instead
        tree = ast.parse((ROOT / 'build_app.py').read_text())
        step_app = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'step_app')
        rebound = [n.lineno for n in ast.walk(step_app) if isinstance(n, ast.Name) and n.id == 'info'
                   and isinstance(n.ctx, (ast.Store, ast.Del))]
        self.assertEqual(rebound, [], 'step_app must not rebind its info parameter')

    def test_checkout_commit(self):
        commit, dirty = build_app.checkout_commit()
        if (ROOT / '.git').exists():
            self.assertRegex(commit, r'^[0-9a-f]{40}$')
            self.assertIn(dirty, (True, False))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(build_app, 'REPO', Path(tmp)):
            self.assertEqual(build_app.checkout_commit(), (None, None))


if __name__ == '__main__':
    unittest.main()
