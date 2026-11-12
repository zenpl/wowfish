"""一天里各时段的价格规律（大宗货）。

行情源给每个物品 7 天的小时级序列（最低价、挂单量）。做法：
  1. 每个点的最低价除以当天的中位最低价 —— 去掉这一周整体涨跌，只留"一天之内"的起伏；
  2. 按本地时间分成 8 个 3 小时段，取每段的中位比值；
  3. 最便宜/最贵的段、两者相差多少。每段至少要有 3 个点、来自 3 个不同的日子才算数。
只有一周数据，样本很少，结果只能当参考。
"""
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path

from . import collector

BUCKET = 3                      # 每段几小时
MIN_POINTS, MIN_DAYS = 3, 3
MIN_PRICE, MIN_SPREAD = 20, 0.05     # 铜；高低相差
CACHE = Path(__file__).resolve().parent.parent / "data" / "tod_cache.json"


def profile(series, now=None):
    """series: [{t: ISO时间, min: 铜, quantity: 挂单量}] -> 规律；数据不够返回 None。"""
    pts = []
    for p in series or []:
        if not p.get("min") or p["min"] <= 0:
            continue
        ts = datetime.strptime(p["t"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
        lt = time.localtime(ts)
        pts.append((time.strftime("%Y-%m-%d", lt), lt.tm_hour // BUCKET, p["min"], p.get("quantity") or 0))
    if not pts:
        return None
    day_mid = {}
    for day in {p[0] for p in pts}:
        day_mid[day] = statistics.median(p[2] for p in pts if p[0] == day)
    buckets = {}
    for day, b, price, qty in pts:
        buckets.setdefault(b, []).append((day, price / day_mid[day], qty))
    good = {b: v for b, v in buckets.items()
            if len(v) >= MIN_POINTS and len({d for d, _, _ in v}) >= MIN_DAYS}
    if len(good) < 4:                                   # 一天里有一半以上的时段没数据，谈不上规律
        return None
    ratio = {b: statistics.median(r for _, r, _ in v) for b, v in good.items()}
    lo, hi = min(ratio, key=ratio.get), max(ratio, key=ratio.get)
    qty = {b: statistics.median(q for _, _, q in v) for b, v in good.items()}
    center = lambda b: (b * BUCKET + BUCKET // 2) % 24
    return dict(low_hour=center(lo), high_hour=center(hi), spread=ratio[hi] / ratio[lo] - 1,
                typical=int(statistics.median(p[2] for p in pts)), points=len(pts),
                thin_hour=center(min(qty, key=qty.get)), hours=len({(p[0], p[1]) for p in pts}) * BUCKET)


def pick_items(db, snapshot_id, limit):
    """卖得最快的那批货（按估计日销）。"""
    return [(r["item_id"], r["sold_per_day"]) for r in db.execute(
        "SELECT item_id, sold_per_day FROM quotes WHERE snapshot_id=? AND min_buyout>0 "
        "ORDER BY sold_per_day DESC LIMIT ?", (snapshot_id, limit))]


def build(cfg, db, snapshot_id, limit=40, max_age_hours=6, fetch=None, now=None):
    pause = 0.2 if fetch is None else 0
    """返回 {hours, market_note, items}。结果缓存 max_age_hours，免得每次分析都拉 40 个物品明细。"""
    now = now or time.time()
    if fetch is None and CACHE.exists():
        try:
            c = json.loads(CACHE.read_text(encoding="utf-8"))
            if now - c.get("at", 0) < max_age_hours * 3600 and c.get("market") == cfg["market"]["id"]:
                return c["tod"]
        except (ValueError, KeyError):
            pass
    fetch = fetch or (lambda iid: collector.fetch_detail(cfg, db, iid))
    items, hours = [], 0
    for iid, spd in pick_items(db, snapshot_id, limit):
        try:
            d = fetch(iid)
        except Exception:
            continue
        pr = profile(d.get("series"))
        if not pr:
            continue
        hours = max(hours, pr.pop("hours"))
        items.append(dict(pr, item_id=iid, name=(d.get("item") or {}).get("name") or str(iid), sold_per_day=spd))
        time.sleep(pause)
    # 单价几铜的东西（弹药、碎皮）一铜之差就是百分之几十，没有意义；波动不到 5% 的也不列
    items = [r for r in items if r["typical"] >= MIN_PRICE and r["spread"] >= MIN_SPREAD]
    items.sort(key=lambda r: -r["spread"])
    note = ""
    if items:
        mode = lambda k: statistics.mode(r[k] for r in items)
        note = f"多数货在 {mode('low_hour'):02d} 点前后最便宜、{mode('high_hour'):02d} 点前后最贵"
    tod = dict(hours=hours, market_note=note, items=items)
    if items:
        CACHE.write_text(json.dumps(dict(at=now, market=cfg["market"]["id"], tod=tod), ensure_ascii=False), encoding="utf-8")
    return tod
