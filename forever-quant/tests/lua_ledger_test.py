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
S = Lg.Stats()
check("压在货上的钱 = 在售的成本 + 没挂的成本 + 流拍退回的成本", (S.listedCost, S.heldCost, S.stock) == (2000, 1500 + 800, 4300) and S.heldN == 2)
check("垫着的押金只算在售的；流拍的押金记成损失", S.depHeld == 200 and S.depLost[2] == 50)
check("现金流：卖货收回 4750 - 买货 5300 - 押金损失 50", S.back[2] == 4750 and S.buy[2] == 5300 and S.flow[2] == 4750 - 5300 - 50)
check("已实现净赚 3750；资产 = 现金 + 货 + 押金", S.profit[2] == 3750 and S.assets == 50000 + 4300 + 200)
check("全卖光的话：现金 + 在售挂牌价扣抽成 + 押金 + 没挂的货", S.ifSold == 50000 + int(8000 * 0.95) + 200 + 2300)
g.NOW = T + 1800            # 卖出才 20 分钟：钱还被拍卖行押着
S = Lg.Stats()
check("卖出不到一小时：货款算「没到账」，不算收回，但算资产", (S.transit, S.transitN, S.back[2]) == (4750, 1, 0) and S.flow[2] == -5300 - 50
      and S.assets == 50000 + 4300 + 200 + 4750 and S.profit[2] == 3750)
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
Tr.on, Tr.state, Tr.queue = False, "idle", L.table()

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
Lg.Reconcile(); Lg.Build()
st = {r.name: r.status for r in Lg.rows.values() if r.status in ("sold", "expired")}
hs = [(h.name, h.cost, h.target) for h in g.ForeverQuantDB.holdings.values()]
check("对账：挂满 24 小时不见的算流拍，没挂满的算卖出", st == {"到期的": "expired", "刚卖的": "sold"})
check("流拍的自动放回待上架：成本照旧，暂定上次的挂价", hs == [("到期的", 1000, 5000)])
Lg.OnSystemMessage("你拍卖的不存在的东西已经过期。")
check("收到「已经过期」的消息也走同一条路（账上找不到的只记一笔，不乱加待上架）", len(list(g.ForeverQuantDB.holdings.values())) == 1)
g.ForeverQuantDB.holdings = L.table(); g.NOW = 1794520000

# ---- 每个页签都真的刷一遍（模拟环境里控件是假的，但表格内容、文字格式都会实际算）
L.execute('GetRealZoneText = function() return "测试区" end; GetSubZoneText = function() return "" end; GetZoneText = GetRealZoneText; GetMinimapZoneText = GetRealZoneText')
L.execute("TABERR = {}; for _, m in ipairs({'gear','blue','recipe','ledger','tod','biz','de','watch','fish'}) do local okk, err = pcall(ForeverQuantDebugGo, m); if not okk then TABERR[#TABERR + 1] = m .. ': ' .. tostring(err) end end")
errs = list(g.TABERR.values())
for e in errs: print("   ", e)
check("九个页签逐个打开都不报错", not errs)
print("全部通过" if ok else "有失败项")
sys.exit(0 if ok else 1)
