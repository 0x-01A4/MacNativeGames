"""make_button_icons.py: the button guide textures (block-linear addressing, outline rasterizer), without game data."""
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'games/totk/scripts'))
READY = all(importlib.util.find_spec(m) is not None for m in ('compression.zstd', 'fontTools'))


@unittest.skipUnless(READY, 'needs Python 3.14 and fontTools')
class ButtonGuideTextures(unittest.TestCase):
    def setUp(self):
        import make_button_icons
        self.icons = make_button_icons

    def test_block_linear_covers_the_surface_once(self):
        # 72x72 R8 with 8-GOB blocks, as the game stores Nt_KeyTex*: 2 GOBs wide, 2 blocks high = 16384 bytes
        offsets = {self.icons.gob_offset(x, y, 2, 8) for y in range(72) for x in range(72)}
        self.assertEqual(len(offsets), 72 * 72)
        self.assertTrue(all(0 <= o < 16384 for o in offsets))
        self.assertEqual(self.icons.gob_offset(0, 0, 2, 8), 0)
        self.assertEqual(self.icons.gob_offset(64, 0, 2, 8), 512 * 8)   # the next GOB column starts a block later

    def test_square_with_a_hole(self):
        def draw(pen):   # a square and, reversed, a smaller square inside: nonzero winding leaves it empty
            self.icons.polygon(pen, [(0, 0), (100, 0), (100, 100), (0, 100)])
            self.icons.polygon(pen, [(25, 25), (25, 75), (75, 75), (75, 25)])
        mask = self.icons.rasterize(draw, 72)
        at = lambda x, y: mask[y * 72 + x]
        self.assertEqual(at(6, 6), 255)      # inside the square, past the margin
        self.assertEqual(at(36, 36), 0)      # inside the hole
        self.assertEqual(at(1, 1), 0)        # the margin stays empty
        self.assertEqual(at(6, 65), 255)     # rows run top down: the bottom-left corner is filled too


if __name__ == '__main__':
    unittest.main()
