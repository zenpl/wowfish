"""用模拟环境加载插件，检查账本配对和垃圾鱼的保护逻辑。用法（需要 lupa）：python tests/lua_ledger_test.py"""
import sys
import lupa

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
local function mock() local m = {}
  return setmetatable(m, { __index = function(t, k) return function(...) return t end end, __call = function(t) return t end }) end
function CreateFrame() return mock() end
UIParent, Minimap, WorldFrame, GameTooltip, AuctionHouseFrame = mock(), mock(), mock(), mock(), mock()
UISpecialFrames = {}
function tinsert(t, v) table.insert(t, v) end
NOW = 1794520000
function time() return NOW end
function date(fmt, t) return os.date(fmt, t) end
function GetTime() return 100 end
function GetMoney() return 50000 end
function print(...) LAST = table.concat({...}, " ") end
function hooksecurefunc() end
SlashCmdList = {}
ERR_AUCTION_SOLD_S = "你的拍卖品%s已售出。"
ERR_AUCTION_EXPIRED_S = "你的拍卖品%s已过期。"
ForeverQuantScan = { running = false }
ForeverQuantDB = { log = {} }
QUALITY = { [100] = 0, [101] = 1, [102] = 2 }
C_Item = { GetItemInfo = function(id) return "物品" .. id, nil, QUALITY[id] or 1, 20, 15 end,
           GetItemInfoInstant = function(id) return id, "", "", "", 1, 0, 0 end, GetItemCount = function() return 0 end }
