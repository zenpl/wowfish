"""把建议写成插件能读的 Lua 文件。"""
from pathlib import Path

from .config import ROOT

OUT = ROOT / "addon" / "ForeverQuant" / "Recommendations.lua"


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def watch_lines(watch, generated_at):
    """监控项的 Lua 片段，夹在标记行之间，方便单独替换。"""
    lines = ["    -- WATCH-BEGIN", f"    watch_at = {int(generated_at)},", "    watch = {"]
    for w in watch or []:
        ys = ", ".join("{ " + ", ".join([f"id = {y['id']}", f"name = {lua_str(y['name'])}", f"chance = {y['chance']}",
                                         f"qty = {y['qty']}", f"price = {y['price']}"]) + " }" for y in w["yields"])
        lines.append("        { " + ", ".join([
            f"item_id = {w['item_id']}", f"name = {lua_str(w['name'])}", f"level = {w['level']}",
            f"min_price = {w['min_price']}", f"wall_price = {w['wall_price']}", f"quantity = {w['quantity']}",
            f"ev = {w['ev']}", f"main_id = {w['main_id']}", f"main_name = {lua_str(w['main_name'])}",
            f"main_spd = {w['main_spd']}", f"daily_cap = {w['daily_cap']}", f"vendor_price = {w.get('vendor_price') or 0}", f"verdict = {lua_str(w['verdict'])}",
            f"min_roi = 0.15", "yields = { " + ys + " }"]) + " },")
    lines += ["    },", "    -- WATCH-END"]
    return lines


def patch_watch(watch, ah_cut, path=OUT, now=None):
    """只替换已有文件里的监控段，其余建议不动。"""
    import time
    p = Path(path)
    txt = p.read_text(encoding="utf-8")
    new = "\n".join(watch_lines(watch, now or time.time()))
    if "-- WATCH-BEGIN" in txt:
        head, rest = txt.split("    -- WATCH-BEGIN", 1)
        tail = rest.split("    -- WATCH-END", 1)[1]
        txt = head + new + tail
    else:
        i = txt.rstrip().rfind("}")
        txt = txt[:i] + new + "\n}\n"
    p.write_text(txt, encoding="utf-8")
    return p


def blue_lines(blue):
    """蓝色武器逐件的价格画像（见 quant/blue.py）。"""
    if not blue or not blue.get("items"):
        return []
    from .blue import snipe
    pick = snipe(blue["items"], watch=blue.get("watch") or ())
    lines = ["    blue = {", f"        at = {int(blue['at'])},", "        items = {"]
    for r in blue["items"]:
        sn = pick.get(r["item_id"])
        extra = [f"ilvl = {r.get('ilvl') or 0}"] + ([f"snipe = {lua_str(sn[0])}", f"line = {sn[1]}", f"ref = {sn[2]}"] if sn else [])
        nd = (blue.get("need") or {}).get(r["item_id"])
        if nd:
            extra += [f"need = {nd['need']}", f"who = {lua_str(nd['who'])}", f"why = {lua_str(nd['why'].replace(chr(10), ' ## '))}"]
        lines.append("            { " + ", ".join(extra + [
            f"item_id = {r['item_id']}", f"name = {lua_str(r['name'])}", f"kind = {lua_str(r['kind'])}", f"req = {r['req']}",
            f"cur = {r['cur']}", f"qty = {r['qty']}", f"typ = {r['typ']}", f"low = {r['low']}", f"high = {r['high']}", f"recent = {r.get('recent') or r['typ']}",
            f"spd = {r['spd']:.1f}", f"points = {r['points']}"]) + " },")
    lines.append("        },")
    ids = blue.get("ref_ids") or []
    if ids:
        lines.append("        ref_ids = { " + ", ".join(str(i) for i in ids) + " },")
    return lines + ["    },"]


