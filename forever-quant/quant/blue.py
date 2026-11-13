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
        last = (d.get("latest") or {})
        lmed = int(last.get("median") or 0)              # 此刻全部挂单的中位价：大家现在都挂多少
        items.append(dict(lmed=lmed, item_id=iid, name=g["name"], kind=SUB.get(g["sub"], "武器"), req=g["req"], ilvl=g["ilvl"],
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


def snipe(items, top=20, frac=0.6, min_typ=15000, min_spd=5, watch=()):
    """挑出值得在快扫里盯"超低价单"的蓝色武器：{物品ID: (类别, 买入线, 参照卖价)}。
    只要有真实需求的：平时最低价不太低、每天有人买；按日成交额（价 × 日销）取前 top 把。
      小号 = 比上下 4 级的其它蓝武贵一倍以上（大号给小号买的那种，不在乎价）
      走量 = 其余（练级的人自己买，便宜走得快）
    买入线 = 参照卖价的 frac；参照卖价取"一周最低价中位"、"最近一天"、"此刻全部挂单的中位价"里最低的。挂的时候不高于参照卖价。
    这里的买入线只是粗筛：游戏里查到全部挂单后，还要低于"其它挂单的中位价"的 frac 才算数（见插件 Pool.Judge）。"""
    out = {}
    cand = [it for it in items if it["typ"] >= min_typ and it["spd"] >= min_spd]
    cand.sort(key=lambda it: -it["typ"] * it["spd"])
    picked = cand[:top]
    named = [it for it in items if it["name"] in set(watch)]          # 你点名要重点盯的：不管日销和价位，一律盯
    for it in named + [it for it in picked if it not in named]:
        peers = [x["typ"] for x in items if x is not it and abs(x["req"] - it["req"]) <= 4]
        prem = it["typ"] / statistics.median(peers) if peers else 1
        ref = min(it["typ"], it.get("recent") or it["typ"], it.get("lmed") or it["typ"])      # 再加一条：不高于此刻挂单的中位价（一路跌的货，历史价是虚的）
        out[it["item_id"]] = ("重点" if it in named else ("小号" if prem >= 2 else "走量"), int(ref * frac), ref)
    return out


# ---------------------------------------------------------------------------------------------------------------------
# 按职业的用法给蓝色武器打"需求指数"。面板来自游戏里读到的提示文字（插件存在 SavedVariables 的 blueTips 里）。
# 规则是和玩家一起定的：
#   物理武器先比秒伤（和需求等级上下 3 级、同一大类的绿色武器比）；攻速和白字上限只决定"风格"，风格决定谁要：
#       慢速高白字 —— 双手给圣骑 / 战士 / 萨满，单手给盗贼主手 / 战士；不在乎击中特效
#       快速     —— 匕首给盗贼副手；快武器带击中特效的加分
#   法系的杖和单手：白字不看，必须明确加法伤 / 治疗 / 智力
#   魔杖：只有法系能用，当属性件看加多少属性；练级时魔杖的秒伤也算（攻略里牧师、术士 40 级前靠魔杖输出）
#   弓 / 枪 / 弩：猎人，看秒伤
# 小号（19 / 29 / 39 级战场）毕业名单来自网上的攻略，命中的另外加一星。
TWINK = {1482: "19 级盗贼/战士主手", 1935: "19 级盗贼副手", 12992: "19 级战士/圣骑双手", 890: "19 级法系/萨满双手", 2567: "19 级法系主手",
         935: "19 级术士主手", 1484: "19 级术士双手", 13136: "19 级猎人远程", 8226: "29 级猎人/盗贼主手", 13033: "29 级法师/盗贼主手",
         2912: "29 级萨满/盗贼主手", 776: "29 级盗贼副手", 7752: "29 级战士/圣骑主手", 2299: "29 级萨满双手", 2549: "29 级术士/暗牧双手",
         13063: "29 级法系魔杖", 13048: "29 级德鲁伊主手", 13064: "39 级牧师魔杖", 13138: "39 级猎人远程", 13034: "39 级猎人副手", 9427: "39 级盗贼主手"}
STAT_CN = {"力量": "str", "敏捷": "agi", "耐力": "sta", "智力": "int", "精神": "spi"}


def read_tips(path):
    """SavedVariables 里的 blueTips：{物品ID: 提示文字}。没有返回空。"""
    try:
        t = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    i = t.find('["blueTips"] = {')
    if i < 0:
        return {}
    j = t.find("\n},", i)
    return {int(k): v for k, v in re.findall(r'\[(\d+)\] = "((?:[^"\\]|\\.)*)"', t[i:j if j > 0 else None])}


def parse_tip(text):
    """提示文字 -> 面板字典；不是武器（没有伤害行）返回 None。"""
    m = re.search(r"(\d+) - (\d+)\s*(\S*?)伤害 ~ 速度 ([\d.]+)", text)
    if not m:
        return None
    parts = text.split(" // ")
    slot = next((p for p in parts if " ~ " in p and "伤害" not in p), "? ~ ?")
    hand, typ = [x.strip() for x in slot.split(" ~ ", 1)]
    d = dict(name=parts[0], hand=hand, type=typ, lo=int(m.group(1)), hi=int(m.group(2)), speed=float(m.group(4)), school=m.group(3),
             dps=0.0, req=0, sp=0, heal=0, ap=0, proc="", klass="", str=0, agi=0, sta=0, int=0, spi=0)
    for p in parts:
        mm = re.search(r"每秒伤害([\d.]+)", p)
        if mm:
            d["dps"] = float(mm.group(1))
        mm = re.match(r"\+(\d+) (力量|敏捷|耐力|智力|精神)$", p)
        if mm:
            d[STAT_CN[mm.group(2)]] = int(mm.group(1))
        mm = re.match(r"需要等级 (\d+)", p)
        if mm:
            d["req"] = int(mm.group(1))
        mm = re.match(r"职业：(.+)", p)
        if mm:
            d["klass"] = mm.group(1)
        if p.startswith("击中时可能"):
            d["proc"] = p.split("：", 1)[-1].strip()
        if p.startswith("装备："):
            nums = [int(x) for x in re.findall(r"(\d+)点", p)]
            if "攻击强度" in p and "对" not in p:
                d["ap"] += int(re.search(r"\+(\d+)", p).group(1))
            elif "治疗效果提高最多" in p and "伤害提高最多" in p and len(nums) >= 2:      # 治疗 N，伤害 M
                d["heal"], d["sp"] = max(d["heal"], nums[0]), max(d["sp"], nums[1])
            elif "伤害和治疗效果" in p and nums:
                d["sp"], d["heal"] = max(d["sp"], nums[0]), max(d["heal"], nums[0])
            elif "治疗效果提高" in p and nums:
                d["heal"] = max(d["heal"], nums[0])
            elif "所造成的伤害提高最多" in p and nums:                                      # 单系法伤
                d["sp"] = max(d["sp"], nums[0])
                d["sp_school"] = re.search(r"使(\S+?)法术", p).group(1) if re.search(r"使(\S+?)法术", p) else ""
    return d


def _group(d):
    if d["type"] == "魔杖":
        return "wand"
    if d["hand"] == "远程":
        return "ranged"
    if d["hand"] == "投掷":
        return "thrown"
    return "2h" if d["hand"] == "双手" else "1h"


def classify(tips, gdb):
    """{物品ID: {need 0-3, who 短语, why 完整说明}}，只给蓝色武器算；绿色武器当参照。"""
    parsed = {}
    for iid, text in tips.items():
        d = parse_tip(text)
        g = gdb.get(iid)
        if d and g:
            d["q"], d["grp"] = g["q"], _group(d)
            d["req"] = d["req"] or g["req"]
            parsed[iid] = d
    out = {}
    for iid, d in parsed.items():
        if d["q"] != 3:
            continue
        greens = [x for x in parsed.values() if x["q"] == 2 and x["grp"] == d["grp"] and abs(x["req"] - d["req"]) <= 3]
        gd = sorted(x["dps"] for x in greens)
        adv = (d["dps"] / statistics.median(gd) - 1) if gd else None          # 比同等级段绿武的中位秒伤高多少
        top = (d["dps"] / gd[-1] - 1) if gd else None                         # 比其中最好的高多少
        # 蓝武天生比绿武秒伤高两成，所以不和"中位"比，和同等级段里最好的那把绿武比：高出一成以上才算明显好，持平算一般
        blues = sorted((x["dps"] for x in parsed.values() if x["q"] == 3 and x["grp"] == d["grp"] and abs(x["req"] - d["req"]) <= 3), reverse=True)
        rank = blues.index(d["dps"]) + 1 if d["dps"] in blues else 0
        # 两星 = 比最好的绿武高一成以上，而且在同段蓝武里排前三分之一；一星 = 不输最好的绿武
        tier = 0 if top is None else (2 if top >= 0.10 and rank <= max(1, -(-len(blues) // 3)) else 1 if top >= 0.0 else 0)
        stats_txt = " ".join(f"+{d[k]}{cn}" for cn, k in STAT_CN.items() if d[k]) + (f" 法伤{d['sp']}" if d["sp"] else "") + \
            (f" 治疗{d['heal']}" if d["heal"] and d["heal"] != d["sp"] else "") + (f" 攻强{d['ap']}" if d["ap"] else "")
        cmp_txt = "同等级段没有绿武可比" if adv is None else (
            f"秒伤 {d['dps']:.1f}，比同等级段最好的绿武 {top * 100:+.0f}%（比 {len(gd)} 把绿武的中位 {adv * 100:+.0f}%），在同段 {len(blues)} 把蓝武里排第 {rank}")
        roles = []                                                           # (分数, 谁, 理由)
        caster_stat = d["sp"] or d["heal"]
        grp, typ, spd = d["grp"], d["type"], d["speed"]
        if grp == "wand":
            s = (2 if caster_stat >= 8 or d["int"] + d["sta"] + d["spi"] >= 8 else 1 if caster_stat or d["int"] + d["sta"] + d["spi"] else 0)
            if tier >= 1:
                s += 1
            who = "法系魔杖" + (f"（只有{d['klass']}能用）" if d["klass"] else "")
            roles.append((s, who, "魔杖当属性件看：" + (stats_txt.strip() or "没有附加属性") + "；练级时魔杖秒伤也算：" + cmp_txt))
        elif grp == "ranged":
            roles.append((tier + (1 if tier == 2 and (top or 0) > 0 else 0), "猎人远程", "猎人的输出主要靠远程武器，看秒伤：" + cmp_txt))
        elif grp == "thrown":
            roles.append((0, "投掷", "投掷武器没人专门要"))
        else:
            if caster_stat or d["int"] >= 5 or d["spi"] >= 8:                 # 法系：白字不看（精神多的算牧师的）
                s = 3 if caster_stat >= 20 else 2 if caster_stat >= 8 else 1
                roles.append((s, "法系" + ("双手杖" if grp == "2h" else "主手"), "法系不看白字，看法伤/治疗/智力：" + stats_txt.strip()))
            if grp == "2h" and typ != "法杖":
                slow = spd >= 3.2
                s = tier + (1 if slow and tier >= 1 else 0)
                who = {"锤": "圣骑/萨满/战士双手", "斧": "战士/萨满/猎人双手", "剑": "战士/圣骑/猎人双手", "长柄武器": "战士/猎人双手"}.get(typ, "双手近战")
                roles.append((s, who, f"{'慢速' if slow else '偏快'}（{spd:.1f} 秒）白字上限 {d['hi']}；{cmp_txt}" + ("；慢速双手正是圣骑/战士要的" if slow else "；速度不够慢，白字上限吃亏")))
            if grp == "2h" and typ == "法杖" and not caster_stat and (d["agi"] or d["str"]):
                roles.append((1, "野德/猎人属性棒", "变形后不吃武器面板，只看属性：" + stats_txt.strip()))
            if grp == "1h" and typ != "匕首":
                slow = spd >= 2.4
                rogue_ok = typ in ("剑", "锤", "拳套")
                s = tier + (1 if slow and tier >= 1 else 0)
                who = ("盗贼主手/战士" if rogue_ok else "战士/萨满/猎人") + "单手"
                roles.append((s, who, f"{'慢速' if slow else '偏快'}（{spd:.1f} 秒）白字上限 {d['hi']}；{cmp_txt}" + ("；慢速高白字适合当主手" if slow else "")))
            if typ == "匕首":
                fast = spd <= 1.6
                s = tier + (1 if fast and d["proc"] else 0) + (1 if not fast and spd >= 1.8 and tier >= 1 else 0)
                who = "盗贼副手匕首" if fast else "匕首贼主手"
                roles.append((s, who, f"{'快' if fast else '慢'}匕首（{spd:.1f} 秒）；{cmp_txt}" + ("；快武器带击中特效，加分" if fast and d["proc"] else "")))
        roles.sort(key=lambda r: -r[0])
        best = roles[0] if roles else (0, "?", "")
        need = min(3, best[0])
        who = best[1]
        why = [f"{d['name']}（{d['hand']}{typ}，需要 {d['req']} 级）：{d['lo']}-{d['hi']} 伤害，速度 {spd:.2f}，秒伤 {d['dps']:.1f}" + (f"，{stats_txt.strip()}" if stats_txt.strip() else "")]
        if d["proc"]:
            why.append("击中特效：" + d["proc"][:60])
        for s, w, t in roles:
            why.append(f"{'★' * min(3, s) or '☆'} {w}：{t}")
        if iid in TWINK:
            need = min(3, need + 1)
            who += " · " + TWINK[iid].split(" ")[0] + "小号"
            why.append(f"小号毕业名单：{TWINK[iid]}（网上的攻略里点名，买家是大号带的，不在乎价）")
        out[iid] = dict(need=need, who=who, why="\n".join(why))
    return out
