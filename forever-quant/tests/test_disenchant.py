import unittest

from quant import disenchant as de

S = dict(ah_cut=0.05, min_roi=0.15, min_unit_profit=100)
MATS = {de.SOUL: dict(name="Soul Dust", price=579, sold_per_day=2496),
        de.G_ASTRAL: dict(name="Greater Astral Essence", price=1510, sold_per_day=408),
        de.L_GLIMMER: dict(name="Large Glimmering Shard", price=2700, sold_per_day=0.5),   # 卖不动
        de.STRANGE: dict(name="Strange Dust", price=86, sold_per_day=12798),
        de.L_MAGIC: dict(name="Lesser Magic Essence", price=153, sold_per_day=3405)}


def row(item, ilvl, price, cls=4, suffix=0, name="X", count=1):
    return dict(item_id=item, level=ilvl, buyout=price, class_id=cls, suffix_id=suffix, name=name, count=count)


class TestDisenchant(unittest.TestCase):
    def test_yields_match_verified_brackets(self):
        # 和 AHledger 逐件产出核对过的档位
        self.assertEqual(de.yields(4, 28), [(de.SOUL, 0.75, 1.5), (de.G_ASTRAL, 0.20, 1.5), (de.L_GLIMMER, 0.05, 1.0)])
        self.assertEqual(de.yields(4, 43), [(de.VISION, 0.75, 3.5), (de.L_NETHER, 0.20, 1.5), (de.S_RADIANT, 0.05, 1.0)])
        self.assertEqual(de.yields(2, 23), [(de.STRANGE, 0.15, 5.0), (de.L_ASTRAL, 0.75, 1.5), (de.S_GLIMMER, 0.10, 1.0)])
        self.assertEqual(de.yields(2, 48)[1], (de.G_NETHER, 0.75, 1.5))

    def test_out_of_table(self):
        self.assertIsNone(de.yields(4, 3))
        self.assertIsNone(de.yields(9, 30))        # 不是武器护甲

    def test_expected_ignores_illiquid(self):
        net, main, dead = de.expected(de.yields(4, 28), MATS, S)
        want = 0.75 * 1.5 * int(int(579 * 0.97) * 0.95) + 0.20 * 1.5 * int(int(1510 * 0.97) * 0.95)
        self.assertEqual(net, int(want))
        self.assertEqual((main, dead), ("Soul Dust", ["Large Glimmering Shard"]))

    def test_scan_picks_cheapest_suffix_and_filters(self):
        net = de.expected(de.yields(4, 28), MATS, S)[0]
        rows = [row(1, 28, 5000, suffix=7, name="贵的后缀"), row(1, 28, 300, suffix=8, name="便宜的后缀", count=3),
                row(2, 28, net - 10, name="几乎没利润"), row(3, 3, 1, name="等级太低"), row(4, 28, net * 10, name="太贵")]
        ops, table, stats = de.scan(rows, MATS, S)
        self.assertEqual([(o["item_id"], o["name"], o["quantity"]) for o in ops], [(1, "便宜的后缀", 3)])
        self.assertEqual(ops[0]["profit"], net - 300)
        self.assertEqual(stats[("护甲", "26-30")], (1, 3))
        self.assertEqual(table[("护甲", "26-30")][0], net)


    def test_excluded_and_verified(self):
        rows = [row(1, 28, 300, name="能分解"), row(2, 28, 300, name="不能分解的")]
        ops, _, stats = de.scan(rows, MATS, S, excluded=[2], verified=[1])
        self.assertEqual([(o["item_id"], o["verified"]) for o in ops], [(1, True)])
        self.assertEqual(stats[("护甲", "26-30")], (1, 1))      # 被排除的不计入在售统计
        ops, _, _ = de.scan(rows, MATS, S)
        self.assertEqual([o["verified"] for o in ops], [False, False])


if __name__ == "__main__":
    unittest.main()