def tod_lines(tod):
    """一天里各时段的价格规律（见 quant/tod.py）。"""
    if not tod or not tod.get("items"):
        return []
    lines = ["    tod = {", f"        hours = {int(tod['hours'])}, market_note = {lua_str(tod['market_note'])},", "        items = {"]
    for r in tod["items"]:
        lines.append("            { " + ", ".join([
            f"item_id = {r['item_id']}", f"name = {lua_str(r['name'])}", f"low_hour = {r['low_hour']}",
            f"high_hour = {r['high_hour']}", f"thin_hour = {r['thin_hour']}", f"spread = {r['spread']:.3f}",
            f"typical = {r['typical']}", f"sold_per_day = {r['sold_per_day']:.1f}", f"points = {r['points']}"]) + " },")
    return lines + ["        },", "    },"]


def de_lines(de):
    """分解表和材料信息：插件用它在游戏内直接算分解套利。"""
    if not de:
        return []
    lines = ["    de = {", "        brackets = {"]
    for lo, hi, dust, dq, ess, eq, shard, ap, wp in de["brackets"]:
        lines.append(f"            {{ lo = {lo}, hi = {hi}, dust = {dust}, dust_qty = {sum(dq) / 2}, ess = {ess}, ess_qty = {sum(eq) / 2}, "
                     f"shard = {shard or 0}, armor = {{ {ap[0]}, {ap[1]}, {ap[2]} }}, weapon = {{ {wp[0]}, {wp[1]}, {wp[2]} }} }},")
    lines += ["        },", "        mats = {"]
    for mid, m in de["mats"].items():
        lines.append(f"            [{mid}] = {{ name = {lua_str(m['name'])}, spd = {m['sold_per_day']}, price = {m['price']} }},")
    lines += ["        },",
              "        excluded = { " + ", ".join(f"[{i}] = true" for i in de["excluded"]) + " },",
              "        verified = { " + ", ".join(f"[{i}] = true" for i in de["verified"]) + " },",
              "    },"]
    return lines


def rule_lines(rule_export):
    """筛选规则的 Lua 片段：插件拿它在游戏内直接筛，不用等电脑端。"""
    if not rule_export:
        return []
    r = rule_export
    lines = ["    rule = {"]
    for k in ("max_level", "floor_ratio", "min_gap", "twink_min_req", "twink_max_req", "max_price", "min_unit_profit",
              "effect_max_ratio", "min_roi", "hot_min_value", "comp_margin", "alt_level_range", "scarcity_bonus",
              "premium_bonus", "effect_premium_ratio", "need_bonus", "stars_3", "stars_2", "premium_full_level", "min_level"):
        lines.append(f"        {k} = {r[k]},")
    lines.append(f"        highlight_bonus = {r['highlight_bonus']},")
    for k in ("twink_extra", "uncertain", "confirmed"):
        lines.append(f"        {k} = {{ " + ", ".join(f"[{lua_str(x)}] = true" for x in r[k]) + " },")
    lines.append("        effect_keywords = { " + ", ".join(lua_str(k) for k in r["effect_keywords"]) + " },")
    lines.append("        stats_cn = { " + ", ".join(f"[{lua_str(l)}] = {lua_str(v)}" for l, v in r["stats_cn"].items()) + " },")
    lines.append("        nstats = { " + ", ".join(f"[{lua_str(l)}] = {n}" for l, n in r["nstats"].items()) + " },")
    for name in ("value", "star", "role", "ok", "role_key", "role_value", "tier", "need", "multi", "multi_note", "multi_n", "role_short"):
        lines.append(f"        {name} = {{")
        for key, labels in r[name].items():
            def fmt(v):
                return lua_str(v) if isinstance(v, str) else ("true" if v is True else str(v))
            lines.append(f"            {key} = {{ " + ", ".join(f"[{lua_str(l)}] = {fmt(v)}" for l, v in labels.items()) + " },")
        lines.append("        },")
    lines.append("        hot = {")
    for key, labels in r["hot"].items():
        lines.append(f"            {key} = {{ " + ", ".join(f"[{lua_str(l)}] = {lua_str(why)}" for l, why in labels.items()) + " },")
    lines += ["        },", "        stats = {"]
    for label, stats in r["stats"].items():
        lines.append(f"            [{lua_str(label)}] = {lua_str('+'.join(stats))},")
    lines += ["        },", "    },"]
    return lines


