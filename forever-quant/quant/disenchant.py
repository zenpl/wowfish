"""绿装分解套利：拍卖行买便宜绿装 -> 分解 -> 卖材料。

产出表是经典旧世的绿色装备分解表，按物品等级每 5 级一档。其中 26-34、41-55、60 级护甲和
23、41、46-50 级武器这几档已经和行情源（AHledger）给出的逐件产出核对一致，其余档位按同一张表填写。
每次分解只出其中一种材料，这里算的是大量分解的平均值，单次结果是随机的。

重要局限：这张表不知道哪些物品不能分解。强效魔法杖（11288）就是不能分解的，而行情源和这张表
都把它算成了机会；当初"核对 23 级武器档"用的那条数据恰好就是它，所以那一档其实没有被独立验证过。
不能分解的物品靠 config.toml 的 [disenchant] not_disenchantable 排除。
"""
from collections import defaultdict

from . import strategies

# 材料物品 ID
STRANGE, SOUL, VISION, DREAM, ILLUSION = 10940, 11083, 11137, 11176, 16204
L_MAGIC, G_MAGIC, L_ASTRAL, G_ASTRAL = 10938, 10939, 10998, 11082
L_MYSTIC, G_MYSTIC, L_NETHER, G_NETHER = 11134, 11135, 11174, 11175
L_ETERNAL, G_ETERNAL = 16202, 16203
S_GLIMMER, L_GLIMMER, S_GLOW, L_GLOW = 10978, 11084, 11138, 11139
S_RADIANT, L_RADIANT, S_BRILLIANT, L_BRILLIANT = 11177, 11178, 14343, 14344
MATERIAL_IDS = [STRANGE, SOUL, VISION, DREAM, ILLUSION, L_MAGIC, G_MAGIC, L_ASTRAL, G_ASTRAL, L_MYSTIC, G_MYSTIC,
                L_NETHER, G_NETHER, L_ETERNAL, G_ETERNAL, S_GLIMMER, L_GLIMMER, S_GLOW, L_GLOW, S_RADIANT, L_RADIANT,
                S_BRILLIANT, L_BRILLIANT]

# (最低物品等级, 最高, 尘, 尘数量, 精华, 精华数量, 碎片, 护甲概率(尘,精华,碎片), 武器概率(尘,精华,碎片))
BRACKETS = [
    (5, 15, STRANGE, (1, 2), L_MAGIC, (1, 2), None, (0.80, 0.20, 0.0), (0.20, 0.80, 0.0)),
    (16, 20, STRANGE, (2, 3), G_MAGIC, (1, 2), S_GLIMMER, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (21, 25, STRANGE, (4, 6), L_ASTRAL, (1, 2), S_GLIMMER, (0.75, 0.15, 0.10), (0.15, 0.75, 0.10)),
    (26, 30, SOUL, (1, 2), G_ASTRAL, (1, 2), L_GLIMMER, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (31, 35, SOUL, (2, 5), L_MYSTIC, (1, 2), S_GLOW, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (36, 40, VISION, (1, 2), G_MYSTIC, (1, 2), L_GLOW, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (41, 45, VISION, (2, 5), L_NETHER, (1, 2), S_RADIANT, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (46, 50, DREAM, (1, 2), G_NETHER, (1, 2), L_RADIANT, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (51, 55, DREAM, (2, 5), L_ETERNAL, (1, 2), S_BRILLIANT, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (56, 60, ILLUSION, (1, 2), G_ETERNAL, (1, 2), L_BRILLIANT, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
    (61, 65, ILLUSION, (2, 5), G_ETERNAL, (2, 3), L_BRILLIANT, (0.75, 0.20, 0.05), (0.20, 0.75, 0.05)),
]


def yields(class_id, ilvl):
    """返回 [(材料ID, 概率, 平均数量)]；不在表里（等级太低/太高或不是武器护甲）返回 None。"""
    if class_id not in (2, 4):
        return None
    for lo, hi, dust, dq, ess, eq, shard, armor_p, weapon_p in BRACKETS:
        if lo <= ilvl <= hi:
            p = weapon_p if class_id == 2 else armor_p
            out = [(dust, p[0], sum(dq) / 2), (ess, p[1], sum(eq) / 2)]
            if shard and p[2] > 0:
                out.append((shard, p[2], 1.0))
            return out
    return None


def bracket_of(ilvl):
    for b in BRACKETS:
        if b[0] <= ilvl <= b[1]:
            return f"{b[0]}-{b[1]}"
    return None


def expected(ys, mats, s, min_sold_per_day=5.0):
    """分解一件的期望到手铜币（材料按当前最低价再让 3% 卖出，扣拍卖行抽成）。

    mats: {材料ID: {price, sold_per_day, name}}。卖不动的材料（日销低于阈值）按 0 算，
    因为挂上去也换不成钱。返回 (净值, 主要材料名, 被按 0 算的材料名列表)。
    """
    total, dead, best = 0.0, [], (0, "")
    for mid, chance, qty in ys:
        m = mats.get(mid)
        if not m or not m.get("price"):
            dead.append((m or {}).get("name") or f"材料{mid}")
            continue
        if (m.get("sold_per_day") or 0) < min_sold_per_day:
            dead.append(m["name"])
            continue
        v = chance * qty * strategies.net_after_cut(int(m["price"] * 0.97), s["ah_cut"])
        total += v
        if v > best[0]:
            best = (v, m["name"])
    return int(total), best[1], dead


def scan(rows, mats, s, min_profit=None, min_roi=None, excluded=(), verified=()):
    """rows: gear.load() 的绿装行情。返回 (机会列表, 每档保本价表, 每档统计)。

    同一件装备只看最便宜的那个后缀：分解不看后缀。
    excluded: 已知不能分解的物品 ID，直接跳过。verified: 实测能分解的物品 ID。
    分解表只按物品等级算期望，不知道游戏里哪些物品被标记为无法分解——没在 verified 里的
    机会一律带 verified=False，买之前必须先拿一件试。
    """
    excluded, verified = set(excluded), set(verified)
    min_profit = s.get("min_unit_profit", 0) if min_profit is None else min_profit
    min_roi = s["min_roi"] if min_roi is None else min_roi
    cheapest = {}
    for r in rows:
        k = (r["item_id"], r["level"])
        if k not in cheapest or r["buyout"] < cheapest[k]["buyout"]:
            cheapest[k] = r
    out, table = [], {}
    stats = defaultdict(lambda: [0, 0])
    for r in cheapest.values():
        if r["item_id"] in excluded:
            continue
        ys = yields(r["class_id"], r["level"])
        if not ys:
            continue
        net, main, dead = expected(ys, mats, s)
        kind = "武器" if r["class_id"] == 2 else "护甲"
        key = (kind, bracket_of(r["level"]))
        table[key] = (net, main, dead)
        stats[key][1] += 1
        profit = net - r["buyout"]
        if net <= 0 or profit < min_profit or profit / r["buyout"] < min_roi:
            continue
        stats[key][0] += 1
        out.append(dict(item_id=r["item_id"], suffix_id=r["suffix_id"], name=r["name"], level=r["level"], kind=kind,
                        price=r["buyout"], quantity=r["count"], net=net, profit=profit, roi=profit / r["buyout"],
                        main=main, dead=dead, bracket=key[1], verified=r["item_id"] in verified))
    out.sort(key=lambda o: -o["profit"])
    return out, table, {k: tuple(v) for k, v in stats.items()}