BAGS = {}
C_Container = {
  GetContainerNumFreeSlots = function(bag) return bag == 0 and FREE or 0 end,
  GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
  GetContainerItemInfo = function(bag, slot) return BAGS[slot] end,
  PickupContainerItem = function(bag, slot) CURSOR = slot end,
}
function ClearCursor() CURSOR = nil end
function CursorHasItem() return CURSOR ~= nil end
function DeleteCursorItem() DELETED = BAGS[CURSOR].itemID; BAGS[CURSOR] = nil; CURSOR = nil end
function UnitIsDeadOrGhost() return false end
''')
L.execute(open("addon/ForeverQuant/Recommendations.lua", encoding="utf-8").read())
L.execute(open("addon/ForeverQuant/Core.lua", encoding="utf-8").read())
L.execute("for _, r in ipairs(ForeverQuantRecommendations.blue and ForeverQuantRecommendations.blue.items or {}) do r.snipe = nil end")   # 真实数据里要盯的蓝武先拿掉，池子的测试才不受它影响
# 默认当作"账上的货都在手里"；要测背包的地方自己换掉 BagNames
L.execute("ALL_IN_HAND = function() return setmetatable({}, { __index = function() return 99 end }) end; EMPTY_BAG = function() return {} end; ForeverQuantLedger.BagNames = ALL_IN_HAND")
g = L.globals()
ok = True
def check(name, cond):
    global ok
    ok = ok and bool(cond)
    print(("  通过  " if cond else "  失败  ") + name)

# ---- 账本配对
T = 1794500000
lines = [
    f"{T}|BUY|15137|14313|1|2400|能量之切喉者手套|",
    f"{T+600}|POST|15137|14313|1|9405|能量之切喉者手套|dep=120",
    f"{T+4200}|SOLD|0|0|1|0|能量之切喉者手套|",                # 挂了 1 小时卖掉
    f"{T+100}|BUY|9781|14306|1|1000|孤狼之歹徒短裤|",
    f"{T+700}|POST|9781|14306|1|6500|孤狼之歹徒短裤|dep=80",
    f"{T+90000}|EXPIRED|0|0|1|0|孤狼之歹徒短裤|",               # 流拍
    f"{T+200}|POST|6358|0|20|900|油性黑口鱼|commodity",           # 没有买入记录（自己钓的）
    f"{T+3800}|SOLD|0|0|1|0|油性黑口鱼|",
    f"{T+300}|BUY|4251|0|3|2400|山地护肩|",                        # 买了没挂
    f"{T+5000}|SOLD|0|0|1|0|装插件之前挂的东西|",
]
g.ForeverQuantDB.ledger = L.table_from(lines)
s = g.ForeverQuantLedger.Build()
rows = {r.name: r for r in g.ForeverQuantLedger.rows.values()}
r = rows["能量之切喉者手套"]
check("买 24s 卖 94s：净赚 = 94.05s x 0.95 - 24s", r.status == "sold" and r.net == int(9405 * 0.95) - 2400 and r.took == 3600)
wolf = [r for r in g.ForeverQuantLedger.rows.values() if r.name == "孤狼之歹徒短裤"]
check("流拍的标成流拍，不算卖出；货回到手里（多一行「只买未挂」）", sorted(r.status for r in wolf) == ["expired", "held"] and all(r.net is None for r in wolf))
check("自己钓的鱼没有买入价：算卖出但不计入净赚", rows["油性黑口鱼"].status == "sold" and rows["油性黑口鱼"].cost is None)
check("买了没挂的列为持有", rows["山地护肩"].status == "held" and rows["山地护肩"].qty == 3)
check("没有上架记录的卖出也记一行", rows["装插件之前挂的东西"].status == "sold")
check("汇总：卖出 3 笔，1 笔有净赚，2 笔缺买入价，流拍 1", (s.sold, s.noCost, s.expired, s.open) == (3, 2, 1, 0) and s.net == int(9405 * 0.95) - 2400)

# ---- 经营总览（简化的商户账）
g.NOW = T + 7200
g.ForeverQuantDB.ledger = L.table_from([
    f"{T}|BUY|1|0|1|1000|甲|", f"{T+10}|POST|1|0|1|5000|甲|dep=100", f"{T+600}|SOLD|0|0|1|0|甲|",          # 卖掉：到手 4750，赚 3750
    f"{T}|BUY|2|0|1|2000|乙|", f"{T+10}|POST|2|0|1|8000|乙|dep=200",                                       # 还在卖
    f"{T}|BUY|3|0|1|1500|丙|",                                                                             # 买了没挂
    f"{T}|BUY|4|0|1|800|丁|", f"{T+10}|POST|4|0|1|3000|丁|dep=50", f"{T+900}|EXPIRED|0|0|1|0|丁|",        # 流拍：货回到手里，押金没了
])
Lg = g.ForeverQuantLedger
L.execute("OLD_INFO = C_Item.GetItemInfo; VEND = { [2] = 300, [3] = 200 }; C_Item.GetItemInfo = function(id) return '物品' .. id, nil, 2, 20, 15, nil, nil, nil, nil, nil, VEND[id] end")
S = Lg.Stats()
check("买入成本 = 在售的 + 没挂的 + 流拍退回的", (S.listedCost, S.heldCost, S.cost) == (2000, 1500 + 800, 4300) and S.heldN == 2)
check("货值按商店收购价的底线算：在售 3s + 没挂 2s，查不到商店价的那件按 0 并且说明", (S.stock, S.floorUnknown) == (500, 1))
check("垫着的押金只算在售的；流拍的押金记成损失", S.depHeld == 200 and S.depLost[2] == 50)
check("现金流：卖货收回 4750 - 买货 5300 - 押金损失 50", S.back[2] == 4750 and S.buy[2] == 5300 and S.flow[2] == 4750 - 5300 - 50)
check("已实现净赚 3750；资产 = 现金 + 货（底线）+ 押金", S.profit[2] == 3750 and S.assets == 50000 + 500 + 200)
check("全卖光的话：现金 + 在售挂牌价扣抽成 + 押金", S.ifSold == 50000 + int(8000 * 0.95) + 200)
g.NOW = T + 1800            # 卖出才 20 分钟：钱还被拍卖行押着
S = Lg.Stats()
check("卖出不到一小时：货款算「没到账」，不算收回，但算资产", (S.transit, S.transitN, S.back[2]) == (4750, 1, 0) and S.flow[2] == -5300 - 50
      and S.assets == 50000 + 500 + 200 + 4750 and S.profit[2] == 3750)
g.NOW = T + 7200
check("生成总览表不出错", len(list(Lg.BizRows()[0].values())) > 10)
g.ForeverQuantDB.ledger[len(list(g.ForeverQuantDB.ledger.values())) + 1] = f"{T+1000}|USED|3|0|1|1500|丙|"      # 丙不卖了，自己用
S = Lg.Stats()
check("标成自用的货不再算压货", S.heldCost == 800 and S.heldN == 1 and any(r.status == "used" for r in Lg.rows.values()))
check("自用单列：1 件、成本 1500；买货花掉不变；倒卖净成绩 = 净赚 - 赔掉的押金", (S.used[2], S.usedN[2], S.buy[2]) == (1500, 1, 5300) and S.result[2] == 3750 - 50)
g.ForeverQuantDB.ledger[len(list(g.ForeverQuantDB.ledger.values())) + 1] = f"{T+1100}|RESTOCK|3|0|1|1500|丙|"   # 又拿出来卖
S = Lg.Stats()
check("自用后又拿出来卖：成本回到压货，自用清零，买货花掉还是不变", (S.heldCost, S.used[2], S.buy[2]) == (2300, 0, 5300))
g.NOW = 1794520000

# ---- 钓鱼时自动静音
L.execute('CV = { Sound_EnableMusic = "1", Sound_EnableAmbience = "1", Sound_EnableSFX = "0", Sound_EnableAllSound = "1" }; C_CVar = { GetCVar = function(k) return CV[k] end, SetCVar = function(k, v) CV[k] = v end }')
g.ForeverQuantFishSound(True)
check("开始钓鱼：音乐、环境音关掉，音效打开", (g.CV.Sound_EnableMusic, g.CV.Sound_EnableAmbience, g.CV.Sound_EnableSFX) == ("0", "0", "1"))
g.ForeverQuantFishSound(True); g.ForeverQuantFishSound(False)
check("停止钓鱼：恢复成原来的设置（连着开两次也不会把原设置盖掉）", (g.CV.Sound_EnableMusic, g.CV.Sound_EnableAmbience, g.CV.Sound_EnableSFX) == ("1", "1", "0") and g.ForeverQuantDB.soundSaved is None)

# ---- 卖出消息、对账补记
Lg = g.ForeverQuantLedger
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|15125|0|1|1100|强盗之粗鲁手套|", f"{T+40}|POST|15125|0|1|2850|强盗之粗鲁手套|dep=198",
                                        f"{T+50}|POST|9807|0|1|11300|强盗之超强护肩|dep=251", f"{T+60}|POST|7409|0|1|9700|强盗之间谍之靴|dep=457"])
Lg.OnSystemMessage("你拍卖的强盗之粗鲁手套已经售出。")       # 这个客户端里实际的文字，和全局模板不一样
Lg.Build(); rows = {r.name: r for r in Lg.rows.values()}
check("收到「已售出」的系统消息：记成卖出", rows["强盗之粗鲁手套"].status == "sold" and rows["强盗之粗鲁手套"].net == int(2850 * 0.95) - 1100)
L.execute("""
OWNED = { { itemLink = "|cff1eff00|Hitem:7409:0:0:0:0:0:1547|h[强盗之间谍之靴]|h|r", status = 0 } }
C_AuctionHouse = { HasFullOwnedAuctionResults = function() return true end,
  GetNumOwnedAuctions = function() return #OWNED end, GetOwnedAuctionInfo = function(i) return OWNED[i] end }
""")
Lg.Reconcile(); Lg.Build(); rows = {r.name: r for r in Lg.rows.values()}
check("对账：我的拍卖里已经没有的补记成卖出，还挂着的不动", rows["强盗之超强护肩"].status == "sold" and rows["强盗之间谍之靴"].status == "open")
Lg.Reconcile(); check("再对一次账不会重复记", sum(1 for x in g.ForeverQuantDB.ledger.values() if "|SOLD|" in x) == 2)

L.execute("C_Item.GetItemInfo = OLD_INFO")
# ---- 垃圾鱼的保护
J = g.ForeverQuantJunk
g.ForeverQuantDB.junk = L.table()
J.Toggle(102); check("绿色品质不允许标成垃圾", not g.ForeverQuantDB.junk[102])
J.Toggle(100); check("灰色品质可以标记", g.ForeverQuantDB.junk[100])
g.BAGS = L.table_from({1: L.table_from({"itemID": 101, "quality": 1, "stackCount": 5}),
                       2: L.table_from({"itemID": 100, "quality": 0, "stackCount": 9}),
                       3: L.table_from({"itemID": 102, "quality": 2, "stackCount": 1})})
g.FREE = 2
check("没开钓鱼时不扔", not J.Wanted())
bag, slot, iid, n = J.Find()
check("只找得到标记过的那一堆", (slot, iid, n) == (2, 100, 9))
g.ForeverQuantDB.junk[102] = True      # 就算有人硬把绿装塞进名单
g.BAGS[2] = None
check("品质高于白色的永远不扔", J.Find() is None)
g.BAGS[2] = L.table_from({"itemID": 100, "quality": 0, "stackCount": 9})
check("执行销毁：扔掉的是标记的那堆", J.DeleteOne() and g.DELETED == 100 and g.BAGS[2] is None and g.BAGS[1] is not None and g.BAGS[3] is not None)
# ---- 同款印证
P = g.ForeverQuantPeer
def op(buy, target, stars=2, verified=False):
    return L.table_from(dict(item_id=1, suffix_id=2, name="x", max_unit_price=buy, target_unit_price=target,
                             expected_profit=int(target * 0.95) - buy, stars=stars, verified=verified, reason="未验证"))
def peers(*prices):
    return L.table_from(dict(n=len(prices), low=prices[0] if prices else 0, text="", t=0))
o = op(2000, 8000); P.Apply(o, peers(7000, 7000, 7200))
check("一件 20s、三件 70s：算已验证并加一星，目标价贴着 70s", o.peer == "ok" and o.model_verified and o.model_stars == 3 and o.target_unit_price == 6700)
o = op(2000, 3500); P.Apply(o, peers(6200, 6500, 6800))
check("模型估 35s、同款三件 62s 起：目标价抬到 60s", o.target_unit_price == 6000)
o = op(2000, 3500); P.Apply(o, peers(6200))
check("只有一件同款挂得贵：目标价不往上抬", o.target_unit_price == 3500)
o = op(2000, 8000, stars=3, verified=True); P.Apply(o, peers(2200, 2500))
check("同款也只挂 22s：取消验证并减一星", o.peer == "flat" and not o.model_verified and o.model_stars == 2 and o.expected_profit <= 0)
o = op(2000, 8000); P.Apply(o, peers(7000))
check("只有一件同款挂得贵：只列出来，不改星级", o.peer == "weak" and o.model_stars == 2 and not o.model_verified)
o = op(2000, 8000); P.Apply(o, peers())
check("没有同款：什么都不动", o.peer is None and o.target_unit_price == 8000)
# ---- 上架前定价
D = g.ForeverQuantPricingDecide
def hold(cost, target): return L.table_from(dict(name="x", cost=cost, target=target))
h = hold(1500, 3500); D(h, L.table_from([6200, 6500, 6800])); check("同款都挂 60 多、原目标 35s：挂 60s", h.post == 6000)
h = hold(1500, 3500); D(h, L.table_from([6200])); check("只有一件同款 62s：取中间 47s", h.post == 4700)
h = hold(1500, 3500); D(h, L.table_from([])); check("没有同款：按原目标 35s", h.post == 3500)
h = hold(1500, 3500); D(h, L.table_from([1600, 1700])); check("同款只挂 16s（低于成本线）：不跟着砸，按原目标挂", h.post == 3500)
h = hold(1500, 3500); D(h, L.table_from([2600, 2700])); check("同款 26s，比原目标低但还有利润：贴着挂 25s", h.post == 2500)
hot = lambda name, relist=0: L.table_from(dict(name=name, item_id=101, cost=1000, target=5000, relist=relist))
h = hot("强盗之刚硬护肩"); D(h, L.table_from([])); check("强盗词缀、没有同款在售：比原目标价提 15%", h.post == 5700)
h = hot("强盗之刚硬护肩"); D(h, L.table_from([5400])); check("强盗、唯一一件同款挂得更高：提价但不越过它", 5000 < h.post < 5400)
h = hot("强盗之刚硬护肩"); D(h, L.table_from([4000, 4200])); check("强盗、有人压在下面：不提，照旧贴着最低的挂", h.post < 4000)
h = hot("野熊之刚硬护肩"); D(h, L.table_from([])); check("别的词缀不提", h.post == 5000)
h = hot("强盗之刚硬护肩", 1); D(h, L.table_from([])); check("流拍过的强盗不提，照样打折", h.post == 4500)
M = lambda target, *ps: g.ForeverQuantPricing.Mistakes(L.table_from(dict(name="x", item_id=101, cost=1000, target=target)), L.table_from(list(ps)))
check("一件 20s、后面三件 60s 起：标错的压价单，买 1 件，参照 60s", M(5000, 2000, 6000, 6200, 6500) == (1, 6000))
check("两件 20s 上下、后面都 60s 起：买 2 件", M(5000, 2000, 2200, 6000, 6200) == (2, 6000))
check("三件都 20s 上下：那是行情，不买", M(5000, 2000, 2100, 2200, 6000, 6200)[0] == 0 if isinstance(M(5000, 2000, 2100, 2200, 6000, 6200), tuple) else M(5000, 2000, 2100, 2200, 6000, 6200) == 0)
check("只比后面便宜三成：正常压价，不买", (M(5000, 4200, 6000, 6200) or 0) in (0, (0,)))
check("后面只有一件挂天价：不信它，按原目标价当参照", M(5000, 2000, 90000) == (1, 5000))
check("只有这一件、不到原目标价一半：买", M(5000, 2000) == (1, 5000))
check("转手赚不到 15s 的不买", (M(3000, 1400, 3000, 3100) or 0) in (0, (0,)))
def rehold(cost, last, n, iid=101): return L.table_from(dict(name="x", item_id=iid, cost=cost, target=last, relist=n))
g.SELL = L.table_from({101: 300})
L.execute("C_Item.GetItemInfo = function(id) return '物品' .. id, nil, QUALITY[id] or 1, 20, 15, nil, nil, nil, nil, nil, SELL[id] or 0 end")
h = rehold(1500, 6000, 1); D(h, L.table_from([])); check("流拍一次、没有同款：比上次的 60s 降一成挂 54s", h.post == 5400)
h = rehold(1500, 6000, 2); D(h, L.table_from([9000])); check("流拍两次、只有一件同款挂得更贵：不往上抬，降到 48s", h.post == 4800)
h = rehold(1500, 6000, 1); D(h, L.table_from([5000, 5200, 5500])); check("流拍后同款有三件 50s 起：跟市场，挂 48s", h.post == 4800)
h = rehold(1500, 2000, 4); D(h, L.table_from([])); check("逐步打折不守成本：成本 15s 的货第四次降到 13s 照挂", h.post == 1300 and not h.vendor)
h = rehold(1500, 400, 3); D(h, L.table_from([])); check("降到拍卖行到手不如卖店（商店收 3s）：不再上架，标成该卖店", h.vendor and h.fail >= 2 and h.post is None)
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|101|0|1|1500|x|", f"{T+9}|VENDOR|101|0|1|300|x|"])
S = Lg.Stats()
check("卖店记账：收回 3s 算现金，亏 12s 算进净赚，不再压货", (S.back[2], S.profit[2], S.heldCost, S.vendorN[2]) == (300, -1200, 0, 1))

# ---- 背包里找流拍退回来的货
SAVE = (g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings, g.ForeverQuantDB.known)
now = int(g.NOW)
g.ForeverQuantDB.ledger = L.table_from([
    f"{now-40000}|BUY|501|7|1|1000|甲|", f"{now-39000}|POST|501|7|1|6000|甲|dep=10,dur=2",          # 还标着在售，其实退回来了
    f"{now-40000}|BUY|502|7|1|1000|乙|", f"{now-39000}|POST|502|7|1|6000|乙|dep=10,dur=2", f"{now-100}|SOLD|0|0|1|0|乙|补记",   # 被对账误记成卖出
    f"{now-40000}|BUY|503|7|1|1000|丙|", f"{now-39000}|POST|503|7|1|6000|丙|dep=10,dur=2", f"{now-100}|SOLD|0|0|1|0|丙|",       # 亲眼看到卖出消息的
    f"{now-40000}|BUY|504|7|1|1000|丁|", f"{now-30000}|USED|504|0|1|1000|丁|",                       # 标成自用的
    f"{now-40000}|BUY|505|7|1|1000|戊|",                                                             # 买了还在待上架
])
g.ForeverQuantDB.holdings = L.table_from([L.table_from(dict(item_id=505, suffix_id=7, name="戊", cost=1000, target=5000))])
g.ForeverQuantDB.known = L.table()
L.execute("C_Container.GetContainerItemLink = C_Container.GetContainerItemLink or function() return nil end")
L.execute("ForeverQuantLedger.BagNames = function() return { ['甲'] = 1, ['乙'] = 1, ['丙'] = 1, ['丁'] = 1, ['戊'] = 1, ['路人'] = 2 } end")
n = Lg.BagCheck()
hn = sorted(h.name for h in g.ForeverQuantDB.holdings.values())
check("背包里的货：在售的记流拍、误记卖出的更正，都放回待上架；真卖出的、自用的、本来就待上架的、无关的不动",
      n == 2 and hn == ["乙", "戊", "甲"])
Lg.Build(); st = {r.name: r.status for r in Lg.rows.values() if r.price}
check("账上两笔都改成流拍，成本放回压货", st["甲"] == "expired" and st["乙"] == "expired" and st["丙"] == "sold" and Lg.Stats().heldCost >= 3000)
check("流拍放回的带流拍次数（重挂会打折）", all((h.relist or 0) == 1 for h in g.ForeverQuantDB.holdings.values() if h.name in ("甲", "乙")))
check("再检查一遍不会重复放", Lg.BagCheck() == 0 and len(list(g.ForeverQuantDB.holdings.values())) == 3)
g.ForeverQuantDB.durHours = None
Lg.LearnDur(2, now - 3600, 7 * 3600 - 60)
check("从剩余时间学到这一档是 8 小时", Lg.DurHours(2) == 8 and Lg.DurHours(3) == 48)
g.ForeverQuantDB.durHours = None
g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings, g.ForeverQuantDB.known = SAVE
L.execute("ForeverQuantLedger.BagNames = ALL_IN_HAND")

# ---- 没到账的钱：以拍卖行报的为准
SAVE2 = (g.ForeverQuantDB.ledger, g.OWNED)
now = int(g.NOW)
g.ForeverQuantDB.ledger = L.table_from([
    f"{now-9000}|BUY|601|7|1|1000|子|", f"{now-8000}|POST|601|7|1|6000|子|dep=10,dur=2",
    f"{now-9000}|BUY|602|7|1|1000|丑|", f"{now-8000}|POST|602|7|1|4000|丑|dep=10,dur=2",
    f"{now-9000}|BUY|603|7|1|1000|寅|", f"{now-8000}|POST|603|7|1|9000|寅|dep=10,dur=2", f"{now-7000}|SOLD|0|0|1|0|寅|补记",   # 近两小时前卖的，早到账了
])
lk = lambda i, n: f"|cff1eff00|Hitem:{i}:0:0:0:0:0:7|h[{n}]|h|r"
g.OWNED = L.table_from([
    L.table_from(dict(itemLink=lk(601, "子"), status=1, buyoutAmount=6000, timeLeftSeconds=1200)),     # 卖了 40 分钟，还要等 20 分钟
    L.table_from(dict(itemLink=lk(602, "丑"), status=0, buyoutAmount=4000, timeLeftSeconds=50000)),    # 还在卖
])
Lg.Reconcile()
S = Lg.Stats()
check("没到账的钱 = 拍卖行报的已售出那一笔（扣抽成），早到账的和还在卖的不算", (S.transit, S.transitN, S.transitExact) == (5700, 1, True))
Lg.Build(); r = [r for r in Lg.rows.values() if r.name == "子"][0]
check("补记的卖出时间用拍卖行报的（40 分钟前），不是对账的时刻", r.status == "sold" and abs((now - r.sold) - 2400) <= 2)
g.NOW = now + 1300
check("过了到账时间就不再算在路上", Lg.Stats().transit == 0)
g.NOW = now
Lg.pend = None
g.ForeverQuantDB.ledger, g.OWNED = SAVE2

# ---- 自用只认真在手里的
SAVE4 = (g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings)
g.ForeverQuantDB.ledger = L.table_from([
    f"{T}|BUY|701|0|1|1000|早挂了的|", f"{T+10}|POST|701|0|1|5000|早挂了的|dep=1,dur=2", f"{T+20}|USED|701|0|1|1000|早挂了的|",       # 多记的待上架被清掉时误记的自用
    f"{T}|BUY|702|0|1|2000|真留着的|", f"{T+20}|USED|702|0|1|2000|真留着的|",
    f"{T}|BUY|703|0|1|3000|又挂了的|", f"{T+20}|USED|703|0|1|3000|又挂了的|", f"{T+30}|POST|703|0|1|9000|又挂了的|dep=1,dur=2",
    f"{T}|BUY|704|0|1|1100|甲后缀|", f"{T+1}|BUY|704|0|1|2200|乙后缀|", f"{T+5}|POST|704|0|1|8000|乙后缀|dep=1,dur=2",
])
sm = Lg.Build(); S = Lg.Stats()
rows = {r.name: r for r in Lg.rows.values()}
check("账上没有可销批次的「自用」不算数；真留着的才算", S.usedN[2] == 1 and S.used[2] == 2000 and sm.ghostUsed == 1)
check("标了自用后来又挂出去的：自用作废，成本接到上架那一笔", [r.cost for r in Lg.rows.values() if r.name == "又挂了的" and r.status == "open"] == [3000])
check("同一个物品 ID 的不同后缀：上架先配同名的买入批次", [r.cost for r in Lg.rows.values() if r.name == "乙后缀" and r.status == "open"] == [2200])
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|705|0|1|1000|在包里|"])
g.ForeverQuantDB.holdings = L.table_from([L.table_from(dict(item_id=705, name="在包里", cost=1000, target=5000)),
                                          L.table_from(dict(item_id=706, name="不存在", cost=900, target=5000))])
L.execute("OLD_BN = ForeverQuantLedger.BagNames; ForeverQuantLedger.BagNames = function() return { ['在包里'] = 1 } end")
g.ForeverQuantModes.ClearPending()
used = [x for x in g.ForeverQuantDB.ledger.values() if "|USED|" in x]
check("清空待上架：在背包里的记自用，背包里没有的直接删、不记账", len(used) == 1 and "在包里" in used[0] and len(list(g.ForeverQuantDB.holdings.values())) == 0)
L.execute("ForeverQuantLedger.BagNames = OLD_BN")
g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings = SAVE4

# ---- 挂价不跟着别人的虚高挂价走；改价重挂
SAVE6 = (g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings, g.OWNED)
g.ForeverQuantDB.ledger = L.table_from([
    f"{T}|BUY|801|0|1|2200|卖过的|", f"{T+10}|POST|801|0|1|10000|卖过的|dep=1,dur=2", f"{T+600}|SOLD|0|0|1|0|卖过的|补记",
    f"{T}|BUY|801|0|1|2200|卖过的|", f"{T+20}|POST|801|0|1|11000|卖过的|dep=1,dur=2", f"{T+900}|SOLD|0|0|1|0|卖过的|补记",
])
Lg.Build()
h = L.table_from(dict(name="卖过的", item_id=801, cost=2200, target=9700)); D(h, L.table_from([30000, 31000, 32000]))
check("同款都挂 3 金，但自己前两件是 1 金上下卖的：挂价不超过自己卖出价中位的 1.3 倍", h.post == 13000)
h = L.table_from(dict(name="卖过的", item_id=801, cost=2200, target=28200, relist=1)); D(h, L.table_from([30000, 31000, 32000]))
check("标高到 2.8 金流拍了一次：重挂时回到自己卖出价中位 1 金，不再跟同款的 3 金", h.post == 10000)
h = L.table_from(dict(name="卖过的", item_id=801, cost=2200, target=10000, relist=2)); D(h, L.table_from([30000, 31000, 32000]))
check("按 1 金挂又流拍：再降一成到 90 银", h.post == 9000)
h = L.table_from(dict(name="没卖过的", item_id=802, cost=2200, target=9700)); D(h, L.table_from([30000, 31000, 32000]))
check("没有自己的卖出记录：照旧跟同款", h.post > 28000)
lk = lambda i, n: f"|cff1eff00|Hitem:{i}:0:0:0:0:0:7|h[{n}]|h|r"
own = lambda aid, price, st=0: L.table_from(dict(auctionID=aid, itemLink=lk(801, "卖过的"), status=st, buyoutAmount=price, itemKey=L.table_from(dict(itemID=801))))
g.OWNED = L.table_from([own(1, 29100), own(2, 28200), own(3, 27100), own(4, 11000), own(5, 30000, 1)])
L.execute("CANCELLED = {}; C_AuctionHouse.CancelAuction = function(id) CANCELLED[#CANCELLED + 1] = id end; C_AuctionHouse.CanCancelAuction = function() return true end")
g.ForeverQuantDB.holdings = L.table()
Tr = g.ForeverQuantTrade
g.ForeverQuantAction.key, g.ForeverQuantAction.keyIdx = "F6", 1
n = Tr.Reprice(801, 2, 11500)
check("改价重挂：只排挂得比新价贵的，从最贵的开始，要几件排几件；已售出的不碰", n == 2 and [c.auctionID for c in Tr.cancelQ.values()] == [1, 2])
Tr.cancelAt = 0; Tr.CancelOne()
hs = list(g.ForeverQuantDB.holdings.values())
check("撤一件：撤的是最贵那件，放进待上架并钉死新价", list(g.CANCELLED.values()) == [1] and len(hs) == 1 and hs[0].fixed == 11500)
check("撤单之间留间隔，不连着撤", not Tr.CancelOne() and len(list(g.CANCELLED.values())) == 1)
Tr.cancelQ = L.table(); Tr.repriced = None
Lg.Build()
n = Tr.AutoReprice()
q = [(c.auctionID, c.price) for c in Tr.cancelQ.values()]
check("自动纠正：挂价比自己卖出价中位高一半以上的排去撤，新价 = 卖出价中位的 1.1 倍；挂得合理的和已售出的不动",
      n == 3 and sorted(q) == [(1, 11000), (2, 11000), (3, 11000)])
check("同一批挂单不会重复排", Tr.AutoReprice() == 0)
Tr.cancelQ = L.table(); Tr.repriced = None
g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings, g.OWNED = SAVE6
L.execute("C_AuctionHouse.CancelAuction = nil; C_AuctionHouse.CanCancelAuction = nil")

# ---- 囤够了就不再买
SAVE7 = (g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings)
Tr = g.ForeverQuantTrade
now = int(g.NOW)
gop = lambda name: L.table_from(dict(item_id=7, suffix_id=2, name=name, strategy="GEAR", ikey=L.table(), key=name, max_unit_price=1000, target_unit_price=5000, stars=3, verified=True))
g.ForeverQuantDB.holdings = L.table_from([L.table_from(dict(item_id=7, name="走得慢的", cost=1000, target=5000))])
g.ForeverQuantDB.ledger = L.table_from([
    f"{now-5000}|BUY|7|0|1|1000|走得慢的|", f"{now-4000}|POST|7|0|1|5000|走得慢的|dep=1,dur=2",                                   # 挂着 1 件 + 待上架 1 件 = 2 件，没卖出
    f"{now-9000}|BUY|8|0|1|1000|走得快的|", f"{now-8000}|POST|8|0|1|5000|走得快的|dep=1,dur=2", f"{now-7000}|SOLD|0|0|1|0|走得快的|补记",
    f"{now-9000}|BUY|8|0|1|1000|走得快的|", f"{now-8000}|POST|8|0|1|5000|走得快的|dep=1,dur=2", f"{now-6000}|SOLD|0|0|1|0|走得快的|补记",
    f"{now-900}|BUY|8|0|1|1000|走得快的|", f"{now-800}|POST|8|0|1|5000|走得快的|dep=1,dur=2",
    f"{now-900}|BUY|8|0|1|1000|走得快的|", f"{now-700}|POST|8|0|1|5000|走得快的|dep=1,dur=2",
])
Tr.stockAt = None
check("手里已有 2 件、一天没卖出 2 件：囤够了，不再买", g.ForeverQuantVerdict(gop("走得慢的")) == "full")
check("手里有 2 件但一天卖出过 2 件：走得快，照买", g.ForeverQuantVerdict(gop("走得快的")) == "buy")
check("手里没有的：照买", g.ForeverQuantVerdict(gop("新货")) == "buy")
w = gop("走得慢的"); w.marked, w.wantGap = "want", 0
check("标过「要」的也受这条限制（不会自己越买越多）", g.ForeverQuantVerdict(w) == "full")
g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings = SAVE7
Tr.stockAt = None

# ---- 蓝色武器页的「买这把」
Tr = g.ForeverQuantTrade
g.ForeverQuantAction.key, g.ForeverQuantAction.keyIdx = "F6", 1
L.execute("C_AuctionHouse.MakeItemKey = function(id, lvl, suf) return { itemID = id, itemLevel = lvl, itemSuffix = suf } end")
row = L.table_from(dict(item_id=950, name="行内买的", ilvl=30, now=40000, typ=80000, recent=80000, high=95000))
Tr.queue, Tr.state, Tr.cur = L.table(), "idle", None
check("点「买这把」：排到买入队首，买价上限就是这一行显示的现价", Tr.BuyBlueRow(row) and Tr.queue[1].blueRow.item_id == 950 and Tr.queue[1].max_unit_price == 40000 and Tr.queue[1].strategy == "BLUE")
check("同一行正在买时再点不重复排", not Tr.BuyBlueRow(row) and len(list(Tr.queue.values())) == 1)
row0 = L.table_from(dict(item_id=951, name="没货的", ilvl=30, now=0, typ=80000))
check("没货的行点了没反应", not Tr.BuyBlueRow(row0))
Tr.queue = L.table()

# ---- 查完当场买
Tr = g.ForeverQuantTrade
A = g.ForeverQuantAction; A.key, A.keyIdx = "F6", 1
def cand(**kw):
    return L.table_from(dict(dict(item_id=7, suffix_id=2, name="y", strategy="GEAR", ikey=L.table(), key="7:2:1000", max_unit_price=1000,
                                  target_unit_price=5000, stars=3, verified=True), **kw))
best = lambda price: L.table_from({"auctionID": 99, "buyoutAmount": price})
Tr.on, Tr.state, Tr.queue = True, "idle", L.table()
c = cand()
check("刚查完同款、该买的：不排队重查，当场进待买", Tr.Direct(c, best(1000)) and Tr.state == "ready" and Tr.ready.auctionID == 99 and Tr.done["7:2:1000"])
Tr.state, Tr.cur, Tr.ready = "idle", None, None
check("同一条挂单不会买第二次", not Tr.Direct(c, best(1000)))
check("最便宜的那条已经涨过建议买价：不买", not Tr.Direct(cand(key="7:2:b"), best(1200)) and Tr.state == "idle")
check("不够格的（二星差价不到 3 倍）：不买", not Tr.Direct(cand(key="7:2:c", stars=2, target_unit_price=2500), best(1000)))
Tr.on = False
check("自动买入关着：不买", not Tr.Direct(cand(key="7:2:d"), best(1000)))
Tr.on = True
# 建议那一列：动过手的写结果
col = [c for c in g.ForeverQuantDebugCols("gear").values() if c[1] == "建议"][0][4] if g.ForeverQuantDebugCols else None
if col:
    c2 = cand(key="7:2:z")
    check("没动过的写建议", "买" in col(c2) and "买到" not in col(c2))
    Tr.cur = c2; check("正在买的写买入中", "买入中" in col(c2)); Tr.cur = None
    Tr.outcome["7:2:z"] = "yes"; check("买到的写买到了", "买到了" in col(c2))
    Tr.outcome["7:2:z"] = "no"; check("没抢到的写没买到", "没买到" in col(c2))
Tr.on, Tr.state, Tr.queue = False, "idle", L.table()

# ---- 不打扰你看货
V = g.ForeverQuantView
L.execute("""
C_AuctionHouse = C_AuctionHouse or {}
C_AuctionHouse.IsThrottledMessageSystemReady = function() return true end
SENT = {}
C_AuctionHouse.SendSearchQuery = function(key) SENT[#SENT + 1] = key end
OLD_AH = AuctionHouseFrame
PAGE = { shown = true, itemKey = 'mine', IsShown = function(self) return self.shown end }
OVER = true
AuctionHouseFrame = { ItemBuyFrame = PAGE, IsMouseOver = function() return OVER end, IsShown = function() return true end }
""")
check("你的鼠标停在某件物品的挂单页上：后台查询先停", V.Hover() and not V.Ready())
g.OVER = False
check("鼠标移开：照常查，并记下把你那页冲掉了", V.Ready() and (V.Search("theirs", L.table(), False) or True) and V.dirty)
g.OVER = True
L.execute("VIEW_TICK = ForeverQuantView.frame"); V.Tick() if V.Tick else None
check("鼠标移回来：先把你那页重查一遍", list(g.SENT.values())[-1] == "mine" and not V.dirty and not V.Ready())
L.execute("AuctionHouseFrame = OLD_AH; ForeverQuantView.restoring = nil; C_AuctionHouse.SendSearchQuery = nil; C_AuctionHouse.IsThrottledMessageSystemReady = nil")

# ---- 高概率池
Pl = g.ForeverQuantPool
g.ForeverQuantDB.marks = L.table()
kn = lambda i, best, **kw: L.table_from(dict(dict(id=i, name="货%d" % i, suffix=7, target=6000, buy=1500, stars=best, best=best, ilvl=30, t=i), **kw))
g.ForeverQuantDB.known = L.table_from({"a": kn(1, 1), "b": kn(2, 2), "c": kn(3, 3), "d": kn(4, 3)})
g.ForeverQuantDB.marks["4:7"] = "no"; g.ForeverQuantDB.marks["1:7"] = "want"
order = [e.kn.id for e in Pl.Build().values()]
check("池子：标「要」的最先；标「不要」的不进", order[0] == 1 and 4 not in order and sorted(order) == [1, 2, 3])
g.ForeverQuantDB.marks = L.table()
g.ForeverQuantDB.known = L.table_from({"a": kn(51, 3, target=4000, buy=1000), "b": kn(52, 2, target=9000, buy=1000), "c": kn(53, 2, target=3500, buy=1000),
                                       "d": kn(54, 3, target=2500, buy=500)})
g.ForeverQuantDB.ledger = L.table_from([f"{T}|POST|53|0|1|3500|货53|dep=1", f"{T+5}|SOLD|0|0|1|0|货53|"])
Pl.soldAt = None
check("优先级：差价 × 卖出加成；卖过的小货排在同档没卖过的前面，但挤不掉大差价的；能卖价不到 30s 的不进池",
      [e.kn.id for e in Pl.Build().values()] == [52, 53, 51])
g.ForeverQuantDB.known = L.table_from({str(i): kn(i, 3, target=3000 + i * 10) for i in range(1, 131)})
ids = [e.kn.id for e in Pl.Build().values()]
check("池子封顶 100 件，留下的是差价最大的", len(ids) == 100 and min(ids) == 31)
g.ForeverQuantDB.favCap = 40
check("偏好位更少时按偏好位封顶", len(list(Pl.Build().values())) == 40)
g.ForeverQuantDB.favCap = None
# 蓝色武器超低价单
L.execute("ForeverQuantRecommendations.blue = ForeverQuantRecommendations.blue or { at = 0, items = {} }")
L.execute("table.insert(ForeverQuantRecommendations.blue.items, { item_id = 900, name = '测试蓝剑', kind = '单手剑', req = 19, ilvl = 24, cur = 80000, qty = 5, typ = 80000, low = 70000, high = 90000, recent = 80000, spd = 10, points = 100, snipe = '小号', line = 48000, ref = 80000 })")
g.ForeverQuantDB.known = L.table_from({str(i): kn(i, 3, target=3000 + i * 10) for i in range(1, 131)})
check("蓝武不占偏好池的位子", not [e for e in Pl.Build().values() if e.kn.id == 900] and len(list(Pl.Build().values())) == 100)
ents = Pl.BlueEntries()
check("要盯的蓝武单独成一份名单", ents[900] is not None and ents[900].kn.blue == "小号")
mk = lambda iid, price, suf=0: L.table_from(dict(itemKey=L.table_from(dict(itemID=iid, itemSuffix=suf, itemLevel=24)), minPrice=price))
check("蓝武那一遍浏览的结果：没到买入线的不细查", len(list(Pl.BlueResults(L.table_from([mk(900, 60000), mk(12345, 100)])).values())) == 0 and Pl.blueSeen == 1)
q = list(Pl.BlueResults(L.table_from([mk(900, 70000), mk(900, 40000)])).values())
check("低于买入线的排去细查，用的是拍卖行给的物品键", len(q) == 1 and q[0].kn.id == 900 and L.eval("ForeverQuantPool.keys['900:0'].itemLevel") == 24)
check("蓝武那一遍顺带记下所有蓝武的现价和件数（「蓝色武器」页用）", L.eval("ForeverQuantPool.blueLive[900].price") == 40000 and L.eval("ForeverQuantPool.blueLive[900].qty") == 2)
Pl.pull = True; g.LAST = ""
Pl.BlueResults(L.table_from([mk(900, 70000)]))
check("点「刷新现价」拉回来后报一句，并且收起刷新中的状态", "现价已刷新" in g.LAST and not Pl.pull)
L.execute("ForeverQuantPool.blueLive = nil")
Pl.bq, Pl.wantBlue = None, None
check("接在快扫后面扫蓝武；已经在扫就不重复开", Pl.StartBlue(False) and Pl.bq is not None and not Pl.StartBlue(False) and Pl.Busy())
Pl.bq = None
e = ents[900]; e.ikey = L.table()
check("蓝武价没到买入线（六成）：不提醒", Pl.Judge(e, L.table_from([50000, 80000])) is None)
check("二十把都挂得差不多低：那是行情不是漏，哪怕比历史价低一大截也不提醒", Pl.Judge(e, L.table_from([12800] + [13000 + i * 100 for i in range(19)])) is None)
o = Pl.Judge(e, L.table_from([40000, 41000, 75000, 80000, 82000]))
check("蓝武明显低于其它挂单、可比的有两把以上：建议是「买」；挂价按其它挂单的中位价、不高于历史价",
      o is not None and o.strategy == "BLUE" and g.ForeverQuantVerdict(o) == "buy" and o.target_unit_price == 75000 and o.peer != "flat")
o2 = Pl.Judge(e, L.table_from([40000]))
check("只有这一把在卖：用行情站的历史价当参照，但只提醒不自动买", o2 is not None and o2.target_unit_price == 80000 and g.ForeverQuantVerdict(o2) == "look")
Tr.on, Tr.blueOn = True, False
check("蓝武开关关着：绿装的「自动买入」开着也不会买蓝武", not Tr.Direct(o, best(40000)))
gl = L.table(); gl[1] = o
Tr.on, Tr.blueOn = False, True
check("蓝武开关开着、可比的太少：不买", not Tr.Direct(o2, best(40000)))
check("蓝武开关开着、明显的漏：直接买，不用开绿装的「自动买入」", Tr.Direct(o, best(40000)) and Tr.state == "ready")
Tr.on, Tr.state, Tr.cur, Tr.ready, Tr.queue = False, "idle", None, None, L.table()
big = Pl.Judge(e, L.table_from([40000, 41000, 75000, 80000, 82000])); big = big or o
o.max_unit_price = 110000
check("单把超过 10 金：不自动买，只提醒", g.ForeverQuantVerdict(o) == "look")
o.max_unit_price = 40000
SAVE3 = g.ForeverQuantDB.ledger
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|900|0|1|90000|测试蓝剑|", f"{T}|BUY|900|0|1|80000|测试蓝剑|"])
Pl.blueHeldAt = None
check("手里蓝武已经压了 17 金，再买 4 金就超 20 金：不自动买", Pl.BlueHeld() == 170000 and g.ForeverQuantVerdict(o) == "look")
g.ForeverQuantDB.ledger = SAVE3; Pl.blueHeldAt = None
check("没压货时照常买", g.ForeverQuantVerdict(o) == "buy")
# 控价的货
g.ForeverQuantDB.control = L.table_from({"测试蓝剑": L.table_from(dict(ask=90000, bid=60000))})
ce = Pl.BlueEntries()[900]; ce.ikey = L.table()
check("控价的货：收货线和挂价用你定的", ce.kn.blue == "控价" and ce.kn.line == 60000 and ce.kn.target == 90000)
SAVE5 = (g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings)
g.ForeverQuantDB.ledger = L.table(); g.ForeverQuantDB.holdings = L.table()
co = Pl.Judge(ce, L.table_from([55000, 58000, 70000, 80000]))
check("有人挂到收货线以下：建议是「买」（自动买入开着才真买），哪怕没比别人便宜四成", co is not None and g.ForeverQuantVerdict(co) == "buy" and co.target_unit_price == 90000)
check("都在收货线以上：不管", Pl.Judge(ce, L.table_from([65000, 70000])) is None)
Tr.on, Tr.blueOn, Tr.state, Tr.cur, Tr.ready = False, False, "idle", None, None
L.execute("OLD_MONEY = GetMoney; function GetMoney() return 500000 end")
check("蓝武开关关着：控价的货也不收", not Tr.Direct(co, best(55000)))
Tr.blueOn = True
check("蓝武开关开着：控价的货在收货线以下就收，不看绿装的开关", Tr.Direct(co, best(55000)) and Tr.state == "ready")
L.execute("GetMoney = OLD_MONEY")
Tr.state, Tr.cur, Tr.ready = "idle", None, None
g.LAST = ""
L.execute("ForeverQuantTrade.ctlSayAt = 0; ForeverQuantTrade.ctlScanAt = 1e12; ForeverQuantTrade.ControlTick(true)")
check("定时报状态：有变化才说一句", "控价" in (g.LAST or "") and "测试蓝剑" in g.LAST)
g.LAST = ""
L.execute("ForeverQuantTrade.ctlSayAt = 0; ForeverQuantTrade.ControlTick(true)")
check("没变化不重复说", "控价" not in (g.LAST or ""))
Tr.blueOn = False
g.ForeverQuantDB.holdings = L.table_from([L.table_from(dict(item_id=900, name="测试蓝剑", cost=50000, target=90000)) for _ in range(12)])
check("手里加挂着已经 12 把：到上限了，只提醒不再收", g.ForeverQuantVerdict(co) == "look")
# 排班：最多挂 3 把，先补前排 7 金，其余 9 金，多的按住
g.ForeverQuantDB.holdings = L.table()
for _ in range(5): Tr.AddHolding(900, 0, "测试蓝剑", 50000, 90000)
Tr.ControlPlan()
hs = list(g.ForeverQuantDB.holdings.values())
check("控价的货进待上架但先按住，一次只放行一把：前排没货先挂 7 金", [bool(h.hold) for h in hs] == [False, True, True, True, True] and hs[0].post == 70000 and all(Tr.Postable(h) == (i == 0) for i, h in enumerate(hs)))
now = int(g.NOW)
g.ForeverQuantDB.ledger = L.table_from([f"{now-100}|POST|900|0|1|70000|测试蓝剑|dep=1,dur=2"])
g.ForeverQuantDB.holdings = L.table_from(hs[1:])
Tr.ControlPlan(); hs = list(g.ForeverQuantDB.holdings.values())
check("前排已经有一把：下一把挂计划价 9 金", hs[0].post == 90000 and not hs[0].hold and hs[1].hold)
g.ForeverQuantDB.ledger = L.table_from([f"{now-100}|POST|900|0|1|70000|测试蓝剑|dep=1,dur=2", f"{now-90}|POST|900|0|1|90000|测试蓝剑|dep=1,dur=2", f"{now-80}|POST|900|0|1|90000|测试蓝剑|dep=1,dur=2"])
Tr.ControlPlan(); hs = list(g.ForeverQuantDB.holdings.values())
check("已经挂了 3 把：剩下的全按住，等卖掉再补", all(h.hold for h in hs) and not any(Tr.Postable(h) for h in hs))
g.ForeverQuantDB.ledger = L.table_from([f"{now-90}|POST|900|0|1|90000|测试蓝剑|dep=1,dur=2", f"{now-80}|POST|900|0|1|90000|测试蓝剑|dep=1,dur=2"])
Tr.ControlPlan(); hs = list(g.ForeverQuantDB.holdings.values())
check("前排那把卖掉了：补一把到前排", hs[0].post == 70000 and not hs[0].hold)
g.ForeverQuantDB.ledger, g.ForeverQuantDB.holdings = SAVE5
g.ForeverQuantDB.control = L.table()
g.ForeverQuantDB.marks["900:0"] = "no"
check("蓝武标了「不要」就不再盯", Pl.BlueEntries()[900] is None)
g.ForeverQuantDB.marks = L.table()
L.execute("table.remove(ForeverQuantRecommendations.blue.items)")
g.ForeverQuantDB.ledger = L.table(); Pl.soldAt = None
e = L.table_from(dict(kn=kn(9, 3), ikey=L.table()))
o = Pl.Judge(e, L.table_from([2000, 6500, 6800, 7000]))
check("池内装备出现 20s（同款 65s 起）：成为候选，三星已验证，目标贴着同款", o is not None and o.model_stars == 3 and o.model_verified and o.target_unit_price == 6300)
check("池内装备现在最低 40s（不到目标价一半的差距）：不算", Pl.Judge(e, L.table_from([4000, 6500])) is None)
check("没货：不算", Pl.Judge(e, L.table_from([])) is None)
# ---- 星级和差价是两个独立指标
V = g.ForeverQuantVerdict
def cand(stars, buy, target, verified=True, **kw):
    return L.table_from(dict(dict(strategy="GEAR", stars=stars, verified=verified, max_unit_price=buy, target_unit_price=target), **kw))
check("三星、已验证、差价 3 倍：买", V(cand(3, 2000, 6000)) == "buy")
check("三星但差价只有 2 倍：犹豫，不自动买", V(cand(3, 3000, 6000)) == "hesitate")
check("二星、已验证、差价 5 倍：买", V(cand(2, 1200, 6000)) == "buy")
check("二星、没验证、差价 5 倍：值得看，不自动买", V(cand(2, 1200, 6000, verified=False)) == "look")
check("二星、已验证、差价 3 倍：买（起买线从 4 倍降到 3 倍）", V(cand(2, 2000, 6000)) == "buy")
check("二星、差价 2.8 倍：不买", V(cand(2, 2000, 5600)) == "skip")
o = op(1200, 3500, stars=2); P.Apply(o, peers(6500, 6800, 7000)); o.stars, o.verified, o.strategy = o.model_stars, o.model_verified, "GEAR"
check("二星、特别便宜、同款抬轿子（三件 65s 起）：买", V(o) == "buy")
check("同款也只值这个价：不买", V(cand(3, 2000, 6000, peer="flat")) == "skip")
check("标「要」时差价 3.2 倍：以后 3.2 倍及以上才买，星级不变", V(cand(1, 1000, 3300, marked="want", wantGap=3.2)) == "buy"
      and V(cand(1, 1500, 3300, verified=False, marked="want", wantGap=3.2)) == "skip")
check("你标了「要」：买；标了「不要」：不买", V(cand(1, 5000, 6000, marked="want")) == "buy" and V(cand(3, 1000, 6000, marked="no")) == "skip")
# ---- 偏好批量快扫
L.execute("""
FAVS, FAVMAX = {}, 3
C_AuctionHouse.MakeItemKey = function(id, ilvl, suffix) return { itemID = id, itemLevel = ilvl, itemSuffix = suffix } end
C_AuctionHouse.SetFavoriteItem = function(k, on) FAVS[k.itemID .. ":" .. k.itemSuffix] = on or nil end
C_AuctionHouse.HasMaxFavorites = function() local n = 0 for _ in pairs(FAVS) do n = n + 1 end return n >= FAVMAX end
C_AuctionHouse.SearchForFavorites = function() end
ForeverQuantScan.running = false
""")
g.ForeverQuantDB.marks = L.table()
g.ForeverQuantDB.known = L.table_from({"a": kn(11, 3), "b": kn(12, 3), "c": kn(13, 2), "d": kn(14, 2)})
check("开始快扫：走偏好批量", Pl.Start() and Pl.how == "偏好批量" and Pl.fav is not None)
check("偏好只放得下 3 件：只占 3 个位，并记下容量", len(list(g.FAVS.keys())) == 3 and g.ForeverQuantDB.favCap == 3)
res = L.table_from([L.table_from(dict(itemKey=L.table_from(dict(itemID=11, itemSuffix=7)), minPrice=2000)),      # 20s，目标 60s：够便宜
                    L.table_from(dict(itemKey=L.table_from(dict(itemID=12, itemSuffix=7)), minPrice=5500))])     # 55s：不够
q = [e.kn.id for e in Pl.FavResults(res).values()]
left_out = [i for i in (11, 12, 13, 14) if f"{i}:7" not in list(g.FAVS.keys())]
check("批量结果：够便宜的去细查；偏好位以外的轮流查", sorted(q) == sorted(([11] if "11:7" in list(g.FAVS.keys()) else []) + left_out) and Pl.fav is None)
Pl.queue = L.table()
g.ForeverQuantDB.known = L.table_from({"a": kn(11, 3)})
Pl.Start()
check("出了池子的：只取消自己设的偏好", list(g.FAVS.keys()) == ["11:7"])
Pl.fav = None; Pl.queue = L.table()
# ---- 买卖记录里逐件「不卖了 / 再上架」
L.execute("C_Container.GetContainerItemLink = function() return nil end")
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|21|0|1|1000|留着穿的|", f"{T}|BUY|22|0|1|2000|要卖的|"])
g.ForeverQuantDB.holdings = L.table_from([L.table_from(dict(item_id=21, suffix_id=0, name="留着穿的", cost=1000, target=5000)),
                                          L.table_from(dict(item_id=22, suffix_id=0, name="要卖的", cost=2000, target=6000))])
Lg.Build(); row = [r for r in Lg.rows.values() if r.name == "留着穿的"][0]
g.ForeverQuantModes.Relist(row)
names = [h.name for h in g.ForeverQuantDB.holdings.values()]
S = Lg.Stats()
check("点「不卖了」：只把这一件拿出待上架、记成自用，别的不动", names == ["要卖的"] and S.usedN[2] == 1 and S.heldCost == 2000)
row = [r for r in Lg.rows.values() if r.status == "used"][0]
g.ForeverQuantModes.Relist(row)
names = sorted(h.name for h in g.ForeverQuantDB.holdings.values()); S = Lg.Stats()
check("点「再上架」：放回待上架，成本回到压货", names == ["留着穿的", "要卖的"] and S.usedN[2] == 0 and S.heldCost == 3000)
g.ForeverQuantDB.holdings = L.table()

# ---- 流拍：放回待上架
g.NOW = T + 90000                                                   # 挂了 25 小时
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|31|0|1|1000|到期的|", f"{T+10}|POST|31|0|1|5000|到期的|dep=100,dur=2",
                                        f"{T+80000}|BUY|32|0|1|1000|刚卖的|", f"{T+80010}|POST|32|0|1|4000|刚卖的|dep=80,dur=2"])
g.ForeverQuantDB.holdings = L.table()
g.OWNED = L.table()                                                 # 我的拍卖里两件都不见了
g.ForeverQuantDB.fixedUnknown, g.ForeverQuantDB.settledOld = True, True
Lg.Reconcile(); Lg.Build()
st = {r.name: r.status for r in Lg.rows.values() if r.price}
check("对账：挂满时长才不见的分不清卖没卖，记去向不明；没到期就不见的算卖出", st == {"到期的": "unknown", "刚卖的": "sold"})
S = Lg.Stats()
check("去向不明的不算卖出、不算净赚、不放进待上架，单列出来", S.unkN == 1 and S.sold[2] == 1 and len(list(g.ForeverQuantDB.holdings.values())) == 0)
# 信箱给准信
L.execute("""
MAILS = { { sender = '部落拍卖行', days = 29.99, items = 1, item = '到期的' } }
function GetInboxNumItems() return #MAILS end
function GetInboxHeaderInfo(i) local m = MAILS[i] return nil, nil, m.sender, 'x', 0, 0, m.days, m.items end
function GetInboxInvoiceInfo(i) local m = MAILS[i] if m.invoice then return 'seller', m.item, '买家', 0, m.buyout end end
function GetInboxItem(i, n) return MAILS[i].item end
""")
paid, back = Lg.MailScan()
Lg.Build(); st = {r.name: r.status for r in Lg.rows.values() if r.price}
hs = [(h.name, h.cost, h.target) for h in g.ForeverQuantDB.holdings.values()]
check("信箱里有拍卖行退回的那件：判明是流拍，放回待上架（成本照旧，暂定上次的挂价）", (paid, back) == (0, 1) and st["到期的"] == "expired" and hs == [("到期的", 1000, 5000)])
check("同一封信再看一遍不重复记", Lg.MailScan() == (0, 0))
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|37|0|1|1000|没退信的|", f"{T+10}|POST|37|0|1|5000|没退信的|dep=1,dur=2", f"{T+89000}|UNKNOWN|0|0|1|0|没退信的|"])
L.execute("ForeverQuantLedger.BagNames = EMPTY_BAG")
paid, back = Lg.MailScan(); Lg.Build(); r = [r for r in Lg.rows.values() if r.price][0]
check("信箱看全了、没有它的退货信、背包里也没有：只能是卖了，按卖出入账", paid == 1 and r.status == "sold" and r.net == 3750 and r.fix)
# 按件数核对：买 2 件，现在挂着 1 件，手里没有 -> 只卖了 1 件；三笔去向不明里最近一笔算卖出，前两笔是流拍重挂
g.ForeverQuantDB.ledger = L.table_from([
    f"{T}|BUY|38|0|1|1000|核对的|", f"{T}|BUY|38|0|1|1200|核对的|",
    f"{T+10}|POST|38|0|1|5000|核对的|dep=1,dur=2", f"{T+11}|POST|38|0|1|5000|核对的|dep=1,dur=2",
    f"{T+100}|UNKNOWN|0|0|1|0|核对的|", f"{T+101}|UNKNOWN|0|0|1|0|核对的|",
    f"{T+200}|POST|38|0|1|4500|核对的|dep=1,dur=2", f"{T+300}|UNKNOWN|0|0|1|0|核对的|", f"{T+400}|POST|38|0|1|4000|核对的|dep=1,dur=2",
])
n = Lg.SettleUnknown("测试"); sm = Lg.Build(); S = Lg.Stats()
stc = sorted(r.status for r in Lg.rows.values() if r.price)
check("买 2 挂着 1 手里 0：三笔去向不明里 1 笔算卖出、2 笔是流拍重挂；成本都配得上、不多出没挂的货",
      n == 1 and stc == ["expired", "expired", "open", "sold"] and S.heldN == 0 and S.goneN == 0 and S.listedNoCost == 0 and S.sold[2] == 1)
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|39|0|1|1000|没挂过的|"])
S = Lg.Stats()
check("买了没挂、手里也没有：单列成「账上有、手里没有」，不算压货", (S.goneN, S.goneCost, S.heldN) == (1, 1000, 0))
L.execute("ForeverQuantLedger.BagNames = ALL_IN_HAND")
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|31|0|1|1000|到期的|", f"{T+10}|POST|31|0|1|5000|到期的|dep=100,dur=2", f"{T+89000}|UNKNOWN|0|0|1|0|到期的|"])
g.ForeverQuantDB.mailSeen = L.table(); g.ForeverQuantDB.holdings = L.table()
L.execute("MAILS = { { sender = '部落拍卖行', days = 29.99, items = 0, item = '到期的', invoice = true, buyout = 5000 } }")
paid, back = Lg.MailScan(); Lg.Build(); r = [r for r in Lg.rows.values() if r.price][0]
check("信箱里是货款信（带发票）：判明是卖出，净赚照算", (paid, back) == (1, 0) and r.status == "sold" and r.net == 3750)
# 流拍后又挂了一次：上一笔推断的卖出不可能成立
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|33|0|1|1000|重挂的|", f"{T+10}|POST|33|0|1|5000|重挂的|dep=100,dur=2", f"{T+40000}|SOLD|0|0|1|0|重挂的|补记",
                                        f"{T+50000}|POST|33|0|1|4500|重挂的|dep=100,dur=2"])
Lg.Build(); rs = sorted([(r.posted, r.status, r.cost) for r in Lg.rows.values() if r.price])
check("同一件没有新买入却又挂了一次：上一笔「推断卖出」改成流拍，成本接到新的一笔", rs == [(T + 10, "expired", 1000), (T + 50000, "open", 1000)])
# 老账更正
g.ForeverQuantDB.ledger = L.table_from([f"{T}|BUY|34|0|1|1000|拖很久的|", f"{T+10}|POST|34|0|1|5000|拖很久的|dep=1,dur=2", f"{T+88000}|SOLD|0|0|1|0|拖很久的|补记",
                                        f"{T}|BUY|35|0|1|1000|很快卖的|", f"{T+10}|POST|35|0|1|5000|很快卖的|dep=1,dur=2", f"{T+3000}|SOLD|0|0|1|0|很快卖的|补记"])
g.ForeverQuantDB.fixedUnknown, g.ForeverQuantDB.settledOld = None, None; g.ForeverQuantDB.durHours = L.table_from({2: 24})
L.execute("OLD_BN2 = ForeverQuantLedger.BagNames; ForeverQuantLedger.BagNames = function() return { ['还在包里的'] = 1 } end")
g.ForeverQuantDB.ledger[len(list(g.ForeverQuantDB.ledger.values())) + 1] = f"{T}|BUY|36|0|1|1000|还在包里的|"
g.ForeverQuantDB.ledger[len(list(g.ForeverQuantDB.ledger.values())) + 1] = f"{T+10}|POST|36|0|1|5000|还在包里的|dep=1,dur=2"
g.ForeverQuantDB.ledger[len(list(g.ForeverQuantDB.ledger.values())) + 1] = f"{T+88000}|SOLD|0|0|1|0|还在包里的|补记"
n = Lg.FixHistory(); Lg.Build(); st = {r.name: r.status for r in Lg.rows.values() if r.price}
check("更正老账：到期后才记上的卖出先打回去向不明；不在背包也没重挂的按排除法算卖出，背包里还有的留给背包去认",
      n == 2 and st == {"拖很久的": "sold", "很快卖的": "sold", "还在包里的": "unknown"} and Lg.FixHistory() == 0)
nb = Lg.BagCheck(); Lg.Build()
check("背包那一步把剩下那件认成流拍", nb == 1 and {r.name: r.status for r in Lg.rows.values() if r.price}["还在包里的"] == "expired")
g.ForeverQuantDB.holdings = L.table()
L.execute("ForeverQuantLedger.BagNames = OLD_BN2")
g.ForeverQuantDB.durHours = None; g.ForeverQuantDB.mailSeen = None
L.execute("GetInboxNumItems = nil")
Lg.OnSystemMessage("你拍卖的不存在的东西已经过期。")
check("收到「已经过期」的消息：账上找不到的只记一笔，不乱加待上架", len(list(g.ForeverQuantDB.holdings.values())) == 0)
g.ForeverQuantDB.holdings = L.table(); g.NOW = 1794520000

# ---- 每个页签都真的刷一遍（模拟环境里控件是假的，但表格内容、文字格式都会实际算）
L.execute('GetRealZoneText = function() return "测试区" end; GetSubZoneText = function() return "" end; GetZoneText = GetRealZoneText; GetMinimapZoneText = GetRealZoneText')
L.execute("TABERR = {}; for _, m in ipairs({'gear','blue','recipe','ledger','tod','biz','de','watch','fish'}) do local okk, err = pcall(ForeverQuantDebugGo, m); if not okk then TABERR[#TABERR + 1] = m .. ': ' .. tostring(err) end end")
errs = list(g.TABERR.values())
for e in errs: print("   ", e)
check("九个页签逐个打开都不报错", not errs)
print("全部通过" if ok else "有失败项")
sys.exit(0 if ok else 1)