def export(orders, names, market, generated_at, prices_at, path=OUT, recipes=None, ah_cut=0.05, disenchant=None, watch=None, rule=None, de=None, prices=None, tod=None, blue=None):
    lines = ["-- 由 forever-quant 生成，请勿手改。Prices from AHledger (https://ahledger.com)",
             "ForeverQuantRecommendations = {",
             f"    generated_at = {int(generated_at)},",
             f"    prices_at = {int(prices_at)},",
             f"    market = {lua_str(market)},",
             "    opportunities = {"]
    for o in orders:
        c = o.cand
        lines.append(
            "        { " + ", ".join([
                f"item_id = {c.item_id}", f"suffix_id = {c.suffix_id}", f"name = {lua_str(c.name or names.get(c.item_id, ''))}",
                f"strategy = {lua_str(c.strategy)}", f"max_unit_price = {c.buy_price}",
                f"target_unit_price = {c.target_price}", f"max_quantity = {o.quantity}",
                f"expected_profit = {o.expected_profit}", f"score = {c.score}",
                f"affordable = {'true' if getattr(c, 'affordable', False) else 'false'}",
                f"highlight = {'true' if getattr(c, 'highlight', False) else 'false'}",
                f"premium = {'true' if getattr(c, 'premium', False) else 'false'}",
                f"stars = {getattr(c, 'stars', 1)}", f"reason = {lua_str(getattr(c, 'reason', ''))}",
                f"note = {lua_str('; '.join(c.notes))}"]) + " },")
    lines += ["    },", f"    ah_cut = {ah_cut},", "    recipes = {"]
    for r in recipes or []:
        spd = r["sold_per_day"] if r.get("sold_per_day") is not None else -1
        lines.append("        { " + ", ".join([
            f"item_id = {r['item_id']}", f"name = {lua_str(r['name'])}", f"profession = {lua_str(r['profession'])}",
            f"cost = {r['cost']}", f"min_price = {r['min_price']}", f"net = {r['net']}",
            f"quantity = {r['quantity']}", f"sold_per_day = {spd}",
            "vendors = { " + ", ".join(
                "{ " + ", ".join([f"map = {v.get('map') or 0}", f"x = {v['x'] if v.get('x') is not None else 0}",
                                  f"y = {v['y'] if v.get('y') is not None else 0}", f"zone = {lua_str(v['zone'])}",
                                  f"name = {lua_str(v['name'])}"]) + " }"
                for v in r.get("vendor_list", [])) + " }"]) + " },")
    lines += ["    },", "    disenchant = {"]
    for o in disenchant or []:
        lines.append("        { " + ", ".join([
            f"item_id = {o['item_id']}", f"suffix_id = {o['suffix_id']}", f"name = {lua_str(o['name'])}",
            f"kind = {lua_str(o['kind'])}", f"level = {o['level']}", f"price = {o['price']}", f"net = {o['net']}",
            f"profit = {o['profit']}", f"quantity = {o['quantity']}", f"main = {lua_str(o['main'])}",
            f"verified = {'true' if o.get('verified') else 'false'}"]) + " },")
    lines += ["    },"]
    if prices:        # 行情源里各物品的最低价（铜）。钓鱼页估收益用；游戏内全量扫描后会被更新鲜的价格盖掉
        lines.append("    prices = { " + ", ".join(f"[{i}] = {p}" for i, p in sorted(prices.items())) + " },")
    lines += blue_lines(blue) + tod_lines(tod) + rule_lines(rule) + de_lines(de) + watch_lines(watch, generated_at) + ["}", ""]
    Path(path).write_text("\n".join(lines), encoding="utf-8")
    return path
