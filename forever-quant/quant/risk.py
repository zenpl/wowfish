"""资金管理：把候选变成带数量的建议，受本金、储备、单品和单笔上限约束。"""
from dataclasses import dataclass


@dataclass
class Order:
    cand: object
    quantity: int
    cost: int
    expected_profit: int


def allocate(cands, cfg, holdings=None, realized=0):
    """cands 需已按优先级排好。holdings: {item_id: 持仓成本}。"""
    cap, s = cfg["capital"], cfg["strategy"]
    holdings = holdings or {}
    equity = cap["total"] + realized
    budget = int(equity * (1 - cap["reserve_pct"])) - sum(holdings.values())
    orders = []
    for c in cands:
        if budget < c.buy_price:
            continue
        room = cap["max_per_item"] - holdings.get(c.item_id, 0)
        limits = [cap["max_per_trade"] // c.buy_price, room // c.buy_price, budget // c.buy_price]
        if c.strategy == "FLIP":
            limits.append(max(1, int(c.sold_per_day * s["max_days_of_volume"])))
        else:
            limits.append(1)            # 装备类一次只建议一件
        qty = min(limits)
        if qty < 1:
            continue
        profit = qty * c.unit_profit
        if profit < s["min_profit"]:
            continue
        cost = qty * c.buy_price
        orders.append(Order(c, qty, cost, profit))
        budget -= cost
        holdings[c.item_id] = holdings.get(c.item_id, 0) + cost
    return orders, budget
