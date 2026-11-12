import os
import tempfile
import unittest

from quant import database, disenchant as de, export_lua, watch

CFG = dict(strategy=dict(ah_cut=0.05, min_roi=0.15, min_unit_profit=100))
MATS = {de.STRANGE: dict(name="Strange Dust", price=86, sold_per_day=12798),
        de.L_ASTRAL: dict(name="Lesser Astral Essence", price=450, sold_per_day=557),
        de.S_GLIMMER: dict(name="Small Glimmering Shard", price=310, sold_per_day=532)}
ROW = dict(item_id=11288, name="强效魔法杖", buyout=215, count=584, class_id=2, level=23)


def detail(median=300, p25=260, spd=649):
    return dict(item=dict(name="Greater Magic Wand"), latest=dict(minBuyout=220, median=median, quantity=649),
                sales=dict(estimatedPerDay=spd), series=[dict(p25=p25, min=220, median=median)] * 8)


class TestWatch(unittest.TestCase):
    def test_wand_numbers(self):
        w = watch.evaluate(CFG, None, 11288, ROW, detail=detail(), mats=MATS)
        self.assertEqual(w["ev"], 552)                       # (0.15*5*86 + 1.125*450 + 0.1*310)，每种材料先让 3%、扣 5% 并取整
        self.assertEqual((w["min_price"], w["wall_price"], w["p25_price"]), (215, 300, 260))
        self.assertEqual((w["profit_min"], w["profit_wall"]), (552 - 215, 552 - 300))
        self.assertEqual((w["main_id"], w["verdict"]), (de.L_ASTRAL, "可以做"))
        self.assertEqual(w["breakeven_wall"], 204)           # 和之前手算的"精华至少 204c"一致
        self.assertEqual(w["daily_cap"], int(557 * 0.2 / 1.125))

    def test_verdicts(self):
        w = watch.evaluate(CFG, None, 11288, ROW, detail=detail(median=600), mats=MATS)
        self.assertEqual(w["verdict"], "可以做")              # 别人挂得再贵也无所谓，只看现在能买到的价
        w = watch.evaluate(CFG, None, 11288, dict(ROW, buyout=500), detail=detail(median=600), mats=MATS)
        self.assertEqual(w["verdict"], "利润太薄")            # 赚 52c，不到 15%
        w = watch.evaluate(CFG, None, 11288, dict(ROW, buyout=900), detail=detail(median=900), mats=MATS)
        self.assertEqual(w["verdict"], "停")
        thin = dict(MATS); thin[de.L_ASTRAL] = dict(name="Lesser Astral Essence", price=450, sold_per_day=10)
        self.assertEqual(watch.evaluate(CFG, None, 11288, ROW, detail=detail(), mats=thin)["verdict"], "停")

    def test_refuses_non_disenchantable(self):
        cfg = dict(CFG, disenchant=dict(not_disenchantable=[11288]))
        with self.assertRaises(ValueError):
            watch.evaluate(cfg, None, 11288, ROW, detail=detail(), mats=MATS)

    def test_needs_scan_row(self):
        with self.assertRaises(ValueError):
            watch.evaluate(CFG, None, 11288, None, detail=detail(), mats=MATS)

    def test_history_trend_and_lua_patch(self):
        with tempfile.TemporaryDirectory() as d:
            db = database.connect(os.path.join(d, "t.sqlite"))
            w = watch.evaluate(CFG, None, 11288, ROW, detail=detail(), mats=MATS)
            import time
            watch.record(db, dict(w, min_price=430, quantity=1168), now=time.time() - 7200)
            tr = watch.trend(watch.history(db, 11288), w)
            self.assertAlmostEqual(tr["min_price"], -50.0)
            self.assertAlmostEqual(tr["quantity"], -50.0)
            self.assertAlmostEqual(tr["hours"], 2.0, places=1)
            p = os.path.join(d, "r.lua")
            export_lua.export([], {}, "m", 1, 1, path=p, watch=[w])
            txt = open(p, encoding="utf-8").read()
            self.assertIn("item_id = 11288", txt)
            self.assertEqual(txt.count("WATCH-BEGIN"), 1)
            export_lua.patch_watch([dict(w, min_price=199)], 0.05, path=p)
            txt = open(p, encoding="utf-8").read()
            self.assertIn("min_price = 199", txt)
            self.assertNotIn("min_price = 215", txt)
            self.assertEqual(txt.count("WATCH-BEGIN"), 1)
            self.assertTrue(txt.rstrip().endswith("}"))
            db.close()


if __name__ == "__main__":
    unittest.main()
