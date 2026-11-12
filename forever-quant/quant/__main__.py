"""命令行入口:  python -m quant <命令>

  run        拉行情 + 生成建议 + 写入插件（日常用这一个）
  collect    只拉行情
  scan       只用库里最新行情生成建议
  gear       分析游戏内 /fq scan 扫到的随机后缀绿装（找错标的热门后缀）
  auto       一直开着：游戏里点「扫描拍卖行」并存盘后，自动分析并写回插件
  watch      只更新固定监控项（强效魔法杖这类买来分解的批量货源），不需要重新扫描
  show       显示最近一次建议
  buy / sell / writeoff / trades    记录和查看真实交易
  report     真实交易的绩效
  review     历史信号复盘（代理指标）
  install    把插件链接到游戏的 AddOns 目录
"""
import argparse
import os
import sys
import time
from pathlib import Path

from . import backtest, collector, config, database, disenchant, export_lua, gear, questiedb, risk, strategies, tod, watch
from .config import gold


def _ts(t):
    return time.strftime("%m-%d %H:%M", time.localtime(t))


def holdings(db):
    return {r["item_id"]: r["c"] for r in db.execute(
        "SELECT item_id, SUM(cost) c FROM trades WHERE status='HOLDING' GROUP BY item_id")}


def realized(db):
    r = db.execute("SELECT COALESCE(SUM(COALESCE(proceeds,0)-cost-fees),0) p FROM trades "
                   "WHERE status IN ('SOLD','WRITTEN_OFF')").fetchone()
    return r["p"]


def cmd_collect(cfg, db, a):
    sid, msg = collector.collect(cfg, db, force=a.force)
    print(msg)
    return sid


def cmd_scan(cfg, db, a):
    s, market = cfg["strategy"], cfg["market"]["id"]
    snap = database.latest_snapshot(db, market)
    if not snap:
        sys.exit("库里还没有行情，先运行 collect")
    age_h = (time.time() - snap["captured_at"]) / 3600
    print(f"市场 {market}，行情时间 {_ts(snap['captured_at'])}（{age_h:.1f} 小时前）")
    if age_h > s["max_snapshot_age_hours"]:
        print(f"行情超过 {s['max_snapshot_age_hours']} 小时，太旧，不出信号。")
        return
    rows = db.execute("SELECT * FROM quotes WHERE snapshot_id=?", (snap["id"],)).fetchall()
    cands = strategies.scan_flips(rows, s)
    max_px = cfg["capital"]["max_per_trade"]
    cands = [c for c in cands if c.buy_price <= max_px]     # 买不起的不用查
    print(f"{len(rows)} 个物品中粗筛出 {len(cands)} 个买得起的候选", end="")
    top, refined = cands[: cfg["api"]["detail_top_n"]], []
    if not a.offline:
        print(f"，对日销最高的 {len(top)} 个用历史最低价复核……")
        for c in top:
            try:
                d = collector.fetch_detail(cfg, db, c.item_id)
                c = strategies.refine_with_series(c, d, s)
            except Exception as e:           # 单个物品失败不影响整体；没复核过的不出
                print(f"  明细拉取失败 item {c.item_id}: {e}")
                c = None
            if c:
                refined.append(c)
            time.sleep(0.4)
        if a.disenchant:
            try:
                for op in collector.fetch_disenchant(cfg).get("opportunities", []):
                    c = strategies.evaluate_disenchant(op, s)
                    if c:
                        db.execute("INSERT INTO items(item_id,name,quality) VALUES(?,?,?) "
                                   "ON CONFLICT(item_id) DO UPDATE SET name=excluded.name",
                                   (c.item_id, op["item"].get("name"), op["item"].get("quality")))
                        refined.append(c)
            except Exception as e:
                print(f"拆解数据拉取失败: {e}")
    else:
        print("\n离线模式无法用历史最低价复核，粗筛结果不可靠，不出建议。")
        refined = []
    refined.sort(key=lambda c: c.score, reverse=True)
    orders, left = risk.allocate(refined, cfg, holdings(db), realized(db))
    now = int(time.time())
    db.execute("DELETE FROM signals WHERE snapshot_id=?", (snap["id"],))
    for o in orders:
        c = o.cand
        db.execute("INSERT OR REPLACE INTO signals(snapshot_id,item_id,generated_at,strategy,buy_price,"
                   "target_price,max_quantity,expected_profit,score) VALUES(?,?,?,?,?,?,?,?,?)",
                   (snap["id"], c.item_id, now, c.strategy, c.buy_price, c.target_price,
                    o.quantity, o.expected_profit, c.score))
    db.commit()
    names = {o.cand.item_id: database.item_name(db, o.cand.item_id) for o in orders}
    path = export_lua.export(orders, names, market, now, snap["captured_at"])
    print_orders(orders, names, left)
    print(f"\n已写入插件数据: {path}\n游戏里 /reload 后输入 /fq 查看。买之前必须在拍卖行核对实时价格。")
    print("Prices from AHledger — https://ahledger.com")


