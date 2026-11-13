"""蓝色武器逐件分析。

蓝色（精良）武器就那么一百来把，每把都是固定属性、固定的一批人在某个等级段要用，所以不走"后缀错标"的思路，
而是一把一把地看它自己的价格：平时最低卖多少、一周里低位和高位在哪、一天走几把。
  进货线 = 过去 7 天"每小时最低价"的下四分位（一周里有四分之一的时间能在这个价以下买到）
  平时最低价 = 同一序列的中位数（挂出去能比较快卖掉的价）
  高位 = 上四分位
哪些物品是蓝色武器，来自本机装的 DungeonsForeverGear 插件的装备库（没装就做不了）。
"""
import json
import os
import re
import statistics
import time
from pathlib import Path

from . import collector

SUB = {0: "单手斧", 1: "双手斧", 2: "弓", 3: "枪械", 4: "单手锤", 5: "双手锤", 6: "长柄", 7: "单手剑", 8: "双手剑",
       10: "法杖", 13: "拳套", 15: "匕首", 16: "投掷", 18: "弩", 19: "魔杖"}
CACHE = Path(__file__).resolve().parent.parent / "data" / "blue_cache.json"


def gear_db(cfg):
    """装备库：{物品ID: {name, q(品质), ilvl, req, sub(武器子类), cls(2 武器 / 4 护甲)}}。"""
    p = Path(os.path.expanduser(cfg["addon"]["addons_dir"])) / "DungeonsForeverGear" / "Core" / "Data" / "Data_Gear.lua"
    if not p.exists():
        return {}
    out = {}
    for m in re.finditer(r'\{(\d+),"((?:[^"\\]|\\.)*)",(\d+),"[^"]*"\}', p.read_text(encoding="utf-8", errors="replace")):
        i, name, v = int(m.group(1)), m.group(2), int(m.group(3))
        out[i] = dict(name=name, q=v % 8, ilvl=(v >> 3) % 256, req=(v >> 11) % 256, sub=(v >> 19) % 32, cls=4 if (v >> 24) % 2 else 2)
    return out


def profile(series):
    """7 天小时序列 -> (平时最低价, 低位, 高位, 样本数, 最近一天的最低价中位)；历史不够返回 None。"""
    seq = [p[1] for p in series or [] if p[1] > 0]          # 按时间先后
    mins = sorted(seq)
    if len(mins) < 20:
        return None
    recent = int(statistics.median(seq[-max(6, len(seq) // 7):]))      # 最后七分之一 ≈ 最近一天
    return int(statistics.median(mins)), mins[len(mins) // 4], mins[len(mins) * 3 // 4], len(mins), recent


def build(cfg, db, snapshot_id, max_req=39, max_age_hours=6, fetch=None, now=None):
    now = now or time.time()
    if fetch is None and CACHE.exists():
        try:
            c = json.loads(CACHE.read_text(encoding="utf-8"))
            if now - c.get("at", 0) < max_age_hours * 3600 and c.get("market") == cfg["market"]["id"]:
                return c["blue"]
        except (ValueError, KeyError):
            pass
    gdb = gear_db(cfg)
    if not gdb:
        return None
    quotes = {r["item_id"]: r for r in db.execute("SELECT * FROM quotes WHERE snapshot_id=?", (snapshot_id,))}
    pause = 0.15 if fetch is None else 0
    fetch = fetch or (lambda iid: collector.fetch_detail(cfg, db, iid))
    items = []
    for iid, q in quotes.items():
        g = gdb.get(iid)
        if not g or g["cls"] != 2 or g["q"] != 3 or g["req"] > max_req or q["min_buyout"] <= 0:
            continue
        try:
            d = fetch(iid)
        except Exception:
            continue
        pr = profile([(p.get("t"), p.get("min") or 0) for p in d.get("series") or []])
        time.sleep(pause)
        if not pr:
            continue
        typ, low, high, n, recent = pr
        items.append(dict(item_id=iid, name=g["name"], kind=SUB.get(g["sub"], "武器"), req=g["req"], ilvl=g["ilvl"],
                          cur=q["min_buyout"], qty=q["quantity"], typ=typ, low=low, high=high, recent=recent, spd=q["sold_per_day"] or 0, points=n))
    blue = dict(at=int(now), items=items)
    if items:
        CACHE.write_text(json.dumps(dict(at=now, market=cfg["market"]["id"], blue=blue), ensure_ascii=False), encoding="utf-8")
    return blue


def judge(it, cur=None, ah_cut=0.05, min_roi=0.15):
    """现在这个价值不值得进：返回 (结论, 按平时最低价卖出的净赚)。和插件里的判断一致。"""
    cur = cur or it["cur"]
    ref = min(it["typ"], it.get("recent") or it["typ"])      # 卖价按"一周中位"和"最近一天"里低的那个算：在跌的货不能按一周前的价估
    net = int(ref * (1 - ah_cut)) - cur
    if cur <= 0:
        return "没货", 0
    falling = (it.get("recent") or it["typ"]) < it["typ"] * 0.85
    if cur <= it["low"] and net >= cur * min_roi:
        return ("可以进" if it["spd"] >= 2 else "可以进（走得慢）"), net
    if falling:
        return "在跌，先别进", net
    if net >= cur * min_roi:
        return "偏低", net
    if cur >= it["high"]:
        return "高位（出货）", net
    return "等", net
