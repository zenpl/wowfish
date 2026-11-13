"""随机后缀绿装分析。

数据来自游戏内 /fq scan（插件读取拍卖行挂单，带后缀）。假设：同一类装备，热门后缀
（比如皮甲的"猴之"）卖得比冷门后缀贵得多；把热门后缀按冷门价挂出来的单子就是机会。
"""
import os
import re
import time
from collections import defaultdict
from pathlib import Path
from statistics import median

from . import strategies
from .config import silver

SCHEMA = """
CREATE TABLE IF NOT EXISTS gear_scans (
    id INTEGER PRIMARY KEY, scanned_at INTEGER NOT NULL UNIQUE, ended_at INTEGER, faction TEXT, realm TEXT,
    min_level INTEGER, max_level INTEGER, status TEXT, pages INTEGER, n INTEGER
);
CREATE TABLE IF NOT EXISTS gear_listings (
    scan_id INTEGER NOT NULL REFERENCES gear_scans(id), item_id INTEGER, suffix_id INTEGER, unique_id INTEGER,
    count INTEGER, buyout INTEGER, min_bid INTEGER, level INTEGER, time_left INTEGER,
    class_id INTEGER, subclass_id INTEGER, equip_loc TEXT, owner TEXT, name TEXT
);
CREATE INDEX IF NOT EXISTS idx_gear_scan ON gear_listings(scan_id);
CREATE TABLE IF NOT EXISTS gear_suffixes (suffix_id INTEGER PRIMARY KEY, label TEXT);
CREATE TABLE IF NOT EXISTS vendor_hits (
    scan_id INTEGER NOT NULL REFERENCES gear_scans(id), item_id INTEGER, suffix_id INTEGER, level INTEGER,
    quantity INTEGER, min_price INTEGER, vendor_price INTEGER, name TEXT
);
CREATE TABLE IF NOT EXISTS vendor_stats (scan_id INTEGER PRIMARY KEY, checked INTEGER, unknown INTEGER);
CREATE TABLE IF NOT EXISTS recipes (
    scan_id INTEGER NOT NULL REFERENCES gear_scans(id), item_id INTEGER, subclass_id INTEGER,
    quantity INTEGER, min_price INTEGER, vendor_sell INTEGER, name TEXT
);
"""
ARMOR = {0: "杂项", 1: "布甲", 2: "皮甲", 3: "锁甲", 4: "板甲", 6: "盾牌"}
# 剩余时间档位对应的"至少还剩多久"（秒）：1 短 <30 分钟，2 中 30 分钟~2 小时，3 长 2~8 小时，4 很长 >8 小时
MIN_REMAINING = {1: 0, 2: 1800, 3: 7200, 4: 28800}


def kind(class_id, subclass_id):
    return ARMOR.get(subclass_id, f"护甲{subclass_id}") if class_id == 4 else "武器"


def find_saved_variables(cfg):
    wtf = Path(os.path.expanduser(cfg["addon"]["addons_dir"])).parent.parent / "WTF" / "Account"
    files = sorted(wtf.glob("*/SavedVariables/ForeverQuant.lua"), key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def parse_log(text):
    """从 SavedVariables 文本里按顺序取出 log 数组的字符串。"""
    out = []
    for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)",?\s*(?:--.*)?$', text, re.M):   # 行尾的 "-- [n]" 注释可有可无
        out.append(re.sub(r"\\(.)", r"\1", m.group(1)))
    return out


def parse_scans(lines):
    scans, cur = [], None
    for line in lines:
        if line.startswith("#SCAN|"):
            f = line.split("|")
            cur = dict(scanned_at=int(f[1]), faction=f[2], realm=f[3], min_level=int(f[4]),
                       max_level=int(f[5]), rows=[], status=None, suffixes={}, vendor=[], vstat=None)
        elif line.startswith("#VENDOR|"):
            f = line.split("|", 7)
            if cur is not None and len(f) == 8:
                cur["vendor"].append(tuple(int(x) for x in f[1:7]) + (f[7],))
        elif line.startswith("#RECIPE|"):
            f = line.split("|", 6)
            if cur is not None and len(f) == 7:
                cur.setdefault("recipes", []).append(tuple(int(x) for x in f[1:6]) + (f[6],))
        elif line.startswith("#VSTAT|"):
            f = line.split("|")
            if cur is not None:
                cur["vstat"] = (int(f[1]), int(f[2]))
        elif line.startswith("#SUFFIX|"):
            f = line.split("|", 2)
            if cur is not None and len(f) == 3 and f[2]:
                cur["suffixes"][int(f[1])] = f[2]
        elif line.startswith("#END|"):
            if cur:
                f = line.split("|")
                cur.update(ended_at=int(f[1]), status=f[2], pages=int(f[3]))
                scans.append(cur)
                cur = None
        elif cur is not None:
            f = line.split("|", 12)
            if len(f) == 13:
                try:
                    cur["rows"].append(tuple(int(x) for x in f[:10]) + (f[10], f[11], f[12]))
                except ValueError:
                    pass
    return scans           # 没有 #END 的（比如扫描中途掉线）被丢弃


