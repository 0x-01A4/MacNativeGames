"""build_app.build_info: the record an app keeps of what it was built from (Contents/Resources/build-info.json), which the
Builder's library reads. No game data and no keys.
"""
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

    def test_never_names_the_keys(self):
        # main() passes only these inputs; a keys argument would be a mistake in a later change
        source = (ROOT / 'build_app.py').read_text()
        for call in source.split('build_info(')[2:]:   # the two calls in main, after the definition
            self.assertNotIn('keys', call.split(')))')[0])

    def test_checkout_commit(self):
        commit, dirty = build_app.checkout_commit()
        if (ROOT / '.git').exists():
            self.assertRegex(commit, r'^[0-9a-f]{40}$')
            self.assertIn(dirty, (True, False))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(build_app, 'REPO', Path(tmp)):
            self.assertEqual(build_app.checkout_commit(), (None, None))


if __name__ == '__main__':
    unittest.main()
