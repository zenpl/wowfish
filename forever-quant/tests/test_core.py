import os
import tempfile
import unittest

from quant import backtest, collector, database, export_lua, risk, strategies
from quant.config import gold

S = dict(ah_cut=0.05, min_discount=0.20, min_roi=0.15, min_profit=5000, min_sold_per_day=2.0,
         max_market_drop=0.20, max_days_of_volume=0.25, max_snapshot_age_hours=6)
CFG = dict(capital=dict(total=1_000_000, reserve_pct=0.20, max_per_item=150_000, max_per_trade=80_000), strategy=S)


def q(**kw):
    base = dict(item_id=1, median=10000, min_buyout=6000, quantity=50, median7d=10000,
                median30d=10000, low=4000, high=20000, sold_per_day=40.0)
    base.update(kw)
    return base


class TestParse(unittest.TestCase):
    def test_pricetable(self):
        txt = "AHL1|forever/normal/horde/us|1794497262|2\n118:8:7:768:15:15:5:28:15965\n35:700:700:4:2017:2234:500:10000:53\nbad:row\n"
        market, t, rows = collector.parse_pricetable(txt)
        self.assertEqual(market, "forever.normal.horde.us")
        self.assertEqual(t, 1794497262)
        self.assertEqual(len(rows), 2)
        r = rows[0]
        self.assertEqual((r["item_id"], r["median"], r["min_buyout"], r["quantity"]), (118, 8, 7, 768))
        self.assertEqual((r["median7d"], r["median30d"]), (15, 15))
        self.assertAlmostEqual(r["sold_per_day"], 1596.5)

    def test_bad_header(self):
        with self.assertRaises(ValueError):
            collector.parse_pricetable("<html>nope</html>")


class TestFlip(unittest.TestCase):
    def test_basic(self):
        c = strategies.evaluate_flip(q(), S)
        self.assertEqual(c.target_price, 9700)
        self.assertEqual(c.unit_profit, int(9700 * 0.95) - 6000)
        self.assertAlmostEqual(c.discount, 0.4)

    def test_not_cheap_enough(self):
        self.assertIsNone(strategies.evaluate_flip(q(min_buyout=8500), S))

    def test_market_wide_drop_rejected(self):
        # 最低价看着比历史便宜很多，但整个市场的中位价也跌了：不是机会
        self.assertIsNone(strategies.evaluate_flip(q(median=7000, min_buyout=5000), S))

    def test_target_capped_by_current_median(self):
        c = strategies.evaluate_flip(q(median=9000, min_buyout=5000), S)
        self.assertEqual(c.target_price, int(9000 * 0.97))

    def test_illiquid_rejected(self):
        self.assertIsNone(strategies.evaluate_flip(q(sold_per_day=0.5), S))

    def test_missing_data(self):
        self.assertIsNone(strategies.evaluate_flip(q(min_buyout=0), S))
        self.assertIsNone(strategies.evaluate_flip(q(median7d=0, median30d=0), S))

    def test_uses_lower_reference(self):
        c = strategies.evaluate_flip(q(median7d=8000, median30d=12000, median=8000), S)
        self.assertAlmostEqual(c.discount, 0.25)

    def test_refine_uses_typical_min(self):
        c = strategies.evaluate_flip(q(), S)                    # 现最低 6000
        c2 = strategies.refine_with_series(c, dict(series=[dict(min=9000)] * 30), S)
        self.assertEqual(c2.target_price, int(9000 * 0.97))
        self.assertAlmostEqual(c2.discount, 1 - 6000 / 9000)

    def test_refine_rejects_normal_price(self):
        # 最低价平时就是 6000 左右：中位价再高也不是机会
        c = strategies.evaluate_flip(q(), S)
        self.assertIsNone(strategies.refine_with_series(c, dict(series=[dict(min=6100)] * 30), S))

    def test_refine_rejects_downtrend(self):
        # 7 天看着便宜，但最近一天最低价已经跌到现价附近
        c = strategies.evaluate_flip(q(), S)
        series = [dict(min=9000)] * 60 + [dict(min=6200)] * 24
        self.assertIsNone(strategies.refine_with_series(c, dict(series=series), S))

    def test_refine_needs_history(self):
        c = strategies.evaluate_flip(q(), S)
        self.assertIsNone(strategies.refine_with_series(c, dict(series=[dict(min=9000)] * 5), S))