def import_scans(db, scans):
    db.executescript(SCHEMA)
    added = 0
    for s in scans:
        for sid, label in s.get("suffixes", {}).items():     # 后缀属性表每次都更新
            db.execute("INSERT INTO gear_suffixes VALUES(?,?) ON CONFLICT(suffix_id) DO UPDATE SET label=excluded.label",
                       (sid, label))
        if s.get("status") is None:
            continue
        if not s["rows"] or db.execute("SELECT 1 FROM gear_scans WHERE scanned_at=?", (s["scanned_at"],)).fetchone():
            continue
        cur = db.execute("INSERT INTO gear_scans(scanned_at,ended_at,faction,realm,min_level,max_level,status,pages,n) "
                         "VALUES(?,?,?,?,?,?,?,?,?)", (s["scanned_at"], s["ended_at"], s["faction"], s["realm"],
                                                       s["min_level"], s["max_level"], s["status"], s["pages"], len(s["rows"])))
        db.executemany("INSERT INTO gear_listings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       [(cur.lastrowid,) + r for r in s["rows"]])
        db.executemany("INSERT INTO vendor_hits VALUES(?,?,?,?,?,?,?,?)", [(cur.lastrowid,) + v for v in s.get("vendor", [])])
        db.executemany("INSERT INTO recipes VALUES(?,?,?,?,?,?,?)", [(cur.lastrowid,) + v for v in s.get("recipes", [])])
        if s.get("vstat"):
            db.execute("INSERT OR REPLACE INTO vendor_stats VALUES(?,?,?)", (cur.lastrowid,) + s["vstat"])
        added += 1
    db.commit()
    return added


def learn_suffix_labels(db):
    """从带后缀的物品名里学出每个后缀 ID 的叫法，写入 gear_suffixes。

    中文客户端是 "野熊之七彩戒指"（前缀 + 之），英文客户端是 "Ritual Cape of the Bear"。
    对每个后缀 ID，取它名下所有物品名里出现最多的那个前缀/后缀。
    """
    votes = defaultdict(lambda: defaultdict(int))
    for r in db.execute("SELECT suffix_id, name FROM gear_listings WHERE suffix_id != 0 AND name != ''"):
        name = r["name"]
        if " of " in name:
            votes[r["suffix_id"]][name[name.rfind(" of ") + 1:]] += 1
        elif "之" in name:
            votes[r["suffix_id"]][name.split("之", 1)[0] + "之"] += 1
    for sid, v in votes.items():
        label, n = max(v.items(), key=lambda kv: kv[1])
        if n >= 3 and n >= 0.6 * sum(v.values()):          # 大多数物品都带同一个词才算数
            db.execute("INSERT INTO gear_suffixes VALUES(?,?) ON CONFLICT(suffix_id) DO UPDATE SET label=excluded.label",
                       (sid, label))
    db.commit()


def suffix_label(suffix_id, known=None):
    if not suffix_id:
        return ""
    return (known or {}).get(suffix_id) or f"后缀{suffix_id}"


def load(db, scan_id):
    rows = []
    known = {r["suffix_id"]: r["label"] for r in db.execute("SELECT * FROM gear_suffixes") if r["label"]}
    for r in db.execute("SELECT * FROM gear_listings WHERE scan_id=? AND buyout>0", (scan_id,)):
        d = dict(r)
        d["label"] = suffix_label(d["suffix_id"], known)
        d["kind"] = kind(d["class_id"], d["subclass_id"])
        d["group"] = (d["class_id"], d["subclass_id"], d["equip_loc"], d["label"], d["level"] // 5)
        d["key"] = (d["item_id"], d["suffix_id"], d["unique_id"], d["owner"], d["buyout"])
        # 汇总式扫描（没有剩余时间）里，"起拍价"那一列存的是需求等级
        d["req_level"] = d["min_bid"] if not d["time_left"] else 0
        d["effect"] = d["owner"] if not d["time_left"] else ""     # 同理，"卖家"那一列存的是特效文字
        rows.append(d)
    return rows


def percentile(vals, p):
    v = sorted(vals)
    return v[min(len(v) - 1, int(len(v) * p))]


def suffix_premium(rows, min_item_listings=4):
    """每个 (装备类型, 后缀) 的相对价格：单子价格 / 同一物品所有后缀的中位价，再取中位数。"""
    by_item = defaultdict(list)
    for r in rows:
        by_item[r["item_id"]].append(r["buyout"])
    rel = defaultdict(list)
    for r in rows:
        if r["label"] and len(by_item[r["item_id"]]) >= min_item_listings:
            rel[(r["kind"], r["label"])].append(r["buyout"] / median(by_item[r["item_id"]]))
    return {k: (median(v), len(v)) for k, v in rel.items()}


def sell_through(prev_rows, cur_rows, gap):
    """两次扫描之间减少的在售数量，按 (装备类型, 后缀) 汇总。返回 {(类型, 后缀): (减少数, 上次在售数)}。

    减少可能是卖出，也可能是过期或撤单，所以这是走货速度的上限估计。
    逐单数据（有剩余时间）会排除可能自然过期的单子；汇总数据（剩余时间为 0）做不到。
    """
    listing_mode = any(r["time_left"] for r in prev_rows)
    out = defaultdict(lambda: [0, 0])
    if listing_mode:
        alive = {r["key"] for r in cur_rows}
        for r in prev_rows:
            if not r["label"] or MIN_REMAINING.get(r["time_left"], 0) <= gap:
                continue
            k = (r["kind"], r["label"])
            out[k][1] += 1
            if r["key"] not in alive:
                out[k][0] += 1
    else:
        now_qty = defaultdict(int)
        for r in cur_rows:
            now_qty[(r["item_id"], r["suffix_id"], r["level"])] += r["count"]
        for r in prev_rows:
            if not r["label"]:
                continue
            k = (r["kind"], r["label"])
            out[k][1] += r["count"]
            out[k][0] += max(0, r["count"] - now_qty.get((r["item_id"], r["suffix_id"], r["level"]), 0))
    return {k: tuple(v) for k, v in out.items()}


def find_mispriced(rows, s, premium, sold=None, min_comps=5, max_ratio=0.5, min_premium=1.2):
    """热门后缀里，价格不到同类单子下四分位价一半的挂单。"""
    groups = defaultdict(list)
    for r in rows:
        if r["label"]:
            groups[r["group"]].append(r)
    out = []
    for g, members in groups.items():
        if len(members) < min_comps + 1:
            continue
        for r in members:
            comps = [m["buyout"] for m in members if m is not r]
            fair = percentile(comps, 0.25)             # 保守：按同类里偏便宜的价位估
            prem, n_prem = premium.get((r["kind"], r["label"]), (0, 0))
            if r["buyout"] > fair * max_ratio or prem < min_premium:
                continue
            target = int(fair * 0.97)
            profit = strategies.net_after_cut(target, s["ah_cut"]) - r["buyout"]
            if profit < s.get("min_unit_profit", 0) or profit / r["buyout"] < s["min_roi"]:
                continue
            c = strategies.Candidate(r["item_id"], "GEAR", r["buyout"], target, profit, profit / r["buyout"],
                                     1 - r["buyout"] / fair, 0.0, 0.0)
            c.name = r["name"]
            c.suffix_id = r["suffix_id"]
            who = f"，卖家 {r['owner']}" if r["owner"] else ""
            c.notes = [f"{r['kind']} {r['label']}，物品等级 {r['level']}{who}",
                       f"同类 {len(comps)} 单：下四分位 {int(fair)} 铜，中位 {int(median(comps))} 铜；后缀溢价 ×{prem:.1f}"]
            st = (sold or {}).get((r["kind"], r["label"]))
            if st and st[1] >= 5:
                rate = st[0] / st[1]
                c.notes.append(f"上次扫描以来这类后缀在售减少 {st[0]}/{st[1]} 件")
                c.score = round(min(100, 100 * rate * min(c.roi, 3) / 3 + 20), 1)
            else:
                c.notes.append("还没有走货数据（需要至少两次扫描），挂价高不等于卖得掉")
                c.score = round(min(40, 10 * min(c.roi, 4)), 1)
            out.append(c)
    out.sort(key=lambda c: (c.score, c.unit_profit), reverse=True)
    return out


def vendor_arbitrage(db, scan_id, min_profit=1):
    """拍卖行最低价低于商人收购价的物品。返回 (命中列表, 比对条数, 查不到商人价的条数)。
    只能确定这个价位至少有 1 件；quantity 是该物品全部在售数量，不是这个价位的数量。"""
    hits = [dict(r, profit=r["vendor_price"] - r["min_price"]) for r in db.execute(
        "SELECT * FROM vendor_hits WHERE scan_id=? AND min_price < vendor_price", (scan_id,))]
    hits = [h for h in hits if h["profit"] >= min_profit]
    hits.sort(key=lambda h: -h["profit"])
    st = db.execute("SELECT * FROM vendor_stats WHERE scan_id=?", (scan_id,)).fetchone()
    return hits, (st["checked"] if st else None), (st["unknown"] if st else None)


PROFESSION = {0: "书籍", 1: "制皮", 2: "裁缝", 3: "工程", 4: "锻造", 5: "烹饪", 6: "炼金", 7: "急救", 8: "附魔", 9: "钓鱼", 10: "珠宝"}
VENDOR_MARKUP = 4      # 商人卖价通常是收购价的 4 倍（声望折扣前）。这是通用规律，不是逐个核实的


def fmt_vendors(vs, limit=4):
    parts = []
    for v in vs[:limit]:
        pos = f" {v['x']:.0f},{v['y']:.0f}" if v.get("x") is not None else ""
        parts.append(f"{v['zone']}{pos} {v['name']}")
    return "；".join(parts) + (f"；等共 {len(vs)} 处" if len(vs) > limit else "")


def recipe_resale(db, scan_id, s, sold_per_day=None, min_net=100, min_roi=0.15, vendor_db=None, faction="H"):
    """从商人买配方、到拍卖行卖。成本按"收购价 x4"估算；只对商人确实有卖的配方成立。
    sold_per_day: {item_id: 估计日销}（来自行情源，可缺）。"""
    out = []
    for r in db.execute("SELECT * FROM recipes WHERE scan_id=? AND vendor_sell>0 AND min_price>0", (scan_id,)):
        cost = r["vendor_sell"] * VENDOR_MARKUP
        target = int(r["min_price"] * 0.97)                      # 比现在最低价再低一点才卖得掉
        net = strategies.net_after_cut(target, s["ah_cut"]) - cost
        if net < min_net or net / cost < min_roi:
            continue
        spd = (sold_per_day or {}).get(r["item_id"])
        vs = vendor_db.vendors(r["item_id"], faction) if vendor_db else None
        # source: vendor=本阵营商人有卖  none=数据库里没有商人卖（掉落/制造/任务）  unknown=数据库里没有这个物品
        source = "unknown" if vs is None else ("vendor" if vs else "none")
        out.append(dict(r, cost=cost, target=target, net=net, roi=net / cost, sold_per_day=spd,
                        profession=PROFESSION.get(r["subclass_id"], "?"), source=source,
                        vendors=fmt_vendors(vs) if vs else "", vendor_list=vs or []))
    # 卖得动的排前面：日销 >= 0.5 的按"每张净赚 x 日销（封顶 20 张）"排；几乎不走货的沉底，
    # 否则挂着天价但没人买的配方会排到最上面
    def key(x):
        spd = x["sold_per_day"] or 0
        return (spd >= 0.5, x["net"] * min(spd, 20) if spd >= 0.5 else x["net"])
    out.sort(key=key, reverse=True)
    return out


RULE_KIND = {"皮甲": "leather", "布甲": "cloth", "锁甲": "mail"}

# 武器按类型分规则：谁会用这种武器，决定了哪些后缀有人要（法杖上的智力有人要，弓上的智力没人要）。
# 游戏里的武器子类编号 -> 规则名。每类谁会用，写在 config.toml 的 [gear_rule.wearers] 里。
WEAPON_KEY = {15: "weapon_dagger", 7: "weapon_sword1h", 4: "weapon_mace1h", 0: "weapon_axe1h", 13: "weapon_fist",
              1: "weapon_2h", 8: "weapon_2h", 6: "weapon_2h", 5: "weapon_mace2h", 10: "weapon_staff",
              2: "weapon_ranged", 3: "weapon_ranged", 18: "weapon_ranged", 16: "weapon_ranged", 19: "weapon_wand"}
WEAPON_NAME = {"weapon_dagger": "匕首", "weapon_sword1h": "单手剑", "weapon_mace1h": "单手锤", "weapon_axe1h": "单手斧",
               "weapon_fist": "拳套", "weapon_2h": "双手剑/斧/长柄", "weapon_mace2h": "双手锤", "weapon_staff": "法杖",
               "weapon_ranged": "弓/枪/弩", "weapon_wand": "魔杖", "weapon": "武器"}


def rule_key(r):
    """这一行适用哪条规则：首饰和披风单独一类，武器一类，其余按护甲类型。没有规则返回 None。"""
    if r["equip_loc"] in ("INVTYPE_CLOAK", "INVTYPE_FINGER", "INVTYPE_NECK"):
        return "jewelry_cloak"
    if r["class_id"] == 2:
        return WEAPON_KEY.get(r["subclass_id"], "weapon")
    return RULE_KIND.get(r["kind"])


KEY_KIND = {"leather": "皮甲", "cloth": "布甲", "mail": "锁甲", **{k: "武器" for k in WEAPON_NAME}}


ROLE_NAME = {"mage": "法师", "warlock": "术士", "priest": "牧师", "caster": "法系", "melee": "盗贼/近战", "paladin": "圣骑", "druid": "德鲁伊", "druid_caster": "法系德", "feral": "野德"}


SECONDARY_CAP = 0.9      # 副属性再重要也不能和主属性齐平


def role_weights(rule, role):
    """某个职业的属性权重表 {属性: 权重}。

    新写法：{main = [...], secondary = {属性 = 权重}, premium = [...]} —— 主属性和好词缀固定 1.0，
    副属性最高压到 SECONDARY_CAP。旧写法（直接一张 {属性 = 权重} 的表）原样使用。
    """
    spec = (rule.get("roles") or {}).get(role) or {}
    if not any(k in spec for k in ("main", "secondary", "premium")):
        return spec
    w = {st: min(float(v), SECONDARY_CAP) for st, v in (spec.get("secondary") or {}).items()}
    for st in (spec.get("premium") or []):
        w[st] = 1.0
    for st in (spec.get("main") or []):
        w[st] = 1.0
    # main_weight：仍然算主属性级别（不触发"没有主属性"的减半），但因为用的人少，需求打个折
    for st, v in (spec.get("main_weight") or {}).items():
        if st in w:
            w[st] = float(v)
    return w


def role_mains(rule, role):
    """某个职业的主属性集合。新写法取 main 列表；旧写法取权重为 1.0 的属性。"""
    spec = (rule.get("roles") or {}).get(role) or {}
    if any(k in spec for k in ("main", "premium")):
        return set(spec.get("main") or []) | set(spec.get("premium") or [])    # premium 是早先的写法，等同主属性级别
    return {st for st, v in spec.items() if isinstance(v, (int, float)) and v >= 1.0}


def role_value(rule, role, label):
    """后缀对某一个职业的价值（0~1）和是否重点。见 suffix_value 的说明。"""
    w = role_weights(rule, role)
    stats = list((rule.get("suffix_stats") or {}).get(label) or [])
    if not stats or not w:
        return 0, False
    main_set = role_mains(rule, role)
    mains = sum(1 for st in stats if st in main_set)
    value = sum(w.get(st, 0) for st in stats) / len(stats)
    if mains == 0:
        value *= rule.get("no_main_penalty", 0.5)
    value = round(value, 3)
    # 重点：攻强或法伤，再叠加一个主属性，而且整体浪费不多（价值 >= 80%）
    premium = set(rule.get("premium_stats") or ["ap", "sp"])
    power = any(st in premium and w.get(st, 0) >= 1.0 for st in stats)
    return value, bool(power and mains >= 2 and value >= rule.get("star_min_value", 0.8))


def suffix_value(rule, key, label):
    """后缀在某类装备上的价值（0~1）：属性预算里有多大比例落在穿戴者想要的属性上。

    按"属性预算"模型：各属性平分预算；主属性权重 1.0，想要的副属性 0.7~0.8，不要的属性 0（浪费）。
    没有任何主属性的后缀再乘 no_main_penalty。在会穿这类装备的职业里取价值最高的那个。
    返回 (价值, 是否重点, 职业)。重点 = 攻强或法伤叠加另一个主属性，且价值不低于 80%。没配职业表时返回 (0, False, None)。
    """
    best = (0, False, None)
    for role in (rule.get("wearers") or {}).get(key) or []:
        value, star = role_value(rule, role, label)
        if (value, star) > best[:2]:
            best = (value, star, role)
    return best


# "melee" 这组在规则里是"要敏捷/攻强的人"：盗贼、40 级前的猎人、增强萨。估价按属性走没问题，但具体到武器，谁能用是不一样的：
# 盗贼只用匕首、单手剑、单手锤、拳套，不能用斧子，也不用双手武器；斧子和双手武器的敏捷/攻强买家是猎人和增强萨。
# 所以理由里写的职业名要按武器类型换，不能一律写盗贼。
WEAPON_MELEE_WHO = {"weapon_axe1h": "猎人/萨满", "weapon_2h": "猎人/萨满", "weapon_mace2h": "萨满", "weapon_staff": "猎人/野德",
                    "weapon_ranged": "猎人", "weapon_fist": "盗贼/萨满", "weapon_dagger": "盗贼", "weapon_sword1h": "盗贼/猎人",
                    "weapon_mace1h": "盗贼/萨满", "weapon": "近战"}


def role_name(key, role, short=False):
    """这条规则（装备类型）下，这个角色该叫什么。"""
    if role == "melee" and key in WEAPON_MELEE_WHO:
        return WEAPON_MELEE_WHO[key]
    return (ROLE_SHORT if short else ROLE_NAME).get(role, role)


ROLE_SHORT = {"mage": "法师", "warlock": "术士", "priest": "牧师", "caster": "法系", "melee": "盗贼", "paladin": "圣骑", "druid": "德鲁伊", "druid_caster": "法系德", "feral": "野德"}    # 面板理由里用的短名
STAT_CN = {"agi": "敏捷", "str": "力量", "int": "智力", "sta": "耐力", "spi": "精神", "ap": "攻强", "sp": "法伤", "heal": "治疗",
           "sp_shadow": "暗影法伤", "sp_fire": "火焰法伤", "sp_frost": "冰霜法伤", "sp_arcane": "奥术法伤", "sp_holy": "神圣法伤", "sp_nature": "自然法伤",
           "def": "防御", "crit": "暴击", "res": "抗性", "mp5": "回蓝", "hp5": "回血", "dodge": "躲闪"}


def stats_cn(rule, label):
    return "+".join(STAT_CN.get(st, st) for st in (rule.get("suffix_stats") or {}).get(label) or [])


def stars_for(score, rule):
    """综合分数 -> 一到三星。"""
    if score >= rule.get("stars_3", 85):
        return 3
    return 2 if score >= rule.get("stars_2", 55) else 1


def demand_index(rule, key, label):
    """这个后缀在这类装备上的需求指数，以及各职业的需求明细。

    返回 (指数, [(职业, 需求值), ...] 按需求值从高到低，只含达到热门门槛的职业)。
    指数 = 最高的那个 + 其余的 x multi_role_factor。没有职业想要时返回 (0, [])。
    """
    hot_min = rule.get("hot_min_value", 0.5)
    wants = sorted(((role, role_value(rule, role, label)[0]) for role in (rule.get("wearers") or {}).get(key) or []),
                   key=lambda rv: -rv[1])
    wants = [(role, v) for role, v in wants if v >= hot_min]
    if not wants:
        return 0, []
    index = wants[0][1] + rule.get("multi_role_factor", 0.5) * sum(v for _, v in wants[1:])
    return round(index, 3), wants


def premium_strength(rule, key, label):
    """好词缀的需求强度（0~1）：后缀带攻强/法伤/治疗时，取会穿这类装备的职业里对它最高的权重。
    把它当主属性的职业是 1.0；只当副属性的（比如圣骑对法伤）就是副属性权重；没人要就是 0。"""
    stats = set((rule.get("suffix_stats") or {}).get(label) or []) & set(rule.get("premium_stats") or [])
    if not stats:
        return 0
    return max((role_weights(rule, role).get(st, 0) for role in (rule.get("wearers") or {}).get(key) or [] for st in stats),
               default=0)


def is_premium(rule, key, label):
    return premium_strength(rule, key, label) > 0


SHARE = {1: 1.0, 2: 0.7, 3: 0.55}      # 后缀里属性越多，每项分到的数值越少


def magnitude(rule, label, level):
    """好词缀的数值系数（0.3~1）：物品等级越高数值越大；后缀里属性越少每项越多。
    拿不到带后缀装备的具体点数，这是按规律估的。"""
    n = len((rule.get("suffix_stats") or {}).get(label) or []) or 1
    lvl = max(0.3, min(1.0, level / rule.get("premium_full_level", 34)))
    return round(lvl * SHARE.get(n, 0.5), 3)


def effect_strength(effect, level):
    """特效文字里的数字相对同等级典型值的比例（0.3~1.2）。攻击强度的典型值按 物品等级 x0.5，法伤/治疗按 x0.35。"""
    nums = re.findall(r"\d+", effect)
    if not nums or level <= 0:
        return 0.6
    typical = level * (0.5 if "攻击强度" in effect else 0.35)
    return round(max(0.3, min(1.2, int(nums[-1]) / typical)), 3)


def needed_stats(rule, key, label):
    """这个后缀在这类装备上带了哪些"特定需求"的属性（比如锁甲上的智力）。返回集合，可能为空。"""
    need = set((rule.get("need_stats") or {}).get(key) or [])
    return set((rule.get("suffix_stats") or {}).get(label) or []) & need


def is_confirmed(rule, key, label):
    """这个后缀在这类装备上的规则有没有成交验证。confirmed 里可以写整类（"leather"）
    或"类型:角色"（"leather:melee"）；属性是推断的后缀一律不算。"""
    if label in (rule.get("uncertain") or []):
        return False
    confirmed = set(rule.get("confirmed") or [])
    role = suffix_value(rule, key, label)[2]
    return key in confirmed or (role is not None and f"{key}:{role}" in confirmed)


def highlight_suffixes(rule):
    """重点后缀：攻强叠加近战主属性，或法伤叠加法系主属性。返回后缀名集合。"""
    melee = set(rule.get("highlight_melee_stats") or [])
    caster = set(rule.get("highlight_caster_stats") or [])
    ignore = set(rule.get("ignore") or [])
    out = set()
    for label, stats in (rule.get("suffix_stats") or {}).items():
        st = set(stats)
        if label not in ignore and (("ap" in st and st & melee) or ("sp" in st and st & caster)):
            out.add(label)
    return out


def hot_suffixes(rule, key, prem=None):
    """某类装备的热门后缀 -> 依据（"常识" 或 "数据"）。

    常识：按 [gear_rule.wants] 里这类装备穿戴者的输出属性——后缀带任意一个 primary 属性，
    或带两个 secondary 属性。数据：挂价溢价表里相对价格 >= data_premium 且样本 >= 15 的后缀。
    如果 rule[key] 直接给了后缀名单（旧写法），就用名单。
    """
    ignore = set(rule.get("ignore") or [])
    explicit = rule.get(key)
    if isinstance(explicit, list):
        return {label: "名单" for label in explicit if label not in ignore}
    out = {}
    if rule.get("roles") and (rule.get("wearers") or {}).get(key):
        for label in (rule.get("suffix_stats") or {}):
            if label not in ignore and suffix_value(rule, key, label)[0] >= rule.get("hot_min_value", 0.5):
                out[label] = "常识"
    want = (rule.get("wants") or {}).get(key) if not out else None
    if want:
        primary, secondary = set(want.get("primary") or []), set(want.get("secondary") or [])
        for label, stats in (rule.get("suffix_stats") or {}).items():
            st = set(stats)
            if label not in ignore and (st & primary or len(st & secondary) >= 2):
                out[label] = "常识"
    kind = KEY_KIND.get(key)
    if prem and kind:
        for (k, label), (ratio, n) in prem.items():
            if k == kind and n >= 15 and ratio >= rule.get("data_premium", 2.0) and label not in out and label not in ignore:
                out[label] = "数据"
    return out


def find_by_rule(rows, s, rule, sold=None, max_price=None, prem=None):
    """按"哪种装备要哪种属性"的规则找错标单。

    对每一件装备（同一物品 ID、同一物品等级）：看它所有后缀的最低价。如果某个热门后缀
    挂在这件装备的地板价附近（当垃圾卖），而同一件装备上别的热门后缀贵好几倍，就是候选。
    目标卖价取"同一件装备上其他热门后缀里最便宜的那个"再让 5%：要想卖掉，得比它们都便宜。

    战场小号档：需求等级在 [twink_min_req, twink_max_req] 的装备不受 max_level 限制，
    并且额外看重 twink_extra 里的后缀。需求等级来自扫描（老扫描没有，按 0 处理）。
    """
    confirmed = set(rule.get("confirmed") or [])
    tw_lo, tw_hi = rule.get("twink_min_req", 0), rule.get("twink_max_req", -1)
    tw_extra = set(rule.get("twink_extra") or []) - set(rule.get("ignore") or [])
    star = highlight_suffixes(rule)
    bonus = rule.get("highlight_bonus", 15)
    by = defaultdict(list)
    for r in rows:
        if r["label"]:
            by[(r["item_id"], r["level"])].append(r)
    out, cache = [], {}
    use_value = bool(rule.get("roles"))
    hot_min = rule.get("hot_min_value", 0.5)
    margin = rule.get("comp_margin", 0.15)

    def val(key, label):
        """后缀的价值分；角色表里算不出分的（靠数据补进来的热门后缀）按刚够热门算。"""
        v = suffix_value(rule, key, label)[0]
        return v if v > 0 else hot_min

    # 替代品索引：同类型、同部位的所有带后缀挂单
    slots = defaultdict(list)
    for r in rows:
        if r["label"]:
            slots[(r["class_id"], r["subclass_id"], r["equip_loc"])].append(r)
    alt_range = rule.get("alt_level_range", 3)

    for (item_id, level), lst in by.items():
        key = rule_key(lst[0])
        if not key or len(lst) < 4:
            continue
        if key not in cache:
            cache[key] = hot_suffixes(rule, key, prem)
        basis = cache[key]
        if not basis:
            continue
        req = lst[0].get("req_level") or 0
        twink = tw_lo <= req <= tw_hi
        if (level > rule.get("max_level", 34) and not twink) or level < rule.get("min_level", 0):
            continue
        hot_set = set(basis) | (tw_extra if twink else set())
        floor = min(r["buyout"] for r in lst)
        hots = [r for r in lst if r["label"] in hot_set]
        if len(hots) < 2:
            continue
        for r in hots:
            if max_price and r["buyout"] > max_price:
                continue
            # 参照物：同件装备上其他热门后缀的挂价。有角色表时只和"价值不比自己高出 comp_margin 以上"的比——
            # 一个只带精神+耐力的后缀，不能拿智力+法伤的挂价当自己的目标价。
            if use_value:
                own = val(key, r["label"])
                others = sorted(h["buyout"] for h in hots if h is not r and val(key, h["label"]) <= own + margin + 1e-9)
            else:
                others = sorted(h["buyout"] for h in hots if h is not r)
            if not others:
                continue
            # 超过中位数 10 倍的当作乱挂的天价，不算
            med = median(others)
            others = [o for o in others if o <= med * 10]
            ref = others[0]                       # 最便宜的那个竞争者
            if r["buyout"] > floor * rule.get("floor_ratio", 1.3) or ref < r["buyout"] * rule.get("min_gap", 3.0):
                continue
            target = int(ref * 0.95)
            # 替代品：同类型、同部位、相近等级里，对同一个职业同样好或更好的其他装备
            own_value, _, role = suffix_value(rule, key, r["label"])
            need = needed_stats(rule, key, r["label"])       # 带特定需求属性的：替代品也得带它
            n_alt, cheapest_alt = 0, None
            if role:
                for a in slots[(r["class_id"], r["subclass_id"], r["equip_loc"])]:
                    if a is r or abs(a["level"] - level) > alt_range:
                        continue
                    if need and not (need <= needed_stats(rule, key, a["label"])):
                        continue
                    if role_value(rule, role, a["label"])[0] >= own_value - 1e-9:
                        n_alt += 1
                        if cheapest_alt is None or a["buyout"] < cheapest_alt:
                            cheapest_alt = a["buyout"]
                if cheapest_alt is not None and int(cheapest_alt * 0.95) < target:
                    target = int(cheapest_alt * 0.95)       # 有同样好的更便宜的，卖不过它
            profit = strategies.net_after_cut(target, s["ah_cut"]) - r["buyout"]
            if profit < max(s.get("min_unit_profit", 0), rule.get("min_profit", 0)):
                continue
            c = strategies.Candidate(item_id, "GEAR", r["buyout"], target, profit, profit / r["buyout"],
                                     1 - r["buyout"] / ref, 0.0, 0.0)
            c.name, c.suffix_id = r["name"], r["suffix_id"]
            unsure = r["label"] in (rule.get("uncertain") or [])
            ok = is_confirmed(rule, key, r["label"])
            what = {"jewelry_cloak": "首饰/披风", **WEAPON_NAME}.get(key, r["kind"])
            c.notes = [f"{what} {r['label']}，物品等级 {level}" + (f"，需求等级 {req}" if req else "")
                       + f"；这件装备的地板价 {silver(floor)}",
                       "同件装备其他热门后缀挂价：" + " / ".join(silver(o) for o in others[:5]),
                       "规则有成交验证" if ok else "这类规则没有成交验证"]
            why = basis.get(r["label"])
            stats = (rule.get("suffix_stats") or {}).get(r["label"])
            if unsure:
                c.notes.append("注意：这个后缀加什么属性是推断的，买之前看一眼真实属性")
            if why == "常识" and stats:
                c.notes.append("热门依据：常识（输出优先），这个后缀带 " + "+".join(stats))
            elif why == "数据":
                c.notes.append("热门依据：挂价数据里这个后缀明显偏贵，常识规则没覆盖到")
            if twink:
                c.notes.append(f"39 级战场小号档（需求等级 {req}）")
            st = (sold or {}).get((r["kind"], r["label"]))
            if st and st[1] >= 5:
                c.notes.append(f"上次扫描以来这类后缀在售减少 {st[0]}/{st[1]} 件（含过期和撤单）")
            # 分数：有验证的规则优先，其次看净利润（封顶 1 金）；重点后缀再加分
            c.score = round((50 if ok else 20) + min(profit, 10000) / 10000 * 50, 1)
            value, role_star, role = suffix_value(rule, key, r["label"])
            if role:
                # 有角色表：利润占 40 分，后缀价值占 10 分
                c.score = round((50 if ok else 20) + min(profit, 10000) / 10000 * 40 + min(value, 1.0) * 10, 1)
                c.highlight = role_star
                c.notes.append(f"属性有 {value * 100:.0f}% 落在{role_name(key, role)}想要的属性上")
            else:
                c.highlight = r["label"] in star
            index, wants = demand_index(rule, key, r["label"])
            if len(wants) > 1:
                extra = round(min(rule.get("multi_role_cap", 15), rule.get("multi_role_bonus", 10) * sum(v for _, v in wants[1:])), 1)
                c.score = round(c.score + extra, 1)
                c.notes.append(f"多职业需求（指数 {index:.2f}）：" + "、".join(f"{role_name(key, ro)} {v * 100:.0f}%" for ro, v in wants))
            if need:
                c.score = round(c.score + rule.get("need_bonus", 5), 1)
                c.notes.append("特定需求：这类装备上带" + "+".join(sorted(need)) + "是专门有人找的（比如圣骑兼职奶要智力撑蓝量）；替代品只算同样带它的")
            if role:
                who = role_name(key, role)
                if n_alt == 0:
                    c.score = round(c.score + rule.get("scarcity_bonus", 10), 1)
                    c.notes.append(f"稀缺：同部位、物品等级 ±{alt_range} 内，没有对{who}同样好或更好的其他装备在售")
                else:
                    c.notes.append(f"替代品：同部位、物品等级 ±{alt_range} 内，对{who}同样好或更好的还有 {n_alt} 件，最便宜 {silver(cheapest_alt)}")
            strength = premium_strength(rule, key, r["label"])
            c.premium = strength > 0
            if c.premium:
                mag = magnitude(rule, r["label"], level)
                tier_bonus = round(rule.get("premium_bonus", 12) * strength * mag, 1)
                c.score = round(c.score + tier_bonus, 1)
                c.notes.insert(0, f"好词缀（攻强/法伤/治疗）：{'主属性级别的需求' if strength >= 1 else '只是副属性级别的需求'}，"
                                  f"数值系数 {mag:.2f}（按物品等级和后缀属性个数估），加 {tier_bonus} 分")
            if c.highlight:
                c.score = round(c.score + bonus, 1)
                c.notes.insert(0, "★ 重点：好词缀叠加主属性")
            # 一句话理由（面板里直接显示）和星级
            why_parts = []
            # 面板的列宽有限，理由写得紧凑；完整说明在鼠标提示里
            why_parts.append("属性待确认" if unsure else ("已验证" if ok else "未验证"))
            if role:
                why_parts.append(f"{role_name(key, role, short=True)} {stats_cn(rule, r['label'])} {value * 100:.0f}%")
            elif basis.get(r["label"]) == "数据":
                why_parts.append("挂价偏贵")
            if c.highlight:
                why_parts.append("好词缀+主属性")
            elif c.premium:
                why_parts.append("好词缀" if strength >= 1 else "好词缀(副)")
            if len(wants) > 1:
                why_parts.append(f"{len(wants)}职业都要")
            if need:
                why_parts.append("圣骑要智力")
            if twink:
                why_parts.append("39级档")
            if role:
                why_parts.append("无替代品" if n_alt == 0 else f"替代{n_alt}件")
            c.reason = " · ".join(why_parts)
            c.stars = stars_for(c.score, rule)
            out.append(c)
    out.sort(key=lambda c: (c.score, c.unit_profit), reverse=True)
    return out


def find_effect_items(rows, s, rule, max_price=None):
    """带特效的绿装里明显便宜的。

    特效装没有后缀可比，所以和"同类型、同部位、相近物品等级"的其他绿装（每件取最低价）比：
    价格不到这组中位价的 effect_max_ratio 才报。目标卖价按中位价的九折估，只是个参考——
    玩家的经验是特效好卖，但这里没有任何成交数据支持具体价位。
    """
    cheapest = {}
    for r in rows:
        k = (r["item_id"], r["level"])
        if k not in cheapest or r["buyout"] < cheapest[k]["buyout"]:
            cheapest[k] = r
    groups = defaultdict(list)
    for r in cheapest.values():
        groups[(r["class_id"], r["subclass_id"], r["equip_loc"], r["level"] // 5)].append(r["buyout"])
    out = []
    for r in cheapest.values():
        if not r.get("effect") or (max_price and r["buyout"] > max_price) or r["level"] < rule.get("min_level", 0):
            continue
        comps = groups[(r["class_id"], r["subclass_id"], r["equip_loc"], r["level"] // 5)]
        if len(comps) < 6:
            continue
        med = median(comps)
        good = any(k in r["effect"] for k in (rule.get("effect_keywords") or []))
        limit = rule.get("effect_premium_ratio", 0.7) if good else rule.get("effect_max_ratio", 0.5)
        if r["buyout"] > med * limit:
            continue
        target = int(med * 0.9)
        profit = strategies.net_after_cut(target, s["ah_cut"]) - r["buyout"]
        if profit < max(s.get("min_unit_profit", 0), rule.get("min_profit", 0)):
            continue
        c = strategies.Candidate(r["item_id"], "EFFECT", r["buyout"], target, profit, profit / r["buyout"],
                                 1 - r["buyout"] / med, 0.0, 0.0)
        c.name, c.suffix_id = r["name"], r["suffix_id"]
        c.notes = [f"特效：{r['effect']}",
                   f"{r['kind']}，物品等级 {r['level']}；同类 {len(comps)} 件的最低价中位 {silver(med)}",
                   "依据：玩家经验（特效好卖）。目标价只是按同类中位价估的，没有成交验证"]
        c.score = round(15 + min(profit, 10000) / 10000 * 30, 1)
        c.premium = good
        if good:
            fx_strength = effect_strength(r["effect"], r["level"])
            fx_bonus = round(rule.get("premium_bonus", 12) * fx_strength, 1)
            c.score = round(c.score + fx_bonus, 1)
            c.notes.insert(0, f"好特效（攻强/法伤/治疗/击中触发）：数值是同等级典型值的 {fx_strength * 100:.0f}%，加 {fx_bonus} 分")
        c.reason = "未验证 · " + ("好特效" if good else "带特效") + f" · 同类中位价的 {r['buyout'] / med * 100:.0f}%"
        c.stars = stars_for(c.score, rule)
        out.append(c)
    out.sort(key=lambda c: (c.score, c.unit_profit), reverse=True)
    return out


def latest_scans(db, n=2):
    db.executescript(SCHEMA)
    return db.execute("SELECT * FROM gear_scans WHERE status='complete' ORDER BY scanned_at DESC LIMIT ?", (n,)).fetchall()
