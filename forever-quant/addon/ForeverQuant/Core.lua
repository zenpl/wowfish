-- ForeverQuant：展示 Python 生成的建议。只读行情、帮你搜索；不出价、不购买、不上架。
local ROWS, ROW_H, WIDTH, NCOL = 16, 22, 880, 10
local data = ForeverQuantRecommendations or {}
local gearAll = data.opportunities or {}
local gearBudget = {}
for _, op in ipairs(gearAll) do if op.affordable then gearBudget[#gearBudget + 1] = op end end
local showAll = false
local gear = gearBudget             -- 当前显示的那份；按钮在"本金内 / 全部"之间切换
local recipes = data.recipes or {}
local deList = data.disenchant or {}
local watches = data.watch or {}
local watchLiveAt
local AH_CUT = data.ah_cut or 0.05
local mode, offset, rows, headers = "gear", 0, {}, {}
local liveAt                     -- 配方价格最后一次在游戏内刷新的时间

local function Money(c)
    c = math.floor(c or 0)
    local neg = c < 0
    if neg then c = -c end
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t
    if g > 0 then t = string.format("|cffffd700%dg|r |cffc7c7cf%ds|r", g, s)
    elseif s > 0 then t = string.format("|cffc7c7cf%ds|r |cffeda55f%dc|r", s, k)
    else t = string.format("|cffeda55f%dc|r", k) end
    return neg and ("|cffff4040-|r" .. t) or t
end

-- 装备用的计价：舍掉铜的零头，最小单位是银
local function Silver(c)
    c = math.floor(c or 0)
    local neg = c < 0
    if neg then c = -c end
    local g, s = math.floor(c / 10000), math.floor(c / 100) % 100
    local t
    if g > 0 then t = string.format("|cffffd700%dg|r", g) .. (s > 0 and string.format(" |cffc7c7cf%ds|r", s) or "")
    elseif s > 0 then t = string.format("|cffc7c7cf%ds|r", s)
    else t = "|cff808080<1s|r" end
    return neg and ("|cffff4040-|r" .. t) or t
end
local function SilverText(c)        -- 不带颜色的版本，写进说明文字里
    c = math.floor(c or 0)
    local g, s = math.floor(c / 10000), math.floor(c / 100) % 100
    if g > 0 then return s > 0 and string.format("%dg %ds", g, s) or string.format("%dg", g) end
    return s > 0 and string.format("%ds", s) or "<1s"
end

local function Age(t)
    if not t or t == 0 then return "?" end
    local m = math.floor((time() - t) / 60)
    if m < 1 then return "刚刚" end
    if m < 60 then return m .. " 分钟前" end
    return string.format("%.1f 小时前", m / 60)
end

local function Stars(n)       -- 一到三星：金色实心 + 灰色补位；零星 = 你标了"不要"
    n = math.max(0, math.min(3, n or 1))
    return "|cffffd700" .. string.rep("★", n) .. "|r|cff444444" .. string.rep("★", 3 - n) .. "|r"
end
-- 人工标注：你说"要"的一律三星（并且当作已验证，可以进自动买入），你说"不要"的一律零星。
-- 每标一次记一条校正记录（当时模型给了几星、理由是什么），电脑端用 python3 -m quant marks 汇总，看模型错在哪。
-- 两个独立的指标：星级 = 这件东西好不好（有没有人要）；差价 = 目标卖价是现价的几倍（标得有多便宜）。
-- 买不买由两者一起定：
--   三星 + 已验证 + 差价够       -> 买
--   三星但差价低                 -> 犹豫（列出来，不自动买）
--   二星但差价特别高             -> 已验证的买；没验证的"值得看"
--   同款抬轿子（别人都挂得贵）   -> 在同款印证那一步已经加了一星并算作已验证，所以二星会走到上面"买"的那一档
local GAP_OK, GAP_BIG = 2.5, 3.0      -- 三星的起买线；二星的起买线（本钱高了，从 4 倍降到 3 倍）
local function Gap(op)
    if (op.max_unit_price or 0) <= 0 then return 0 end
    return (op.target_unit_price or 0) / op.max_unit_price
end
local function Verdict(op)
    -- 囤够了：同一件货手里加挂着的已经有 2 件，而它最近一天卖出不到 2 件——再便宜也先不买，免得自己成了最大的卖家却没人接。
    -- （你亲手点「要」的那一下照买；控价的货有自己的件数上限，不走这条）
    local T = ForeverQuantTrade
    if T and T.Overstocked and not op.ctlBuy and op.marked ~= "no" and T.Overstocked(op.name) then return "full" end
    -- 你标过「要」：意思是"这个差价倍数我愿意买"。以后差价不低于当时那个倍数才自动买；星级不因此改变。
    if op.marked == "want" and Gap(op) >= (op.wantGap or 0) * 0.97 then return "buy" end
    if op.marked == "no" or op.peer == "flat" then return "skip" end
    -- 蓝色武器的超低价单：另有两把以上同款作参照、明显是标错的，直接算「买」（「自动买入」开着才会真去买）；
    -- 只有它一把或只有一把可比时，参照价靠不住，只提醒
    -- 不在蓝装上压大本钱：单把超过上限的、或者买了以后蓝武占用的本钱超过总上限的，也只提醒
    if op.strategy == "BLUE" and op.ctlBuy then
        local T = ForeverQuantTrade
        local c = T and T.Control(op.name)
        if not c or (op.max_unit_price or 0) > c.bid then return "look" end
        local listed, held = T.ControlState(op.name)
        return (#listed + held < c.maxUnits) and "buy" or "look"
    end
    if op.strategy == "BLUE" then
        local P = ForeverQuantPool
        local price = op.max_unit_price or 0
        if op.blueAuto and P and price <= P.BLUE_ONE and P.BlueHeld() + price <= P.BLUE_ALL then return "buy" end
        return "look"
    end
    if op.strategy ~= "GEAR" then return "skip" end
    local stars, gap = op.stars or 1, Gap(op)
    if stars >= 3 then
        if gap < GAP_OK then return "hesitate" end
        return op.verified and "buy" or "look"
    end
    if stars == 2 and gap >= GAP_BIG then return op.verified and "buy" or "look" end
    return "skip"
end
ForeverQuantVerdict = Verdict       -- 给测试用
local VERDICT_TEXT = { full = "|cffaaaaaa囤够了|r", buy = "|cff40ff40买|r", hesitate = "|cffffd040犹豫|r", look = "|cff55ccff值得看|r", skip = "|cff808080-|r" }

local function MarkKey(op) return op.item_id .. ":" .. (op.suffix_id or 0) end
-- 标注存的是：「要」连同当时的差价倍数 { want = true, gap = 3.2 }；「不要」是 "no"。老版本存的 "want" 没有倍数，当作 0（任何差价都要）。
local function MarkOf(m)
    if type(m) == "table" then return "want", m.gap or 0 end
    if m == "want" then return "want", 0 end
    return m, nil
end
local function ApplyMarks(list)
    if not ForeverQuantDB or not list then return list end
    local marks = ForeverQuantDB.marks or {}
    local keep, drop = {}, {}
    ForeverQuantDB.known = ForeverQuantDB.known or {}
    for _, op in ipairs(list) do
        if op.name and (op.target_unit_price or 0) > 0 then
            local k = op.item_id .. ":" .. op.name
            local old = ForeverQuantDB.known[k]
            local st = op.model_stars or op.stars or 1
            ForeverQuantDB.known[k] = { target = op.target_unit_price, buy = op.max_unit_price, suffix = op.suffix_id or 0, stars = st,
                best = math.max(st, old and (old.best or old.stars) or 0),               -- 历史上到过的最高星级：决定进不进高概率池
                verified = (op.model_verified or op.verified or (old and old.verified)) and true or false,
                ilvl = (op.ikey and op.ikey.itemLevel) or (old and old.ilvl), id = op.item_id, name = op.name, t = time() }
        end
        if op.model_stars == nil then op.model_stars, op.model_verified = op.stars or 1, op.verified end
        local m, wantGap = MarkOf(marks[MarkKey(op)])
        op.wantGap = wantGap
        if m == "want" then op.stars, op.verified, op.marked = op.model_stars, op.model_verified, "want"      -- 星级照模型的，不改
        elseif m == "no" then op.stars, op.verified, op.marked = 0, false, "no"
        else op.stars, op.verified, op.marked = op.model_stars, op.model_verified, nil end
        if m == "no" then drop[#drop + 1] = op else keep[#keep + 1] = op end
    end
    for i = 1, #keep do list[i] = keep[i] end              -- "不要"的沉到最后，顺序其余不变
    for i = 1, #drop do list[#keep + i] = drop[i] end
    return list
end
local function SetMark(op, want)
    ForeverQuantDB.marks = ForeverQuantDB.marks or {}
    ForeverQuantDB.corrections = ForeverQuantDB.corrections or {}
    local k = MarkKey(op)
    local old = MarkOf(ForeverQuantDB.marks[k])
    local kind = want and "want" or "no"
    local new = nil
    if old ~= kind then                                    -- 再点一次同一个 = 取消标注
        new = want and { want = true, gap = math.floor(Gap(op) * 10) / 10, t = time() } or "no"
    end
    ForeverQuantDB.marks[k] = new
    local clean = function(t) return (string.gsub(tostring(t or ""), "|", "/")) end
    table.insert(ForeverQuantDB.corrections, table.concat({ "#MARK", time(), (new == nil and "clear") or kind, op.item_id, op.suffix_id or 0,
        clean(op.name), op.model_stars or op.stars or 1, op.model_verified and 1 or 0, op.max_unit_price or 0,
        op.target_unit_price or 0, clean(op.reason) }, "|"))
end

local function ItemInfo(id) return ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(id) end
local function BagCount(id) return ((C_Item and C_Item.GetItemCount) or GetItemCount)(id) or 0 end
-- 自动分解的状态和入口在文件后面定义，这里先声明，前面的界面代码才引用得到
local auto, StartAutoDE, StopAutoDE
local function ItemLink(id) local _, link = ItemInfo(id) return link end

-- 监控项：按当前价格重算分解期望、利润和结论（和 Python 里的算法一致）
local function Recalc(w)
    local ev, best = 0, 0
    for _, y in ipairs(w.yields) do
        local v = y.chance * y.qty * math.floor(math.floor(y.price * 0.97) * (1 - AH_CUT))
        ev = ev + v
        if y.id == w.main_id then w.main_price = y.price end
    end
    w.ev = math.floor(ev)
    w.profit_min, w.profit_wall = w.ev - w.min_price, w.ev - w.wall_price
    w.max_buy = math.floor(w.ev / (1 + (w.min_roi or 0.15)))      -- 买入价超过这个数，利润率就不够了
    if (w.main_spd or 0) < 50 then w.verdict = "停"
    elseif w.profit_min > 0 and w.min_price > 0 and w.profit_min / w.min_price >= (w.min_roi or 0.15) then w.verdict = "可以做"
    elseif w.profit_min > 0 then w.verdict = "利润太薄"
    else w.verdict = "停" end
end
for _, w in ipairs(watches) do Recalc(w) end
local VERDICT_COLOR = { ["可以做"] = "|cff40ff40", ["利润太薄"] = "|cffffd040", ["停"] = "|cffff4040" }

-- 选一个商人：优先玩家当前所在地图的，其次列表里第一个；r.pick 是玩家点"导航"轮换到的那个
local function BestVendor(r)
    local vs = r.vendors
    if not vs or #vs == 0 then return nil end
    if r.pick and vs[r.pick] then return vs[r.pick], r.pick end
    local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    for i, v in ipairs(vs) do
        if v.map ~= 0 and v.map == here then return v, i end
    end
    return vs[1], 1
end

-- 在地图上给商人打导航点，并把世界地图翻到那里（装了 OpenMap 就用它的无缝地图）
local function Navigate(r)
    local vs = r.vendors
    if not vs or #vs == 0 then return end
    local _, cur = BestVendor(r)
    if r.navigated then r.pick = cur % #vs + 1 end      -- 再点一次：换下一个商人
    r.navigated = true
    local v = BestVendor(r)
    local x, y = v.x / 100, v.y / 100
    local where = string.format("%s %.0f,%.0f %s", v.zone, v.x, v.y, v.name)
    if v.map == 0 then
        print("|cff55ccffFQ|r 这张地图没有对应的地图编号，没法自动导航：" .. where)
        return
    end
    local pinned = false
    if C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates
        and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(v.map)) then
        pinned = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(v.map, x, y))
        if pinned and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    if TomTom and TomTom.AddWaypoint then
        pcall(TomTom.AddWaypoint, TomTom, v.map, x, y, { title = v.name .. "（" .. r.name .. "）", from = "ForeverQuant" })
    end
    pcall(function()
        if not WorldMapFrame:IsShown() then ToggleWorldMap() end
        WorldMapFrame:SetMapID(v.map)
        if OpenMapAPI and OpenMapAPI.WorldFromMap and OpenMapAPI.ShowWorld then
            local u, w = OpenMapAPI.WorldFromMap(v.map, x, y)
            if u then OpenMapAPI.ShowWorld(u, w) end
        end
    end)
    print(string.format("|cff55ccffFQ|r %s：%s%s%s", r.name, where, pinned and "（已设导航点）" or "（没能设导航点，请按坐标找）",
        #vs > 1 and string.format("。共 %d 处有卖，再点一次「导航」换下一处。", #vs) or ""))
end

-- 每个页签：列定义 {标题, x, 宽, 取值函数}
local fishRows = {}        -- 钓鱼页的行，内容在后面的 BuildFishRows 里填
local bizRows = {}         -- 经营总览页的行
local ledgerRows = {}      -- 账本页的行，内容在后面的 BuildLedgerRows 里填
local todRows = (ForeverQuantRecommendations and ForeverQuantRecommendations.tod and ForeverQuantRecommendations.tod.items) or {}
local function Dur(sec)    -- 时长：分钟 / 小时 / 天
    if not sec then return "-" end
    if sec < 3600 then return string.format("%d 分钟", math.max(1, math.floor(sec / 60))) end
    if sec < 86400 then return string.format("%.1f 小时", sec / 3600) end
    return string.format("%.1f 天", sec / 86400)
end
local VIEWS = {
    gear = {
        list = function() return gear end,
        cols = {
            { "物品", 58, 200, function(op)
                local suffixed = (op.suffix_id or 0) ~= 0 and op.name ~= ""
                local tag = (op.isNew and "|cff40ff40新|r " or "") .. (op.strategy == "EFFECT" and "|cffff8000[特效]|r " or "")
                return tag .. ((suffixed and ("|cff1eff00[" .. op.name .. "]|r")) or ItemLink(op.item_id)
                    or (op.name ~= "" and op.name) or ("item:" .. op.item_id)) end },
            { "买价", 262, 64, function(op) return Silver(op.max_unit_price) end },
            { "目标卖价", 330, 70, function(op) return Silver(op.target_unit_price) end },
            { "净赚(估)", 404, 64, function(op) return Silver(op.expected_profit) end },
            { "差价", 472, 50, function(op)
                local g = Gap(op)
                -- 用装备品质的配色：灰 < 1.5 倍，白 < 2.5，绿 < 3，蓝 < 6，紫 < 10，橙 10 倍以上
                local c = (g >= 10 and "ff8000") or (g >= 6 and "a335ee") or (g >= GAP_BIG and "0070dd") or (g >= GAP_OK and "1eff00")
                    or (g >= 1.5 and "ffffff") or "9d9d9d"
                return "|cff" .. c .. string.format("%.1f倍|r", g) end },
            { "星级", 526, 50, function(op) return Stars(op.stars) end },
            { "建议", 580, 50, function(op)                 -- 这条挂单已经动过手的，写结果；否则写建议
                local T = ForeverQuantTrade
                if T and T.cur == op then return "|cffffd040买入中|r" end
                local o = T and T.outcome and op.key and T.outcome[op.key]
                if o == "yes" then return "|cff40ff40买到了|r" elseif o == "no" then return "|cffff6060没买到|r" end
                return VERDICT_TEXT[Verdict(op)] end },
            { "理由", 634, 230, function(op) return op.reason or "" end },
        },
    },
    watch = {
        list = function() return watches end,
        cols = {
            { "常分解的物品", 12, 190, function(w) return ItemLink(w.item_id) or w.name end },
            { "现在最低价", 206, 90, function(w) return Money(w.min_price) end },
            { "在售", 300, 50, function(w) return w.quantity end },
            { "分解期望到手", 354, 100, function(w) return Money(w.ev) end },
            { "按现价每件赚", 458, 100, function(w) return Money(w.profit_min) end },
            { "止买线", 562, 100, function(w) return Money(w.max_buy) end },
            { "结论", 666, 130, function(w) return (VERDICT_COLOR[w.verdict] or "") .. w.verdict .. "|r" end },
        },
    },
    de = {
        list = function() return deList end,
        cols = {
            { "物品（买最便宜的后缀即可）", 12, 220, function(o) return "|cff1eff00[" .. o.name .. "]|r" end },
            { "类型", 236, 40, function(o) return o.kind end },
            { "等级", 280, 36, function(o) return o.level end },
            { "现在最低价", 320, 84, function(o) return Silver(o.price) end },
            { "分解期望到手", 408, 96, function(o) return Silver(o.net) end },
            { "按现价每件赚", 508, 96, function(o) return Silver(o.profit) end },
            { "止买线", 608, 80, function(o) return Silver(math.floor(o.net / 1.15)) end },
            { "在售", 692, 40, function(o) return o.quantity end },
            { "能否分解", 736, 60, function(o) return o.verified and "|cff40ff40已实测|r" or "|cffffd040先试一件|r" end },
        },
    },
    ledger = {
        list = function() return ledgerRows end,
        cols = {
            { "物品", 12, 230, function(r) return r.name end },
            { "买入", 246, 70, function(r) return r.cost and Silver(r.cost) or "|cff808080?|r" end },
            { "卖出价", 320, 70, function(r) return r.price and Silver(r.price) or "-" end },
            { "净赚", 394, 80, function(r)
                if r.status ~= "sold" and r.status ~= "vendor" then return "-" end
                if not r.cost then return "|cff808080缺买入价|r" end
                return (r.net >= 0 and "|cff40ff40+|r" or "") .. Silver(r.net) end },
            { "多久卖掉", 478, 90, function(r) return r.status == "sold" and Dur(r.took) or (r.status == "open" and ("已挂 " .. Dur(time() - r.posted)) or "-") end },
            { "卖出时间", 572, 110, function(r) return r.sold and date("%m-%d %H:%M", r.sold) or "-" end },
            { "状态", 686, 180, function(r)
                if r.status == "sold" then return "|cff40ff40已卖出|r" end
                if r.status == "open" then return "|cffffd040在售|r" end
                if r.status == "expired" then return "|cffff6060流拍|r" end
                if r.status == "unknown" then return "|cffffa040去向不明（等取信判明）|r" end
                if r.status == "cancelled" then return "|cffaaaaaa已撤单|r" end
                if r.status == "used" then return "|cffaaaaaa自用（不卖了）|r" end
                if r.status == "restocked" then return "|cffaaaaaa自用后又拿出来卖|r" end
                if r.status == "vendor" then return "|cffaaaaaa卖店|r" end
                for _, h in ipairs((ForeverQuantDB and ForeverQuantDB.holdings) or {}) do
                    if h.name == r.name then
                        if h.vendor then return "|cffff8040该卖店了（挂不动）|r" end
                        local re = (h.relist or 0) > 0 and string.format("，流拍 %d 次", h.relist) or ""
                        return string.format("|cffffd040待上架%s%s|r", h.post and (" " .. SilverText(h.post)) or "", re)
                    end
                end
                return "|cffaaaaaa只买未挂|r" end },
        },
    },
    -- 蓝色武器：一共就一百来把，一把一把看它自己的价格（进货线 / 平时最低 / 高位 / 走货速度），不看后缀
    blue = {
        list = function() return data.blueRows or {} end,       -- 表还在建，这里引用不到 VIEWS 自己，所以行存在 data 上
        cols = {
            { "蓝色武器", 12, 150, function(r) return ItemLink(r.item_id) or ("|cff0070dd[" .. r.name .. "]|r") end },
            { "类型", 166, 44, function(r) return r.kind end },
            { "等级", 214, 30, function(r) return r.req end },
            { "现价", 248, 78, function(r) return r.now > 0 and (Silver(r.now) .. ((r.nowQty or 0) > 0 and (" |cff808080×" .. r.nowQty .. "|r") or "")) or "|cff808080没货|r" end },
            { "平时最低", 330, 70, function(r) return Silver(r.typ) .. (r.recent < r.typ * 0.85 and " |cffff6060↓|r" or (r.recent > r.typ * 1.15 and " |cff40ff40↑|r" or "")) end },
            { "高位", 404, 60, function(r) return Silver(r.high) end },
            { "日销", 468, 32, function(r) return string.format("%.0f", r.spd) end },
            { "结论", 504, 74, function(r) return r.verdictText end },
            -- 需求指数：按职业的用法打的星（电脑端算的），后面是谁会用；完整的理由在鼠标提示里
            { "谁要（需求指数）", 582, 170, function(r)
                if not r.need then return "|cff808080还没有面板数据|r" end
                return Stars(r.need) .. " " .. (r.who or "") end },
            -- 手里有这把时，这一格改成显示"持几把·计划挂多少"；没有时显示现在进了能赚多少
            { "能赚/我持", 756, 46, function(r) return r.mineText or (r.net > 0 and Silver(r.net) or "-") end },
        },
    },
    biz = {
        list = function() return bizRows end,
        cols = {
            { "项目", 12, 250, function(r) return r.label end },
            { "今天", 270, 110, function(r) return r.a end },
            { "累计 / 现在", 386, 110, function(r) return r.b end },
            { "说明", 502, 360, function(r) return r.note end },
        },
    },
    tod = {
        list = function() return todRows end,
        cols = {
            { "大宗货", 12, 230, function(r) return ItemLink(r.item_id) or r.name end },
            { "最便宜的时段", 246, 120, function(r) return string.format("%02d 点前后", r.low_hour) end },
            { "最贵的时段", 370, 120, function(r) return string.format("%02d 点前后", r.high_hour) end },
            { "高低相差", 494, 80, function(r) return string.format("%.0f%%", r.spread * 100) end },
            { "典型最低价", 578, 90, function(r) return Money(r.typical) end },
            { "日销", 672, 60, function(r) return string.format("%.0f", r.sold_per_day) end },
            { "样本", 736, 120, function(r) return r.points .. " 个小时点" end },
        },
    },
    fish = {
        list = function() return fishRows end,
        cols = {
            { "这片水域钓到的 / 地点", 12, 300, function(r)
                if r.kind == "fish" then return ItemLink(r.item_id) or ("物品 " .. r.item_id) end
                if r.kind == "spot" then return (r.here and "|cff40ff40▶ |r" or "   ") .. r.key end
                return "|cffaaaaaa" .. r.text .. "|r" end },
            { "条数", 316, 60, function(r) return r.kind == "fish" and r.n or (r.kind == "spot" and r.sp.total or "") end },
            { "占比 / 每小时", 380, 100, function(r)
                if r.kind == "fish" then return string.format("%.0f%%", r.share * 100) end
                if r.kind == "spot" then return r.perHour and string.format("%.0f 条/时", r.perHour) or "时间太短" end
                return "" end },
            { "单价(到手)", 484, 100, function(r)
                if r.kind == "fish" then return Money(r.unit) .. (r.src ~= "拍卖行" and (" |cff808080" .. r.src .. "|r") or "") end
                if r.kind == "spot" then return Money(r.sp.total > 0 and r.value / r.sp.total or 0) .. " |cff808080/条|r" end
                return "" end },
            { "每竿贡献 / 每小时收益", 600, 180, function(r)
                if r.kind == "fish" then return Money(r.each) end
                if r.kind == "spot" then return r.valuePerHour and (Silver(r.valuePerHour) .. " |cff808080/小时|r") or "-" end
                return "" end },
        },
    },
    recipe = {
        list = function() return recipes end,
        cols = {
            { "配方", 12, 210, function(r) return ItemLink(r.item_id) or r.name end },
            { "专业", 226, 40, function(r) return r.profession end },
            { "估算进价", 270, 84, function(r) return Money(r.cost) end },
            { "拍卖最低", 358, 84, function(r) return r.min_price > 0 and Money(r.min_price) or "|cff808080无货|r" end },
            { "每张净赚", 446, 84, function(r) return r.min_price > 0 and Money(r.net) or "-" end },
            { "在售", 534, 40, function(r) return r.quantity end },
            { "日销", 578, 50, function(r) return r.sold_per_day >= 0 and string.format("%.1f", r.sold_per_day) or "?" end },
            { "去哪买", 632, 170, function(r)
                local v = BestVendor(r)
                if not v then return "|cff808080?|r" end
                local more = #r.vendors > 1 and string.format(" |cff808080(共%d处)|r", #r.vendors) or ""
                return string.format("%s %.0f,%.0f%s", v.zone, v.x, v.y, more) end },
        },
    },
}

--------------------------------------------------------------------------------
-- 钓鱼记录：边钓边记"在哪片水域钓到了什么"，配上拍卖行价格估收益。
-- 游戏里查不到某片水域的掉落表，所以用实际钓到的来统计；钓过的地方越多，对比越有意义。
--------------------------------------------------------------------------------
local livePrices = {}            -- 最近一次全量扫描读到的最低价：物品ID -> 铜

local function SpotHere()
    local zone, sub = GetRealZoneText() or "?", GetSubZoneText() or ""
    return zone .. (sub ~= "" and (" · " .. sub) or ""), zone, sub
end

local function PlayerXY()
    local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local pos = m and C_Map.GetPlayerMapPosition(m, "player")
    if pos then local x, y = pos:GetXY(); return x * 100, y * 100 end
end

-- 一件东西卖掉能到手多少：拍卖行按最低价再让 3%、扣抽成；和卖店价取高的。返回 (铜, 来源)
local function NetValue(id)
    local ah = livePrices[id] or (data.prices and data.prices[id])
    local _, _, _, _, _, _, _, _, _, _, vendor = ItemInfo(id)
    local net = ah and math.floor(math.floor(ah * 0.97) * (1 - AH_CUT)) or 0
    if (vendor or 0) > net then return vendor, "卖店" end
    return net, ah and "拍卖行" or "无价格"
end

local function SpotStats(sp)
    local value = 0
    for id, n in pairs(sp.catches) do value = value + n * NetValue(id) end
    local hours = (sp.seconds or 0) / 3600
    return value, hours > 0.02 and sp.total / hours or nil, hours > 0.02 and value / hours or nil
end

local function BuildFishRows()
    local db = ForeverQuantDB and ForeverQuantDB.fish
    local out = {}
    local key = SpotHere()
    local here = db and db.spots[key]
    if here and here.total > 0 then
        local items = {}
        for id, n in pairs(here.catches) do
            local v, src = NetValue(id)
            items[#items + 1] = { kind = "fish", item_id = id, n = n, share = n / here.total, unit = v, src = src, contrib = n * v }
        end
        table.sort(items, function(a, b) return a.contrib > b.contrib end)
        local value = SpotStats(here)
        for _, it in ipairs(items) do
            it.each = value > 0 and it.contrib / here.total or 0        -- 平均到每一竿上，这种东西贡献多少
            out[#out + 1] = it
        end
    else
        out[#out + 1] = { kind = "note", text = "还没在这里钓过，钓了就有记录" }
    end
    if db then
        local spots = {}
        for k, sp in pairs(db.spots) do
            if sp.total >= 5 then
                local value, perHour, valuePerHour = SpotStats(sp)
                spots[#spots + 1] = { kind = "spot", key = k, sp = sp, value = value, perHour = perHour, valuePerHour = valuePerHour, here = (k == key) }
            end
        end
        if #spots > 0 then
            table.sort(spots, function(a, b) return (a.valuePerHour or 0) > (b.valuePerHour or 0) end)
            out[#out + 1] = { kind = "note", text = "—— 钓过的地点对比（至少 5 条才列出；按每小时收益排序）——" }
            for _, r in ipairs(spots) do out[#out + 1] = r end
        end
    end
    fishRows = out
    return out
end

local frame = CreateFrame("Frame", "ForeverQuantFrame", UIParent, "BackdropTemplate")
frame:SetSize(WIDTH, 168 + ROWS * ROW_H)
frame:SetPoint("CENTER")
frame:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
frame:SetBackdropColor(0, 0, 0, 0.9)
frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetFrameStrata("HIGH")
frame:Hide()
tinsert(UISpecialFrames, "ForeverQuantFrame")   -- Esc 关闭

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 12, -12)
local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
sub:SetPoint("TOPLEFT", 12, -100)
local foot = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
foot:SetPoint("BOTTOMLEFT", 12, 10)
foot:SetWidth(WIDTH - 420); foot:SetJustifyH("LEFT"); foot:SetWordWrap(false)
local credit = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")      -- 行情源要求的署名，留在左下角
credit:SetPoint("BOTTOMLEFT", 12, 12)
-- 只在确实用了 AHledger 数据的页上署名，并写明用的是哪一部分；绿装和买卖记录的数字全是游戏里自己扫的、自己记的，不署
local CREDIT = {
    tod = "这一页的数据全部来自 AHledger（ahledger.com）",
    recipe = "日销量来自 AHledger；价格是游戏内扫描的",
    watch = "材料日销量来自 AHledger；价格是游戏内扫描的（没扫过时用 AHledger 的）",
    de = "没做过游戏内全量扫描时，材料价格来自 AHledger",
    fish = "游戏内没扫到价格的物品，用 AHledger 的最低价",
}
local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 0, 0)

local Refresh
local ROW1, ROW2 = -38, -68      -- 第一行：做哪件事（场景）；第二行：这件事里看哪张表 + 这张表自己的操作
-- 界面上三种东西，样子和位置各不相同：
--   页签（去哪看）：左上两行，只有文字，选中的发亮带下划线       -> MakeTab
--   操作（做一次）：右上，红色按钮                               -> MakeButton
--   开关（一直开着/关着）：右下，一个小方框打勾                  -> StyleToggle
local function MakeTab(text, x, w, onClick, y, big)
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(w, 22); b:SetPoint("TOPLEFT", x, y or ROW2)
    b:SetNormalFontObject(big and "GameFontNormalLarge" or "GameFontNormal")            -- 没选中：金色
    b:SetHighlightFontObject(big and "GameFontHighlightLarge" or "GameFontHighlight")   -- 鼠标移上去：白色
    b:SetDisabledFontObject(big and "GameFontHighlightLarge" or "GameFontHighlight")    -- 选中（当前页，不能再点）：白色 + 下划线
    b:SetText(text)
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetColorTexture(1, 0.82, 0, 0.9)
    b.line:SetPoint("BOTTOMLEFT", 6, 0); b.line:SetPoint("BOTTOMRIGHT", -6, 0); b.line:SetHeight(big and 2 or 1)
    b.line:Hide()
    local setEnabled = b.SetEnabled
    b.SetEnabled = function(self, on)
        setEnabled(self, on)
        if on then self.line:Hide() else self.line:Show() end
    end
    b:SetScript("OnClick", onClick)
    return b
end
local function StyleToggle(b)       -- 把一个按钮做成"方框 + 文字"的开关；用 b:Set(开没开, 文字) 更新
    b.box = b:CreateTexture(nil, "ARTWORK")
    b.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    b.box:SetSize(20, 20); b.box:SetPoint("LEFT", 0, 0)
    b.check = b:CreateTexture(nil, "OVERLAY")
    b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    b.check:SetSize(20, 20); b.check:SetPoint("LEFT", 0, 0)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 22, 0); b.label:SetPoint("RIGHT", 0, 0); b.label:SetJustifyH("LEFT"); b.label:SetWordWrap(false)
    b.Set = function(self, on, text)
        if on then self.check:Show() else self.check:Hide() end
        self.label:SetText((on and "|cff40ff40" or "|cffaaaaaa") .. text .. "|r")
    end
    return b
end
local function MakeButton(text, x, w, onClick, y)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetPoint("TOPLEFT", x, y or ROW2); b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end
-- 三个场景：钓鱼 / 分解（套利名单 + 监控）/ 交易（绿装 + 配方）。场景里再分小页签。
-- 蓝色武器页：一键把所有蓝色武器现在的最低价拉回来（一次浏览查询，一两秒）
VIEWS.blue.btn = MakeButton("刷新现价", 720, 100, function()
    local P = ForeverQuantPool
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then print("|cff55ccffFQ|r 刷新现价要先打开拍卖行。") return end
    if not P or P.bq then return end
    P.pull = true
    if P.Busy() then
        P.wantBlue = true                                  -- 正在快扫：排在这一轮后面
        print("|cff55ccffFQ|r 正在扫货，这一轮完了就刷新蓝武现价。")
    elseif not P.StartBlue(true) then
        P.pull = nil
        print("|cff55ccffFQ|r 没有蓝色武器的数据，刷新不了。")
    end
    Refresh()
end, ROW2)
VIEWS.blue.btn:Hide()
local SCENE = { fish = "fish", de = "de", watch = "de", gear = "trade", recipe = "trade", ledger = "trade", tod = "trade", biz = "trade", blue = "trade" }
local lastMode = { fish = "fish", de = "de", trade = "gear" }
local function Go(m) mode, offset = m, 0; lastMode[SCENE[m]] = m; Refresh() end
ForeverQuantDebugGo = Go          -- 给测试用：逐个页签刷一遍，确认打开不报错
ForeverQuantDebugCols = function(view) return VIEWS[view] and VIEWS[view].cols end
local sceneFish = MakeTab("蹲点钓鱼", 10, 110, function() Go(lastMode.fish) end, ROW1, true)
local sceneDe = MakeTab("分解套利", 124, 110, function() Go(lastMode.de) end, ROW1, true)
local sceneTrade = MakeTab("倒卖套利", 238, 110, function() Go(lastMode.trade) end, ROW1, true)
local tabGear = MakeTab("", 10, 110, function() Go("gear") end)
VIEWS.blue.tab = MakeTab("蓝色武器", 122, 84, function() Go("blue") end)
local tabRecipe = MakeTab("", 208, 110, function() Go("recipe") end)
local tabLedger = MakeTab("买卖记录", 320, 80, function() Go("ledger") end)
local tabTod = MakeTab("各时段价格", 402, 92, function() Go("tod") end)
local tabBiz = MakeTab("经营总览", 496, 80, function() Go("biz") end)
local btnAll = StyleToggle(CreateFrame("Button", nil, frame))
btnAll:SetSize(140, 20); btnAll:SetPoint("BOTTOMRIGHT", -400, 8)
btnAll:SetScript("OnClick", function()
    showAll = not showAll
    gear = showAll and gearAll or gearBudget
    offset = 0
    Refresh()
end)
-- 卖货按钮：点一下 = 认领背包里名单上的货并挂出一件（点击本身就是游戏要求的"亲手操作"，不需要另按键）
local btnSell = MakeButton("上架背包里的货", 530, 180, function() ForeverQuantModes.Sell() end, ROW1)
btnSell:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("上架背包里的货", 0.33, 0.8, 1)
    GameTooltip:AddLine("找出背包里和「绿装捡漏」名单对得上的装备，按名单上的目标卖价挂出去。需要先打开拍卖行。", 1, 1, 1, true)
    GameTooltip:AddLine("点一次就把背包里所有待上架的集中挂完：先认出拍卖行退回来的流拍货，逐件查同款价，再由电脑端一件件挂出去，挂完自己停。中途再点一次可以停下。", 1, 1, 1, true)
    GameTooltip:AddLine("电脑端程序没连上时，点一下挂一件。右下角「自动上架」开着的话不用点，有货就会自己挂。", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end)
btnSell:SetScript("OnLeave", function() GameTooltip:Hide() end)
-- 待上架里有些货其实不卖了（自己穿、送人、分解……）：一键清掉，不再等它们上架；账上记成"自用"，不再算压货
local btnClear = MakeButton("清空待上架", 404, 120, function() ForeverQuantModes.ClearPending() end, ROW1)
btnClear:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("清空待上架", 0.33, 0.8, 1)
    GameTooltip:AddLine("把等着上架的货全部从名单里拿掉：不再自动上架它们，买卖记录里记成「自用」，经营总览不再把它们算作压着的货。", 1, 1, 1, true)
    GameTooltip:AddLine("只是清名单，不会动背包里的东西。以后想卖其中某件，点「上架背包里的货」会重新认出来。", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end)
btnClear:SetScript("OnLeave", function() GameTooltip:Hide() end)
local tabDe = MakeTab("", 10, 150, function() Go("de") end)
local tabWatch = MakeTab("", 164, 150, function() Go("watch") end)
-- 把一批新价格（{物品ID = {price, qty}}）套到监控项上并重算结论
local function ApplyWatchPrices(found, quiet)
    for _, w in ipairs(watches) do
        local p = found[w.item_id]
        if p then
            -- 主流挂价没法实时读，保持不变；但不会低于新的最低价
            w.min_price, w.quantity = p.price, p.qty
            w.wall_price = math.max(w.wall_price, p.price)
        end
        for _, y in ipairs(w.yields) do
            if found[y.id] then y.price = found[y.id].price end
        end
        Recalc(w)
        if not quiet then
            print(string.format("|cff55ccffFQ|r 常分解的 %s：最低 %s，在售 %d，分解期望 %s，按现价每件赚 %s —— %s%s|r",
                w.name, Money(w.min_price), w.quantity, Money(w.ev), Money(w.profit_min),
                VERDICT_COLOR[w.verdict] or "", w.verdict))
        end
    end
    watchLiveAt = time()
end

-- 把一批新价格套到配方列表上并重排
local function ApplyRecipePrices(prices)
    for _, r in ipairs(recipes) do
        local p = prices[r.item_id]
        r.min_price, r.quantity = p and p.price or 0, p and p.qty or 0
        r.net = math.floor(math.floor(r.min_price * 0.97) * (1 - AH_CUT)) - r.cost
    end
    -- 按"每张净赚 x 日销（封顶 20）"重排；几乎不走货的排后面，无货和亏本的沉底
    local function key(r)
        if r.min_price <= 0 or r.net <= 0 then return -1 end
        if r.sold_per_day >= 0.5 then return 1e9 + r.net * math.min(r.sold_per_day, 20) end
        return r.net
    end
    table.sort(recipes, function(a, b) return key(a) > key(b) end)
    liveAt = time()
end

local btnWatch = MakeButton("刷新这几件的价格", 720, 150, function()
    local items, missing = {}, 0
    local function add(id)
        local name = ItemInfo(id)
        if name then items[#items + 1] = { id = id, name = name } else missing = missing + 1 end
    end
    local seen = {}
    for _, w in ipairs(watches) do
        add(w.item_id)
        for _, y in ipairs(w.yields) do
            if not seen[y.id] then seen[y.id] = true; add(y.id) end
        end
    end
    if missing > 0 then
        print("|cff55ccffFQ|r 有 " .. missing .. " 件物品的名称还没从服务器取到，过两秒再点一次。")
        return
    end
    ForeverQuantScan.StartItems(items, function(found)
        ApplyWatchPrices(found)
        Refresh()
    end)
end)
local btnLive = MakeButton("刷新配方价格", 720, 150, function()
    ForeverQuantScan.StartRecipes(function(prices, count)
        ApplyRecipePrices(prices)
        offset = 0
        print(string.format("|cff55ccffFQ|r 配方价格已刷新：拍卖行在售配方 %d 种。", count))
        Refresh()
    end)
end)

-- 整个插件的扫描按钮：扫完之后所有页签都在游戏内直接重算，不需要重载界面。
-- （数据仍会写进存盘文件，下次下线或重载时落盘，电脑端到时再更新日销量、商人位置这类慢变的数据。）
local LiveAll       -- 在后面定义：拿一次完整扫描的结果更新所有页签
local btnScan = MakeButton("扫描整个拍卖行", 720, 150, function()
    if ForeverQuantScan.running then
        if ForeverQuantScan.mode == "full" then ForeverQuantScan.Stop() end
    else
        ForeverQuantScan.onFullDone = function(status)
            if status == "complete" and LiveAll then LiveAll() end
            if frame:IsShown() then Refresh() end
        end
        ForeverQuantScan.Start()
    end
    Refresh()
end, ROW1)
btnScan:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("扫描整个拍卖行", 0.33, 0.8, 1)
    GameTooltip:AddLine("读取全部绿装、配方和全品类最低价，约半分钟。需要先打开拍卖行。", 1, 1, 1, true)
    GameTooltip:AddLine("扫完后「分解套利」和「倒卖套利」两个场景里的所有表都当场更新，不用重载界面。", 1, 1, 1, true)
    GameTooltip:Show()
end)
btnScan:SetScript("OnLeave", function() GameTooltip:Hide() end)
local scanTick = 0
frame:HookScript("OnUpdate", function(_, elapsed)       -- 扫描中每半秒更新一次按钮上的进度
    scanTick = scanTick + elapsed
    if scanTick < 0.5 then return end
    scanTick = 0
    if ForeverQuantScan.running and ForeverQuantScan.mode == "full" then
        btnScan:SetText(string.format("扫描中 %d…", #(ForeverQuantScan.list or {}) + #(ForeverQuantScan.all or {})))
    else
        btnScan:SetText("扫描整个拍卖行")
    end
end)

--------------------------------------------------------------------------------
-- 游戏内实时筛选：扫完绿装直接在这里按规则算，面板当场更新，不用重载也不用电脑端。
-- 规则（热门后缀表等）由电脑端分析时导出到 data.rule；算法和 Python 的 find_by_rule 一致。
--------------------------------------------------------------------------------
local RULE = data.rule
local liveGearAt, autoOn, autoNextAt, autoPausedSaid = nil, false, 0, false
local AUTO_INTERVAL = 5          -- 上一轮扫完之后隔多少秒再扫（秒）
local SWEEP_EVERY = 60           -- 全量绿装扫描隔多久做一次（秒）；中间都是高概率池快扫
local lastSweepAt = nil
local knownKeys = nil              -- 上一轮的候选，用来标"新"

local RuleKey
do
local WEAPON_KEY = { [15] = "weapon_dagger", [7] = "weapon_sword1h", [4] = "weapon_mace1h", [0] = "weapon_axe1h", [13] = "weapon_fist",
    [1] = "weapon_2h", [8] = "weapon_2h", [6] = "weapon_2h", [5] = "weapon_mace2h", [10] = "weapon_staff",
    [2] = "weapon_ranged", [3] = "weapon_ranged", [18] = "weapon_ranged", [16] = "weapon_ranged", [19] = "weapon_wand" }
local WEAPON_NAME = { weapon_dagger = "匕首", weapon_sword1h = "单手剑", weapon_mace1h = "单手锤", weapon_axe1h = "单手斧", weapon_fist = "拳套",
    weapon_2h = "双手剑/斧/长柄", weapon_mace2h = "双手锤", weapon_staff = "法杖", weapon_ranged = "弓/枪/弩", weapon_wand = "魔杖" }
function RuleKey(classID, subclassID, equipLoc)
    if equipLoc == "INVTYPE_CLOAK" or equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_NECK" then return "jewelry_cloak", "首饰/披风" end
    if classID == 2 then                                   -- 武器按类型分规则（和电脑端 gear.py 的 WEAPON_KEY 一致）
        local k = WEAPON_KEY[subclassID]
        if k and RULE and RULE.hot and RULE.hot[k] then return k, WEAPON_NAME[k] end
        return "weapon", "武器"
    end
    if classID == 4 then
        if subclassID == 1 then return "cloth", "布甲" end
        if subclassID == 2 then return "leather", "皮甲" end
        if subclassID == 3 then return "mail", "锁甲" end
    end
end
end

local function Median(sorted)
    local n = #sorted
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

local function LiveCompute(list)
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local groups, slots = {}, {}
    for _, e in ipairs(list) do
        if e.suffix ~= 0 and e.name then
            -- 后缀名：中文是"孤狼之歹徒短裤"取到第一个"之"，英文是 "... of the Wolf"
            local label = string.match(e.name, "^(.-之)") or string.match(e.name, "( of .+)$")
            if label then
                local gk = e.id .. ":" .. e.ilvl
                local g = groups[gk]
                if not g then
                    local _, _, _, equipLoc, _, classID, subclassID = instant(e.id)
                    local key, what = RuleKey(classID, subclassID, equipLoc)
                    local _, _, _, _, minLevel = ItemInfo(e.id)
                    g = { rows = {}, key = key, what = what, ilvl = e.ilvl, req = minLevel or 0,
                          slot = (classID or -1) .. ":" .. (subclassID or -1) .. ":" .. (equipLoc or "") }
                    groups[gk] = g
                    slots[g.slot] = slots[g.slot] or {}
                end
                local row = { e = e, label = label }
                g.rows[#g.rows + 1] = row
                table.insert(slots[g.slot], row)      -- 替代品索引：同类型、同部位的所有带后缀挂单
            end
        end
    end
    local out = {}
    for _, g in pairs(groups) do
        local hot = g.key and RULE.hot[g.key]
        local twink = g.req >= RULE.twink_min_req and g.req <= RULE.twink_max_req
        if hot and #g.rows >= 4 and (g.ilvl <= RULE.max_level or twink) and g.ilvl >= (RULE.min_level or 0) then
            local floor, hots = math.huge, {}
            for _, r in ipairs(g.rows) do
                if r.e.price < floor then floor = r.e.price end
                if hot[r.label] or (twink and RULE.twink_extra[r.label]) then hots[#hots + 1] = r end
            end
            if #hots >= 2 then
                for _, r in ipairs(hots) do
                    local price = r.e.price
                    if price <= RULE.max_price and price <= floor * RULE.floor_ratio then
                        -- 参照物只取"价值不比自己高出 1 分以上"的热门后缀，弱后缀不能拿强后缀的挂价当目标
                        local vmap = RULE.value and RULE.value[g.key]
                        local function val(label)
                            local v = vmap and vmap[label]
                            return (v and v > 0) and v or (RULE.hot_min_value or 0.5)
                        end
                        local own, others = val(r.label), {}
                        for _, h in ipairs(hots) do
                            if h ~= r and (not vmap or val(h.label) <= own + (RULE.comp_margin or 0.15) + 1e-9) then others[#others + 1] = h.e.price end
                        end
                        table.sort(others)
                        local kept = {}
                        if #others > 0 then
                            local med = Median(others)
                            for _, o in ipairs(others) do if o <= med * 10 then kept[#kept + 1] = o end end   -- 乱挂的天价不算
                        end
                        local ref = kept[1]
                        if ref and ref >= price * RULE.min_gap then
                            local target = math.floor(ref * 0.95)
                            -- 替代品：同类型、同部位、相近等级里，对同一个职业同样好或更好的其他装备
                            local roleKey = RULE.role_key and RULE.role_key[g.key] and RULE.role_key[g.key][r.label]
                            local rv = roleKey and RULE.role_value and RULE.role_value[roleKey]
                            local nAlt, cheapestAlt = 0, nil
                            local needMap = RULE.need and RULE.need[g.key]
                            local need = needMap and needMap[r.label]        -- 带特定需求属性的：替代品也得带同样的
                            if rv then
                                local ownValue = (vmap and vmap[r.label]) or 0
                                for _, a in ipairs(slots[g.slot]) do
                                    if a ~= r and math.abs(a.e.ilvl - g.ilvl) <= (RULE.alt_level_range or 3)
                                        and (not need or needMap[a.label] == need)
                                        and (rv[a.label] or 0) >= ownValue - 1e-9 then
                                        nAlt = nAlt + 1
                                        if not cheapestAlt or a.e.price < cheapestAlt then cheapestAlt = a.e.price end
                                    end
                                end
                                if cheapestAlt and math.floor(cheapestAlt * 0.95) < target then
                                    target = math.floor(cheapestAlt * 0.95)       -- 有同样好的更便宜的，卖不过它
                                end
                            end
                            local profit = math.floor(target * (1 - AH_CUT)) - price
                            if profit >= RULE.min_unit_profit then
                                local unsure = RULE.uncertain[r.label]
                                local ok
                                if RULE.ok then ok = RULE.ok[g.key] and RULE.ok[g.key][r.label] or false   -- 细到"类型+角色"的验证表
                                else ok = RULE.confirmed[g.key] and not unsure end
                                local parts = {}
                                for i = 1, math.min(#kept, 5) do parts[i] = SilverText(kept[i]) end
                                local note = string.format("%s %s，物品等级 %d%s；这件装备的地板价 %s\n同件装备其他热门后缀挂价：%s\n%s",
                                    g.what, r.label, g.ilvl, g.req > 0 and ("，需求等级 " .. g.req) or "", SilverText(floor), table.concat(parts, " / "),
                                    ok and "规则有成交验证" or "这类规则没有成交验证")
                                if unsure then note = note .. "\n注意：这个后缀加什么属性是推断的，买之前看一眼真实属性" end
                                local why = hot[r.label]
                                if why == "常识" and RULE.stats[r.label] then
                                    note = note .. "\n热门依据：常识（输出优先），这个后缀带 " .. RULE.stats[r.label]
                                elseif why == "数据" then
                                    note = note .. "\n热门依据：挂价数据里这个后缀明显偏贵"
                                end
                                if twink then note = note .. string.format("\n39 级战场小号档（需求等级 %d）", g.req) end
                                local value = RULE.value and RULE.value[g.key] and RULE.value[g.key][r.label]
                                local role = RULE.role and RULE.role[g.key] and RULE.role[g.key][r.label]
                                local star = RULE.star and RULE.star[g.key] and RULE.star[g.key][r.label]
                                if role then note = note .. string.format("\n属性有 %.0f%% 落在%s想要的属性上", (value or 0) * 100, role) end
                                local multi = RULE.multi and RULE.multi[g.key] and RULE.multi[g.key][r.label]
                                if multi then note = note .. "\n" .. RULE.multi_note[g.key][r.label] end
                                if need then
                                    note = note .. "\n特定需求：这类装备上带" .. need .. "是专门有人找的（比如圣骑兼职奶要智力撑蓝量）；替代品只算同样带它的"
                                end
                                local scarce = rv and nAlt == 0
                                if rv then
                                    if scarce then
                                        note = note .. string.format("\n稀缺：同部位、物品等级 ±%d 内，没有对%s同样好或更好的其他装备在售", RULE.alt_level_range or 3, role or "")
                                    else
                                        note = note .. string.format("\n替代品：同部位、物品等级 ±%d 内，对%s同样好或更好的还有 %d 件，最便宜 %s",
                                            RULE.alt_level_range or 3, role or "", nAlt, SilverText(cheapestAlt))
                                    end
                                end
                                local tier = RULE.tier and RULE.tier[g.key] and RULE.tier[g.key][r.label]     -- 需求强度：1 = 主属性级别
                                local tierBonus = 0
                                if tier then
                                    local share = ({ 1.0, 0.7, 0.55 })[(RULE.nstats and RULE.nstats[r.label]) or 1] or 0.5
                                    local lvl = math.max(0.3, math.min(1.0, g.ilvl / (RULE.premium_full_level or 34)))
                                    local mag = math.floor(lvl * share * 1000 + 0.5) / 1000
                                    tierBonus = math.floor((RULE.premium_bonus or 12) * tier * mag * 10 + 0.5) / 10
                                    note = string.format("好词缀（攻强/法伤/治疗）：%s，数值系数 %.2f（按物品等级和后缀属性个数估），加 %s 分\n",
                                        tier >= 1 and "主属性级别的需求" or "只是副属性级别的需求", mag, tostring(tierBonus)) .. note
                                end
                                if star then note = "★ 重点：好词缀叠加主属性\n" .. note end
                                local score
                                if role then
                                    score = (ok and 50 or 20) + math.min(profit, 10000) / 10000 * 40 + math.min(value or 0, 1) * 10
                                else
                                    score = (ok and 50 or 20) + math.min(profit, 10000) / 10000 * 50
                                end
                                score = math.floor((score + (scarce and (RULE.scarcity_bonus or 10) or 0)
                                    + tierBonus
                                    + (need and (RULE.need_bonus or 5) or 0)
                                    + (multi or 0)
                                    + (star and (RULE.highlight_bonus or 15) or 0)) * 10 + 0.5) / 10
                                -- 面板的列宽有限，理由写得紧凑；完整说明在鼠标提示里
                                local why = { unsure and "属性待确认" or (ok and "已验证" or "未验证") }
                                if role then
                                    local short = (RULE.role_short and RULE.role_short[g.key] and RULE.role_short[g.key][r.label]) or role
                                    why[#why + 1] = string.format("%s %s %.0f%%", short, (RULE.stats_cn and RULE.stats_cn[r.label]) or "", (value or 0) * 100)
                                elseif hot[r.label] == "数据" then
                                    why[#why + 1] = "挂价偏贵"
                                end
                                if star then why[#why + 1] = "好词缀+主属性" elseif tier then why[#why + 1] = (tier >= 1) and "好词缀" or "好词缀(副)" end
                                local nRoles = RULE.multi_n and RULE.multi_n[g.key] and RULE.multi_n[g.key][r.label]
                                if nRoles then why[#why + 1] = nRoles .. "职业都要" end
                                if need then why[#why + 1] = "圣骑要智力" end
                                if twink then why[#why + 1] = "39级档" end
                                if rv then why[#why + 1] = (nAlt == 0) and "无替代品" or ("替代" .. nAlt .. "件") end
                                local stars = (score >= (RULE.stars_3 or 85)) and 3 or ((score >= (RULE.stars_2 or 55)) and 2 or 1)
                                out[#out + 1] = { item_id = r.e.id, suffix_id = r.e.suffix, name = r.e.name, strategy = "GEAR",
                                    stars = stars, reason = table.concat(why, " · "), ikey = r.e.key, verified = ok and true or false,
                                    max_unit_price = price, target_unit_price = target, max_quantity = 1, expected_profit = profit,
                                    score = score, highlight = star and true or false, premium = tier and true or false, note = note,
                                    key = r.e.id .. ":" .. r.e.suffix .. ":" .. price }
                            end
                        end
                    end
                end
            end
        end
    end
    -- 带特效的装备：和同类型、同部位、相近等级的其他绿装比，明显便宜的才报
    local effectOf = ForeverQuantScan.EffectText
    if effectOf and RULE.effect_max_ratio then
        local cheapest = {}
        for _, e in ipairs(list) do
            local k = e.id .. ":" .. e.ilvl
            if not cheapest[k] or e.price < cheapest[k].price then cheapest[k] = e end
        end
        local comps, meta = {}, {}
        for k, e in pairs(cheapest) do
            local _, _, _, equipLoc, _, classID, subclassID = instant(e.id)
            local gk = (classID or -1) .. ":" .. (subclassID or -1) .. ":" .. (equipLoc or "") .. ":" .. math.floor(e.ilvl / 5)
            comps[gk] = comps[gk] or {}
            table.insert(comps[gk], e.price)
            meta[k] = gk
        end
        for _, c in pairs(comps) do table.sort(c) end
        for k, e in pairs(cheapest) do
            local c = comps[meta[k]]
            if e.price <= RULE.max_price and #c >= 6 and e.ilvl >= (RULE.min_level or 0) then
                local med = Median(c)
                local fx = (e.price <= med * math.max(RULE.effect_max_ratio, RULE.effect_premium_ratio or 0)) and effectOf(e.id) or ""
                local good = false
                if fx ~= "" then
                    for _, kw in ipairs(RULE.effect_keywords or {}) do
                        if string.find(fx, kw, 1, true) then good = true break end
                    end
                end
                if fx ~= "" and e.price <= med * (good and (RULE.effect_premium_ratio or 0.7) or RULE.effect_max_ratio) then
                    do
                        local target = math.floor(med * 0.9)
                        local profit = math.floor(target * (1 - AH_CUT)) - e.price
                        if profit >= RULE.min_unit_profit then
                            local fxStrength, fxBonus = 0.6, 0
                            if good then
                                local last
                                for num in string.gmatch(fx, "%d+") do last = tonumber(num) end
                                if last and e.ilvl > 0 then
                                    local typical = e.ilvl * (string.find(fx, "攻击强度", 1, true) and 0.5 or 0.35)
                                    fxStrength = math.floor(math.max(0.3, math.min(1.2, last / typical)) * 1000 + 0.5) / 1000
                                end
                                fxBonus = math.floor((RULE.premium_bonus or 12) * fxStrength * 10 + 0.5) / 10
                            end
                            out[#out + 1] = { item_id = e.id, suffix_id = e.suffix, name = e.name or ItemInfo(e.id) or "", strategy = "EFFECT",
                                max_unit_price = e.price, target_unit_price = target, max_quantity = 1, expected_profit = profit,
                                score = math.floor((15 + math.min(profit, 10000) / 10000 * 30 + fxBonus) * 10 + 0.5) / 10,
                                premium = good,
                                reason = string.format("未验证 · %s · 同类中位价的 %.0f%%", good and "好特效" or "带特效", e.price / med * 100),
                                note = string.format("%s特效：%s\n物品等级 %d；同类 %d 件的最低价中位 %s\n依据：玩家经验（特效好卖）。目标价只是按同类中位价估的，没有成交验证",
                                    good and string.format("好特效（攻强/法伤/治疗/击中触发）：数值是同等级典型值的 %.0f%%，加 %s 分\n", fxStrength * 100, tostring(fxBonus)) or "",
                                    fx, e.ilvl, #c, SilverText(med)),
                                key = e.id .. ":" .. e.suffix .. ":" .. e.price }
                        end
                    end
                end
            end
        end
    end
    for _, op in ipairs(out) do
        if not op.stars then op.stars = (op.score >= (RULE.stars_3 or 85)) and 3 or ((op.score >= (RULE.stars_2 or 55)) and 2 or 1) end
    end
    table.sort(out, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.expected_profit > b.expected_profit end)
    -- 本金内：按分数从高到低买，花到手头金币的八成为止
    local budget, afford, fresh, seen = GetMoney() * 0.8, {}, 0, {}
    for _, op in ipairs(out) do
        if op.max_unit_price <= budget then
            budget = budget - op.max_unit_price
            op.affordable = true
            afford[#afford + 1] = op
        end
        seen[op.key] = true
        if knownKeys and not knownKeys[op.key] then op.isNew = true; fresh = fresh + 1 end
    end
    -- 把每条候选第一次出现时的建议价记进存盘（最多留 600 条），以后卖掉了能对上当时建议的买价和目标价
    ForeverQuantDB.liveLog = ForeverQuantDB.liveLog or {}
    ForeverQuantDB.liveSeen = ForeverQuantDB.liveSeen or {}
    local lg = ForeverQuantDB.liveLog
    for _, op in ipairs(out) do
        if not ForeverQuantDB.liveSeen[op.key] then
            ForeverQuantDB.liveSeen[op.key] = true
            lg[#lg + 1] = string.format("%d|%d|%d|%d|%d|%d|%s", time(), op.item_id, op.suffix_id or 0, op.max_unit_price,
                op.target_unit_price, op.stars or 1, op.name or "")
        end
    end
    if #lg > 600 then
        local trimmed = {}
        for i = #lg - 499, #lg do trimmed[#trimmed + 1] = lg[i] end
        ForeverQuantDB.liveLog = trimmed
        ForeverQuantDB.liveSeen = {}          -- 去重表跟着清掉，免得无限增长；最坏情况是同一条再记一次
    end
    local first = knownKeys == nil
    knownKeys = seen
    gearAll, gearBudget = ApplyMarks(out), ApplyMarks(afford)
    gear = showAll and gearAll or gearBudget
    liveGearAt, offset = time(), 0
    return #out, #afford, first and 0 or fresh
end

-- 分解套利：按分解表和当前材料价，找"买来分解再卖材料"划算的绿装。priceOf = {材料ID = 最低价}
local DE = data.de
local function LiveDE(list, priceOf)
    if not DE then return 0 end
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local cheapest = {}
    for _, e in ipairs(list) do
        if not DE.excluded[e.id] then
            local k = e.id .. ":" .. e.ilvl
            if not cheapest[k] or e.price < cheapest[k].price then cheapest[k] = e end
        end
    end
    local out = {}
    for _, e in pairs(cheapest) do
        local _, _, _, _, _, classID = instant(e.id)
        local b
        if classID == 2 or classID == 4 then
            for _, br in ipairs(DE.brackets) do
                if e.ilvl >= br.lo and e.ilvl <= br.hi then b = br break end
            end
        end
        if b then
            local p = classID == 2 and b.weapon or b.armor
            local ys = { { b.dust, p[1], b.dust_qty }, { b.ess, p[2], b.ess_qty } }
            if b.shard ~= 0 and p[3] > 0 then ys[3] = { b.shard, p[3], 1 } end
            local net, best, main = 0, 0, ""
            for _, y in ipairs(ys) do
                local m, price = DE.mats[y[1]], priceOf[y[1]]
                if m and price and price > 0 and m.spd >= 5 then      -- 卖不动的材料按 0 算
                    local v = y[2] * y[3] * math.floor(math.floor(price * 0.97) * (1 - AH_CUT))
                    net = net + v
                    if v > best then best, main = v, (ItemInfo(y[1]) or m.name) end
                end
            end
            net = math.floor(net)
            local profit = net - e.price
            if net > 0 and profit >= RULE.min_unit_profit and profit / e.price >= RULE.min_roi then
                out[#out + 1] = { item_id = e.id, suffix_id = e.suffix, name = e.name or ItemInfo(e.id) or "", kind = classID == 2 and "武器" or "护甲",
                    level = e.ilvl, price = e.price, net = net, profit = profit, quantity = e.qty, main = main, verified = DE.verified[e.id] or false }
            end
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    deList = out
    return #out
end

-- 一次完整扫描之后：所有页签都用这次的数据在游戏内重算
function LiveAll()
    local S = ForeverQuantScan
    local prices = {}                    -- 全品类：物品ID -> {最低价, 在售}
    for _, e in ipairs(S.all or {}) do
        local p = prices[e.id]
        if not p then prices[e.id] = { price = e.price, qty = e.qty }
        else p.price, p.qty = math.min(p.price, e.price), p.qty + e.qty end
    end
    for id, p in pairs(prices) do livePrices[id] = p.price end      -- 钓鱼页估收益用
    ForeverQuantDB.keyLvl = ForeverQuantDB.keyLvl or {}             -- 拍卖行认的物品等级：快扫查蓝色武器时拼物品键要用
    for _, e in ipairs(S.all or {}) do if e.suffix == 0 and (e.ilvl or 0) > 0 then ForeverQuantDB.keyLvl[e.id] = e.ilvl end end
    local msg = {}
    if RULE then
        local total, afford = LiveCompute(S.list or {})
        msg[#msg + 1] = string.format("绿装错标 %d 条（本金内 %d）", total, afford)
        local priceOf = {}
        for id, p in pairs(prices) do priceOf[id] = p.price end
        msg[#msg + 1] = string.format("分解 %d 件", LiveDE(S.list or {}, priceOf))
    end
    if #recipes > 0 then ApplyRecipePrices(prices); msg[#msg + 1] = "配方价格已更新" end
    if #watches > 0 then ApplyWatchPrices(prices, true); msg[#msg + 1] = "常分解的货已更新" end
    offset = 0
    print("|cff55ccffFQ|r 全部页签已用这次扫描更新：" .. table.concat(msg, "，") .. "。")
    if not RULE then print("|cff55ccffFQ|r 插件里还没有筛选规则，绿装和分解没法在游戏内算：在电脑上跑一次 python3 -m quant gear 后重载一次即可。") end
end

-- 给测试用的入口：让外部脚本能拿同一份数据调这些计算，和电脑端的结果对比
ForeverQuantLive = { Compute = LiveCompute, DE = LiveDE, Get = function() return gearAll, gearBudget, deList end }

local function LiveRefresh(quiet)
    if not RULE then
        print("|cff55ccffFQ|r 插件里还没有筛选规则：先在电脑上跑一次 python3 -m quant gear，再 /reload。")
        return false
    end
    return ForeverQuantScan.StartGear(function(list)
        local total, afford, fresh = LiveCompute(list)
        lastSweepAt = GetTime()
        if ForeverQuantPeer then ForeverQuantPeer.Check(gearAll) end
        if autoOn and ForeverQuantPool and ForeverQuantTrade and ForeverQuantTrade.blueOn then ForeverQuantPool.StartBlue(true) end      -- 全量扫完也单独扫一遍蓝武（蓝武开关开着才扫）
        local T = ForeverQuantTrade
        if T then                      -- 你标过「要」的，重扫后又出现新挂单：直接去买（同一条挂单只买一次）
            for _, op in ipairs(gearAll) do
                if op.marked == "want" and Verdict(op) == "buy" and op.ikey and not (op.key and T.done[op.key]) then T.BuyNow(op) end
            end
            T.wantAfterScan = nil
        end
        if ForeverQuantTrade and ForeverQuantTrade.on then
            local n = ForeverQuantTrade.Enqueue()
            if n > 0 then print(string.format("|cff55ccffFQ|r 自动买入：%d 条新的进了买入队列。", n)) end
        end
        if fresh > 0 then
            print(string.format("|cff55ccffFQ|r |cff40ff40发现 %d 条新的错标单|r（共 %d 条，本金内 %d 条）。", fresh, total, afford))
            if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
        elseif not quiet then
            print(string.format("|cff55ccffFQ|r 绿装错标已刷新：共 %d 条，本金内 %d 条。", total, afford))
        end
        if frame:IsShown() then Refresh() end
    end, quiet)
end

local btnAuto = StyleToggle(CreateFrame("Button", nil, frame))
btnAuto:SetSize(160, 20); btnAuto:SetPoint("BOTTOMRIGHT", -230, 8)      -- 和另外两个自动开关排在一起：扫货 → 买入 → 上架
btnAuto:SetScript("OnClick", function()
    autoOn = not autoOn
    if autoOn then
        autoPausedSaid = false
        if LiveRefresh(false) then autoNextAt = GetTime() + AUTO_INTERVAL else autoNextAt = GetTime() + 5 end
    end
    Refresh()
end)
btnAuto:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("自动扫货", 0.33, 0.8, 1)
    GameTooltip:AddLine(string.format("打开后，拍卖行开着时每一轮忙完 %d 秒后开始下一轮。大多数轮次是「快扫」：只查以前到过二星、三星的那几十件；每 1 分钟做一次全量。按钮上会写当前在做什么。", AUTO_INTERVAL), 1, 1, 1, true)
    GameTooltip:AddLine("出现新的错标单时会响一声并在聊天栏提示，新的那几条前面有「新」标记。", 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("只更新「绿装捡漏」这一张表。其他表用右上角的「扫描整个拍卖行」。", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end)
btnAuto:SetScript("OnLeave", function() GameTooltip:Hide() end)

local btnNow = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
btnNow:SetSize(84, 22); btnNow:SetPoint("TOPLEFT", 632, ROW2)
btnNow:SetText("现在重扫")
btnNow:SetScript("OnClick", function()
    if LiveRefresh(false) and autoOn then autoNextAt = GetTime() + AUTO_INTERVAL end
end)

local autoFrame = CreateFrame("Frame")      -- 面板关着也要计时，所以单独一个框架
local autoTick = 0
autoFrame:SetScript("OnUpdate", function(_, elapsed)
    autoTick = autoTick + elapsed
    if autoTick < 1 then return end
    autoTick = 0
    local ahOpen = AuctionHouseFrame and AuctionHouseFrame:IsShown()
    if ahOpen and ForeverQuantTrade and ForeverQuantTrade.ControlTick then ForeverQuantTrade.ControlTick(autoOn) end
    if autoOn then
        if not ahOpen then
            if not autoPausedSaid then
                autoPausedSaid = true
                print("|cff55ccffFQ|r 拍卖行关了，自动扫货先停着；重新打开拍卖行会继续。")
            end
        else
            autoPausedSaid = false
            local busy = ForeverQuantTrade and ForeverQuantTrade.state ~= "idle"                -- 正在买
                or (ForeverQuantPeer and ForeverQuantPeer.Busy())                               -- 正在查同款
                or (ForeverQuantTrade and #ForeverQuantTrade.queue > 0)                         -- 还有排队没买的
                or (ForeverQuantPool and ForeverQuantPool.Busy())                               -- 快扫还没查完
            if ForeverQuantScan.running or busy then
                autoNextAt = math.max(autoNextAt, GetTime() + AUTO_INTERVAL)                    -- 间隔从"忙完"算起，不抢买入和查价的时间
            elseif GetTime() >= autoNextAt then
                autoNextAt = GetTime() + AUTO_INTERVAL
                -- 该全量了（或者池子还是空的）就全量，否则只快扫高概率池
                if not lastSweepAt or GetTime() - lastSweepAt >= SWEEP_EVERY or not (ForeverQuantPool and ForeverQuantPool.Start()) then
                    LiveRefresh(true)
                end
            end
        end
    end
    if frame:IsShown() then
        local A = ForeverQuantAction
        local online = A and A.Online and A.Online()
        title:SetText(string.format("ForeverQuant  |cffaaaaaa%s|r   电脑端程序：%s", data.market or "",
            online and "|cff40ff40已连上|r" or (A and A.key and "|cffff6060没连上（自动功能都不会动）|r" or "|cffaaaaaa没有可用的按键|r")))
        if autoOn then
            local left = math.max(0, math.floor(autoNextAt - GetTime()))
            local P, T, txt = ForeverQuantPool, ForeverQuantTrade, nil
            if not ahOpen then txt = "未开拍卖行"
            elseif ForeverQuantScan.running then txt = "全量"
            elseif P and P.fav then txt = "快扫 批量"
            elseif P and P.Busy() then txt = string.format("快扫 细查剩%d", #P.queue)
            elseif ForeverQuantPeer and ForeverQuantPeer.Busy() then txt = "查同款"
            elseif T and (T.state ~= "idle" or #T.queue > 0) then txt = "买入中"
            else txt = string.format("%d秒", left) end
            btnAuto:Set(true, "自动扫货 " .. txt)
        else
            btnAuto:Set(false, "自动扫货")
        end
    end
end)

-- 面板右下角：自动开关，只在对应的场景里出现。实际干活的是电脑上的 agent，这里只是告诉它该做什么。
local modeFish, modeSnipe, modePress
ForeverQuantModes = {}        -- 具体做什么在文件后面填进来
local function ModeButton(xFromRight, w, onClick, tip)
    local b = StyleToggle(CreateFrame("Button", nil, frame))
    b:SetSize(w, 20); b:SetPoint("BOTTOMRIGHT", -xFromRight, 8)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(tip, 1, 1, 1, true); GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end
modeFish = ModeButton(10, 100, function() ForeverQuantModes.Fish() end,
    "开始或停止自动钓鱼。电脑端程序听到水花声替你收竿；背包满、死亡、掉线会自动停。")
modeSnipe = ModeButton(120, 100, function() ForeverQuantModes.Snipe() end,
    "打开后：「绿装捡漏」里「建议」一栏是「买」的货，就去核对实时挂单，价格没变就排队等买；买到的货到包里后排队等上架。每一笔由电脑端程序按一次动作键成交；电脑端程序没连上时要你自己按。")
modePress = ModeButton(10, 100, function() ForeverQuantModes.Press() end,
    "打开后：背包里待上架的货，查好同款价就由电脑端程序自动挂出去。关着时要你点「挂出」按钮，一次一件。")
ForeverQuantModes.blueBtn = ModeButton(400, 140, function() ForeverQuantModes.Blue() end,
    "蓝色武器单独一个开关，和绿装那三个开关互不相干。打开后，拍卖行开着时在后台自动管蓝武：每 30 秒扫一遍；明显标错的低价单直接买（单把不超过 10 金、蓝武合计不超过 20 金）；控价的货按定好的规矩收和挂；有变化在聊天栏报一句。关着时蓝武什么都不做。重载界面后默认是关的。")
ForeverQuantModes.sweepBtn = ModeButton(550, 110, function() ForeverQuantModes.Sweep() end,
    "默认开着。上架查同款价时，如果最便宜的一两件明显是标错的（比后面的同款便宜一半以上），不跟着它压价，直接买下来，买到的一起挂。关掉后只贴着同款最低价挂，不买。")

for i = 1, NCOL do
    local h = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h:SetJustifyH("LEFT"); headers[i] = h
end

function Refresh()
    local view = VIEWS[mode]
    local list = view.list()
    local A = ForeverQuantAction
    local online = A and A.Online and A.Online()
    title:SetText(string.format("ForeverQuant  |cffaaaaaa%s|r   电脑端程序：%s", data.market or "",
        online and "|cff40ff40已连上|r" or (A and A.key and "|cffff6060没连上（自动功能都不会动）|r" or "|cffaaaaaa没有可用的按键|r")))
    tabGear:SetText(string.format("绿装捡漏 (%d)", #gearBudget))
    tabRecipe:SetText(string.format("配方转卖 (%d)", #recipes))
    tabLedger:SetEnabled(mode ~= "ledger"); tabTod:SetEnabled(mode ~= "tod"); tabBiz:SetEnabled(mode ~= "biz"); VIEWS.blue.tab:SetEnabled(mode ~= "blue")
    tabDe:SetText(string.format("今天划算的 (%d)", #deList))
    tabWatch:SetText(string.format("我常分解的 (%d)", #watches))
    tabGear:SetEnabled(mode ~= "gear"); tabRecipe:SetEnabled(mode ~= "recipe"); tabDe:SetEnabled(mode ~= "de")
    tabWatch:SetEnabled(mode ~= "watch")
    local scene = SCENE[mode]
    sceneFish:SetEnabled(scene ~= "fish"); sceneDe:SetEnabled(scene ~= "de"); sceneTrade:SetEnabled(scene ~= "trade")
    for b, sc in pairs({ [tabGear] = "trade", [tabRecipe] = "trade", [tabLedger] = "trade", [tabTod] = "trade", [tabBiz] = "trade", [VIEWS.blue.tab] = "trade", [tabDe] = "de", [tabWatch] = "de" }) do
        if sc == scene then b:Show() else b:Hide() end
    end
    -- 各场景自己的开关只在自己的页签里出现
    if mode == "gear" then btnNow:Show() else btnNow:Hide() end
    if scene == "trade" then btnAuto:Show() else btnAuto:Hide() end
    foot:Hide()        -- 底部那行说明放不下整句，去掉了；要点都在各按钮的鼠标提示里
    credit:SetText("")        -- 界面上不显示数据来源（用户决定）
    if scene == "fish" then modeFish:Show() else modeFish:Hide() end
    if scene == "trade" then modeSnipe:Show(); modePress:Show(); ForeverQuantModes.sweepBtn:Show() else modeSnipe:Hide(); modePress:Hide(); ForeverQuantModes.sweepBtn:Hide() end
    if scene == "fish" then btnScan:Hide() else btnScan:Show() end
    if scene == "trade" then
        local text, can = "上架背包里的货", true
        if ForeverQuantModes.SellState then text, can = ForeverQuantModes.SellState() end
        btnSell:SetText(text); btnSell:SetEnabled(can)
        btnSell:Show()
        local n = #((ForeverQuantDB and ForeverQuantDB.holdings) or {})
        if n > 0 then btnClear:SetText(string.format("清空待上架 (%d)", n)); btnClear:Show() else btnClear:Hide() end
    else
        btnSell:Hide(); btnClear:Hide()
    end
    if mode == "watch" then btnWatch:Show() else btnWatch:Hide() end
    if mode == "gear" then
        btnAll:Set(showAll, string.format("含买不起的 %d 条", #gearAll - #gearBudget))
        btnAll:Show()
    else
        btnAll:Hide()
    end
    if mode == "ledger" then
        btnLive:Hide()
        local sum = ForeverQuantLedger.Build(); list = ledgerRows
        sub:SetText(string.format("已卖出 %d 笔 · 净赚合计 %s（%d 笔缺买入价没算）· 平均 %s 卖掉 · 在售 %d · 流拍 %d%s",
            sum.sold, SilverText(sum.net), sum.noCost, sum.sold > 0 and Dur(sum.avgTook) or "-", sum.open, sum.expired,
            sum.bestHour and string.format(" · 卖出最多的时段 %02d 点（%d 笔）", sum.bestHour, sum.bestHourN) or ""))
        foot:SetText("买入和上架从接口上记，卖出和流拍靠系统消息；你不在线时卖掉的要等上线后收到消息才记上。")
    elseif mode == "blue" then
        btnLive:Hide()
        local B = data.blue
        local ORDER = { ["可以进"] = 1, ["可以进（走得慢）"] = 2, ["偏低"] = 3, ["等"] = 4, ["在跌，先别进"] = 5, ["高位（出货）"] = 6, ["没货"] = 7 }
        local COLOR = { ["可以进"] = "|cff40ff40", ["可以进（走得慢）"] = "|cffa0e0a0", ["偏低"] = "|cffffffff", ["等"] = "|cff808080",
                        ["在跌，先别进"] = "|cffff8040", ["高位（出货）"] = "|cff55ccff", ["没货"] = "|cff808080" }
        local out, n, live = {}, 0, 0
        for _, r in ipairs(B and B.items or {}) do
            -- 现价：游戏里做过全量扫描就用扫到的（没扫到 = 现在没货），否则用电脑端分析时的
            local P = ForeverQuantPool
            local scanned = next(livePrices) ~= nil
            if P and P.blueLive then                         -- 刚刷新过 / 蓝武扫过：最新
                local e = P.blueLive[r.item_id]
                r.now, r.nowQty = e and e.price or 0, e and e.qty or 0
                live = live + 1
            else
                r.now, r.nowQty = scanned and (livePrices[r.item_id] or 0) or r.cur, nil
                if scanned then live = live + 1 end
            end
            local ref = math.min(r.typ, r.recent or r.typ)        -- 在跌的货按最近一天的价估，不按一周前的
            r.net = math.floor(ref * (1 - AH_CUT)) - r.now
            local v
            if r.now <= 0 then v, r.net = "没货", 0
            elseif r.now <= r.low and r.net >= r.now * 0.15 then v = (r.spd >= 2) and "可以进" or "可以进（走得慢）"
            elseif (r.recent or r.typ) < r.typ * 0.85 then v = "在跌，先别进"
            elseif r.net >= r.now * 0.15 then v = "偏低"
            elseif r.now >= r.high then v = "高位（出货）"
            else v = "等" end
            r.verdict, r.verdictText = v, COLOR[v] .. v .. "|r" .. (r.snipe and (" |cff55ccff盯·" .. r.snipe .. "|r") or "")
            local mine, plan = 0, nil
            for _, h in ipairs(ForeverQuantDB.holdings or {}) do
                if h.name == r.name and h.manual then mine = mine + 1; plan = plan or h.post or h.target end      -- 只算你亲手买的
            end
            r.mineText = mine > 0 and string.format("|cffffd040持%d·%s|r", mine, SilverText(plan or 0)) or nil
            if ORDER[v] <= 2 then n = n + 1 end
            out[#out + 1] = r
        end
        table.sort(out, function(a, b)
            if ORDER[a.verdict] ~= ORDER[b.verdict] then return ORDER[a.verdict] < ORDER[b.verdict] end
            return a.net * math.min(a.spd, 5) > b.net * math.min(b.spd, 5)
        end)
        data.blueRows = out; list = out
        sub:SetText(B and string.format("40 级以下蓝色武器 %d 把，现在可以进的 %d 把 · 价格画像 %s · 现价%s · ↓ = 最近一天在跌 · 标「盯」的在快扫里盯六成价以下的单",
            #out, n, Age(B.at), (ForeverQuantPool and ForeverQuantPool.blueLive) and ("是 " .. Age(ForeverQuantPool.blueLiveAt) .. "刷新的")
                or (live > 0 and "来自游戏内扫描" or "来自电脑端（点「刷新现价」拉最新的）"))
            or "还没有蓝色武器的数据：电脑端下次分析时生成（或运行 python3 -m quant blue）。需要本机装了 DungeonsForeverGear 插件。")
    elseif mode == "biz" then
        btnLive:Hide()
        local S
        bizRows, S = ForeverQuantLedger.BizRows(); list = bizRows
        sub:SetText(string.format("资产 %s = 现金 %s + 货（按商店收购价）%s + 没到账的货款 %s + 押金 %s · 只统计买卖记录里记到的",
            SilverText(S.assets), SilverText(S.cash), SilverText(S.stock), SilverText(S.transit), SilverText(S.depHeld)))
    elseif mode == "tod" then
        btnLive:Hide()
        local t = data.tod
        sub:SetText(t and string.format("本地时间 · 近 %d 小时的数据，样本少只当参考 · %s",
            t.hours or 0, t.market_note or "") or "还没有时段数据：电脑端会在下次分析时生成（或运行 python3 -m quant tod）")
        foot:SetText("想低买高卖大宗货：在「最便宜的时段」进，在「最贵的时段」出。高低相差不到 10% 的扣完抽成没有意义。")
    elseif mode == "fish" then
        btnLive:Hide()
        BuildFishRows(); list = fishRows
        local key = SpotHere()
        local x, y = PlayerXY()
        local sp = ForeverQuantDB.fish and ForeverQuantDB.fish.spots[key]
        local where = key .. (x and string.format("（%.0f, %.0f）", x, y) or "")
        if sp and sp.total > 0 then
            local value, perHour, valuePerHour = SpotStats(sp)
            sub:SetText(string.format("当前位置：%s · 这里已钓 %d 条 · %s · %s", where, sp.total,
                perHour and string.format("约 %.0f 条/小时", perHour) or "时间太短，还算不出速度",
                valuePerHour and ("估算每小时 " .. SilverText(valuePerHour)) or "每条平均 " .. SilverText(value / sp.total)))
        else
            sub:SetText("当前位置：" .. where .. " · 这里还没有记录")
        end
        foot:SetText("价格用最近一次扫描的拍卖行最低价（让 3%、扣抽成），和卖店价取高的。收益是按实际钓到的东西算的。")
    elseif mode == "recipe" then
        btnLive:Show()
        sub:SetText(string.format("价格：%s · 共 %d 种 · 滚轮翻页 · 进价按商人收购价 x4 估算，以商人实际卖价为准",
            liveAt and ("游戏内刷新于 " .. Age(liveAt)) or ("扫描于 " .. Age(data.prices_at)), #list))
        foot:SetText("点「导航」：在地图上标出卖这个配方的商人。打开拍卖行后：点一行搜索；点「刷新配方价格」读当前行情。")
    elseif mode == "watch" then
        btnLive:Hide()
        sub:SetText(string.format("价格：%s · 鼠标放到行上看材料明细和保本价 · 「止买线」= 买入价高过它，利润率就不到 15%% 了，别再买",
            watchLiveAt and ("游戏内刷新于 " .. Age(watchLiveAt)) or ("更新于 " .. Age(data.watch_at))))
        foot:SetText("这里是你固定反复买来分解的货。每行右侧按钮：把包里的这种物品全部自动分解（需要电脑端程序已连上）。")
    elseif mode == "de" then
        btnLive:Hide()
        sub:SetText(string.format("%s · 共 %d 件 · 有些物品游戏不允许分解，这里分辨不出来：没实测过的先只买一件试",
            liveGearAt and ("游戏内刷新于 " .. Age(liveGearAt)) or ("扫描于 " .. Age(data.prices_at)), #list))
        foot:SetText("打开拍卖行后点一行搜索。从最便宜的往上买，买到「止买线」为止。标「先试一件」的没实测过能否分解。")
    else
        btnLive:Hide()
        local P = ForeverQuantPool
        local quick = (P and P.doneAt) and string.format(" · 快扫 %d 秒前（%s %d 件%s，细查 %d，用时 %d 秒%s）", GetTime() - P.doneAt, P.how or "", P.n,
            P.how == "偏好批量" and ("、有货 " .. (P.favSeen or 0) .. ((P.over or 0) > 0 and ("、偏好位外 " .. P.over) or "")) or "", P.detail or 0, P.took or 0,
            (P.timeouts or 0) > 0 and ("，" .. P.timeouts .. " 件没回应") or "") or ""
        sub:SetText(string.format("全量%s%s · %s %d 条 · 鼠标放到行上看依据",
            liveGearAt and (" " .. Age(liveGearAt)) or ("（电脑端）" .. Age(data.prices_at)), quick,
            showAll and "全部" or "买得起的", #list))
        foot:SetText("点一行：去拍卖行搜这件。行首小按钮：左键标「要」、右键标「不要」。 Prices from AHledger")
    end
    local M = ForeverQuantModes
    modeFish:Set(M.fishing and M.fishing(), "自动钓鱼")
    modeSnipe:Set(M.sniping and M.sniping(), "自动买入")
    modePress:Set(M.pressing and M.pressing(), "自动上架")
    M.sweepBtn:Set(M.sweeping and M.sweeping(), "买断压价单")
    M.blueBtn:Set(M.blueOn and M.blueOn(), "自动管理蓝装")
    if mode == "blue" then M.blueBtn:Show() else M.blueBtn:Hide() end
    if mode == "blue" then
        local P = ForeverQuantPool
        VIEWS.blue.btn:SetText(P and (P.pull or P.bq) and "刷新中……" or "刷新现价")
        VIEWS.blue.btn:SetEnabled(not (P and (P.pull or P.bq)))
        VIEWS.blue.btn:Show()
    else
        VIEWS.blue.btn:Hide()
    end
    for i = 1, NCOL do
        local c = view.cols[i]
        if c then
            headers[i]:ClearAllPoints(); headers[i]:SetPoint("TOPLEFT", c[2], -122)
            headers[i]:SetWidth(c[3]); headers[i]:SetText(c[1]); headers[i]:Show()
        else
            headers[i]:Hide()
        end
    end
    for i = 1, ROWS do
        local r, op = rows[i], list[i + offset]
        if op then
            for j = 1, NCOL do
                local c, fs = view.cols[j], r.cells[j]
                if c then
                    fs:ClearAllPoints(); fs:SetPoint("LEFT", c[2], 0); fs:SetWidth(c[3])
                    fs:SetText(c[4](op)); fs:Show()
                else
                    fs:Hide()
                end
            end
            r.op = op; r:Show()
            r.nav:ClearAllPoints()
            if mode == "gear" then                      -- 标注按钮放行首，好点
                r.nav:SetSize(44, ROW_H - 2); r.nav:SetPoint("TOPLEFT", 8, r.navY)
            else
                r.nav:SetSize(60, ROW_H - 2); r.nav:SetPoint("TOPLEFT", WIDTH - 76, r.navY)
            end
            if mode == "gear" then
                r.nav:SetText(op.marked == "want" and string.format("|cff40ff40要%.1f|r", op.wantGap or 0) or (op.marked == "no" and "|cffff6060不要|r" or "|cff808080标|r"))
                r.nav:Show()
            elseif mode == "ledger" and (op.status == "held" or op.status == "used") then
                r.nav:SetText(op.status == "held" and "不卖了" or "|cff40ff40再上架|r"); r.nav:Show()
            elseif mode == "blue" and ((op.now or 0) > 0 or (ForeverQuantTrade.cur and ForeverQuantTrade.cur.blueRow == op)) then
                local T = ForeverQuantTrade
                local busy = (T.cur and T.cur.blueRow == op)
                for _, q in ipairs(T.queue or {}) do if q.blueRow == op then busy = true end end
                r.nav:SetText(busy and "|cffffd040买入中|r" or "|cff40ff40买这把|r"); r.nav:Show()
            elseif mode == "recipe" and op.vendors and #op.vendors > 0 then
                r.nav:SetText("导航"); r.nav:Show()
            elseif mode == "fish" and op.kind == "fish" then
                local junk = ForeverQuantDB.junk and ForeverQuantDB.junk[op.item_id]
                r.nav:SetText(junk and "|cffff6060会扔|r" or "保留")
                r.nav:Show()
            elseif mode == "watch" then
                local n = BagCount(op.item_id)
                if auto and auto.itemId == op.item_id then
                    r.nav:SetText("|cffff6060停止|r 剩" .. n)
                else
                    r.nav:SetText(n > 0 and ("分解 x" .. n) or "包里没有")
                end
                r.nav:Show()
            else
                r.nav:Hide()
            end
        else
            r.op = nil; r:Hide(); r.nav:Hide()
        end
    end
end

local function SearchAH(name)
    if not (name and AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return false end
    return pcall(function()
        local bar = AuctionHouseFrame.SearchBar
        bar.SearchBox:SetText(name)
        bar:StartSearch()
    end)
end

for i = 1, ROWS do
    local r = CreateFrame("Button", nil, frame)
    r:SetSize(WIDTH - 84, ROW_H); r:SetPoint("TOPLEFT", 0, -140 - (i - 1) * ROW_H)
    r.nav = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    r.navY = -141 - (i - 1) * ROW_H
    r.nav:SetSize(60, ROW_H - 2); r.nav:SetPoint("TOPLEFT", WIDTH - 76, r.navY)
    r.nav:SetFrameLevel((tonumber(r:GetFrameLevel()) or 1) + 3)          -- 绿装页里它在行首、压在行上面，要保证点得到
    r.nav:SetText("导航")
    r.nav:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.nav:SetScript("OnEnter", function(self)
        if mode == "blue" then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("买下这把武器现在最便宜的那一件", 0.25, 1, 0.25)
            GameTooltip:AddLine("买之前会核对实时挂单：价格没涨过这一行显示的现价才买。买到后记下计划挂价（贴着下一把的价，不超过这把平时的高位），并把这一行的现价换成下一把的价。", 1, 1, 1, true)
            GameTooltip:AddLine("每一笔由电脑端程序按一次动作键成交；没连上时要你自己按。", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
            return
        end
        if mode ~= "gear" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("左键：要 —— 记下现在的差价倍数，这个倍数及以上的都买（星级不变）", 0.25, 1, 0.25)
        GameTooltip:AddLine("右键：不要（零星，沉到最后，不会自动买）", 1, 0.4, 0.4)
        GameTooltip:AddLine("再点一次同一个键取消。每次标注都会记一条校正记录。", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    r.nav:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.nav:SetScript("OnClick", function(_, button)
        if not r.op then return end
        if mode == "gear" then
            SetMark(r.op, button ~= "RightButton")
            ApplyMarks(gearAll); ApplyMarks(gearBudget)
            local T = ForeverQuantTrade
            if T and r.op.marked == "want" then T.BuyNow(r.op) elseif T then T.Drop(r.op) end
            Refresh()
            return
        end
        if button == "RightButton" then return end
        if mode == "ledger" then
            ForeverQuantModes.Relist(r.op)
            return
        end
        if mode == "blue" then
            ForeverQuantTrade.BuyBlueRow(r.op)
            Refresh()
            return
        end
        if mode == "watch" then
            StartAutoDE(r.op.item_id, r.op.name)       -- 正在跑的话就是停止
            return
        end
        if mode == "fish" then
            if r.op.kind == "fish" then ForeverQuantJunk.Toggle(r.op.item_id) end
            Refresh()
            return
        end
        Navigate(r.op); Refresh()
        frame:Hide()          -- 让开位置，不然会挡住地图；点小地图图标或输入 /fq 回来
    end)
    r.nav:Hide()
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.cells = {}
    for j = 1, NCOL do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
        r.cells[j] = fs
    end
    r:SetScript("OnEnter", function(self)
        local op = self.op
        if not op or not op.item_id or op.item_id == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(string.format("item:%d:0:0:0:0:0:%d", op.item_id, op.suffix_id or 0))
        if mode == "blue" and op.why then            -- 需求指数的完整理由
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("需求指数 " .. Stars(op.need or 0) .. "  " .. (op.who or ""), 0.33, 0.8, 1)
            for line in string.gmatch(op.why .. " ## ", "(.-) ## ") do
                if line ~= "" then GameTooltip:AddLine(line, 1, 1, 1, true) end
            end
        end
        if mode == "watch" and op.yields then       -- 切页签的瞬间，鼠标下的行可能还是上一张表的数据
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("每次分解只出下面一种：", 0.4, 1, 0.4)
            for _, y in ipairs(op.yields) do
                GameTooltip:AddDoubleLine(string.format("%d%%  %s x%.1f", y.chance * 100 + 0.5, ItemInfo(y.id) or y.name, y.qty),
                    "现价 " .. Money(y.price), 1, 0.82, 0, 1, 1, 1)
            end
            -- 主要材料跌到多少还保本（其余材料价格不变）
            local k, other, coef = 0.97 * (1 - AH_CUT), 0, 0
            for _, y in ipairs(op.yields) do
                if y.id == op.main_id then coef = coef + y.chance * y.qty else other = other + y.chance * y.qty * y.price end
            end
            if coef > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine("按现价买，主要材料跌到多少就亏", Money(math.max(0, (op.min_price / k - other) / coef)), 1, 1, 1, 1, 1, 1)
            end
            GameTooltip:AddLine(string.format("建议每天不超过约 %d 件，免得自己把材料价砸下去。", op.daily_cap or 0), 0.7, 0.7, 0.7, true)
            if (op.vendor_price or 0) > 0 then
                GameTooltip:AddDoubleLine("保底：直接卖商人", Money(op.vendor_price), 1, 1, 1, 1, 1, 1)
            end
            GameTooltip:AddLine("买入价超过「分解期望到手」就别买了。", 0.7, 0.7, 0.7, true)
        end
        if mode == "gear" and (op.suffix_id or 0) ~= 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("要买的是：" .. op.name, 0.4, 1, 0.4, true)
            GameTooltip:AddLine("这里显示的是不带后缀的基础款，所以看不到属性。", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("打开拍卖行后点这一行，会搜出这件装备的所有后缀，挑上面这个名字的。", 0.7, 0.7, 0.7, true)
        end
        if op.reason and op.reason ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(Stars(op.stars) .. "  " .. op.reason, 1, 1, 1, true)
        end
        if op.note and op.note ~= "" then
            GameTooltip:AddLine(" "); GameTooltip:AddLine(op.note, 1, 0.6, 0.2, true)
        end
        if op.vendors and #op.vendors > 0 then
            GameTooltip:AddLine(" "); GameTooltip:AddLine("哪里的商人有卖：", 0.4, 1, 0.4)
            for i, v in ipairs(op.vendors) do
                if i > 8 then GameTooltip:AddLine(string.format("…… 共 %d 处", #op.vendors), 0.7, 0.7, 0.7) break end
                GameTooltip:AddLine(string.format("%s %.0f,%.0f  %s", v.zone, v.x, v.y, v.name), 1, 0.82, 0)
            end
        end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self)
        local op = self.op
        if not op or not op.item_id or op.item_id == 0 then return end      -- 说明行、缺物品编号的账本行不能搜
        -- 拍卖行搜索只认不带后缀的基础名
        local base = ItemInfo(op.item_id) or (op.name ~= "" and op.name)
        if not SearchAH(base) then
            print("|cff55ccffFQ|r 先打开拍卖行，再点这一行就会自动搜索：" .. (op.name ~= "" and op.name or base or "?"))
        end
    end)
    rows[i] = r
end

frame:EnableMouseWheel(true)
frame:SetScript("OnMouseWheel", function(_, delta)
    local n = #VIEWS[mode].list()
    offset = math.max(0, math.min(math.max(0, n - ROWS), offset - delta * 3))
    Refresh()
end)
frame:SetScript("OnShow", Refresh)

local function Toggle(which)
    if which and which ~= mode then
        mode, offset = which, 0
        frame:Show(); Refresh()
    elseif frame:IsShown() then
        frame:Hide()
    else
        frame:Show(); Refresh()
    end
end

-- 钓鱼保护：给外部的钓鱼脚本一个状态块（在分解信号块的正下方）。
-- 绿 = 一切正常；红 = 背包满了；橙 = 角色死了。状态块不见了 = 掉线、读条界面或不在游戏世界里。
-- 脚本看到非绿色或连续几秒看不到状态块就停止按键。用 /fq fish 开关，开关状态会记住。
local guard = CreateFrame("Frame", "ForeverQuantGuard", UIParent)
guard:SetSize(14, 14); guard:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -26)
guard:SetFrameStrata("TOOLTIP")
local guardTex = guard:CreateTexture(nil, "OVERLAY")
guardTex:SetAllPoints()
guard:Hide()
local guardTick, guardState = 0, nil
local function FreeBagSlots()
    local free = 0
    local get = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    for bag = 0, 4 do
        local n = get and get(bag)
        if n then free = free + n end
    end
    return free
end
local function UpdateGuard()
    local state = "ok"
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then state = "dead"
    elseif FreeBagSlots() == 0 then state = "full" end
    if state ~= guardState then
        guardState = state
        if state == "ok" then guardTex:SetColorTexture(0, 1, 0, 1)
        elseif state == "full" then
            guardTex:SetColorTexture(1, 0, 0, 1)
            print("|cff55ccffFQ|r 背包满了，钓鱼脚本会停下。")
        else
            guardTex:SetColorTexture(1, 0.5, 0, 1)
            print("|cff55ccffFQ|r 角色死亡，钓鱼脚本会停下。")
        end
    end
end
guard:SetScript("OnUpdate", function(_, elapsed)
    guardTick = guardTick + elapsed
    if guardTick < 1 then return end
    guardTick = 0
    UpdateGuard()
end)
local function SetGuard(on)
    ForeverQuantDB.fishGuard = on and true or false
    guardState = nil
    if on then UpdateGuard(); guard:Show() else guard:Hide() end
end

-- 钓鱼请求：黄色小块（在状态块正下方）。亮着 = 请电脑端的 agent 开始钓鱼；灭了就停。
-- 背包满或角色死亡时自动撤掉。重载界面后默认是关的，要重新开。
local fishReq = CreateFrame("Frame", "ForeverQuantFishRequest", UIParent)
fishReq:SetSize(14, 14); fishReq:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -44)
fishReq:SetFrameStrata("TOOLTIP")
local fishReqTex = fishReq:CreateTexture(nil, "OVERLAY")
fishReqTex:SetAllPoints(); fishReqTex:SetColorTexture(1, 1, 0, 1)
fishReq:Hide()
local fishingOn = false
-- 听声钓鱼要安静：开始钓鱼时关掉音乐和环境音、确保音效开着，停止时恢复成原来的设置。
-- 原来的设置存在存盘里，万一钓到一半重载或掉线，下次登录时也能恢复。
local QUIET = { Sound_EnableMusic = "0", Sound_EnableAmbience = "0", Sound_EnableSFX = "1", Sound_EnableAllSound = "1" }
local function FishSound(quiet)
    local get, set = (C_CVar and C_CVar.GetCVar) or GetCVar, (C_CVar and C_CVar.SetCVar) or SetCVar
    if not (get and set and ForeverQuantDB) then return end
    if quiet then
        if not ForeverQuantDB.soundSaved then
            local saved = {}
            for k in pairs(QUIET) do saved[k] = get(k) end
            ForeverQuantDB.soundSaved = saved
        end
        for k, v in pairs(QUIET) do pcall(set, k, v) end
    elseif ForeverQuantDB.soundSaved then
        for k, v in pairs(ForeverQuantDB.soundSaved) do if v ~= nil then pcall(set, k, v) end end
        ForeverQuantDB.soundSaved = nil
    end
end
ForeverQuantFishSound = FishSound
local function SetFishing(on, why)
    fishingOn = on and true or false
    if fishingOn then
        SetGuard(true)
        if guardState ~= "ok" then
            fishingOn = false
            print("|cff55ccffFQ|r 现在不能钓鱼：" .. (guardState == "full" and "背包满了" or "角色死亡"))
            return
        end
        fishReq:Show()
        FishSound(true)
        print("|cff55ccffFQ|r 自动钓鱼已开启（音乐和环境音已暂时关掉，停止后恢复）：电脑端程序会开始抛竿（需要它已连上，且你站在能钓鱼的水边）。再输入 /fq fish 或点面板上的按钮停止。")
    else
        fishReq:Hide()
        FishSound(false)
        print("|cff55ccffFQ|r 钓鱼已停止" .. (why and ("（" .. why .. "）") or "") .. "。")
    end
    if frame:IsShown() then Refresh() end
end
-- 钓鱼期间：累计这片水域的钓鱼时长，记下钓到的每样东西
local fishTick, fishSpot = 0, nil
fishReq:SetScript("OnUpdate", function(_, elapsed)
    if fishingOn and guardState and guardState ~= "ok" then
        SetFishing(false, guardState == "full" and "背包满了" or "角色死亡")
        return
    end
    if not fishingOn then return end
    fishTick = fishTick + elapsed
    if fishTick < 1 then return end
    ForeverQuantDB.fish = ForeverQuantDB.fish or { spots = {} }
    local key, zone, sub = SpotHere()
    local sp = ForeverQuantDB.fish.spots[key]
    if not sp then
        sp = { zone = zone, sub = sub, total = 0, seconds = 0, catches = {} }
        ForeverQuantDB.fish.spots[key] = sp
    end
    sp.seconds = sp.seconds + fishTick
    fishTick = 0
    local x, y = PlayerXY()
    if x then sp.x, sp.y = x, y end
    fishSpot = sp
end)
local fishLoot = CreateFrame("Frame")
pcall(fishLoot.RegisterEvent, fishLoot, "CHAT_MSG_LOOT")
fishLoot:SetScript("OnEvent", function(_, _, msg, _, _, _, who)
    if not fishingOn or not fishSpot or type(msg) ~= "string" then return end
    if who and who ~= "" and not string.find(who, UnitName("player") or "?", 1, true) then return end   -- 别人的拾取不算
    local id = tonumber(string.match(msg, "|Hitem:(%d+)"))
    if not id then return end
    local n = tonumber(string.match(msg, "|h|r[xX×](%d+)")) or 1
    fishSpot.catches[id] = (fishSpot.catches[id] or 0) + n
    fishSpot.total = fishSpot.total + n
    fishSpot.last = time()
    if frame:IsShown() and mode == "fish" then Refresh() end
end)

-- 小地图图标：左键开关面板，右键直接看配方，按住拖动可以沿小地图边缘挪位置
local mini = CreateFrame("Button", "ForeverQuantMinimapButton", Minimap)
mini:SetSize(31, 31)
mini:SetFrameStrata("MEDIUM"); mini:SetFrameLevel(8)
mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mini:RegisterForDrag("LeftButton")
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local miniIcon = mini:CreateTexture(nil, "BACKGROUND")
miniIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
miniIcon:SetSize(20, 20); miniIcon:SetPoint("CENTER", 0, 1)
miniIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
local miniBorder = mini:CreateTexture(nil, "OVERLAY")
miniBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
miniBorder:SetSize(53, 53); miniBorder:SetPoint("TOPLEFT")

local function PlaceMini()
    local angle = math.rad((ForeverQuantDB and ForeverQuantDB.minimapAngle) or 5)
    local radius = Minimap:GetWidth() / 2 + 6
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end
mini:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        ForeverQuantDB.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
        PlaceMini()
    end)
end)
mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mini:SetScript("OnClick", function(_, button)
    if button == "RightButton" then Toggle("recipe") else Toggle() end
end)
mini:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("ForeverQuant", 0.33, 0.8, 1)
    GameTooltip:AddDoubleLine("绿装错标", string.format("%d 条（全部 %d）", #gearBudget, #gearAll), 1, 1, 1, 1, 0.82, 0)
    GameTooltip:AddDoubleLine("配方倒卖", #recipes .. " 种", 1, 1, 1, 1, 0.82, 0)
    GameTooltip:AddDoubleLine("今天划算的分解", #deList .. " 件", 1, 1, 1, 1, 0.82, 0)
    for _, w in ipairs(watches) do
        GameTooltip:AddDoubleLine("常分解 " .. w.name, string.format("%s%s|r 每件 %s", VERDICT_COLOR[w.verdict] or "", w.verdict, Money(w.profit_min)),
            1, 1, 1, 1, 1, 1)
    end
    if autoOn then GameTooltip:AddDoubleLine("自动扫货", liveGearAt and ("上次 " .. Age(liveGearAt)) or "已开启", 1, 1, 1, 0.25, 1, 0.25) end
    GameTooltip:AddDoubleLine("行情", liveAt and ("配方刷新于 " .. Age(liveAt)) or ("扫描于 " .. Age(data.prices_at)), 1, 1, 1, 0.7, 0.7, 0.7)
    local best = recipes[1]
    if best and best.min_price > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("当前排第一的配方：", 0.4, 1, 0.4)
        GameTooltip:AddDoubleLine(best.name, "每张净赚 " .. Money(best.net), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("左键：开关面板    右键：配方页", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("拖动：沿小地图边缘移动图标", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- 小地图旁的插件收纳菜单（新版界面有）里也能点开
function ForeverQuant_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then Toggle("recipe") else Toggle() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        ForeverQuantDB = ForeverQuantDB or {}
        ForeverQuantDB.log = ForeverQuantDB.log or {}
        for k, v in pairs(ForeverQuantDB.known or {}) do          -- 名单上出现过的货：普通的记 3 天
            local keepDays = ((v.best or v.stars or 1) >= 2) and 14 or 3      -- 到过二星以上的是高概率池，留两周
            if time() - (v.t or 0) > keepDays * 86400 then ForeverQuantDB.known[k] = nil end
        end
        ForeverQuantDB.known = ForeverQuantDB.known or {}
        for _, line in ipairs(ForeverQuantDB.liveLog or {}) do      -- 以前扫到过的候选也算（你这次手动买的那些就在里面）
            local t, id, suffix, buy, target, stars, name = string.match(line, "^(%d+)|(%d+)|(%-?%d+)|(%d+)|(%d+)|(%d+)|(.+)$")
            if name and tonumber(target) > 0 then
                local k = id .. ":" .. name
                local old = ForeverQuantDB.known[k]
                if (not old or (old.t or 0) < tonumber(t)) and time() - tonumber(t) <= 3 * 86400 then
                    ForeverQuantDB.known[k] = { target = tonumber(target), buy = tonumber(buy), suffix = tonumber(suffix), stars = tonumber(stars),
                        best = math.max(tonumber(stars), old and (old.best or old.stars) or 0), verified = old and old.verified or false,
                        ilvl = old and old.ilvl, id = tonumber(id), name = name, t = tonumber(t) }
                end
            end
        end
        ApplyMarks(gearAll); ApplyMarks(gearBudget)
        if ForeverQuantFishSound then ForeverQuantFishSound(false) end      -- 上次钓到一半就重载/掉线了：把声音设置恢复
        PlaceMini()
        if ForeverQuantDB.fishGuard then SetGuard(true) end
        if ForeverQuantAction then ForeverQuantAction.Bind(); ForeverQuantAction.nextPing = GetTime() + 5 end
        for _, op in ipairs(gearAll) do ItemLink(op.item_id) end   -- 预取物品信息
        print(string.format("|cff55ccffForeverQuant|r 已载入 绿装 %d 条、配方 %d 种、分解 %d 件（扫描于 %s）。/fq 查看，/fq help 看命令。",
            #gearBudget, #recipes, #deList, Age(data.prices_at)))
    elseif frame:IsShown() then
        Refresh()
    end
end)

-- 分解宏：按一次键分解一件指定物品。只认这一个物品 ID，不会分解别的东西。
local DE_SPELL, DE_MACRO = 13262, "FQ分解"
local DE_KEYS = { "F8", "F7", "F6", "F5", "F11", "F12", "F9" }   -- 依次找一个没被占用的
local function SetupDisenchantMacro(arg, quiet)
    if InCombatLockdown and InCombatLockdown() then print("|cff55ccffFQ|r 战斗中不能改宏和按键，脱战后再试") return end
    local itemId = tonumber(arg) or (watches[1] and watches[1].item_id)
    if not itemId then print("|cff55ccffFQ|r 「我常分解的」里还没有物品，用 /fq demacro 物品ID 指定要分解的物品") return end
    local spell = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(DE_SPELL)) or (GetSpellInfo and GetSpellInfo(DE_SPELL))
    if not spell then print("|cff55ccffFQ|r 查不到「分解」这个技能，你的角色学附魔了吗？") return end
    local known = (IsSpellKnown and IsSpellKnown(DE_SPELL)) or (IsPlayerSpell and IsPlayerSpell(DE_SPELL))
    -- 第一行和最后一行取消"等待选择目标"的状态：物品用完后再按也不会留下一个待分解的光标
    local body = string.format("/stopspelltarget\n/cast %s\n/use item:%d\n/stopspelltarget", spell, itemId)
    local idx = GetMacroIndexByName(DE_MACRO)
    local ok, err
    if idx and idx > 0 then
        ok, err = pcall(EditMacro, idx, DE_MACRO, nil, body)
    else
        ok, err = pcall(CreateMacro, DE_MACRO, "INV_Enchant_Disenchant", body, nil)
    end
    if not ok then print("|cff55ccffFQ|r 创建宏失败（宏栏满了？）：" .. tostring(err)) return end
    local name = ItemInfo(itemId) or ("物品 " .. itemId)
    local mine, key = "MACRO " .. DE_MACRO, nil
    for _, k in ipairs(DE_KEYS) do            -- 已经绑过的优先，其次第一个空闲的
        if GetBindingAction(k) == mine then key = k break end
    end
    if not key then
        for _, k in ipairs(DE_KEYS) do
            if GetBindingAction(k) == "" then key = k break end
        end
    end
    if key then
        SetBindingMacro(key, DE_MACRO)
        SaveBindings(GetCurrentBindingSet())
        if not quiet then
            print(string.format("|cff55ccffFQ|r 宏「%s」已就绪并绑定到 %s：每按一次分解一件 %s（背包里现有 %d 件）。",
                DE_MACRO, key, name, BagCount(itemId)))
        end
    else
        print(string.format("|cff55ccffFQ|r 宏「%s」已建好（分解 %s），但 %s 这几个键都被占用了，没有改绑。请打开宏界面把它拖到动作条上，或自己绑一个键。",
            DE_MACRO, name, table.concat(DE_KEYS, "/")))
    end
    if not known then print("|cff55ccffFQ|r 提醒：没检测到你已学会「分解」，宏按了不会有效果。") end
    return key
end

-- 自动分解：游戏里不能自己连续施法，所以在屏幕左上角亮一个色块当信号，
-- 电脑上的 de_watch.py 看到色块就替你按分解键；包里分完了（或你点停止）色块消失，它就停。
-- 色块颜色：红蓝拉满，绿色通道 = 键在 DE_KEYS 里的序号 x 30，告诉外部程序该按哪个键。
local signal = CreateFrame("Frame", "ForeverQuantSignal", UIParent)
signal:SetSize(24, 24); signal:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
signal:SetFrameStrata("TOOLTIP")
local signalTex = signal:CreateTexture(nil, "OVERLAY")
signalTex:SetAllPoints()
signal:Hide()
-- auto = { itemId, name, startCount, lastCount, lastChange }

-- 这一轮分出来的东西：{物品ID = 数量}，从拾取消息里记
local lootFrame = CreateFrame("Frame")
lootFrame:SetScript("OnEvent", function(_, _, msg)
    local run = auto or lootFrame.tail
    if not run or type(msg) ~= "string" then return end
    local id = tonumber(string.match(msg, "|Hitem:(%d+)"))
    if not id or id == run.itemId then return end
    local n = tonumber(string.match(msg, "|h|r[xX×](%d+)")) or 1
    run.loot[id] = (run.loot[id] or 0) + n
end)
pcall(lootFrame.RegisterEvent, lootFrame, "CHAT_MSG_LOOT")

local function Summarize(run, reason)
    local done = run.startCount - BagCount(run.itemId)
    local parts = {}
    for id, n in pairs(run.loot) do parts[#parts + 1] = string.format("%s x%d", ItemLink(id) or ItemInfo(id) or ("物品" .. id), n) end
    print(string.format("|cff55ccffFQ|r 自动分解停止（%s）：%s 分解了 %d 件，包里还剩 %d 件。", reason, run.name, done, BagCount(run.itemId)))
    if #parts > 0 then print("|cff55ccffFQ|r 这一轮得到：" .. table.concat(parts, "，")) end
    -- 存一份，Python 那边可以拿来校准分解表
    ForeverQuantDB.deRuns = ForeverQuantDB.deRuns or {}
    local rec = string.format("%d|%d|%d", time(), run.itemId, done)
    for id, n in pairs(run.loot) do rec = rec .. string.format("|%d:%d", id, n) end
    table.insert(ForeverQuantDB.deRuns, rec)
end

function StopAutoDE(reason)
    if not auto then return end
    local run = auto
    signal:Hide()
    auto = nil
    -- 最后一件的拾取消息会晚一点到，等两秒再汇总
    lootFrame.tail = run
    local function finish() lootFrame.tail = nil; Summarize(run, reason) end
    if C_Timer and C_Timer.After then C_Timer.After(2.5, finish) else finish() end
    if frame:IsShown() then Refresh() end
end

function StartAutoDE(itemId, name)
    if auto then StopAutoDE("手动停止") return end
    local n = BagCount(itemId)
    if n == 0 then print("|cff55ccffFQ|r 包里没有 " .. name .. "，先去买。") return end
    local key = SetupDisenchantMacro(itemId, true)
    if not key then return end
    local idx
    for i, k in ipairs(DE_KEYS) do if k == key then idx = i end end
    signalTex:SetColorTexture(1, idx * 30 / 255, 1, 1)
    signal:Show()
    auto = { itemId = itemId, name = name, startCount = n, lastCount = n, lastChange = GetTime(), loot = {} }
    print(string.format("|cff55ccffFQ|r 自动分解开始：%s x%d，按键 %s。需要电脑端程序已连上。再点一次按钮停止。", name, n, key))
    if frame:IsShown() then Refresh() end
end

signal:SetScript("OnUpdate", function()
    if not auto then return end
    local n = BagCount(auto.itemId)
    if n ~= auto.lastCount then auto.lastCount, auto.lastChange = n, GetTime() end
    if n == 0 then StopAutoDE("分完了")
    elseif InCombatLockdown and InCombatLockdown() then StopAutoDE("进入战斗")
    elseif GetTime() - auto.lastChange > 40 then StopAutoDE("40 秒没有进展：电脑上的 de_watch 没开，或者背包满了")
    end
end)

--------------------------------------------------------------------------------
-- 狙击买入 + 一键上架
-- 买：自动刷新发现高星候选 -> 逐条去查实时挂单 -> 价格没变就进入"待买" -> 你按一下键（或电脑端程序替你按）就买。
-- 卖：买到的东西在邮箱里，取回后在拍卖行按一下键挂一件，价格自动用当时的目标价。
-- 每次购买/上架都由一次按键触发，这是游戏对插件的硬性要求。
-- 保险：只买"已验证"的、星级够的；实时价格高于建议买价就跳过；金币不够就跳过；每笔都记进存盘。（以前有个"本次预算"，开的时候定死、卖了货也不涨，已去掉）
--------------------------------------------------------------------------------
-- 不打扰你自己看货：暴雪的"某件物品的挂单列表"和我们后台的逐件查询共用同一份结果，我们一查，你正看的那页的行就空了，
-- 鼠标一划过去暴雪界面就报错（rowData 是 nil）。所以：
--   你的鼠标停在拍卖行窗口上、而且开着某件物品的挂单页时，后台查询先停着；
--   鼠标离开后我们照常查；等你把鼠标移回来，先把你那页重新查一遍，再让你看。
ForeverQuantView = { dirty = false }
function ForeverQuantView.Page()
    local f = AuctionHouseFrame and AuctionHouseFrame.ItemBuyFrame
    if type(f) == "table" and f.IsShown and f:IsShown() then return f end
end
function ForeverQuantView.Hover()
    return ForeverQuantView.Page() ~= nil and AuctionHouseFrame.IsMouseOver and AuctionHouseFrame:IsMouseOver() and true or false
end
function ForeverQuantView.Ready()
    return C_AuctionHouse.IsThrottledMessageSystemReady() and not ForeverQuantView.Hover() and not ForeverQuantView.restoring
end
function ForeverQuantView.Search(key, sorts, separate)
    if ForeverQuantView.Page() then ForeverQuantView.dirty = true end
    return C_AuctionHouse.SendSearchQuery(key, sorts, separate)
end
ForeverQuantView.frame = CreateFrame("Frame")
function ForeverQuantView.Tick()
    local V = ForeverQuantView
    if V.restoring and GetTime() - V.restoring > 1.5 then V.restoring = nil end
    if not V.dirty then return end
    local f = V.Page()
    if not f then V.dirty = false return end                 -- 你已经离开那一页了，不用恢复
    if not V.Hover() or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    local P, Pl, T, Pr = ForeverQuantPeer, ForeverQuantPool, ForeverQuantTrade, ForeverQuantPricing
    if (P and P.cur) or (Pl and Pl.cur) or (T and T.state == "searching") or (Pr and Pr.cur) then return end      -- 等我们手上那一条查完
    local key = f.itemKey or (f.GetItemKey and f:GetItemKey())
    V.dirty = false
    if key then V.restoring = GetTime(); pcall(C_AuctionHouse.SendSearchQuery, key, {}, false) end
end
ForeverQuantView.frame:SetScript("OnUpdate", ForeverQuantView.Tick)

local Trade = { queue = {}, done = {}, outcome = {}, state = "idle", spent = 0, on = false }
local Pricing = { cur = nil, since = 0 }       -- 上架前查同款挂价（实现在上架那一段）
ForeverQuantPricing = Pricing
local Pool = { queue = {}, cur = nil, since = 0, hits = 0, n = 0 }      -- 高概率池快扫（实现在同款印证后面）
ForeverQuantPool = Pool
local function Undercut(p) return math.max(100, math.floor((p - math.max(100, p * 0.03)) / 100) * 100) end
ForeverQuantTrade = Trade
-- 给电脑端程序的信号和自动分解共用左上角那一块：品红 = 分解（隔几秒按一次），蓝色 = 买入/上架（按一次就够）。
-- 绿色通道 = 键在 DE_KEYS 里的序号 x 30，所以买入键和上架键也从 DE_KEYS 里挑空闲的。
local buySignal = {}
function buySignal:Hide() if not auto then signal:Hide() end end
function buySignal:ShowKey(idx)
    if auto or not idx then return end                 -- 正在自动分解时不抢信号
    signalTex:SetColorTexture(0, idx * 30 / 255, 1, 1)
    signal:Show()
end

local function TradeCfg()
    ForeverQuantDB.trade = ForeverQuantDB.trade or { minStars = 3, verifiedOnly = true, autoPress = false }
    ForeverQuantDB.holdings = ForeverQuantDB.holdings or {}
    ForeverQuantDB.tradeLog = ForeverQuantDB.tradeLog or {}
    return ForeverQuantDB.trade
end

local function TLog(kind, op, price)
    local lg = ForeverQuantDB.tradeLog
    lg[#lg + 1] = string.format("%d|%s|%d|%d|%d|%d|%s", time(), kind, op.item_id, op.suffix_id or 0, price or 0, op.target_unit_price or op.target or 0, op.name or "")
end

function Trade.Enqueue()            -- 把当前名单里够格的候选排进队列
    local cfg = TradeCfg()
    local added = 0
    for _, op in ipairs(gearAll) do
        if op.ikey and op.strategy ~= "BLUE" and Verdict(op) == "buy" and not Trade.done[op.key] and not op.peerPending then      -- 同款还没查的先不排，查完那一刻直接买
            Trade.done[op.key] = true
            Trade.queue[#Trade.queue + 1] = op
            added = added + 1
        end
    end
    return added
end

-- 你标了「要」：插到队首马上去买，不管「自动买入」开没开。价格核对、金币够不够的保险照旧。
function Trade.BuyNow(op)
    TradeCfg()
    if not op.ikey then
        print("|cff55ccffFQ|r 已标「要」。这条是旧数据，没法直接买：打开拍卖行点「现在重扫」，重扫后会自动去买。")
        Trade.wantAfterScan = true
        return
    end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        print("|cff55ccffFQ|r 已标「要」。拍卖行没开，打开后会去买。")
    end
    if not ForeverQuantAction.key then ForeverQuantAction.Bind() end
    Trade.key, Trade.keyIdx = ForeverQuantAction.key, ForeverQuantAction.keyIdx
    for i = #Trade.queue, 1, -1 do if Trade.queue[i] == op then table.remove(Trade.queue, i) end end
    if op.key then Trade.done[op.key] = true end
    table.insert(Trade.queue, 1, op)
end
function Trade.Drop(op)             -- 你标了「不要」：排着队的拿掉，正在等按键的作废
    for i = #Trade.queue, 1, -1 do
        local q = Trade.queue[i]
        if q.item_id == op.item_id and (q.suffix_id or 0) == (op.suffix_id or 0) then table.remove(Trade.queue, i) end
    end
    local c = Trade.cur
    if c and c.item_id == op.item_id and (c.suffix_id or 0) == (op.suffix_id or 0) then
        Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
        if not auto then signal:Hide() end
    end
end

-- 你手动买的：按物品、名字、价格找到名单上那条
function Trade.MarkManual(id, name, price)
    for _, op in ipairs(gearAll) do
        if op.key and op.item_id == id and op.name == name and op.max_unit_price == price and not Trade.outcome[op.key] then
            Trade.outcome[op.key] = "yes"
            if frame:IsShown() then Refresh() end
            return true
        end
    end
end
-- 进入"待买"：亮信号请电脑端按键
function Trade.MakeReady(op, auctionID, price)
    Trade.cur, Trade.ready = op, { op = op, auctionID = auctionID, price = price }
    Trade.state, Trade.since = "ready", GetTime()
    print(string.format("|cff55ccffFQ|r |cff40ff40待买|r %s %s  %s → 目标 %s。按 %s 买入。", Stars(op.stars), op.name or "?",
        SilverText(price), SilverText(op.target_unit_price), Trade.key or "买入键"))
    buySignal:ShowKey(Trade.keyIdx)        -- 进了"待买"的都是该买的（自动买入挑的，或你亲手标「要」的）：直接请电脑端按键
    if frame:IsShown() then Refresh() end
end
-- 刚查完这件的全部挂单（同款印证 / 快扫），手里就有最便宜那条的编号：该买的当场进"待买"，不再排队重查一遍
function Trade.Direct(op, best)
    if Trade.state ~= "idle" or not best or not op.ikey or (op.key and Trade.done[op.key]) then return false end
    -- 绿装听「自动买入」的，蓝武听「自动管理蓝装」的，互不相干；你亲手标「要」的两边都买
    local allowed = op.marked == "want" or (op.strategy == "BLUE" and Trade.blueOn) or (op.strategy ~= "BLUE" and Trade.on)
    if not allowed or Verdict(op) ~= "buy" then return false end
    if best.buyoutAmount > op.max_unit_price or best.buyoutAmount > GetMoney() then return false end
    if not ForeverQuantAction.key then ForeverQuantAction.Bind() end
    Trade.key, Trade.keyIdx = ForeverQuantAction.key, ForeverQuantAction.keyIdx
    if not Trade.keyIdx then return false end
    if op.key then Trade.done[op.key] = true end
    for i = #Trade.queue, 1, -1 do if Trade.queue[i] == op then table.remove(Trade.queue, i) end end
    Trade.MakeReady(op, best.auctionID, best.buyoutAmount)
    return true
end

local function TradeSkip(why)
    if Trade.cur and Trade.cur.key then Trade.outcome[Trade.cur.key] = "no" end
    if Trade.cur then print(string.format("|cff55ccffFQ|r 跳过 %s：%s", Trade.cur.name or "?", why)) end
    Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
    buySignal:Hide()
end

--------------------------------------------------------------------------------
-- 同款印证：逐条去查候选的全部挂单，看"同一件装备、同一个后缀"别人挂多少。
--   一件 20s、另外三件 70s 起   -> 市场自己说它值 70s：算已验证，加一星
--   另外几件也只挂 20s 出头     -> 它就值这个价：取消验证，减一星
-- 另外，目标卖价不会高过同款里最便宜的那件（要卖得掉就得比它低）。
-- 扫描只给"最低价 + 件数"，所以这一步要每条单独查一次；结果按挂单缓存 10 分钟。
--------------------------------------------------------------------------------
local Peer = { queue = {}, cache = {}, cur = nil, since = 0 }
ForeverQuantPeer = Peer
local PEER_TTL, PEER_CLEAR, PEER_FLAT, PEER_MIN = 600, 2.0, 1.3, 2      -- 秒；贵多少倍算印证；多接近算"就值这个价"；至少几件同款
function Peer.Busy() return Peer.cur ~= nil or #Peer.queue > 0 end

local function PeerApply(op, p)
    if op.peer or p.n == 0 then return end
    if op.model_stars == nil then op.model_stars, op.model_verified = op.stars or 1, op.verified end
    local buy = op.max_unit_price
    local cap = Undercut(p.low)                                            -- 比同款最便宜的低一点
    -- 同款有两件以上：市场价很明确，目标价就贴着它定，模型估低了也跟着抬上去；只有一件同款时只往下压、不往上抬
    if cap < op.target_unit_price or p.n >= PEER_MIN then
        op.target_unit_price = cap
        op.expected_profit = math.floor(cap * (1 - AH_CUT)) - buy
    end
    local txt
    if p.n >= PEER_MIN and p.low >= buy * PEER_CLEAR and op.expected_profit > 0 then
        op.peer, op.model_verified, op.model_stars = "ok", true, math.min(3, op.model_stars + 1)
        txt = string.format("|cff40ff40同款另 %d 件挂 %s 起|r", p.n, SilverText(p.low))
    elseif p.low < buy * PEER_FLAT or op.expected_profit <= 0 then
        op.peer, op.model_verified, op.model_stars = "flat", false, math.max(1, op.model_stars - 1)
        txt = string.format("|cffff6060同款另 %d 件也只挂 %s|r", p.n, SilverText(p.low))
    else
        op.peer = "weak"                                                   -- 只有一件同款，或者贵得不够多：只列出来，不改判断
        txt = string.format("同款另 %d 件挂 %s 起", p.n, SilverText(p.low))
    end
    op.reason = txt .. " · " .. (op.reason or "")
    op.note = (op.note and (op.note .. "\n") or "") .. "同款挂价（从低到高）：" .. p.text
end

Peer.Apply = PeerApply          -- 给测试用
function Peer.Check(list)           -- 重扫之后调用：有缓存的直接套上，没有的排队去查
    local now = GetTime()
    Peer.queue = {}
    for _, op in ipairs(list) do
        if op.ikey and op.key and not op.peer then
            local c = Peer.cache[op.key]
            if c and now - c.t < PEER_TTL then PeerApply(op, c) else Peer.queue[#Peer.queue + 1] = op; op.peerPending = true end
        end
    end
    table.sort(Peer.queue, function(a, b)                                  -- 最可能要买的先查：标「要」的、星级高的、差价大的
        local wa, wb = a.marked == "want" and 1 or 0, b.marked == "want" and 1 or 0
        if wa ~= wb then return wa > wb end
        if (a.stars or 1) ~= (b.stars or 1) then return (a.stars or 1) > (b.stars or 1) end
        local ga, gb = Gap(a), Gap(b)
        if ga ~= gb then return ga > gb end
        return (a.key or "") < (b.key or "")
    end)
    for k, c in pairs(Peer.cache) do if now - c.t >= PEER_TTL then Peer.cache[k] = nil end end
    ApplyMarks(gearAll); ApplyMarks(gearBudget)
end

local function PeerDone()           -- 一轮查完：按新的星级重排保险，该撤的撤、该买的买
    ApplyMarks(gearAll); ApplyMarks(gearBudget)
    for _, op in ipairs(gearAll) do
        if op.peer == "flat" and op.marked ~= "want" then ForeverQuantTrade.Drop(op) end
    end
    if ForeverQuantTrade.on then
        local n = ForeverQuantTrade.Enqueue()
        if n > 0 then print(string.format("|cff55ccffFQ|r 同款印证后，又有 %d 条进了买入队列。", n)) end
    end
    if frame:IsShown() then Refresh() end
end

Peer.frame, Peer.tick = CreateFrame("Frame"), 0
pcall(Peer.frame.RegisterEvent, Peer.frame, "ITEM_SEARCH_RESULTS_UPDATED")
Peer.frame:SetScript("OnEvent", function()
    local op = Peer.cur
    if not op then return end
    local prices, best = {}, nil
    for i = 1, (C_AuctionHouse.GetNumItemSearchResults(op.ikey) or 0) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(op.ikey, i)
        if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            prices[#prices + 1] = info.buyoutAmount
            if info.auctionID and (not best or info.buyoutAmount < best.buyoutAmount) then best = info end
        end
    end
    table.sort(prices)
    Peer.cur, op.peerPending = nil, nil
    if prices[1] and prices[1] <= op.max_unit_price then                   -- 便宜的那件还在，剩下的才是"同款别人的挂价"
        local show = {}
        for i = 1, math.min(#prices, 8) do show[i] = SilverText(prices[i]) end
        local p = { t = GetTime(), n = #prices - 1, low = prices[2] or 0, text = table.concat(show, " / ") .. (#prices > 8 and " …" or "") }
        Peer.cache[op.key] = p
        PeerApply(op, p)
        ApplyMarks(gearAll); ApplyMarks(gearBudget)
        if op.peer == "flat" and op.marked ~= "want" then ForeverQuantTrade.Drop(op)
        elseif not ForeverQuantTrade.Direct(op, best) and ForeverQuantTrade.on then ForeverQuantTrade.Enqueue() end      -- 查完一条就买一条，不等整轮
    end
    if #Peer.queue == 0 then PeerDone() end
end)
Peer.frame:SetScript("OnUpdate", function(_, elapsed)
    Peer.tick = Peer.tick + elapsed
    if Peer.tick < 0.1 then return end
    Peer.tick = 0
    if Peer.cur then
        if GetTime() - Peer.since > 6 then Peer.cur.peerPending = nil; Peer.cur = nil; if #Peer.queue == 0 then PeerDone() end end      -- 查询超时：跳过这条
        return
    end
    if #Peer.queue == 0 then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        for _, q in ipairs(Peer.queue) do q.peerPending = nil end
        Peer.queue = {} return
    end
    if ForeverQuantScan.running or Trade.state ~= "idle" or #Trade.queue > 0 or Pricing.cur or Pool.cur or Pool.fav or (Pool.bq and Pool.bq.sent) or not ForeverQuantView.Ready() then return end
    Peer.cur, Peer.since = table.remove(Peer.queue, 1), GetTime()
    if not pcall(ForeverQuantView.Search, Peer.cur.ikey, {}, false) then Peer.cur = nil end
end)

--------------------------------------------------------------------------------
-- 高概率池快扫：不读整个拍卖行，只逐件去查"以前到过二星、三星的那些装备 + 后缀"（三星先查），
-- 加上你标过「要」的。查一件拿到的是它现在的全部挂单，所以同款印证顺手就做了。
-- 全量扫描只隔一段时间做一次，用来发现新面孔和刷新参照价。
--------------------------------------------------------------------------------
local POOL_MIN_STARS, POOL_GAP, POOL_MIN_PROFIT = 2, 2.0, 1500        -- 进池的最低历史星级；目标价至少是现价的几倍；最低净赚（铜）
Pool.BLUE_ONE, Pool.BLUE_ALL = 100000, 200000                        -- 蓝武自动买入：单把最多 10 金；手里蓝武占用的本钱合计最多 20 金
-- 现在压在蓝武上的本钱：买了还没卖掉的（待上架、在售、去向不明）按买入成本加起来。几秒内重复问就用上次的数
function Pool.BlueHeld()
    if Pool.blueHeldAt and GetTime() - Pool.blueHeldAt < 5 then return Pool.blueHeld end
    local ids, sum = {}, 0
    for _, r in ipairs(data.blue and data.blue.items or {}) do ids[r.item_id] = true end
    local Lg = ForeverQuantLedger
    if Lg and Lg.Build then
        Lg.Build()
        for _, r in ipairs(Lg.rows or {}) do
            if ids[r.item_id or 0] and (r.status == "held" or r.status == "open" or r.status == "unknown") then sum = sum + (r.cost or 0) end
        end
    end
    Pool.blueHeld, Pool.blueHeldAt = sum, GetTime()
    return sum
end
local BLUE_FRAC = 0.6                                                -- 蓝武：现价不超过"其它挂单中位价"的几成才提醒
local POOL_MIN_TARGET, POOL_MAX = 3000, 100                          -- 能卖的价低于这个数的不进池（赚头太薄）；池子最多几件（不超过偏好位，一次批量查完）
function Pool.Busy() return Pool.cur ~= nil or Pool.fav ~= nil or Pool.bq ~= nil or #Pool.queue > 0 end
-- 卖出过几次（按名字）：每分钟最多重算一次
function Pool.SoldCount()
    if Pool.soldAt and GetTime() - Pool.soldAt < 60 then return Pool.sold end
    local c, Lg = {}, ForeverQuantLedger
    if Lg and Lg.Build then
        Lg.Build()
        for _, r in ipairs(Lg.rows or {}) do
            if r.status == "sold" and r.name then c[r.name] = (c[r.name] or 0) + 1 end
        end
    end
    Pool.sold, Pool.soldAt = c, GetTime()
    return c
end
-- 返回这一轮要查的名单。池子有上限，所以排序就是去留：
--   你标「要」的最先；其余按 差价绝对值（目标价 - 买价）× 卖出加成 排，卖过 1/2/3 次以上分别算 2/3/4 倍。
--   这样卖过的优先，但没卖过的大差价货不会被卖过一次的小货挤出去。
function Pool.Build()
    local sold = Pool.SoldCount()
    local list, marks = {}, ForeverQuantDB.marks or {}
    for _, kn in pairs(ForeverQuantDB.known or {}) do
        if kn.id and kn.name then
            local mark = MarkOf(marks[kn.id .. ":" .. (kn.suffix or 0)])
            local best = (mark == "want") and 4 or (kn.best or kn.stars or 1)
            if mark ~= "no" and best >= POOL_MIN_STARS and (kn.suffix or 0) ~= 0
                and (mark == "want" or (kn.target or 0) >= POOL_MIN_TARGET) then
                local ilvl = kn.ilvl or select(4, ItemInfo(kn.id))
                if ilvl then
                    list[#list + 1] = { kn = kn, best = best, ilvl = ilvl, want = (mark == "want") and 1 or 0,
                                        sold = sold[kn.name] or 0, margin = (kn.target or 0) - (kn.buy or 0) }
                    list[#list].score = list[#list].margin * (1 + math.min(list[#list].sold, 3))
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.want ~= b.want then return a.want > b.want end
        if a.score ~= b.score then return a.score > b.score end
        return a.kn.id < b.kn.id
    end)
    local cap = math.min(POOL_MAX, ForeverQuantDB.favCap or POOL_MAX)      -- 排在后面的直接不查，不再逐件轮流
    for i = #list, cap + 1, -1 do list[i] = nil end
    return list
end
function Pool.Size() return #Pool.Build() end
-- 批量查：把池里的物品设成拍卖行的"偏好"，一次查询拿回所有偏好物品的最低价；只有够便宜的才逐件细查（看同款挂价）。
-- 只管自己设进去的偏好（记在存盘的 favSet 里），你手动收藏的不动；池子里放不进偏好的（满了）照旧逐件查。
local function FavKey(id, suffix) return id .. ":" .. (suffix or 0) end
local function PoolCheap(kn, price)                         -- 这个价值不值得细查 / 做成候选
    if kn.blue then return price <= kn.line end             -- 蓝色武器：低于买入线（参照卖价的六成）
    return price * POOL_GAP <= kn.target and math.floor(kn.target * (1 - AH_CUT)) - price >= POOL_MIN_PROFIT
end
local function FavUsable()
    local A = C_AuctionHouse
    if Pool.favBroken or not (A.SearchForFavorites and A.SetFavoriteItem and A.MakeItemKey) then return false end
    if A.FavoritesAreAvailable and not A.FavoritesAreAvailable() then return false end
    return true
end
local function FavSync(list)        -- 让"我设的偏好"和池子一致；返回没能放进偏好的条目
    ForeverQuantDB.favSet = ForeverQuantDB.favSet or {}
    local set, want, rest = ForeverQuantDB.favSet, {}, {}
    local cap = ForeverQuantDB.favCap                      -- 偏好位能放几件：第一次碰到"满了"时记下来
    for i, e in ipairs(list) do
        if not cap or i <= cap then want[FavKey(e.kn.id, e.kn.suffix)] = e end      -- 只有排在前 cap 位的该占偏好位
    end
    for k, v in pairs(set) do                              -- 出了池子的：取消偏好
        if not want[k] then
            local ok, key = pcall(C_AuctionHouse.MakeItemKey, v.id, v.ilvl, v.suffix)
            if ok and key then pcall(C_AuctionHouse.SetFavoriteItem, key, false) end
            set[k] = nil
        end
    end
    for i, e in ipairs(list) do
        local k = FavKey(e.kn.id, e.kn.suffix)
        if not set[k] then
            local full = (cap and i > cap) or (C_AuctionHouse.HasMaxFavorites and C_AuctionHouse.HasMaxFavorites())
            local ok, key = pcall(C_AuctionHouse.MakeItemKey, e.kn.id, e.ilvl, e.kn.suffix or 0)
            if not full and ok and key and pcall(C_AuctionHouse.SetFavoriteItem, key, true) then
                set[k] = { id = e.kn.id, ilvl = e.ilvl, suffix = e.kn.suffix or 0 }
            else
                if not cap and full then                    -- 第一次满：记下我们能占几个位，下一轮起按优先级腾位
                    local n = 0
                    for _ in pairs(set) do n = n + 1 end
                    ForeverQuantDB.favCap = n
                    cap = n
                end
                rest[#rest + 1] = e
            end
        end
    end
    return rest
end
function Pool.Start()
    if Pool.Busy() then return false end
    local list = Pool.Build()
    Pool.queue, Pool.hits, Pool.timeouts, Pool.startedAt, Pool.n, Pool.detail = {}, 0, 0, GetTime(), #list, 0
    if Pool.n == 0 then return Trade.blueOn and Pool.StartBlue(true) or false end      -- 绿装池还是空的：蓝武开关开着就至少把蓝武扫一遍
    Pool.wantBlue = Trade.blueOn and true or nil            -- 蓝武归「自动管理蓝装」管，它关着就不扫
    if FavUsable() then
        local rest = FavSync(list)
        Pool.list, Pool.rest, Pool.how = list, rest, "偏好批量"
        Pool.fav = { since = GetTime(), sent = false }     -- 查询在 OnUpdate 里发（要等限流放行）
    else
        Pool.queue, Pool.how, Pool.detail = list, "逐件", #list
    end
    return true
end
-- 偏好批量查的结果回来了：挑出够便宜的去细查
function Pool.FavResults(results)
    local low = {}
    for _, r in ipairs(results or {}) do
        local k = r.itemKey
        if k and (r.minPrice or 0) > 0 then
            local key = FavKey(k.itemID, k.itemSuffix or 0)
            if not low[key] or r.minPrice < low[key] then low[key] = r.minPrice end
            Pool.keys = Pool.keys or {}
            Pool.keys[key] = k                              -- 拍卖行自己给的物品键：细查时直接用，比自己拼的可靠
        end
    end
    local seen = 0
    for _ in pairs(low) do seen = seen + 1 end
    Pool.favSeen = seen                                     -- 批量查回来了几件有货的；一直是 0 说明这条路不通
    Pool.favEmpty = (seen == 0) and ((Pool.favEmpty or 0) + 1) or 0
    if Pool.favEmpty >= 3 then
        Pool.favBroken = true
        print("|cff55ccffFQ|r 偏好批量查连着三轮什么都没返回，快扫改回逐件查。")
    end
    local q, inFav, over = {}, ForeverQuantDB.favSet or {}, {}
    for _, e in ipairs(Pool.list or {}) do
        local kn = e.kn
        local key = FavKey(kn.id, kn.suffix)
        local price = low[key]
        if not inFav[key] then
            over[#over + 1] = e                             -- 没进偏好的：下面轮流查
        elseif Pool.favBroken then
            q[#q + 1] = e                                   -- 刚判定批量不可靠：这一轮就全部逐件查
        elseif price and PoolCheap(kn, price) then
            q[#q + 1] = e                                   -- 够便宜：细查同款
        end
    end
    local TAKE = 6                                          -- 偏好位以外的，每轮轮流逐件查 6 件
    Pool.rot = Pool.rot or 0
    for i = 1, math.min(TAKE, #over) do q[#q + 1] = over[(Pool.rot + i - 1) % #over + 1] end
    if #over > 0 then Pool.rot = (Pool.rot + TAKE) % #over end
    Pool.over = #over
    Pool.fav, Pool.list, Pool.rest = nil, nil, nil
    Pool.queue, Pool.detail = q, #q
    return q
end
-- 查到了某件池内装备现在的挂单（已按价格从低到高排好）：够便宜就做成一条候选
function Pool.Judge(e, prices)
    local kn, low = e.kn, prices[1]
    if not low then return nil end
    if kn.blue then
        -- 蓝武：光比历史价低不算便宜，要比"现在别人挂的价"低得多才算。别的挂单的中位价就是此刻的市价；
        -- 二十把都挂 1.3 金的时候，1.28 金那把不是漏，是行情（历史上卖过 2 金也没用）。
        local n, wall = #prices - 1, kn.ref0 or kn.target
        kn.ref0 = wall
        if n >= 1 then wall = math.min(wall, prices[1 + math.ceil(n / 2)]) end
        kn.target, kn.line, kn.wall, kn.others = wall, math.floor(wall * BLUE_FRAC), wall, n
        if kn.ctl then kn.target, kn.line = kn.ctl.ask, kn.ctl.bid end      -- 控价的货不看别人挂多少：低于收货线就提醒
    end
    local profit = math.floor(kn.target * (1 - AH_CUT)) - low
    if not PoolCheap(kn, low) then return nil end
    local key = kn.id .. ":" .. (kn.suffix or 0) .. ":" .. low
    for _, op in ipairs(gearAll) do if op.key == key then return nil end end          -- 名单里已经有这条挂单了
    local op = { item_id = kn.id, suffix_id = kn.suffix or 0, name = kn.name, strategy = kn.blue and "BLUE" or "GEAR", ikey = e.ikey, key = key,
        stars = kn.best or kn.stars or 1, verified = kn.verified and true or false, isNew = true,
        max_unit_price = low, target_unit_price = kn.target, max_quantity = 1, expected_profit = profit, score = 0,
        reason = string.format("高概率池 · 以前到过 %d 星", kn.best or kn.stars or 1),
        note = "这条是快扫查到的：目标价沿用它上次出现在名单里时的估价，没有重新按全市场算。" }
    local show = {}
    for i = 1, math.min(#prices, 8) do show[i] = SilverText(prices[i]) end
    if not kn.blue then
        Peer.Apply(op, { t = GetTime(), n = #prices - 1, low = prices[2] or 0, text = table.concat(show, " / ") })
    else
        -- 蓝武的价值看一周的价格记录，不看此刻的同款：两把都挂得便宜是两次机会，不是"它就值这个价"；挂价也不跟着同款往上抬
        op.peer = "weak"
        op.blueAuto = (kn.others or 0) >= 2 and not kn.ctl
        op.ctlBuy = kn.ctl and true or nil                           -- 控价的货：收货线以下的买掉（有件数上限）
        op.reason = string.format("|cff0070dd蓝色武器（%s）|r 另 %d 把的中位价 %s，这把只有它的 %d%%%s", kn.blue, kn.others or 0, SilverText(kn.target), math.floor(low * 100 / kn.target + 0.5),
            (not op.blueAuto and " · 可比的太少，只提醒") or (low > Pool.BLUE_ONE and string.format(" · 超过单把 %s 的上限，只提醒", SilverText(Pool.BLUE_ONE)))
            or (Pool.BlueHeld() + low > Pool.BLUE_ALL and string.format(" · 蓝武已压 %s，再买就超 %s，只提醒", SilverText(Pool.BlueHeld()), SilverText(Pool.BLUE_ALL))) or "")
        op.note = "蓝色武器的超低价单：参照卖价是此刻其它挂单的中位价（不高于行情站一周的价）；没有其它挂单时才用行情站的价。另有两把以上同款可比时，「自动买入」开着就直接买；可比的不足两把时只提醒，要买点「要」。"
            .. "\n现在的挂价（从低到高）：" .. table.concat(show, " / ")
        if kn.ctl then
            local cheap = 0
            for _, pz in ipairs(prices) do if pz <= kn.ctl.bid then cheap = cheap + 1 end end
            op.reason = string.format("|cffff8000控价|r 有 %d 把挂在收货线 %s 以下（最低 %s）· 「自动买入」开着就收，手里加挂着满 %d 把为止", cheap, SilverText(kn.ctl.bid), SilverText(low), kn.ctl.maxUnits or 12)
            if kn.ctl.saidLow ~= low or time() - (kn.ctl.saidAt or 0) > 600 then      -- 同一个价十分钟内只说一次
                kn.ctl.saidLow, kn.ctl.saidAt = low, time()
                print(string.format("|cff55ccffFQ|r |cffff8000控价提醒|r %s：有 %d 把挂在 %s 以下，最低 %s。", kn.name, cheap, SilverText(kn.ctl.bid), SilverText(low)))
            end
        else
        print(string.format("|cff55ccffFQ|r |cff0070dd蓝色武器低价单|r %s：现在 %s，其它挂单中位 %s。%s", kn.name, SilverText(low), SilverText(kn.target),
            op.blueAuto and "「自动买入」开着会直接买。" or "可比的挂单太少，不自动买；要买在「绿装捡漏」里点「要」。"))
        end
    end
    return op
end
-- 蓝色武器单独扫一遍：每轮自动扫货（快扫或全量）之后做。一次浏览查询把 40 级以下的蓝色武器全拿回来（每把的最低价），
-- 和要盯的那二十来把对一下，够便宜的再逐件细查。不占偏好位，也不用自己拼物品键。
function Pool.BlueEntries()
    local out, marks = {}, ForeverQuantDB.marks or {}
    for _, r in ipairs(data.blue and data.blue.items or {}) do
        local ctl = Trade.Control(r.name)
        if ctl then                                         -- 控价的货：收货线和挂价都用你定的
            out[r.item_id] = { kn = { id = r.item_id, name = r.name, suffix = 0, target = ctl.ask, buy = ctl.bid, best = 2, stars = 2,
                                      blue = "控价", line = ctl.bid, ctl = ctl }, best = 2, ilvl = r.ilvl or 0, blue = 1 }
        elseif r.snipe and (r.line or 0) > 0 and marks[r.item_id .. ":0"] ~= "no" then
            out[r.item_id] = { kn = { id = r.item_id, name = r.name, suffix = 0, target = r.ref, buy = r.line, best = 2, stars = 2,
                                      blue = r.snipe, line = r.line }, best = 2, ilvl = r.ilvl or 0, blue = 1 }
        end
    end
    return out
end
function Pool.BlueResults(results)
    local ents, q, seen = Pool.BlueEntries(), {}, 0
    -- 这一遍把 40 级以下的蓝色武器全拿回来了：每把的最低价和在售件数都记下，「蓝色武器」页的现价用它（没出现的 = 现在没货）
    local livePx = {}
    for _, r in ipairs(results or {}) do
        local k = r.itemKey
        if k and k.itemID and (r.minPrice or 0) > 0 then
            local e = livePx[k.itemID]
            if not e then livePx[k.itemID] = { price = r.minPrice, qty = r.totalQuantity or 1 }
            else e.price, e.qty = math.min(e.price, r.minPrice), e.qty + (r.totalQuantity or 1) end
        end
    end
    Pool.blueLive, Pool.blueLiveAt = livePx, time()
    if Pool.pull then
        Pool.pull = nil
        local n = 0
        for _ in pairs(livePx) do n = n + 1 end
        print(string.format("|cff55ccffFQ|r 蓝色武器现价已刷新：拍卖行现在有 %d 种在卖。", n))
    end
    if Pool.ctlScan then                                   -- 只为控价的货扫的这一遍：别的蓝武不看
        for id, e in pairs(ents) do if not e.kn.ctl then ents[id] = nil end end
        Pool.ctlScan = nil
    end
    Pool.keys = Pool.keys or {}
    for _, r in ipairs(results or {}) do
        local k = r.itemKey
        local e = k and (k.itemSuffix or 0) == 0 and ents[k.itemID]
        if e and (r.minPrice or 0) > 0 then
            seen = seen + 1
            if not e.low or r.minPrice < e.low then e.low, e.key = r.minPrice, k end
        end
    end
    for id, e in pairs(ents) do
        if e.low and e.low <= e.kn.line then               -- 比行情站的买入线便宜：细查它现在的全部挂单再定
            Pool.keys[id .. ":0"] = e.key
            e.ilvl = e.key.itemLevel or e.ilvl
            q[#q + 1] = e
        end
    end
    Pool.blueSeen, Pool.blueAt = seen, GetTime()
    return q
end
function Pool.StartBlue(alone)           -- alone = 不是接在快扫后面（全量扫完之后单独来一遍）
    if Pool.bq or not next(Pool.BlueEntries()) then return false end
    if alone then
        if Pool.Busy() then return false end
        Pool.queue, Pool.hits, Pool.timeouts, Pool.startedAt, Pool.n, Pool.detail, Pool.how = {}, 0, 0, GetTime(), 0, 0, "蓝武"
    end
    Pool.bq = { since = GetTime(), sent = false }
    return true
end
local function PoolDone()
    if Pool.hits > 0 then
        ApplyMarks(gearAll); ApplyMarks(gearBudget)
        for _, op in ipairs(gearAll) do
            if op.marked == "want" and Verdict(op) == "buy" and op.ikey and not (op.key and Trade.done[op.key]) then Trade.BuyNow(op) end
        end
        if Trade.on then Trade.Enqueue() end
        print(string.format("|cff55ccffFQ|r |cff40ff40快扫发现 %d 条|r（查了池里 %d 件）。", Pool.hits, Pool.n))
        if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
    end
    Pool.doneAt = GetTime()
    Pool.took = Pool.doneAt - (Pool.startedAt or Pool.doneAt)
    Pool.wantBlue = nil
    if frame:IsShown() then Refresh() end
end
function Pool.Finish()                   -- 这一段查完了：绿装那部分完了接着扫蓝武，蓝武也完了才算一轮结束
    if Pool.wantBlue then
        Pool.wantBlue = nil
        if Pool.StartBlue(false) then return end
    end
    PoolDone()
end
Pool.frame, Pool.tick = CreateFrame("Frame"), 0
pcall(Pool.frame.RegisterEvent, Pool.frame, "ITEM_SEARCH_RESULTS_UPDATED")
pcall(Pool.frame.RegisterEvent, Pool.frame, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
Pool.frame:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if Pool.bq and Pool.bq.sent and not ForeverQuantScan.running then          -- 蓝武那一遍的结果
            if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
                pcall(C_AuctionHouse.RequestMoreBrowseResults)
                return
            end
            local q = Pool.BlueResults(C_AuctionHouse.GetBrowseResults())
            Pool.bq = nil
            Pool.n = (Pool.n or 0) + (Pool.blueSeen or 0)
            Pool.queue, Pool.detail = q, (Pool.detail or 0) + #q
            if #q == 0 then PoolDone() end
            return
        end
        if not (Pool.fav and Pool.fav.sent) or ForeverQuantScan.running then return end
        if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
            pcall(C_AuctionHouse.RequestMoreBrowseResults)          -- 一页放不下：接着要，等下一次事件
            return
        end
        Pool.favOk = true
        if #Pool.FavResults(C_AuctionHouse.GetBrowseResults()) == 0 then Pool.Finish() end
        return
    end
    local e = Pool.cur
    if not e then return end
    local prices, best = {}, nil
    for i = 1, (C_AuctionHouse.GetNumItemSearchResults(e.ikey) or 0) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(e.ikey, i)
        if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            prices[#prices + 1] = info.buyoutAmount
            if info.auctionID and (not best or info.buyoutAmount < best.buyoutAmount) then best = info end
        end
    end
    table.sort(prices)
    Pool.cur = nil
    local op = Pool.Judge(e, prices)
    if op then
        Pool.hits = Pool.hits + 1
        table.insert(gearAll, 1, op)
        if gearBudget ~= gearAll then table.insert(gearBudget, 1, op) end
        ApplyMarks(gearAll); ApplyMarks(gearBudget)
        if Trade.Direct(op, best) then                              -- 挂单编号已经在手里：当场进待买，不重查
        elseif (op.marked == "want" or (op.strategy == "BLUE" and Trade.blueOn)) and Verdict(op) == "buy" then Trade.BuyNow(op)
        elseif Trade.on then Trade.Enqueue() end
    end
    if #Pool.queue == 0 then Pool.Finish() end
end)
Pool.frame:SetScript("OnUpdate", function(_, elapsed)
    Pool.tick = Pool.tick + elapsed
    if Pool.tick < 0.2 then return end
    Pool.tick = 0
    if Pool.bq then                                          -- 蓝武：一次浏览查询
        local b = Pool.bq
        if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Pool.bq = nil return end
        if not b.sent then
            if ForeverQuantScan.running or Trade.state ~= "idle" or #Trade.queue > 0 or Peer.Busy() or Pricing.cur
                or not ForeverQuantView.Ready() then
                if GetTime() - b.since > 60 then Pool.bq = nil; PoolDone() end      -- 一直轮不上：这一轮不扫了
                return
            end
            local filters = {}
            if Enum and Enum.AuctionHouseFilter and Enum.AuctionHouseFilter.RareQuality then filters[1] = Enum.AuctionHouseFilter.RareQuality end
            b.sent, b.since = true, GetTime()
            if not pcall(C_AuctionHouse.SendBrowseQuery, { searchString = "", sorts = {}, filters = filters,
                                                           itemClassFilters = { { classID = 2 } }, maxLevel = 39 }) then b.since = 0 end
        elseif GetTime() - b.since > 8 then                 -- 没回应：算了，下一轮再来
            Pool.bq = nil
            PoolDone()
        end
        return
    end
    if Pool.fav then                                         -- 偏好批量查
        local f = Pool.fav
        if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Pool.fav, Pool.list = nil, nil return end
        if not f.sent then
            if ForeverQuantScan.running or Trade.state ~= "idle" or #Trade.queue > 0 or Peer.Busy() or Pricing.cur
                or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
            f.sent, f.since = true, GetTime()
            if not pcall(C_AuctionHouse.SearchForFavorites, {}) then f.since = 0 end
        elseif GetTime() - f.since > 6 then                 -- 没回应：这一轮退回逐件查；连着两次都这样就整场不再用偏好
            Pool.favFails = (Pool.favFails or 0) + 1
            if Pool.favFails >= 2 and not Pool.favOk then
                Pool.favBroken = true
                print("|cff55ccffFQ|r 偏好批量查没有回应，快扫改回逐件查。")
            end
            Pool.queue, Pool.how, Pool.detail = Pool.list or {}, "逐件", #(Pool.list or {})
            Pool.fav, Pool.list = nil, nil
        end
        return
    end
    if Pool.cur then
        if GetTime() - Pool.since > 3 then                  -- 没回应：记一笔，跳过
            Pool.cur, Pool.timeouts = nil, (Pool.timeouts or 0) + 1
            if #Pool.queue == 0 then Pool.Finish() end
        end
        return
    end
    if #Pool.queue == 0 then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Pool.queue = {} return end
    if ForeverQuantScan.running or Trade.state ~= "idle" or #Trade.queue > 0 or Peer.Busy() or Pricing.cur
        or not ForeverQuantView.Ready() then return end           -- 买入、印证、定价都比快扫优先
    local e = table.remove(Pool.queue, 1)
    local ok, key = true, Pool.keys and Pool.keys[e.kn.id .. ":" .. (e.kn.suffix or 0)]
    if not key then ok, key = pcall(C_AuctionHouse.MakeItemKey, e.kn.id, e.ilvl, e.kn.suffix or 0) end
    if not ok or not key then return end
    e.ikey = key
    Pool.cur, Pool.since = e, GetTime()
    if not pcall(ForeverQuantView.Search, key, {}, false) then Pool.cur = nil end
end)

local tradeFrame = CreateFrame("Frame")
for _, ev in ipairs({ "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_CLOSED" }) do pcall(tradeFrame.RegisterEvent, tradeFrame, ev) end
tradeFrame:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_CLOSED" then
        if Trade.state ~= "idle" then Trade.cur, Trade.ready, Trade.state = nil, nil, "idle" end
        buySignal:Hide()
        return
    end
    if Trade.state ~= "searching" or not Trade.cur then return end
    local op = Trade.cur
    local n = C_AuctionHouse.GetNumItemSearchResults(op.ikey) or 0
    local best
    for i = 1, n do
        local info = C_AuctionHouse.GetItemSearchResultInfo(op.ikey, i)
        if info and info.auctionID and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            if not best or info.buyoutAmount < best.buyoutAmount then best = info end
        end
    end
    if op.blueRow then                                     -- 从「蓝色武器」页点的：顺手把这一行的现价换成刚查到的
        local nxt, cnt = nil, 0
        for i = 1, n do
            local info = C_AuctionHouse.GetItemSearchResultInfo(op.ikey, i)
            if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
                cnt = cnt + 1
                if best and info.auctionID ~= best.auctionID and (not nxt or info.buyoutAmount < nxt) then nxt = info.buyoutAmount end
            end
        end
        op.nextPrice, op.count = nxt, cnt
        local P = ForeverQuantPool
        if P then
            P.blueLive = P.blueLive or {}
            P.blueLive[op.item_id] = best and { price = best.buyoutAmount, qty = cnt } or nil
        end
        -- 计划挂价：贴着下一把的价挂；下一把贵得离谱时不超过这把平时的高位；没有下一把就按平时最低价
        local r = op.blueRow
        local ref = math.min(r.typ or 0, r.recent or r.typ or 0)
        if nxt then op.target_unit_price = math.min(Undercut(nxt), math.max(ref, r.high or ref)) else op.target_unit_price = ref end
    end
    if not best then return TradeSkip("已经没有了") end
    if best.buyoutAmount > op.max_unit_price then
        return TradeSkip(string.format("现在最低 %s，高于建议买价 %s", SilverText(best.buyoutAmount), SilverText(op.max_unit_price)))
    end
    if best.buyoutAmount > GetMoney() then return TradeSkip("金币不够") end
    Trade.MakeReady(op, best.auctionID, best.buyoutAmount)
end)

local tradeTick = 0
tradeFrame:SetScript("OnUpdate", function(_, elapsed)
    tradeTick = tradeTick + elapsed
    if tradeTick < 0.1 then return end
    tradeTick = 0
    if not Trade.on and #Trade.queue == 0 and Trade.state == "idle" then return end      -- 关着时只处理你亲手标「要」的那几条
    local now = GetTime()
    if Trade.state == "idle" then
        if #Trade.queue > 0 and AuctionHouseFrame and AuctionHouseFrame:IsShown() and not ForeverQuantScan.running
            and not Pricing.cur and not Pool.cur and not (Pool.fav and Pool.fav.sent) and not (Pool.bq and Pool.bq.sent) and not Peer.cur      -- 排进来的都已经查过同款了：插在剩下的印证前面买
            and ForeverQuantView.Ready() then
            Trade.cur = table.remove(Trade.queue, 1)
            Trade.state, Trade.since = "searching", now
            local ok = pcall(ForeverQuantView.Search, Trade.cur.ikey, {}, false)
            if not ok then TradeSkip("查询失败") end
        end
    elseif Trade.state == "searching" then
        if now - Trade.since > 8 then TradeSkip("查询超时") end
    elseif Trade.state == "ready" then
        if now - Trade.since > 60 then TradeSkip("一分钟没按买入键，放弃这一条") end
    elseif Trade.state == "buying" then
        local r = Trade.ready
        if GetMoney() <= Trade.moneyBefore - r.price then          -- 钱真的扣了才算买到
            Trade.spent = Trade.spent + r.price
            local h = { item_id = r.op.item_id, suffix_id = r.op.suffix_id or 0, name = r.op.name, cost = r.price,
                        target = r.op.target_unit_price, t = time() }
            if r.op.manual then
                h.manual = true                                                -- 你在「蓝色武器」页亲手买的：和自动管理的那一套分开，不归控价排班、不归蓝武开关
            else
                if Trade.Control(h.name) then h.ctl, h.hold = true, true end   -- 控价的货：什么时候挂、挂多少按排班来
                if r.op.strategy == "BLUE" then h.blue = true end              -- 蓝武：上架归「自动管理蓝装」管
            end
            table.insert(ForeverQuantDB.holdings, h)
            TLog("BUY", r.op, r.price)
            print(string.format("|cff55ccffFQ|r |cff40ff40买到|r %s，花了 %s；这次开着以来共花 %s。东西在邮箱里。",
                r.op.name or "?", SilverText(r.price), SilverText(Trade.spent)))
            if r.op.key then Trade.outcome[r.op.key] = "yes" end
            if r.op.blueRow then                                     -- 这一行的现价换成下一把
                Pool.blueLive = Pool.blueLive or {}
                Pool.blueLive[r.op.item_id] = r.op.nextPrice and { price = r.op.nextPrice, qty = math.max(1, (r.op.count or 2) - 1) } or nil
                print(string.format("|cff55ccffFQ|r %s：计划挂 %s%s。", r.op.name or "?", SilverText(r.op.target_unit_price),
                    r.op.nextPrice and ("；下一把现在挂 " .. SilverText(r.op.nextPrice)) or "；拍卖行里已经没有别的了"))
            end
            Pool.blueHeldAt = nil                                    -- 刚买了东西：蓝武占用的本钱要重算
            Trade.stockAt = nil                                      -- 手里的件数也要重算
            Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
            if frame:IsShown() then Refresh() end
        elseif now - Trade.since > 6 then
            print("|cff55ccffFQ|r 没买到 " .. (r.op.name or "?") .. "（可能被别人抢先了）。")
            if r.op.key then Trade.outcome[r.op.key] = "no" end
            Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
            if frame:IsShown() then Refresh() end
        end
    end
end)

-- 买入：必须由真实按键/点击触发（由下面的"动作键"调用）
local function DoBuy()
    if Trade.state ~= "ready" or not Trade.ready then return end
    local r = Trade.ready
    buySignal:Hide()
    Trade.moneyBefore, Trade.state, Trade.since = GetMoney(), "buying", GetTime()
    local ok, err = pcall(C_AuctionHouse.PlaceBid, r.auctionID, r.price)
    if not ok then
        print("|cff55ccffFQ|r 买入出错：" .. tostring(err))
        Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
    end
end

-- 上架按钮：在背包里找一件持仓，按当时的目标价挂出去
local function FindInBags(itemId, suffixId, name)
    local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    local getSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    for bag = 0, 4 do
        for slot = 1, (getSlots(bag) or 0) do
            local link = getLink(bag, slot)
            if link then
                local id, suffix = string.match(link, "item:(%d+):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d*)")
                if tonumber(id) == itemId then
                    -- 背包链接里的后缀编号和拍卖行给的不一定是同一套，所以名字对得上也算（名字里带后缀，足够区分）
                    if (tonumber(suffix) or 0) == (suffixId or 0) or (name and string.match(link, "%[(.-)%]") == name) then return bag, slot end
                    if ForeverQuantDB then ForeverQuantDB.debugLink = string.gsub(link, "|", "!") end      -- 排查用：没对上的那条链接
                end
            end
        end
    end
end

-- 认领：你自己手动买的货不在持仓里。把背包里"和绿装捡漏名单对得上"的装备收进持仓，按名单上的目标价上架。
-- 只在你输入 /fq sell 时做，不会自己去翻背包。
-- 名单上出现过的货（不管几星、不管是不是插件买的）：返回当时的目标卖价等
function Trade.Known(itemId, name)
    return itemId and name and ForeverQuantDB.known and ForeverQuantDB.known[itemId .. ":" .. name]
end
-- 控价的货：插件按定好的规矩替你管——
--   收：别人挂到收货线（bid）以下的，买掉（「自动买入」开着时；手里和挂着的合计不超过 maxUnits 把）
--   挂：最多同时挂 maxListed 把：一把挂在前排价（front），其余挂计划价（ask）；多出来的留在包里，等挂着的卖掉再补
--   不跟别人压价，不打折，不参与"贴着同款最低价"那套定价
-- ForeverQuantDB.control = { [名字] = { ask, front, bid, maxListed, maxUnits } }
function Trade.Control(name)
    if not ForeverQuantDB then return nil end
    if ForeverQuantDB.control == nil then ForeverQuantDB.control = { ["仇杀"] = { ask = 90000, bid = 60000, since = time() } } end
    local c = name and ForeverQuantDB.control[name] or nil
    if c then
        if c.ask == 80000 and not c.front then c.ask = 90000 end           -- 第一版写的是 8 金，后来你实际挂的是 7 / 9
        c.front, c.maxListed, c.maxUnits = c.front or 70000, c.maxListed or 3, c.maxUnits or 12
    end
    return c
end
function Trade.Postable(h) return (h.fail or 0) < 2 and not h.hold end
-- 「蓝色武器」页每行的「买这把」：买下这把武器现在最便宜的那一件。是你亲手点的，所以不看开关、不看各种上限；
-- 只保留一条保险：实时最低价不能比这一行显示的现价贵。
function Trade.BuyBlueRow(r)
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then print("|cff55ccffFQ|r 要先打开拍卖行。") return false end
    if not r or (r.now or 0) <= 0 then return false end
    for _, q in ipairs(Trade.queue) do if q.blueRow == r then return false end end
    if Trade.cur and Trade.cur.blueRow == r then return false end
    local P = ForeverQuantPool
    local key = P and P.keys and P.keys[r.item_id .. ":0"]
    if not key then
        local lvl = (ForeverQuantDB.keyLvl and ForeverQuantDB.keyLvl[r.item_id]) or r.ilvl or 0
        local ok
        ok, key = pcall(C_AuctionHouse.MakeItemKey, r.item_id, lvl, 0)
        if not ok then key = nil end
    end
    if not key then print("|cff55ccffFQ|r 拼不出这把武器的查询键，先点一次「刷新现价」。") return false end
    local ref = math.min(r.typ or 0, r.recent or r.typ or 0)
    local op = { item_id = r.item_id, suffix_id = 0, name = r.name, strategy = "BLUE", ikey = key, key = r.item_id .. ":0:row:" .. tostring(GetTime()),
        stars = 2, verified = true, marked = "want", wantGap = 0, max_unit_price = r.now, target_unit_price = ref, blueRow = r,
        manual = true, reason = "蓝色武器页手动买" }
    Trade.BuyNow(op)
    return true
end
-- 每种货（按名字）手里有几件（待上架 + 挂着的）、最近一天真卖出几件。翻账本比较费，五秒内重复问就用上次的
Trade.STOCK_MAX, Trade.STOCK_FAST = 2, 2
function Trade.Stock()
    if Trade.stock and GetTime() - (Trade.stockAt or 0) < 5 then return Trade.stock end
    local st, Lg = {}, ForeverQuantLedger
    local function at(name) st[name] = st[name] or { have = 0, sold = 0 } return st[name] end
    for _, h in ipairs((ForeverQuantDB and ForeverQuantDB.holdings) or {}) do if h.name then at(h.name).have = at(h.name).have + 1 end end
    if Lg and Lg.Build then
        Lg.Build()
        local dayAgo = time() - 86400
        for _, r in ipairs(Lg.rows or {}) do
            if r.name and r.price then
                if r.status == "open" then at(r.name).have = at(r.name).have + (r.qty or 1)
                elseif r.status == "sold" and (r.sold or 0) >= dayAgo and (r.took or 0) < (r.dur or 8) * 3600 - 300 then
                    at(r.name).sold = at(r.name).sold + 1
                end
            end
        end
    end
    Trade.stock, Trade.stockAt = st, GetTime()
    return st
end
function Trade.Overstocked(name)
    local e = name and Trade.Stock()[name]
    return e ~= nil and e.have >= Trade.STOCK_MAX and e.sold < Trade.STOCK_FAST
end
-- 改价重挂：把我们挂着的某件货里最贵的 n 件撤下来，取回后按你指定的价重新挂。
-- 撤单要真实按键，所以排个队，一次按键撤一件（电脑端程序会接着按）。撤单会损失那一件的押金。
function Trade.Reprice(itemId, n, price)
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then print("|cff55ccffFQ|r 改价重挂要先打开拍卖行。") return 0 end
    local mine = {}
    for i = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info and (info.status or 0) == 0 and info.itemKey and info.itemKey.itemID == itemId and (info.buyoutAmount or 0) > price then
            local name = info.itemLink and string.match(info.itemLink, "%[(.-)%]")
            mine[#mine + 1] = { auctionID = info.auctionID, name = name, was = info.buyoutAmount, price = price, id = itemId }
        end
    end
    table.sort(mine, function(a, b) return a.was > b.was end)
    Trade.cancelQ = Trade.cancelQ or {}
    local took = 0
    for i = 1, math.min(n, #mine) do Trade.cancelQ[#Trade.cancelQ + 1] = mine[i]; took = took + 1 end
    if not ForeverQuantAction.key then ForeverQuantAction.Bind() end
    print(string.format("|cff55ccffFQ|r 改价重挂：我的拍卖里有 %d 件挂得比 %s 贵，排了 %d 件去撤。撤下来的会寄到邮箱，取回背包后按 %s 重新挂。%s",
        #mine, SilverText(price), took, SilverText(price), #mine == 0 and "（没找到：先点开一次「拍卖」页签让列表刷新，再试）" or ""))
    return took
end
-- 纠正标高的挂单。不自动做（压着等 8 小时到期再按合理的价重挂就行，犯不上赔押金去撤）；要立刻处理时输入 /fq reprice auto：
-- 挂价比这件货自己真实卖出价的中位数高一半以上的，撤下来，按卖出价中位的 1.1 倍重挂。
-- 没有两笔以上真实卖出的不动（没有依据）；控价的货不动；一遍最多排 6 件，免得一下子撤太多。
-- 撤下来之后就是普通的待上架：取回背包自动挂；再流拍就按流拍次数逐次打折，降到不如卖店时提示卖店。
function Trade.AutoReprice()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return 0 end
    Trade.cancelQ = Trade.cancelQ or {}
    local queued, n = {}, 0
    for _, c in ipairs(Trade.cancelQ) do queued[c.auctionID] = true end
    Trade.repriced = Trade.repriced or {}                   -- 这次上线已经处理过的挂单，不重复排
    for i = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if n < 6 and info and (info.status or 0) == 0 and info.auctionID and info.itemLink and not queued[info.auctionID] and not Trade.repriced[info.auctionID] then
            local name = string.match(info.itemLink, "%[(.-)%]")
            local own = name and not Trade.Control(name) and Pricing.OwnSold(name)
            local price = info.buyoutAmount or 0
            if own and price > own * 1.5 then
                local new = math.max(100, math.floor(own * 1.1 / 100) * 100)
                Trade.cancelQ[#Trade.cancelQ + 1] = { auctionID = info.auctionID, name = name, was = price, price = new,
                                                      id = info.itemKey and info.itemKey.itemID or 0, auto = true }
                Trade.repriced[info.auctionID] = true
                n = n + 1
            end
        end
    end
    if n > 0 then
        if not ForeverQuantAction.key then ForeverQuantAction.Bind() end
        print(string.format("|cff55ccffFQ|r 有 %d 件挂得比自己卖出价高一半以上，撤下来改价重挂（取回背包后自动挂）。", n))
    end
    return n
end
function Trade.CancelOne()                                  -- 由动作键（真实按键）调用
    local q = Trade.cancelQ
    if not q or #q == 0 or GetTime() < (Trade.cancelAt or 0) then return false end
    local c = table.remove(q, 1)
    Trade.cancelAt = GetTime() + 1.5
    if C_AuctionHouse.CanCancelAuction and not C_AuctionHouse.CanCancelAuction(c.auctionID) then
        print(string.format("|cff55ccffFQ|r %s 现在撤不了（可能刚卖掉，或者有人出价了），跳过。", c.name or "?"))
        return true
    end
    local cost
    for _, r in ipairs(ForeverQuantLedger.rows or {}) do
        if r.name == c.name and r.status == "open" then cost = r.cost end
    end
    local ok, err = pcall(C_AuctionHouse.CancelAuction, c.auctionID)
    if not ok then print("|cff55ccffFQ|r 撤单出错：" .. tostring(err)) return true end
    ForeverQuantDB.holdings = ForeverQuantDB.holdings or {}
    table.insert(ForeverQuantDB.holdings, { item_id = c.id, suffix_id = 0, name = c.name, cost = cost or 0, target = c.price, fixed = c.price, t = time() })
    Trade.stockAt = nil
    print(string.format("|cff55ccffFQ|r 已撤下 %s（原挂 %s），取回背包后按 %s 重挂。还要撤 %d 件。", c.name or "?", SilverText(c.was), SilverText(c.price), #q))
    return true
end
-- 「自动管理蓝装」开着、拍卖行也开着时的定时器：每 30 秒把蓝武扫一遍（「自动扫货」开着时它每轮本来就带着扫，这里就不重复）；
-- 每 20 秒核一次控价货的状态，有变化（卖了、挂了、收了）就在聊天栏报一句。挂和收在别处，这里只管定时。
function Trade.ControlTick(scanning)
    if not Trade.blueOn then return end
    Trade.Control()
    local now = GetTime()
    local P = ForeverQuantPool
    if not scanning and P and now >= (Trade.ctlScanAt or 0) and not ForeverQuantScan.running and not P.Busy() and Trade.state == "idle" then
        Trade.ctlScanAt = now + 30
        if ForeverQuantAction and not ForeverQuantAction.key then ForeverQuantAction.Bind() end
        P.StartBlue(true)
    end
    if now < (Trade.ctlSayAt or 0) then return end
    Trade.ctlSayAt = now + 20
    for name, c in pairs(ForeverQuantDB.control) do
        local listed, held = Trade.ControlState(name)
        local bought, spent, sold, got = 0, 0, 0, 0
        for _, line in ipairs(ForeverQuantDB.ledger or {}) do
            local t, kind, total, n = string.match(line, "^(%d+)|(%u+)|%d+|%-?%d+|%d+|(%d+)|([^|]*)")
            if n == name and kind == "BUY" and tonumber(t) >= (c.since or 0) - 3600 then bought, spent = bought + 1, spent + tonumber(total) end
        end
        for _, r in ipairs(ForeverQuantLedger.rows or {}) do
            if r.name == name and r.status == "sold" and r.price and (r.sold or 0) >= (c.since or 0) - 3600 then
                sold, got = sold + 1, got + math.floor(r.price * (1 - AH_CUT))
            end
        end
        local show = {}
        for i, pz in ipairs(listed) do show[i] = SilverText(pz) end
        local sig = #listed .. ":" .. held .. ":" .. sold .. ":" .. bought
        if c.sig ~= sig then
            c.sig = sig
            print(string.format("|cff55ccffFQ|r |cffff8000控价|r %s：挂着 %d 把%s，包里待挂 %d 把 · 开始以来收 %d 把花 %s，卖 %d 把到手 %s，现金净 %s%s",
                name, #listed, #listed > 0 and ("（" .. table.concat(show, " / ") .. "）") or "", held, bought, SilverText(spent), sold, SilverText(got),
                (got - spent >= 0 and "+" or "-"), SilverText(math.abs(got - spent))))
        end
    end
end
-- 某个控价货现在的情况：挂着的价（从低到高）、手里待挂的件数
function Trade.ControlState(name)
    local listed, held = {}, 0
    local Lg = ForeverQuantLedger
    if Lg and Lg.Build then
        Lg.Build()
        for _, r in ipairs(Lg.rows or {}) do
            if r.name == name and r.status == "open" and r.price then listed[#listed + 1] = r.price end
        end
    end
    table.sort(listed)
    for _, h in ipairs(ForeverQuantDB.holdings or {}) do if h.name == name and not h.manual then held = held + 1 end end
    return listed, held
end
-- 给待上架里的控价货排班：轮到的那一把定好价、放行；其余的先按住
function Trade.ControlPlan()
    local hs, state, freed = ForeverQuantDB.holdings or {}, {}, {}
    for _, h in ipairs(hs) do
        local c = not h.manual and Trade.Control(h.name)
        if c then
            h.ctl = true
            state[h.name] = state[h.name] or { Trade.ControlState(h.name) }
            local listed = state[h.name][1]
            local price
            if #listed < c.maxListed and not freed[h.name] then
                price = (listed[1] and listed[1] <= c.front) and c.ask or c.front      -- 前排没有我们的货就先补前排
            end
            if price then
                h.hold, h.post, h.priced_at, h.target = nil, price, time(), price
                freed[h.name] = true                                                  -- 一次只放一把，挂上了再排下一把
            else
                h.hold, h.priced_at = true, time()
            end
        end
    end
end
function Trade.AddHolding(itemId, suffixId, name, cost, target)
    ForeverQuantDB.holdings = ForeverQuantDB.holdings or {}
    table.insert(ForeverQuantDB.holdings, { item_id = itemId, suffix_id = suffixId or 0, name = name, cost = cost, target = target, t = time(),
                                            ctl = Trade.Control(name) and true or nil, hold = Trade.Control(name) and true or nil })
end
-- 认领：翻一遍背包，凡是在「绿装捡漏」名单上出现过的装备（你自己手动买的也算），按当时的目标卖价排队上架。
-- 只在你点「上架背包里的货」时做。
function Trade.Adopt(quiet)
    ForeverQuantDB.holdings = ForeverQuantDB.holdings or {}
    local holdings, n = ForeverQuantDB.holdings, 0
    local have = {}                                         -- 同名的已经排了几件
    for _, h in ipairs(holdings) do local k = h.item_id .. ":" .. (h.name or "") have[k] = (have[k] or 0) + 1 end
    local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    local getSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    for bag = 0, 4 do
        for slot = 1, (getSlots(bag) or 0) do
            local link = getLink(bag, slot)
            local id, name = link and tonumber(string.match(link, "item:(%d+)")), link and string.match(link, "%[(.-)%]")
            local kn = Trade.Known(id, name)
            if kn then
                local k = id .. ":" .. name
                if (have[k] or 0) > 0 then
                    have[k] = have[k] - 1                   -- 这一件已经在待上架名单里了
                else
                    n = n + 1
                    local cost = kn.buy
                    local Lg = ForeverQuantLedger
                    if Lg and Lg.Build then                      -- 之前清成"自用"的又拿出来卖：按当时的买入成本记回去
                        Lg.Build()
                        for _, r in ipairs(Lg.rows or {}) do
                            if r.status == "used" and r.name == name then
                                cost = r.cost or cost
                                Lg.Add("RESTOCK", id, 0, 1, cost, name)
                                break
                            end
                        end
                    end
                    Trade.AddHolding(id, kn.suffix, name, cost, kn.target)
                end
            end
        end
    end
    if quiet and n == 0 then return end
    print(string.format("|cff55ccffFQ|r 背包里找到 %d 件名单上出现过的货，待上架共 %d 件：", n, #holdings))
    for _, h in ipairs(holdings) do
        print(string.format("   %s  → 挂 %s%s", h.name or "?", SilverText(h.target), FindInBags(h.item_id, h.suffix_id, h.name) and "" or "  |cffff6060（不在背包里）|r"))
    end
    if #holdings == 0 then print("|cff55ccffFQ|r 背包里没有在「绿装捡漏」名单上出现过的装备。名单外的货要手动挂。") end
end

-- 上架查同款时，最便宜的一两件是不是"明显标错的压价单"：返回 (要买几件, 参照价)。
--   它们和后面的同款之间要差一倍以上（MIS_GAP）；三件以上都这么便宜就是行情，不是标错。
--   后面有两件以上同款时拿同款最低价当参照；不足两件时拿原目标价当参照（一件孤零零的高价不可信）。
--   还要买来转手有赚头、钱够。
function Pricing.Mistakes(h, prices)
    local MIS_GAP = 2.0
    for k = 1, math.min(2, #prices) do
        local others = #prices - k
        local ref = (others >= 2) and prices[k + 1] or math.min(prices[k + 1] or h.target, h.target)
        if ref and prices[k] * MIS_GAP <= ref then
            local sell = Undercut(ref)
            if math.floor(sell * (1 - AH_CUT)) - prices[k] >= 1500 and prices[k] <= GetMoney() then return k, ref end
            return 0
        end
    end
    return 0
end
-- 这件货（按名字）我们自己最近的卖出价中位数。只认"没到期就卖掉"的，推断出来的不算；不足两笔返回 nil
function Pricing.OwnSold(name)
    local Lg, ps = ForeverQuantLedger, {}
    if not name or not (Lg and Lg.rows) then return nil end
    for _, r in ipairs(Lg.rows) do                         -- rows 新的在前
        if r.name == name and r.status == "sold" and r.price and (r.took or 0) < (r.dur or 8) * 3600 - 300 then
            ps[#ps + 1] = r.price
            if #ps >= 5 then break end
        end
    end
    if #ps < 2 then return nil end
    table.sort(ps)
    return ps[math.ceil(#ps / 2)]
end
Pricing.HOT, Pricing.HOT_BUMP = { "强盗之" }, 0.15         -- 好卖的词缀（名字开头）；没人压价时提多少
local HOT_BUMP = Pricing.HOT_BUMP
local function HotSuffix(name)
    for _, pre in ipairs(Pricing.HOT) do
        if name and string.sub(name, 1, #pre) == pre then return (string.gsub(pre, "之$", "")) end
    end
end
-- 上架前定价：挂之前先查一次这件装备现在的同款挂单，贴着同款最便宜的那件挂（低 3%）。
-- 买入时记下的目标价只是模型估的，常常偏低（挂上去一秒就被买走 = 挂便宜了）。结果两分钟内有效。
local function PriceDecide(h, prices)
    local low, n = prices[1], #prices
    local floorPrice = math.ceil((h.cost or 0) * 1.15 / (1 - AH_CUT))      -- 低于这个价就不到 15% 利润了
    local post, why
    if not low then
        post, why = h.target, "没有同款在售，按原目标价"
    else
        local cand = Undercut(low)
        if cand < floorPrice then
            post, why = math.max(h.target, floorPrice), string.format("同款最低只有 %s，贴着它挂就没利润了，按原目标价挂着等", SilverText(low))
        elseif n == 1 and cand > h.target then
            post = math.floor((cand + h.target) / 2 / 100) * 100          -- 只有一件同款，可能是乱标的：取它和模型估价的中间
            why = string.format("只有 1 件同款挂 %s，取它和原目标价的中间", SilverText(low))
        else
            post, why = cand, string.format("同款 %d 件，最低 %s", n, SilverText(low))
        end
    end
    -- 好卖的词缀：没有同款压在我们下面时（没同款，或唯一一件同款挂得比原目标价高），原目标价多半估低了，往上提一档。
    -- 有两件以上同款时本来就跟着市场价走，不用提；流拍过的不提。
    local hot = (h.relist or 0) == 0 and HotSuffix(h.name)
    if hot and (not low or (n == 1 and Undercut(low) > h.target)) then
        local up = math.floor(h.target * (1 + HOT_BUMP) / 100) * 100
        if low then up = math.min(up, Undercut(low)) end                    -- 不越过那一件同款
        if up > post then
            post, why = up, why .. string.format("；「%s」好卖又没人压价，提 %d%%", hot, math.floor(HOT_BUMP * 100 + 0.5))
        end
    end
    -- 流拍后重新挂的：上次那个价没卖掉，这次要打折。每流拍一次降一成，一路降下去，不守成本；
    -- 同款有两件以上时跟市场价（哪怕低于成本）。降到"拍卖行到手还不如卖商店"时，就不再挂了，改成建议卖店。
    if (h.relist or 0) > 0 then
        local vendor = select(11, ItemInfo(h.item_id)) or 0
        local cut = math.floor(h.target * (0.9 ^ h.relist) / 100) * 100
        if low and n >= 2 then
            post, why = math.min(Undercut(low), h.target), string.format("同款 %d 件，最低 %s", n, SilverText(low))      -- 跟市场，但不比上次挂得高
        else
            post, why = cut, low and string.format("只有 1 件同款挂 %s，不参考", SilverText(low)) or "没有同款在售"
        end
        post = math.min(post, cut > 0 and math.max(cut, post) or post)
        why = why .. string.format("；流拍过 %d 次（上次挂 %s）", h.relist, SilverText(h.target))
        if post <= 0 or math.floor(post * (1 - AH_CUT)) <= vendor then
            h.vendor, h.fail = true, 9                          -- fail >= 2 的不会再被自动上架
            h.post, h.priced_at = nil, time()
            print(string.format("|cff55ccffFQ|r %s 流拍 %d 次，再降就不如卖商店了（商店收 %s）。不再上架，带去商人那里卖掉就行，账上会自动记。",
                h.name or "?", h.relist, SilverText(vendor)))
            return
        end
    end
    -- 别人的挂价不等于成交价：同款都挂 3 金，可我们自己前几件是 1 金上下卖掉的，那就不能跟着挂 3 金压货。
    -- 这件货自己卖出过两次以上的，挂价不超过"最近几次卖出价的中位数"的 1.3 倍。
    -- 流拍过的更要收着挂：第一次流拍后不超过卖出价中位，再流拍每次再降一成。
    local own = Pricing.OwnSold(h.name)
    local n = h.relist or 0
    local lim = own and math.floor(own * (n == 0 and 1.3 or (0.9 ^ (n - 1))))
    if lim and post and post > lim then
        post = math.max(100, math.floor(lim / 100) * 100)
        why = (why or "") .. string.format("；自己最近卖出价中位 %s，%s", SilverText(own),
            n == 0 and "不超过它的 1.3 倍" or string.format("流拍 %d 次后不超过它%s", n, n > 1 and string.format("的 %d%%", math.floor(0.9 ^ (n - 1) * 100 + 0.5)) or ""))
    end
    local changed = h.post ~= post
    h.post, h.priced_at = post, time()
    if changed then print(string.format("|cff55ccffFQ|r 定价 %s：%s → 挂 %s（原目标 %s，买入 %s）", h.name or "?", why, SilverText(post), SilverText(h.target), SilverText(h.cost))) end
end
Pricing.Decide = PriceDecide
ForeverQuantPricingDecide = PriceDecide        -- 给测试用
local PRICE_TTL = 300               -- 定价多久算过期（秒）；过期了后台会自己重查
local function PriceFresh(h) return h.post and h.priced_at and time() - h.priced_at < PRICE_TTL end
local function PriceReady(h)        -- 这件有新鲜的定价了吗？没有就发起一次查询
    if h.fixed then h.post, h.priced_at = h.fixed, time() return true end      -- 你指定了价的：不查同款
    if PriceFresh(h) then return true end
    if h.ctl then return false end                       -- 控价的货不查同款、不跟价：价由排班给
    if Pricing.cur then return false end
    local bag, slot = FindInBags(h.item_id, h.suffix_id, h.name)
    if not bag then return false end
    local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, ItemLocation:CreateFromBagAndSlot(bag, slot))
    if not ok or not key then h.post, h.priced_at = h.target, time() return true end      -- 查不了就用原目标价
    if ForeverQuantScan.running or Trade.state ~= "idle" or ForeverQuantPeer.cur or Pool.cur or Pool.fav or (Pool.bq and Pool.bq.sent) or not ForeverQuantView.Ready() then return false end
    Pricing.cur, Pricing.since = { h = h, key = key }, GetTime()
    if not pcall(ForeverQuantView.Search, key, {}, false) then Pricing.cur = nil; h.post, h.priced_at = h.target, time() return true end
    return false
end
Pricing.frame = CreateFrame("Frame")
pcall(Pricing.frame.RegisterEvent, Pricing.frame, "ITEM_SEARCH_RESULTS_UPDATED")
Pricing.frame:SetScript("OnEvent", function()
    local c = Pricing.cur
    if not c then return end
    local prices, infos = {}, {}
    for i = 1, (C_AuctionHouse.GetNumItemSearchResults(c.key) or 0) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(c.key, i)
        if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            prices[#prices + 1] = info.buyoutAmount
            infos[#infos + 1] = info
        end
    end
    table.sort(prices)
    table.sort(infos, function(a, b) return a.buyoutAmount < b.buyoutAmount end)
    Pricing.cur = nil
    -- 最便宜的一两件明显是标错的：不跟着它压价，直接买下来（买到的进待上架，之后一起挂），自己这件按剩下的同款定价
    local k, ref = 0, nil
    if ForeverQuantModes.sweeping() then k, ref = Pricing.Mistakes(c.h, prices) end
    if k > 0 then
        for i = 1, k do
            local info = infos[i]
            local op = { item_id = c.h.item_id, suffix_id = c.h.suffix_id or 0, name = c.h.name, strategy = "GEAR", ikey = c.key,
                key = c.h.item_id .. ":" .. (c.h.suffix_id or 0) .. ":" .. info.buyoutAmount .. ":" .. tostring(info.auctionID or i),
                stars = 3, verified = true, marked = "want", wantGap = 0, max_unit_price = info.buyoutAmount, target_unit_price = Undercut(ref),
                expected_profit = math.floor(Undercut(ref) * (1 - AH_CUT)) - info.buyoutAmount, reason = "上架时发现的压价单" }
            if not Trade.done[op.key] then
                print(string.format("|cff55ccffFQ|r 上架 %s 时发现压价单：%s，其余同款 %s 起。不跟它压价，直接买下来。", c.h.name or "?", SilverText(info.buyoutAmount), SilverText(ref)))
                if not Trade.Direct(op, info) then Trade.BuyNow(op) end
            end
        end
        local rest = {}
        for i = k + 1, #prices do rest[#rest + 1] = prices[i] end
        prices = rest
    end
    PriceDecide(c.h, prices)
end)
Pricing.frame:SetScript("OnUpdate", function()
    local c = Pricing.cur
    if c and GetTime() - Pricing.since > 6 then          -- 查询没回来：按"没有同款"处理
        Pricing.cur = nil
        PriceDecide(c.h, {})
    end
end)

local function DoPost(quiet)
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        if not quiet then print("|cff55ccffFQ|r 请先打开拍卖行") end
        return
    end
    local holdings = ForeverQuantDB.holdings or {}
    for i, h in ipairs(holdings) do
        local bag, slot = FindInBags(h.item_id, h.suffix_id, h.name)
        if bag then
            if Trade.Postable(h) and not Trade.posting and (not Trade.ctlOnly or h.ctl or h.blue) then
                if not PriceReady(h) then return end       -- 价还没查好：后台在查，查好后按钮会变成"挂出"
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                buySignal:Hide()
                local ok, err = pcall(C_AuctionHouse.PostItem, loc, 2, 1, nil, h.post)       -- 时长取中间一档
                if ok then
                    -- 等那个格子里的东西真的离开背包才算挂上。认格子不认名字：包里有两件同名的时候，
                    -- 挂掉一件、另一件还在，按名字找会以为没挂上，结果留下一条根本不存在的"待上架"
                    local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
                    Trade.posting = { h = h, since = GetTime(), bag = bag, slot = slot, link = getLink(bag, slot) }
                else
                    h.fail = (h.fail or 0) + 1
                    print("|cff55ccffFQ|r 上架出错：" .. tostring(err))
                end
                return
            end
        end
    end
    if not Trade.posting and not quiet then
        print(#holdings > 0 and "|cff55ccffFQ|r 待上架的东西不在背包里（或上架失败过两次），先去邮箱取。" or "|cff55ccffFQ|r 没有待上架的东西。")
    end
end

-- 动作键：一个键管三件事。有待买的就买；否则有能上架的就上架；同时它也是电脑端程序的"在线心跳"——
-- 插件隔一会儿亮一下蓝色信号请 agent 按这个键，按了就说明 agent 活着，面板上显示"电脑端：在线"。
local Action = { seen = nil, nextPing = 0, pinging = false }
ForeverQuantAction = Action
local actionBtn = CreateFrame("Button", "ForeverQuantActionButton", UIParent)
actionBtn:SetScript("OnClick", function()
    if Action.pinging then
        Action.seen, Action.pinging = GetTime(), false
        buySignal:Hide()
    end
    Action.nextPing = GetTime() + 60
    if Trade.state == "ready" then
        DoBuy()
    elseif Trade.cancelQ and #Trade.cancelQ > 0 then
        Trade.CancelOne()
    elseif ForeverQuantJunk and ForeverQuantJunk.Wanted() then
        ForeverQuantJunk.DeleteOne()
    elseif (Trade.on or #(ForeverQuantDB.holdings or {}) > 0) and Trade.state == "idle" and not Trade.posting then
        DoPost(true)
    end
end)
function Action.Online() return Action.seen and (GetTime() - Action.seen) < 150 end

-- 上架的后续：确认物品离开背包；需要的话给"按上架键"的信号
local postTick = 0
local postFrame = CreateFrame("Frame")
postFrame:SetScript("OnUpdate", function(_, elapsed)
    postTick = postTick + elapsed
    if postTick < 0.4 then return end
    postTick = 0
    if not ForeverQuantDB then return end
    local holdings = ForeverQuantDB.holdings or {}       -- 没有持仓也要往下走：后面还有心跳
    if not Trade.posting and GetTime() >= (Trade.planAt or 0) then      -- 排班要翻一遍账本，两秒做一次就够
        Trade.planAt = GetTime() + 2
        Trade.ControlPlan()
    end
    if Trade.posting then
        local h = Trade.posting.h
        local P = Trade.posting
        local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
        local gone
        if P.bag and P.link then gone = getLink(P.bag, P.slot) ~= P.link else gone = not FindInBags(h.item_id, h.suffix_id, h.name) end
        if gone then
            for i, x in ipairs(holdings) do if x == h then table.remove(holdings, i) break end end
            TLog("POST", h, h.post or h.target)
            print(string.format("|cff55ccffFQ|r |cff40ff40已上架|r %s  挂 %s  买 %s",
                h.name or "?", SilverText(h.post or h.target), SilverText(h.cost)))
            Trade.posting = nil
            if frame:IsShown() then Refresh() end
        elseif GetTime() - Trade.posting.since > 5 then
            h.fail = (h.fail or 0) + 1
            print(string.format("|cff55ccffFQ|r %s 没挂上（第 %d 次）。%s", h.name or "?", h.fail, h.fail >= 2 and "不再自动重试，请手动上架。" or ""))
            Trade.posting = nil
        end
        return
    end
    if MerchantFrame and MerchantFrame:IsShown() then
        for i = #holdings, 1, -1 do
            local h = holdings[i]
            if h.vendor then
                local inBag = FindInBags(h.item_id, h.suffix_id, h.name) ~= nil
                if h.wasInBag and not inBag then
                    local vendor = select(11, ItemInfo(h.item_id)) or 0
                    ForeverQuantLedger.Add("VENDOR", h.item_id, 0, 1, vendor, h.name)
                    table.remove(holdings, i)
                    print(string.format("|cff55ccffFQ|r %s 卖给商人了，收回 %s（买入 %s）。", h.name or "?", SilverText(vendor), SilverText(h.cost or 0)))
                else
                    h.wasInBag = inBag
                end
            end
        end
    end
    -- 后台定价：拍卖行开着、背包里有待上架的货，就主动把价查好（不用你点），按钮跟着变
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        for _, h in ipairs(holdings) do
            if Trade.Postable(h) and not PriceFresh(h) and FindInBags(h.item_id, h.suffix_id, h.name) then PriceReady(h) break end
        end
    end
    if frame:IsShown() then
        local text = ForeverQuantModes.SellState()
        if text ~= Pricing.shown then Pricing.shown = text; Refresh() end
    end
    -- 自动上架：狙击开着、允许自动按键、拍卖行开着、当前没有待买的，而且背包里有持仓
    -- 集中上架：点一次按钮开一轮，把背包里待上架的一口气挂完就自己停（不用开着「自动上架」）
    if Trade.batch and not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        print(string.format("|cff55ccffFQ|r 拍卖行关了，集中上架停下：这一轮挂了 %d 件。", Trade.batch.total - Trade.batch.left))
        Trade.batch = nil
    end
    -- 改价重挂排着队要撤的：请电脑端按键，一次撤一件
    if Trade.cancelQ and #Trade.cancelQ > 0 and Action.keyIdx and Trade.state == "idle" and not Trade.posting
        and AuctionHouseFrame and AuctionHouseFrame:IsShown() and not auto then
        if GetTime() >= (Trade.cancelAt or 0) then
            Action.pinging = false
            buySignal:ShowKey(Action.keyIdx)
        end
        return
    end
    -- 蓝武（控价的货、自动买进的蓝武）听「自动管理蓝装」的：它开着、拍卖行开着、轮到了就挂，只挂蓝武，绿装的待上架不动
    local allowAll = TradeCfg().autoPress or Trade.batch
    local ctlGo = false
    if not allowAll and Trade.blueOn then
        for _, h in ipairs(holdings) do
            if (h.ctl or h.blue) and Trade.Postable(h) and FindInBags(h.item_id, h.suffix_id, h.name) then ctlGo = true break end
        end
        if ctlGo and not Action.keyIdx then Action.Bind() end
    end
    if (Trade.on or #holdings > 0) and (allowAll or ctlGo) and Action.keyIdx and Trade.state == "idle"
        and AuctionHouseFrame and AuctionHouseFrame:IsShown() and not auto then
        local left = 0
        for _, h in ipairs(holdings) do
            if Trade.Postable(h) and FindInBags(h.item_id, h.suffix_id, h.name) then left = left + 1 end
        end
        if Trade.batch then
            Trade.batch.left = left
            if left == 0 then
                print(string.format("|cff55ccffFQ|r |cff40ff40集中上架完成|r：这一轮挂了 %d 件。", Trade.batch.total))
                Trade.batch = nil
                if frame:IsShown() then Refresh() end
            end
        end
        for _, h in ipairs(holdings) do
            if Trade.Postable(h) and (allowAll or h.ctl or h.blue) and FindInBags(h.item_id, h.suffix_id, h.name) then
                if not PriceReady(h) then return end       -- 先查同款定好价，再请电脑端按键
                Action.pinging = false
                Trade.ctlOnly = not allowAll               -- 告诉下面真正上架的那一步：这次只许挂控价的货
                buySignal:ShowKey(Action.keyIdx)
                return
            end
        end
    end
    -- 钓鱼时背包快满、包里有标记过的垃圾：请 agent 按动作键扔一堆
    if Action.keyIdx and not auto and Trade.state ~= "ready" and ForeverQuantJunk and ForeverQuantJunk.Wanted() then
        Action.pinging = false
        buySignal:ShowKey(Action.keyIdx)
        return
    end
    -- 心跳：没有别的信号在亮时，每分钟请 agent 按一次动作键
    local now = GetTime()
    if Action.pinging then
        if now > Action.pingUntil then Action.pinging = false; buySignal:Hide(); Action.nextPing = now + 60 end
    elseif Action.keyIdx and not auto and Trade.state ~= "ready" and now >= Action.nextPing and not signal:IsShown() then
        Action.pinging, Action.pingUntil = true, now + 3
        buySignal:ShowKey(Action.keyIdx)
    end
end)

local function BindFirstFree(keys, buttonName)
    local mine = "CLICK " .. buttonName .. ":LeftButton"
    for i, k in ipairs(keys) do if GetBindingAction(k) == mine then return k, i end end
    for i, k in ipairs(keys) do
        if GetBindingAction(k) == "" then
            SetBindingClick(k, buttonName)
            SaveBindings(GetCurrentBindingSet())
            return k, i
        end
    end
end

function Action.Bind()
    if Action.key then return Action.key end
    if InCombatLockdown and InCombatLockdown() then return end
    Action.key, Action.keyIdx = BindFirstFree(DE_KEYS, "ForeverQuantActionButton")
    return Action.key
end

function Trade.Toggle(arg)
    local cfg = TradeCfg()
    if InCombatLockdown and InCombatLockdown() then print("|cff55ccffFQ|r 战斗中不能改按键") return end
    if arg == "auto" then
        cfg.autoPress = not cfg.autoPress
        print("|cff55ccffFQ|r 自动上架：" .. (cfg.autoPress and "开（查好同款价就自动挂出去）" or "关（要你点「挂出」按钮）"))
        return
    end
    Trade.on = not Trade.on
    if not Trade.on then
        Trade.queue, Trade.cur, Trade.ready, Trade.state = {}, nil, nil, "idle"
        buySignal:Hide()
        print("|cff55ccffFQ|r 自动买入已关闭。")
        return
    end
    Action.Bind()
    Trade.key, Trade.keyIdx = Action.key, Action.keyIdx
    Trade.spent = 0
    local n = Trade.Enqueue()
    print(string.format("|cff55ccffFQ|r 自动买入已开启：只买「建议」一栏是「买」的；没有花费上限，金币够就买。动作键 %s（买入和上架都是它）。当前排队 %d 条。",
        Trade.key or "未绑定", n))
    if not Trade.key then print("|cff55ccffFQ|r 没有空闲的键可以绑定买入，请在按键设置里手动绑定。") end
end

--------------------------------------------------------------------------------
-- 账本：不管用什么方式买卖（本插件、Auctionator、游戏自带界面）都记。
-- 买入和上架：在游戏接口上挂钩子。卖出、流拍：靠系统消息。每条记一行，存在 ForeverQuantDB.ledger：
--   时间|类型|物品ID|后缀ID|数量|总价(铜)|名称|附加
-- 类型：BUY 买入 / POST 上架 / SOLD 卖出 / EXPIRED 流拍 / CANCEL 撤单
--------------------------------------------------------------------------------
local Ledger = {}
ForeverQuantLedger = Ledger

local function ParseLink(link)
    if not link then return 0, 0, "?" end
    local id, suffix = string.match(link, "item:(%d+):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d*)")
    if not id then id = string.match(link, "item:(%d+)") end
    return tonumber(id) or 0, tonumber(suffix) or 0, string.match(link, "%[(.-)%]") or "?"
end

local function LAdd(kind, id, suffix, qty, total, name, extra)
    ForeverQuantDB.ledger = ForeverQuantDB.ledger or {}
    local lg = ForeverQuantDB.ledger
    lg[#lg + 1] = string.format("%d|%s|%d|%d|%d|%d|%s|%s", Ledger.stamp or time(), kind, id or 0, suffix or 0, qty or 1, total or 0,
        string.gsub(name or "?", "|", "/"), extra or "")
    if frame:IsShown() and mode == "ledger" then Refresh() end
end

Ledger.Add = LAdd
local pendingBuys = {}          -- 发出了购买请求、还没确认扣钱的
local ledgerFrame = CreateFrame("Frame")
pcall(function()
    hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, amount)
        local info = C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
        local id, suffix, name = ParseLink(info and info.itemLink)
        pendingBuys[#pendingBuys + 1] = { since = GetTime(), money = GetMoney(), amount = amount, id = id, suffix = suffix, name = name, qty = 1 }
    end)
end)
pcall(function()
    hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
        pendingBuys[#pendingBuys + 1] = { since = GetTime(), money = GetMoney(), id = itemID, suffix = 0, name = ItemInfo(itemID) or ("物品" .. itemID), qty = quantity }
    end)
end)
pcall(function()
    hooksecurefunc(C_AuctionHouse, "PostItem", function(item, duration, quantity, bid, buyout)
        local link = C_Item and C_Item.GetItemLink and C_Item.DoesItemExist(item) and C_Item.GetItemLink(item)
        local id, suffix, name = ParseLink(link)
        local dep = 0
        pcall(function() dep = C_AuctionHouse.CalculateItemDeposit(item, duration, quantity or 1) or 0 end)
        LAdd("POST", id, suffix, quantity or 1, buyout or bid or 0, name, "dep=" .. dep .. ",dur=" .. tostring(duration or 2))
    end)
end)
pcall(function()
    hooksecurefunc(C_AuctionHouse, "PostCommodity", function(item, duration, quantity, unitPrice)
        local link = C_Item and C_Item.GetItemLink and C_Item.DoesItemExist(item) and C_Item.GetItemLink(item)
        local id, suffix, name = ParseLink(link)
        LAdd("POST", id, suffix, quantity or 1, (unitPrice or 0) * (quantity or 1), name, "commodity")
    end)
end)
ledgerFrame:SetScript("OnUpdate", function()
    if Ledger.askOwnedAt and GetTime() >= Ledger.askOwnedAt and not ForeverQuantScan.running then      -- 开拍卖行后要一次"我的拍卖"用来对账
        Ledger.askOwnedAt = nil
        pcall(C_AuctionHouse.QueryOwnedAuctions, {})
        if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
            if Trade.blueOn and next(ForeverQuantDB.control or {}) then
                Ledger.askOwnedAt = GetTime() + 60       -- 有控价的货：每分钟对一次账，卖掉了才知道该补货
            end
        end
    end
    if Ledger.mailAt and GetTime() >= Ledger.mailAt then
        Ledger.mailAt = nil
        pcall(Ledger.MailScan)
        Ledger.quiet = nil
    end
    if Ledger.bagAt and GetTime() >= Ledger.bagAt and not Trade.posting and #pendingBuys == 0 then
        Ledger.bagAt = nil
        Ledger.BagCheck()
    end
    if #pendingBuys == 0 then return end
    local now = GetTime()
    for i = #pendingBuys, 1, -1 do
        local b = pendingBuys[i]
        local spent = b.money - GetMoney()
        if spent > 0 and (not b.amount or spent >= b.amount) then        -- 钱真的扣了才算买到
            LAdd("BUY", b.id, b.suffix, b.qty, b.amount or spent, b.name)
            Trade.MarkManual(b.id, b.name, b.amount or spent)                -- 你自己在拍卖行点的：名单上对应那条也标成买到了
            local kn = Trade.state ~= "buying" and Trade.Known(b.id, b.name)      -- 插件排队买的那条路自己会记，别记两遍
            if kn then
                Trade.AddHolding(b.id, kn.suffix, b.name, b.amount or spent, kn.target)
                print(string.format("|cff55ccffFQ|r 你买的 %s 在捡漏名单上（当时 %d 星），已排进待上架：目标 %s。去邮箱取回后会挂出去。",
                    b.name, kn.stars or 1, SilverText(kn.target)))
            end
            table.remove(pendingBuys, i)
        elseif now - b.since > 8 then
            table.remove(pendingBuys, i)                                  -- 没扣钱：没买到
        end
    end
end)

-- 系统消息：把"你的拍卖品 %s 已售出"这类格式串变成能取出物品名的匹配式
local function MsgPattern(fmt)
    if not fmt or fmt == "" then return nil end
    local p = string.gsub(fmt, "([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    return "^" .. string.gsub(p, "%%s", "(.+)") .. "$"        -- 之前这里写成了匹配 "%%s"，永远对不上，所以卖出一条都没记
end
local SOLD_PAT, EXPIRED_PAT = MsgPattern(ERR_AUCTION_SOLD_S), MsgPattern(ERR_AUCTION_EXPIRED_S)
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "CHAT_MSG_SYSTEM")
local function PlainName(n) return string.match(n, "%[(.-)%]") or n end       -- 消息里可能是带颜色的物品链接
local SOLD_PATS = { SOLD_PAT, "^你拍卖的(.+)已经售出。?$", "^你的拍卖品(.+)已售出。?$", "^A buyer has been found for your auction of (.+)%.$" }
local EXPIRED_PATS = { EXPIRED_PAT, "^你拍卖的(.+)已经过期。?$", "^你的拍卖品(.+)已过期。?$", "^Your auction of (.+) has expired%.$" }
-- 流拍（到期没卖掉）的货会退回邮箱：记一笔，并把它放回待上架，回到背包后照常重新定价、重新挂
function Ledger.Expired(name, note, mode)        -- mode: nil = 账上在售的；"fix" = 误记成卖出的；"unknown" = 去向不明的
    local fix = mode == "fix" or mode == true
    Ledger.Build()
    local row
    for i = #(Ledger.rows or {}), 1, -1 do                 -- 同名的取最早挂的那一件
        local r = Ledger.rows[i]
        if r.status == "open" and r.name == name then row = r break end
    end
    local n = 1                                            -- 这件东西（同名）之前流拍过几次（在记这一笔之前数）
    for _, r in ipairs(Ledger.rows or {}) do if r.status == "expired" and r.name == name then n = n + 1 end end
    if fix then                                            -- 更正：之前对账时误记成"已卖出"的，其实是流拍退回来了
        row = nil
        for _, r in ipairs(Ledger.rows or {}) do           -- rows 新的在前：取最近一笔补记的卖出
            if r.status == "sold" and r.fix and r.name == name then row = r break end
        end
        if not row then return false end
        LAdd("UNSOLD", row.item_id or 0, 0, 1, 0, name, note)
    elseif mode == "unknown" then                          -- 去向不明的那一笔，现在确认是流拍退回来了
        row = nil
        for i = #(Ledger.rows or {}), 1, -1 do
            local r = Ledger.rows[i]
            if r.status == "unknown" and r.name == name then row = r break end
        end
        if not row then return false end
        LAdd("FOUND", row.item_id or 0, 0, 1, 0, name, note)
    else
        LAdd("EXPIRED", row and row.item_id or 0, 0, 1, 0, name, note)
    end
    if row and row.item_id and row.item_id ~= 0 then
        local kn = ForeverQuantTrade.Known(row.item_id, name)
        ForeverQuantTrade.AddHolding(row.item_id, kn and kn.suffix or 0, name, row.cost or 0, row.price or (kn and kn.target) or 0)
        local hs = ForeverQuantDB.holdings
        hs[#hs].relist = n
        if not Ledger.quiet then
            print(string.format("|cff55ccffFQ|r %s 到期没卖掉，已放回待上架（上次挂 %s）。去邮箱取回后会按同款重新定价再挂。", name, SilverText(row.price or 0)))
        end
    end
    return row ~= nil
end

-- 以背包为准找流拍退回来的货：一件东西不可能既在背包里又挂在拍卖行。
-- 所以背包里某个名字的件数，超过"待上架 + 标成自用"的那几件，就是从拍卖行退回来的：
--   账上还标着在售的 -> 记流拍；账上被对账误记成已卖出的 -> 更正成流拍。两种都放回待上架，按流拍次数打折重挂。
-- 不依赖系统消息（这个客户端流拍时聊天栏不一定有字），也不依赖拍卖时长猜得对不对。
function Ledger.BagNames()
    local out = {}
    local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    local getSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not getLink or not getSlots then return out end
    for bag = 0, 4 do
        for slot = 1, (getSlots(bag) or 0) do
            local link = getLink(bag, slot)
            local name = link and string.match(link, "%[(.-)%]")
            if name then out[name] = (out[name] or 0) + 1 end
        end
    end
    return out
end
function Ledger.BagCheck()
    if not (ForeverQuantDB and ForeverQuantDB.ledger) or (InCombatLockdown and InCombatLockdown()) then return 0 end
    local bags = Ledger.BagNames()
    if not next(bags) then return 0 end
    Ledger.Build()
    local cover, back, open, unk = {}, {}, {}, {}           -- 名字 -> 已经有着落的件数 / 账上可能退回来的件数 / 其中还标着在售的 / 去向不明的
    for _, h in ipairs(ForeverQuantDB.holdings or {}) do if h.name then cover[h.name] = (cover[h.name] or 0) + 1 end end
    for _, r in ipairs(Ledger.rows or {}) do
        if r.name then
            if r.status == "used" then cover[r.name] = (cover[r.name] or 0) + 1
            elseif r.status == "open" or r.status == "unknown" or (r.status == "sold" and r.fix) then
                back[r.name] = (back[r.name] or 0) + 1
                if r.status == "open" then open[r.name] = (open[r.name] or 0) + 1 end
                if r.status == "unknown" then unk[r.name] = (unk[r.name] or 0) + 1 end
            end
        end
    end
    local found = {}
    Ledger.quiet = true
    for name, n in pairs(bags) do
        local extra = math.min(n - (cover[name] or 0), back[name] or 0)
        for i = 1, extra do                                 -- 先认去向不明的（挂得最早），再销还标着在售的，最后更正误记成卖出的
            local u, o = unk[name] or 0, open[name] or 0
            local m = "fix"
            if i <= u then m = "unknown" elseif i <= u + o then m = nil end
            if Ledger.Expired(name, "背包里找到", m) then found[#found + 1] = name else break end
        end
    end
    Ledger.quiet = nil
    if #found > 0 then
        print(string.format("|cff55ccffFQ|r 背包里有 %d 件是拍卖行到期退回来的，已放回待上架，会降一点价重挂：%s", #found, table.concat(found, "、", 1, math.min(#found, 8)) .. (#found > 8 and " …" or "")))
        if frame:IsShown() then Refresh() end
    end
    return #found
end
function Ledger.OnSystemMessage(msg)
    if type(msg) ~= "string" then return end
    for i = 1, 4 do
        local name = SOLD_PATS[i] and string.match(msg, SOLD_PATS[i])
        if name then return LAdd("SOLD", 0, 0, 1, 0, PlainName(name)) end
    end
    for i = 1, 4 do
        local name = EXPIRED_PATS[i] and string.match(msg, EXPIRED_PATS[i])
        if name then return Ledger.Expired(PlainName(name)) end
    end
end
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "OWNED_AUCTIONS_UPDATED")
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "BAG_UPDATE_DELAYED")
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "MAIL_INBOX_UPDATE")
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "AUCTION_HOUSE_SHOW")
ledgerFrame:SetScript("OnEvent", function(_, event, msg)
    if event == "CHAT_MSG_SYSTEM" then return Ledger.OnSystemMessage(msg) end
    if event == "AUCTION_HOUSE_SHOW" then Ledger.askOwnedAt = GetTime() + 3; Ledger.bagAt = GetTime() + 4 return end
    if event == "BAG_UPDATE_DELAYED" then Ledger.bagAt = GetTime() + 1.5 return end           -- 等背包停下来再看（取信时一件件进来）
    if event == "MAIL_INBOX_UPDATE" then Ledger.mailAt = Ledger.mailAt or (GetTime() + 0.5) return end
    if event == "OWNED_AUCTIONS_UPDATED" then Ledger.Reconcile() end
end)
-- 撤单
pcall(function()
    hooksecurefunc(C_AuctionHouse, "CancelAuction", function(auctionID)
        for i = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
            local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
            if info and info.auctionID == auctionID then
                local id, suffix, name = ParseLink(info.itemLink)
                return LAdd("CANCEL", id, suffix, 1, 0, name)
            end
        end
    end)
end)
-- 补记：拿"我的拍卖"对账。账本里还标着在售、但我的拍卖里已经没有（或已标成售出）的，就是卖掉了而当时没记上
-- （比如你不在线时卖的，或者上面那个消息匹配出错的时候）。补记的卖出时间只能写成对账的时间。
function Ledger.Reconcile()
    if not (C_AuctionHouse.HasFullOwnedAuctionResults and C_AuctionHouse.HasFullOwnedAuctionResults()) then return end
    local active, left, pend, soldAt = {}, {}, {}, {}
    for i = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info and info.itemLink and (info.status or 0) == 0 then           -- 0 = 还在卖；1 = 已售出、钱在路上
            local _, _, name = ParseLink(info.itemLink)
            active[name] = (active[name] or 0) + 1
            left[name] = math.max(left[name] or 0, info.timeLeftSeconds or 0)
        elseif info and info.status == 1 then
            -- 已售出、钱还押在拍卖行：这是拍卖行自己报的，拿它当"没到账的钱"的准数（金额和还要等多久都有）
            local _, _, name = ParseLink(info.itemLink or "")
            local amount = info.buyoutAmount or info.bidAmount or 0
            local wait = info.timeLeftSeconds or Ledger.HOLD
            pend[#pend + 1] = { name = name, got = math.floor(amount * (1 - AH_CUT)), due = time() + wait }
            if name then
                soldAt[name] = soldAt[name] or {}
                table.insert(soldAt[name], time() - math.max(0, Ledger.HOLD - wait))      -- 真正卖出的时刻
            end
        end
    end
    Ledger.pend = { at = time(), list = pend }
    Ledger.Build()
    local newest = {}                                                        -- 每个名字最近挂的那一笔：它的剩余时间最长，拿来学时长
    for i = #(Ledger.rows or {}), 1, -1 do
        local r = Ledger.rows[i]
        if r.status == "open" and r.name then newest[r.name] = r end
    end
    for name, r in pairs(newest) do if (left[name] or 0) > 0 then Ledger.LearnDur(r.durIdx, r.posted, left[name]) end end
    Ledger.Build()                                                           -- 时长可能刚学到，重配一遍
    local n, unknown = 0, {}
    for i = #(Ledger.rows or {}), 1, -1 do                                   -- rows 是新的在前，倒着走 = 先挂的先算
        local r = Ledger.rows[i]
        if r.status == "open" and r.name then
            if (active[r.name] or 0) > 0 then
                active[r.name] = active[r.name] - 1
            elseif soldAt[r.name] and #soldAt[r.name] > 0 then               -- 拍卖行明说它卖了（钱还押着）：准
                Ledger.stamp = table.remove(soldAt[r.name], 1)
                if Ledger.stamp < (r.posted or 0) then Ledger.stamp = nil end
                LAdd("SOLD", 0, 0, 1, 0, r.name, "拍卖行")
                Ledger.stamp = nil
                n = n + 1
            elseif time() - (r.posted or 0) >= (r.dur or 24) * 3600 - 300 then
                -- 挂满了时长才发现不见了，拍卖行也没报它卖出：可能中途卖了、钱早寄走了，也可能到期流拍了。分不清，先记去向不明
                unknown[#unknown + 1] = r.name
            elseif time() - (r.posted or 0) > 20 then                        -- 没到期就不见了：只能是卖掉（撤单另有记录）
                LAdd("SOLD", 0, 0, 1, 0, r.name, "补记")
                n = n + 1
            end
        end
    end
    for _, name in ipairs(unknown) do LAdd("UNKNOWN", 0, 0, 1, 0, name, "") end
    if n > 0 or #unknown > 0 then
        print(string.format("|cff55ccffFQ|r 买卖记录对账：补记卖出 %d 笔%s。", n,
            #unknown > 0 and string.format("；另有 %d 件到期后不见了，分不清是卖了还是流拍，记成去向不明，取信后会自动判明", #unknown) or ""))
    end
    Ledger.FixHistory()
    Ledger.bagAt = GetTime() + 0.5
end

-- 拍卖时长的三档各是几小时：不同版本的客户端不一样（12/24/48 或 2/8/24），所以从"我的拍卖"里的剩余时间学，学到之前按 12/24/48 算
function Ledger.DurHours(idx)
    local learned = ForeverQuantDB and ForeverQuantDB.durHours
    return (learned and learned[idx]) or ({ 12, 24, 48 })[idx] or 24
end
function Ledger.LearnDur(idx, posted, left)
    if not idx or not posted or not left or left <= 0 then return end
    local h, best = (time() - posted + left) / 3600, nil
    for _, c in ipairs({ 2, 8, 12, 24, 48 }) do if math.abs(h - c) <= c * 0.1 + 0.2 and (not best or math.abs(h - c) < math.abs(h - best)) then best = c end end
    if best then
        ForeverQuantDB.durHours = ForeverQuantDB.durHours or {}
        ForeverQuantDB.durHours[idx] = best
    end
end

-- 一次性更正老账：早先的版本把"挂满时长后不见了"的一律推断成卖出，流拍的也算进去了，卖出和净赚都虚高。
-- 学到真实的拍卖时长之后，把这些推断卖出里"拖到到期以后才记上"的改成去向不明（之后由信件 / 背包 / 重新上架判明）。
-- 货只有三个去处：在手里（背包 / 待上架）、挂在拍卖行、卖掉了。所以对每一种货（按名字）：
--     卖掉的件数 = 买进的件数 - 现在挂着的 - 自己留用的 - 手里的
-- 手里没有这种货的时候，拿这条等式去核「去向不明」的那几笔：等式说卖了几件，就有几笔算卖出（取最近的几笔），
-- 其余的是流拍后又重新挂上了（那一次上架没卖成）。等式说账上卖多了，就把推断出来的卖出改回流拍。
-- 这是推出来的，所以留着记号：以后货要是在背包或信箱里冒出来，还会再更正。
-- 不是买来的货（自己打的、做的）没有"买进几件"可对，去向不明的只能按卖出算。
function Ledger.SettleUnknown(why, only)
    Ledger.Build()
    local inBag = Ledger.BagNames()
    local hold, bought, cnt = {}, {}, {}
    for _, h in ipairs(ForeverQuantDB.holdings or {}) do if h.name then hold[h.name] = (hold[h.name] or 0) + 1 end end
    for _, line in ipairs(ForeverQuantDB.ledger or {}) do
        local kind, qty, name = string.match(line, "^%d+|(%u+)|%d+|%-?%d+|(%d+)|%d+|([^|]*)")
        if kind == "BUY" then bought[name] = (bought[name] or 0) + (tonumber(qty) or 1) end
    end
    for i = #(Ledger.rows or {}), 1, -1 do                 -- 旧的在前
        local r = Ledger.rows[i]
        if r.name then
            cnt[r.name] = cnt[r.name] or { open = 0, sold = 0, used = 0, unknown = {}, fix = 0 }
            local c = cnt[r.name]
            if r.status == "used" then c.used = c.used + 1
            elseif r.price and r.status == "open" then c.open = c.open + (r.qty or 1)
            elseif r.price and r.status == "sold" then c.sold = c.sold + (r.qty or 1); if r.fix then c.fix = c.fix + 1 end
            elseif r.status == "unknown" then c.unknown[#c.unknown + 1] = r end
        end
    end
    local nSold, nBack, nUndo = 0, 0, 0
    for name, c in pairs(cnt) do
        if (#c.unknown > 0 or c.fix > 0) and (not only or only[name]) and (inBag[name] or 0) == 0 and (hold[name] or 0) == 0 then
            local u, sell = #c.unknown, #c.unknown
            if bought[name] then
                local need = bought[name] - c.open - c.used - c.sold      -- 等式说还应该有几笔卖出
                sell = math.max(0, math.min(u, need))
                for _ = 1, math.min(c.fix, math.max(0, -need)) do          -- 账上卖多了：把推断的卖出改回流拍
                    LAdd("UNSOLD", 0, 0, 1, 0, name, "按件数核对")
                    nUndo = nUndo + 1
                end
            end
            for idx = 1, u - sell do                                       -- 较早的几笔：流拍后重挂了
                LAdd("FOUND", c.unknown[idx].item_id or 0, 0, 1, 0, name, "按件数核对")
                nBack = nBack + 1
            end
            for idx = u - sell + 1, u do                                   -- 最近的几笔：卖掉了
                Ledger.stamp = c.unknown[idx].ended
                LAdd("PAID", 0, 0, 1, 0, name, "按件数核对")
                Ledger.stamp = nil
                nSold = nSold + 1
            end
        end
    end
    if nSold + nBack + nUndo > 0 then
        print(string.format("|cff55ccffFQ|r %s：按「买进 - 挂着 = 卖掉」逐种核对，%d 笔去向不明的算卖出，%d 笔是流拍后重挂的%s。", why or "对账", nSold, nBack,
            nUndo > 0 and string.format("；另有 %d 笔以前推断的卖出其实没卖，改回流拍", nUndo) or ""))
        if frame:IsShown() then Refresh() end
    end
    return nSold + nBack + nUndo
end
function Ledger.FixHistory()
    if ForeverQuantDB and ForeverQuantDB.fixedUnknown and not ForeverQuantDB.settledOld then
        ForeverQuantDB.settledOld = true
        Ledger.SettleUnknown("老账")                       -- 之前那次更正留下的去向不明，一次性结掉
    end
    if not ForeverQuantDB or ForeverQuantDB.fixedUnknown or not ForeverQuantDB.durHours then return 0 end
    Ledger.Build()
    local names = {}
    for _, r in ipairs(Ledger.rows or {}) do
        if r.status == "sold" and r.fix and r.name and (r.took or 0) >= (r.dur or 24) * 3600 - 300 then names[#names + 1] = r.name end
    end
    for _, name in ipairs(names) do LAdd("UNKNOWN", 0, 0, 1, 0, name, "fix") end
    ForeverQuantDB.fixedUnknown, ForeverQuantDB.settledOld = true, true
    Ledger.SettleUnknown("老账")
    if #names > 0 then
        print(string.format("|cff55ccffFQ|r 更正老账：有 %d 笔以前记成「已卖出」的，其实是挂满 %d 小时后才不见的，分不清卖没卖，改成去向不明。经营总览里的卖出和净赚会相应减少。",
            #names, Ledger.DurHours(2)))
    end
    return #names
end

-- 信件给准信：拍卖成功的信带一张发票（卖了什么、卖了多少钱）；流拍的信是拍卖行寄回来的物品、没有发票。
-- 只用来判明「去向不明」的那些，别的不动。同一封信只认一次（按物品、金额、到期时间记）。
function Ledger.MailScan()
    if not (GetInboxNumItems and GetInboxHeaderInfo and ForeverQuantDB and ForeverQuantDB.ledger) then return 0, 0 end
    Ledger.Build()
    local unk = {}
    for _, r in ipairs(Ledger.rows or {}) do if r.status == "unknown" and r.name then unk[r.name] = (unk[r.name] or 0) + 1 end end
    if not next(unk) then return 0, 0 end
    ForeverQuantDB.mailSeen = ForeverQuantDB.mailSeen or {}
    local seen, paid, back = ForeverQuantDB.mailSeen, 0, 0
    local function fresh(kind, name, amount, daysLeft)
        local b = math.floor((time() + (daysLeft or 0) * 86400) / 900)
        for d = -1, 1 do if seen[kind .. "|" .. name .. "|" .. amount .. "|" .. (b + d)] then return false end end
        seen[kind .. "|" .. name .. "|" .. amount .. "|" .. b] = time()
        return true
    end
    Ledger.quiet = true
    for i = 1, (GetInboxNumItems() or 0) do
        local _, _, sender, _, _, _, daysLeft, itemCount = GetInboxHeaderInfo(i)
        local invoiceType, itemName, _, bid, buyout = nil, nil, nil, nil, nil
        if GetInboxInvoiceInfo then invoiceType, itemName, _, bid, buyout = GetInboxInvoiceInfo(i) end
        if invoiceType == "seller" and itemName and (unk[itemName] or 0) > 0 then
            if fresh("S", itemName, buyout or bid or 0, daysLeft) then
                local sent = time() + (daysLeft or 30) * 86400 - 30 * 86400      -- 拍卖行的信留 30 天：倒推寄出的时刻，再减去押的一小时
                Ledger.stamp = math.min(time(), sent - Ledger.HOLD)
                LAdd("PAID", 0, 0, 1, buyout or bid or 0, itemName, "信件")
                Ledger.stamp = nil
                unk[itemName], paid = unk[itemName] - 1, paid + 1
            end
        elseif not invoiceType and (itemCount or 0) > 0 and GetInboxItem and type(sender) == "string"
            and (string.find(sender, "拍卖", 1, true) or string.find(sender, "Auction", 1, true)) then
            local name = GetInboxItem(i, 1)
            if name and (unk[name] or 0) > 0 and fresh("E", name, 0, daysLeft) then
                if Ledger.Expired(name, "信件", "unknown") then unk[name], back = unk[name] - 1, back + 1 end
            end
        end
    end
    Ledger.quiet = nil
    if paid + back > 0 then
        print(string.format("|cff55ccffFQ|r 信箱里判明了去向不明的货：%d 件其实卖掉了，%d 件是流拍退回（取出来后会重新挂）。", paid, back))
        if frame:IsShown() then Refresh() end
    end
    -- 信箱里的信全都看得到（没有排在后面没显示的），而剩下这些去向不明的既没有退货信、也不在背包：只能是卖掉了
    local shown, total = GetInboxNumItems()
    if (total or shown or 0) <= (shown or 0) then
        local left = {}
        for name, n in pairs(unk) do if n > 0 then left[name] = true end end
        if next(left) then paid = paid + Ledger.SettleUnknown("信箱里没有退货", left) end
    end
    return paid, back
end

-- 把流水配成一笔笔交易：同名物品先挂的先卖；买入价取这件物品（同 ID 同后缀）最近一次还没用掉的买入
function Ledger.Build()
    local lots, posts, out, usedRows = {}, {}, {}, {}
    local sum = { sold = 0, net = 0, noCost = 0, open = 0, expired = 0, tookSum = 0, hours = {} }
    for _, line in ipairs((ForeverQuantDB and ForeverQuantDB.ledger) or {}) do
        local t, kind, id, suffix, qty, total, name, extra = string.match(line, "^(%d+)|(%u+)|(%d+)|(%-?%d+)|(%d+)|(%d+)|([^|]*)|?(.*)$")
        t, id, suffix, qty, total = tonumber(t), tonumber(id), tonumber(suffix), tonumber(qty), tonumber(total)
        if kind == "BUY" then
            local key = id .. ":" .. suffix
            lots[key] = lots[key] or {}
            table.insert(lots[key], { t = t, unit = total / math.max(1, qty), left = qty, name = name })
        elseif kind == "POST" then
            local cost
            local ls = lots[id .. ":" .. suffix]
            if ls then
                for pass = 1, 2 do                          -- 同一个物品 ID 下有不同后缀的货：先配同名的批次，配不到再配别的
                  for _, lot in ipairs(ls) do
                    if lot.left > 0 and (pass == 2 or lot.name == name) then
                        local take = math.min(lot.left, qty)
                        lot.left = lot.left - take
                        cost = (cost or 0) + lot.unit * take
                        if take >= qty then break end
                    end
                  end
                  if cost then break end
                end
            end
            if not cost and usedRows[name] then
                -- 标成"自用"的那件其实后来挂出去了（自用的东西不会出现在拍卖行）：那条自用作废，成本接到这一笔
                for i = #usedRows[name], 1, -1 do
                    local ur = usedRows[name][i]
                    if ur.status == "used" then cost, ur.status = ur.cost, "restocked" break end
                end
            end
            if not cost and posts[name] then
                -- 没有买入批次可配，而同名的上一笔是"推断卖出"或"去向不明"、当初又确实是买来的：
                -- 那就是同一件东西流拍后又挂了一次（卖掉的东西不可能再挂）。把上一笔改成流拍，成本接过来。
                for i = #posts[name], 1, -1 do
                    local pr = posts[name][i]
                    if pr.cost and ((pr.status == "sold" and pr.fix) or pr.status == "unknown") then
                        cost = pr.cost
                        pr.status, pr.ended, pr.sold, pr.took, pr.net, pr.fix, pr.inferred = "expired", t, nil, nil, nil, nil, true
                        break
                    end
                end
            end
            local row = { name = name, item_id = id, suffix_id = suffix, qty = qty, price = total, cost = cost, posted = t, status = "open",
                          durIdx = tonumber(string.match(extra or "", "dur=(%d+)")) or 2,
                          dep = tonumber(string.match(extra or "", "dep=(%d+)")) or 0,
                          dur = Ledger.DurHours(tonumber(string.match(extra or "", "dur=(%d+)")) or 2) }      -- 挂了多少小时到期
            posts[name] = posts[name] or {}
            table.insert(posts[name], row)
            out[#out + 1] = row
        elseif kind == "RESTOCK" then              -- 之前标成自用的，又拿出来卖：成本放回去（不算新花的钱）
            lots[id .. ":" .. suffix] = lots[id .. ":" .. suffix] or {}
            table.insert(lots[id .. ":" .. suffix], { t = t, unit = total, left = 1, name = name })
            for _, r in ipairs(out) do
                if r.status == "used" and r.name == name then r.status = "restocked" break end
            end
        elseif kind == "VENDOR" then               -- 卖给商人了：销掉买入批次，按商人收的钱算
            local cost
            for _, ls in pairs(lots) do
                for _, lot in ipairs(ls) do
                    if not cost and lot.left > 0 and lot.name == name then lot.left = lot.left - 1; cost = lot.unit end
                end
            end
            out[#out + 1] = { name = name, item_id = id, qty = 1, price = total, cost = cost, posted = t, sold = t, status = "vendor",
                              net = cost and (total - cost) or nil }
        elseif kind == "USED" then                 -- 不卖了：把对应的买入批次销掉，不再算压货
            local cost
            for _, ls in pairs(lots) do
                for _, lot in ipairs(ls) do
                    if not cost and lot.left > 0 and lot.name == name then
                        lot.left = lot.left - 1
                        cost = lot.unit
                    end
                end
            end
            -- 账上这件货没有"买了还没挂"的批次可销：说明它早就挂出去了，这条"自用"是清掉一条多记的待上架时误记的。不算数
            if cost then
                local ur = { name = name, item_id = id, qty = 1, cost = cost, posted = t, status = "used" }
                out[#out + 1] = ur
                usedRows[name] = usedRows[name] or {}
                table.insert(usedRows[name], ur)
            else
                sum.ghostUsed = (sum.ghostUsed or 0) + 1
            end
        elseif kind == "UNKNOWN" or kind == "FOUND" or kind == "PAID" then
            -- 去向不明：挂满时长后不见了，拍卖行也没报它卖出——可能早卖了钱已寄出，也可能流拍退在邮箱里。不算卖出也不算流拍，
            -- 等信件或背包给出准信：FOUND = 是流拍（货回来了）；PAID = 是卖出（收到了货款信）。
            local q, row = posts[name], nil
            if kind == "UNKNOWN" and extra == "fix" then                    -- 把以前推断成卖出的改回去向不明：取拖得最久的那笔
                for _, r in ipairs(q or {}) do
                    if r.status == "sold" and r.fix and (not row or (r.took or 0) > (row.took or 0)) then row = r end
                end
            elseif kind == "UNKNOWN" then
                for _, r in ipairs(q or {}) do if r.status == "open" then row = r break end end
            else
                for _, r in ipairs(q or {}) do if r.status == "unknown" then row = r break end end
            end
            if row then
                if kind == "UNKNOWN" then
                    row.status, row.ended, row.sold, row.took, row.net, row.fix = "unknown", t, nil, nil, nil, nil
                elseif kind == "PAID" then
                    row.status, row.sold, row.took, row.ended = "sold", t, math.max(0, t - row.posted), nil
                    row.fix = (extra ~= "信件") or nil              -- 排除法推出来的卖出：以后货要是又冒出来，还能改回流拍
                    if row.price and row.cost then row.net = math.floor(row.price * (1 - AH_CUT)) - row.cost end
                else
                    row.status, row.ended = "expired", t
                    if row.cost and row.item_id and row.item_id ~= 0 then
                        local key = row.item_id .. ":" .. (row.suffix_id or 0)
                        lots[key] = lots[key] or {}
                        table.insert(lots[key], 1, { t = row.posted, unit = row.cost / math.max(1, row.qty or 1), left = row.qty or 1, name = row.name })
                    end
                end
            end
        elseif kind == "UNSOLD" then               -- 更正：最近一笔补记的"已卖出"其实是流拍
            local q, row = posts[name], nil
            for i = #(q or {}), 1, -1 do if q[i].status == "sold" and q[i].fix then row = q[i] break end end
            if row then
                row.status, row.ended, row.sold, row.took, row.net, row.fix = "expired", t, nil, nil, nil, nil
                if row.cost and row.item_id and row.item_id ~= 0 then
                    local key = row.item_id .. ":" .. (row.suffix_id or 0)
                    lots[key] = lots[key] or {}
                    table.insert(lots[key], 1, { t = row.posted, unit = row.cost / math.max(1, row.qty or 1), left = row.qty or 1, name = row.name })
                end
            end
        elseif kind == "SOLD" or kind == "EXPIRED" or kind == "CANCEL" then
            local q = posts[name]
            local row
            if q then
                for _, r in ipairs(q) do if r.status == "open" then row = r break end end
            end
            if not row then            -- 没有对应的上架记录（装插件之前挂的）
                row = { name = name, item_id = 0, posted = t }
                out[#out + 1] = row
            end
            if kind == "SOLD" then
                row.status, row.sold, row.took = "sold", t, t - row.posted
                row.fix = (extra == "补记") or nil                 -- 不是亲眼看到卖出消息，是对账时推断的
                if row.price and row.cost then row.net = math.floor(row.price * (1 - AH_CUT)) - row.cost end
            else
                row.status, row.ended = kind == "EXPIRED" and "expired" or "cancelled", t
                if row.cost and row.item_id and row.item_id ~= 0 then        -- 货退回来了，还在你手里：成本放回去，重新上架时接着用
                    local key = row.item_id .. ":" .. (row.suffix_id or 0)
                    lots[key] = lots[key] or {}
                    table.insert(lots[key], 1, { t = row.posted, unit = row.cost / math.max(1, row.qty or 1), left = row.qty or 1, name = row.name })
                end
            end
        end
    end
    -- 补配：有的上架当时没配到买入成本（那一刻成本还挂在别的记录上，后来才更正回来）。
    -- 账尾还剩着同名的买入批次，就补给它，免得一边"缺买入价"、一边凭空多出一件"买了没挂"。
    for _, ls in pairs(lots) do
        for _, lot in ipairs(ls) do
            if lot.left > 0 and posts[lot.name] then
                for _, r in ipairs(posts[lot.name]) do
                    if lot.left > 0 and not r.cost and (r.qty or 1) <= lot.left
                        and (r.status == "open" or r.status == "sold" or r.status == "unknown") then
                        r.cost = lot.unit * (r.qty or 1)
                        lot.left = lot.left - (r.qty or 1)
                        if r.status == "sold" and r.price then r.net = math.floor(r.price * (1 - AH_CUT)) - r.cost end
                    end
                end
            end
        end
    end
    for key, ls in pairs(lots) do          -- 买了还没挂的
        for _, lot in ipairs(ls) do
            if lot.left > 0 then
                local id, suffix = string.match(key, "^(%d+):(%-?%d+)$")
                out[#out + 1] = { name = lot.name, item_id = tonumber(id), suffix_id = tonumber(suffix), qty = lot.left,
                                  cost = lot.unit * lot.left, posted = lot.t, status = "held" }
            end
        end
    end
    for _, r in ipairs(out) do
        if r.status == "sold" then
            sum.sold = sum.sold + 1
            if r.net then sum.net = sum.net + r.net else sum.noCost = sum.noCost + 1 end
            sum.tookSum = sum.tookSum + (r.took or 0)
            local h = tonumber(date("%H", r.sold))
            sum.hours[h] = (sum.hours[h] or 0) + 1
        elseif r.status == "open" then sum.open = sum.open + 1
        elseif r.status == "unknown" then sum.unknown = (sum.unknown or 0) + 1
        elseif r.status == "expired" then sum.expired = sum.expired + 1 end
    end
    sum.avgTook = sum.sold > 0 and sum.tookSum / sum.sold or nil
    for h, n in pairs(sum.hours) do
        if not sum.bestHourN or n > sum.bestHourN then sum.bestHour, sum.bestHourN = h, n end
    end
    local top = { held = 1, used = 2 }                     -- 手里没挂的、标成自用的排最前面：这两种是要你拿主意的
    table.sort(out, function(a, b)
        local pa, pb = top[a.status] or 9, top[b.status] or 9
        if pa ~= pb then return pa < pb end
        return (a.sold or a.posted or 0) > (b.sold or b.posted or 0)
    end)
    ledgerRows = out
    Ledger.rows = out
    return sum
end

-- 经营总览：把账本看成一个小商户的账。存货按买入成本算（不按挂牌价，没卖出去的不算赚到）。
--   资产 = 现金 + 压在货上的钱 + 垫着的押金
--   现金流 = 卖货收回 - 买货花掉 - 流拍/撤单赔掉的押金
-- 只统计账本里记到的买卖：装插件之前的货、钓来的鱼、分解出来的材料都不在里面。
Ledger.HOLD = 3600        -- 卖出后拍卖行扣押货款的时间（秒）
function Ledger.Stats()
    Ledger.Build()
    local rows = Ledger.rows or {}
    local dayStart = time() - (tonumber(date("%H")) * 3600 + tonumber(date("%M")) * 60 + tonumber(date("%S")))
    local S = { cash = GetMoney(), listedN = 0, listedCost = 0, listedAsk = 0, listedNoCost = 0, heldN = 0, heldCost = 0, depHeld = 0,
                transit = 0, transitN = 0, transitNext = nil, unkN = 0, unkAsk = 0, unkCost = 0,
                used = { 0, 0 }, usedN = { 0, 0 }, vendorN = { 0, 0 }, buy = { 0, 0 }, back = { 0, 0 }, depLost = { 0, 0 }, profit = { 0, 0 }, sold = { 0, 0 }, failed = { 0, 0 }, tookSum = 0 }
    local function add(t, when, v) t[2] = t[2] + v; if when and when >= dayStart then t[1] = t[1] + v end end
    -- 没到账的钱：这次上线打开过拍卖行的话，用拍卖行"我的拍卖"里报的已售出条目（准）；没打开过只能按账本估
    -- 货值的底线：卖不掉时拿去卖商店能收回多少。买入成本是已经花出去的钱，不代表货还值那么多
    S.floor, S.floorUnknown = 0, 0
    local function floorOf(r)
        local v = r.item_id and r.item_id ~= 0 and select(11, ItemInfo(r.item_id))
        if v then S.floor = S.floor + v * (r.qty or 1) else S.floorUnknown = S.floorUnknown + (r.qty or 1) end
    end
    local inHand = Ledger.BagNames()                                -- 手里实际有的：背包里的 + 待上架名单上的（刚买还在邮箱的也在名单上）
    for _, h in ipairs(ForeverQuantDB.holdings or {}) do if h.name then inHand[h.name] = (inHand[h.name] or 0) + 1 end end
    S.goneN, S.goneCost = 0, 0
    local exact = Ledger.pend
    S.transitExact, S.transitAt = exact ~= nil, exact and exact.at
    for _, p in ipairs(exact and exact.list or {}) do
        if p.due > time() then
            S.transit, S.transitN = S.transit + p.got, S.transitN + 1
            if not S.transitNext or p.due < S.transitNext then S.transitNext = p.due end
        end
    end
    for _, line in ipairs((ForeverQuantDB and ForeverQuantDB.ledger) or {}) do          -- 买货的钱按流水算，最准
        local t, kind, total = string.match(line, "^(%d+)|(%u+)|%d+|%-?%d+|%d+|(%d+)|")
        if kind == "BUY" then add(S.buy, tonumber(t), tonumber(total)) end
    end
    for _, r in ipairs(rows) do
        if r.status == "open" then
            S.listedN = S.listedN + 1
            S.listedAsk = S.listedAsk + (r.price or 0)
            S.depHeld = S.depHeld + (r.dep or 0)
            if r.cost then S.listedCost = S.listedCost + r.cost else S.listedNoCost = S.listedNoCost + 1 end
            floorOf(r)
        elseif r.status == "unknown" then
            S.unkN, S.unkAsk, S.unkCost = S.unkN + 1, S.unkAsk + (r.price or 0), S.unkCost + (r.cost or 0)
        elseif r.status == "held" then
            -- 账上"买了没挂"，但背包里没有、也不在待上架里：货已经不在你手里了，只是怎么出去的没记到（分解、卖店、送人……）。单列，不算压货
            local q = r.qty or 1
            local have = math.min(q, (inHand[r.name or ""] or 0))
            inHand[r.name or ""] = (inHand[r.name or ""] or 0) - have
            if have < q then
                S.goneN, S.goneCost = S.goneN + (q - have), S.goneCost + math.floor((r.cost or 0) * (q - have) / q)
            end
            if have > 0 then
                S.heldN = S.heldN + have
                S.heldCost = S.heldCost + math.floor((r.cost or 0) * have / q)
                floorOf(r)
            end
        elseif r.status == "sold" then
            local got = math.floor((r.price or 0) * (1 - AH_CUT))
            local due = (r.sold or 0) + Ledger.HOLD                 -- 卖出后拍卖行押一小时，钱才寄到邮箱
            if exact then
                add(S.back, math.min(due, time()), got)             -- 没到账的另按拍卖行报的算（见下）；这里只管现金流
            elseif due > time() then
                S.transit, S.transitN = S.transit + got, S.transitN + 1
                if not S.transitNext or due < S.transitNext then S.transitNext = due end
            else
                add(S.back, due, got)                               -- 到账了才算收回
            end
            add(S.sold, r.sold, 1)
            if r.net then add(S.profit, r.sold, r.net) end
            S.tookSum = S.tookSum + (r.took or 0)
        elseif r.status == "vendor" then            -- 卖店的钱当场到手
            add(S.back, r.sold, r.price or 0)
            add(S.vendorN, r.sold, 1)
            if r.net then add(S.profit, r.sold, r.net) end
        elseif r.status == "used" then
            add(S.used, r.posted, r.cost or 0)
            add(S.usedN, r.posted, 1)
        elseif r.status == "expired" or r.status == "cancelled" then
            add(S.depLost, r.ended, r.dep or 0)
            add(S.failed, r.ended, 1)
        end
    end
    S.cost = S.listedCost + S.heldCost                              -- 买这些货花掉的钱
    S.stock = S.floor                                               -- 货值按底线（商店收购价）算
    S.assets = S.cash + S.stock + S.depHeld + S.transit
    S.ifSold = S.cash + math.floor(S.listedAsk * (1 - AH_CUT)) + S.depHeld + S.transit      -- 没挂出去的货没有挂牌价，不计
    S.flow = { S.back[1] - S.buy[1] - S.depLost[1], S.back[2] - S.buy[2] - S.depLost[2] }
    -- 倒卖这门生意真正的成绩：卖出的净赚，减掉赔掉的押金。自用的货不算亏也不算赚，单列出来
    S.result = { S.profit[1] - S.depLost[1], S.profit[2] - S.depLost[2] }
    return S
end
local function Signed(c) return (c < 0 and "|cffff6060-" or "|cff40ff40+") .. SilverText(math.abs(c)) .. "|r" end
function Ledger.BizRows()
    local S = Ledger.Stats()
    local out = {}
    local function head(t) out[#out + 1] = { label = "|cffffd100" .. t .. "|r", a = "", b = "", note = "" } end
    local function row(label, a, b, note) out[#out + 1] = { label = "   " .. label, a = a or "", b = b or "", note = note or "" } end
    head("资产（现在）")
    row("现金", "", SilverText(S.cash), "背包里的金币")
    row("手里的货值（底线）", "", SilverText(S.stock), string.format("全卖给商店能收回的钱：在售 %d 件，没挂出去 %d 件%s",
        S.listedN, S.heldN, S.floorUnknown > 0 and string.format("（%d 件查不到商店价，按 0 算）", S.floorUnknown) or ""))
    row("这些货的买入成本", "", SilverText(S.cost), string.format("在售 %s，没挂出去 %s%s · 已经花出去的钱，不计入资产",
        SilverText(S.listedCost), SilverText(S.heldCost),
        S.listedNoCost > 0 and string.format("（另有 %d 件在售的没有买入记录）", S.listedNoCost) or ""))
    local src = S.transitExact and string.format("拍卖行 %s前报的数", Dur(math.max(0, time() - S.transitAt)))
        or "按账本估的，不准；打开一次拍卖行就换成拍卖行报的数"
    row("卖了还没到账的钱", "", SilverText(S.transit), (S.transitN > 0
        and string.format("%d 笔，最近一笔 %s 后到 · ", S.transitN, Dur(math.max(0, S.transitNext - time())))
        or "现在没有在路上的 · ") .. src)
    if S.goneN > 0 then
        row("账上有、手里没有的货", "", string.format("%d 件", S.goneN), string.format("买入成本 %s。买了没挂过、现在也不在背包：怎么出去的没记到（分解、卖店、送人？）。不算压货",
            SilverText(S.goneCost)))
    end
    if S.unkN > 0 then
        row("去向不明的货", "", string.format("%d 件", S.unkN), string.format("到期后不见了，分不清卖没卖：挂牌 %s、成本 %s。没算进资产也没算进净赚；开信箱或取回背包后自动判明",
            SilverText(S.unkAsk), SilverText(S.unkCost)))
    end
    row("垫着的押金", "", SilverText(S.depHeld), "在售的货的上架押金；卖掉退回，流拍就没了")
    row("资产合计", "", "|cffffffff" .. SilverText(S.assets) .. "|r", string.format("货占 %.0f%%", S.assets > 0 and S.stock / S.assets * 100 or 0))
    row("如果在售的全按挂牌价卖光", "", SilverText(S.ifSold), string.format("挂牌总价 %s，扣完抽成；比现在多 %s（没挂出去的货不计）", SilverText(S.listedAsk), SilverText(math.max(0, S.ifSold - S.assets))))
    head("现金流")
    row("买货花掉", "-" .. SilverText(S.buy[1]), "-" .. SilverText(S.buy[2]),
        S.usedN[2] > 0 and string.format("其中 %s 是后来转自用的 %d 件", SilverText(S.used[2]), S.usedN[2]) or "")
    row("卖货收回（已到账）", "+" .. SilverText(S.back[1]), "+" .. SilverText(S.back[2]), "扣完 5% 抽成；到账是指寄到了邮箱，要去取信才进背包")
    row("流拍 / 撤单赔掉的押金", "-" .. SilverText(S.depLost[1]), "-" .. SilverText(S.depLost[2]))
    row("垫着没退的押金", "", "-" .. SilverText(S.depHeld), "在售的货的押金，现在不在你手里")
    row("净现金流", Signed(S.flow[1]), Signed(S.flow[2] - S.depHeld), "累计这个数 ≈ 你的现金比开始倒卖时多了多少（还没取的信、修理学技能等别的收支不在内）")
    head("经营")
    row("已实现净赚", Signed(S.profit[1]), Signed(S.profit[2]), "卖出到手 - 买入成本；只算有买入记录的")
    row("赔掉的押金", "-" .. SilverText(S.depLost[1]), "-" .. SilverText(S.depLost[2]))
    row("倒卖净成绩", Signed(S.result[1]), Signed(S.result[2]), "已实现净赚 - 赔掉的押金")
    row("转自用的货（按成本）", SilverText(S.used[1]) .. " / " .. S.usedN[1] .. " 件", SilverText(S.used[2]) .. " / " .. S.usedN[2] .. " 件",
        "买来没卖、自己留着用了：钱花了，但不算倒卖的亏损，也不算压货")
    row("卖不掉最后卖店的", S.vendorN[1] .. " 件", S.vendorN[2] .. " 件", "亏的部分已经算在上面的净赚里")
    row("卖出笔数", tostring(S.sold[1]), tostring(S.sold[2]), S.sold[2] > 0 and ("平均 " .. Dur(S.tookSum / S.sold[2]) .. " 卖掉") or "")
    row("流拍 / 撤单笔数", tostring(S.failed[1]), tostring(S.failed[2]),
        (S.sold[2] + S.failed[2]) > 0 and string.format("售出率 %.0f%%", S.sold[2] / (S.sold[2] + S.failed[2]) * 100) or "")
    return out, S
end

--------------------------------------------------------------------------------
-- 垃圾鱼：钓鱼时自动扔掉你标记过的东西，腾背包。销毁不可恢复，所以规矩很死：
--   只扔在钓鱼页里被你标成"会扔"的物品；只扔灰色和白色品质的；只在钓鱼开着、背包空位不多时扔。
-- 销毁必须由按键触发，所以走动作键：有东西要扔时亮信号，agent 按一下扔一堆。
--------------------------------------------------------------------------------
local Junk = { freeBelow = 4 }
ForeverQuantJunk = Junk
function Junk.Toggle(id)
    ForeverQuantDB.junk = ForeverQuantDB.junk or {}
    local name = ItemLink(id) or ("物品 " .. id)
    local _, _, quality = ItemInfo(id)
    if not ForeverQuantDB.junk[id] and (quality or 9) > 1 then
        print("|cff55ccffFQ|r " .. name .. " 不是灰色或白色品质，不允许标成自动扔。")
        return
    end
    ForeverQuantDB.junk[id] = not ForeverQuantDB.junk[id] or nil
    print("|cff55ccffFQ|r " .. name .. (ForeverQuantDB.junk[id] and " 已标记：钓鱼时背包快满会自动扔掉。" or " 已取消标记，会保留。"))
end
function Junk.Find()         -- 背包里第一堆该扔的：返回 背包, 格子, 物品ID, 数量
    local junk = ForeverQuantDB and ForeverQuantDB.junk
    if not junk or not next(junk) then return end
    local info = C_Container and C_Container.GetContainerItemInfo
    local slots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not info then return end
    for bag = 0, 4 do
        for slot = 1, (slots(bag) or 0) do
            local it = info(bag, slot)
            if it and junk[it.itemID] and (it.quality or 9) <= 1 and not it.isLocked then
                return bag, slot, it.itemID, it.stackCount or 1
            end
        end
    end
end
function Junk.Wanted() return fishingOn and FreeBagSlots() <= Junk.freeBelow and Junk.Find() ~= nil end
function Junk.DeleteOne()    -- 只能在按键回调里调用
    local bag, slot, id, n = Junk.Find()
    if not bag then return false end
    local name = ItemLink(id) or ("物品 " .. id)
    ClearCursor()
    C_Container.PickupContainerItem(bag, slot)
    if CursorHasItem() then
        DeleteCursorItem()
        ForeverQuantDB.junkLog = ForeverQuantDB.junkLog or {}
        table.insert(ForeverQuantDB.junkLog, string.format("%d|%d|%d", time(), id, n))
        print(string.format("|cff55ccffFQ|r 扔掉了 %s x%d（背包空位 %d）。", name, n, FreeBagSlots()))
        return true
    end
    ClearCursor()
    return false
end

ForeverQuantModes.Fish = function() SetFishing(not fishingOn) end
ForeverQuantModes.fishing = function() return fishingOn end
ForeverQuantModes.Snipe = function() Trade.Toggle(); if frame:IsShown() then Refresh() end end
ForeverQuantModes.sniping = function() return Trade.on end
ForeverQuantModes.Press = function() Trade.Toggle("auto"); if frame:IsShown() then Refresh() end end
ForeverQuantModes.pressing = function() return ForeverQuantDB and ForeverQuantDB.trade and ForeverQuantDB.trade.autoPress end
ForeverQuantModes.blueOn = function() return Trade.blueOn and true or false end
ForeverQuantModes.Blue = function()
    Trade.blueOn = not Trade.blueOn
    if Trade.blueOn and not ForeverQuantAction.key then ForeverQuantAction.Bind() end
    Trade.ctlScanAt, Trade.ctlSayAt = 0, 0
    for _, c in pairs(ForeverQuantDB.control or {}) do c.sig = nil end      -- 打开时先报一次现状
    print("|cff55ccffFQ|r 自动管理蓝装：" .. (Trade.blueOn and "开（拍卖行开着时后台扫蓝武、收明显的漏、管控价的货；和绿装的开关无关）" or "关（蓝武什么都不做）"))
    if frame:IsShown() then Refresh() end
end
ForeverQuantModes.sweeping = function() return not (ForeverQuantDB and ForeverQuantDB.trade and ForeverQuantDB.trade.sweepUnder == false) end      -- 没设过 = 开
ForeverQuantModes.Sweep = function()
    local cfg = TradeCfg()
    cfg.sweepUnder = not ForeverQuantModes.sweeping()
    print("|cff55ccffFQ|r 买断压价单：" .. (cfg.sweepUnder and "开（上架时碰到明显标错的一两件同款，直接买下来）" or "关（只贴着同款最低价挂，不买）"))
    if frame:IsShown() then Refresh() end
end

SLASH_FOREVERQUANT1 = "/fq"
-- 上架按钮现在该显示什么、能不能点
ForeverQuantModes.SellState = function()
    local hs = (ForeverQuantDB and ForeverQuantDB.holdings) or {}
    local inBag, nxt = 0, nil
    for _, h in ipairs(hs) do
        if Trade.Postable(h) and FindInBags(h.item_id, h.suffix_id, h.name) then
            inBag = inBag + 1
            nxt = nxt or h
        end
    end
    if Trade.batch then return string.format("集中上架中：还剩 %d 件（点这里停）", inBag), true end
    if #hs == 0 then return "上架背包里的货", true end
    if not nxt then return string.format("%d 件待上架：不在背包", #hs), true end       -- 还能点：再翻一遍背包找别的能上架的
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return string.format("%d 件待上架：先开拍卖行", inBag), false end
    if Trade.posting then return "正在挂……", false end
    if not PriceFresh(nxt) then return string.format("查同款价中……（%d 件）", inBag), inBag > 1 end      -- 多件时可以先点：价查好就开始挂
    if inBag > 1 then return string.format("集中上架 %d 件（先挂 %s）", inBag, SilverText(nxt.post)), true end
    return string.format("挂出 %s（共 %d 件）", SilverText(nxt.post), inBag), true
end

-- 买卖记录里逐件拿主意：手里没挂的 -> 不卖了（记成自用，从待上架里拿掉）；标成自用的 -> 再上架（放回待上架）
ForeverQuantModes.Relist = function(row)
    if not row or not row.name then return end
    ForeverQuantDB.holdings = ForeverQuantDB.holdings or {}
    local hs = ForeverQuantDB.holdings
    if row.status == "held" then
        for i, h in ipairs(hs) do if h.name == row.name then table.remove(hs, i) break end end
        ForeverQuantLedger.Add("USED", row.item_id, 0, 1, math.floor((row.cost or 0) / math.max(1, row.qty or 1)), row.name)
        print("|cff55ccffFQ|r " .. row.name .. "：不卖了，记成自用。")
    elseif row.status == "used" then
        local kn = Trade.Known(row.item_id, row.name)
        local cost = row.cost or 0
        local target = (kn and kn.target) or cost * 3      -- 名单上找不到当时的目标价就先按成本的 3 倍；真正挂的时候还会按同款重新定价
        ForeverQuantLedger.Add("RESTOCK", row.item_id, 0, 1, cost, row.name)
        Trade.AddHolding(row.item_id, kn and kn.suffix or 0, row.name, cost, target)
        print(string.format("|cff55ccffFQ|r %s：放回待上架，暂定 %s（挂之前会按同款重新定价）。%s", row.name, SilverText(target),
            FindInBags(row.item_id, kn and kn.suffix or 0, row.name) and "" or "它现在不在背包里。"))
    end
    Refresh()
end

ForeverQuantModes.ClearPending = function()
    local hs = ForeverQuantDB.holdings or {}
    if #hs == 0 then print("|cff55ccffFQ|r 没有待上架的东西。") return end
    -- 只有东西真的在背包里、你决定不卖了，才算"自用"。背包里根本没有的，是账上多记的一条，直接删掉，不记自用。
    local names, ghost, inBag = {}, 0, ForeverQuantLedger.BagNames()
    for _, h in ipairs(hs) do
        if h.name and (inBag[h.name] or 0) > 0 then
            inBag[h.name] = inBag[h.name] - 1
            names[#names + 1] = h.name
            ForeverQuantLedger.Add("USED", h.item_id, 0, 1, h.cost or 0, h.name)
        else
            ghost = ghost + 1
        end
    end
    ForeverQuantDB.holdings = {}
    Pricing.cur = nil
    print(string.format("|cff55ccffFQ|r 已清空待上架：%d 件在背包里的记成自用%s；%d 件背包里根本没有，是账上多记的，直接删掉。",
        #names, #names > 0 and ("（" .. table.concat(names, "、") .. "）") or "", ghost))
    Refresh()
end

ForeverQuantModes.Sell = function()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then print("|cff55ccffFQ|r 请先打开拍卖行，再点「上架背包里的货」。") return end
    if Trade.batch then                                    -- 正在集中上架：再点一次 = 停
        print(string.format("|cff55ccffFQ|r 集中上架已停：这一轮挂了 %d 件，还剩 %d 件。", Trade.batch.total - Trade.batch.left, Trade.batch.left))
        Trade.batch = nil
        Refresh()
        return
    end
    if Trade.posting then return end                       -- 上一件还在确认中
    local before = #(ForeverQuantDB.holdings or {})
    ForeverQuantLedger.BagCheck()                          -- 先把拍卖行退回来的认出来
    Trade.Adopt(before > 0)                                -- 第一次点才打印清单
    local n = 0
    for _, h in ipairs(ForeverQuantDB.holdings or {}) do
        if Trade.Postable(h) and FindInBags(h.item_id, h.suffix_id, h.name) then n = n + 1 end
    end
    local A = ForeverQuantAction
    if n > 1 and A and A.Online and A.Online() and A.keyIdx then      -- 两件以上、电脑端连着：开一轮集中上架，后面的由电脑端接着按
        Trade.batch = { total = n, left = n }
        print(string.format("|cff55ccffFQ|r 集中上架：背包里 %d 件待挂，查好价就一件件挂出去，挂完自己停。再点一次按钮可以中途停下。", n))
    elseif n > 1 then
        print("|cff55ccffFQ|r 电脑端程序没连上，没法连着挂：这次点一下挂一件。")
    end
    Trade.ctlOnly = nil
    DoPost(Trade.batch ~= nil)
    Refresh()
end

SlashCmdList["FOREVERQUANT"] = function(msg)
    local cmd, arg = string.match(string.lower(msg or ""), "^(%a*)%s*(%d*)")
    if cmd == "snipe" then
        Trade.Toggle(string.match(string.lower(msg or ""), "^%a+%s+(%a+)"))
    elseif cmd == "reprice" then                            -- /fq reprice 物品ID 件数 新价(银)   例：/fq reprice 9809 3 115；/fq reprice auto = 标高的全撤下来改价
        local id, n, silver = string.match(msg or "", "^%a+%s+(%d+)%s+(%d+)%s+(%d+)")
        if string.match(string.lower(msg or ""), "^%a+%s+auto") then
            if Trade.AutoReprice() == 0 then print("|cff55ccffFQ|r 没有挂得比自己卖出价高一半以上的（或者「我的拍卖」还没刷新，点开一次「拍卖」页签再试）。") end
        elseif id then Trade.Reprice(tonumber(id), tonumber(n), tonumber(silver) * 100)
        else print("|cff55ccffFQ|r 用法：/fq reprice 物品ID 件数 新价（银）。例：/fq reprice 9809 3 115 = 把 9809 里挂得最贵的 3 件撤下来按 1 金 15 银重挂。") end
    elseif cmd == "sell" then
        ForeverQuantModes.Sell()
    elseif cmd == "unsell" then
        ForeverQuantModes.ClearPending()
    elseif cmd == "holdings" then
        local hs = ForeverQuantDB.holdings or {}
        print(string.format("|cff55ccffFQ|r 待上架的持仓 %d 件：", #hs))
        for _, h in ipairs(hs) do print(string.format("   %s  买入 %s → 目标 %s", h.name or "?", SilverText(h.cost), SilverText(h.target))) end
    elseif cmd == "fish" then
        SetFishing(not fishingOn)
    elseif cmd == "demacro" then
        SetupDisenchantMacro(arg)
    elseif cmd == "scan" then
        ForeverQuantScan.Start()
    elseif cmd == "stop" then
        ForeverQuantScan.Stop()
    elseif cmd == "help" then
        print("|cff55ccffFQ|r /fq 打开列表 · /fq recipe 配方转卖 · /fq de 今天划算的分解 · /fq watch 我常分解的货 · /fq demacro [物品ID] 生成分解宏 · /fq fish 开始/停止钓鱼 · /fq snipe 开关自动买入（/fq snipe auto 开关自动上架）· /fq sell 把背包里名单上的货排队上架（/fq unsell 清空，/fq holdings 查看）· /fq scan 全量扫描（先打开拍卖行）· /fq stop 中断扫描")
    elseif cmd == "recipe" or cmd == "watch" or cmd == "de" then
        mode, offset = cmd, 0
        frame:Show(); Refresh()
    else
        Toggle()
    end
end

--------------------------------------------------------------------------------
-- 蓝色武器的面板：把每把的提示文字（伤害、速度、附加属性、装备效果）原样存下来，电脑端拿它按职业的用法给武器分类
-- （圣骑要高白字的慢速双手、盗贼主手要慢速高伤单手 / 副手要快匕首、法师要明确加法伤或智力的杖和单手）。
-- 物品信息要等客户端从服务器取回来，所以登录后分几次慢慢读，读到的就不再读。
--------------------------------------------------------------------------------
do
    ForeverQuantBlueTips = { frame = CreateFrame("Frame"), tries = 0, nextAt = 0 }      -- 主文件的局部变量已经到上限了，状态放表里
    ForeverQuantBlueTips.frame:SetScript("OnUpdate", function()
        local T = ForeverQuantBlueTips
        if not ForeverQuantDB or GetTime() < T.nextAt then return end
        T.nextAt = GetTime() + 3
        T.tries = T.tries + 1
        ForeverQuantDB.blueTips = ForeverQuantDB.blueTips or {}
        local tips, missing = ForeverQuantDB.blueTips, 0
        local ids = data.blue and data.blue.ref_ids
        if not ids then
            ids = {}
            for _, r in ipairs(data.blue and data.blue.items or {}) do ids[#ids + 1] = r.item_id end
        end
        local budget = 60                                   -- 一次最多新读 60 把，免得卡一下
        for _, id in ipairs(ids) do
            local r = { item_id = id }
            if not tips[r.item_id] and budget > 0 then
                budget = budget - 1
                local parts = {}
                if C_TooltipInfo and C_TooltipInfo.GetItemByID then
                    local d = C_TooltipInfo.GetItemByID(r.item_id)
                    for _, line in ipairs(d and d.lines or {}) do
                        local t = (line.leftText or "") .. ((line.rightText and line.rightText ~= "") and (" ~ " .. line.rightText) or "")
                        if t ~= "" then parts[#parts + 1] = (string.gsub(t, "[|\n\r\"\\]", " ")) end
                    end
                end
                if #parts >= 3 then tips[r.item_id] = table.concat(parts, " // ") else
                    missing = missing + 1
                    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, r.item_id) end
                end
            end
        end
        if (missing == 0 and budget > 0) or T.tries >= 60 then T.frame:SetScript("OnUpdate", nil) end
    end)
end
