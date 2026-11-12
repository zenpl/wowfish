"""把同一份真实扫描分别交给插件里的 LiveCompute（Lua）和 Python 的 find_by_rule，对比结果。
用法（需要 lupa）：python tests/lua_live_compare.py
"""
import sys
import lupa
sys.path.insert(0, ".")
from quant import config, database, gear

cfg = config.load(); db = database.connect(cfg["db_path"])
scan = gear.latest_scans(db)[0]; rows = gear.load(db, scan["id"])
prem = gear.suffix_premium(rows)
py = gear.find_by_rule(rows, cfg["strategy"], cfg["gear_rule"], max_price=cfg["capital"]["max_per_trade"], prem=prem)
py += gear.find_effect_items(rows, cfg["strategy"], cfg["gear_rule"], max_price=cfg["capital"]["max_per_trade"])
py.sort(key=lambda c: (c.score, c.unit_profit), reverse=True)
py_set = {(c.item_id, c.suffix_id, c.buy_price, c.target_price, c.unit_profit) for c in py}

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
-- 万能假对象：任何方法都能调，返回自己，够让界面代码跑完
local function mock() local m = {}
  return setmetatable(m, { __index = function(t, k) return function(...) return t end end, __call = function(t) return t end }) end
function CreateFrame() return mock() end
UIParent, Minimap, WorldFrame, GameTooltip, AuctionHouseFrame = mock(), mock(), mock(), mock(), mock()
UISpecialFrames = {}
function tinsert(t, v) table.insert(t, v) end
function time() return 1794511000 end
function GetTime() return 100 end
function GetMoney() return 9781 end
function print() end
SlashCmdList = {}
EFFECTS = {}
ForeverQuantScan = { running = false, EffectText = function(id) return EFFECTS[id] or "" end }
ForeverQuantDB = { log = {} }
ITEMS = {}
C_Item = {
  GetItemInfo = function(id) local it = ITEMS[id]; if not it then return nil end
    return it.name, nil, 2, it.ilvl, it.req end,
  GetItemInfoInstant = function(id) local it = ITEMS[id]; return id, "", "", it.loc, 1, it.cls, it.sub end,
  GetItemCount = function() return 0 end,
}
''')
L.execute(open("addon/ForeverQuant/Recommendations.lua", encoding="utf-8").read())
L.execute(open("addon/ForeverQuant/Core.lua", encoding="utf-8").read())
items = L.globals().ITEMS
effects = L.globals().EFFECTS
for r in rows:
    if r["effect"]:
        effects[r["item_id"]] = r["effect"]
lst = L.table()
for i, r in enumerate(rows, 1):
    items[r["item_id"]] = L.table_from(dict(name=r["name"], ilvl=r["level"], req=r["req_level"], loc=r["equip_loc"],
                                            cls=r["class_id"], sub=r["subclass_id"]))
    lst[i] = L.table_from(dict(id=r["item_id"], suffix=r["suffix_id"], ilvl=r["level"], qty=r["count"], price=r["buyout"], name=r["name"]))
total, afford, fresh = L.globals().ForeverQuantLive.Compute(lst)
all_ops, budget_ops, _ = L.globals().ForeverQuantLive.Get()
lua_set = {(o.item_id, o.suffix_id, o.max_unit_price, o.target_unit_price, o.expected_profit) for o in all_ops.values()}
print(f"Python: {len(py_set)} 条   Lua: {len(lua_set)} 条   完全相同的: {len(py_set & lua_set)}")
for name, diff in (("只有 Python 报的", py_set - lua_set), ("只有 Lua 报的", lua_set - py_set)):
    if diff:
        print(name + ":", sorted(diff)[:6])
# 理由和星级也要一致
py_rs = {(c.item_id, c.suffix_id, c.buy_price): (c.stars, c.reason) for c in py}
lua_rs = {(o.item_id, o.suffix_id, o.max_unit_price): (o.stars, o.reason) for o in all_ops.values()}
same_rs = sum(1 for k in py_rs if lua_rs.get(k) == py_rs[k])
print(f"星级和理由一致的: {same_rs}/{len(py_rs)}")
for k in list(py_rs)[:400]:
    if lua_rs.get(k) != py_rs[k]:
        print("  不一致:", k, "\n    Python:", py_rs[k], "\n    Lua:   ", lua_rs.get(k)); break
py_top = [(c.item_id, c.suffix_id) for c in py[:10]]
lua_top = [(all_ops[i].item_id, all_ops[i].suffix_id) for i in range(1, min(10, len(all_ops)) + 1)]
print("前 10 名顺序一致:", py_top == lua_top, "| 本金内（按 97s81c 金币的八成）:", afford, "条")
# ---- 分解：两边用同一份材料价（导出文件里的那份）
import re
from quant import disenchant
txt = open("addon/ForeverQuant/Recommendations.lua", encoding="utf-8").read()
mats = {int(m.group(1)): dict(name=m.group(2), sold_per_day=float(m.group(3)), price=int(m.group(4)))
        for m in re.finditer(r'\[(\d+)\] = \{ name = "([^"]*)", spd = ([\d.]+), price = (\d+) \}', txt)}
de_cfg = cfg.get("disenchant") or {}
py_de, _, _ = disenchant.scan(rows, mats, cfg["strategy"], excluded=de_cfg.get("not_disenchantable") or [], verified=de_cfg.get("verified") or [])
price_of = L.table_from({k: v["price"] for k, v in mats.items()})
n = L.globals().ForeverQuantLive.DE(lst, price_of)
_, _, lua_de = L.globals().ForeverQuantLive.Get()
py_de_set = {(o["item_id"], o["level"], o["price"], o["net"], o["profit"], bool(o["verified"])) for o in py_de}
lua_de_set = {(o.item_id, o.level, o.price, o.net, o.profit, bool(o.verified)) for o in lua_de.values()}
print(f"分解  Python: {len(py_de_set)} 件   Lua: {len(lua_de_set)} 件   完全相同的: {len(py_de_set & lua_de_set)}")
for name, diff in (("只有 Python 报的", py_de_set - lua_de_set), ("只有 Lua 报的", lua_de_set - py_de_set)):
    if diff:
        print("  " + name + ":", sorted(diff)[:5])
n_fx = sum(1 for o in all_ops.values() if o.strategy == "EFFECT")
print(f"特效  Python: {sum(1 for c in py if c.strategy == 'EFFECT')} 件   Lua: {n_fx} 件")
sys.exit(0 if py_set == lua_set and py_de_set == lua_de_set and same_rs == len(py_rs) else 1)
