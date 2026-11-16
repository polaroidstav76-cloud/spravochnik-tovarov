import unittest
from dtf_layout import Print,arrange,pixels
from core import UserError

class TestDTFLayout(unittest.TestCase):
    def assert_geometry(self,layout,items):
        self.assertEqual({p.key for p in layout.prints},{p.key for p in items})
        by_key={p.key:p for p in items}
        self.assertGreaterEqual(layout.gap,pixels(.5));self.assertLessEqual(layout.gap,pixels(2))
        for p in layout.prints:
            item=by_key[p.key]
            self.assertEqual((p.width,p.height),(item.height,item.width) if p.rotated else (item.width,item.height))
            self.assertGreaterEqual(p.x,layout.margin);self.assertGreaterEqual(p.y,layout.margin)
            self.assertLessEqual(p.x+p.width,layout.width-layout.margin)
            self.assertLessEqual(p.y+p.height,layout.height-layout.margin)
        for i,a in enumerate(layout.prints):
            for b in layout.prints[i+1:]:
                self.assertTrue(a.x+a.width+layout.gap<=b.x or b.x+b.width+layout.gap<=a.x or a.y+a.height+layout.gap<=b.y or b.y+b.height+layout.gap<=a.y)
    def test_fixed_width_and_all_copies_without_distortion(self):
        items=[Print(str(i),pixels(8),pixels(12)) for i in range(12)]
        for width in (55,56):
            layout=arrange(items,width)
            self.assertEqual(layout.width,pixels(width));self.assertEqual(layout.height,pixels(50))
            self.assert_geometry(layout,items)
    def test_extends_height_and_preserves_margins(self):
        items=[Print(str(i),pixels(50),pixels(45)) for i in range(5)]
        layout=arrange(items,56)
        self.assertGreater(layout.height,pixels(50));self.assertEqual(layout.width,pixels(56))
        self.assert_geometry(layout,items)
    def test_rejects_artwork_wider_than_sheet_in_both_orientations(self):
        with self.assertRaises(UserError):arrange([Print('too-large',pixels(60),pixels(70))],55)
    def test_can_rotate_without_resizing(self):
        items=[Print('landscape',pixels(70),pixels(20))]
        layout=arrange(items,56)
        self.assertTrue(layout.prints[0].rotated);self.assert_geometry(layout,items)

if __name__=='__main__':unittest.main()
