"""固定监控项：批量货源的"买来分解"是否还值得做。

每次运行记录一条快照（价格、在售量、材料价），所以能看到趋势。
"""
import time
from statistics import median

from . import collector, disenchant, strategies

SCHEMA = """
CREATE TABLE IF NOT EXISTS watch_log (
    t INTEGER NOT NULL, item_id INTEGER NOT NULL, min_price INTEGER, wall_price INTEGER, quantity INTEGER,
    ev INTEGER, main_mat INTEGER, main_price INTEGER, source TEXT,
    PRIMARY KEY (t, item_id)
);
"""


def sell_net(price, s):
    return strategies.net_after_cut(int(price * 0.97), s["ah_cut"])


def breakeven_main_price(ys, mats, main_id, cost, s):
    """主要材料跌到多少还能保本（其余材料价格不变）。"""
    k = 0.97 * (1 - s["ah_cut"])
    other = sum(ch * q * mats[m]["price"] for m, ch, q in ys if m != main_id and mats.get(m, {}).get("price"))
    coef = sum(ch * q for m, ch, q in ys if m == main_id)
    return max(0, int((cost / k - other) / coef)) if coef else None


def verdict(profit_min, roi_min, main_spd, s):
    """只看现在能买到的价格（当前最低价）。没人会按"大多数人挂的价"去买，所以不拿它下结论。"""
    if main_spd < 50:
        return "停", "主要材料一天卖不到 50 个，分出来也难出手"
    if profit_min > 0 and roi_min >= s["min_roi"]:
        return "可以做", "按现在的最低价买，利润够"
    if profit_min > 0:
        return "利润太薄", "按现在的最低价买有得赚，但不到要求的利润率，价格再涨一点就没了"
    return "停", "现在的最低价已经高于分解期望"


def vendor_floor(db, item_id):
    """这件物品卖给商人的价格（来自游戏内扫描；只有拍卖价接近商人价时才有记录）。没有返回 None。"""
    try:
        r = db.execute("SELECT vendor_price FROM vendor_hits WHERE item_id=? ORDER BY scan_id DESC LIMIT 1", (item_id,)).fetchone()
    except Exception:
        return None
    return r["vendor_price"] if r else None


def evaluate(cfg, db, item_id, scan_row=None, detail=None, mats=None):
    """算一个监控项。scan_row: 游戏内扫描里这件物品的行（可无）；detail/mats 可注入，便于测试。"""
    s = cfg["strategy"]
    if item_id in ((cfg.get("disenchant") or {}).get("not_disenchantable") or []):
        raise ValueError(f"物品 {item_id} 在「不能分解」名单里，不能作为分解监控项")
    detail = detail if detail is not None else collector.fetch_detail(cfg, db, item_id)
    mats = mats if mats is not None else collector.fetch_materials(cfg)[0]
    latest = detail.get("latest") or {}
    series = detail.get("series") or []
    # 价格：优先游戏内扫描（更新鲜），没有就用行情源
    if scan_row:
        min_price, quantity, source = scan_row["buyout"], scan_row["count"], "游戏内扫描"
        class_id, level = scan_row["class_id"], scan_row["level"]
    else:
        min_price, quantity, source = latest.get("minBuyout") or 0, latest.get("quantity") or 0, "行情源"
        class_id, level = None, None
    if class_id is None:
        raise ValueError(f"物品 {item_id} 不在最近的游戏内扫描里，不知道它的类型和物品等级，先 /fq scan 一次")
    ys = disenchant.yields(class_id, level)
    if not ys:
        raise ValueError(f"物品 {item_id}（等级 {level}）不在分解表里")
    wall = latest.get("median") or min_price              # 大多数挂单的价位
    p25 = median([x["p25"] for x in series[-6:] if x.get("p25")] or [wall])
    ev, main_name, dead = disenchant.expected(ys, mats, s)
    main_id = max(ys, key=lambda y: y[1] * y[2] * (mats.get(y[0], {}).get("price") or 0))[0]
    main = mats.get(main_id, {})
    profit_min, profit_wall = ev - min_price, ev - wall
    v, why = verdict(profit_min, profit_min / min_price if min_price else 0, main.get("sold_per_day") or 0, s)
    out = dict(
        item_id=item_id, name=(scan_row or {}).get("name") or (detail.get("item") or {}).get("name") or f"item:{item_id}",
        class_id=class_id, level=level, source=source, min_price=min_price, p25_price=int(p25), wall_price=wall,
        quantity=quantity, sold_per_day=(detail.get("sales") or {}).get("estimatedPerDay"), ev=ev,
        profit_min=profit_min, profit_wall=profit_wall, main_id=main_id, main_name=main.get("name", main_name),
        main_price=main.get("price") or 0, main_spd=main.get("sold_per_day") or 0,
        breakeven_min=breakeven_main_price(ys, mats, main_id, min_price, s),
        breakeven_wall=breakeven_main_price(ys, mats, main_id, wall, s),
        verdict=v, why=why, dead=dead, vendor_price=vendor_floor(db, item_id) if db is not None else None,
        yields=[dict(id=m, name=mats.get(m, {}).get("name", f"材料{m}"), chance=ch, qty=q,
                     price=mats.get(m, {}).get("price") or 0, sold_per_day=mats.get(m, {}).get("sold_per_day") or 0)
                for m, ch, q in ys])
    # 每天能做多少：别超过主要材料日销的 20%，也别超过货源日销的一半
    per_unit_main = sum(y["chance"] * y["qty"] for y in out["yields"] if y["id"] == main_id)
    cap_mat = int(out["main_spd"] * 0.2 / per_unit_main) if per_unit_main else 0
    cap_src = int((out["sold_per_day"] or quantity) * 0.5)
    out["daily_cap"] = max(0, min(cap_mat, cap_src))
    return out


def record(db, w, now=None):
    db.executescript(SCHEMA)
    db.execute("INSERT OR REPLACE INTO watch_log VALUES(?,?,?,?,?,?,?,?,?)",
               (int(now or time.time()), w["item_id"], w["min_price"], w["wall_price"], w["quantity"], w["ev"],
                w["main_id"], w["main_price"], w["source"]))
    db.commit()


def history(db, item_id, limit=8):
    db.executescript(SCHEMA)
    return list(reversed(db.execute("SELECT * FROM watch_log WHERE item_id=? ORDER BY t DESC LIMIT ?",
                                    (item_id, limit)).fetchall()))


def trend(hist, w):
    """和最早一条记录比：货源价、在售量、主要材料价的变化。"""
    if not hist:
        return None
    first = hist[0]
    def pct(a, b):
        return (b - a) / a * 100 if a else 0
    return dict(hours=(time.time() - first["t"]) / 3600, min_price=pct(first["min_price"], w["min_price"]),
                quantity=pct(first["quantity"], w["quantity"]), main_price=pct(first["main_price"], w["main_price"]),
                ev=pct(first["ev"], w["ev"]))