def print_orders(orders, names, left=None, criteria=None):
    if not orders:
        print("\n这次没有通过全部过滤条件的机会。这很正常，不要为了交易而放宽条件。")
        print(criteria or "（判断标准：现在的最低价要比该物品自己平时的最低价低 20% 以上，且扣完抽成每件净赚 1 银以上。）")
        return
    print(f"\n{'#':>2} {'星级':<4} {'物品':<28} {'最高买价':>11} {'目标卖价':>11} {'最多买':>4} {'每件净利':>10} {'利润上限':>11} {'ROI':>5} {'日销':>6} {'分':>5}")
    for i, o in enumerate(orders, 1):
        c = o.cand
        is_gear = c.strategy in ("GEAR", "EFFECT")
        stars = "★" * getattr(c, "stars", 0) if is_gear else c.strategy[:5]
        m = config.silver if is_gear else gold            # 装备按银计价，舍掉铜的零头
        print(f"{i:>2} {stars:<6} {(c.name or names[c.item_id])[:28]:<30} {m(c.buy_price):>12} {m(c.target_price):>12} "
              f"{o.quantity:>5} {m(c.unit_profit):>11} {m(o.expected_profit):>12} {c.roi*100:>4.0f}% {c.sold_per_day:>6.1f} {c.score:>5.1f}")
        if getattr(c, "reason", ""):
            print(f"      理由：{c.reason}")
        for n in c.notes:
            print(f"      ! {n}")
    cost = sum(o.cost for o in orders)
    print(f"\n若全部按最高买价买满：占用 {gold(cost)}，利润上限 {gold(sum(o.expected_profit for o in orders))}"
          + (f"，剩余可用预算 {gold(left)}" if left is not None else ""))
    print("注意：数据源只给最低价，不给这个价位有多少件。'最多买'是资金和销量允许的上限，"
          "实际能按此价买到的往往只有一两件，利润上限通常达不到。")