class TestRisk(unittest.TestCase):
    def cand(self, item_id=1, price=6000, profit=3000, spd=40.0, strategy="FLIP"):
        return strategies.Candidate(item_id, strategy, price, 9700, profit, profit / price, 0.4, spd, 50.0)

    def test_caps(self):
        orders, left = risk.allocate([self.cand()], CFG)
        o = orders[0]
        self.assertEqual(o.quantity, 10)            # 日销 40 * 25% = 10，小于单笔上限 13
        self.assertEqual(left, 800_000 - 60_000)

    def test_trade_cap(self):
        orders, _ = risk.allocate([self.cand(spd=1000)], CFG)
        self.assertEqual(orders[0].quantity, 80_000 // 6000)

    def test_min_profit(self):
        orders, _ = risk.allocate([self.cand(price=100, profit=30, spd=8)], CFG)
        self.assertEqual(orders, [])                 # 2 件 * 30c 远不到 50s

    def test_holdings_reduce_room(self):
        orders, _ = risk.allocate([self.cand(spd=1000, profit=6000)], CFG, holdings={1: 140_000})
        self.assertEqual(orders[0].quantity, 1)      # 单品上限 15g，只剩 1g 空间

    def test_reserve_respected(self):
        cands = [self.cand(item_id=i, price=70_000, profit=20_000, spd=1000) for i in range(30)]
        orders, left = risk.allocate(cands, CFG)
        self.assertLessEqual(sum(o.cost for o in orders), 800_000)
        self.assertGreaterEqual(left, 0)

    def test_too_expensive(self):
        orders, _ = risk.allocate([self.cand(price=90_000, profit=30_000)], CFG)
        self.assertEqual(orders, [])


class TestPipeline(unittest.TestCase):
    def test_collect_dedup_export_review(self):
        with tempfile.TemporaryDirectory() as d:
            db = database.connect(os.path.join(d, "t.sqlite"))
            cfg = dict(CFG, market=dict(id="forever.normal.horde.us"),
                       api=dict(base="x", user_agent="t", min_interval_minutes=30, detail_top_n=5))
            bodies = iter([
                "AHL1|forever/normal/horde/us|1000|1\n1:10000:6000:50:10000:10000:4000:20000:400\n",
                "AHL1|forever/normal/horde/us|1000|1\n1:10000:6000:50:10000:10000:4000:20000:400\n",
                "AHL1|forever/normal/horde/us|5000|1\n1:10000:9900:50:10000:10000:4000:20000:400\n",
            ])
            collector._get = lambda cfg, path, etag=None: (200, next(bodies), "e")
            sid, _ = collector.collect(cfg, db, now=2000)
            self.assertEqual(collector.collect(cfg, db, now=2100)[0], sid)          # 间隔不足，跳过
            self.assertEqual(collector.collect(cfg, db, now=9000)[0], sid)          # 同一份扫描，不重复入库
            rows = db.execute("SELECT * FROM quotes WHERE snapshot_id=?", (sid,)).fetchall()
            orders, _ = risk.allocate(strategies.scan_flips(rows, S), cfg)
            self.assertEqual(len(orders), 1)
            o = orders[0]
            db.execute("INSERT INTO signals(snapshot_id,item_id,generated_at,strategy,buy_price,target_price,"
                       "max_quantity,expected_profit,score) VALUES(?,?,?,?,?,?,?,?,?)",
                       (sid, 1, 2000, "FLIP", o.cand.buy_price, o.cand.target_price, o.quantity, o.expected_profit, 1))
            sid2, _ = collector.collect(cfg, db, now=20000)
            self.assertNotEqual(sid2, sid)
            r = backtest.review(db, "forever.normal.horde.us", 0.05)
            self.assertEqual((r["total"], r["hit"]), (1, 1))
            p = export_lua.export(orders, {1: 'Odd "Name"'}, "m", 1, 1, path=os.path.join(d, "r.lua"))
            txt = open(p, encoding="utf-8").read()
            self.assertIn('name = "Odd \\"Name\\""', txt)
            self.assertIn("max_unit_price = 6000", txt)
            db.close()


class TestGold(unittest.TestCase):
    def test_fmt(self):
        self.assertEqual(gold(1_000_000), "100g 0s 0c")
        self.assertEqual(gold(5025), "50s 25c")
        self.assertEqual(gold(7), "7c")
        self.assertEqual(gold(-150), "-1s 50c")


if __name__ == "__main__":
    unittest.main()
