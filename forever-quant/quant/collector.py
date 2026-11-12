"""从 AHledger 公开 API 拉行情。数据由玩家扫描贡献，不是逐笔成交。Prices from AHledger."""
import json
import time
import urllib.error
import urllib.request

from . import database


def parse_pricetable(text):
    """解析 AHL1 文本价格表。

    首行: AHL1|<market path>|<unix 时间>|<行数>
    每行: itemId:median:minBuyout:quantity:median7d:median30d:low:high:soldPerDay*10
    （列含义已和 /prices 明细接口逐项核对过；low/high 是数据源给的历史区间。）
    """
    lines = text.strip().split("\n")
    head = lines[0].split("|")
    if head[0] != "AHL1" or len(head) < 4:
        raise ValueError(f"未知的价格表格式: {lines[0][:60]!r}")
    market = head[1].replace("/", ".")
    captured_at = int(head[2])
    rows = []
    for line in lines[1:]:
        f = line.split(":")
        if len(f) != 9:
            continue
        v = [int(x) if x else 0 for x in f]
        rows.append(dict(item_id=v[0], median=v[1], min_buyout=v[2], quantity=v[3],
                         median7d=v[4], median30d=v[5], low=v[6], high=v[7],
                         sold_per_day=v[8] / 10.0))
    return market, captured_at, rows


def _get(cfg, path, etag=None):
    req = urllib.request.Request(cfg["api"]["base"] + path,
                                 headers={"User-Agent": cfg["api"]["user_agent"]})
    if etag:
        req.add_header("If-None-Match", etag)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8"), r.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return 304, None, etag
        raise


def collect(cfg, db, force=False, now=None):
    """拉一次全市场价格表。返回 (snapshot_id, 状态说明)。"""
    now = int(now or time.time())
    market = cfg["market"]["id"]
    last = db.execute("SELECT * FROM snapshots WHERE market=? ORDER BY fetched_at DESC LIMIT 1",
                      (market,)).fetchone()
    gap = cfg["api"]["min_interval_minutes"] * 60
    if last and not force and now - last["fetched_at"] < gap:
        return last["id"], f"距上次拉取不足 {cfg['api']['min_interval_minutes']} 分钟，跳过"
    status, body, etag = _get(cfg, f"/pricetable/{market}", last["etag"] if last else None)
    if status == 304:
        db.execute("UPDATE snapshots SET fetched_at=? WHERE id=?", (now, last["id"]))
        db.commit()
        return last["id"], "数据源没有更新 (304)"
    got_market, captured_at, rows = parse_pricetable(body)
    if got_market != market:
        raise ValueError(f"返回的市场 {got_market} 和配置的 {market} 不一致")
    dup = db.execute("SELECT id FROM snapshots WHERE market=? AND captured_at=? AND source='ahledger'",
                     (market, captured_at)).fetchone()
    if dup:
        db.execute("UPDATE snapshots SET fetched_at=?, etag=? WHERE id=?", (now, etag, dup["id"]))
        db.commit()
        return dup["id"], "数据源还是同一份扫描"
    cur = db.execute("INSERT INTO snapshots(market,captured_at,fetched_at,source,etag) VALUES(?,?,?,?,?)",
                     (market, captured_at, now, "ahledger", etag))
    sid = cur.lastrowid
    db.executemany(
        "INSERT INTO quotes VALUES(:sid,:item_id,:median,:min_buyout,:quantity,:median7d,:median30d,"
        ":low,:high,:sold_per_day)", [dict(r, sid=sid) for r in rows])
    db.commit()
    return sid, f"新快照 #{sid}：{len(rows)} 个物品，行情时间 {time.strftime('%m-%d %H:%M', time.localtime(captured_at))}"


def fetch_detail(cfg, db, item_id):
    """拉单个物品明细（名称、品质、7 天价格序列）。名称写入 items 表。"""
    _, body, _ = _get(cfg, f"/prices/{cfg['market']['id']}/{item_id}")
    d = json.loads(body)
    it = d.get("item", {})
    db.execute("INSERT INTO items(item_id,name,quality) VALUES(?,?,?) "
               "ON CONFLICT(item_id) DO UPDATE SET name=excluded.name, quality=excluded.quality",
               (item_id, it.get("name"), it.get("quality")))
    db.commit()
    return d


def fetch_materials(cfg):
    """分解材料的当前行情：{材料ID: {name, price(最低价), median, sold_per_day}}，以及行情时间。"""
    d = fetch_disenchant(cfg)
    mats = {m["id"]: dict(name=m["name"], price=m.get("minBuyout") or 0, median=m.get("median") or 0,
                          sold_per_day=m.get("soldPerDay") or 0) for m in d.get("materials", [])}
    return mats, d.get("pricesAsOf")


def fetch_disenchant(cfg):
    _, body, _ = _get(cfg, f"/disenchant/{cfg['market']['id']}")
    return json.loads(body)