def cmd_gear(cfg, db, a):
    path = Path(a.file) if a.file else gear.find_saved_variables(cfg)
    if not path or not path.exists():
        sys.exit("找不到插件存盘文件。先在游戏里打开拍卖行输入 /fq scan，扫完后 /reload。")
    added = gear.import_scans(db, gear.parse_scans(gear.parse_log(path.read_text(encoding="utf-8", errors="replace"))))
    print(f"读取 {path.name}（{_ts(path.stat().st_mtime)} 存盘），新导入 {added} 次扫描")
    gear.learn_suffix_labels(db)
    scans = gear.latest_scans(db, 20)
    if not scans:
        sys.exit("库里没有完整的扫描。")
    cur = scans[0]
    rows = gear.load(db, cur["id"])
    age_h = (time.time() - cur["scanned_at"]) / 3600
    suffixed = [r for r in rows if r["label"]]
    print(f"最新扫描 {_ts(cur['scanned_at'])}（{age_h:.1f} 小时前）：{len(rows)} 条有一口价的绿装挂单，其中带后缀 {len(suffixed)} 条")
    prem = gear.suffix_premium(rows)
    sold = None
    older = [s for s in scans[1:] if cur["scanned_at"] - s["scanned_at"] >= 1800]
    if older:
        gap = cur["scanned_at"] - older[0]["scanned_at"]
        sold = gear.sell_through(gear.load(db, older[0]["id"]), rows, gap)
        print(f"和 {gap/3600:.1f} 小时前的扫描对比，得到走货数据（在售减少量，含过期和撤单）")
    else:
        print("还没有相隔 30 分钟以上的两次扫描：能看挂价分布，还看不出哪些后缀真的卖得动。隔 1~3 小时再扫一次。")
    print("\n各后缀的挂价溢价（单子价格 ÷ 同一件装备所有后缀的中位价；样本 ≥ 8）")
    table = sorted(((k, v) for k, v in prem.items() if v[1] >= 8), key=lambda kv: -kv[1][0])
    shown = table if len(table) <= 30 else table[:18] + [None] + table[-10:]
    for entry in shown:
        if entry is None:
            print("   …"); continue
        (kd, label), (m, n) = entry
        st = (sold or {}).get((kd, label))
        extra = f"  在售减少 {st[0]}/{st[1]}" if st and st[1] else ""
        print(f"   {kd:<4} {label:<22} ×{m:>4.2f}  ({n} 单){extra}")
    hits, checked, unknown = gear.vendor_arbitrage(db, cur["id"])
    print("\n低于商人收购价的挂单（买来直接卖店，不用再上拍卖行）")
    if checked is None:
        print("   这次扫描没有做商人价比对（旧版插件扫的）。")
    else:
        print(f"   比对了 {checked} 条全品类行情" + (f"，另有 {unknown} 条查不到商人价" if unknown else "")
              + f"，低于收购价的 {len(hits)} 条" + ("：" if hits else "。"))
        for h in hits[:a.top]:
            print(f"   {h['name'][:26]:<28} 最低 {gold(h['min_price']):>10} | 商人收 {gold(h['vendor_price']):>10} | "
                  f"每件赚 {gold(h['profit']):>9} | 该物品在售 {h['quantity']} 件")
        if hits:
            print("   注意：只能确定这个价位至少有 1 件；买之前在拍卖行确认一口价，并确认物品能卖给商人。")
    spd = {}
    snap = database.latest_snapshot(db, cfg["market"]["id"])
    if snap:
        spd = {r["item_id"]: r["sold_per_day"] for r in db.execute(
            "SELECT item_id, sold_per_day FROM quotes WHERE snapshot_id=?", (snap["id"],))}
    vdb = None
    try:
        if questiedb.toc_path(cfg).exists():
            vdb = questiedb.VendorDB(cfg)
    except Exception as e:
        print(f"读取 QuestieDB 失败（{e}），无法判断哪些配方商人有卖")
    faction = "A" if "alliance" in cfg["market"]["id"] else "H"
    all_recs = gear.recipe_resale(db, cur["id"], cfg["strategy"], spd, vendor_db=vdb, faction=faction)
    n_rec = db.execute("SELECT COUNT(*) c FROM recipes WHERE scan_id=?", (cur["id"],)).fetchone()["c"]
    recs = [r for r in all_recs if r["source"] == "vendor"] if vdb else all_recs
    n_none = sum(1 for r in all_recs if r["source"] == "none")
    n_unk = sum(1 for r in all_recs if r["source"] == "unknown")
    print(f"\n配方倒卖（商人买 → 拍卖行卖）：在售配方 {n_rec} 种，拍卖行价明显高于估算商人卖价的 {len(all_recs)} 种")
    if vdb:
        print(f"   按本机 QuestieDB 核对：本阵营商人有卖 {len(recs)} 种；没有商人卖（掉落/制造）{n_none} 种，已剔除；数据库里查不到 {n_unk} 种，已剔除。")
    if recs:
        print("   进价按「商人收购价 x4」估算，以商人实际卖价为准；部分配方商人限量，卖完要等补货。")
        print(f"   {'配方':<28}{'专业':<5}{'估算进价':>10}{'拍卖最低':>10}{'每张净赚':>10}{'在售':>5}{'日销':>7}  去哪买")
        for r in recs[:a.top]:
            sp = f"{r['sold_per_day']:.1f}" if r["sold_per_day"] is not None else "?"
            print(f"   {r['name'][:26]:<28}{r['profession']:<5}{gold(r['cost']):>11}{gold(r['min_price']):>11}{gold(r['net']):>11}{r['quantity']:>5}{sp:>7}  {r['vendors']}")
    de_ops, de_export = [], None
    try:
        mats, mats_at = collector.fetch_materials(cfg)
        de_export = dict(brackets=disenchant.BRACKETS, mats=mats,
                         excluded=(cfg.get("disenchant") or {}).get("not_disenchantable") or [],
                         verified=(cfg.get("disenchant") or {}).get("verified") or [])
        de_cfg = cfg.get("disenchant") or {}
        de_ops, de_table, de_stats = disenchant.scan(rows, mats, cfg["strategy"],
                                                     excluded=de_cfg.get("not_disenchantable") or [],
                                                     verified=de_cfg.get("verified") or [])
        print(f"\n分解套利（买绿装 → 分解 → 卖材料；需要附魔专业）：材料行情 {mats_at}")
        print("   每档的分解期望净值 = 买入价低于它才不亏（材料按当前最低价让 3% 卖，已扣 5% 抽成；卖不动的材料按 0 算）")
        print(f"   {'类型':<4}{'物品等级':<8}{'期望净值':>10}  {'主要来源':<14}{'划算/在售':>10}  卖不动的材料")
        for (kd, br), (net, main, dead) in sorted(de_table.items(), key=lambda kv: (kv[0][0], int(kv[0][1].split('-')[0]))):
            ok, total = de_stats.get((kd, br), (0, 0))
            print(f"   {kd:<4}{br:<10}{gold(net):>11}  {main:<16}{ok:>5}/{total:<5} {'、'.join(dead)}")
        print(f"   划算的（每件净赚 ≥ {gold(cfg['strategy'].get('min_unit_profit', 0))} 且利润率 ≥ {cfg['strategy']['min_roi']*100:.0f}%）共 {len(de_ops)} 件" + ("，前几名：" if de_ops else "。"))
        for o in de_ops[:a.top]:
            tag = "已实测" if o["verified"] else "未验证能否分解"
            print(f"   {o['name'][:24]:<26} {o['kind']} 等级{o['level']:<3} 买 {gold(o['price']):>10} | 期望到手 {gold(o['net']):>10} | 净赚 {gold(o['profit']):>10} | 在售 {o['quantity']:<4} [{tag}]")
        if de_ops:
            print("   重要：有些物品游戏不允许分解（例如附魔师做的魔杖），这张表分辨不出来。标着「未验证」的，")
            print("   先只买一件试；确认能分解后把物品 ID 加进 config.toml 的 [disenchant] verified，不能分解就加进 not_disenchantable。")
            print("   期望值是大量分解的平均，单次结果随机。")
    except Exception as e:
        print(f"\n分解套利：拿不到材料行情（{e}），跳过。")
    watches = run_watch(cfg, db, rows)
    rule = cfg.get("gear_rule")
    if rule:
        cands = gear.find_by_rule(rows, cfg["strategy"], rule, sold, max_price=cfg["capital"]["max_per_trade"], prem=prem)
        print("\n按规则推出的热门后缀（常识 = 输出优先；数据 = 挂价明显偏贵）：")
        for key, kind_name in (("leather", "皮甲"), ("cloth", "布甲"), ("mail", "锁甲"), ("weapon", "武器"), ("jewelry_cloak", "首饰披风")):
            hs = gear.hot_suffixes(rule, key, prem)
            by_basis = {}
            for label, why in hs.items():
                by_basis.setdefault(why, []).append(label[:-1] if label.endswith("之") else label)
            print(f"   {kind_name}: " + "；".join(f"{why}：{'、'.join(sorted(v))}" for why, v in sorted(by_basis.items())))
        stars = {kn: sorted(l[:-1] for l in (rule.get("suffix_stats") or {}) if gear.suffix_value(rule, k, l)[1] and l not in (rule.get("ignore") or []))
                 for k, kn in (("leather", "皮甲"), ("cloth", "布甲"), ("mail", "锁甲"))}
        print("   ★ 重点（同一角色最想要的属性占两个）：" + "；".join(f"{kn}：{'、'.join(v) or '无'}" for kn, v in stars.items())
              + "。不追踪：" + "、".join(rule.get("ignore") or []))
        effects = gear.find_effect_items(rows, cfg["strategy"], rule, max_price=cfg["capital"]["max_per_trade"])
        n_fx = sum(1 for r in rows if r.get("effect"))
        print(f"\n带特效的绿装：扫描里有 {n_fx} 条带特效文字" + ("（这次扫描是旧版插件做的，没有记特效；重扫一次才有）" if not n_fx else f"，其中明显便宜的 {len(effects)} 件"))
        cands = sorted(cands + effects, key=lambda c: (c.score, c.unit_profit), reverse=True)
        criteria = "（规则：热门后缀挂在这件装备的地板价附近，而同一件装备上别的热门后缀贵 3 倍以上；目标卖价 = 其中最便宜的再让 5%。）"
    else:
        cands = gear.find_mispriced(rows, cfg["strategy"], prem, sold)
        criteria = "（判断标准：后缀属于挂价偏高的那类，且这一单的价格不到同类型、同部位、同后缀、相近等级单子下四分位价的一半。）"
    if age_h > cfg["strategy"]["max_snapshot_age_hours"]:
        print(f"\n扫描已超过 {cfg['strategy']['max_snapshot_age_hours']} 小时，便宜单多半已被买走，不出绿装建议。")
        cands = []
    orders, left = risk.allocate(cands, cfg, holdings(db), realized(db))
    names = {o.cand.item_id: o.cand.name for o in orders}
    print(f"\n绿装后缀错标：符合规则的 {len(cands)} 条，按本金约束选出 {len(orders)} 条")
    print_orders(orders[:a.top], names, left, criteria)
    rule_export = None
    if rule:
        rule_export = dict(
            max_level=rule.get("max_level", 34), floor_ratio=rule.get("floor_ratio", 1.3), min_gap=rule.get("min_gap", 3.0),
            twink_min_req=rule.get("twink_min_req", 0), twink_max_req=rule.get("twink_max_req", -1),
            max_price=cfg["capital"]["max_per_trade"], min_level=rule.get("min_level", 0),
            min_unit_profit=max(cfg["strategy"].get("min_unit_profit", 0), rule.get("min_profit", 0)),
            effect_max_ratio=rule.get("effect_max_ratio", 0.5), min_roi=cfg["strategy"]["min_roi"],
            twink_extra=[x for x in (rule.get("twink_extra") or []) if x not in (rule.get("ignore") or [])],
            uncertain=rule.get("uncertain") or [], confirmed=rule.get("confirmed") or [],
            highlight_bonus=rule.get("highlight_bonus", 15), hot_min_value=rule.get("hot_min_value", 0.5), comp_margin=rule.get("comp_margin", 0.15),
            alt_level_range=rule.get("alt_level_range", 3), scarcity_bonus=rule.get("scarcity_bonus", 10),
            premium_bonus=rule.get("premium_bonus", 12), effect_premium_ratio=rule.get("effect_premium_ratio", 0.7),
            effect_keywords=rule.get("effect_keywords") or [], tier={}, need={}, need_bonus=rule.get("need_bonus", 5),
            multi={}, multi_note={}, multi_n={}, role_short={}, premium_full_level=rule.get("premium_full_level", 34),
            nstats={l: len(v) for l, v in (rule.get("suffix_stats") or {}).items()}, stars_3=rule.get("stars_3", 85), stars_2=rule.get("stars_2", 55),
            stats_cn={l: gear.stats_cn(rule, l) for l in (rule.get("suffix_stats") or {})},
            hot={k: gear.hot_suffixes(rule, k, prem) for k in ("leather", "cloth", "mail", "weapon", "jewelry_cloak")},
            value={}, star={}, role={}, ok={}, role_key={}, role_value={},
            stats=rule.get("suffix_stats") or {})
    if rule_export:
        labels = set(rule.get("suffix_stats") or {})
        for k in rule_export["hot"]:
            sv = {l: gear.suffix_value(rule, k, l) for l in labels}
            rule_export["value"][k] = {l: v[0] for l, v in sv.items() if v[2]}
            rule_export["star"][k] = {l: True for l, v in sv.items() if v[1]}
            rule_export["role"][k] = {l: gear.ROLE_NAME.get(v[2], v[2]) for l, v in sv.items() if v[2]}
            rule_export["ok"][k] = {l: True for l in labels if gear.is_confirmed(rule, k, l)}
            rule_export["role_key"][k] = {l: v[2] for l, v in sv.items() if v[2]}
            rule_export["role_short"][k] = {l: gear.ROLE_SHORT.get(v[2], v[2]) for l, v in sv.items() if v[2]}
            # 好词缀的需求强度（1 = 主属性级别，小于 1 = 副属性级别）
            rule_export["tier"][k] = {l: gear.premium_strength(rule, k, l) for l in labels if gear.is_premium(rule, k, l)}
            # 多职业需求：加分数和说明文字都在这里算好，插件直接用
            rule_export["multi"][k], rule_export["multi_note"][k], rule_export["multi_n"][k] = {}, {}, {}
            for l in labels:
                index, wants = gear.demand_index(rule, k, l)
                if len(wants) > 1:
                    rule_export["multi"][k][l] = round(min(rule.get("multi_role_cap", 15),
                                                           rule.get("multi_role_bonus", 10) * sum(v for _, v in wants[1:])), 1)
                    rule_export["multi_n"][k][l] = len(wants)
                    rule_export["multi_note"][k][l] = f"多职业需求（指数 {index:.2f}）：" + "、".join(
                        f"{gear.ROLE_NAME.get(ro, ro)} {v * 100:.0f}%" for ro, v in wants)
            # 特定需求属性：导出成字符串（比如 "int"），插件里用它判断替代品是否也带
            rule_export["need"][k] = {l: "+".join(sorted(gear.needed_stats(rule, k, l))) for l in labels if gear.needed_stats(rule, k, l)}
        for role in (rule.get("roles") or {}):          # 每个职业下各后缀的价值：找替代品时要按同一个职业比
            rule_export["role_value"][role] = {l: gear.role_value(rule, role, l)[0] for l in labels}
    # 面板里给全部候选（最多 200 条），本金内的排前面并打标记，方便切换"只看本金内 / 显示全部"
    chosen = {id(o.cand) for o in orders}
    extra = [risk.Order(c, 1, c.buy_price, c.unit_profit) for c in cands if id(c) not in chosen]
    for o in orders:
        o.cand.affordable = True
    all_orders = (orders + extra)[:200]
    names.update({o.cand.item_id: o.cand.name for o in extra})
    path = export_lua.export(all_orders, names, cfg["market"]["id"], int(time.time()), cur["scanned_at"],
                             recipes=recs, ah_cut=cfg["strategy"]["ah_cut"], disenchant=de_ops[:200], watch=watches,
                             rule=rule_export, de=de_export, tod=_tod(cfg, db, snap),
                             prices={i: q for i, q in db.execute(
                                 "SELECT item_id, min_buyout FROM quotes WHERE snapshot_id=? AND min_buyout>0 AND sold_per_day>=1",
                                 (snap["id"],))} if snap else None)
    print(f"\n已写入插件数据：绿装 {len(all_orders)} 条（本金内 {len(orders)} 条），配方 {len(recs)} 种。游戏里 /reload 后 /fq 查看。")


