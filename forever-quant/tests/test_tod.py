import unittest
from datetime import datetime, timedelta, timezone

from quant import tod


def series(days, price_at, step=2):
    t0 = datetime(2026, 11, 1, tzinfo=timezone.utc)
    return [dict(t=(t0 + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%S.000Z"), min=price_at(h), quantity=1000)
            for h in range(0, days * 24, step)]


class TodTest(unittest.TestCase):
    def test_finds_cheap_and_dear_hours(self):
        import time
        # 本地时间 3-5 点便宜一半，18-20 点贵一半，其余平价；同时整周缓慢上涨（应该被去掉）
        def price(h):
            lt = time.localtime(datetime(2026, 11, 1, tzinfo=timezone.utc).timestamp() + h * 3600)
            lh = lt.tm_hour
            base = 100 + lt.tm_yday * 20          # 按本地日期逐日上涨
            return int(base * (0.5 if 3 <= lh < 6 else 1.5 if 18 <= lh < 21 else 1.0))
        p = tod.profile(series(7, price, step=1))
        self.assertEqual((p["low_hour"], p["high_hour"]), (4, 19))
        self.assertAlmostEqual(p["spread"], 2.0, delta=0.1)

    def test_flat_price_has_no_spread(self):
        p = tod.profile(series(7, lambda h: 100))
        self.assertAlmostEqual(p["spread"], 0.0)

    def test_too_little_data(self):
        self.assertIsNone(tod.profile(series(2, lambda h: 100)))
        self.assertIsNone(tod.profile([]))


if __name__ == "__main__":
    unittest.main()
