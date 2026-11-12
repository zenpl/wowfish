-- ForeverQuant：展示 Python 生成的建议。只读行情、帮你搜索；不出价、不购买、不上架。
local ROWS, ROW_H, WIDTH, NCOL = 16, 22, 880, 8
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
local GAP_OK, GAP_BIG = 2.5, 4.0
local function Gap(op)
    if (op.max_unit_price or 0) <= 0 then return 0 end
    return (op.target_unit_price or 0) / op.max_unit_price
end
local function Verdict(op)
    if op.marked == "want" then return "buy" end
    if op.marked == "no" or op.peer == "flat" or op.strategy ~= "GEAR" then return "skip" end
    local stars, gap = op.stars or 1, Gap(op)
    if stars >= 3 then
        if gap < GAP_OK then return "hesitate" end
        return op.verified and "buy" or "look"
    end
    if stars == 2 and gap >= GAP_BIG then return op.verified and "buy" or "look" end
    return "skip"
end
ForeverQuantVerdict = Verdict       -- 给测试用
local VERDICT_TEXT = { buy = "|cff40ff40买|r", hesitate = "|cffffd040犹豫|r", look = "|cff55ccff值得看|r", skip = "|cff808080-|r" }

local function MarkKey(op) return op.item_id .. ":" .. (op.suffix_id or 0) end
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
        local m = marks[MarkKey(op)]
        if m == "want" then op.stars, op.verified, op.marked = 3, true, "want"
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
    local new = want and "want" or "no"
    if ForeverQuantDB.marks[k] == new then new = nil end   -- 再点一次同一个 = 取消标注
    ForeverQuantDB.marks[k] = new
    local clean = function(t) return (string.gsub(tostring(t or ""), "|", "/")) end
    table.insert(ForeverQuantDB.corrections, table.concat({ "#MARK", time(), new or "clear", op.item_id, op.suffix_id or 0,
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
                return (g >= GAP_BIG and "|cff40ff40" or (g >= GAP_OK and "|cffffffff" or "|cffff8040")) .. string.format("%.1f倍|r", g) end },
            { "星级", 526, 50, function(op) return Stars(op.stars) end },
            { "建议", 580, 50, function(op) return VERDICT_TEXT[Verdict(op)] end },
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
                if r.status ~= "sold" then return "-" end
                if not r.cost then return "|cff808080缺买入价|r" end
                return (r.net >= 0 and "|cff40ff40+|r" or "") .. Silver(r.net) end },
            { "多久卖掉", 478, 90, function(r) return r.status == "sold" and Dur(r.took) or (r.status == "open" and ("已挂 " .. Dur(time() - r.posted)) or "-") end },
            { "卖出时间", 572, 110, function(r) return r.sold and date("%m-%d %H:%M", r.sold) or "-" end },
            { "状态", 686, 180, function(r)
                if r.status == "sold" then return "|cff40ff40已卖出|r" end
                if r.status == "open" then return "|cffffd040在售|r" end
                if r.status == "expired" then return "|cffff6060流拍|r" end
                if r.status == "cancelled" then return "|cffaaaaaa已撤单|r" end
                return "|cffaaaaaa只买未挂|r" end },
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
local SCENE = { fish = "fish", de = "de", watch = "de", gear = "trade", recipe = "trade", ledger = "trade", tod = "trade" }
local lastMode = { fish = "fish", de = "de", trade = "gear" }
local function Go(m) mode, offset = m, 0; lastMode[SCENE[m]] = m; Refresh() end
local sceneFish = MakeTab("蹲点钓鱼", 10, 110, function() Go(lastMode.fish) end, ROW1, true)
local sceneDe = MakeTab("分解套利", 124, 110, function() Go(lastMode.de) end, ROW1, true)
local sceneTrade = MakeTab("倒卖套利", 238, 110, function() Go(lastMode.trade) end, ROW1, true)
local tabGear = MakeTab("", 10, 120, function() Go("gear") end)
local tabRecipe = MakeTab("", 134, 120, function() Go("recipe") end)
local tabLedger = MakeTab("买卖记录", 258, 90, function() Go("ledger") end)
local tabTod = MakeTab("各时段价格", 352, 96, function() Go("tod") end)
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
    GameTooltip:AddLine("同款挂价由插件在后台自己查，查好后按钮会变成「挂出 xx」，这时点一次挂一件。右下角「自动上架」开着的话不用点，会自动挂完。", 1, 1, 1, true)
    GameTooltip:Show()
end)
btnSell:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