def run_watch(cfg, db, rows=None, quiet=False):
    """算所有固定监控项并打印。rows: 最新游戏内扫描的绿装行（没有就自己读）。返回结果列表。"""
    ids = (cfg.get("watch") or {}).get("disenchant_items") or []
    if not ids:
        return []
    if rows is None:
        scans = gear.latest_scans(db, 1)
        rows = gear.load(db, scans[0]["id"]) if scans else []
    by_item = {}
    for r in rows:                       # 同一物品取最便宜的一行
        if r["item_id"] not in by_item or r["buyout"] < by_item[r["item_id"]]["buyout"]:
            by_item[r["item_id"]] = r
    try:
        mats = collector.fetch_materials(cfg)[0]
    except Exception as e:
        print(f"\n固定监控：拿不到材料行情（{e}），跳过。")
        return []
    out = []
    print("\n固定监控（买来分解）")
    for iid in ids:
        try:
            hist = watch.history(db, iid)
            w = watch.evaluate(cfg, db, iid, by_item.get(iid), mats=mats)
        except Exception as e:
            print(f"   物品 {iid}: {e}")
            continue
        tr = watch.trend(hist, w)
        watch.record(db, w)
        out.append(w)
        mark = {"可以做": "✔", "利润太薄": "△", "停": "✘"}[w["verdict"]]
        print(f"   {mark} {w['name']}（{'武器' if w['class_id'] == 2 else '护甲'} 等级 {w['level']}）—— {w['verdict']}：{w['why']}")
        print(f"      货源：最低 {gold(w['min_price'])}，约四分之一的货在 {gold(w['p25_price'])} 以下，大多数挂 {gold(w['wall_price'])}；"
              f"在售 {w['quantity']} 件（{w['source']}）" + (f"，估计日销 {w['sold_per_day']:.0f}" if w["sold_per_day"] else ""))
        print(f"      分解期望到手 {gold(w['ev'])} → 按现价每件赚 {gold(w['profit_min'])}；最高买到 {gold(int(w['ev'] / (1 + cfg['strategy']['min_roi'])))} 还划算")
        print(f"      主要材料 {w['main_name']}：现价 {gold(w['main_price'])}，日销 {w['main_spd']:.0f}；"
              f"按现价买的话，它跌到 {gold(w['breakeven_min'])} 以下就亏")
        print(f"      建议规模：每天不超过约 {w['daily_cap']} 件（不超过主要材料日销的两成、货源日销的一半）")
        if w.get("vendor_price"):
            print(f"      保底：直接卖商人 {gold(w['vendor_price'])}，按最低价买入最多每件亏 {gold(max(0, w['min_price'] - w['vendor_price']))}")
        if w["dead"]:
            print(f"      按 0 算的材料（卖不动）：{'、'.join(w['dead'])}")
        if tr and tr["hours"] >= 0.2:
            print(f"      和 {tr['hours']:.1f} 小时前比：货源最低价 {tr['min_price']:+.0f}%，在售量 {tr['quantity']:+.0f}%，"
                  f"{w['main_name']} {tr['main_price']:+.0f}%，分解期望 {tr['ev']:+.0f}%")
        elif not quiet:
            print("      这是第一条记录，下次运行起会显示趋势。")
    return out


