"""信号复盘（代理指标，不是真实成交）。

对每条历史 FLIP 信号，看之后 72 小时内的快照：如果某次快照的挂单中位价 >= 我们的目标价，
就认为"按目标价挂单大概率能卖掉"。这只是粗略代理：真实结果以 trades 表里的实际成交为准。
"""
HORIZON = 72 * 3600


def review(db, market, cut):
    rows = db.execute(
        "SELECT s.*, sn.captured_at AS t0 FROM signals s JOIN snapshots sn ON sn.id=s.snapshot_id "
        "WHERE sn.market=? AND s.strategy='FLIP' ORDER BY sn.captured_at", (market,)).fetchall()
    last = db.execute("SELECT MAX(captured_at) m FROM snapshots WHERE market=?", (market,)).fetchone()["m"]
    res = dict(total=0, pending=0, hit=0, miss=0, pnl=0, seen=set())
    for r in rows:
        key = (r["item_id"], r["t0"] // 86400)      # 同一物品同一天只算一次
        if key in res["seen"]:
            continue
        res["seen"].add(key)
        res["total"] += 1
        later = db.execute(
            "SELECT q.median, q.min_buyout, sn.captured_at FROM quotes q JOIN snapshots sn ON sn.id=q.snapshot_id "
            "WHERE sn.market=? AND q.item_id=? AND sn.captured_at>? AND sn.captured_at<=? ORDER BY sn.captured_at",
            (market, r["item_id"], r["t0"], r["t0"] + HORIZON)).fetchall()
        if any(x["median"] and x["median"] >= r["target_price"] for x in later):
            res["hit"] += 1
            res["pnl"] += (int(r["target_price"] * (1 - cut)) - r["buy_price"]) * r["max_quantity"]
        elif last - r["t0"] < HORIZON:
            res["pending"] += 1
        else:
            res["miss"] += 1
            exit_px = later[-1]["min_buyout"] if later and later[-1]["min_buyout"] else 0
            res["pnl"] += (int(exit_px * (1 - cut)) - r["buy_price"]) * r["max_quantity"]
    del res["seen"]
    return res
