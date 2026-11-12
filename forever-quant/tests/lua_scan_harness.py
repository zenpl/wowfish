"""用 lupa 模拟新版拍卖行接口跑 Scan.lua，输出一份 SavedVariables 格式的文件。用法: harness.py <输出路径>"""
import sys
import lupa

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ForeverQuantDB = {}
frames, now, clock = {}, 1794500000, 100
function time() return now end
function GetTime() return clock end
function CreateFrame() local f = {scripts={}, events={}}
  function f:RegisterEvent(e) if e == "BOGUS" then error("unknown event") end self.events[e] = true end
  function f:SetScript(n, fn) self.scripts[n] = fn end
  function f:IsShown() return true end
  frames[#frames+1] = f; return f end
AuctionHouseFrame = CreateFrame(); frames = {}
function UnitFactionGroup() return "Horde" end
function GetRealmName() return "TestRealm" end
Enum = { AuctionHouseFilter = { UncommonQuality = 5 } }
ITEM_SPELL_TRIGGER_ONEQUIP, ITEM_SPELL_TRIGGER_ONPROC, ITEM_SPELL_TRIGGER_ONUSE = "Equip:", "Chance on hit:", "Use:"
local SUF = { [845] = "of the Whale", [600] = "of the Monkey" }
local batches, sent, nameCalls = {}, 0, 0
local id = 0
for b = 1, 3 do batches[b] = {}
  for i = 1, (b < 3 and 50 or 7) do id = id + 1
    batches[b][i] = { itemKey = { itemID = 14123 + id % 4, itemSuffix = (id % 3 == 0) and 0 or (id % 3 == 1 and 845 or 600),
                                  itemLevel = 20 + id % 3, battlePetSpeciesID = 0 }, minPrice = 300 + id * 10, totalQuantity = 1 + id % 2 }
  end
end
batches[2][1] = batches[1][1]            -- 重复条目，应被去重
lastQuery = nil
C_AuctionHouse = {
  IsThrottledMessageSystemReady = function() return true end,
  SendBrowseQuery = function(q) queriesSent = (queriesSent or 0) + 1; if queriesSent % 2 == 1 then lastQuery = q else lastQuery2 = q end; sent = 1 end,
  RequestMoreBrowseResults = function() sent = sent + 1 end,
  GetBrowseResults = function() return batches[1] end,
  HasFullBrowseResults = function() return sent >= 3 end,
  GetItemKeyInfo = function(k) return { itemName = "KeyName" } end,
}
C_TooltipInfo = { GetItemByID = function(id) return { lines = { {leftText="Ritual Cape"}, {leftText="Equip: Increases attack power by 6."} } } end, GetHyperlink = function(link) return { lines = { {leftText="Ritual Cape"}, {leftText="+3 Agility"}, {leftText="+3 Stamina"} } } end,
}
C_Item = {
  GetItemInfo = function(link) nameCalls = nameCalls + 1
    local id, suf = string.match(link, "item:(%d+):0:0:0:0:0:(%-?%d+)")
    if nameCalls < 30 then return nil end              -- 前几次没缓存
    if type(link) == "number" then return "Item" .. link, nil, 2, 1, 1, "", "", 1, "", 1, (link == 14124) and 5000 or 100 end
    return "Ritual Cape" .. (SUF[tonumber(suf)] and (" " .. SUF[tonumber(suf)]) or "") end,
  GetItemInfoInstant = function(id) return id, "Armor", "Cloth", "INVTYPE_CLOAK", 1, 4, 1 end,
}
function fire(f) if sent == 1 then f.scripts.OnEvent(f, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  else f.scripts.OnEvent(f, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", batches[sent]) end end
''')
L.execute(open("addon/ForeverQuant/Scan.lua", encoding="utf-8").read())
L.execute(r'''
local f = frames[1]
assert(f.events["AUCTION_HOUSE_BROWSE_RESULTS_ADDED"])
for round = 1, 2 do
  ForeverQuantScan.Start()
  for step = 1, 120 do
    if not ForeverQuantScan.running then break end
    f.scripts.OnUpdate(f)
    if ForeverQuantScan.state == "wait" then fire(f) end
    clock = clock + 1
  end
  assert(not ForeverQuantScan.running, "scan did not finish")
  now = now + 3600
end
assert(lastQuery.filters[1] == 5 and lastQuery.itemClassFilters[2].classID == 4)
assert(#lastQuery2.filters == 0 and #lastQuery2.itemClassFilters == 0, "pass 2 should be unfiltered")
ForeverQuantScan.Start(); f.scripts.OnUpdate(f); f.scripts.OnEvent(f, "AUCTION_HOUSE_CLOSED")
''')
log = list(L.globals().ForeverQuantDB.log.values())
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write('\nForeverQuantDB = {\n["log"] = {\n')
    for i, line in enumerate(log, 1):
        fh.write('"' + line.replace("\\", "\\\\").replace('"', '\\"') + f'", -- [{i}]\n')
    fh.write("},\n}\n")
heads = [l for l in log if l.startswith("#") and not l.startswith("#VENDOR")]
print("vendor lines:", sum(l.startswith("#VENDOR") for l in log), [l for l in log if l.startswith("#VENDOR")][:2])
rows = [l for l in log if not l.startswith("#")]
print("\n".join(heads)); print("rows", len(rows), "| samples:", rows[0], "||", rows[1])