def _tod(cfg, db, snap):
    """时段规律拉不到不该拖垮整次分析。"""
    if not snap:
        return None
    try:
        return tod.build(cfg, db, snap["id"])
    except Exception as e:
        print(f"时段分析跳过：{e}")
        return None


def cmd_tod(cfg, db, a):
    snap = database.latest_snapshot(db, cfg["market"]["id"])
    if not snap:
        sys.exit("还没有行情快照，先运行 collect")
    t = tod.build(cfg, db, snap["id"], max_age_hours=0 if a.force else 6)
    print(f"数据覆盖约 {t['hours']} 小时。{t['market_note']}\n")
    print(f"{'物品':<28}{'最便宜':>8}{'最贵':>8}{'相差':>7}{'典型最低价':>10}{'日销':>8}{'挂单最少':>9}{'样本':>6}")
    for r in t["items"]:
        print(f"{r['name'][:26]:<28}{r['low_hour']:>6}点{r['high_hour']:>6}点{r['spread']*100:>6.0f}%"
              f"{r['typical']:>10}{r['sold_per_day']:>8.0f}{r['thin_hour']:>7}点{r['points']:>6}")
    print("\n只有一周数据，样本少，只当参考。下次分析（或 quant gear）会把它写进插件的「时段」页。Prices from AHledger")


