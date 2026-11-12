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
check("流拍的标成流拍，不算卖出", rows["孤狼之歹徒短裤"].status == "expired" and rows["孤狼之歹徒短裤"].net is None)
check("自己钓的鱼没有买入价：算卖出但不计入净赚", rows["油性黑口鱼"].status == "sold" and rows["油性黑口鱼"].cost is None)
check("买了没挂的列为持有", rows["山地护肩"].status == "held" and rows["山地护肩"].qty == 3)
check("没有上架记录的卖出也记一行", rows["装插件之前挂的东西"].status == "sold")
check("汇总：卖出 3 笔，1 笔有净赚，2 笔缺买入价，流拍 1", (s.sold, s.noCost, s.expired, s.open) == (3, 2, 1, 0) and s.net == int(9405 * 0.95) - 2400)

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
Lg.OnSystemMessage("你的拍卖品强盗之粗鲁手套已售出。")
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
# ---- 高概率池
Pl = g.ForeverQuantPool
g.ForeverQuantDB.marks = L.table()
kn = lambda i, best, **kw: L.table_from(dict(dict(id=i, name="货%d" % i, suffix=7, target=6000, buy=1500, stars=best, best=best, ilvl=30, t=i), **kw))
g.ForeverQuantDB.known = L.table_from({"a": kn(1, 1), "b": kn(2, 2), "c": kn(3, 3), "d": kn(4, 3)})
g.ForeverQuantDB.marks["4:7"] = "no"; g.ForeverQuantDB.marks["1:7"] = "want"
order = [e.kn.id for e in Pl.Build().values()]
check("池子：标「要」的最先，然后三星、二星；标「不要」的不进", order == [1, 3, 2])
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
check("二星、差价 3 倍：不买", V(cand(2, 2000, 6000)) == "skip")
o = op(1200, 3500, stars=2); P.Apply(o, peers(6500, 6800, 7000)); o.stars, o.verified, o.strategy = o.model_stars, o.model_verified, "GEAR"
check("二星、特别便宜、同款抬轿子（三件 65s 起）：买", V(o) == "buy")
check("同款也只值这个价：不买", V(cand(3, 2000, 6000, peer="flat")) == "skip")
check("你标了「要」：买；标了「不要」：不买", V(cand(1, 5000, 6000, marked="want")) == "buy" and V(cand(3, 1000, 6000, marked="no")) == "skip")
print("全部通过" if ok else "有失败项")
sys.exit(0 if ok else 1)