local function RuleKey(classID, subclassID, equipLoc)
    if equipLoc == "INVTYPE_CLOAK" or equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_NECK" then return "jewelry_cloak", "首饰/披风" end
    if classID == 2 then return "weapon", "武器" end
    if classID == 4 then
        if subclassID == 1 then return "cloth", "布甲" end
        if subclassID == 2 then return "leather", "皮甲" end
        if subclassID == 3 then return "mail", "锁甲" end
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
        local T = ForeverQuantTrade
        if T then                      -- 你标过「要」的，重扫后又出现新挂单：直接去买（同一条挂单只买一次）
            for _, op in ipairs(gearAll) do
                if op.marked == "want" and op.ikey and not (op.key and T.done[op.key]) then T.BuyNow(op) end
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
            elseif P and P.Busy() then txt = string.format("快扫 %d/%d", P.n - #P.queue, P.n)
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
    tabLedger:SetEnabled(mode ~= "ledger"); tabTod:SetEnabled(mode ~= "tod")
    tabDe:SetText(string.format("今天划算的 (%d)", #deList))
    tabWatch:SetText(string.format("我常分解的 (%d)", #watches))
    tabGear:SetEnabled(mode ~= "gear"); tabRecipe:SetEnabled(mode ~= "recipe"); tabDe:SetEnabled(mode ~= "de")
    tabWatch:SetEnabled(mode ~= "watch")
    local scene = SCENE[mode]
    sceneFish:SetEnabled(scene ~= "fish"); sceneDe:SetEnabled(scene ~= "de"); sceneTrade:SetEnabled(scene ~= "trade")
    for b, sc in pairs({ [tabGear] = "trade", [tabRecipe] = "trade", [tabLedger] = "trade", [tabTod] = "trade", [tabDe] = "de", [tabWatch] = "de" }) do
        if sc == scene then b:Show() else b:Hide() end
    end
    -- 各场景自己的开关只在自己的页签里出现
    if mode == "gear" then btnNow:Show() else btnNow:Hide() end
    if scene == "trade" then btnAuto:Show() else btnAuto:Hide() end
    foot:Hide()        -- 底部那行说明放不下整句，去掉了；要点都在各按钮的鼠标提示里
    credit:SetText("")        -- 界面上不显示数据来源（用户决定）
    if scene == "fish" then modeFish:Show() else modeFish:Hide() end
    if scene == "trade" then modeSnipe:Show(); modePress:Show() else modeSnipe:Hide(); modePress:Hide() end
    if scene == "fish" then btnScan:Hide() else btnScan:Show() end
    if scene == "trade" then
        local text, can = "上架背包里的货", true
        if ForeverQuantModes.SellState then text, can = ForeverQuantModes.SellState() end
        btnSell:SetText(text); btnSell:SetEnabled(can)
        btnSell:Show()
    else
        btnSell:Hide()
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
        local quick = (P and P.doneAt) and string.format(" · 快扫 %d 秒前（%d 件，用时 %d 秒%s）", GetTime() - P.doneAt, P.n, P.took or 0,
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
                r.nav:SetText(op.marked == "want" and "|cff40ff40要|r" or (op.marked == "no" and "|cffff6060不要|r" or "|cff808080标|r"))
                r.nav:Show()
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
        if mode ~= "gear" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("左键：要（直接三星）", 0.25, 1, 0.25)
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
-- 保险：只买"已验证"的、星级够的；实时价格高于建议买价就跳过；有本次预算上限；每笔都记进存盘。
--------------------------------------------------------------------------------
local Trade = { queue = {}, done = {}, state = "idle", spent = 0, on = false }
local Pricing = { cur = nil, since = 0 }       -- 上架前查同款挂价（实现在上架那一段）
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
        if op.ikey and Verdict(op) == "buy" and not Trade.done[op.key] then
            Trade.done[op.key] = true
            Trade.queue[#Trade.queue + 1] = op
            added = added + 1
        end
    end
    return added
end

-- 你标了「要」：插到队首马上去买，不管「自动买入」开没开。价格核对、金币和预算的保险照旧。
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
    if not Trade.on then Trade.budget = math.max(Trade.budget or 0, Trade.spent + math.floor(GetMoney() * 0.8)) end
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

local function TradeSkip(why)
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
            if c and now - c.t < PEER_TTL then PeerApply(op, c) else Peer.queue[#Peer.queue + 1] = op end
        end
    end
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

local peerFrame, peerTick = CreateFrame("Frame"), 0
pcall(peerFrame.RegisterEvent, peerFrame, "ITEM_SEARCH_RESULTS_UPDATED")
peerFrame:SetScript("OnEvent", function()
    local op = Peer.cur
    if not op then return end
    local prices = {}
    for i = 1, (C_AuctionHouse.GetNumItemSearchResults(op.ikey) or 0) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(op.ikey, i)
        if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            prices[#prices + 1] = info.buyoutAmount
        end
    end
    table.sort(prices)
    Peer.cur = nil
    if prices[1] and prices[1] <= op.max_unit_price then                   -- 便宜的那件还在，剩下的才是"同款别人的挂价"
        local show = {}
        for i = 1, math.min(#prices, 8) do show[i] = SilverText(prices[i]) end
        local p = { t = GetTime(), n = #prices - 1, low = prices[2] or 0, text = table.concat(show, " / ") .. (#prices > 8 and " …" or "") }
        Peer.cache[op.key] = p
        PeerApply(op, p)
    end
    if #Peer.queue == 0 then PeerDone() end
end)
peerFrame:SetScript("OnUpdate", function(_, elapsed)
    peerTick = peerTick + elapsed
    if peerTick < 0.3 then return end
    peerTick = 0
    if Peer.cur then
        if GetTime() - Peer.since > 6 then Peer.cur = nil; if #Peer.queue == 0 then PeerDone() end end      -- 查询超时：跳过这条
        return
    end
    if #Peer.queue == 0 then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Peer.queue = {} return end
    if ForeverQuantScan.running or Trade.state ~= "idle" or Pricing.cur or Pool.cur or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    Peer.cur, Peer.since = table.remove(Peer.queue, 1), GetTime()
    if not pcall(C_AuctionHouse.SendSearchQuery, Peer.cur.ikey, {}, false) then Peer.cur = nil end
end)

--------------------------------------------------------------------------------
-- 高概率池快扫：不读整个拍卖行，只逐件去查"以前到过二星、三星的那些装备 + 后缀"（三星先查），
-- 加上你标过「要」的。查一件拿到的是它现在的全部挂单，所以同款印证顺手就做了。
-- 全量扫描只隔一段时间做一次，用来发现新面孔和刷新参照价。
--------------------------------------------------------------------------------
local POOL_MIN_STARS, POOL_GAP, POOL_MIN_PROFIT = 2, 2.0, 1500        -- 进池的最低历史星级；目标价至少是现价的几倍；最低净赚（铜）
function Pool.Busy() return Pool.cur ~= nil or #Pool.queue > 0 end
function Pool.Build()               -- 返回这一轮要查的名单（三星在前）
    local list, marks = {}, ForeverQuantDB.marks or {}
    for _, kn in pairs(ForeverQuantDB.known or {}) do
        if kn.id and kn.name then
            local mark = marks[kn.id .. ":" .. (kn.suffix or 0)]
            local best = (mark == "want") and 4 or (kn.best or kn.stars or 1)
            if mark ~= "no" and best >= POOL_MIN_STARS and (kn.suffix or 0) ~= 0 then
                local ilvl = kn.ilvl or select(4, ItemInfo(kn.id))
                if ilvl then list[#list + 1] = { kn = kn, best = best, ilvl = ilvl } end
            end
        end
    end
    table.sort(list, function(a, b) if a.best ~= b.best then return a.best > b.best end return (a.kn.t or 0) > (b.kn.t or 0) end)
    return list
end
function Pool.Size() return #Pool.Build() end
function Pool.Start()
    if Pool.Busy() then return false end
    Pool.queue, Pool.hits, Pool.timeouts, Pool.startedAt = Pool.Build(), 0, 0, GetTime()
    Pool.n = #Pool.queue
    return Pool.n > 0
end
-- 查到了某件池内装备现在的挂单（已按价格从低到高排好）：够便宜就做成一条候选
function Pool.Judge(e, prices)
    local kn, low = e.kn, prices[1]
    if not low then return nil end
    local profit = math.floor(kn.target * (1 - AH_CUT)) - low
    if low * POOL_GAP > kn.target or profit < POOL_MIN_PROFIT then return nil end
    local key = kn.id .. ":" .. (kn.suffix or 0) .. ":" .. low
    for _, op in ipairs(gearAll) do if op.key == key then return nil end end          -- 名单里已经有这条挂单了
    local op = { item_id = kn.id, suffix_id = kn.suffix or 0, name = kn.name, strategy = "GEAR", ikey = e.ikey, key = key,
        stars = kn.best or kn.stars or 1, verified = kn.verified and true or false, isNew = true,
        max_unit_price = low, target_unit_price = kn.target, max_quantity = 1, expected_profit = profit, score = 0,
        reason = string.format("高概率池 · 以前到过 %d 星", kn.best or kn.stars or 1),
        note = "这条是快扫查到的：目标价沿用它上次出现在名单里时的估价，没有重新按全市场算。" }
    local show = {}
    for i = 1, math.min(#prices, 8) do show[i] = SilverText(prices[i]) end
    Peer.Apply(op, { t = GetTime(), n = #prices - 1, low = prices[2] or 0, text = table.concat(show, " / ") })
    return op
end
local function PoolDone()
    if Pool.hits > 0 then
        ApplyMarks(gearAll); ApplyMarks(gearBudget)
        for _, op in ipairs(gearAll) do
            if op.marked == "want" and op.ikey and not (op.key and Trade.done[op.key]) then Trade.BuyNow(op) end
        end
        if Trade.on then Trade.Enqueue() end
        print(string.format("|cff55ccffFQ|r |cff40ff40快扫发现 %d 条|r（查了池里 %d 件）。", Pool.hits, Pool.n))
        if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
    end
    Pool.doneAt = GetTime()
    Pool.took = Pool.doneAt - (Pool.startedAt or Pool.doneAt)
    if frame:IsShown() then Refresh() end
end
local poolFrame, poolTick = CreateFrame("Frame"), 0
pcall(poolFrame.RegisterEvent, poolFrame, "ITEM_SEARCH_RESULTS_UPDATED")
poolFrame:SetScript("OnEvent", function()
    local e = Pool.cur
    if not e then return end
    local prices = {}
    for i = 1, (C_AuctionHouse.GetNumItemSearchResults(e.ikey) or 0) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(e.ikey, i)
        if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            prices[#prices + 1] = info.buyoutAmount
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
        if op.marked == "want" then Trade.BuyNow(op) elseif Trade.on then Trade.Enqueue() end      -- 不等这一轮查完，马上去买
    end
    if #Pool.queue == 0 then PoolDone() end
end)
poolFrame:SetScript("OnUpdate", function(_, elapsed)
    poolTick = poolTick + elapsed
    if poolTick < 0.2 then return end
    poolTick = 0
    if Pool.cur then
        if GetTime() - Pool.since > 3 then                  -- 没回应：记一笔，跳过
            Pool.cur, Pool.timeouts = nil, (Pool.timeouts or 0) + 1
            if #Pool.queue == 0 then PoolDone() end
        end
        return
    end
    if #Pool.queue == 0 then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Pool.queue = {} return end
    if ForeverQuantScan.running or Trade.state ~= "idle" or #Trade.queue > 0 or Peer.Busy() or Pricing.cur
        or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end           -- 买入、印证、定价都比快扫优先
    local e = table.remove(Pool.queue, 1)
    local ok, key = pcall(C_AuctionHouse.MakeItemKey, e.kn.id, e.ilvl, e.kn.suffix or 0)
    if not ok or not key then return end
    e.ikey = key
    Pool.cur, Pool.since = e, GetTime()
    if not pcall(C_AuctionHouse.SendSearchQuery, key, {}, false) then Pool.cur = nil end
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
    if not best then return TradeSkip("已经没有了") end
    if best.buyoutAmount > op.max_unit_price then
        return TradeSkip(string.format("现在最低 %s，高于建议买价 %s", SilverText(best.buyoutAmount), SilverText(op.max_unit_price)))
    end
    if best.buyoutAmount > GetMoney() then return TradeSkip("金币不够") end
    if Trade.spent + best.buyoutAmount > (Trade.budget or 0) then return TradeSkip("超过本次预算") end
    Trade.ready = { op = op, auctionID = best.auctionID, price = best.buyoutAmount }
    Trade.state = "ready"
    print(string.format("|cff55ccffFQ|r |cff40ff40待买|r %s %s  %s → 目标 %s。按 %s 买入。", Stars(op.stars), op.name or "?",
        SilverText(best.buyoutAmount), SilverText(op.target_unit_price), Trade.key or "买入键"))
    buySignal:ShowKey(Trade.keyIdx)        -- 进了"待买"的都是该买的（自动买入挑的，或你亲手标「要」的）：直接请电脑端按键
    if frame:IsShown() then Refresh() end
end)

local tradeTick = 0
tradeFrame:SetScript("OnUpdate", function(_, elapsed)
    tradeTick = tradeTick + elapsed
    if tradeTick < 0.3 then return end
    tradeTick = 0
    if not Trade.on and #Trade.queue == 0 and Trade.state == "idle" then return end      -- 关着时只处理你亲手标「要」的那几条
    local now = GetTime()
    if Trade.state == "idle" then
        if #Trade.queue > 0 and AuctionHouseFrame and AuctionHouseFrame:IsShown() and not ForeverQuantScan.running
            and not Pricing.cur and not Pool.cur and not Peer.Busy()        -- 先等同款印证查完，免得买到"同款都只值这个价"的
            and C_AuctionHouse.IsThrottledMessageSystemReady() then
            Trade.cur = table.remove(Trade.queue, 1)
            Trade.state, Trade.since = "searching", now
            local ok = pcall(C_AuctionHouse.SendSearchQuery, Trade.cur.ikey, {}, false)
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
            table.insert(ForeverQuantDB.holdings, h)
            TLog("BUY", r.op, r.price)
            print(string.format("|cff55ccffFQ|r |cff40ff40买到|r %s，花了 %s；本次已花 %s / 预算 %s。东西在邮箱里。",
                r.op.name or "?", SilverText(r.price), SilverText(Trade.spent), SilverText(Trade.budget)))
            Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
            if frame:IsShown() then Refresh() end
        elseif now - Trade.since > 6 then
            print("|cff55ccffFQ|r 没买到 " .. (r.op.name or "?") .. "（可能被别人抢先了）。")
            Trade.cur, Trade.ready, Trade.state = nil, nil, "idle"
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
function Trade.AddHolding(itemId, suffixId, name, cost, target)
    ForeverQuantDB.holdings = ForeverQuantDB.holdings or {}
    table.insert(ForeverQuantDB.holdings, { item_id = itemId, suffix_id = suffixId or 0, name = name, cost = cost, target = target, t = time() })
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
                    Trade.AddHolding(id, kn.suffix, name, kn.buy, kn.target)
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
    local changed = h.post ~= post
    h.post, h.priced_at = post, time()
    if changed then print(string.format("|cff55ccffFQ|r 定价 %s：%s → 挂 %s（原目标 %s，买入 %s）", h.name or "?", why, SilverText(post), SilverText(h.target), SilverText(h.cost))) end
end
Pricing.Decide = PriceDecide
ForeverQuantPricingDecide = PriceDecide        -- 给测试用
local PRICE_TTL = 300               -- 定价多久算过期（秒）；过期了后台会自己重查
local function PriceFresh(h) return h.post and h.priced_at and time() - h.priced_at < PRICE_TTL end
local function PriceReady(h)        -- 这件有新鲜的定价了吗？没有就发起一次查询
    if PriceFresh(h) then return true end
    if Pricing.cur then return false end
    local bag, slot = FindInBags(h.item_id, h.suffix_id, h.name)
    if not bag then return false end
    local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, ItemLocation:CreateFromBagAndSlot(bag, slot))
    if not ok or not key then h.post, h.priced_at = h.target, time() return true end      -- 查不了就用原目标价
    if ForeverQuantScan.running or Trade.state ~= "idle" or ForeverQuantPeer.cur or Pool.cur or not C_AuctionHouse.IsThrottledMessageSystemReady() then return false end
    Pricing.cur, Pricing.since = { h = h, key = key }, GetTime()
    if not pcall(C_AuctionHouse.SendSearchQuery, key, {}, false) then Pricing.cur = nil; h.post, h.priced_at = h.target, time() return true end
    return false
end
local pricingFrame = CreateFrame("Frame")
pcall(pricingFrame.RegisterEvent, pricingFrame, "ITEM_SEARCH_RESULTS_UPDATED")
pricingFrame:SetScript("OnEvent", function()
    local c = Pricing.cur
    if not c then return end
    local prices = {}
    for i = 1, (C_AuctionHouse.GetNumItemSearchResults(c.key) or 0) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(c.key, i)
        if info and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem and not info.containsAccountItem then
            prices[#prices + 1] = info.buyoutAmount
        end
    end
    table.sort(prices)
    Pricing.cur = nil
    PriceDecide(c.h, prices)
end)
pricingFrame:SetScript("OnUpdate", function()
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
            if (h.fail or 0) < 2 and not Trade.posting then
                if not PriceReady(h) then return end       -- 价还没查好：后台在查，查好后按钮会变成"挂出"
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                buySignal:Hide()
                local ok, err = pcall(C_AuctionHouse.PostItem, loc, 2, 1, nil, h.post)       -- 时长取中间一档
                if ok then
                    Trade.posting = { h = h, since = GetTime() }      -- 等物品真的离开背包才算挂上
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
    if Trade.posting then
        local h = Trade.posting.h
        if not FindInBags(h.item_id, h.suffix_id, h.name) then
            for i, x in ipairs(holdings) do if x == h then table.remove(holdings, i) break end end
            TLog("POST", h, h.post or h.target)
            print(string.format("|cff55ccffFQ|r |cff40ff40已上架|r %s，一口价 %s（买入价 %s）。还有 %d 件待挂。",
                h.name or "?", SilverText(h.post or h.target), SilverText(h.cost), #holdings))
            Trade.posting = nil
            if frame:IsShown() then Refresh() end
        elseif GetTime() - Trade.posting.since > 5 then
            h.fail = (h.fail or 0) + 1
            print(string.format("|cff55ccffFQ|r %s 没挂上（第 %d 次）。%s", h.name or "?", h.fail, h.fail >= 2 and "不再自动重试，请手动上架。" or ""))
            Trade.posting = nil
        end
        return
    end
    -- 后台定价：拍卖行开着、背包里有待上架的货，就主动把价查好（不用你点），按钮跟着变
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        for _, h in ipairs(holdings) do
            if (h.fail or 0) < 2 and not PriceFresh(h) and FindInBags(h.item_id, h.suffix_id, h.name) then PriceReady(h) break end
        end
    end
    if frame:IsShown() then
        local text = ForeverQuantModes.SellState()
        if text ~= Pricing.shown then Pricing.shown = text; Refresh() end
    end
    -- 自动上架：狙击开着、允许自动按键、拍卖行开着、当前没有待买的，而且背包里有持仓
    if (Trade.on or #holdings > 0) and TradeCfg().autoPress and Action.keyIdx and Trade.state == "idle"
        and AuctionHouseFrame and AuctionHouseFrame:IsShown() and not auto then
        for _, h in ipairs(holdings) do
            if (h.fail or 0) < 2 and FindInBags(h.item_id, h.suffix_id, h.name) then
                if not PriceReady(h) then return end       -- 先查同款定好价，再请电脑端按键
                Action.pinging = false
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
    Trade.budget = math.floor(GetMoney() * 0.8)
    local n = Trade.Enqueue()
    print(string.format("|cff55ccffFQ|r 自动买入已开启：只买「建议」一栏是「买」的，本次预算 %s（手头金币的八成）。动作键 %s（买入和上架都是它）。当前排队 %d 条。",
        SilverText(Trade.budget), Trade.key or "未绑定", n))
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
    lg[#lg + 1] = string.format("%d|%s|%d|%d|%d|%d|%s|%s", time(), kind, id or 0, suffix or 0, qty or 1, total or 0,
        string.gsub(name or "?", "|", "/"), extra or "")
    if frame:IsShown() and mode == "ledger" then Refresh() end
end

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
        LAdd("POST", id, suffix, quantity or 1, buyout or bid or 0, name, "dep=" .. dep)
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
    end
    if #pendingBuys == 0 then return end
    local now = GetTime()
    for i = #pendingBuys, 1, -1 do
        local b = pendingBuys[i]
        local spent = b.money - GetMoney()
        if spent > 0 and (not b.amount or spent >= b.amount) then        -- 钱真的扣了才算买到
            LAdd("BUY", b.id, b.suffix, b.qty, b.amount or spent, b.name)
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
function Ledger.OnSystemMessage(msg)
    if type(msg) ~= "string" then return end
    local name = SOLD_PAT and string.match(msg, SOLD_PAT)
    if name then return LAdd("SOLD", 0, 0, 1, 0, PlainName(name)) end
    name = EXPIRED_PAT and string.match(msg, EXPIRED_PAT)
    if name then return LAdd("EXPIRED", 0, 0, 1, 0, PlainName(name)) end
end
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "OWNED_AUCTIONS_UPDATED")
pcall(ledgerFrame.RegisterEvent, ledgerFrame, "AUCTION_HOUSE_SHOW")
ledgerFrame:SetScript("OnEvent", function(_, event, msg)
    if event == "CHAT_MSG_SYSTEM" then return Ledger.OnSystemMessage(msg) end
    if event == "AUCTION_HOUSE_SHOW" then Ledger.askOwnedAt = GetTime() + 3 return end
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
    local active = {}
    for i = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info and info.itemLink and (info.status or 0) == 0 then           -- 0 = 还在卖；1 = 已售出、钱在路上
            local _, _, name = ParseLink(info.itemLink)
            active[name] = (active[name] or 0) + 1
        end
    end
    Ledger.Build()
    local n = 0
    for i = #(Ledger.rows or {}), 1, -1 do                                   -- rows 是新的在前，倒着走 = 先挂的先算
        local r = Ledger.rows[i]
        if r.status == "open" and r.name then
            if (active[r.name] or 0) > 0 then
                active[r.name] = active[r.name] - 1
            elseif time() - (r.posted or 0) > 20 then                        -- 刚挂上的可能还没进列表
                LAdd("SOLD", 0, 0, 1, 0, r.name, "补记")
                n = n + 1
            end
        end
    end
    if n > 0 then print(string.format("|cff55ccffFQ|r 买卖记录对账：补记了 %d 笔已卖出（卖出时间按现在算）。", n)) end
end

-- 把流水配成一笔笔交易：同名物品先挂的先卖；买入价取这件物品（同 ID 同后缀）最近一次还没用掉的买入
function Ledger.Build()
    local lots, posts, out = {}, {}, {}
    local sum = { sold = 0, net = 0, noCost = 0, open = 0, expired = 0, tookSum = 0, hours = {} }
    for _, line in ipairs((ForeverQuantDB and ForeverQuantDB.ledger) or {}) do
        local t, kind, id, suffix, qty, total, name = string.match(line, "^(%d+)|(%u+)|(%d+)|(%-?%d+)|(%d+)|(%d+)|([^|]*)")
        t, id, suffix, qty, total = tonumber(t), tonumber(id), tonumber(suffix), tonumber(qty), tonumber(total)
        if kind == "BUY" then
            local key = id .. ":" .. suffix
            lots[key] = lots[key] or {}
            table.insert(lots[key], { t = t, unit = total / math.max(1, qty), left = qty, name = name })
        elseif kind == "POST" then
            local cost
            local ls = lots[id .. ":" .. suffix]
            if ls then
                for _, lot in ipairs(ls) do
                    if lot.left > 0 then
                        local take = math.min(lot.left, qty)
                        lot.left = lot.left - take
                        cost = (cost or 0) + lot.unit * take
                        if take >= qty then break end
                    end
                end
            end
            local row = { name = name, item_id = id, suffix_id = suffix, qty = qty, price = total, cost = cost, posted = t, status = "open" }
            posts[name] = posts[name] or {}
            table.insert(posts[name], row)
            out[#out + 1] = row
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
                if row.price and row.cost then row.net = math.floor(row.price * (1 - AH_CUT)) - row.cost end
            else
                row.status = kind == "EXPIRED" and "expired" or "cancelled"
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
        elseif r.status == "expired" then sum.expired = sum.expired + 1 end
    end
    sum.avgTook = sum.sold > 0 and sum.tookSum / sum.sold or nil
    for h, n in pairs(sum.hours) do
        if not sum.bestHourN or n > sum.bestHourN then sum.bestHour, sum.bestHourN = h, n end
    end
    table.sort(out, function(a, b) return (a.sold or a.posted or 0) > (b.sold or b.posted or 0) end)
    ledgerRows = out
    Ledger.rows = out
    return sum
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

SLASH_FOREVERQUANT1 = "/fq"
-- 上架按钮现在该显示什么、能不能点
ForeverQuantModes.SellState = function()
    local hs = (ForeverQuantDB and ForeverQuantDB.holdings) or {}
    local inBag, nxt = 0, nil
    for _, h in ipairs(hs) do
        if (h.fail or 0) < 2 and FindInBags(h.item_id, h.suffix_id, h.name) then
            inBag = inBag + 1
            nxt = nxt or h
        end
    end
    if #hs == 0 then return "上架背包里的货", true end
    if not nxt then return string.format("%d 件待上架：不在背包", #hs), true end       -- 还能点：再翻一遍背包找别的能上架的
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return string.format("%d 件待上架：先开拍卖行", inBag), false end
    if Trade.posting then return "正在挂……", false end
    if not PriceFresh(nxt) then return string.format("查同款价中……（%d 件）", inBag), false end
    return string.format("挂出 %s（共 %d 件）", SilverText(nxt.post), inBag), true
end

ForeverQuantModes.Sell = function()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then print("|cff55ccffFQ|r 请先打开拍卖行，再点「上架背包里的货」。") return end
    if Trade.posting then return end                       -- 上一件还在确认中
    local before = #(ForeverQuantDB.holdings or {})
    Trade.Adopt(before > 0)                                -- 第一次点才打印清单
    DoPost(false)
    Refresh()
end

SlashCmdList["FOREVERQUANT"] = function(msg)
    local cmd, arg = string.match(string.lower(msg or ""), "^(%a*)%s*(%d*)")
    if cmd == "snipe" then
        Trade.Toggle(string.match(string.lower(msg or ""), "^%a+%s+(%a+)"))
    elseif cmd == "sell" then
        ForeverQuantModes.Sell()
    elseif cmd == "unsell" then
        ForeverQuantDB.holdings = {}
        print("|cff55ccffFQ|r 待上架名单已清空，不会再自动上架任何东西。")
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