def cmd_marks(cfg, db, a):
    """游戏里的人工标注（要 / 不要）和当时模型的判断对照，用来找规则哪里错了。"""
    path = gear.find_saved_variables(cfg)
    if not path:
        sys.exit("找不到插件存盘文件")
    last = {}
    for line in gear.parse_log(path.read_text(encoding="utf-8", errors="replace")):
        f = line.split("|", 10)
        if f[0] == "#MARK" and len(f) == 11:
            last[(f[3], f[4])] = f                       # 同一件多次标注只看最后一次
    rows = [f for f in last.values() if f[2] != "clear"]
    if not rows:
        print("还没有标注。在「绿装捡漏」每行末尾的按钮上左键标「要」、右键标「不要」，然后 /reload 或下线存盘。")
        return
    groups = {"模型看低了（你要，模型不到三星）": [], "模型看高了（你不要，模型给了两星以上）": [], "和模型一致": []}
    for f in rows:
        want, stars = f[2] == "want", int(f[6])
        k = ("模型看低了（你要，模型不到三星）" if want and stars < 3 else
             "模型看高了（你不要，模型给了两星以上）" if not want and stars >= 2 else "和模型一致")
        groups[k].append(f)
    for title, g in groups.items():
        print(f"\n{title}：{len(g)} 条")
        for f in sorted(g, key=lambda f: -int(f[1])):
            print(f"   {time.strftime('%m-%d %H:%M', time.localtime(int(f[1])))}  {'要  ' if f[2] == 'want' else '不要'}  "
                  f"模型 {f[6]} 星{'' if f[7] == '1' else '(未验证)'}  {f[5]}  买 {int(f[8]) // 100}s → 卖 {int(f[9]) // 100}s（差价 {int(f[9]) / max(int(f[8]), 1):.1f} 倍） | {f[10]}")


