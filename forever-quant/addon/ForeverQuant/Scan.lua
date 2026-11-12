-- ForeverQuant 绿装扫描：玩家在拍卖行里手动输入 /fq scan 发起，只读取挂单汇总，不出价、不购买。
-- 用新版拍卖行接口的"浏览"结果：每个（物品, 后缀, 物品等级）一行，带最低一口价和在售数量。
-- 结果写进 ForeverQuantDB.log（一维字符串数组，方便 Python 解析）：
--   "#SCAN|时间|阵营|服务器|0|0"
--   "物品ID|后缀ID|0|在售数量|最低一口价|需求等级|物品等级|0|类别ID|子类ID|部位|特效文字|名称"
--   "#SUFFIX|后缀ID|属性"、"#VENDOR|物品ID|后缀ID|物品等级|在售数量|最低一口价|商人收购价|名称"（最低价不高于收购价 1.2 倍的）
--   "#RECIPE|物品ID|子类ID|在售数量|最低一口价|商人收购价|名称"（所有配方）
--   "#VSTAT|比对过的条数|查不到收购价的条数"
--   "#END|时间|complete 或 partial|批次数|条数"
-- 扫描分两遍：第 1 遍只看绿色武器护甲（分析后缀），第 2 遍看全品类（找低于商人收购价的）。
local KEEP_SCANS = 3
local S = { running = false }
ForeverQuantScan = S

local function Say(msg) print("|cff55ccffFQ|r " .. msg) end
local function Ready() return C_AuctionHouse.IsThrottledMessageSystemReady() end

