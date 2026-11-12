"""候选信号生成。这里只回答"值不值得看一眼"，数量和资金由 risk.py 决定。"""
import math
from dataclasses import dataclass, field
from statistics import median


@dataclass
class Candidate:
    item_id: int
    strategy: str
    buy_price: int          # 每件最高买入价（铜）
    target_price: int       # 每件目标挂单价
    unit_profit: int        # 每件预期净利润（已扣抽成）
    roi: float
    discount: float
    sold_per_day: float
    score: float
    notes: list = field(default_factory=list)
    name: str = ""          # 带后缀的完整名称（绿装用）
    suffix_id: int = 0
    highlight: bool = False   # 重点后缀（好词缀叠加主属性）
    premium: bool = False     # 好词缀/好特效（攻强、法伤、治疗、击中触发）
    reason: str = ""          # 一句话理由
    stars: int = 1            # 一到三星


def net_after_cut(price, cut):
    return int(price * (1 - cut))


def liquidity_factor(sold_per_day):
    """0..1，日销 100 件以上视为满分。"""
    return min(1.0, math.log10(1 + max(sold_per_day, 0)) / 2)


def evaluate_flip(q, s):
    """q: quotes 行（dict），s: [strategy] 配置。返回 Candidate 或 None。"""
    price, cur_med = q["min_buyout"], q["median"]
    refs = [x for x in (q["median7d"], q["median30d"]) if x and x > 0]
    if not price or price <= 0 or not cur_med or not refs:
        return None
    ref = min(refs)                      # 保守：取两个历史中位价里较低的
    if q["sold_per_day"] < s["min_sold_per_day"]:
        return None
    if 1 - cur_med / ref > s["max_market_drop"]:
        return None                      # 整个市场都跌了，不是个别挂单便宜
    discount = 1 - price / ref
    if discount < s["min_discount"]:
        return None
    # 卖出目标：不高于当前挂单中位价，也不高于历史参考价，再让 3% 方便成交
    target = int(min(cur_med, ref) * 0.97)
    profit = net_after_cut(target, s["ah_cut"]) - price
    if profit <= 0:
        return None
    roi = profit / price
    if roi < s["min_roi"] or profit < s.get("min_unit_profit", 0):
        return None
    notes = []
    if discount > 0.7:
        notes.append("折扣异常大，可能是数据错误或单件误挂，务必游戏内核价")
    if q["quantity"] and q["quantity"] <= 2:
        notes.append("在售数量很少，价格参考性弱")
    score = 100 * min(roi, 1.0) * liquidity_factor(q["sold_per_day"])
    return Candidate(q["item_id"], "FLIP", price, target, profit, roi, discount,
                     q["sold_per_day"], round(score, 1), notes)


def refine_with_series(c, detail, s):
    """用 7 天序列里的"最低价"复核，这一步是必须的，不通过返回 None。

    买家只买最便宜的那一单，所以一个物品实际能卖出去的价格是它平时的最低价，而不是挂单中位价
    （中位价会被大量挂得离谱、永远卖不掉的单子抬高）。只有当现在的最低价明显低于它自己平时的
    最低价时，才是真的捡漏。
    """
    mins = [x["min"] for x in detail.get("series", []) if x.get("min")]
    if len(mins) < 20:
        return None                       # 历史太短，无法判断
    ref = min(median(mins), median(mins[-24:]))   # 7 天和最近约一天，取较低的
    c.discount = 1 - c.buy_price / ref
    if c.discount < s["min_discount"]:
        return None
    c.target_price = int(ref * 0.97)
    c.unit_profit = net_after_cut(c.target_price, s["ah_cut"]) - c.buy_price
    if c.unit_profit <= 0 or c.unit_profit < s.get("min_unit_profit", 0):
        return None
    c.roi = c.unit_profit / c.buy_price
    if c.roi < s["min_roi"]:
        return None
    c.score = round(100 * min(c.roi, 1.0) * liquidity_factor(c.sold_per_day), 1)
    c.notes = [n for n in c.notes if "折扣异常" not in n]
    c.notes.append(f"平时最低价约 {int(ref)} 铜，现价低 {c.discount*100:.0f}%")
    return c


def evaluate_disenchant(op, s):
    """op: /disenchant 接口里的一条 opportunity。需要附魔专业才能执行。"""
    price, net = op.get("minBuyout"), op.get("netValue")
    if not price or not net or net <= price:
        return None
    profit = net - price
    roi = profit / price
    if roi < s["min_roi"]:
        return None
    notes = ["需要附魔专业；产出是概率期望值", f"材料定价覆盖 {op.get('materialsPriced', '?')}"]
    return Candidate(op["item"]["id"], "DISENCHANT", price, net, profit, roi, 0.0,
                     0.0, round(60 * min(roi, 1.0), 1), notes)


def scan_flips(rows, s):
    """粗筛：最低价明显低于挂单中位价的物品。这只是"值得去查历史"的名单，
    按流动性排序后交给 refine_with_series 用历史最低价做真正的判断。"""
    out = [c for c in (evaluate_flip(dict(r), s) for r in rows) if c]
    out.sort(key=lambda c: c.sold_per_day, reverse=True)
    return out