def cmd_watch(cfg, db, a):
    ws = run_watch(cfg, db)
    if ws:
        export_lua.patch_watch(ws, cfg["strategy"]["ah_cut"])
        print("\n已更新插件里的监控数据，游戏里 /reload 后生效。")


def cmd_auto(cfg, db, a):
    """一直开着：游戏里扫描并存盘后，自动拉行情、分析、写回插件。"""
    path = gear.find_saved_variables(cfg)
    if not path:
        sys.exit("找不到插件存盘文件。先在游戏里扫描一次并 /reload。")
    gear.import_scans(db, gear.parse_scans(gear.parse_log(path.read_text(encoding="utf-8", errors="replace"))))
    seen = (gear.latest_scans(db, 1) or [{"scanned_at": 0}])[0]["scanned_at"]
    print(f"[{time.strftime('%H:%M:%S')}] 自动分析已启动，盯着 {path.name}。游戏里扫描并存盘后这里会自动跑。Ctrl+C 退出。", flush=True)
    mtime = path.stat().st_mtime
    try:
        while True:
            time.sleep(2)
            m = path.stat().st_mtime
            if m == mtime:
                continue
            mtime = m
            time.sleep(1.5)                                   # 等游戏把文件写完
            gear.import_scans(db, gear.parse_scans(gear.parse_log(path.read_text(encoding="utf-8", errors="replace"))))
            latest = (gear.latest_scans(db, 1) or [{"scanned_at": 0}])[0]["scanned_at"]
            if latest <= seen:
                continue                                      # 只是普通的重载，没有新扫描
            seen = latest
            print(f"\n[{time.strftime('%H:%M:%S')}] 发现新扫描（{_ts(latest)}），开始分析……", flush=True)
            try:
                cfg = config.load()                           # 每次重读配置，改了规则不用重启
                print(collector.collect(cfg, db)[1])
                a.file, a.top = None, 30
                cmd_gear(cfg, db, a)
            except SystemExit as e:
                print(f"分析中止：{e}")
            except Exception as e:
                print(f"分析出错：{e}")
            print(f"[{time.strftime('%H:%M:%S')}] 分析完成。回游戏点「载入结果」或 /reload。", flush=True)
            mtime = path.stat().st_mtime
    except KeyboardInterrupt:
        print("\n已退出")


def cmd_show(cfg, db, a):
    snap = db.execute("SELECT sn.* FROM snapshots sn JOIN signals s ON s.snapshot_id=sn.id "
                      "WHERE sn.market=? ORDER BY sn.captured_at DESC LIMIT 1", (cfg["market"]["id"],)).fetchone()
    if not snap:
        sys.exit("还没有生成过建议")
    print(f"行情时间 {_ts(snap['captured_at'])}")
    for r in db.execute("SELECT * FROM signals WHERE snapshot_id=? ORDER BY score DESC", (snap["id"],)):
        print(f"  [{r['strategy']}] {database.item_name(db, r['item_id'])} (id {r['item_id']}): "
              f"≤{gold(r['buy_price'])} 买 {r['max_quantity']} 件，挂 {gold(r['target_price'])}，"
              f"预期净利 {gold(r['expected_profit'])}，分 {r['score']}")


def cmd_buy(cfg, db, a):
    cost = a.quantity * a.unit_price
    cur = db.execute("INSERT INTO trades(item_id,bought_at,quantity,cost,note) VALUES(?,?,?,?,?)",
                     (a.item_id, int(time.time()), a.quantity, cost, a.note))
    db.commit()
    print(f"已记录买入 #{cur.lastrowid}: {database.item_name(db, a.item_id)} x{a.quantity}，成本 {gold(cost)}")


def cmd_sell(cfg, db, a):
    t = db.execute("SELECT * FROM trades WHERE id=?", (a.trade_id,)).fetchone()
    if not t or t["status"] != "HOLDING":
        sys.exit("找不到这笔持仓")
    gross = t["quantity"] * a.unit_price
    proceeds = gross if a.net else int(gross * (1 - cfg["strategy"]["ah_cut"]))
    db.execute("UPDATE trades SET sold_at=?, proceeds=?, fees=?, status='SOLD' WHERE id=?",
               (int(time.time()), proceeds, a.fees, a.trade_id))
    db.commit()
    print(f"已记录卖出 #{a.trade_id}: 到手 {gold(proceeds)}，净利 {gold(proceeds - t['cost'] - a.fees)}")


def cmd_writeoff(cfg, db, a):
    db.execute("UPDATE trades SET sold_at=?, proceeds=?, status='WRITTEN_OFF' WHERE id=? AND status='HOLDING'",
               (int(time.time()), a.recovered, a.trade_id))
    db.commit()
    print(f"已核销 #{a.trade_id}，回收 {gold(a.recovered)}")