local function Trim()   -- 只保留最近 KEEP_SCANS 次扫描，防止存盘文件无限变大
    local log, starts = ForeverQuantDB.log, {}
    for i, line in ipairs(log) do
        if string.sub(line, 1, 6) == "#SCAN|" then starts[#starts + 1] = i end
    end
    if #starts < KEEP_SCANS then return end
    local from, new = starts[#starts - KEEP_SCANS + 2], {}
    for i = from, #log do new[#new + 1] = log[i] end
    ForeverQuantDB.log = new
end

local function NameOf(e)
    -- 拍卖行自己的物品信息里，名称带后缀（例如"野熊之七彩戒指"）；没缓存时会触发加载，稍后再取
    local info = C_AuctionHouse.GetItemKeyInfo(e.key)
    if info and info.itemName and info.itemName ~= "" then return info.itemName end
    return nil
end

-- 读一个带后缀物品的鼠标提示，取出 "+数字 属性名" 这类行里的属性名，例如 "敏捷+耐力"
local scanTip
local function SuffixStats(e)
    local link = string.format("item:%d:0:0:0:0:0:%d", e.id, e.suffix)
    local texts = {}
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = C_TooltipInfo.GetHyperlink(link)
        if not data or not data.lines then return nil end
        for _, line in ipairs(data.lines) do texts[#texts + 1] = line.leftText or "" end
    else
        scanTip = scanTip or CreateFrame("GameTooltip", "ForeverQuantScanTip", nil, "GameTooltipTemplate")
        scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
        scanTip:SetHyperlink(link)
        for i = 1, scanTip:NumLines() do
            local fs = _G["ForeverQuantScanTipTextLeft" .. i]
            texts[#texts + 1] = fs and fs:GetText() or ""
        end
    end
    if #texts < 2 then return nil end           -- 物品信息还没加载
    local stats = {}
    for _, t in ipairs(texts) do
        local name = string.match(t, "^%+%d+%s*(.+)$")
        if name then stats[#stats + 1] = name end
    end
    return table.concat(stats, "+")
end

-- 装备的特效文字（"装备：……""击中时可能：……""使用：……"），没有返回 ""。同一物品只读一次。
local effectCache = {}
local function EffectText(itemId)
    if effectCache[itemId] ~= nil then return effectCache[itemId] end
    local texts = {}
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
        local data = C_TooltipInfo.GetItemByID(itemId)
        for _, line in ipairs(data and data.lines or {}) do texts[#texts + 1] = line.leftText or "" end
    else
        scanTip = scanTip or CreateFrame("GameTooltip", "ForeverQuantScanTip", nil, "GameTooltipTemplate")
        scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
        scanTip:SetHyperlink("item:" .. itemId)
        for i = 1, scanTip:NumLines() do
            local fs = _G["ForeverQuantScanTipTextLeft" .. i]
            texts[#texts + 1] = fs and fs:GetText() or ""
        end
    end
    local found = ""
    local triggers = { ITEM_SPELL_TRIGGER_ONEQUIP, ITEM_SPELL_TRIGGER_ONPROC, ITEM_SPELL_TRIGGER_ONUSE }
    for _, t in ipairs(texts) do
        for _, trig in ipairs(triggers) do
            if trig and trig ~= "" and string.sub(t, 1, #trig) == trig then
                found = string.sub(string.gsub(t, "[|\n\r\"]", " "), 1, 90)
                break
            end
        end
        if found ~= "" then break end
    end
    if #texts >= 2 then effectCache[itemId] = found end      -- 提示还没加载出来时先不缓存
    return found
end

S.EffectText = EffectText

local function Write(status)
    local log, n = ForeverQuantDB.log, 0
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    for _, e in ipairs(S.list) do
        local _, _, _, equipLoc, _, classID, subclassID = instant(e.id)
        log[#log + 1] = table.concat({ e.id, e.suffix, 0, e.qty, e.price, S.minLevel[e.id] or 0, e.ilvl, 0,
            classID or -1, subclassID or -1, equipLoc or "", EffectText(e.id), e.name or "" }, "|")
        n = n + 1
    end
    for sid, e in pairs(S.suffixItem) do
        log[#log + 1] = string.format("#SUFFIX|%d|%s", sid, S.suffixStats[sid] or "")
    end
    local checked, unknown, hits, below = 0, 0, 0, 0
    for _, e in ipairs(S.all) do
        local sell = S.vendor[e.id]
        if sell == nil then
            unknown = unknown + 1
        else
            checked = checked + 1
            local _, _, _, _, _, classID, subclassID = instant(e.id)
            if classID == 9 then            -- 配方：全部记下来，Python 里和商人售价比
                log[#log + 1] = string.format("#RECIPE|%d|%d|%d|%d|%d|%s", e.id, subclassID or -1, e.qty, e.price, sell,
                    S.vname[e.id] or "")
            end
            if sell > 0 and e.price < sell then below = below + 1 end
            if sell > 0 and e.price <= sell * 1.2 then
                hits = hits + 1
                local info = C_AuctionHouse.GetItemKeyInfo(e.key)
                log[#log + 1] = string.format("#VENDOR|%d|%d|%d|%d|%d|%d|%s", e.id, e.suffix, e.ilvl, e.qty, e.price, sell,
                    (info and info.itemName) or S.vname[e.id] or "")
            end
        end
    end
    log[#log + 1] = string.format("#VSTAT|%d|%d", checked, unknown)
    log[#log + 1] = string.format("#END|%d|%s|%d|%d", time(), status, S.batches, n)
    S.running = false
    -- 记扫描的"开始时间"：电脑端分析结果里的行情时间用的也是它，两边才对得上
    if status == "complete" then ForeverQuantDB.lastScanAt = S.startedAt or time() end
    if S.onFullDone then S.onFullDone(status, n) end
    Say(string.format("扫描%s：绿装 %d 条，全品类 %d 条（其中 %d 条查不到商人价），低于商人收购价 %d 条。输入 /reload 存盘后，在电脑上运行 python3 -m quant gear",
        status == "complete" and "完成" or "中断（数据不完整）", n, #S.all, unknown, below))
end

local function Add(results)
    for _, r in ipairs(results or {}) do
        local k = r.itemKey
        if k and k.itemID and (k.battlePetSpeciesID or 0) == 0 and (r.minPrice or 0) > 0 then
            local id = S.pass .. ":" .. k.itemID .. ":" .. (k.itemSuffix or 0) .. ":" .. (k.itemLevel or 0)
            if S.pass == 2 then
                if not S.seen[id] then
                    S.seen[id] = true
                    S.all[#S.all + 1] = { key = k, id = k.itemID, suffix = k.itemSuffix or 0, ilvl = k.itemLevel or 0,
                                          qty = r.totalQuantity or 1, price = r.minPrice }
                end
            elseif not S.seen[id] then
                S.seen[id] = true
                local sid = k.itemSuffix or 0
                if sid ~= 0 and not S.suffixItem[sid] then S.suffixItem[sid] = { id = k.itemID, suffix = sid } end
                S.list[#S.list + 1] = { key = k, id = k.itemID, suffix = k.itemSuffix or 0, ilvl = k.itemLevel or 0,
                                        qty = r.totalQuantity or 1, price = r.minPrice }
            end
        end
    end
    S.batches = S.batches + 1
    if S.mode == "items" then
        -- 按名字逐个查：只留物品 ID 对得上的，取最低价、数量相加
        local want = S.queue[S.qi]
        for _, e in ipairs(S.all) do
            if e.id == want.id then
                local p = S.found[e.id]
                if not p then S.found[e.id] = { price = e.price, qty = e.qty }
                else p.price, p.qty = math.min(p.price, e.price), p.qty + e.qty end
            end
        end
        S.all, S.seen = {}, {}
        if not C_AuctionHouse.HasFullBrowseResults() then
            S.state = "more"
        elseif S.qi < #S.queue then
            S.qi, S.state = S.qi + 1, "query"
        else
            S.running = false
            if S.onItems then S.onItems(S.found) end
        end
        return
    end
    if S.mode == "recipes" then
        if C_AuctionHouse.HasFullBrowseResults() then
            local prices, count = {}, 0          -- 同一物品可能有多条，取最低价、数量相加
            for _, e in ipairs(S.all) do
                local p = prices[e.id]
                if not p then
                    prices[e.id] = { price = e.price, qty = e.qty }; count = count + 1
                else
                    p.price, p.qty = math.min(p.price, e.price), p.qty + e.qty
                end
            end
            S.running = false
            if S.onRecipes then S.onRecipes(prices, count) end
        else
            S.state = "more"
        end
        return
    end
    if S.batches % 20 == 0 then Say(string.format("已读取 绿装 %d 条 / 全品类 %d 条……", #S.list, #S.all)) end
    if C_AuctionHouse.HasFullBrowseResults() then
        if S.mode == "gear" then                  -- 轻量模式：只要绿装这一遍，接着取名字
            S.state, S.namesUntil, S.nextPoll = "names", GetTime() + 20, 0
        elseif S.pass == 1 then
            S.pass, S.state = 2, "query"          -- 第 2 遍：全品类
        else
            S.state, S.namesUntil, S.nextPoll = "names", GetTime() + 40, 0
        end
    else
        S.state = "more"
    end
end

local f = CreateFrame("Frame")
for _, ev in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_CLOSED" }) do
    pcall(f.RegisterEvent, f, ev)
end
f:SetScript("OnEvent", function(_, event, added)
    if not S.running then return end
    if event == "AUCTION_HOUSE_CLOSED" then
        if S.mode ~= "full" then S.running = false else Write("partial") end
    elseif S.state == "wait" then
        if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
            Add(C_AuctionHouse.GetBrowseResults())
        else
            Add(added)
        end
    end
end)
f:SetScript("OnUpdate", function()
    if not S.running then return end
    local now = GetTime()
    if S.state == "query" and Ready() then
        local filters, classes, search = {}, {}, ""
        if S.mode == "items" then
            search = S.queue[S.qi].name
        elseif S.mode == "recipes" then
            classes = { { classID = 9 } }                    -- 9=配方
        elseif S.pass == 1 then
            if Enum and Enum.AuctionHouseFilter and Enum.AuctionHouseFilter.UncommonQuality then
                filters[1] = Enum.AuctionHouseFilter.UncommonQuality
            end
            classes = { { classID = 2 }, { classID = 4 } }   -- 2=武器 4=护甲
        end
        S.state, S.sentAt = "wait", now
        local q = { searchString = search, sorts = {}, filters = filters, itemClassFilters = classes }
        if S.mode == "gear" then q.maxLevel = 39 end          -- 绿装捡漏只看 40 级以下能穿的；全量扫描（分解等要用）不限
        C_AuctionHouse.SendBrowseQuery(q)
    elseif S.state == "more" and Ready() then
        S.state, S.sentAt = "wait", now
        C_AuctionHouse.RequestMoreBrowseResults()
    elseif S.state == "wait" and now - S.sentAt > 20 then
        if not C_AuctionHouse.HasFullBrowseResults() or (S.mode ~= "full" and S.mode ~= "gear") then
            S.state = "more"       -- 超时，再要一次
        elseif S.mode == "gear" then
            S.state, S.namesUntil, S.nextPoll = "names", now + 20, 0
        elseif S.pass == 1 then
            S.pass, S.state = 2, "query"
        else
            S.state, S.namesUntil, S.nextPoll = "names", now + 40, 0
        end
    elseif S.state == "names" and now >= S.nextPoll then
        S.nextPoll = now + 0.5
        local missing = 0
        for _, e in ipairs(S.list) do
            if not e.name then
                e.name = NameOf(e)
                if not e.name then missing = missing + 1 end
            end
        end
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        for _, e in ipairs(S.all) do              -- 商人收购价：GetItemInfo 的第 11 个返回值，没缓存时返回 nil 并触发加载
            if S.vendor[e.id] == nil then
                local name, _, _, _, minLevel, _, _, _, _, _, sell = getInfo(e.id)
                if name then
                    S.vendor[e.id], S.vname[e.id], S.minLevel[e.id] = sell or 0, name, minLevel or 0
                else
                    missing = missing + 1
                end
            end
        end
        if S.mode == "gear" then
            if missing == 0 or now > S.namesUntil then
                S.running = false
                if S.onGear then S.onGear(S.list) end
            end
            return
        end
        for sid, e in pairs(S.suffixItem) do
            if not S.suffixStats[sid] or S.suffixStats[sid] == "" then
                S.suffixStats[sid] = SuffixStats(e)
                if not S.suffixStats[sid] then missing = missing + 1 end
            end
        end
        if missing == 0 or now > S.namesUntil then
            local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            for _, e in ipairs(S.list) do          -- 实在取不到的，退回用不带后缀的基础名
                if not e.name then e.name = get(e.id) end
            end
            Write("complete")
        end
    end
end)

function S.Start()
    if S.running then Say("已经在扫描了，/fq stop 可以中断") return end
    if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then Say("这个客户端没有新版拍卖行接口") return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Say("请先打开拍卖行") return end
    ForeverQuantDB.log = ForeverQuantDB.log or {}
    Trim()
    S.mode = "full"
    S.minLevel = {}
    S.running, S.state, S.list, S.seen, S.batches = true, "query", {}, {}, 0
    S.suffixItem, S.suffixStats = {}, {}
    S.pass, S.all, S.vendor, S.vname = 1, {}, {}, {}
    local log = ForeverQuantDB.log
    S.startedAt = time()
    log[#log + 1] = string.format("#SCAN|%d|%s|%s|0|0", S.startedAt, UnitFactionGroup("player") or "?", GetRealmName() or "?")
    Say("开始扫描：先绿色武器护甲，再全品类比对商人收购价。扫描期间请不要在拍卖行里搜索。")
end

-- 只扫绿色武器护甲这一遍（约十秒），结果交给回调在游戏内直接筛，不写存盘
function S.StartGear(callback, quiet)
    if S.running then return false end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        if not quiet then Say("请先打开拍卖行") end
        return false
    end
    S.mode, S.onGear = "gear", callback
    S.running, S.state, S.list, S.seen, S.batches = true, "query", {}, {}, 0
    S.pass, S.all, S.suffixItem, S.suffixStats, S.vendor, S.vname, S.minLevel = 1, {}, {}, {}, {}, {}, {}
    if not quiet then Say("正在读取绿装行情……") end
    return true
end

-- 只读配方这一类的当前最低价（几秒钟），结果交给回调，不写存盘
function S.StartRecipes(callback)
    if S.running then Say("正在扫描中，稍等") return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Say("请先打开拍卖行") return end
    S.mode, S.onRecipes = "recipes", callback
    S.running, S.state, S.list, S.seen, S.batches = true, "query", {}, {}, 0
    S.pass, S.all, S.suffixItem, S.suffixStats, S.vendor, S.vname, S.minLevel = 2, {}, {}, {}, {}, {}, {}
    Say("正在读取配方当前价格……")
end

-- 按名字逐个查几件物品的当前最低价和在售量（每件一次查询），结果 {物品ID = {price, qty}} 交给回调
function S.StartItems(items, callback)
    if S.running then Say("正在扫描中，稍等") return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Say("请先打开拍卖行") return end
    if #items == 0 then return end
    S.mode, S.onItems, S.queue, S.qi, S.found = "items", callback, items, 1, {}
    S.running, S.state, S.list, S.seen, S.batches = true, "query", {}, {}, 0
    S.pass, S.all, S.suffixItem, S.suffixStats, S.vendor, S.vname, S.minLevel = 2, {}, {}, {}, {}, {}, {}
    Say(string.format("正在读取 %d 件物品的当前价格……", #items))
end

function S.Stop()
    if not S.running then return end
    if S.mode ~= "full" then S.running = false else Write("partial") end
end