def cmd_trades(cfg, db, a):
    for t in db.execute("SELECT * FROM trades ORDER BY id DESC LIMIT 40"):
        pnl = "" if t["proceeds"] is None else f" 净利 {gold(t['proceeds'] - t['cost'] - t['fees'])}"
        print(f"#{t['id']:<3} {t['status']:<11} {_ts(t['bought_at'])} {database.item_name(db, t['item_id'])} "
              f"x{t['quantity']} 成本 {gold(t['cost'])}{pnl}")


def cmd_report(cfg, db, a):
    done = db.execute("SELECT * FROM trades WHERE status IN ('SOLD','WRITTEN_OFF')").fetchall()
    hold = db.execute("SELECT * FROM trades WHERE status='HOLDING'").fetchall()
    pnl = sum((t["proceeds"] or 0) - t["cost"] - t["fees"] for t in done)
    print(f"已完结 {len(done)} 笔，已实现净利润 {gold(pnl)}")
    if done:
        wins = sum(1 for t in done if (t["proceeds"] or 0) - t["cost"] - t["fees"] > 0)
        days = [(t["sold_at"] - t["bought_at"]) / 86400 for t in done]
        print(f"盈利笔数 {wins}/{len(done)}，平均持有 {sum(days)/len(days):.1f} 天")
    now = time.time()
    stale = [t for t in hold if now - t["bought_at"] > 3 * 86400]
    print(f"持仓 {len(hold)} 笔，占用 {gold(sum(t['cost'] for t in hold))}，其中超过 3 天未卖出 {len(stale)} 笔")
    print(f"当前权益（本金+已实现）: {gold(cfg['capital']['total'] + pnl)}")


def cmd_review(cfg, db, a):
    r = backtest.review(db, cfg["market"]["id"], cfg["strategy"]["ah_cut"])
    print("历史信号复盘（代理指标：之后 72 小时内挂单中位价是否回到目标价，不是真实成交）")
    print(f"信号 {r['total']} 条：达到目标 {r['hit']}，未达到 {r['miss']}，观察期未满 {r['pending']}")
    print(f"按代理口径估算的盈亏: {gold(r['pnl'])}")
    n = db.execute("SELECT COUNT(*) c FROM snapshots WHERE market=?", (cfg["market"]["id"],)).fetchone()["c"]
    if n < 20:
        print(f"注意：库里只有 {n} 份快照，样本太少，这个结果还说明不了什么。")


def cmd_install(cfg, db, a):
    src = config.ROOT / "addon" / "ForeverQuant"
    dst = Path(os.path.expanduser(cfg["addon"]["addons_dir"])) / "ForeverQuant"
    if not dst.parent.is_dir():
        sys.exit(f"找不到插件目录: {dst.parent}")
    if dst.is_symlink() or dst.exists():
        print(f"已存在: {dst}")
        return
    dst.symlink_to(src, target_is_directory=True)
    print(f"已链接 {dst} -> {src}")


def main():
    ap = argparse.ArgumentParser(prog="python -m quant", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "collect"):
        p = sub.add_parser(name); p.add_argument("--force", action="store_true", help="忽略最短拉取间隔")
        if name == "run":
            p.add_argument("--offline", action="store_true"); p.add_argument("--disenchant", action="store_true", help="加入拆解机会（需要附魔）")
    p = sub.add_parser("scan"); p.add_argument("--offline", action="store_true", help="不拉明细复核")
    p.add_argument("--disenchant", action="store_true", help="加入拆解机会（需要附魔）")
    sub.add_parser("show")
    p = sub.add_parser("buy"); p.add_argument("item_id", type=int); p.add_argument("quantity", type=int)
    p.add_argument("unit_price", type=int, help="每件买入价（铜币）"); p.add_argument("--note", default="")
    p = sub.add_parser("sell"); p.add_argument("trade_id", type=int); p.add_argument("unit_price", type=int, help="每件成交价（铜币）")
    p.add_argument("--net", action="store_true", help="价格已是扣完抽成的到手价"); p.add_argument("--fees", type=int, default=0, help="押金损失等（铜币）")
    p = sub.add_parser("writeoff"); p.add_argument("trade_id", type=int); p.add_argument("--recovered", type=int, default=0, help="卖店等回收的铜币")
    p = sub.add_parser("gear", help="分析游戏内 /fq scan 的绿装扫描")
    p.add_argument("--file", help="指定存盘文件（默认自动找）"); p.add_argument("--top", type=int, default=30)
    p = sub.add_parser("tod", help="大宗货一天里各时段的价格规律"); p.add_argument("--force", action="store_true", help="不用缓存，重新拉")
    for name in ("trades", "report", "review", "install", "watch", "auto", "marks"):
        sub.add_parser(name)
    a = ap.parse_args()
    cfg = config.load()
    db = database.connect(cfg["db_path"])
    if a.cmd == "run":
        cmd_collect(cfg, db, a); cmd_scan(cfg, db, a)
    else:
        globals()[f"cmd_{a.cmd}"](cfg, db, a)


if __name__ == "__main__":
    main()
