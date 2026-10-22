--[[
煙霧測試骨架：用假的 PZ 全域載入**真正的** MOD Lua，跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄執行；標準 Lua 5.x 即可）

為什麼需要（兩類 luac -p 抓不到的錯誤，皆為正式服實際事故）：
- 改函式簽章漏改呼叫點：語法完全合法，要等該路徑真的執行才炸
  （實例：hotspotKey 兩參數改三參數，刪除成功後的 log 聚合路徑必崩）
- 邏輯回歸：安全把關（範圍／阻隔／保護規則）被改壞時，「執行到並斷言」是唯一防線

限制（必須誠實面對）：這是標準 Lua，不是遊戲的 Kahlua。
- 標準 Lua 有 next/xpcall，Kahlua 沒有——本 harness **測不出**誤用，
  那由 scripts/verify_mod.py 的靜態掃描負責（發版前兩者都要跑）
- Kahlua 專屬行為（table.sort 遞迴深度、Java instance field 不暴露、rawget 呼叫形式、
  每個 table 都是 LinkedHashMap 的記憶體成本）只能靠反編譯查證與實機測試

寫情境的原則：
- 情境要「執行到會炸的路徑」——刪除後的收尾、跨 tick 的第二輪、聚合輸出，都是重災區
- 安全邊界要有**反面**斷言（範圍外／被阻隔／受保護的對象必須存活），不是只測 happy path
- 新防線寫完先「植入違規證明它會抓」再信任它——測不出來的測試等於沒有測試
]]

-- 家族佈局固定，直接填死最省事；scaffold 時由模板替換佔位符
local MEDIA = "MOD/MinidoracatPackThrowFor42/Contents/mods/MinidoracatPackThrowFor42/42/media/lua"

-- ===== 假的 PZ 全域（依 MOD 實際用到的 API 增補）=====
local nowMs = 5000000
local logLines = {}

function getTimestampMs() return nowMs end
function isClient() return false end
function isServer() return true end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getText(key) return key end
local realPrint = print
local quiet = false
function print(...) if not quiet then realPrint(...) end end

Events = setmetatable({}, { __index = function() return { Add = function() end } end })
function getWorld() return { getWorld = function() return "harness world" end } end
-- 全域 ModData（跟世界存檔一起存）：Store 的展開標記；ModData.tables 讓測試看得到、也能清掉模擬回溯
ModData = { tables = {} }
function ModData.getOrCreate(key)
    ModData.tables[key] = ModData.tables[key] or {}
    return ModData.tables[key]
end

-- 假物品／容器：只做 Store、Guard、Admin 用到的方法。AddItem 刻意不從舊容器移除（漏呼叫 Remove 會被抓到）
local nextItemId = 1000
local function javaList(l)
    return { size = function() return #l end, get = function(_, i) return l[i + 1] end }
end
local function newContainer(holder)
    local c = { list = {}, holder = holder }
    function c:getItems() return javaList(self.list) end
    function c:getContainingItem() return self.holder end
    function c:isEmpty() return #self.list == 0 end
    function c:AddItem(it) self.list[#self.list + 1] = it; it.container = self; return it end
    function c:Remove(it)
        for i, x in ipairs(self.list) do
            if x == it then table.remove(self.list, i); it.container = nil; return end
        end
    end
    c.DoRemoveItem = c.Remove
    function c:getItemWithIDRecursiv(id)
        for _, x in ipairs(self.list) do
            if x.id == id then return x end
            local r = x.inv and x.inv:getItemWithIDRecursiv(id)
            if r then return r end
        end
    end
    function c:getCountTypeRecurse(t) return self:getAllTypeRecurse(t):size() end
    function c:getFirstTypeRecurse(t) return self:getAllTypeRecurse(t):get(0) end
    function c:getAllTypeRecurse(t)
        local out = {}
        local function walk(cc)
            for _, x in ipairs(cc.list) do
                if x.type == t then out[#out + 1] = x end
                if x.inv then walk(x.inv) end
            end
        end
        walk(self)
        return javaList(out)
    end
    return c
end
-- 膠囊的貨物倉（物品腳本的 Resources 元件，M.cargoStore）：只做用到的方法。引擎的 offerItem 遇到還在容器裡的物品會自己移除並
-- 逐件送封包（ResourceItem.java:328-346），這裡記下每次呼叫的參數與物品在不在容器裡，讓測試抓「沒先 Remove」與同步
ComponentType = { Resources = "Resources" }
ArrayList = { new = function()
    local l = {}
    return { add = function(_, x) l[#l + 1] = x end, size = function() return #l end, get = function(_, i) return l[i + 1] end }
end }
local function newStore()
    local s = { list = {}, offers = {} }
    function s:getStoredItems() return javaList(self.list) end
    function s:isEmpty() return #self.list == 0 end
    function s:offerItem(it, _, force, sync)
        self.offers[#self.offers + 1] = { force = force, sync = sync, inContainer = it.container ~= nil }
        if it.container then it.container:Remove(it) end
        self.list[#self.list + 1] = it
        return nil
    end
    function s:removeAllItems(out)
        for _, it in ipairs(self.list) do out:add(it) end
        self.list = {}
        return out
    end
    return s
end
local function newItem(fullType, isContainer)
    nextItemId = nextItemId + 1
    local it = { id = nextItemId, type = fullType }
    function it:getID() return self.id end
    function it:setID(n) self.id = n end
    function it:getFullType() return self.type end
    function it:getContainer() return self.container end
    function it:getWorldItem() return nil end
    if isContainer then
        it.inv = newContainer(it)
        function it:getInventory() return self.inv end
    end
    -- only loaded capsules carry the component (items script); other items answer nil like the engine
    if fullType:find("^MinidoracatPackThrow%.LoadedCapsule") then it.store = newStore() end
    function it:getComponent(t)
        if t ~= ComponentType.Resources or not self.store then return nil end
        local store = self.store
        return { getResource = function(_, id) return id == "cargo" and store or nil end }
    end
    return it
end
function instanceof(o, cls) return cls == "InventoryContainer" and type(o) == "table" and o.inv ~= nil end
function instanceItem(t)
    return newItem(t, t:find("^MinidoracatPackThrow%.Loaded") ~= nil or t == "Base.Bag_Schoolbag")
end
function sendAddItemToContainer() end
function sendRemoveItemFromContainer() end
Capability = { ManipulateVehicle = "ManipulateVehicle" }
function checkPermissions(p) return p.admin == true end
-- the lowest roll: a wild animal is caught at any chance above 0 (wildCases forces both outcomes)
function ZombRand() return 0 end
local function newPlayer(name, admin)
    local p = { admin = admin, inv = newContainer(nil) }
    function p:getUsername() return name end
    function p:getX() return 100.5 end
    function p:getY() return 200.7 end
    function p:getZ() return 0 end
    function p:getInventory() return self.inv end
    function p:removeFromHands() end
    function p:isEquipped(it) return it.equipped == true end
    function p:isAttachedItem() return false end
    function p:isSneaking() return self.sneak == true end
    function p:getForwardDirectionX() return self.fx or 0 end
    function p:getForwardDirectionY() return self.fy or 1 end
    function p:getVehicle() return self.vehicle end
    return p
end
-- 假世界：已載入的車（sqlId）與已載入的格子
local loadedCars, loadedSquares = {}, {}
function getCell()
    return {
        getVehicles = function()
            return { iterator = function()
                local i = 0
                return { hasNext = function() return i < #loadedCars end,
                    next = function() i = i + 1; return loadedCars[i] end }
            end }
        end,
        getGridSquare = function(_, x, y) return loadedSquares[tostring(x) .. "," .. tostring(y)] end,
    }
end
local function fakeCar(sqlId, script)
    return { getSqlId = function() return sqlId end, getScriptName = function() return script or "Base.PickUpTruck" end }
end
function getScriptManager() return { getVehicle = function(_, s) return s == "Base.PickUpTruck" end } end
function getOnlinePlayers() return javaList({}) end

-- 假檔案系統：照 getFileWriter 的副檔名白名單（LuaManager.java:1035），且可植入「靜默丟寫」與「寫壞」
local files, dropWrites, corruptWrites = {}, false, false
local WHITELIST = { ini = true, cfg = true, txt = true, log = true, json = true }
function getFileWriter(path, _, append)
    if path:find("%.%.") or not WHITELIST[path:match("%.(%w+)$") or ""] then return nil end
    local buf = append and files[path] or ""
    return {
        write = function(_, s) buf = buf .. s end,
        close = function()
            if dropWrites then return end -- PrintWriter 吞掉 I/O 錯誤：呼叫端什麼都看不到
            files[path] = corruptWrites and buf:sub(1, #buf - 1) or buf
        end,
    }
end
function getFileReader(path, _)
    local text = files[path]
    if not text then return nil end
    local lines, i = {}, 0
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    if text:sub(-1) == "\n" then lines[#lines] = nil end
    return {
        readLine = function() i = i + 1; return lines[i] end,
        close = function() end,
    }
end

-- ===== 載入受測程式碼 =====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    loaded[name] = true
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then chunk() return true end
    end
    error("require 找不到: " .. name)
end

require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Json"
require "MinidoracatPackThrow/Store"
require "MinidoracatPackThrow/Guard"
require "MinidoracatPackThrow/Admin"
local M = MinidoracatPackThrow
local Json, Store, Guard, Admin = M.Json, M.Store, M.Guard, M.Admin

-- ===== 測試工具 =====
local failures = 0
local function check(ok, label)
    if ok then print("  PASS  " .. label)
    else failures = failures + 1; print("  FAIL  " .. label) end
end

-- 逐值比對（型別也要一樣：數字 key 不能變字串）；回傳第一個不同的路徑
local function diff(a, b, path)
    path = path or "$"
    if type(a) ~= type(b) then return path .. " type " .. type(a) .. "/" .. type(b) end
    if type(a) ~= "table" then
        if a ~= b then return path .. " " .. tostring(a) .. "~=" .. tostring(b) end
        return nil
    end
    for k, v in pairs(a) do
        local d = diff(v, b[k], path .. "[" .. type(k) .. ":" .. tostring(k) .. "]")
        if d then return d end
    end
    for k in pairs(b) do
        if a[k] == nil then return path .. " extra key " .. type(k) .. ":" .. tostring(k) end
    end
    return nil
end

local function roundTrip(v)
    local text, bad = Json.encode(v)
    if not text then return nil, "encode failed at " .. tostring(bad) end
    local back, err = Json.decode(text)
    if err then return nil, "decode failed: " .. err end
    return back, text
end

local player = {
    getUsername = function() return "tester" end,
    getX = function() return 100.5 end, getY = function() return 200.7 end, getZ = function() return 0 end,
}

-- ===== 情境 =====
print("Json：往返保留型別與數值")
local nasty = {
    nested = { a = { b = { c = { d = "deep" } } } },
    [1] = "one", [2] = "two", [10] = "ten", [-3] = "neg", [1.5] = "half",
    ["1"] = "string one", ["#tag"] = "hash", ["##x"] = "double hash", ["#5"] = "hash five",
    unicode = "中文 日本語 한국어 é ✓",
    escapes = 'quote " backslash \\ newline \n cr \r tab \t ctrl \1 del \127 slash /',
    empty = {},
    emptyStr = "",
    floats = { 0.1, 0.1 + 0.2, 1 / 3, 1e-300, 1e300, -2.5, 123456789.125, 2 ^ 53, -(2 ^ 53), 1e14, 1e15 + 0.5 },
    bools = { t = true, f = false },
    ints = { 0, -0, 7, 4294967296, 99999999999 },
}
local back, text = roundTrip(nasty)
check(back ~= nil, "巢狀刁鑽值可編碼並解碼（" .. tostring(text and #text) .. " bytes）")
check(back and diff(nasty, back) == nil, "逐值相等，型別不變：" .. tostring(back and diff(nasty, back)))
check(back and back[1] == "one" and back["1"] == "string one", "數字 key 1 與字串 key \"1\" 不互相覆蓋")
check(back and back["#tag"] == "hash" and back["##x"] == "double hash" and back["#5"] == "hash five", "# 開頭字串 key 原樣保留")
check(text and not text:find("\n"), "輸出單行（讀回比對逐行串接）")
check(Json.encode({}) == "{}", "空表編成 {}")
check(select(2, Json.decode("{} x")) ~= nil, "尾端垃圾拒收")
check(select(2, Json.decode('{"#abc":1}')) ~= nil, "壞數字 key 拒收")
check(Json.decode('{"a":"\\u0041\\u00e9"}').a == "A\195\169", "\\u 跳脫解碼（標準 Lua 轉 UTF-8）")

print("Json：拒收不能存的值並回傳路徑")
local function rejects(v, want, label)
    local text2, path = Json.encode(v)
    check(text2 == nil and path == want, label .. "（path=" .. tostring(path) .. "）")
end
rejects({ modData = { foo = { bar = function() end } } }, "modData.foo.bar", "function")
rejects({ modData = { foo = { bar = io.stdout } } }, "modData.foo.bar", "userdata")
rejects({ x = { y = 0 / 0 } }, "x.y", "NaN")
rejects({ x = { y = math.huge } }, "x.y", "inf")
rejects({ x = { [true] = 1 } }, "x.<boolean key>", "boolean key")
local loop = {}; loop.self = loop
check(Json.encode(loop) == nil, "循環參照不會無限遞迴")

print("Json.storable：照引擎存檔規則跳過 userdata/function/NaN/inf/布林 key，其餘逐值保留")
local mixed = {
    keep = nasty,
    foo = { bar = io.stdout, fn = function() end, ok = 1 },
    _vehicle = io.stdout,
    nan = 0 / 0, inf = math.huge,
    [true] = "bool key",
}
local skipped = {}
local clean = Json.storable(mixed, "modData", skipped)
local want = {
    ["modData.foo.bar"] = true, ["modData.foo.fn"] = true, ["modData._vehicle"] = true,
    ["modData.nan"] = true, ["modData.inf"] = true, ["modData.<boolean key>"] = true,
}
local got = {}
for _, p in ipairs(skipped) do got[p] = true end
check(diff(want, got) == nil and #skipped == 6, "skipped 正好列出 6 條路徑：" .. table.concat(skipped, ","))
check(diff(nasty, clean.keep) == nil and clean.foo.ok == 1 and clean.foo.bar == nil, "可存的值逐值保留")
local cleanBack = roundTrip(clean)
check(cleanBack and diff(clean, cleanBack) == nil, "storable 結果一定能 JSON 往返")
local deep = {}; deep.self = deep
local dskip = {}
Json.storable(deep, "m", dskip)
check(#dskip == 1, "循環參照在深度上限處截斷並記一條路徑")

print("Store：寫後讀回、狀態只轉一次")
local snap = { v = 1, state = "PACKED", settled = true, script = "Base.PickUpTruck", modData = nasty, history = {} }
check(Store.write(42, snap) == true, "寫入並讀回一致")
check(Store.dir() == "MinidoracatPackThrow/MP_harness_world/" and files[Store.path(42, "a")] ~= nil
    and files[Store.path(42, "a")]:find("\n42 {", 1, true) ~= nil, "落在這個世界的資料夾、42 號桶的 a 份（MP_<伺服器>）")
local r = Store.read(42)
check(r and diff(snap, r) == nil, "read 讀回與寫入相同")
check(select(2, Store.read(43)) == "NO_SNAPSHOT", "沒有檔案回 NO_SNAPSHOT")
files[Store.path(44, "a")] = "MVC1 1\n44 {broken\nEND 1 1" -- 桶檔完整，只有這一筆壞掉
check(select(2, Store.read(44)) == "CORRUPT", "壞掉的一筆回 CORRUPT")
Store.write(45, { state = "PACKED", settled = true, history = {} })
check(Store.claim(45, player) ~= nil and Store.marked(45) and Store.release(45, Store.read(45), player, "x") == true
    and not Store.marked(45), "claim 在 ModData 標記展開，生車失敗退回 PACKED 時拿掉標記")

local claimed = Store.claim(42, player)
check(claimed and claimed.state == "UNPACKED", "claim：PACKED -> UNPACKED")
check(Store.read(42).state == "UNPACKED", "claim 已落盤（生車前）")
local again, why = Store.claim(42, player)
check(again == nil and why == "NOT_PACKED", "第二次 claim 被拒 NOT_PACKED")
local h = Store.read(42).history
check(#h == 1 and h[1].ev == "REJECTED" and h[1].by == "tester", "被拒記 REJECTED（by=" .. tostring(h[1] and h[1].by) .. "）")
check(#logLines >= 1 and logLines[#logLines]:find("REJECTED capsule=42", 1, true) ~= nil, "REJECTED 寫進 writeLog")
check(Store.read(42).settled == nil, "claim 清掉 settled（新狀態要重新落盤）")

Store.write(50, { state = "PACKED", settled = true, history = {} })
local s50 = Store.claim(50, player)
check(Store.release(50, s50, player, "BLOCKED") == true and Store.read(50).state == "PACKED", "生車失敗 release 回 PACKED")
check(Store.read(50).history[1].ev == "UNPACK_FAILED" and Store.read(50).history[1].why == "BLOCKED", "release 記 UNPACK_FAILED 與原因")
check(Store.setState(50, Store.read(50), "RESTORED", player, { car = 7 }) == true, "PACKED -> RESTORED")
check(select(2, Store.claim(50, player)) == "NOT_PACKED", "RESTORED 後 claim 被拒")
check(select(2, Store.release(50, Store.read(50), player, "x")) == "BAD_TRANSITION", "RESTORED 不能 release")

print("Store：寫入失敗要被發現（植入違規）")
dropWrites = true
quiet = true
local ok1, why1 = Store.write(60, { state = "PACKED" })
quiet = false
dropWrites = false
check(ok1 == nil and why1 == "WRITE_FAILED", "靜默丟寫 -> WRITE_FAILED")
Store.write(61, { state = "PACKED", settled = true, history = {} })
corruptWrites = true
quiet = true
local c61, cwhy = Store.claim(61, player)
quiet = false
corruptWrites = false
check(c61 == nil and cwhy == "WRITE_FAILED", "claim 寫壞 -> WRITE_FAILED，不回快照")
local ok2, why2, path2 = Store.write(62, { modData = { bad = function() end } })
check(ok2 == nil and why2 == "MODDATA_UNSUPPORTED" and path2 == "modData.bad", "存不成 JSON -> MODDATA_UNSUPPORTED＋路徑")
check(files[Store.path(62, "a")] == nil and files[Store.path(62, "b")] == nil, "被拒時不寫桶檔")

print("Store：狀態轉換表（只有表上的 5 條箭頭）")
local STATES = { "PACKED", "UNPACKED", "RESTORED", "VOID" }
local ARROWS = { ["PACKED>UNPACKED"] = true, ["PACKED>RESTORED"] = true, ["PACKED>VOID"] = true,
    ["UNPACKED>PACKED"] = true, ["UNPACKED>RESTORED"] = true }
local tid, badArrows = 100, {}
quiet = true
for _, from in ipairs(STATES) do
    for _, to in ipairs(STATES) do
        tid = tid + 1
        Store.write(tid, { state = from, settled = true, history = {} })
        local ok = Store.setState(tid, Store.read(tid), to, player) == true
        local after = Store.read(tid)
        local want = ARROWS[from .. ">" .. to] == true
        if ok ~= want or after.state ~= (ok and to or from) or (ok and after.history[1].ev ~= to) then
            badArrows[#badArrows + 1] = from .. ">" .. to
        end
    end
end
quiet = false
check(#badArrows == 0, "16 組只有表上的允許，其餘 BAD_TRANSITION 且不動檔案：" .. table.concat(badArrows, ","))

print("Store：落盤標記 settled 與 uncertain")
local t0 = nowMs
Store.write(200, { state = "PACKED", history = {} })
Store.schedule(200)
check(not Store.uncertain(200, Store.read(200)), "剛收車（pending）不是 uncertain")
nowMs = t0 + Store.SETTLE_MS - 1
Store.settleDue(nowMs)
check(Store.read(200).settled == nil, "未滿 5 秒不寫 settled")
nowMs = t0 + Store.SETTLE_MS
quiet = true
Store.settleDue(nowMs)
quiet = false
check(Store.read(200).settled == true and not Store.uncertain(200, Store.read(200)), "滿 5 秒寫上 settled（含讀回）")
Store.write(201, { state = "UNPACKED", history = {} })
local logBefore = #logLines
quiet = true
check(Store.uncertain(201, Store.read(201)), "沒有 settled 又不在 pending＝uncertain（當機留下的）")
Store.read(201)
quiet = false
local warns = 0
for i = logBefore + 1, #logLines do
    if logLines[i]:find("UNCERTAIN capsule=201", 1, true) then warns = warns + 1 end
end
check(warns == 1, "開服後第一次讀到 uncertain 寫一行 log，之後不重複（" .. warns .. "）")
Store.write(202, { state = "PACKED", history = {} })
Store.schedule(202)
dropWrites, quiet = true, true
nowMs = nowMs + Store.SETTLE_MS
Store.settleDue(nowMs)
dropWrites, quiet = false, false
check(Store.read(202).settled == nil and Store.uncertain(202, Store.read(202)), "settle 寫不進去：離開 pending，變 uncertain")
check(Store.uncertain(203, { state = "VOID" }) == false, "VOID 不算 uncertain")

-- history: PACKED with the original car 7 at (1, 2); UNPACKED/RESTORED add the new car 8 at (x or 1, 2)
local function rec(id, state, settled, x)
    local h = { { ev = "PACKED", car = 7, x = 1, y = 2, z = 0 } }
    if state ~= "PACKED" then h[2] = { ev = state, car = 8, x = x or 1, y = 2, z = 0 } elseif x then h[1].x = x end
    Store.write(id, { state = state, settled = settled, script = "Base.PickUpTruck",
        manifest = { ["Base.WaterBottle"] = 2 }, history = h })
end

print("Store.claim：只接受 PACKED 且不是 uncertain；舊膠囊依狀態處理")
quiet = true
local claimCases = {
    { 301, "PACKED", true, nil }, { 302, "PACKED", nil, "UNCERTAIN" }, { 303, "UNPACKED", nil, "UNCERTAIN" },
    { 304, "UNPACKED", true, "STALE" }, { 305, "VOID", nil, "STALE" }, { 306, "RESTORED", true, "NOT_PACKED" },
}
local claimResults = {}
for _, c in ipairs(claimCases) do
    rec(c[1], c[2], c[3])
    local s, w, stale = Store.claim(c[1], player)
    local after = Store.read(c[1])
    local ev = after.history[#after.history]
    local good
    if c[4] == nil then
        good = s ~= nil and after.state == "UNPACKED"
    elseif c[4] == "STALE" then
        good = s == nil and w == "STALE" and stale ~= nil and after.state == c[2] and ev.ev ~= "REJECTED"
    else
        good = s == nil and w == c[4] and after.state == c[2] and ev.ev == "REJECTED" and ev.why == c[4]
    end
    claimResults[#claimResults + 1] = { good, c[2] .. (c[3] and "+settled" or "+unsettled") .. " -> "
        .. tostring(c[4] or "UNPACKED") .. "（得到 " .. tostring(w or (s and s.state)) .. "）" }
end
rec(307, "PACKED", nil)
Store.schedule(307)
local quick = Store.claim(307, player)
quiet = false
for _, cr in ipairs(claimResults) do check(cr[1], cr[2]) end
check(quick ~= nil, "同一次開服收車後馬上展開（pending）照常成功")

print("Admin.resolve：只處理 uncertain，分支照判定")
local admin, nobody = newPlayer("admin", true), newPlayer("bob", false)
loadedSquares["1,2"] = {}
local function resolve(id, verdict, checked) return Admin.resolve(admin, id, verdict, "note", checked) end
quiet = true
rec(401, "PACKED", nil)
local rNo = Admin.resolve(nobody, 401, "present")
rec(402, "PACKED", true)
local rSettled = resolve(402, "present")
loadedCars = { fakeCar(7) }
local r401 = resolve(401, "present")
local s401 = Store.read(401)
rec(403, "PACKED", nil)
local r403exists = resolve(403, "missing")
loadedCars = {}
local r403site = resolve(403, "present")
local r403checked = resolve(403, "present", true)
rec(404, "PACKED", nil)
local r404 = resolve(404, "missing")
rec(405, "UNPACKED", nil)
loadedCars = { fakeCar(7) } -- only the original car is loaded; the record's car is the new one (8)
local r405 = resolve(405, "missing")
local s405 = Store.read(405)
local claim405 = Store.claim(405, player)
loadedCars = { fakeCar(8) }
rec(406, "UNPACKED", nil)
local r406 = resolve(406, "present")
loadedCars = {}
rec(407, "PACKED", nil, 900)
local r407 = resolve(407, "missing")
local r407checked = resolve(407, "missing", true)
rec(408, "PACKED", nil)
local r408 = resolve(408, "maybe")
loadedCars = { fakeCar(7, "Base.CarNormal") } -- sqlId reused by another model after a crash
rec(409, "PACKED", nil)
local r409 = resolve(409, "missing")
loadedCars = {}
quiet = false
check(rNo.why == "NOT_ADMIN", "非管理員 NOT_ADMIN")
check(rSettled.why == "NOT_UNCERTAIN", "已落盤的紀錄不必判定 NOT_UNCERTAIN")
check(r401.ok and s401.state == "VOID" and s401.history[#s401.history].ev == "RESOLVED"
    and s401.history[#s401.history].verdict == "present", "PACKED＋原車找得到，判「車在」-> VOID，記 RESOLVED")
check(r403exists.why == "CAR_EXISTS", "伺服器找得到車時「車不在」被拒 CAR_EXISTS")
check(r403site.why == "CHECK_SITE", "找不到車又沒到現場確認，「車在」-> CHECK_SITE")
check(r403checked.ok and Store.read(403).state == "VOID", "到現場確認車在 -> VOID")
check(r404.ok and Store.read(404).state == "PACKED" and Store.read(404).settled == true, "PACKED＋車不在 -> 寫上 settled（照常可補回）")
check(r405.ok and s405.state == "PACKED" and s405.settled == true, "UNPACKED＋新車不在 -> 改回 PACKED 並 settled")
check(claim405 ~= nil, "改回 PACKED 後玩家可以再丟一次")
check(r406.ok and Store.isStale(Store.read(406)), "UNPACKED＋新車在 -> settled，舊膠囊之後會被清空")
check(r407.why == "CHECK_SITE" and r407checked.ok, "紀錄位置沒載入：「車不在」要 checked")
check(r408.why == "BAD_ARGS", "不認得的判定 BAD_ARGS")
check(r409.ok, "同 sqlId 但車種不同（sqlId 被重用）不算紀錄的車")
local placed = Store.recordedCar({ history = {
    { ev = "PACKED", x = 10, y = 10, z = 0, car = 7 },
    { ev = "RESOLVED", verdict = "missing", x = 20, y = 20, z = 0, car = 7 },
} })
check(placed.ev == "PACKED" and placed.x == 10 and placed.y == 10,
    "紀錄位置取最後一次放車的事件，判定（RESOLVED）時管理員站的位置不算")

print("Unpack.spawn：快照缺欄位時不生車（CORRUPT）")
local spawnedCount = 0
local savedAdd = addVehicleDebug
addVehicleDebug = function() spawnedCount = spawnedCount + 1; return nil end
local fullSnap = { script = "Base.PickUpTruck", keyId = 1, rust = 0, parts = {}, hsv = { 0.1, 0.2, 0.3 }, engine = { 50, 40, 60 } }
check(M.Snapshot.missing(fullSnap) == nil, "完整的快照沒有缺欄位")
local brokenHsv = Json.copy(fullSnap); brokenHsv.hsv = { 0.1, 0.2 }
local noEngine = Json.copy(fullSnap); noEngine.engine = nil
local noKey = Json.copy(fullSnap); noKey.keyId = nil
check(M.Snapshot.missing(brokenHsv) == "hsv" and M.Snapshot.missing(noEngine) == "engine"
    and M.Snapshot.missing(noKey) == "keyId", "缺 hsv／engine／keyId 各自指出欄位")
quiet = true
local v1, why1 = M.Unpack.spawn(brokenHsv, {}, "N")
quiet = false
check(v1 == nil and why1 == "CORRUPT" and spawnedCount == 0, "缺欄位的快照回 CORRUPT，而且沒有呼叫 addVehicleDebug")
do -- SP 在 addVehicleDebug 裡同步跑 damnlib 客戶端 Init：空槽的隨機補件要停掉，生完再換回原函式
    local damnCalls, savedDirs = 0, IsoDirections
    IsoDirections = { N = "N" }
    local damnDefaults = function() damnCalls = damnCalls + 1 end
    DAMN = { Parts = { processDefaults = damnDefaults } }
    addVehicleDebug = function() DAMN.Parts:processDefaults(); return nil end
    local v2, why2 = M.Unpack.spawn(fullSnap, {}, "N")
    check(v2 == nil and why2 == "BLOCKED" and damnCalls == 0 and DAMN.Parts.processDefaults == damnDefaults,
        "addVehicleDebug 期間 damnlib 的空槽隨機補件不動作，之後換回原函式")
    DAMN, IsoDirections = nil, savedDirs
end
addVehicleDebug = savedAdd

print("Unpack：addVehicleDebug 沒把車放進世界（sqlId -1）＝生車失敗，膠囊與紀錄不動（正式服 2026-10-19 有車整台消失）")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    local S = M.Snapshot
    local saved = { add = addVehicleDebug, dirs = IsoDirections, restore = S.restore, cargo = S.restoreCargo }
    IsoDirections = { N = "N" }
    local restored = 0
    S.restore = function() restored = restored + 1 end
    S.restoreCargo = function() return { home = 0, other = 0, ground = 0 } end
    local spot = { getX = function() return 3 end, getY = function() return 4 end, getZ = function() return 0 end }
    -- an invalid spot (indoors outside a vehicle zone) skips addToWorld and VehiclesDB2, yet the vehicle comes back
    -- (LuaManager.java:10817-10828); getSquare() is worked out from x, y, z (BaseVehicle.java:9769)
    local function spawned(sqlId)
        return { getSqlId = function() return sqlId end, getSquare = function() return spot end, getId = function() return 9 end,
            getKeyId = function() return 1 end, getSkinIndex = function() return 0 end, exit = function() end }
    end
    local p = newPlayer("unpacker", false)
    local function capsule()
        local cap = p.inv:AddItem(instanceItem(M.TYPES[1].loaded))
        Store.write(cap.id, { state = "PACKED", settled = true, script = "Base.PickUpTruck", keyId = 1, rust = 0, parts = {},
            hsv = { 0.1, 0.2, 0.3 }, engine = { 50, 40, 60 }, history = { { ev = "PACKED", car = 7 } } })
        return cap
    end
    local lost, kept = capsule(), capsule()
    quiet = true
    addVehicleDebug = function() return spawned(-1) end
    local refused = M.Unpack.unpack(p, lost, spot, "N", {})
    local refusedRec, restoredRefused = Store.read(lost.id), restored
    addVehicleDebug = function() return spawned(41) end
    local placed = M.Unpack.unpack(p, kept, spot, "N", {})
    quiet = false
    check(refused.ok == false and refused.why == "BLOCKED" and restoredRefused == 0 and refusedRec.state == "PACKED"
        and refusedRec.history[#refusedRec.history].ev == "UNPACK_FAILED" and p.inv:getItemWithIDRecursiv(lost.id) == lost,
        "車沒放進世界：BLOCKED、快照不寫進那台車、紀錄退回 PACKED、膠囊留在背包")
    check(placed.ok and placed.sqlId == 41 and Store.read(kept.id).state == "UNPACKED" and p.inv:getItemWithIDRecursiv(kept.id) == nil,
        "車放進世界（有 sqlId）：照常展開")
    addVehicleDebug, IsoDirections, S.restore, S.restoreCargo = saved.add, saved.dirs, saved.restore, saved.cargo
end)() end

print("Snapshot.restore：改裝 hook 照 part modData 決定留不留零件（Autotsar tsarslib Tuning2；正式服 2026-10-18 展開後改裝件不見）")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved = { add = addVehicleDebug, dirs = IsoDirections, utils = VehicleUtils, inst = instanceItem }
    IsoDirections = { N = "N" }
    VehicleUtils = { callLua = function(fn, ...) return fn(...) end }
    local Item, Part, Car = {}, {}, {}
    Item.__index, Part.__index, Car.__index = Item, Part, Car
    local function item(fullType, cond) return setmetatable({ type = fullType, cond = cond or 100, md = {} }, Item) end
    function Item:getFullType() return self.type end
    function Item:getCondition() return self.cond end
    function Item:setConditionNoSound(c) self.cond = c end
    function Item:hasModData() return next(self.md) ~= nil end
    function Item:getModData() return self.md end
    function Item:IsDrainable() return false end
    instanceItem = function(t) return item(t) end
    function Part:getId() return self.id end
    function Part:getCondition() return self.cond end
    function Part:setCondition(c) self.cond = c; if self.item then self.item.cond = c end end -- VehiclePart.java:870-886
    function Part:getInventoryItem() return self.item end
    function Part:setInventoryItem(it) self.item = it end
    function Part:hasModData() return next(self.md) ~= nil end
    function Part:getModData() return self.md end
    function Part:getTable(name) return self.tables and self.tables[name] end
    function Part:getItemType() return { isEmpty = function() return false end } end
    function Part:getItemContainer() return nil end
    function Part:isContainer() return false end
    function Part:getDoor() return nil end
    function Part:getWindow() return nil end
    function Part:getLight() return nil end
    for _, f in ipairs({ "setKeyId", "setSkinIndex", "setColorHSV", "setRust", "setBloodIntensity", "setEngineFeature",
        "setHotwired", "setAlarmed", "setHeadlightsOn", "updatePartStats", "updateBulletStats", "doDamageOverlay", "exit" }) do
        Car[f] = function() end
    end
    function Car:getScriptName() return "Base.PickUpTruck" end
    function Car:getScript() return nil end
    function Car:getSkinIndex() return 0 end
    function Car:getColorHue() return 0.1 end
    function Car:getColorSaturation() return 0.2 end
    function Car:getColorValue() return 0.3 end
    function Car:getRust() return 0 end
    function Car:getBloodIntensity() return 0 end
    function Car:getEngineQuality() return 50 end
    function Car:getEngineLoudness() return 40 end
    function Car:getEnginePower() return 60 end
    function Car:getKeyId() return 7 end
    function Car:isHotwired() return false end
    function Car:isAlarmed() return false end
    function Car:getHeadlightsOn() return false end
    function Car:hasModData() return false end
    function Car:getModData() return self.md end
    function Car:getPartCount() return #self.list end
    function Car:getPartByIndex(i) return self.list[i + 1] end
    function Car:getPartById(id) return self.byId[id] end
    function Car:getSqlId() return 1 end -- placed: VehiclesDB2 numbered it
    -- the tsarslib Tuning2 hooks, the parts that matter here (ATATuning2.lua): install drops the item of a slot whose
    -- tuning2 names no model (ModelByModData :451-452); a guard parks the condition of the part it protects in that
    -- part's modData and shows 100 (InstallComplete.Tuning :571-600); uninstall gives the parked condition back
    local function install(car, part)
        local t2 = part:getModData().tuning2
        if not (t2 and part:getInventoryItem()) then return end
        if not t2.model then part:setInventoryItem(nil) return end
        for _, id in ipairs(t2.protection or {}) do
            local guarded = car:getPartById(id)
            local g = guarded:getModData()
            g.tuning2 = g.tuning2 or {}
            if guarded:getInventoryItem() then
                g.tuning2.health = guarded:getCondition()
                guarded:setCondition(100)
            end
        end
    end
    local function uninstall(car, part)
        local t2 = part:getModData().tuning2
        for _, id in ipairs(t2 and t2.protection or {}) do
            local g = car:getPartById(id):getModData().tuning2
            if g and g.health then car:getPartById(id):setCondition(g.health); g.health = nil end
        end
    end
    local hooks = { install = { complete = install }, uninstall = { complete = uninstall } }
    -- parts in script order: the guarded headlight comes before its bull bar (ATA Jeep and Samara windows, headlights)
    local function car(parts)
        local c = setmetatable({ list = {}, byId = {}, md = {} }, Car)
        for _, s in ipairs(parts) do
            local p = setmetatable({ id = s[1], item = s[2] and item(s[2], s[3]), cond = s[3] or 100, md = s[4],
                tables = s[5] }, Part)
            c.list[#c.list + 1] = p
            c.byId[p.id] = p
        end
        return c
    end
    local bulb = "Base.LightBulb"
    local packed = car({
        { "Headlight", bulb, 86, { tuning2 = { health = 60, protectionRequireUninstalled = { Bullbar = true } } } },
        { "Bullbar", bulb, 90, { tuning2 = { model = "Bar2", protection = { "Headlight" } } }, hooks },
        { "Spoiler", bulb, 100, { tuning2 = { model = "Rear1" } }, hooks },
        { "Skirts", nil, 100, { tuning2 = {} }, hooks },
    })
    -- a fresh spawn as ATATuning2.Create.Tuning leaves it: slots tuning2 = {}, one slot rolled a random part
    local fresh = car({
        { "Headlight", bulb, 77, {} },
        { "Bullbar", nil, 100, { tuning2 = {} }, hooks },
        { "Spoiler", nil, 100, { tuning2 = {} }, hooks },
        { "Skirts", bulb, 100, { tuning2 = { model = "Rand" } }, hooks },
    })
    addVehicleDebug = function() return fresh end
    local v = M.Unpack.spawn(M.Snapshot.capture(packed), {}, "N")
    local bar, spoiler, light, skirts = fresh.byId.Bullbar, fresh.byId.Spoiler, fresh.byId.Headlight, fresh.byId.Skirts
    check(v == fresh and bar.item ~= nil and spoiler.item ~= nil and bar.md.tuning2.model == "Bar2"
        and spoiler.md.tuning2.model == "Rear1" and bar.cond == 90 and bar.item.cond == 90,
        "快照裡裝著的改裝件都裝回去、型號照快照（新車那槽的 tuning2 沒有型號，hook 會把物品拿掉）")
    check(light.cond == 86 and light.item.cond == 86 and light.md.tuning2.health == 60
        and light.md.tuning2.protectionRequireUninstalled.Bullbar == true,
        "排在護槓前面、被它保護的大燈：狀況與停著的真實狀況照快照（護槓的 hook 後跑也蓋不掉）")
    check(skirts.item == nil and next(skirts.md.tuning2) == nil, "快照裡空著的改裝槽維持空的（新車隨機抽到的拿掉）")
    addVehicleDebug, IsoDirections, VehicleUtils, instanceItem = saved.add, saved.dirs, saved.utils, saved.inst
end)() end

print("Admin.restore：可補的狀態、CAR_EXISTS、checked、先改 RESTORED 再生車")
local spawnFails, restoringId, fileAtSpawn = false, nil, {}
M.Unpack.spawn = function(s)
    fileAtSpawn[restoringId] = s.state .. "/" .. tostring(Store.read(restoringId).state)
    if spawnFails then return nil, "BLOCKED" end
    local sq = { getX = function() return 1 end, getY = function() return 2 end, getZ = function() return 0 end }
    return { getSquare = function() return sq end, getSqlId = function() return 99 end, getId = function() return 5 end }, {}
end
local function restore(id, x, checked)
    restoringId = id
    return Admin.restore(admin, id, x or 1, 2, 0, "gave water back", checked)
end
quiet = true
local notRestorable = {}
for id, st in pairs({ [501] = { "VOID", true }, [502] = { "RESTORED", true }, [503] = { "UNPACKED", true } }) do
    rec(id, st[1], st[2])
    notRestorable[#notRestorable + 1] = restore(id, 1, true).why
end
rec(504, "PACKED", true)
loadedCars = { fakeCar(7) }
local r504 = restore(504)
loadedCars = {}
rec(505, "PACKED", nil)
local r505 = restore(505)
local r505checked = restore(505, 1, true)
rec(506, "PACKED", true)
local r506 = restore(506)
local s506 = Store.read(506)
local claim506, why506 = Store.claim(506, player)
rec(507, "UNPACKED", nil)
local r507 = restore(507, 1, true)
rec(508, "UNPACKED", nil)
spawnFails = true
local r508 = restore(508, 1, true)
spawnFails = false
nowMs = nowMs + Store.SETTLE_MS
Store.settleDue(nowMs)
local s508 = Store.read(508)
rec(509, "PACKED", true)
local r509 = restore(509, 900)
quiet = false
check(table.concat(notRestorable, ",") == "NOT_RESTORABLE,NOT_RESTORABLE,NOT_RESTORABLE", "VOID、RESTORED、已落盤 UNPACKED 不能補：" .. table.concat(notRestorable, ","))
check(r504.why == "CAR_EXISTS", "紀錄的車找得到 -> CAR_EXISTS")
check(r505.why == "CHECK_SITE" and r505checked.ok, "uncertain 的 PACKED 要 checked 才補")
check(r506.ok and r506.sqlId == 99 and fileAtSpawn[506] == "RESTORED/RESTORED", "生車時快照與檔案已是 RESTORED（" .. tostring(fileAtSpawn[506]) .. "）")
local last506 = s506.history[#s506.history]
check(last506.ev == "RESTORED" and last506.car == 99 and last506.note == "gave water back" and last506.items == "Base.WaterBottle*2"
    and s506.history[#s506.history - 1].ev == "RESTORE_START", "記 RESTORE_START、RESTORED（新車、備註、貨物清單）")
check(claim506 == nil and why506 == "NOT_PACKED", "補回後原膠囊不能再展開")
check(r507.ok and Store.read(507).state == "RESTORED", "uncertain 的 UNPACKED 確認後可補")
check(r508.why == "BLOCKED" and s508.state == "UNPACKED" and s508.settled == nil and Store.uncertain(508, s508)
    and s508.history[#s508.history].ev == "RESTORE_FAILED", "生車失敗退回原狀態，仍是 uncertain（不會被 settle）")
check(r509.why == "BLOCKED" and Store.read(509).state == "PACKED", "補回位置沒載入 -> BLOCKED，不動狀態")

print("Guard：清空規則（哪些狀態清、哪些不動）與貨物鎖")
local owner = newPlayer("owner", false)
local function packedCapsule(state, settled, loaded)
    local cap = instanceItem(loaded or M.TYPES[1].loaded)
    local water, bag, pencil = newItem("Base.WaterBottle"), newItem("Base.Bag_Schoolbag", true), newItem("Base.Pencil")
    cap.inv:AddItem(water)
    cap.inv:AddItem(bag)
    bag.inv:AddItem(pencil)
    owner.inv:AddItem(cap)
    Store.write(cap.id, { state = state, settled = settled, script = "Base.PickUpTruck",
        sealed = { water.id, bag.id, pencil.id }, history = { { ev = "PACKED", car = 7 } } })
    return cap, water, bag, pencil
end
local function topLevel(type)
    local n = 0
    for _, x in ipairs(owner.inv.list) do if x.type == type then n = n + 1 end end
    return n
end
-- { state, settled, cleared?, marked? }：marked＝世界存檔已知道這次展開（ModData 標記）
local clearCases = {
    { "UNPACKED", true, true, true }, { "VOID", nil, true },
    { "PACKED", nil, false }, { "UNPACKED", nil, false }, { "RESTORED", true, false }, { "PACKED", true, false },
}
quiet = true
local clearResults = {}
for _, c in ipairs(clearCases) do
    local cap = packedCapsule(c[1], c[2])
    if c[4] then Store.mark(cap.id) end
    local empties = topLevel(M.TYPES[1].empty)
    Guard.pass(owner)
    local gone = owner.inv:getItemWithIDRecursiv(cap.id) == nil
    local h = Store.read(cap.id).history
    local cleared = gone and topLevel(M.TYPES[1].empty) == empties + 1 and h[#h].ev == "CLEARED"
        and h[#h].items:find("Base.Pencil*1", 1, true) ~= nil
    clearResults[#clearResults + 1] = { (c[3] and cleared) or (not c[3] and not gone and h[#h].ev ~= "CLEARED"),
        c[1] .. (c[2] and "+settled" or "+unsettled") .. (c[3] and " -> 換成空膠囊、記 CLEARED 與貨物" or " -> 不動") }
    if not gone then owner.inv:Remove(cap) end
end
do -- same type back: a cleared steam capsule becomes an empty steam capsule (checked with the others below)
    local steam = M.TYPE_BY_ID.Steam
    local steamCap = packedCapsule("VOID", nil, steam.loaded)
    local before = topLevel(steam.empty)
    Guard.pass(owner)
    clearResults[#clearResults + 1] = { owner.inv:getItemWithIDRecursiv(steamCap.id) == nil
        and topLevel(steam.empty) == before + 1, "清空時換成同一種空膠囊（蒸汽換蒸汽）" }
end
local stale = packedCapsule("UNPACKED", true)
Store.mark(stale.id)
local unpackRes = M.Unpack.unpack(owner, stale, nil, "N")
local staleGone = owner.inv:getItemWithIDRecursiv(stale.id) == nil
local cap, water, bag, pencil = packedCapsule("PACKED", true)
cap.inv:Remove(water)
owner.inv:AddItem(water)
cap.inv:Remove(bag)
owner.inv:AddItem(bag)
Guard.pass(owner)
local lockH = Store.read(cap.id).history
cap.inv:Remove(water)
owner.inv:AddItem(water)
water.equipped = true
Guard.pass(owner)
Guard.pass(owner)
local missing = 0
for _, e in ipairs(Store.read(cap.id).history) do if e.why == "missing" then missing = missing + 1 end end
quiet = false
for _, cr in ipairs(clearResults) do check(cr[1], cr[2]) end
check(unpackRes.why == "CLEARED" and staleGone, "展開時遇到已落盤的 UNPACKED：拒絕並清空（CLEARED）")
check(bag.container == cap.inv and pencil.container == bag.inv and topLevel("Base.Bag_Schoolbag") == 0,
    "搬出的背包連同裡面的鉛筆放回膠囊，玩家身上不留")
local lockEv = lockH[#lockH]
check(lockEv.ev == "CARGO_LOCK" and lockEv.why == "returned" and lockEv.items:find("Base.WaterBottle", 1, true) ~= nil
    and lockEv.items:find("Base.Bag_Schoolbag", 1, true) ~= nil, "記 CARGO_LOCK returned（水瓶、背包）：" .. tostring(lockEv.items))
check(water.container == owner.inv and missing == 1, "裝備中的物品不硬拿，只記一次 missing")

do -- 拿出模式（AllowCargoTakeOut）：主程式的 local 已接近 200 個上限，放進函式
    (function()
        print("Guard：伺服器允許拿出貨物時，跟著紀錄、不放回；沒落盤的照樣放回")
        owner.inv:Remove(cap) -- 上面貨物鎖那顆（水瓶裝備中）不參與
        SandboxVars = { MinidoracatPackThrow = { AllowCargoTakeOut = true } }
        quiet = true
        local open, water, bag, pencil = packedCapsule("PACKED", true)
        local s0 = Store.read(open.id)
        s0.manifest = { ["Base.WaterBottle"] = 1, ["Base.Bag_Schoolbag"] = 1 }
        Store.write(open.id, s0)
        open.inv:Remove(water)
        owner.inv:AddItem(water)
        bag.inv:Remove(pencil)
        owner.inv:AddItem(pencil)
        Guard.pass(owner)
        Guard.pass(owner)
        local s1 = Store.read(open.id)
        local taken = 0
        for _, e in ipairs(s1.history) do if e.ev == "CARGO_TAKEN" then taken = taken + 1 end end
        local last = s1.history[#s1.history]
        owner.inv:Remove(open)
        local settling, water2 = packedCapsule("PACKED", nil)
        settling.inv:Remove(water2)
        owner.inv:AddItem(water2)
        Guard.pass(owner)
        local h2 = Store.read(settling.id).history
        owner.inv:Remove(settling)
        local R = M.Rules
        local only = R.cargoOpen({ state = "PACKED", settled = true }) and not R.cargoOpen({ state = "PACKED", settled = false })
            and not R.cargoOpen({ state = "UNPACKED", settled = true }) and not R.cargoOpen({ state = "VOID", settled = true })
            and not R.cargoOpen(nil)
        SandboxVars = nil
        local off = not R.cargoOpen({ state = "PACKED", settled = true })
        quiet = false
        check(water.container == owner.inv and pencil.container == owner.inv,
            "已落盤的膠囊：拿出的水瓶、背包裡拿出的鉛筆都留在玩家身上")
        check(#s1.sealed == 1 and s1.sealed[1] == bag.id and s1.manifest["Base.Bag_Schoolbag"] == 1
            and s1.manifest["Base.WaterBottle"] == nil, "紀錄只剩還在膠囊裡的背包（sealed、manifest）")
        check(taken == 1 and last.ev == "CARGO_TAKEN" and last.items:find("Base.WaterBottle*1", 1, true) ~= nil
            and last.items:find("Base.Pencil*1", 1, true) ~= nil, "記一次 CARGO_TAKEN（水瓶、鉛筆），第二輪不重記：" .. tostring(last.items))
        check(water2.container == settling.inv and h2[#h2].ev == "CARGO_LOCK" and h2[#h2].why == "returned",
            "剛收好、還沒落盤的膠囊照樣放回（CARGO_LOCK returned）")
        check(only and off, "Rules.cargoOpen：只有已落盤的 PACKED，而且沙盒開著")
    end)()
end

do -- 回溯判斷：主程式的 local 已接近 200 個上限，放進函式
    (function()
        print("Guard.stale：世界存檔比展開舊（沒有 ModData 標記）時，車在才清空，車不在交給管理員")
        local function unpackedTo(car)
            local c = packedCapsule("UNPACKED", true)
            local s = Store.read(c.id)
            s.history[#s.history + 1] = { ev = "UNPACKED", car = car, x = 1, y = 1, z = 0 }
            Store.write(c.id, s)
            return c
        end
        quiet = true
        local lost = unpackedTo(4242) -- 車跟著世界回溯不見了
        Guard.pass(owner)
        local afterLost = Store.read(lost.id)
        local keptLost = owner.inv:getItemWithIDRecursiv(lost.id) ~= nil
        owner.inv:Remove(lost)
        local here = unpackedTo(4343) -- 當機：車已寫進 vehicles.db，膠囊跟著玩家存檔回來
        loadedCars[#loadedCars + 1] = fakeCar(4343)
        Guard.pass(owner)
        local hereGone = owner.inv:getItemWithIDRecursiv(here.id) == nil
        local hh = Store.read(here.id).history
        local thrown = unpackedTo(4444)
        local res = M.Unpack.unpack(owner, thrown, nil, "N")
        local thrownKept = owner.inv:getItemWithIDRecursiv(thrown.id) ~= nil
        owner.inv:Remove(thrown)
        local resolved = Admin.resolve(newPlayer("adm", true), thrown.id, "present", nil, true)
        quiet = false
        check(keptLost and afterLost.settled == nil and Store.uncertain(lost.id, afterLost)
            and afterLost.history[#afterLost.history].ev == "SUSPECT", "車不在：膠囊不動，紀錄改回當機前未確認（SUSPECT）")
        check(hereGone and hh[#hh].ev == "CLEARED" and Store.marked(here.id), "車在：清空重複的貨物並補上標記")
        check(res.ok == false and res.why == "UNCERTAIN" and thrownKept, "丟出時遇到同樣情況：拒絕（UNCERTAIN），膠囊不動")
        check(resolved.ok and Store.marked(thrown.id), "管理員判定「車在」後補上標記，下一輪照常清空")
    end)()
end

-- ===== Phase 3：落點範圍、收車權限、玩家身分（intent） =====
require "MinidoracatPackThrow/Footprint"
require "MinidoracatPackThrow/Rules"
local clientCommand
Events.OnClientCommand = { Add = function(fn) clientCommand = clientCommand or fn end } -- PlayerCommands' (the first)
require "MinidoracatPackThrow/PlayerCommands"
local Footprint, Rules, Play = M.Footprint, M.Rules, M.Play

print("Footprint：方向與範圍")
check(Footprint.dirOf(5, 1) == "E" and Footprint.dirOf(-5, 1) == "W" and Footprint.dirOf(1, 6) == "S"
    and Footprint.dirOf(0, -3) == "N" and Footprint.dirOf(3, 3) == "E", "丟出方向取最近的東南西北")
-- 車身繞中心最多偏 0.2 rad（addVehicleDebug）：四角在各角度都要落在 box 內
local function bodyInside(x, y, dir, w, l)
    local b = Footprint.box(x, y, dir, w, l)
    local base = ({ N = 0, S = 0, E = math.pi / 2, W = math.pi / 2 })[dir]
    for _, da in ipairs({ -0.2, -0.1, 0, 0.1, 0.2 }) do
        local a = base + da
        for _, c in ipairs({ { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }) do
            local lx, ly = c[1] * w / 2, c[2] * l / 2 -- 寬沿 x、長沿 y（朝北）
            local px = x + lx * math.cos(a) - ly * math.sin(a)
            local py = y + lx * math.sin(a) + ly * math.cos(a)
            local tx, ty = math.floor(px), math.floor(py)
            if tx < b.x1 or tx > b.x2 or ty < b.y1 or ty > b.y2 then return false, b end
        end
    end
    return true, b
end
local inN, bN = bodyInside(10, 20, "N", 2.2, 5.0)
local inE, bE = bodyInside(10, 20, "E", 2.2, 5.0)
check(inN and inE, "皮卡（2.2×5）朝北／朝東轉 ±0.2 rad，四角都在 box 內")
check(bN.y2 - bN.y1 > bN.x2 - bN.x1 and bE.x2 - bE.x1 > bE.y2 - bE.y1, "朝北長邊沿 y、朝東長邊沿 x")

-- 假格子：預設空曠的戶外地面
IsoFlagType = { solidfloor = "solidfloor", water = "water" }
for k in pairs(loadedSquares) do loadedSquares[k] = nil end
local function fakeSquare(x, y)
    local s = { x = x, y = y, free = true, floor = true, outside = true, wallE = false, wallS = false }
    function s:getX() return self.x end
    function s:getY() return self.y end
    function s:getZ() return 0 end
    function s:getVehicleContainer() return self.vehicle end
    function s:getMovingObjects() return javaList(self.movers or {}) end
    function s:isFree() return self.free and self.floor and not self.tree end
    function s:HasTree() return self.tree == true end
    function s:has(flag) return (flag == "solidfloor" and self.floor) or (flag == "water" and self.water == true) end
    function s:getAnimals() return javaList(self.animals or {}) end
    function s:isOutside() return self.outside end
    function s:isBlockedTo(o)
        if o.x == self.x + 1 then return self.wallE end
        if o.y == self.y + 1 then return self.wallS end
        return false
    end
    loadedSquares[x .. "," .. y] = s
    return s
end
for x = 0, 30 do for y = 0, 40 do fakeSquare(x, y) end end
local function sq(x, y) return loadedSquares[x .. "," .. y] end
local function getSq(x, y) return sq(x, y) end
local pickup = { getExtents = function() return { x = function() return 2.2 end, z = function() return 5.0 end } end }
local function clearAt(x, y, dir) return (Footprint.clear(pickup, x, y, 0, dir or "N")) end
check(clearAt(10, 20) == nil, "空地：放得下")
local function blockedBy(setup, undo, want, label)
    setup()
    local got = clearAt(10, 20)
    undo()
    check(got == want, label .. "（得到 " .. tostring(got) .. "）")
end
blockedBy(function() sq(9, 18).tree = true end, function() sq(9, 18).tree = nil end, "TREE", "車身範圍內有樹")
blockedBy(function() sq(10, 22).free = false end, function() sq(10, 22).free = true end, "SOLID", "車身範圍內有家具")
blockedBy(function() sq(11, 17).floor = false end, function() sq(11, 17).floor = true end, "NO_FLOOR", "沒有地面（水）")
blockedBy(function() sq(8, 22).vehicle = {} end, function() sq(8, 22).vehicle = nil end, "VEHICLE", "另一台車壓到範圍")
blockedBy(function() sq(10, 17).movers = { {} } end, function() sq(10, 17).movers = nil end, "PERSON", "範圍內有人或殭屍")
blockedBy(function() sq(10, 16).movers = { {} } end, function() sq(10, 16).movers = nil end, nil, "車頭前一格的人不算")
blockedBy(function() sq(9, 20).wallE = true end, function() sq(9, 20).wallE = false end, "WALL", "範圍內兩格之間有牆或圍欄")
blockedBy(function() sq(11, 20).wallE = true end, function() sq(11, 20).wallE = false end, nil, "範圍外緣的牆不算（不擋車身）")
blockedBy(function() sq(10, 20).outside = false end, function() sq(10, 20).outside = true end, "INDOORS", "中心在室內")
blockedBy(function() loadedSquares["12,21"] = nil end, function() fakeSquare(12, 21) end, nil, "範圍外的格子沒載入不影響")
blockedBy(function() loadedSquares["11,21"] = nil end, function() fakeSquare(11, 21) end, "UNLOADED", "範圍內的格子沒載入")
check(Footprint.blocked(getSq, Footprint.box(10, 20, "E", 2.2, 5.0), 0) == nil, "朝東也放得下")
-- 按按鈕：玩家站在膠囊旁邊，車放在另一側 3 格（中心＝落點格的西北角），玩家那一格不能在範圍內
local pb = Footprint.box(23, 30, "E", 2.2, 5.0)
check(pb.x1 >= 20, "膠囊在 (20,30)、往東 3 格放車：站在膠囊西邊 (19,30) 的玩家不在範圍內（x1=" .. pb.x1 .. "）")
do -- 動物落點只看一格：水、車、樹、家具、沒地面擋；室內與有人站著可以
    local s = sq(10, 20)
    local function with(field, v, want, label)
        local old = s[field]
        s[field] = v
        local got = Footprint.animalClear(10, 20, 0)
        s[field] = old
        check(got == want, "動物落點：" .. label .. "（得到 " .. tostring(got) .. "）")
    end
    with("water", true, "WATER", "水上不行（IsoAnimal.new 在水上不初始化）")
    with("vehicle", {}, "VEHICLE", "車底下不行")
    with("tree", true, "TREE", "樹不行")
    with("free", false, "SOLID", "家具不行")
    with("floor", false, "NO_FLOOR", "沒有地面不行")
    with("outside", false, nil, "室內可以")
    with("movers", { {} }, nil, "有人站著也可以（只看 isFree(false)）")
    local why, box = Footprint.animalClear(10, 20, 0)
    check(why == nil and box.x1 == 10 and box.x2 == 10 and box.y1 == 20 and box.y2 == 20
        and Footprint.animalClear(99, 99, 0) == "UNLOADED", "動物只占一格；沒載入的格子 UNLOADED")
end

print("Footprint：丟擲距離與視線")
local losBlocked = false
LosUtil = { lineClear = function() return losBlocked and "Blocked" or "Clear" end }
check(Footprint.reach(10.5, 10.5, 0, 17, 10, 0, 8, true) == nil, "7 格、看得到：可以丟")
check(Footprint.reach(10.5, 10.5, 0, 19, 10, 0, 8, true) == "TOO_FAR", "8.5 格：太遠")
check(Footprint.reach(10.5, 10.5, 1, 15, 10, 0, 8, true) == "TOO_FAR", "不同樓層：不行")
losBlocked = true
check(Footprint.reach(10.5, 10.5, 0, 15, 10, 0, 8, true) == "NO_SIGHT", "視線被擋：看不到")
check(Footprint.reach(10.5, 10.5, 0, 12, 10, 0, 3, false) == nil, "按按鈕不看視線，只看 3 格內")
losBlocked = false

print("Rules：膠囊種類、收車權限")
do
    local T1, T4, T6 = M.TYPES[1], M.TYPE_BY_ID.Steam, M.TYPE_BY_ID.Magic
    local kp = newPlayer("kinds", false)
    kp.inv:AddItem(instanceItem(T4.empty))
    kp.inv:AddItem(instanceItem(T4.empty))
    kp.inv:AddItem(instanceItem(T1.empty))
    kp.inv:AddItem(instanceItem(M.FIRST_SPHERE.empty))
    SandboxVars = { MinidoracatPackThrow = { TypeSteam = false } }
    local kinds, spheres = Rules.emptyTypes(kp), Rules.emptyTypes(kp, true)
    check(#kinds == 2 and kinds[1].type == T1 and kinds[1].n == 1 and kinds[1].on and kinds[2].type == T4
        and kinds[2].n == 2 and not kinds[2].on and #spheres == 1 and spheres[1].type == M.FIRST_SPHERE,
        "emptyTypes：照 M.TYPES 順序列出帶著的款式、數量與是否啟用；車輛選單只列膠囊、動物選單只列帕魯球")
    check(Rules.typeOn(T1) and not Rules.typeOn(T4) and not Rules.typeOn(nil), "typeOn：沙盒 Type<id> 關掉才算停用")
    local savedV, savedM = Rules.vehicleWhyNot, Rules.mayPack
    Rules.vehicleWhyNot, Rules.mayPack = function() return nil end, function() return true end
    check(Rules.packWhyNot(kp, {}, T4) == "TYPE_OFF" and Rules.packWhyNot(kp, {}, T6) == "NO_CAPSULE"
        and Rules.packWhyNot(kp, {}, nil) == "NO_CAPSULE" and Rules.packWhyNot(kp, {}, T1) == nil
        and Rules.packWhyNot(kp, {}, M.FIRST_SPHERE) == "WRONG_ITEM",
        "packWhyNot：停用的款式 TYPE_OFF、沒帶的或沒指定 NO_CAPSULE、帕魯球收不了車 WRONG_ITEM、帶著且啟用的放行")
    Rules.vehicleWhyNot, Rules.mayPack = savedV, savedM
    SandboxVars = nil
    check(Rules.typeOn(T4), "沒有沙盒值＝啟用（預設七種全開）")
end
local car = { keyId = 4242, ignition = false }
function car:getKeyId() return self.keyId end
function car:isKeysInIgnition() return self.ignition end
function car:getCurrentKey() return nil end
local keyHolder, stranger, admin3 = newPlayer("keyholder", false), newPlayer("stranger", false), newPlayer("boss", true)
keyHolder.inv.haveThisKeyId = function(_, id) return id == 4242 and {} or nil end
stranger.inv.haveThisKeyId = function() return nil end
admin3.inv.haveThisKeyId = function() return nil end
SandboxVars = { MinidoracatPackThrow = { PackPermission = 1 } }
check(Rules.mayPack(keyHolder, car) and not Rules.mayPack(stranger, car), "模式 1：有鑰匙才行（背包）")
check(Rules.mayPack(admin3, car) and select(2, Rules.mayPack(admin3, car)) == "ADMIN", "模式 1：管理員沒鑰匙也能收")
SandboxVars.MinidoracatPackThrow.PackPermission = 3
check(not Rules.mayPack(stranger, car) and not Rules.mayPack(keyHolder, car), "模式 3：有鑰匙的一般玩家也不行")
do -- VehicleManager 假實作：照玩家回答，記下問的是哪個權限（收車＝拖曳 TOW）
    local vmAsked
    local function vmStub(answers)
        return { canUse = function(p, _, action)
            vmAsked = action
            local a = answers[p] or { false, "NOT_AUTHORIZED" }
            return a[1], a[2]
        end }
    end
    MinidoracatVehicleManagerAPI = vmStub({})
    check(not Rules.mayPack(admin3, car) and vmAsked == "TOW", "VehicleManager 綁定的車：問拖曳權限；管理員沒開越權也不行")
    MinidoracatVehicleManagerAPI = nil
    SandboxVars.MinidoracatPackThrow.PackPermission = 1
    car.ignition = true
    check(Rules.mayPack(stranger, car), "模式 1：鑰匙插在點火孔，誰都能收")
    car.ignition = false
    SandboxVars.MinidoracatPackThrow.PackPermission = 2
    check(Rules.mayPack(stranger, car), "模式 2：任何人")
    SandboxVars.MinidoracatPackThrow.PackPermission = 3
    check(Rules.mayPack(admin3, car) and not Rules.mayPack(keyHolder, car), "模式 3：只有管理員")
    MinidoracatVehicleManagerAPI = vmStub({ [stranger] = { true, "OWNER" }, [keyHolder] = { true, "MEMBER" },
        [admin3] = { false, "RENT_LOCKED" } })
    local ownOk, ownMode = Rules.mayPack(stranger, car)
    local shOk, shMode = Rules.mayPack(keyHolder, car)
    local lkOk, lkMode, lkWhy = Rules.mayPack(admin3, car)
    check(ownOk and ownMode == "VM" and shOk and shMode == "SHARED",
        "VehicleManager 綁定的車：車主與被分享拖曳的人都能收（模式 3 的沙盒不看）")
    check(not lkOk and lkMode == "VM" and lkWhy == "RENT_LOCKED", "VehicleManager 擋下時帶回它的原因（租用到期鎖定）")
    MinidoracatVehicleManagerAPI = vmStub({ [admin3] = { true, "ADMIN" } })
    local ovOk, ovMode = Rules.mayPack(admin3, car)
    check(ovOk and ovMode == "ADMIN" and not Rules.mayPack(keyHolder, car),
        "VehicleManager 越權中的管理員算「管理員」；別人綁定的車，有鑰匙也不行")
    MinidoracatVehicleManagerAPI = { canUse = function() return true, "UNCLAIMED" end }
    SandboxVars.MinidoracatPackThrow.PackPermission = 1
    local unOk, unMode = Rules.mayPack(admin3, car)
    check(Rules.mayPack(keyHolder, car) and not Rules.mayPack(stranger, car) and unOk and unMode == "ADMIN",
        "VehicleManager 沒綁定的車照沙盒：模式 1 要鑰匙，管理員照常")
    MinidoracatVehicleManagerAPI = nil
    SandboxVars = nil
end

print("Play：身分只認 OnClientCommand 的連線（intent）")
local alice, bob = newPlayer("alice", false), newPlayer("bob", false)
clientCommand(M.MODULE, "intent", alice, { kind = "pack", id = 77, type = "Steam" })
clientCommand(M.MODULE, "intent", alice, { kind = "nuke", id = 77 })
clientCommand(M.MODULE, "intent", alice, { kind = "pack", id = 78, type = "Rocket" })
check(Play.takeIntent(bob, "pack", 77) == nil, "別人的 intent 不能拿來用（bob 冒充 alice 的車）")
local it = Play.takeIntent(alice, "pack", 77)
check(it ~= nil and it.type == M.TYPE_BY_ID.Steam, "同一連線的 intent 可用，帶著要用的款式：" .. tostring(it and it.type and it.type.id))
do
    local it78 = Play.takeIntent(alice, "pack", 78)
    check(it78 ~= nil and it78.type == nil, "不認得的款式不帶（Play.pack 回 NO_CAPSULE）")
end
check(Play.takeIntent(alice, "pack", 77) == nil, "intent 用一次就沒了")
check(Play.takeIntent(alice, "nuke", 77) == nil, "不認得的種類不收")
clientCommand(M.MODULE, "intent", alice, { kind = "throw", id = 9 })
nowMs = nowMs + 61000
check(not Play.hasIntent(alice, "throw", 9), "60 秒後過期")
logLines = {}
local printed, savedPrint = {}, print
alice.inv.containsID = function() return false end
print = function(s) printed[#printed + 1] = tostring(s) end
local refused = Play.pack(alice, { getId = function() return 77 end }, "local")
local thrown = Play.throw({ character = alice, item = { getID = function() return 5 end,
    getFullType = function() return M.TYPES[1].loaded end }, x = 1, y = 1, z = 0 })
print = savedPrint
check(refused == false and printed[1] and printed[1]:find("pack refused by=alice why=NO_INTENT", 1, true) ~= nil,
    "沒有 intent 的收車被拒並記一行：" .. tostring(printed[1]))
check(thrown == false, "膠囊不在背包裡的丟擲被拒")
do -- 動作瞬間完成（管理員作弊）時沒有放手事件：complete 仍要先畫飛行，FLIGHT_MS 後落地
    (function()
        local Fx, Fp, Th = M.Fx, M.Footprint, M.Throw
        local kinds, at = {}, nil
        local saved = { Fx.broadcast, Fp.reach, Th.schedule }
        Fx.broadcast = function(kind) kinds[#kinds + 1] = kind end
        Fp.reach = function() return nil end
        Th.schedule = function(_, t) at = t end
        alice.inv.containsID = function() return true end
        clientCommand(M.MODULE, "intent", alice, { kind = "throw", id = 5 })
        local ok = Play.throw({ character = alice, item = { getID = function() return 5 end,
            getFullType = function() return M.TYPES[1].loaded end }, x = 1, y = 1, z = 0 })
        Fx.broadcast, Fp.reach, Th.schedule = saved[1], saved[2], saved[3]
        check(ok == true and kinds[1] == "flight" and at == nowMs + Th.FLIGHT_MS,
            "沒有放手事件時 complete 先送飛行特效、FLIGHT_MS 後落地（" .. tostring(kinds[1]) .. "）")
    end)()
end
do -- 收動物：intent 種類 packAnimal（id＝動物的 onlineID），沒有 intent 的動作被拒並記一行
    (function()
        local carol = newPlayer("carol", false)
        local cow = { getOnlineID = function() return 31 end }
        local lines, saved = {}, print
        print = function(s) lines[#lines + 1] = tostring(s) end
        local noIntent = Play.packAnimal(carol, cow, "Cartoon")
        print = saved
        clientCommand(M.MODULE, "intent", carol, { kind = "packAnimal", id = 31, type = "Steam" })
        local it = Play.takeIntent(carol, "packAnimal", 31)
        check(noIntent == false and lines[1] ~= nil and lines[1]:find("packAnimal refused by=carol why=NO_INTENT", 1, true) ~= nil,
            "沒有 intent 的收動物被拒並記一行：" .. tostring(lines[1]))
        check(it ~= nil and it.type == M.TYPE_BY_ID.Steam and Play.takeIntent(carol, "pack", 31) == nil,
            "packAnimal intent 帶動物的 onlineID 與款式，不能拿去收車")
    end)()
end
-- ===== Phase 4：索引分頁、查詢權限、管理指令、戰利品權重 =====
-- 新的假全域：原生沙盒選項、server->client 指令
local sandbox = {}
function getSandboxOptions()
    return { getOptionByName = function(_, name)
        local k = name:match("^MinidoracatPackThrow%.(.+)$")
        if k == nil or sandbox[k] == nil then return nil end
        return { getValue = function() return sandbox[k] end }
    end }
end
local sent = {}
function sendServerCommand(...) sent[#sent + 1] = { ... } end

-- 把舊情境的紀錄清掉，Phase 4 從空的桶開始（Store 對桶檔的快取一起清）
for path in pairs(files) do files[path] = nil end
Store._resetForTests()
require "MinidoracatPackThrow/Index"
require "MinidoracatPackThrow/Query"
require "MinidoracatPackThrow/AdminCommands"
require "MinidoracatPackThrow/Loot"
local Index, Query, AdminCommands, Loot = M.Index, M.Query, M.AdminCommands, M.Loot

print("Index：分頁 50 筆、搜尋編號與玩家、狀態篩選（含當機前未確認）")
-- 65 筆：60 筆 PACKED（玩家 p0..p5 輪流收）、2 筆 UNPACKED（ann 展開）、1 筆 RESTORED、1 筆 VOID、1 筆 uncertain
quiet = true
local base = nowMs
for i = 1, 60 do
    Store.write(70000 + i, { state = "PACKED", settled = true, script = "Base.PickUpTruck", name = "Pickup", packedBy = "P" .. (i % 6),
        history = { { t = base + i, ev = "PACKED", by = "P" .. (i % 6), x = i, y = 2, z = 0, car = i } } })
end
for i = 61, 62 do
    Store.write(70000 + i, { state = "UNPACKED", settled = true, packedBy = "p1", history = {
        { t = base + i, ev = "PACKED", by = "p1", car = i }, { t = base + 100 + i, ev = "UNPACKED", by = "Ann", car = 900 + i } } })
end
Store.write(70063, { state = "RESTORED", settled = true, packedBy = "p2", history = { { t = base + 63, ev = "PACKED", by = "p2" } } })
Store.write(70064, { state = "VOID", settled = true, packedBy = "p3", history = { { t = base + 64, ev = "PACKED", by = "p3" } } })
Store.write(70065, { state = "PACKED", packedBy = "p4", history = { { t = base + 65, ev = "PACKED", by = "p4" } } }) -- 沒有 settled＝uncertain
quiet = false
local p1 = Index.page({}, 1)
local p2 = Index.page({}, 2)
check(#p1.rows == 50 and p1.total == 65 and p1.pages == 2 and #p2.rows == 15, "65 筆分成 50＋15（" .. #p1.rows .. "+" .. #p2.rows .. "）")
check(p1.rows[1].id == 70065 and p2.rows[15].id == 70001, "新收的在前（第一筆 " .. tostring(p1.rows[1].id) .. "）")
check(p1.rows[1].uncertain == true and p1.counts.UNCERTAIN == 1, "沒有 settled 的紀錄標 uncertain 並計數")
check(p1.counts.PACKED == 61 and p1.counts.UNPACKED == 2 and p1.counts.RESTORED == 1 and p1.counts.VOID == 1,
    "各狀態計數 PACKED 61 / UNPACKED 2 / RESTORED 1 / VOID 1")
local unc = Index.page({ state = "UNCERTAIN" }, 1)
check(unc.total == 1 and unc.rows[1].id == 70065, "篩「當機前未確認」只剩那一筆")
check(Index.page({ state = "UNPACKED" }, 1).total == 2, "篩已展開 2 筆")
check(Index.page({ q = "70064" }, 1).total == 1, "搜尋完整編號")
check(Index.page({ q = "7006" }, 1).total == 6, "搜尋編號片段（70060..70065）")
check(Index.page({ q = "  ANN " }, 1).total == 2, "搜尋玩家不分大小寫、去空白，展開者也算")
check(Index.page({ q = "p1" }, 1).total == 12, "搜尋收車者 p1（10 筆 PACKED＋2 筆 UNPACKED）")
check(Index.page({}, 99).page == 2 and Index.page({}, -3).page == 1, "頁碼夾在 1..pages")
check(Index.page({ q = "nobody" }, 1).pages == 1 and #Index.page({ q = "nobody" }, 1).rows == 0, "沒有結果仍是 1 頁、0 列")

-- 序列化大小估算（TableNetworkUtils：鍵值各 1 byte 型別、字串 2 byte 長度＋UTF-8、數字 8 byte、每層 4 byte 筆數）
local function wireSize(v)
    if type(v) == "table" then
        local n = 4
        for k, x in pairs(v) do n = n + wireSize(k) + wireSize(x) end
        return n
    elseif type(v) == "string" then return 1 + 2 + #v
    elseif type(v) == "number" then return 1 + 8 end
    return 2
end
quiet = true
local longName = string.rep("W", 120)
for i = 1, 60 do
    Store.write(80000 + i, { state = "PACKED", settled = true, script = "Base." .. longName, name = longName, packedBy = longName,
        history = { { t = base + 1000 + i, ev = "PACKED", by = longName } } })
end
quiet = false
local worst = AdminCommands.handle(newPlayer("admin", true), "adminPage", { q = "", state = "ALL", page = 1 })
check(#worst.rows == 50 and wireSize(worst) < 64 * 1024, "一頁 50 筆、欄位 120 字也只有 " .. wireSize(worst) .. " bytes（遠低於 1 MB）")

print("Index：索引檔壞掉或落後時從桶重建，讀到紀錄就跟上")
Index.flush(nowMs + 10000)
check(files[Index.file()] ~= nil and Index.file() == Store.dir() .. "index.json", "flush 寫出這個世界的 index.json")
Index._resetForTests()
check(Index.page({}, 1).total == 125, "從 index.json 讀回 125 筆")
files[Index.file()] = "{broken"
Index._resetForTests()
quiet = true
local rebuilt = Index.page({}, 1).total
quiet = false
check(rebuilt == 125, "索引壞檔 -> 從桶重建 125 筆")
Index.flush(nowMs + 20000)
-- 索引沒跟上的寫入（寫完紀錄、下次 flush 之前當機）：先拔掉監聽器，模擬索引沒看到
local listeners = Store.listeners
Store.listeners = {}
Store.write(70066, { state = "PACKED", settled = true, packedBy = "late", history = { { t = base + 66, ev = "PACKED", by = "late" } } })
Store.drop({ 70001 })
Store.listeners = listeners
Index._resetForTests()
check(Index.page({ q = "late" }, 1).total == 1 and Index.page({ q = "70001" }, 1).total == 0,
    "桶的代數和索引記的不同：重讀那個桶，補進新紀錄、拿掉不在的")
local s70002 = Store.read(70002)
s70002.state = "VOID"
Store.write(70002, s70002)
check(Index.page({ q = "70002" }, 1).rows[1].state == "VOID", "寫入後索引同步（VOID）")

do -- 桶檔、保留天數、最後看到：主程式的 local 已接近 200 個上限，放進函式
    (function()
        print("Store：桶檔兩份輪流寫，寫到一半的那份被略過，兩份都不完整就不動")
        local id = 999999
        local b = Store.bucketOf(id)
        local function headOf(side)
            local t = files[Store.path(b, side)]
            return t and tonumber(t:match("^MVC1 (%d+)"))
        end
        Store.write(id, { state = "PACKED", settled = true, note = "v1", history = {} })
        local g1 = Store.gen(b)
        local side1 = headOf("a") == g1 and "a" or "b"
        Store.write(id, { state = "PACKED", settled = true, note = "v2", history = {} })
        local side2 = headOf("a") == g1 + 1 and "a" or "b"
        files[Store.path(b, side2)] = files[Store.path(b, side2)]:gsub("\nEND [^\n]*$", "") -- 寫到一半當機：沒有結尾
        Store._resetForTests()
        local back = Store.read(id)
        local genBack = Store.gen(b)
        Store.write(id, { state = "PACKED", settled = true, note = "v3\nEND 1 1", history = {} }) -- 換行要逸出：一筆一行
        local v3 = Store.read(id)
        local saveA, saveB = files[Store.path(b, "a")], files[Store.path(b, "b")]
        files[Store.path(b, "a")], files[Store.path(b, "b")] = "MVC1 9\nbroken", "MVC1 8\nbroken"
        Store._resetForTests()
        quiet = true
        local _, rwhy = Store.read(id)
        local wok, wwhy = Store.write(id, { state = "PACKED", history = {} })
        quiet = false
        local untouched = files[Store.path(b, "a")] == "MVC1 9\nbroken" and files[Store.path(b, "b")] == "MVC1 8\nbroken"
        files[Store.path(b, "a")], files[Store.path(b, "b")] = saveA, saveB
        Store._resetForTests()
        check(side1 ~= side2 and headOf(side1) == g1, "第二次寫進另一份、代數加一（" .. side1 .. " -> " .. side2 .. "）")
        check(back and back.note == "v1" and genBack == g1, "比較新的那份沒寫完：改用上一份（v1）")
        check(v3 and v3.note == "v3\nEND 1 1", "之後的寫入蓋掉沒寫完的那份；欄位裡的換行原樣讀回")
        check(rwhy == "CORRUPT" and wok == nil and wwhy == "CORRUPT" and untouched, "兩份都不完整：讀寫都回 CORRUPT，檔案原樣留給管理員")
        check(Store.bucketOf(-5) == 251 and Store.bucketOf(256 * 7 + 3) == 3, "負的編號也落在 0..255")

        print("Index.prune：結束的紀錄超過保留天數就刪，收起中、未確認、還沒到期的留著")
        local day = 86400000
        local old = nowMs - 40 * day
        local function rec(cid, state, settled, t)
            Store.write(cid, { state = state, settled = settled, history = { { t = t, ev = state, by = "p" } } })
        end
        rec(990001, "UNPACKED", true, old)
        rec(990002, "RESTORED", true, old)
        rec(990003, "PACKED", true, old)
        rec(990004, "UNPACKED", nil, old) -- 當機前未確認
        rec(990006, "RESTORED", nil, old) -- 補回寫到一半當機：同樣未確認
        rec(990005, "VOID", true, nowMs - day)
        Store.mark(990001)
        quiet = true
        local done = Index.prune(nowMs, 30, 256)
        quiet = false
        check(done and select(2, Store.read(990001)) == "NO_SNAPSHOT" and select(2, Store.read(990002)) == "NO_SNAPSHOT",
            "40 天前結束的（已展開、已補回）刪掉")
        check(Store.read(990003) ~= nil and Store.read(990004) ~= nil and Store.read(990006) ~= nil and Store.read(990005) ~= nil,
            "收起中、當機前未確認（展開或補回）、昨天才作廢的留著")
        check(not Store.marked(990001) and Index.page({ q = "990001" }, 1).total == 0, "ModData 標記與索引列一起拿掉")
        rec(990011, "UNPACKED", true, old)
        rec(990012, "UNPACKED", true, old)
        rec(990013, "UNPACKED", true, old)
        quiet = true
        local first = Index.prune(nowMs, 30, 2)
        local second = Index.prune(nowMs, 30, 2)
        quiet = false
        check(first == false and second == true and Index.page({ q = "99001" }, 1).total == 0,
            "一次最多兩個桶，剩下的下一輪再刪")

        print("Index：收起中又 7 天沒人看到的膠囊")
        Store.write(990021, { state = "PACKED", settled = true, history = { { t = nowMs - 10 * day, ev = "PACKED", by = "u" } } })
        Store.write(990022, { state = "PACKED", settled = true, seen = { t = nowMs - day, where = "ground", x = 1, y = 2, z = 0 },
            history = { { t = nowMs - 10 * day, ev = "PACKED", by = "u" } } })
        local unseen = Index.page({ q = "99002", state = "UNSEEN" }, 1)
        check(unseen.total == 1 and unseen.rows[1].id == 990021 and unseen.counts.UNSEEN == 1,
            "10 天前收、之後沒被看到的算；昨天才看到的不算")
        local detail = AdminCommands.handle(newPlayer("admin", true), "adminDetail", { id = 990022 })
        check(detail.seen and detail.seen.where == "ground" and detail.seen.x == 1, "管理面板明細帶最後看到的位置")

        print("Store.seen：同一人同一處一小時內只寫一次；換人、換地方、地上的膠囊換格或過一小時才再寫；不記時間軸、不叫客戶端丟快取")
        Store.write(990031, { state = "PACKED", settled = true, history = { { t = nowMs, ev = "PACKED", by = "s" } } })
        local writes, sentBefore = 0, #sent
        local function count(cid, _, written, q) if cid == 990031 and written and q then writes = writes + 1 end end
        Store.listeners[#Store.listeners + 1] = count
        Store.seen(990031, { where = "player", by = "amy", x = 1, y = 1, z = 0 })
        Store.seen(990031, { where = "player", by = "amy", x = 2, y = 2, z = 0 })
        Store.seen(990031, { where = "player", by = "ben", x = 2, y = 2, z = 0 })
        nowMs = nowMs + Store.SEEN_MS
        Store.seen(990031, { where = "player", by = "ben", x = 3, y = 3, z = 0 })
        local byPlayer = writes
        Store.seen(990031, { where = "ground", x = 5, y = 5, z = 0 })
        Store.seen(990031, { where = "ground", x = 5, y = 5, z = 0 })
        Store.seen(990031, { where = "ground", x = 6, y = 5, z = 0 })
        Store.listeners[#Store.listeners] = nil
        local s = Store.read(990031)
        check(byPlayer == 3, "身上：寫了 3 次（第一次、換人、過一小時），走動不算")
        check(writes == 5 and s.seen.where == "ground" and s.seen.x == 6 and s.seen.by == nil and #s.history == 1,
            "地上：放下算一次、同一格不再寫、被移到隔壁格再寫")
        check(#sent == sentBefore, "看到不算改變：沒有 queryChanged")
        local amy = newPlayer("amy", false)
        local held2 = instanceItem(M.TYPES[1].loaded)
        amy.inv:AddItem(held2)
        local at = Query.near(amy, held2.id)
        check(at and at.where == "player" and at.by == "amy" and at.x == 100 and at.y == 200, "Query.near 回傳在誰身上、站在哪")

        print("Store.dir：單機一個存檔一個資料夾（SP_<模式>_<存檔>），名稱裡的特殊字元換成底線")
        local realIsServer, realGetCore, realGetWorld = isServer, getCore, getWorld
        isServer = function() return false end
        getCore = function() return { getGameMode = function() return "Apocalypse" end } end
        getWorld = function() return { getWorld = function() return "10-10-2026_12-00/x" end } end
        Store._resetForTests()
        local spDir = Store.dir()
        isServer, getCore, getWorld = realIsServer, realGetCore, realGetWorld
        Store._resetForTests()
        check(spDir == "MinidoracatPackThrow/SP_Apocalypse_10-10-2026_12-00_x/" and Store.dir() ~= spDir, "單機：" .. spDir)

        print("Store：紀錄再多檔案數也固定（256 桶 × 兩份 + index.json）；刪紀錄是改寫桶，不會多出檔案")
        local many = {}
        for i = 1, 1200 do
            many[i] = 5000000 + i
            Store.write(many[i], { state = "VOID", settled = true, history = {} })
        end
        Index.flush(nowMs + 3600000)
        local prefix = Store.dir()
        local function fileCount()
            local n = 0
            for path in pairs(files) do
                if path:sub(1, #prefix) == prefix then n = n + 1 end
            end
            return n
        end
        local full = fileCount()
        local gone = Store.drop(many)
        check(full == 2 * Store.BUCKETS + 1, "寫了 1200 筆：" .. full .. " 個檔")
        check(#gone == 1200 and fileCount() == full and select(2, Store.read(5000001)) == "NO_SNAPSHOT",
            "刪掉 1200 筆：紀錄不在了，檔案數不變")
    end)()
end

print("Query：一般玩家只能查身上或附近的膠囊，管理員都能查")
local bob = newPlayer("bob", false)
local held = instanceItem(M.TYPES[1].loaded)
bob.inv:AddItem(held)
Store.write(held.id, { state = "PACKED", settled = true, script = "Base.PickUpTruck", packedBy = "bob", skin = 2,
    parts = { GasTank = { cond = 90, item = "Base.NormalGasTank", icond = 90, amount = 12.5 }, DoorRearRight = { cond = 0 } },
    manifest = { ["Base.WaterBottle"] = 6 }, history = { { t = base, ev = "PACKED", by = "bob", car = 1 } } })
local groundCap = instanceItem(M.TYPES[1].loaded)
Store.write(groundCap.id, { state = "UNPACKED", settled = true, history = { { t = base, ev = "PACKED" }, { t = base + 5, ev = "UNPACKED", by = "ann" } } })
local farCap = instanceItem(M.TYPES[1].loaded)
Store.write(farCap.id, { state = "PACKED", settled = true, history = {} })
local function emptyList() return javaList({}) end
loadedSquares["102,201"] = {
    getWorldObjects = function() return javaList({ { getItem = function() return groundCap end } }) end,
    getObjects = emptyList, getVehicleContainer = function() return nil end,
}
local q = Query.query(bob, { held.id, groundCap.id, farCap.id, 99999999 })
local byId = {}
for _, it in ipairs(q.items) do byId[it.id] = it end
local hs = byId[held.id]
check(hs and hs.ok and hs.script == "Base.PickUpTruck" and hs.by == "bob" and hs.skin == 2 and #hs.manifest == 1
    and hs.manifest[1].n == 6, "身上的膠囊：回車種、收車者、塗裝、貨物清單")
local gas
for _, p in ipairs(hs and hs.parts or {}) do if p.id == "GasTank" then gas = p end end
check(gas and gas.a == 12.5 and gas.i == "Base.NormalGasTank" and gas.ic == 90, "零件精簡欄位（油量、物品、物品狀況）")
check(byId[groundCap.id] and byId[groundCap.id].ok and byId[groundCap.id].state == "UNPACKED"
    and byId[groundCap.id].last.by == "ann", "附近地上的膠囊可查（已展開，最後事件 ann）")
check(byId[farCap.id] and byId[farCap.id].ok == false and byId[farCap.id].why == "FAR", "不在身上也不在附近 -> FAR，不回資料")
check(byId[99999999] and byId[99999999].why == "FAR", "不存在的編號對一般玩家也只回 FAR（不洩漏有沒有紀錄）")
local qa = Query.query(newPlayer("admin", true), { farCap.id, 99999999 })
check(qa.items[1].ok and qa.items[2].why == "NO_SNAPSHOT", "管理員可查任何膠囊；沒有紀錄回 NO_SNAPSHOT")
local many = {}
for i = 1, 50 do many[i] = held.id end
check(#Query.query(bob, many).items == Query.MAX_IDS, "一次最多 " .. Query.MAX_IDS .. " 個編號")
local before = #sent
Store.write(held.id, Store.read(held.id))
check(#sent == before + 1 and sent[#sent][2] == "queryChanged" and sent[#sent][3].id == held.id, "寫入快照後廣播 queryChanged")
Store.read(held.id)
check(#sent == before + 1, "只讀不廣播")

print("AdminCommands：一般玩家一律 NOT_ADMIN；明細只回最新 100 筆歷史")
quiet = true
local refused = {}
for _, cmd in ipairs({ "adminPage", "adminDetail", "adminResolve", "adminRestore" }) do
    refused[#refused + 1] = AdminCommands.handle(bob, cmd, { id = held.id }).why
end
check(AdminCommands.handle(bob, "handle", {}) == nil and AdminCommands.handle(bob, "debugPack", {}) == nil,
    "不是 admin* 的指令不處理")
local longH = {}
for i = 1, 130 do longH[i] = { t = base + i, ev = "REJECTED", by = "x" } end
Store.write(70100, { state = "PACKED", settled = true, history = longH })
local det = AdminCommands.handle(newPlayer("admin", true), "adminDetail", { id = 70100 })
quiet = false
check(table.concat(refused, ",") == "NOT_ADMIN,NOT_ADMIN,NOT_ADMIN,NOT_ADMIN", "四個管理指令對一般玩家都拒絕：" .. table.concat(refused, ","))
check(det.ok and #det.history == 100 and det.historyTotal == 130 and det.history[100].t == base + 130, "歷史只送最新 100 筆，另回總數")

print("Loot：開關與權重照沙盒寫進表，會掉的款式平分、總量不變，重排不疊加，其他物品保留")
local function fakeList()
    return { MechanicShelfTools = { items = { "Base.Wrench", 4 } }, CrateMechanics = { items = { "Base.Jack", 2 } },
        CarSupplyTools = { items = {} }, GasStorageMechanics = { items = { "Base.Funnel", 1 } }, GarageMechanics = { items = {} },
        BarnTools = { items = { "Base.Fleshing_Tool", 10 } }, CrateAnimalFeed = { items = {} }, PetShopShelf = { items = {} },
        CratePetSupplies = { items = {} }, HuntingLockers = { items = {} } }
end
-- Total capsule weight in a table (all types), and how many capsule entries it has.
local function weightIn(list, t)
    local items, w, n = list[t].items, nil, 0
    for i = 1, #items, 2 do
        if Loot.ITEMS[items[i]] then w, n = (w or 0) + items[i + 1], n + 1 end
    end
    return w and math.floor(w * 1000 + 0.5) / 1000, n
end
local L = fakeList()
Loot.apply(L, Loot.wanted())
check(weightIn(L, "MechanicShelfTools") == 0.5 and weightIn(L, "CrateMechanics") == 0.5 and weightIn(L, "CarSupplyTools") == 0.5
    and weightIn(L, "GasStorageMechanics") == 0.3 and weightIn(L, "GarageMechanics") == nil, "沒設沙盒＝預設值（住家車庫預設關）")
check(select(2, weightIn(L, "MechanicShelfTools")) == #M.TYPES - 4, "預設七種膠囊全開：每張表七筆（沒有帕魯球），總量仍是地點的權重")
sandbox = { LootEnabled = true, LootMechanic = true, LootMechanicWeight = 2.5, LootCarSupply = false, LootCarSupplyWeight = 9,
    LootGasStation = true, LootGasStationWeight = 0, LootGarage = true, LootGarageWeight = 1.2 }
Loot.apply(L, Loot.wanted())
Loot.apply(L, Loot.wanted())
check(weightIn(L, "MechanicShelfTools") == 2.5 and weightIn(L, "CrateMechanics") == 2.5, "修車廠兩張表都是 2.5，重排兩次不疊加")
check(weightIn(L, "CarSupplyTools") == nil, "關掉的汽車用品店不出現")
check(weightIn(L, "GasStorageMechanics") == nil, "權重 0 的加油站不出現")
check(weightIn(L, "GarageMechanics") == 1.2, "打開的住家車庫 1.2")
check(L.MechanicShelfTools.items[1] == "Base.Wrench" and L.MechanicShelfTools.items[2] == 4 and L.GasStorageMechanics.items[1] == "Base.Funnel"
    and #L.GasStorageMechanics.items == 2, "原版物品原樣保留")
sandbox.TypeMagicLoot, sandbox.TypeShock = false, false
Loot.apply(L, Loot.wanted())
do
    local w5, n5 = weightIn(L, "MechanicShelfTools")
    local dropped = false
    for i = 1, #L.MechanicShelfTools.items, 2 do
        local ft = L.MechanicShelfTools.items[i]
        if ft == M.TYPE_BY_ID.Magic.empty or ft == M.TYPE_BY_ID.Shock.empty then dropped = true end
    end
    check(w5 == 2.5 and n5 == #M.TYPES - 4 - 2 and not dropped,
        "魔法關戰利品、衝擊停用：兩種都不掉，剩下的平分 2.5（" .. tostring(n5) .. " 筆，共 " .. tostring(w5) .. "）")
end
sandbox.LootEnabled = false
Loot.apply(L, Loot.wanted())
local any = false
for t in pairs(L) do if weightIn(L, t) then any = true end end
check(not any, "總開關關掉：十張表都沒有膠囊或帕魯球")
check(Loot.signature(Loot.wanted()) ~= Loot.signature((function() sandbox.LootEnabled = true; return Loot.wanted() end)()),
    "設定改了簽章就不同（觸發重排）")
sandbox = {}
do (function() -- Pal Sphere places (BarnTools, CrateAnimalFeed, PetShopShelf, CratePetSupplies, HuntingLockers)
    local function share(list, name, ft)
        local items = list[name].items
        for i = 1, #items, 2 do if items[i] == ft then return math.floor(items[i + 1] * 10000 + 0.5) / 10000 end end
        return nil
    end
    local S = fakeList()
    Loot.apply(S, Loot.wanted())
    local basic, mega, giga, legend = M.TYPE_BY_ID.SphereBasic, M.TYPE_BY_ID.SphereMega, M.TYPE_BY_ID.SphereGiga,
        M.TYPE_BY_ID.SphereLegend
    local capsInBarn, spheresInShop = false, false
    for i = 1, #S.BarnTools.items, 2 do local t = M.EMPTY[S.BarnTools.items[i]]; if t and not t.sphere then capsInBarn = true end end
    for i = 1, #S.MechanicShelfTools.items, 2 do local t = M.EMPTY[S.MechanicShelfTools.items[i]]; if t and t.sphere then spheresInShop = true end end
    check(weightIn(S, "BarnTools") == 0.4 and weightIn(S, "CrateAnimalFeed") == 0.4 and weightIn(S, "PetShopShelf") == 0.4
        and weightIn(S, "CratePetSupplies") == 0.4 and weightIn(S, "HuntingLockers") == 0.3 and select(2, weightIn(S, "BarnTools")) == 4
        and not capsInBarn and not spheresInShop and S.BarnTools.items[1] == "Base.Fleshing_Tool",
        "帕魯球三個地點（穀倉、寵物店、獵人置物櫃）預設 0.4／0.4／0.3，每張表四級各一筆；膠囊地點沒有帕魯球、帕魯球地點沒有膠囊")
    check(share(S, "BarnTools", basic.empty) == 0.2133 and share(S, "BarnTools", mega.empty) == 0.1067
        and share(S, "BarnTools", giga.empty) == 0.0533 and share(S, "BarnTools", legend.empty) == 0.0267,
        "等級稀有度 8:4:2:1：穀倉 0.4 分成 0.2133／0.1067／0.0533／0.0267")
    sandbox = { TypeSphereLegendLoot = false, TypeSphereGiga = false, LootSpherePet = false, LootSphereHuntingWeight = 1.5 }
    Loot.apply(S, Loot.wanted())
    check(weightIn(S, "BarnTools") == 0.4 and share(S, "BarnTools", basic.empty) == 0.2667 and share(S, "BarnTools", legend.empty) == nil
        and share(S, "BarnTools", giga.empty) == nil and weightIn(S, "PetShopShelf") == nil and weightIn(S, "HuntingLockers") == 1.5
        and weightIn(S, "MechanicShelfTools") == 0.5,
        "傳奇關戰利品、優質停用：剩帕魯球 8、高級 4 分 0.4（0.2667／0.1333）；寵物店關掉不出現；獵人置物櫃 1.5；膠囊地點不受影響")
    sandbox = {}
end)() end

print("Admin.restore：指定位置（方向、車身範圍）、交易中的膠囊不能補")
do (function()
    local adm = newPlayer("admin", true)
    local savedClear, savedSpawn = M.Footprint.clear, M.Unpack.spawn
    local gotDir, blocked = nil, nil
    M.Footprint.clear = function() return blocked end
    M.Unpack.spawn = function(_, _, dir)
        gotDir = dir
        local s = { getX = function() return 30 end, getY = function() return 40 end, getZ = function() return 0 end }
        return { getSquare = function() return s end, getSqlId = function() return 77 end, getId = function() return 8 end }, {}
    end
    loadedSquares["30,40"] = {}
    local function packed(id, extra)
        local s = { state = "PACKED", settled = true, script = "Base.PickUpTruck",
            history = { { t = 1, ev = "PACKED", car = 3, x = 1, y = 2, z = 0 } } }
        for k, v in pairs(extra or {}) do s[k] = v end
        Store.write(id, s)
    end
    quiet = true
    packed(71001)
    blocked = "VEHICLE"
    local rBlocked = AdminCommands.handle(adm, "adminRestore", { id = 71001, x = 30, y = 40, z = 0, dir = "E" })
    local stillPacked = Store.read(71001).state
    blocked = nil
    local rBad = AdminCommands.handle(adm, "adminRestore", { id = 71001, x = 30, y = 40, z = 0, dir = "NE" })
    local rNoSpot = AdminCommands.handle(adm, "adminRestore", { id = 71001, note = "x", checked = true })
    local noSpotState = Store.read(71001).state
    local rOk = AdminCommands.handle(adm, "adminRestore", { id = 71001, x = 30.7, y = 40.2, z = 0, dir = "E" })
    local after, dirOk = Store.read(71001), gotDir
    packed(71002, { escrow = { active = true, cargo = {} } })
    local rTrade = AdminCommands.handle(adm, "adminRestore", { id = 71002, x = 30, y = 40, z = 0, dir = "N" })
    packed(71003, { escrow = { cargo = { { id = 5, s = { type = "Base.Axe" } } } } })
    local rDone = AdminCommands.handle(adm, "adminRestore", { id = 71003, x = 30, y = 40, z = 0, dir = "S" })
    quiet = false
    check(rBlocked.why == "PICK_BLOCKED" and stillPacked == "PACKED", "指定位置被擋 -> PICK_BLOCKED，紀錄不動")
    check(rBad.why == "BAD_SPOT", "方向不是東南西北 -> BAD_SPOT")
    check(rNoSpot.why == "BAD_SPOT" and noSpotState == "PACKED", "沒帶位置的補回 -> BAD_SPOT（紀錄位置只是游標的預設，沒有不選位置的補回）")
    check(rOk.ok and dirOk == "E" and after.state == "RESTORED" and after.history[#after.history].x == 30,
        "指定位置補回：照選的方向生車、紀錄 RESTORED")
    check(rTrade.why == "IN_TRADE", "交易中的膠囊（escrow.active）不能補 -> IN_TRADE")
    check(rDone.ok and gotDir == "S" and Store.read(71003).escrow == nil, "交易結束後留下的貨物副本在補回時清掉")
    M.Footprint.clear, M.Unpack.spawn = savedClear, savedSpawn
end)() end

print("Trade：Economy 交易（檢查、交出時把貨物存進紀錄、交回時改回原編號）")
do (function()
    local refuse, initHook = {}, nil
    local function keyRing(it)
        it.keys = {}
        function it:getKeys() return javaList(self.keys) end
        function it:addKey(k) self.keys[#self.keys + 1] = k end
        return it
    end
    local eco = {
        API_MAJOR = 1, API_REVISION = 6, CAPABILITIES = { uniqueItemTypes = true, blockItemType = true },
        snapshotItem = function(it, opts)
            if refuse[it.type] then return nil, refuse[it.type] end
            return { type = it.type, cond = it.cond, contents = opts and opts.contents }
        end,
        rebuildItem = function(s)
            local it = instanceItem(s.type)
            it.cond = s.cond
            if s.type == "Base.KeyRing" then keyRing(it) end
            return it
        end,
        detachParts = function(w, container)
            local n = #w.parts
            for _, p in ipairs(w.parts) do container:AddItem(p) end
            w.parts = {}
            return n
        end,
    }
    MinidoracatEconomy = { v1 = eco }
    require "MinidoracatPackThrow/Trade"
    local Trade = M.Trade
    local seller, buyer = newPlayer("seller", false), newPlayer("buyer", false)
    local cap = instanceItem(M.TYPES[1].loaded)
    local water, rifle, scope = newItem("Base.WaterBottle"), newItem("Base.HuntingRifle"), newItem("Base.x2Scope")
    water.cond = 7
    rifle.parts = { scope }
    function rifle:getAllWeaponParts() return javaList(self.parts) end
    local bag, can = instanceItem("Base.Bag_Schoolbag"), newItem("Base.TinnedBeans")
    bag.inv:AddItem(can)
    local ring, key = keyRing(newItem("Base.KeyRing")), newItem("Base.Key1")
    ring:addKey(key)
    for _, it in ipairs({ water, rifle, bag, ring }) do cap.inv:AddItem(it) end
    -- a dedicated server weighs this mod's items at 0 (no display name, InventoryItem.java:2740-2742): the escrow adds
    -- the script weight to the contents
    function cap:getUnequippedWeight() return 12 end
    function cap:getContentsWeight() return 12 end
    function cap:getScriptItem() return { getActualWeight = function() return 0.5 end } end
    local id = cap.id
    local function record(extra)
        local s = { state = "PACKED", settled = true, script = "Base.PickUpTruck", name = "Truck",
            parts = { Engine = { cond = 63 }, Battery = { cond = 100, item = "Base.CarBattery1", uses = 0.37 },
                DoorFrontLeft = { cond = 80, item = "Base.FrontCarDoor1" }, TireFrontLeft = { cond = 0 } },
            cargo = { [water.id] = "TruckBed", [rifle.id] = "SeatFrontLeft", [bag.id] = "TruckBed", [ring.id] = "GloveBox" },
            manifest = { ["Base.WaterBottle"] = 1, ["Base.HuntingRifle"] = 1, ["Base.Bag_Schoolbag"] = 1, ["Base.KeyRing"] = 1 },
            sealed = { water.id, rifle.id, bag.id, can.id, ring.id }, history = { { t = 1, ev = "PACKED" } } }
        for k, v in pairs(extra or {}) do s[k] = v end
        Store.write(id, s)
    end
    quiet = true
    local noRec = select(2, Trade.check(instanceItem(M.TYPES[1].loaded)))
    record({ state = "UNPACKED" })
    local notPacked = select(2, Trade.check(cap))
    record({ settled = false })
    local uncertain = select(2, Trade.check(cap))
    Store.schedule(id)
    local notReady = select(2, Trade.check(cap))
    Store.settle(id)
    record()
    refuse["Base.TinnedBeans"] = "perishable"
    local cargoBad = select(2, Trade.check(cap))
    refuse["Base.TinnedBeans"] = nil
    Trade.MAX_CARGO = 3
    local tooMany = select(2, Trade.check(cap))
    Trade.MAX_CARGO = 300
    local okCheck = Trade.check(cap)
    local ext = Trade.escrow(cap, seller, "market", "L-1")
    local held = Store.read(id)
    quiet = false
    check(noRec.code == "NO_RECORD" and notPacked.code == "NOT_PACKED" and uncertain.code == "UNCERTAIN"
        and notReady.code == "NOT_READY", "沒有紀錄、已展開、當機前未確認、剛收好都擋，各回自己的原因")
    check(cargoBad.code == "CARGO" and cargoBad.type == "Base.TinnedBeans" and cargoBad.why == "perishable",
        "背包裡一件 Economy 帶不走的貨物（罐頭腐壞）也擋，回物品與 Economy 的原因")
    check(tooMany.code == "TOO_MANY" and tooMany.n == 7, "貨物件數含背包內容、鑰匙圈上的鑰匙、槍上配件（7 件）")
    check(okCheck == true and ext and ext.capsuleId == id and ext.weight == 12.5, "能交易：ext 帶膠囊編號與含貨物的重量")
    local v = ext and ext.view or {}
    check(v.script == "Base.PickUpTruck" and v.engine == 63 and v.battery == 37 and v.body == 80 and v.missing == 1
        and v.cargo == 5, "上架車況：引擎 63、電瓶 37、車身 80、缺件 1、貨物 5 件（含拆下的瞄準鏡）")
    check(cap.inv:getItemWithIDRecursiv(scope.id) ~= nil and held.cargo[scope.id] == "SeatFrontLeft"
        and held.manifest["Base.x2Scope"] == 1, "槍上配件先拆進膠囊，跟著槍回原本的車上位置")
    local tree = held.escrow and held.escrow.cargo or {}
    local byId = {}
    for _, n in ipairs(tree) do byId[n.id] = n end
    check(held.escrow and held.escrow.active == true and #tree == 5 and byId[bag.id].c[1].id == can.id
        and byId[ring.id].k == "keys" and byId[ring.id].c[1].id == key.id and byId[water.id].s.contents == true,
        "交出時貨物（含背包內容、鑰匙圈的鑰匙）照原編號存進紀錄")
    check(held.seen.where == "economy" and held.seen.by == "seller" and held.history[#held.history].ev == "ESCROW",
        "最後看到改成經濟系統，歷史記 ESCROW")
    quiet = true
    local fresh = instanceItem(M.TYPES[1].loaded)
    local freshId = fresh.id
    Trade.rebuilt(ext, fresh, buyer, { kind = "market", ref = "L-1" })
    local dropped = instanceItem(M.TYPES[1].loaded) -- Economy builds again for the same delivery and keeps one item
    Trade.rebuilt(ext, dropped, buyer, { kind = "market", ref = "L-1" })
    local built = Store.read(id)
    Guard.check(buyer, fresh)
    local got = Store.read(id)
    local traded = 0
    for _, e in ipairs(got.history) do if e.ev == "TRADED" then traded = traded + 1 end end
    Guard.check(buyer, fresh)
    local offered = Trade.check(fresh, buyer)
    local again = instanceItem(M.TYPES[1].loaded)
    Trade.rebuilt(ext, again, buyer, { kind = "market", ref = "M-9" })
    local orphan = instanceItem(M.TYPES[1].loaded)
    local orphanId = orphan.id
    Trade.rebuilt({ capsuleId = 99999999 }, orphan, buyer, {})
    quiet = false
    local w2 = fresh.inv:getItemWithIDRecursiv(water.id)
    local b2 = fresh.inv:getItemWithIDRecursiv(bag.id)
    local r2 = fresh.inv:getItemWithIDRecursiv(ring.id)
    check(freshId ~= id and fresh.id == id and dropped.id == id, "Economy 做的新膠囊拿回原本的編號（每次重做都一樣）")
    check(#fresh.inv.list == 5 and w2 and w2.cond == 7 and b2 and b2.inv:getItemWithIDRecursiv(can.id)
        and r2 and #r2.keys == 1 and r2.keys[1].id == key.id and fresh.inv:getItemWithIDRecursiv(scope.id),
        "貨物照樹狀重建（背包內容、鑰匙圈的鑰匙），每件都是原編號、狀態照快照")
    check(built.escrow.active == true and built.escrow.last.to == "buyer" and built.history[#built.history].ev == "ESCROW",
        "Economy 做好新膠囊還不算交出（可能被丟掉重做）：仍是交易中、不記 TRADED")
    check(got.state == "PACKED" and got.escrow.active == nil and got.history[#got.history].ev == "TRADED"
        and got.history[#got.history].why == "market L-1" and got.history[#got.history].by == "buyer" and traded == 1,
        "膠囊出現在玩家身上（Guard 看到）才算交出：交易結束、記一筆 TRADED（通道與編號）")
    check(offered == true and #Store.read(id).history == #got.history, "交出後再看到或再拿來上架不再記 TRADED，可以再交易")
    check(again.id == id and #again.inv.list == 5, "當機回溯後 Economy 再交一次：一樣拿回原編號與整批貨物")
    check(orphan.id == orphanId and #orphan.inv.list == 0, "找不到紀錄的 ext 不動新物品")
    local claimed = Store.claim(id, buyer)
    check(claimed and claimed.escrow == nil and Store.read(id).escrow == nil, "展開時清掉紀錄裡的貨物副本")
    record({ escrow = { active = true, cargo = {} } })
    quiet = true
    Trade.aborted({ capsuleId = id }, seller, "L-2")
    quiet = false
    local ab = Store.read(id)
    check(ab.escrow == nil and ab.history[#ab.history].ev == "ESCROW_ABORTED", "Economy 中途放棄：清掉交易標記，歷史記一筆")
    local savedEv = Events.OnInitGlobalModData
    Events.OnInitGlobalModData = { Add = function(fn) initHook = fn end }
    require "MinidoracatPackThrow/Economy"
    Events.OnInitGlobalModData = savedEv
    local calls = {}
    eco.registerUniqueItemType = function(t, mod, h) calls[#calls + 1] = "unique:" .. t .. ":" .. mod; return h == Trade.handler end
    eco.blockItemType = function(t) calls[#calls + 1] = "block:" .. t; return true end
    quiet = true
    initHook()
    eco.registerUniqueItemType = function() calls[#calls + 1] = "refused"; return false, "taken" end
    initHook()
    eco.API_REVISION = 5
    initHook()
    quiet = false
    local want = {}
    for _, t in ipairs(M.TYPES) do want[#want + 1] = "unique:" .. t.loaded .. ":" .. M.MOD_ID end
    for _, t in ipairs(M.TYPES) do
        want[#want + 1] = "refused"
        want[#want + 1] = "block:" .. t.loaded
    end
    for _, t in ipairs(M.TYPES) do want[#want + 1] = "block:" .. t.loaded end
    check(table.concat(calls, ",") == table.concat(want, ",")
        and table.concat(calls, ","):find("unique:MinidoracatPackThrow.LoadedSphereLegend:" .. M.MOD_ID, 1, true) ~= nil,
        "rev 6 七種膠囊與四級帕魯球（LoadedSphere<等級>）各註冊一次；被拒或只有 rev 5 時每種退回 blockItemType（"
        .. #calls .. " 次呼叫）")
    MinidoracatEconomy = nil
end)() end

print("CargoWeight：關掉時新收的車，貨物原物件放進膠囊的貨物倉（膠囊只算本身重量）；展開、Guard、清空、Economy 交易都認得；開著照舊")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    require "MinidoracatPackThrow/Pack"
    local S, Pack, R = M.Snapshot, M.Pack, M.Rules
    local saved = { whyNot = Pack.whyNot, capture = S.capture, fx = M.Fx.broadcast, sv = SandboxVars }
    Pack.whyNot = function() return nil end
    M.Fx.broadcast = function() end
    -- a truck with a bed and a glove box; loaded: water and a school bag (pencil inside) in the bed, a lighter in the box
    local function truck(loaded)
        local v = { parts = {} }
        for _, id in ipairs({ "TruckBed", "GloveBox" }) do
            local p = { id = id, inv = newContainer(nil) }
            function p:getId() return self.id end
            function p:getItemContainer() return self.inv end
            v.parts[#v.parts + 1] = p
        end
        local sq = { getX = function() return 10 end, getY = function() return 20 end, getZ = function() return 0 end }
        function sq:AddWorldInventoryItem(it) v.dropped = it; return it end
        function v:getSquare() return sq end
        function v:getSqlId() return 9 end
        function v:getPartCount() return #self.parts end
        function v:getPartByIndex(i) return self.parts[i + 1] end
        function v:getPartById(id) for _, p in ipairs(self.parts) do if p.id == id then return p end end end
        function v:getCurrentKey() return nil end
        function v:permanentlyRemove() self.removed = true end
        if loaded then
            local c = { water = newItem("Base.WaterBottle"), bag = newItem("Base.Bag_Schoolbag", true),
                pencil = newItem("Base.Pencil"), lighter = newItem("Base.Lighter") }
            v.parts[1].inv:AddItem(c.water)
            v.parts[1].inv:AddItem(c.bag)
            c.bag.inv:AddItem(c.pencil)
            v.parts[2].inv:AddItem(c.lighter)
            v.cargo = c
        end
        return v
    end
    -- the cargo fields of Snapshot.capture (nothing else of the record is read here)
    S.capture = function(v)
        local snap = { script = "Base.PickUpTruck", parts = {}, cargo = {}, manifest = {}, sealed = {}, skipped = {} }
        for _, p in ipairs(v.parts) do
            for _, it in ipairs(p.inv.list) do
                snap.cargo[it.id] = p.id
                snap.manifest[it.type] = (snap.manifest[it.type] or 0) + 1
                snap.sealed[#snap.sealed + 1] = it.id
                for _, kid in ipairs(it.inv and it.inv.list or {}) do snap.sealed[#snap.sealed + 1] = kid.id end
            end
        end
        return snap
    end
    local packer = newPlayer("packer", false)
    local function pack(light)
        SandboxVars = light and { MinidoracatPackThrow = { CargoWeight = false } } or nil
        local v = truck(true)
        local res = Pack.pack(packer, v, {})
        return v.dropped, Store.read(res.capsuleId), v.cargo, res
    end
    quiet = true
    SandboxVars = nil
    local onByDefault = R.cargoWeighs()
    local heavy, heavySnap, _, heavyRes = pack(false)
    local light, lightSnap, c, lightRes = pack(true)
    local off = not R.cargoWeighs()
    local clean = #light.store.offers == 3
    for _, o in ipairs(light.store.offers) do clean = clean and o.force == true and o.sync == false and not o.inContainer end
    local fresh = truck(false)
    local packedLight = lightSnap.light == true and #light.inv.list == 0 and #light.store.list == 3
        and c.water.container == nil and c.pencil.container == c.bag.inv
    local back = S.restoreCargo(light, fresh, lightSnap)
    local bed, box = fresh.parts[1].inv.list, fresh.parts[2].inv.list
    quiet = false
    check(onByDefault and off, "Rules.cargoWeighs：預設算重量，沙盒 CargoWeight=false 才不算")
    check(heavyRes.ok and #heavy.inv.list == 3 and #heavy.store.list == 0 and heavySnap.light == nil,
        "開著（預設）：貨物照舊放進膠囊容器，紀錄沒有 light")
    check(lightRes.ok and packedLight,
        "關掉：三件貨物進貨物倉（背包連同鉛筆），膠囊容器是空的（引擎只算容器的重量），紀錄記 light")
    check(clean, "放進貨物倉前先從容器移除、不同步（force、sync=false：不會逐件送移除封包，混裝的清單也不走 saveSync）")
    check(back.home == 3 and back.other == 0 and back.ground == 0 and #light.store.list == 0
        and bed[#bed - 1] == c.water and bed[#bed] == c.bag and box[1] == c.lighter,
        "展開：貨物倉的貨物回到原本的車上位置（車斗：水瓶、背包；置物箱：打火機），貨物倉清空")

    -- Guard: the store counts as inside (no CARGO_LOCK; no CARGO_TAKEN with taking out allowed); clearing lists it
    quiet = true
    local g, gSnap = pack(true)
    local gid = g.id
    Store.settle(gid)
    packer.inv:AddItem(g)
    Guard.pass(packer)
    SandboxVars.MinidoracatPackThrow.AllowCargoTakeOut = true
    Guard.pass(packer)
    local evs = {}
    for _, e in ipairs(Store.read(gid).history) do evs[#evs + 1] = e.ev end
    local afterTake = Store.read(gid)
    local void = Store.read(gid)
    void.state = "VOID"
    Store.write(gid, void)
    Guard.pass(packer)
    local h = Store.read(gid).history
    quiet = false
    check(table.concat(evs, ","):find("CARGO", 1, true) == nil and #g.store.list == 3 and #afterTake.sealed == #gSnap.sealed,
        "Guard：貨物倉裡的貨物算在膠囊裡，不放回也不當成拿走（拿出模式開著也一樣，紀錄不變）：" .. table.concat(evs, ","))
    check(packer.inv:getItemWithIDRecursiv(gid) == nil and h[#h].ev == "CLEARED" and h[#h].items:find("Base.Pencil*1", 1, true)
        and h[#h].items:find("Base.Lighter*1", 1, true), "已作廢的輕量膠囊照樣清空，CLEARED 列出貨物倉裡的貨物：" .. tostring(h[#h].items))

    -- Economy: the cargo goes through the container for the codec and back into the store of the capsule handed over
    local eco = { API_MAJOR = 1, API_REVISION = 6, CAPABILITIES = { uniqueItemTypes = true },
        snapshotItem = function(it) return { type = it.type } end,
        rebuildItem = function(s) return instanceItem(s.type) end,
        detachParts = function() return 0 end }
    MinidoracatEconomy = { v1 = eco }
    require "MinidoracatPackThrow/Trade"
    local function listed()
        local cap = pack(true)
        Store.settle(cap.id)
        function cap:getContentsWeight() return #self.inv.list end -- the engine weighs the container only
        function cap:getScriptItem() return { getActualWeight = function() return 0.2 end } end
        return cap
    end
    quiet = true
    local t = listed()
    local ext = M.Trade.escrow(t, packer, "market", "L-7")
    local held = Store.read(t.id)
    local rebuilt = instanceItem(M.TYPES[1].loaded)
    M.Trade.rebuilt(ext, rebuilt, packer, { kind = "market", ref = "L-7" })
    local refused = listed()
    dropWrites = true -- the escrow record cannot be written: Economy keeps out, the cargo goes back into the store
    local noExt = M.Trade.escrow(refused, packer, "market", "L-8")
    dropWrites = false
    quiet = false
    check(ext and ext.weight == 0.2 and held.escrow and #held.escrow.cargo == 3 and held.escrow.cargo[2].c
        and held.escrow.cargo[2].c[1].s.type == "Base.Pencil", "Economy：輕量膠囊以本身重量上架；貨物（含背包裡的鉛筆）照樣存進紀錄")
    check(rebuilt.id == t.id and #rebuilt.inv.list == 0 and #rebuilt.store.list == 3,
        "Economy 交回的新膠囊：原編號，貨物放回貨物倉（還是只算本身重量）")
    check(noExt == nil and #refused.inv.list == 0 and #refused.store.list == 3, "交出時紀錄寫不進去：Economy 不收，貨物回到貨物倉")

    -- 16 languages: the option's label and tooltip
    local missing = {}
    for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
        local h2 = io.open(MEDIA .. "/shared/Translate/" .. lang .. "/Sandbox.json", "rb")
        local sb = h2 and M.Json.decode(h2:read("*a")) or {}
        if h2 then h2:close() end
        for _, k in ipairs({ "Sandbox_MinidoracatPackThrow_CargoWeight", "Sandbox_MinidoracatPackThrow_CargoWeight_tooltip" }) do
            if not sb[k] then missing[#missing + 1] = lang .. ":" .. k:gsub("Sandbox_MinidoracatPackThrow_", "") end
        end
    end
    check(#missing == 0, "16 種語言都有 CargoWeight 的標籤與說明（" .. table.concat(missing, ",", 1, math.min(#missing, 12)) .. "）")

    MinidoracatEconomy, SandboxVars = nil, saved.sv
    Pack.whyNot, S.capture, M.Fx.broadcast = saved.whyNot, saved.capture, saved.fx
end)() end

-- ===== 介面版面：管理面板訊息依欄寬換行、詳情按鈕列放不下就換列（真框架 Text.wrap／fit，實際譯文）=====
print("UI：訊息換行不超出欄寬、行數有上限；按鈕列換列不出欄")
local function uiLayout() -- 獨立函式：主程式的 local 已接近 200 個上限
    local MUI = os.getenv("MUI_LUA_DIR") or "../MinidoracatUIFor42/MOD/MinidoracatUIFor42/Contents/mods/MinidoracatUIFor42/42/media/lua/client/MinidoracatUI/"
    local mui = io.open(MUI .. "V1.lua", "rb")
    if not mui then
        print("  SKIP  找不到框架 " .. MUI .. "（把 MinidoracatUIFor42 clone 在本 repo 同層，或設 MUI_LUA_DIR）")
        return
    end
    mui:close()
    -- 量字：每個字 7px（UTF-8 一個字元算一個字，俄文、法文重音字母不會被當成 2 個）
    local function width(s) return 7 * select(2, s:gsub("[^\128-\191]", "")) end
    UIFont = { Small = "Small", Medium = "Medium" }
    function getTextManager()
        return { MeasureStringX = function(_, _, s) return width(s) end, getFontHeight = function() return 16 end }
    end
    dofile(MUI .. "V1.lua")
    dofile(MUI .. "TextWrap.lua")
    local caps = MinidoracatUI.v1.CAPABILITIES
    caps.window, caps.controls, caps.virtualList, caps.slider = true, true, true, true -- widget 檔要遊戲 UI 類別；這裡只驗文字與排版
    caps.scrollPanel, caps.opaqueWindow = true, true
    require "MinidoracatPackThrow/UIKit"
    local Kit = M.UIKit
    check(Kit.ok and caps.textWrap == true, "UIKit 接上框架（含 Text.wrap）")
    local function ui(lang)
        local fh = assert(io.open(MEDIA .. "/shared/Translate/" .. lang .. "/UI.json", "rb"))
        local t = Json.decode(fh:read("*a"))
        fh:close()
        return t
    end
    local P = "UI_MinidoracatPackThrow_"
    local DW = 548 -- 980 寬面板的詳情欄
    local msgs = 0
    for _, lang in ipairs({ "EN", "FR", "RU" }) do
        local t = ui(lang)
        for k, s in pairs(t) do
            if k:find("^" .. P .. "Why_") or k == P .. "Restored" or k == P .. "WentTo" or k == P .. "WentToSeen" then
                msgs = msgs + 1
                for _, w in ipairs({ DW, 160 }) do
                    local lines = Kit.lines(s, w, 3)
                    local ok = #lines >= 1 and #lines <= 3
                    for _, line in ipairs(lines) do ok = ok and width(line) <= w end
                    local all = #Kit.wrap(s, w) <= 3
                    ok = ok and (all or lines[3]:sub(-3) == "...")
                    if not ok then check(false, lang .. " " .. k .. " 寬 " .. w .. " 超出或沒標省略") end
                end
                local whole = table.concat(Kit.lines(s, DW, 3), " ")
                if width(s) <= DW * 2 and whole:gsub("%s", "") ~= s:gsub("%s", "") then
                    check(false, lang .. " " .. k .. " 兩行內放得下卻少了字")
                end
            end
        end
    end
    check(msgs >= 30, "三語的拒絕原因與結果訊息都量過（" .. msgs .. " 則）")
    local items = { { width = 120 }, { width = 200 }, { width = 260 }, { width = 180 }, { width = 600 } }
    local rows = Kit.flow(items, DW, 8)
    local inside = true
    for i, it in ipairs(items) do
        if i < #items then inside = inside and it.flowX + it.width <= DW end
    end
    check(inside and rows == 3 and items[3].flowRow == 1 and items[3].flowX == 0 and items[4].flowX == 268
        and items[5].flowRow == 2 and items[5].flowX == 0, "按鈕列放不下就換到下一列、比欄還寬的自成一列（rows=" .. rows .. "）")
    local ru = ui("RU")
    local btns = {}
    for _, key in ipairs({ "GoTo", "GoSeen", "Restore", "VerdictPresent", "VerdictMissing" }) do
        btns[#btns + 1] = { width = width(ru[P .. key]) + 20 }
    end
    Kit.flow(btns, DW, 8)
    inside = true
    for _, b in ipairs(btns) do inside = inside and b.flowX + b.width <= DW end
    check(inside, "RU 五顆詳情按鈕都在詳情欄內")
end
uiLayout()

print("Types：七種膠囊與四級帕魯球的物品、模型、圖示、音效（膠囊全部不同，帕魯球用科幻款）、煙霧幀、沙盒與 12 種語言都對得上")
local function capsuleTypes() -- 獨立函式：主程式的 local 已接近 200 個上限
    local base = MEDIA .. "/.."
    local function read(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    local function exists(path) return read(path) ~= nil end
    local items = read(base .. "/scripts/MinidoracatPackThrow_items.txt")
    local models = read(base .. "/scripts/MinidoracatPackThrow_models.txt")
    local sandboxTxt = read(base .. "/sandbox-options.txt")
    local sounds, used, bad = {}, {}, {}
    for name, file in read(base .. "/scripts/MinidoracatPackThrow_sounds.txt"):gmatch("sound%s+([%w_]+)%s*{[^}]-file%s*=%s*([^,%s]+)") do
        sounds[name] = file
    end
    for _, t in ipairs(M.TYPES) do
        local id, item, loaded, model = t.id, "Capsule" .. t.id, "LoadedCapsule" .. t.id, "PackThrow" .. t.id
        if t.sphere then item, loaded, model = id, "Loaded" .. id, t.icon end
        if not items:find("item " .. item .. "%s*{[^}]-Icon = " .. t.icon .. ",") then bad[#bad + 1] = id .. ".empty item" end
        if not items:find("item " .. loaded .. "%s*{[^}]-Icon = " .. t.icon .. "Loaded,") then bad[#bad + 1] = id .. ".loaded item" end
        if t.sphere and not items:find("item " .. loaded .. "%s*{[^}]-ItemType = base:container,") then
            bad[#bad + 1] = id .. ".loaded container"
        end
        for _, suffix in ipairs({ "", "Loaded", "Hand", "LoadedHand" }) do
            if not models:find("model " .. model .. suffix .. "%s*{") then bad[#bad + 1] = id .. ".model" .. suffix end
        end
        local world = t.sphere and ("WorldItems/" .. t.icon) or ("WorldItems/MinidoracatCapsule" .. id)
        for _, png in ipairs({ "textures/Item_" .. t.icon .. ".png", "textures/Item_" .. t.icon .. "Loaded.png",
            "textures/" .. world .. ".png", "textures/" .. world .. "Loaded.png" }) do
            if not exists(base .. "/" .. png) then bad[#bad + 1] = png end
        end
        for _, k in ipairs({ "throw", "pop", "pack", "button", "smoke" }) do
            if t.sphere then
                if t[k] ~= M.TYPE_BY_ID.SciFi[k] then bad[#bad + 1] = id .. "." .. k .. " not SciFi" end
            elseif k ~= "smoke" then
                local file = sounds[t[k]]
                if not (file and exists(base .. "/../" .. file)) then bad[#bad + 1] = id .. "." .. k .. "=" .. tostring(t[k]) end
                if used[t[k]] then bad[#bad + 1] = id .. "." .. k .. " shares " .. used[t[k]] end
                used[t[k]] = id .. "." .. k
            end
        end
        for i = 1, t.frames + 1 do
            local has = exists(base .. "/textures/MinidoracatPackThrow/" .. t.smoke .. i .. ".png")
            if has ~= (i <= t.frames) then bad[#bad + 1] = id .. " frame " .. i end
        end
        for _, opt in ipairs({ "Type" .. id, "Type" .. id .. "Loot" }) do
            if not sandboxTxt:find("option MinidoracatPackThrow%." .. opt .. "%s*{[^}]-page = MinidoracatPackThrowTypes") then
                bad[#bad + 1] = "sandbox " .. opt
            end
        end
    end
    if not exists(base .. "/models_X/WorldItems/MinidoracatSphere.fbx") then bad[#bad + 1] = "MinidoracatSphere.fbx" end
    local tiers = {}
    for _, t in ipairs(M.TYPES) do if t.sphere then tiers[#tiers + 1] = t.tier .. "+" .. t.bonus .. "/" .. t.rarity end end
    check(#bad == 0, "每種都有兩個物品、四個模型、四張圖；膠囊四段音效（28 段互不共用、檔案都在），帕魯球用科幻款的煙霧與音效；"
        .. "裝了動物的帕魯球是容器；煙霧幀、兩個沙盒選項（" .. table.concat(bad, ",") .. "）")
    check(table.concat(tiers, ",") == "Basic+0/8,Mega+15/4,Giga+30/2,Legend+50/1"
        and M.TYPE_BY_ID.SphereMega.empty == "MinidoracatPackThrow.SphereMega"
        and M.TYPE_BY_ID.SphereMega.loaded == "MinidoracatPackThrow.LoadedSphereMega" and M.TYPES[5].id == "SciFi",
        "帕魯球四級（等級加成／稀有度）寫死在 M.TYPES 尾端，物品 ID Sphere<等級>／LoadedSphere<等級>，膠囊的特效索引不變")
    check(not sandboxTxt:find("EffectStyle", 1, true), "沙盒不再有 EffectStyle")
    local missing = {}
    for _, lang in ipairs({ "CH", "CN", "DE", "EN", "ES", "FR", "JP", "KO", "PL", "PTBR", "RU", "TR" }) do
        local dir = MEDIA .. "/shared/Translate/" .. lang .. "/"
        local itemNames = M.Json.decode(read(dir .. "ItemName.json"))
        local sb = M.Json.decode(read(dir .. "Sandbox.json"))
        local tip = M.Json.decode(read(dir .. "Tooltip.json"))
        for _, t in ipairs(M.TYPES) do
            for _, k in ipairs({ t.empty, t.loaded }) do if not itemNames[k] then missing[#missing + 1] = lang .. ":" .. k end end
            for _, k in ipairs({ "Type" .. t.id, "Type" .. t.id .. "_tooltip", "Type" .. t.id .. "Loot", "Type" .. t.id .. "Loot_tooltip" }) do
                if not sb["Sandbox_MinidoracatPackThrow_" .. k] then missing[#missing + 1] = lang .. ":" .. k end
            end
            if not tip["Tooltip_MinidoracatPackThrow_Look_" .. t.id] then missing[#missing + 1] = lang .. ":Look_" .. t.id end
        end
        for k in pairs(sb) do if k:find("EffectStyle", 1, true) then missing[#missing + 1] = lang .. ":" .. k .. "(old)" end end
    end
    check(#missing == 0, "12 種語言都有七種的物品名、沙盒選項與效果說明，沒有舊的 EffectStyle（"
        .. table.concat(missing, ",", 1, math.min(#missing, 12)) .. "）")
end
capsuleTypes()

print("Animals：快照可存、寫回順序、規則、收進膠囊、展開、紀錄分 kind、管理員、Economy、16 種語言")
-- Wild catch chance (WildCaptureChance, WILD_OFF, ESCAPED, the tooltip rows), run inside animals(): live is its fake
-- animal, packer a player next to it (101.5, 201.5).
local function wildCases(live, packer)
    print("Wild：抓野生動物的成功率（WildCaptureChance、WILD_OFF、ESCAPED、提示框列）")
    local Pack, Ball = M.Pack, M.FIRST_SPHERE
    local savedRand, savedRoll = ZombRand, Rules.rollWild
    local function chance(v)
        SandboxVars = { MinidoracatPackThrow = { WildCaptureChance = v } }
        return Rules.wildChance()
    end
    check(chance(nil) == 50 and chance(0) == 0 and chance(100) == 100 and chance(150) == 100 and chance(-5) == 0
        and chance(33.7) == 33, "WildCaptureChance：預設 50，夾在 0–100、取整數")
    local function roll(c, v)
        ZombRand = function(n) return n == 100 and v or -1 end
        return Rules.rollWild(c)
    end
    check(roll(50, 49) and not roll(50, 50) and not roll(0, 0) and roll(100, 99) and roll(1, 0) and not roll(1, 1),
        "rollWild：ZombRand(100) 小於成功率才成功（0 一定失敗、100 一定成功）")
    ZombRand = savedRand

    local ground = {}
    local spot = { getX = function() return 101 end, getY = function() return 201 end, getZ = function() return 0 end,
        AddWorldInventoryItem = function(_, it) ground[#ground + 1] = it end }
    local function empty() return packer.inv:AddItem(instanceItem(Ball.empty)) end
    local rolls = {}
    local function forced(ok) Rules.rollWild = function(c) rolls[#rolls + 1] = c; return ok end end
    -- 0%: WILD_OFF on every path (menu, server, capture), nothing rolled; tame animals still go
    chance(0)
    forced(true)
    local hare, cap = live({ wild = true, square = spot }), empty()
    local off = Pack.packAnimal(packer, hare, { capsule = cap, typeId = "SphereBasic" })
    check(Rules.animalWhyNot(packer, hare) == "WILD_OFF" and Rules.packAnimalWhyNot(packer, hare, Ball) == "WILD_OFF"
        and Rules.captureWhyNot(packer, hare, true, Ball) == "WILD_OFF" and Rules.animalWhyNot(packer, live()) == nil
        and off.ok == false and off.why == "WILD_OFF" and #rolls == 0 and #hare.log == 0,
        "成功率 0：野生動物 WILD_OFF（選單、伺服器、抓取都擋，不擲骰）；家養的照收")
    -- a forced miss at 50%: ESCAPED with the chance; the animal, the capsule and the records untouched
    chance(50)
    forced(false)
    local before = { ground = #ground, empties = packer.inv:getCountTypeRecurse(Ball.empty) }
    quiet = true
    local miss = Pack.packAnimal(packer, hare, { capsule = cap, typeId = "SphereBasic" })
    quiet = false
    check(miss.ok == false and miss.why == "ESCAPED" and miss.chance == 50 and rolls[1] == 50 and #hare.log == 0
        and #ground == before.ground and packer.inv:getCountTypeRecurse(Ball.empty) == before.empties
        and packer.inv:getItemWithIDRecursiv(cap.id) == cap,
        "強制失敗：ESCAPED 帶成功率 50；動物沒被 setWild／remove，沒有紀錄、地上沒有膠囊，空膠囊沒用掉")
    -- a forced catch: packed as before and tamed
    forced(true)
    quiet = true
    local hit = Pack.packAnimal(packer, hare, { capsule = cap, typeId = "SphereBasic" })
    quiet = false
    check(hit.ok and rolls[2] == 50 and hare.log[1] == "setWild:false" and hare.log[#hare.log] == "remove"
        and Store.read(hit.capsuleId).animal.wild == false and packer.inv:getItemWithIDRecursiv(cap.id) == nil,
        "強制成功：照舊收好、setWild(false)、紀錄 wild=false、空膠囊用掉")
    -- WildCaptureFailConsumes on: the forced miss takes the capsule this pack used (consumed = true); a refusal that
    -- is not the roll (WILD_OFF here) keeps it; off (above) nothing is used up
    SandboxVars.MinidoracatPackThrow.WildCaptureFailConsumes = true
    Rules.rollWild = function() return false end
    local hare2, cap2, cap3 = live({ wild = true, square = spot }), empty(), empty()
    local before2 = #ground
    quiet = true
    local gone = Pack.packAnimal(packer, hare2, { capsule = cap2, typeId = "SphereBasic" })
    SandboxVars.MinidoracatPackThrow.WildCaptureChance = 0
    local offKept = Pack.packAnimal(packer, live({ wild = true, square = spot }), { capsule = cap3, typeId = "SphereBasic" })
    quiet = false
    check(gone.ok == false and gone.why == "ESCAPED" and gone.consumed == true and gone.chance == 50
        and packer.inv:getItemWithIDRecursiv(cap2.id) == nil and #hare2.log == 0 and #ground == before2
        and miss.consumed == nil and offKept.why == "WILD_OFF" and offKept.consumed == nil
        and packer.inv:getItemWithIDRecursiv(cap3.id) == cap3,
        "沒抓到時膠囊消失（開）：強制失敗 consumed=true、用的空膠囊從背包移除、動物不動；關著時與非擲骰的拒絕（WILD_OFF）膠囊照舊")
    packer.inv:Remove(cap3)
    -- 100% with the real roll catches on the highest die; a tame animal never rolls (a forced miss changes nothing)
    Rules.rollWild = savedRoll
    chance(100)
    ZombRand = function() return 99 end
    quiet = true
    local sure = Pack.packAnimal(packer, live({ wild = true, square = spot }), { capsule = empty(), typeId = "SphereBasic" })
    chance(50)
    forced(false)
    local tame = Pack.packAnimal(packer, live({ square = spot }), { capsule = empty(), typeId = "SphereBasic" })
    quiet = false
    check(sure.ok and tame.ok and #rolls == 2, "成功率 100：最大的骰子也成功；家養動物不擲骰（強制失敗也照收）")
    ZombRand, Rules.rollWild = savedRand, savedRoll
    SandboxVars = { MinidoracatPackThrow = {} }

    -- the option, its settings row, the tooltip rows and the strings
    local function src(path)
        local f = io.open(MEDIA .. "/" .. path, "rb")
        local s = f:read("*a")
        f:close()
        return s
    end
    local sb, panel = src("../sandbox-options.txt"), src("client/MinidoracatPackThrow/AdminPanel.lua")
    local allow, wild, keep = sb:find("option MinidoracatPackThrow.AllowAnimals", 1, true),
        sb:find("option MinidoracatPackThrow%.WildCaptureChance%s*{type = integer, min = 0, max = 100, default = 50, page = MinidoracatPackThrow,"),
        sb:find("option MinidoracatPackThrow.RecordRetentionDays", 1, true)
    local pAllow, pWild, pKeep = panel:find('key = "AllowAnimals"', 1, true),
        panel:find('{ key = "WildCaptureChance", kind = "int", min = 0, max = 100, default = 50, pct = true }', 1, true),
        panel:find('key = "RecordRetentionDays"', 1, true)
    local sGone, pGone = sb:find("option MinidoracatPackThrow%.WildCaptureFailConsumes%s*{type = boolean, default = false, page = MinidoracatPackThrow,"),
        panel:find('{ key = "WildCaptureFailConsumes", kind = "bool", default = false }', 1, true)
    check(allow and wild and keep and allow < wild and wild < keep and pAllow and pWild and pKeep and pAllow < pWild
        and pWild < pKeep, "沙盒 WildCaptureChance 整數 0–100、預設 50、主頁緊接 AllowAnimals；設定分頁同一位置、顯示成百分比")
    check(sGone and wild < sGone and sGone < keep and pGone and pWild < pGone and pGone < pKeep,
        "沙盒 WildCaptureFailConsumes 布林、預設關、緊接成功率；設定分頁同一位置（開關）")
    local sPrev, pPrev, order = sGone, pGone, true
    for _, b in ipairs({ { "WildCaptureInjuredBonus", 30 }, { "WildCaptureYoungBonus", 15 }, { "WildCaptureUnawareBonus", 20 } }) do
        local s = sb:find("option MinidoracatPackThrow%." .. b[1] .. "%s*{type = integer, min = 0, max = 100, default = " .. b[2]
            .. ", page = MinidoracatPackThrow,")
        local p = panel:find('{ key = "' .. b[1] .. '", kind = "int", min = 0, max = 100, default = ' .. b[2] .. ', pct = true }', 1, true)
        order = order and s ~= nil and p ~= nil and s > sPrev and p > pPrev
        sPrev, pPrev = s or math.huge, p or math.huge
    end
    check(order and sPrev < keep and pPrev < pKeep,
        "三個加成（受傷 30、幼崽 15、沒發現你 20）整數 0–100、主頁緊接 WildCaptureFailConsumes；設定分頁同順序、顯示成百分比")
    check(src("client/MinidoracatPackThrow/Menu.lua"):find("Notify.chanceRows(player, animal, t)", 1, true)
        and src("client/MinidoracatPackThrow/ThrowCursor.lua"):find("Notify.chanceRows(self.character, tgt.thing, M.typeOf(self.item))", 1, true),
        "動物選單與抓取游標的提示框都加成功率與加成列（Notify.chanceRows，用該等級的帕魯球）")
    local missing = {}
    for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
        local ui = Json.decode(src("shared/Translate/" .. lang .. "/IG_UI.json"))
        local box = Json.decode(src("shared/Translate/" .. lang .. "/Sandbox.json"))
        for _, k in ipairs({ "Why_ESCAPED", "WildChance", "WildChanceGone", "EscapedGone" }) do
            local s = ui["IGUI_MinidoracatPackThrow_" .. k] or ""
            if not (s:find("%1", 1, true) and s:find("%%", 1, true)) then missing[#missing + 1] = lang .. ":" .. k end
        end
        if (ui.IGUI_MinidoracatPackThrow_Why_WILD_OFF or "") == "" then missing[#missing + 1] = lang .. ":Why_WILD_OFF" end
        for _, k in ipairs({ "WildCaptureChance", "WildCaptureChance_tooltip", "WildCaptureFailConsumes",
            "WildCaptureFailConsumes_tooltip", "WildCaptureInjuredBonus", "WildCaptureInjuredBonus_tooltip",
            "WildCaptureYoungBonus", "WildCaptureYoungBonus_tooltip", "WildCaptureUnawareBonus",
            "WildCaptureUnawareBonus_tooltip" }) do
            local s = box["Sandbox_MinidoracatPackThrow_" .. k] or ""
            if s == "" or s:find("%", 1, true) then missing[#missing + 1] = lang .. ":" .. k end
        end
    end
    check(#missing == 0, "16 種語言：成功率列與掙脫原因帶 %1 與字面 %%，WILD_OFF，沙盒標籤與說明不用 % 符號（"
        .. table.concat(missing, ",", 1, math.min(#missing, 12)) .. "）")
end

local function animals() -- 獨立函式：主程式的 local 已接近 200 個上限
    require "MinidoracatPackThrow/Pack"
    do -- an earlier case replaced Unpack.spawn for good: put the real one back (modules hold the M.Unpack table)
        local Unpack0 = M.Unpack
        loadfile(MEDIA .. "/server/MinidoracatPackThrow/Unpack.lua")()
        Unpack0.spawn, M.Unpack = M.Unpack.spawn, Unpack0
    end
    local A, Pack, Unpack, Query, Index, AdminCommands, Trade = M.Animal, M.Pack, M.Unpack, M.Query, M.Index,
        M.AdminCommands, M.Trade
    local Ball = M.FIRST_SPHERE
    CharacterStat = { HUNGER = "HUNGER", THIRST = "THIRST" }
    fakeSquare(30, 40) -- an earlier case left a bare table there; findLoadedAnimal scans around (10, 10)
    local function allele(v, r, gd)
        return { getCurrentValue = function() return v end, getTrueRatioValue = function() return r end,
            isDominant = function() return true end, isUsed = function() return false end,
            getGeneticDisorder = function() return gd end }
    end
    -- A live animal as Animal.capture, Rules.animalWhyNot and Pack.packAnimal read it.
    local function live(o)
        o = o or {}
        local d = {
            getAge = function() return 40 end, getSize = function() return 0.9 end, getWeight = function() return 512.5 end,
            canHaveMilk = function() return true end, getMilkQuantity = function() return 3.2 end,
            getMaxMilkActual = function() return 5.5 end, getWoolQuantity = function() return 0 end,
            isPregnant = function() return true end, getPregnancyTime = function() return 37 end,
            isFertilized = function() return false end, getFertilizedTime = function() return 0 end,
            getAttachedPlayer = function() return o.rope end, getAttachedTree = function() return nil end,
        }
        local a = { log = {}, wild = o.wild == true,
            md = { tag = "cow", num = 42.5, flag = true, fn = function() end, [3] = "numeric key" } }
        function a:getData() return d end
        function a:getGeneticDisorder() return javaList({ "dwarf" }) end
        function a:getModData() return self.md end
        function a:getAnimalVisual() return { getSkinTexture = function() return "CowHolstein01" end } end
        function a:getAnimalType() return "cow" end
        function a:getBreed() return { getName = function() return "holstein" end } end
        function a:isFemale() return true end
        function a:getHoursSurvived() return 960.5 end
        function a:getHealth() return o.health or 1 end
        function a:isBaby() return o.baby == true end
        function a:isAlerted() return o.alerted ~= false end -- alerted unless a case says otherwise (no Unaware bonus)
        function a:getForwardDirectionX() return o.fx or 0 end
        function a:getForwardDirectionY() return o.fy or -1 end
        function a:getStats() return { get = function(_, k) return k == "HUNGER" and 0.31 or 0.27 end } end
        function a:getStress() return 23.5 end
        function a:getCustomName() return o.name end
        function a:getAnimalID() return 4321 end
        function a:isWild() return self.wild end
        function a:setWild(b)
            self.log[#self.log + 1] = "setWild:" .. tostring(b)
            if not b then self.wild = false end
        end
        function a:getAcceptanceLevel() return 66.6 end
        function a:getFullGenomeList()
            return javaList({ { getName = function() return "strength" end,
                getAllele1 = function() return allele(0.613, 0.5) end,
                getAllele2 = function() return allele(0.4, 0.377, "blind") end } })
        end
        function a:isDead() return o.dead == true end
        function a:isOnHook() return o.hook == true end
        function a:isExistInTheWorld() return o.away ~= true end
        function a:getX() return o.x or 101.5 end
        function a:getY() return 201.5 end
        function a:getSquare() return o.square end
        function a:getOnlineID() return 31 end
        function a:remove()
            self.log[#self.log + 1] = "remove"
            self.removedWith = o.onRemove and o.onRemove()
        end
        return a
    end
    local packer, admin = newPlayer("packer", false), newPlayer("admin", true)

    -- capture -> JSON -> back
    local snap = A.capture(live({ name = "Bessie" }), packer)
    local text = Json.encode(snap)
    local back = text and Json.decode(text)
    check(text ~= nil and back ~= nil and diff(snap, back) == nil and back.modData.fn == nil and back.modData[3] == nil
        and back.modData.num == 42.5 and back.genome.strength.a2.gd == "blind" and back.disorders[1] == "dwarf"
        and back.accept == 66.6 and back.milkMax == 5.5 and back.name == "Bessie",
        "動物快照（基因、遺傳病、只留字串 key 基本值的 modData）存成 JSON 原樣讀回（" .. tostring(text and #text) .. " bytes）")

    -- restore order: every call on the rebuilt animal, in order
    local order, water, spawned = {}, false, nil
    local function rec(name, own)
        return setmetatable(own or {}, { __index = function(_, k)
            return function(_, v) order[#order + 1] = name .. "." .. k .. "(" .. tostring(v) .. ")" end
        end })
    end
    -- the disorder list IsoAnimal.new leaves behind: its init rolled a random genome and listed that genome's disorders
    local initDisorders = { "fromInit" }
    local function arrayList(items)
        local l = { items = items }
        function l:clear() self.items = {} end
        function l:add(v) self.items[#self.items + 1] = v end
        function l:contains(v) for _, x in ipairs(self.items) do if x == v then return true end end return false end
        function l:size() return #self.items end
        function l:get(i) return self.items[i + 1] end
        return l
    end
    local function storing(name)
        return rec(name, { setGeneticDisorder = function(self, v)
            order[#order + 1] = name .. ".setGeneticDisorder(" .. tostring(v) .. ")"
            self.gd = v
        end })
    end
    IsoAnimal = { new = function(_, x, y, z, t, b)
        local a1, a2, data = storing("a1"), storing("a2"), rec("d")
        local gn = { getName = function() return "strength" end, getAllele1 = function() return a1 end,
            getAllele2 = function() return a2 end }
        local copy = {}
        for i, v in ipairs(initDisorders) do copy[i] = v end
        local dl = arrayList(copy)
        spawned = rec("an", { at = { x, y, z, t, b }, md = {}, dl = dl,
            getAnimalType = function() return not water and t or nil end,
            getFullGenomeList = function() return javaList({ gn }) end,
            getGeneticDisorder = function() return dl end,
            getData = function() return data end, getStats = function() return rec("st") end,
            getAnimalVisual = function() return rec("vis") end, getModData = function(self) return self.md end,
            setAnimalID = function(self, id) order[#order + 1] = "an.setAnimalID(" .. id .. ")"; self.id = id end,
            getAnimalID = function(self) return self.id end, getSquare = function() return sq(10, 10) end,
            getOnlineID = function() return 77 end, isDead = function() return false end })
        return spawned
    end }
    -- as vanilla (AnimalGene.java:250-259): adds a disorder both alleles of a gene carry, never removes one
    AnimalGene = { checkGeneticDisorder = function(a)
        order[#order + 1] = "AnimalGene.check"
        local list = a:getFullGenomeList()
        for i = 0, list:size() - 1 do
            local g = list:get(i)
            local gd = g:getAllele1().gd
            if gd and gd ~= "" and gd == g:getAllele2().gd and not a:getGeneticDisorder():contains(gd) then
                a:getGeneticDisorder():add(gd)
            end
        end
    end }
    local function at(s, from)
        for i = from or 1, #order do if order[i] == s then return i end end
        return math.huge
    end
    local made = A.restore(back, sq(10, 10), packer)
    local o = {
        gene = at("a1.setCurrentValue(0.613)"), check = at("AnimalGene.check"), age = at("an.setAgeDebug(40)"),
        hours = at("an.setHoursSurvived(960.5)"), size = at("d.setSize(0.9)"), weight = at("d.setWeight(512.5)"),
        wild = at("an.setWild(false)"), stress = at("an.setDebugStress(23.5)"), milkOff = at("d.setCanHaveMilk(false)"),
    }
    o.max1 = at("d.setMaxMilkActual(5.5)", o.milkOff)
    o.milk = at("d.setMilkQuantity(3.2)", o.max1)
    o.max2 = at("d.setMaxMilkActual(5.5)", o.milk)
    o.milkOn = at("d.setCanHaveMilk(true)", o.max2)
    check(made == spawned and spawned.at[4] == "cow" and spawned.at[5] == "holstein" and spawned.md.num == 42.5
        and o.gene < o.check and o.check < o.age and o.age < o.hours and o.hours < o.size and o.size < o.weight
        and o.wild < o.stress and o.milkOff < o.max1 and o.max1 < o.milk and o.milk < o.max2 and o.max2 < o.milkOn
        and o.milkOn < math.huge and order[#order] == "an.addToWorld(nil)",
        "寫回順序：基因→checkGeneticDisorder→年齡→存活時數→體型→體重；野生在壓力前；奶上限→奶量→奶上限→可擠奶；最後 addToWorld")
    water, order = true, {}
    local none, why = A.restore(back, sq(10, 10), packer)
    water = false
    check(none == nil and why == "BLOCKED" and at("an.addToWorld(nil)") == math.huge, "水上 IsoAnimal.new 沒初始化（沒有種類）：BLOCKED、不放進世界")
    -- genetic disorders: the released animal has exactly the stored ones, not the throwaway init genome's
    local function disordersAfter(mut)
        local s = Json.decode(text)
        mut(s)
        order = {}
        A.restore(s, sq(10, 10), packer)
        return table.concat(spawned.dl.items, ",")
    end
    local plain = disordersAfter(function() end)
    local paired = disordersAfter(function(s) s.genome.strength.a1.gd = "blind"; s.disorders = { "blind" } end)
    local oldRecord = disordersAfter(function(s) s.genome.strength.a1.gd = "blind"; s.disorders = nil end)
    initDisorders = {}
    local cleanInit = disordersAfter(function() end)
    initDisorders = { "fromInit" }
    check(plain == "dwarf" and paired == "blind" and oldRecord == "blind" and cleanInit == "dwarf",
        "遺傳病：IsoAnimal.new 隨機基因留下的病（fromInit）放出後不在，只有紀錄裡的（" .. plain .. "）；兩個等位基因同一種病的照樣在（"
            .. paired .. "）；沒有清單的舊紀錄由基因算回（" .. oldRecord .. "）")

    -- rules
    SandboxVars = { MinidoracatPackThrow = {} }
    local function why1(o2) return tostring(Rules.animalWhyNot(packer, o2 and live(o2) or nil)) end
    check(why1(nil) == "NO_ANIMAL" and why1({ dead = true }) == "NO_ANIMAL" and why1({ hook = true }) == "NO_ANIMAL"
        and why1({ away = true }) == "ANIMAL_AWAY" and why1({ rope = {} }) == "ROPE" and why1({ x = 150 }) == "TOO_FAR"
        and why1({ wild = true }) == "nil",
        "animalWhyNot：死的或掛鉤上 NO_ANIMAL、被抱著／雞舍／拖車 ANIMAL_AWAY、繩子 ROPE、太遠 TOO_FAR；野生的照樣能收")
    SandboxVars.MinidoracatPackThrow.AllowAnimals = false
    local off = why1({})
    SandboxVars.MinidoracatPackThrow = { TypeSphereBasic = false }
    local noCap = Rules.packAnimalWhyNot(packer, live(), Ball)
    packer.inv:AddItem(instanceItem(Ball.empty))
    local typeOff = Rules.packAnimalWhyNot(packer, live(), Ball)
    SandboxVars.MinidoracatPackThrow = {}
    check(off == "ANIMALS_OFF" and noCap == "NO_CAPSULE" and typeOff == "TYPE_OFF" and Rules.packAnimalWhyNot(packer, live(), Ball) == nil,
        "沙盒 AllowAnimals 關掉 ANIMALS_OFF；沒有空膠囊 NO_CAPSULE；款式停用 TYPE_OFF；都過才放行")

    -- pack: record first, capsule on the square, the animal goes last
    local ground = {}
    local spot = { getX = function() return 101 end, getY = function() return 201 end, getZ = function() return 0 end,
        AddWorldInventoryItem = function(_, it) ground[#ground + 1] = it end }
    local empty = Rules.emptyCapsule(packer, Ball)
    local cow = live({ name = "Bessie", wild = true, square = spot,
        onRemove = function() return ground[1] and Store.read(ground[1]:getID()) end })
    quiet = true
    local dead = Pack.packAnimal(packer, live({ dead = true, square = spot }), { capsule = empty, typeId = "SphereBasic" })
    dropWrites = true
    local lost = live({ square = spot })
    local failed = Pack.packAnimal(packer, lost, { capsule = empty, typeId = "SphereBasic" })
    dropWrites = false
    local afterFail = { ground = #ground, empties = packer.inv:getCountTypeRecurse(Ball.empty) }
    local savedFxB, packFx = M.Fx.broadcast, nil
    M.Fx.broadcast = function(kind, args) if kind == "pack" then packFx = args end end
    local res = Pack.packAnimal(packer, cow, { capsule = empty, typeId = "SphereBasic" })
    M.Fx.broadcast = savedFxB
    quiet = false
    check(dead.ok == false and dead.why == "NO_ANIMAL" and failed.ok == false and failed.why == "WRITE_FAILED"
        and #lost.log == 1 and afterFail.ground == 0 and afterFail.empties == 1,
        "收不了的動物不動；紀錄寫不進去：動物留在世界、空膠囊不用掉、地上沒有膠囊")
    local stored = res.ok and Store.read(res.capsuleId) or {}
    check(res.ok and res.kind == "animal" and res.type == "SphereBasic" and res.animal.name == "Bessie" and res.animal.type == "cow"
        and res.x == 101 and res.y == 201, "packAnimal 回傳和收車同一個形狀，另帶 kind 與動物名稱")
    check(stored.kind == "animal" and stored.state == "PACKED" and stored.animal.animalId == 4321 and stored.animal.wild == false
        and stored.history[1].ev == "PACKED" and stored.history[1].animal == 4321 and stored.history[1].car == nil
        and stored.script == nil, "紀錄 kind=animal、animal＝快照、PACKED 事件記動物編號不記 car")
    check(cow.log[1] == "setWild:false" and cow.log[#cow.log] == "remove" and cow.removedWith ~= nil
        and cow.removedWith.kind == "animal", "快照前 setWild(false)（照原版抱起）；紀錄與地上的膠囊都在之後才 remove 動物")
    check(#ground == 1 and ground[1]:getFullType() == Ball.loaded and packer.inv:getCountTypeRecurse(Ball.empty) == 0,
        "裝好的帕魯球放在動物那一格，玩家的空帕魯球用掉")
    check(packFx and packFx.capsuleId == empty.id and packFx.x == 101,
        "收的煙霧帶用掉那顆的編號（丟出抓取時就是飛出去那顆，客戶端用它收掉飛行，不靠同一格）")
    wildCases(live, packer)

    -- unpack by the existing claim / spawn / event path
    local capsule = packer.inv:AddItem(ground[1])
    order = {}
    quiet = true
    local u = Unpack.unpack(packer, capsule, sq(10, 10), "N", {})
    quiet = false
    local after = Store.read(res.capsuleId)
    local ev = after.history[#after.history]
    check(u.ok and u.kind == "animal" and u.animalId == 4321 and u.onlineId == 77 and u.animal.name == "Bessie" and u.returned
        and u.script == nil and u.sqlId == nil, "展開動物膠囊：同一 tick 生出（addToWorld）、回傳 kind 與動物，還空膠囊")
    check(after.state == "UNPACKED" and ev.ev == "UNPACKED" and ev.animal == 4321 and ev.x == 10 and ev.car == nil
        and packer.inv:getCountTypeRecurse(Ball.empty) == 1, "紀錄 UNPACKED，事件記動物編號與落點")

    -- the spawned animal is found by id near its recorded spot
    sq(11, 10).animals = { spawned }
    local near = Store.findLoadedAnimal(4321, 10, 10, 3, 0)
    check(near == spawned and Store.findLoadedAnimal(9999, 10, 10, 3, 0) == nil and Store.findLoadedAnimal(4321, 25, 10, 3, 0) == nil
        and Store.findRecorded(after) == spawned, "findLoadedAnimal 比動物編號、只看半徑內；findRecorded 依 kind 找動物")

    -- admin: restore refused while the animal is around, one-square pick check, then restored
    local id = 88001
    local function packedRec(extra)
        local s = { kind = "animal", animal = Json.copy(back), state = "PACKED", settled = true, packedBy = "packer",
            history = { { t = 1, ev = "PACKED", by = "packer", x = 10, y = 10, z = 0, animal = 4321 } } }
        for k, v in pairs(extra or {}) do s[k] = v end
        Store.write(id, s)
    end
    packedRec()
    quiet = true
    local exists = AdminCommands.handle(admin, "adminRestore", { id = id, x = 12, y = 12, z = 0, dir = "E" })
    local resolveExists = Admin.resolve(admin, id, "missing", nil, true)
    sq(11, 10).animals = nil
    sq(12, 12).water = true
    local picked = AdminCommands.handle(admin, "adminRestore", { id = id, x = 12, y = 12, z = 0, dir = "E" })
    local stillPacked = Store.read(id).state
    sq(12, 12).water = nil
    local detail = AdminCommands.adminDetail(admin, { id = id })
    local restored = AdminCommands.handle(admin, "adminRestore", { id = id, x = 12, y = 12, z = 0, dir = "E" })
    quiet = false
    local rs = Store.read(id)
    check(exists.why == "ANIMAL_EXISTS" and resolveExists.why == "NOT_UNCERTAIN", "紀錄的動物還在附近：補回被拒 ANIMAL_EXISTS")
    check(picked.why == "PICK_BLOCKED" and stillPacked == "PACKED", "補回的格子是水：PICK_BLOCKED（一格的落點檢查），紀錄不動")
    check(detail.ok and detail.kind == "animal" and detail.animal.type == "cow" and detail.animal.pregnant == true
        and detail.car == 4321 and detail.carLoaded == false and detail.script == nil and detail.x == 10,
        "管理面板明細：kind、動物摘要（管理員看得到懷孕）、動物編號與在不在附近")
    check(restored.ok and restored.animalId == 4321 and rs.state == "RESTORED" and rs.history[#rs.history].animal == 4321
        and rs.history[#rs.history].x == 10, "補回生出動物，紀錄 RESTORED、事件記動物編號")

    -- record readers branch on kind
    local sumNo, sumYes = Query.summary(id, rs, false), Query.summary(id, rs, true)
    check(sumNo.kind == "animal" and sumNo.animal.name == "Bessie" and sumNo.animal.pregnant == nil and sumYes.animal.pregnant == true
        and sumNo.parts == nil and sumNo.script == nil and sumNo.animal.milkMax == 5.5,
        "Query：動物紀錄回動物摘要；懷孕只給畜牧 > 2（原版規則）")
    local row = Index.row(id, rs)
    local pageRow = Index.page({ q = tostring(id) }, 1).rows[1]
    check(row.kind == "animal" and row.name == "Bessie" and row.atype == "cow" and row.breed == "holstein" and row.script == nil
        and row.x == 10 and pageRow and pageRow.kind == "animal" and pageRow.atype == "cow",
        "索引列與分頁列帶 kind、動物名、種類與品種；紀錄位置取動物的事件")
    check(Index.row(1, { state = "PACKED", script = "Base.PickUpTruck", history = {} }).kind == nil,
        "沒有 kind 的紀錄一律當車")

    -- Economy: listed and bought like a vehicle capsule, nothing escrowed
    local snaps = 0
    MinidoracatEconomy = { v1 = { snapshotItem = function() snaps = snaps + 1; return {} end,
        rebuildItem = function() return nil, "x" end } }
    local listed = instanceItem(Ball.loaded)
    function listed:getUnequippedWeight() return 0 end -- the dedicated server's reading (vcap-tam-1012c listed 0.0)
    function listed:getContentsWeight() return 0 end
    function listed:getScriptItem() return { getActualWeight = function() return 0.2 end } end
    local lid = listed.id
    Store.write(lid, { kind = "animal", animal = Json.copy(back), state = "PACKED", settled = true,
        history = { { t = 1, ev = "PACKED", x = 10, y = 10, z = 0, animal = 4321 } } })
    quiet = true
    local okCheck = Trade.check(listed, packer)
    local ext = Trade.escrow(listed, packer, "market", "L-9")
    local held = Store.read(lid)
    local fresh = instanceItem(Ball.loaded)
    local buyer = newPlayer("buyer", false)
    Trade.rebuilt(ext, fresh, buyer, { kind = "market", ref = "L-9" })
    Guard.check(buyer, fresh)
    quiet = false
    local got = Store.read(lid)
    local v = ext and ext.view or {}
    check(okCheck == true and ext and ext.capsuleId == lid and ext.weight == 0.2 and snaps == 0 and held.escrow.active
        and held.escrow.cargo == nil, "動物膠囊能上架：escrow 不帶貨物")
    check(v.kind == "animal" and v.style == "SphereBasic" and v.animal.name == "Bessie" and v.animal.type == "cow"
        and v.animal.pregnant == nil and v.script == nil, "上架 view：款式、動物名與摘要（不給懷孕）")
    check(fresh.id == lid and #fresh.inv.list == 0 and got.state == "PACKED" and got.escrow.active == nil
        and got.history[#got.history].ev == "TRADED", "rebuilt 改回膠囊編號，紀錄不動；買方身上看到才記 TRADED")
    MinidoracatEconomy = nil
    SandboxVars = nil

    -- strings: every new key in the 16 languages; the loaded name no longer says "vehicle packed"
    local want = {
        Tooltip = { "Animal", "Name", "AgeDays", "Weight", "Milk", "Wild", "Empty", "EmptySphere", "SphereTime",
            "ReturnOn_Loaded", "ReturnOff_Loaded", "ReturnOn_LoadedSphere", "ReturnOff_LoadedSphere", "ReturnOn_Empty",
            "ReturnOff_Empty", "ReturnOn_EmptySphere", "ReturnOff_EmptySphere", "FailGone" },
        IG_UI = { "PackAnimalFailed", "PackAnimalInfo", "Why_ANIMALS_OFF", "Why_NO_ANIMAL", "Why_ANIMAL_AWAY", "Why_ROPE",
            "Why_WATER", "HasSphereNo", "HasSphereKind", "TypeOffRowSphere", "Why_WRONG_ITEM", "Why_WRONG_ITEM_VEHICLE",
            "Why_WRONG_ITEM_RELEASE", "Why_NO_ROOM", "Why_IN_VEHICLE", "ChanceFactor", "FactorSep", "Factor_Injured",
            "Factor_Young", "Factor_Unaware", "Released", "SphereBack", "ReleaseFailed" },
        UI = { "RestoreAnimal", "RestoreAnimalConfirm", "AnimalLoaded", "AnimalNotLoaded", "Why_ANIMAL_EXISTS", "RestoredAnimal" },
        Sandbox = { "AllowAnimals", "AllowAnimals_tooltip", "LootSphereBarn", "LootSphereBarn_tooltip", "LootSphereBarnWeight",
            "LootSphereBarnWeight_tooltip", "LootSpherePet", "LootSpherePet_tooltip", "LootSpherePetWeight",
            "LootSpherePetWeight_tooltip", "LootSphereHunting", "LootSphereHunting_tooltip", "LootSphereHuntingWeight",
            "LootSphereHuntingWeight_tooltip", "ReturnEmptySphere", "ReturnEmptySphere_tooltip" },
        ContextMenu = { "PackSphere", "Release" },
    }
    local PREFIX = { Tooltip = "Tooltip_MinidoracatPackThrow_", IG_UI = "IGUI_MinidoracatPackThrow_",
        UI = "UI_MinidoracatPackThrow_", Sandbox = "Sandbox_MinidoracatPackThrow_", ContextMenu = "ContextMenu_MinidoracatPackThrow_" }
    local gone = { "BlockedTitleAnimal", "BlockedThrowAnimal", "BlockedPressAnimal" } -- a sphere is never thrown nor pressed
    local missing = {}
    for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
        local dir = MEDIA .. "/shared/Translate/" .. lang .. "/"
        for file, keys in pairs(want) do
            local f = io.open(dir .. file .. ".json", "rb")
            local data = f and Json.decode(f:read("*a")) or {}
            if f then f:close() end
            for _, k in ipairs(keys) do
                if type(data[PREFIX[file] .. k]) ~= "string" or data[PREFIX[file] .. k] == "" then missing[#missing + 1] = lang .. ":" .. k end
            end
            if file == "IG_UI" then
                for _, k in ipairs(gone) do if data[PREFIX[file] .. k] then missing[#missing + 1] = lang .. ":" .. k .. "(old)" end end
            end
            for _, k in ipairs(file == "IG_UI" and { "ChanceFactor", "Released", "SphereBack", "HasSphereKind", "TypeOffRowSphere" }
                or file == "ContextMenu" and { "Release" } or {}) do
                if not (data[PREFIX[file] .. k] or ""):find("%1", 1, true) then missing[#missing + 1] = lang .. ":" .. k .. "(no %1)" end
            end
        end
        -- words shown for animal records too (tooltip "packed by", timeline PACKED): not "packed the vehicle" (CH and CN
        -- said so until vcap-animal-mp-1012a showed it under a cow)
        local function says(file, key)
            local fh = io.open(dir .. file .. ".json", "rb")
            local v = fh and Json.decode(fh:read("*a"))[key] or ""
            if fh then fh:close() end
            return v
        end
        local f = io.open(dir .. "ItemName.json", "rb")
        local names = f:read("*a")
        f:close()
        for _, s in ipairs({ names, says("Tooltip", "Tooltip_MinidoracatPackThrow_PackedBy"), says("UI", "UI_MinidoracatPackThrow_Ev_PACKED") }) do
            if s:find("收車", 1, true) or s:find("收车", 1, true) then missing[#missing + 1] = lang .. ":vehicle-only wording" end
        end
        -- strings a player also sees on an animal record or capsule: in EN, CH and CN a vehicle word only together with
        -- "animal" (the VOID tooltip, admin verdicts and the type switches said "vehicle" only until the merge pass)
        local word = ({ EN = { "vehicle", "animal" }, CH = { "車", "動物" }, CN = { "车", "动物" } })[lang]
        if word then
            local shared = {
                Tooltip = { "Loading", "Far", "Restored", "Void", "TypeOff" },
                IG_UI = { "UsedBody", "State_RESTORED", "Trade_NO_RECORD", "Trade_NOT_PACKED", "Trade_UNCERTAIN",
                    "Why_NO_FLOOR", "Why_SPAWN", "TypeOffRow", "Why_TYPE_OFF" },
                UI = { "Why_BLOCKED", "Why_PICK_BLOCKED", "Verdict_present", "Verdict_missing", "VerdictPresent",
                    "VerdictMissing", "UncertainHelp", "TypeUseTip", "TypeOffLine" },
                Sandbox = { "RecordRetentionDays_tooltip" }, -- ReturnEmptyCapsule is capsules only since the split
            }
            for _, t in ipairs(M.TYPES) do -- capsules take vehicles only (their switches say so); spheres animals
                if t.sphere then
                    table.insert(shared.Sandbox, "Type" .. t.id)
                    table.insert(shared.Sandbox, "Type" .. t.id .. "_tooltip")
                end
            end
            for file, keys in pairs(shared) do
                for _, k in ipairs(keys) do
                    local s = says(file, PREFIX[file] .. k):lower()
                    local car = s:find(word[1], 1, true) or (lang == "EN" and s:find("%f[%a]car%f[%A]"))
                    if s == "" or (car and not s:find(word[2], 1, true)) then missing[#missing + 1] = lang .. ":" .. k end
                end
            end
        end
    end
    -- the panel's message after an animal restore (Admin.restore answers animalId) is the animal one
    local panel = io.open(MEDIA .. "/client/MinidoracatPackThrow/AdminPanel.lua", "rb")
    local panelSrc = panel:read("*a")
    panel:close()
    if not panelSrc:find('res.animalId and "RestoredAnimal"', 1, true) then missing[#missing + 1] = "AdminPanel:RestoredAnimal" end
    local sandboxTxt = io.open(MEDIA .. "/../sandbox-options.txt", "rb")
    local sbText = sandboxTxt:read("*a")
    sandboxTxt:close()
    check(#missing == 0 and sbText:find("option MinidoracatPackThrow%.AllowAnimals%s*{type = boolean, default = true, page = MinidoracatPackThrow,") ~= nil,
        "16 種語言都有動物的新字串、裝填名稱不再寫「收車」、與動物共用的字串不只寫車（EN／CH／CN）；沙盒 AllowAnimals 布林、預設開、在主頁（"
        .. table.concat(missing, ",", 1, math.min(#missing, 12)) .. "）")
end
animals()

print("Capture／Safehouse：丟空膠囊抓取（選目標、重找、規則、沒中）與安全屋（選單收、抓取、丟、按、補回）")
local function captureCases() -- 獨立函式：主程式的 local 已接近 200 個上限
    local Throw, Steam, Ball = M.Throw, M.TYPE_BY_ID.Steam, M.FIRST_SPHERE
    SandboxVars = { MinidoracatPackThrow = { PackPermission = 1 } }
    -- 假安全屋：x 20..24、y 30..34，屋主 owner；屋主、成員以外只有 CanGoInsideSafehouses 能碰（SafeHouse.java:245-260）
    local zone, houses = { x1 = 20, y1 = 30, x2 = 24, y2 = 34 }, {}
    SafeHouse = {
        getSafehouseList = function() return javaList(houses) end,
        isSafehouseAllowInteract = function(s, p)
            if not s or not p or #houses == 0 then return true end
            local inside = s:getX() >= zone.x1 and s:getX() <= zone.x2 and s:getY() >= zone.y1 and s:getY() <= zone.y2
            return not inside or p:getUsername() == "owner" or p.canGoInside == true
        end }
    local function at(name, x, y, admin)
        local p = newPlayer(name, admin)
        function p:getX() return x + 0.5 end
        function p:getY() return y + 0.5 end
        function p:getCurrentSquare() return sq(x, y) end
        p.inv.haveThisKeyId = function() return nil end
        p.inv.containsID = function(c, id) return c:getItemWithIDRecursiv(id) ~= nil end
        return p
    end
    local function beast(x, y, oid)
        local a = { x = x, y = y }
        function a:getX() return self.x + 0.5 end
        function a:getY() return self.y + 0.5 end
        function a:getSquare() return sq(self.x, self.y) end
        function a:getOnlineID() return oid end
        function a:getAnimalID() return 9000 + oid end
        function a:isDead() return false end
        function a:isOnHook() return false end
        function a:isExistInTheWorld() return true end
        function a:isWild() return self.wild == true end
        function a:getHealth() return 1 end
        function a:isBaby() return false end
        function a:isAlerted() return true end
        function a:getForwardDirectionX() return 0 end
        function a:getForwardDirectionY() return 1 end
        function a:getData() return { getAttachedPlayer = function() end, getAttachedTree = function() end } end
        sq(x, y).animals = { a }
        return a
    end
    local function move(a, x, y)
        sq(a.x, a.y).animals = nil
        a.x, a.y = x, y
        sq(x, y).animals = { a }
    end
    local function truck(id, x1, y1, x2, y2)
        local v = {}
        function v:getId() return id end
        function v:getX() return (x1 + x2 + 1) / 2 end
        function v:getY() return (y1 + y2 + 1) / 2 end
        function v:getZ() return 0 end
        function v:getSquare() return sq(math.floor(self:getX()), math.floor(self:getY())) end
        function v:getScript() return pickup end
        function v:getMaxPassengers() return 0 end
        function v:getVehicleTowing() return nil end
        function v:getVehicleTowedBy() return nil end
        function v:getAnimals() return javaList({}) end
        function v:isEngineRunning() return self.engine == true end
        function v:getPartCount() return 0 end
        function v:isKeysInIgnition() return false end
        function v:getCurrentKey() return nil end
        function v:getKeyId() return 7 end
        for x = x1, x2 do for y = y1, y2 do sq(x, y).vehicle = v end end
        return v
    end
    local hunter, stranger, owner = at("hunter", 6, 30), at("stranger", 19, 37), at("owner", 19, 37)
    local cow, truck1 = beast(12, 30, 31), truck(501, 14, 28, 15, 32)
    local cow2, truck2, truck3 = beast(22, 31, 32), truck(502, 21, 32, 22, 36), truck(503, 17, 30, 18, 34)

    -- target selection and re-finding
    local function tgt(x, y) local t, a = Footprint.target(x, y, 0); return t, a end
    local t1, a1 = tgt(12, 30)
    local t2, a2 = tgt(14, 29)
    local t3, a3 = tgt(13, 30)
    check(t1 == cow and a1 and t2 == truck1 and a2 == false and t3 == cow and a3 and tgt(3, 3) == nil,
        "選目標：游標格的動物、游標格的車、旁邊一格時動物優先於車；空地沒有目標")
    check(Footprint.find({ kind = "animal", tid = 31 }, 12, 30, 0) == cow and Footprint.find({ kind = "animal", tid = 31 }, 12, 32, 0) == nil
        and Footprint.find({ kind = "animal", thing = cow }, 11, 31, 0) == cow and Footprint.find({ kind = "animal", tid = 99 }, 12, 30, 0) == nil
        and Footprint.find({ kind = "vehicle", tid = 501 }, 13, 30, 0) == truck1 and Footprint.find({ kind = "vehicle", tid = 501 }, 11, 30, 0) == nil,
        "重找目標：MP 比 onlineID／車 id、SP 比物件，只認瞄準點一格內；離開兩格就找不到")
    cow.x = 18 -- teleported this tick: still on its old square's list
    check(Footprint.find({ kind = "animal", tid = 31 }, 12, 30, 0) == nil, "重找目標看動物自己的位置：剛傳送走、還掛在舊格子清單上的不算")
    cow.x = 12

    -- capture rules: the menu's rules with CAPTURE_REACH, TYPE_OFF
    local far = at("far", 12, 10)
    check(Rules.captureWhyNot(hunter, cow, true, Ball) == nil and Rules.captureWhyNot(far, cow, true, Ball) == "TOO_FAR"
        and Rules.animalWhyNot(hunter, cow) == nil and Rules.animalWhyNot(at("h2", 1, 30), cow) == "TOO_FAR",
        "抓取距離用 CAPTURE_REACH（選單仍是 PACK_RANGE）")
    SandboxVars.MinidoracatPackThrow.AllowAnimals = false
    local off = Rules.captureWhyNot(hunter, cow, true, Ball)
    SandboxVars.MinidoracatPackThrow.AllowAnimals, SandboxVars.MinidoracatPackThrow.TypeSphereBasic = nil, false
    local typeOff = Rules.captureWhyNot(hunter, cow, true, Ball)
    SandboxVars.MinidoracatPackThrow.TypeSphereBasic = nil
    local noKey = Rules.captureWhyNot(hunter, truck1, false, Steam)
    hunter.inv.haveThisKeyId = function(_, id) return id == 7 and {} or nil end
    local withKey = Rules.captureWhyNot(hunter, truck1, false, Steam)
    truck1.engine = true
    local running = Rules.captureWhyNot(hunter, truck1, false, Steam)
    truck1.engine = nil
    check(off == "ANIMALS_OFF" and typeOff == "TYPE_OFF" and noKey == "NOT_ALLOWED" and withKey == nil and running == "ENGINE_RUNNING",
        "抓取規則：收動物關閉、款式停用、車沒鑰匙 NOT_ALLOWED（同選單權限）、有鑰匙放行、引擎發動中")

    -- safehouse: the animal's square, the squares under the vehicle's body
    local none = Rules.animalWhyNot(stranger, cow2)
    houses[1] = zone
    local admin = at("boss", 19, 37, true)
    admin.canGoInside = true
    check(none == nil and Rules.animalWhyNot(stranger, cow2) == "SAFEHOUSE" and Rules.animalWhyNot(owner, cow2) == nil
        and Rules.animalWhyNot(admin, cow2) == nil and Rules.packAnimalWhyNot(stranger, cow2, Ball) == "SAFEHOUSE",
        "安全屋：動物那格在別人的安全屋 SAFEHOUSE（選單收也擋）；屋主、有 CanGoInsideSafehouses 的管理員可以；沒有安全屋不擋")
    stranger.inv.haveThisKeyId, owner.inv.haveThisKeyId = hunter.inv.haveThisKeyId, hunter.inv.haveThisKeyId
    check(Rules.vehicleWhyNot(stranger, truck2) == "SAFEHOUSE" and Rules.vehicleWhyNot(owner, truck2) == nil
        and Rules.vehicleWhyNot(stranger, truck3) == nil and Rules.captureWhyNot(stranger, cow2, true, Ball) == "SAFEHOUSE"
        and Rules.captureWhyNot(stranger, truck2, false, Steam) == "SAFEHOUSE",
        "安全屋：車身壓到安全屋的格子就擋（只壓到外框範圍不算）；丟出抓取同一條")

    -- Play.throw with an empty capsule: the capture intent names the target; refusals keep the capsule
    local savedSchedule, savedFx, savedOnline = Throw.schedule, M.Fx.broadcast, getOnlinePlayers
    local scheduled, flights = {}, {}
    Throw.schedule = function(p) scheduled[#scheduled + 1] = p end
    local misses, landingNow = {}, function() return 0 end
    M.Fx.broadcast = function(kind, args)
        if kind == "flight" then flights[#flights + 1] = args end
        if kind == "miss" then misses[#misses + 1] = { id = args.capsuleId, dropsBefore = landingNow() } end
    end
    getOnlinePlayers = function() return javaList({ hunter, stranger }) end
    local function capsuleFor(p, t) return p.inv:AddItem(instanceItem((t or Ball).empty)) end -- a sphere unless t
    local function throwAt(p, item, x, y) return Play.throw({ character = p, item = item, x = x, y = y, z = 0 }) end
    local function lastSent() local s = sent[#sent]; return s and s[4] or {} end
    local c1 = capsuleFor(hunter)
    quiet = true
    clientCommand(M.MODULE, "intent", hunter, { kind = "capture", id = c1.id }) -- no target: not kept
    local noTarget = throwAt(hunter, c1, 12, 30)
    clientCommand(M.MODULE, "intent", hunter, { kind = "capture", id = c1.id, target = "animal", tid = 99 })
    local gone = throwAt(hunter, c1, 12, 30)
    local goneSent = lastSent()
    clientCommand(M.MODULE, "intent", hunter, { kind = "capture", id = c1.id, target = "animal", tid = 31 })
    local thrown = throwAt(hunter, c1, 12, 30)
    local c2 = capsuleFor(stranger)
    clientCommand(M.MODULE, "intent", stranger, { kind = "capture", id = c2.id, target = "animal", tid = 32 })
    local inHouse = throwAt(stranger, c2, 22, 31)
    local houseSent = lastSent()
    quiet = false
    check(noTarget == false and gone == false and goneSent.why == "NO_TARGET" and goneSent.mode == "capture"
        and hunter.inv:getItemWithIDRecursiv(c1.id) == c1, "抓取 intent 沒帶目標不收；目標不在瞄準點：complete 拒絕 NO_TARGET，膠囊留在背包")
    local sp = scheduled[1] or {}
    check(thrown == true and #scheduled == 1 and sp.mode == "capture" and sp.cap and sp.cap.kind == "animal" and sp.cap.tid == 31
        and flights[1] and flights[1].empty == true and flights[1].capsuleId == c1.id,
        "抓取：排落地（mode capture、帶目標），飛行特效畫空膠囊、帶膠囊編號（沒中時好收掉）")
    check(inHouse == false and houseSent.why == "SAFEHOUSE" and #scheduled == 1 and stranger.inv:getItemWithIDRecursiv(c2.id) == c2,
        "丟出抓取別人安全屋裡的動物：丟擲前就被拒 SAFEHOUSE，膠囊留在背包、不排落地")

    -- Throw.capture (landing): the pack path with the thrown capsule, or a miss that drops it
    local packed = {}
    local savedPA, savedP = M.Pack.packAnimal, M.Pack.pack
    M.Pack.packAnimal = function(p, a, opts) packed[#packed + 1] = { p, a, opts }; return { ok = true, capsuleId = 777, kind = "animal" } end
    M.Pack.pack = function(p, v, opts) packed[#packed + 1] = { p, v, opts }; return { ok = true, capsuleId = 778, script = "Base.PickUpTruck" } end
    local function drops(s) local l = {}; s.AddWorldInventoryItem = function(_, it) l[#l + 1] = it end; return l end
    quiet = true
    Throw.land(sp)
    local okSent = lastSent()
    local c3 = capsuleFor(hunter)
    move(cow, 12, 34) -- the target ran off before the capsule landed
    local landing = drops(sq(12, 30))
    landingNow = function() return #landing end
    Throw.land({ player = hunter, capsuleId = c3.id, x = 12, y = 30, z = 0, mode = "capture", cap = { kind = "animal", tid = 31 } })
    local missSent = lastSent()
    local c4 = capsuleFor(hunter, Steam)
    Throw.land({ player = hunter, capsuleId = c4.id, x = 14, y = 30, z = 0, mode = "capture", cap = { kind = "vehicle", tid = 501 } })
    local c5 = capsuleFor(stranger)
    local feet, house = drops(sq(19, 37)), drops(sq(22, 31))
    Throw.land({ player = stranger, capsuleId = c5.id, x = 22, y = 31, z = 0, mode = "capture", cap = { kind = "animal", tid = 77 } })
    quiet = false
    local pa, pv = packed[1] or {}, packed[2] or {}
    check(pa[2] == cow and pa[3].capsule == c1 and pa[3].typeId == "SphereBasic" and pa[3].range == Rules.CAPTURE_REACH
        and okSent.ok and okSent.mode == "capture" and okSent.loadedId == 777 and okSent.capsuleId == c1.id,
        "抓到動物：走 Pack.packAnimal，用的是丟出去的那顆空膠囊、距離用 CAPTURE_REACH，回覆帶裝好的膠囊編號")
    check(missSent.ok == false and missSent.why == "NO_TARGET" and missSent.dropped == true and landing[1] == c3 and #packed == 2,
        "目標在落地前跑開：沒中，空膠囊掉在落點，toast 寫原因")
    check(pv[2] == truck1 and pv[3].empty == c4 and pv[3].type == Steam and pv[3].range == Rules.CAPTURE_REACH,
        "抓到車：走 Pack.pack（同選單收車），用丟出去的空膠囊")
    check(feet[1] == c5 and #house == 0, "沒中且落點在別人的安全屋：空膠囊掉在丟的人腳下，不掉進安全屋")
    check(#misses == 2 and misses[1].id == c3.id and misses[1].dropsBefore == 1 and misses[2].id == c5.id,
        "沒中（目標跑開、安全屋）各廣播一次 miss（帶那顆的編號、在掉到地上之後），抓到的兩次不廣播：飛行圖示不再停 1.5 秒")
    M.Pack.packAnimal, M.Pack.pack = savedPA, savedP

    -- a wild target: at 0% the throw is refused before it flies (WILD_OFF); a miss of the roll at the landing (the real
    -- Pack.packAnimal) drops the empty capsule at the aim point, the reply says ESCAPED with the chance, the hare stays
    local hare = beast(10, 30, 33)
    hare.wild = true
    local c6 = capsuleFor(hunter)
    SandboxVars.MinidoracatPackThrow.WildCaptureChance = 0
    quiet = true
    clientCommand(M.MODULE, "intent", hunter, { kind = "capture", id = c6.id, target = "animal", tid = 33 })
    local offThrow = throwAt(hunter, c6, 10, 30)
    local offSent = lastSent()
    SandboxVars.MinidoracatPackThrow.WildCaptureChance = nil
    local savedRoll = Rules.rollWild
    Rules.rollWild = function() return false end
    local hareDrop = drops(sq(10, 30))
    Throw.land({ player = hunter, capsuleId = c6.id, x = 10, y = 30, z = 0, mode = "capture", cap = { kind = "animal", tid = 33 } })
    local escSent = lastSent()
    Rules.rollWild = savedRoll
    quiet = false
    check(offThrow == false and offSent.why == "WILD_OFF" and #scheduled == 1,
        "成功率 0：丟出抓取野生動物在丟擲前就被拒 WILD_OFF，不排落地")
    check(escSent.ok == false and escSent.why == "ESCAPED" and escSent.chance == 50 and escSent.dropped == true
        and hareDrop[1] == c6 and sq(10, 30).animals[1] == hare,
        "抓取時野生動物掙脫：回覆 ESCAPED 帶成功率 50，空膠囊掉在落點，野兔還在")
    -- WildCaptureFailConsumes on: the hare breaking free takes the thrown capsule (no drop, not in the inventory,
    -- consumed); a miss that is not the roll (the target is not there: NO_TARGET) still drops it at the aim point
    SandboxVars.MinidoracatPackThrow.WildCaptureFailConsumes = true
    Rules.rollWild = function() return false end
    local c7, c8 = capsuleFor(hunter), capsuleFor(hunter)
    local goneDrop, awayDrop = drops(sq(10, 30)), drops(sq(10, 33))
    quiet = true
    Throw.land({ player = hunter, capsuleId = c7.id, x = 10, y = 30, z = 0, mode = "capture", cap = { kind = "animal", tid = 33 } })
    local goneSent = lastSent()
    Throw.land({ player = hunter, capsuleId = c8.id, x = 10, y = 33, z = 0, mode = "capture", cap = { kind = "animal", tid = 33 } })
    local awaySent = lastSent()
    quiet = false
    Rules.rollWild = savedRoll
    SandboxVars.MinidoracatPackThrow.WildCaptureFailConsumes = nil
    check(goneSent.why == "ESCAPED" and goneSent.consumed == true and goneSent.dropped == nil and #goneDrop == 0
        and hunter.inv:getItemWithIDRecursiv(c7.id) == nil and c7.container == nil and sq(10, 30).animals[1] == hare
        and escSent.consumed == nil,
        "沒抓到時膠囊消失（開）：抓取掙脫 consumed=true，丟出的空膠囊不在落點也不在背包，野兔還在；關著時照舊掉在落點")
    check(awaySent.why == "NO_TARGET" and awaySent.consumed == nil and awaySent.dropped == true and awayDrop[1] == c8,
        "沒抓到時膠囊消失（開）：不是擲骰失敗（目標不在）照舊掉在落點")

    -- releasing into a safehouse: throw drops at the thrower's feet, press keeps the capsule, the admin restore refuses
    local function animalRecord(item)
        Store.write(item.id, { kind = "animal", animal = { type = "cow", breed = "holstein", animalId = 4321 }, state = "PACKED",
            settled = true, packedBy = "x", history = { { t = 1, ev = "PACKED", x = 5, y = 5, z = 0, animal = 4321 } } })
        return item
    end
    local l1 = animalRecord(stranger.inv:AddItem(instanceItem(Steam.loaded)))
    local l2 = animalRecord(stranger.inv:AddItem(instanceItem(Steam.loaded)))
    feet = drops(sq(19, 37))
    landingNow = function() return #feet end
    local missesBefore = #misses
    quiet = true
    Throw.land({ player = stranger, capsuleId = l1.id, x = 22, y = 31, z = 0, mode = "throw", dir = "E" })
    local throwSent = lastSent()
    Throw.land({ player = stranger, capsuleId = l2.id, x = 22, y = 31, z = 0, mode = "press", dir = "E" })
    local pressSent = lastSent()
    quiet = false
    check(throwSent.why == "SAFEHOUSE" and throwSent.feet == true and throwSent.dropped == true and feet[1] == l1
        and Store.read(l1.id).state == "PACKED", "丟裝好的膠囊進別人的安全屋：落地被拒，膠囊掉在丟的人腳下，紀錄不動")
    local m = misses[missesBefore + 1] or {}
    check(#misses == missesBefore + 1 and m.id == l1.id and m.dropsBefore == 1,
        "落地被拒的丟出廣播 miss（帶那顆的編號、在掉到腳下之後）：飛行圖示馬上收；按按鈕被拒沒有飛行、不廣播")
    check(pressSent.why == "SAFEHOUSE" and pressSent.dropped == nil and stranger.inv:getItemWithIDRecursiv(l2.id) == l2
        and Throw.safehouse(owner, Store.read(l2.id), 22, 31, 0, "E") == nil and Throw.safehouse(stranger, Store.read(l2.id), 12, 31, 0, "E") == nil,
        "按按鈕放進別人的安全屋被拒、膠囊不動；屋主或安全屋外可以")
    local l3 = animalRecord(stranger.inv:AddItem(instanceItem(Ball.loaded)))
    quiet = true
    Throw.land({ player = stranger, capsuleId = l3.id, x = 22, y = 31, z = 0, mode = "release", dir = "E" })
    local releaseSent = lastSent()
    quiet = false
    check(releaseSent.why == "SAFEHOUSE" and releaseSent.mode == "release" and releaseSent.dropped == nil
        and stranger.inv:getItemWithIDRecursiv(l3.id) == l3 and Store.read(l3.id).state == "PACKED",
        "帕魯球放出時那格剛好在別人的安全屋（落地再驗）：被拒，帕魯球留在背包，紀錄不動")
    local restorer = at("restorer", 19, 37, true)
    quiet = true
    local refused = Admin.restore(restorer, l2.id, 22, 31, 0, nil, nil, "E")
    local savedSpawn = M.Unpack.spawn
    M.Unpack.spawn = function() return { getSquare = function() return sq(22, 31) end, getAnimalID = function() return 4321 end }, {} end
    restorer.canGoInside = true
    local passed = Admin.restore(restorer, l2.id, 22, 31, 0, nil, nil, "E")
    M.Unpack.spawn = savedSpawn
    quiet = false
    check(refused.why == "SAFEHOUSE" and passed.ok == true, "管理員補回到別人的安全屋：沒有 CanGoInsideSafehouses 擋 SAFEHOUSE，有就放行")

    Throw.schedule, M.Fx.broadcast, getOnlinePlayers = savedSchedule, savedFx, savedOnline
    houses[1] = nil
    SafeHouse, SandboxVars = nil, nil
    for _, s in ipairs({ sq(12, 34), sq(22, 31), sq(10, 30) }) do s.animals = nil end
    for x = 14, 22 do for y = 28, 36 do sq(x, y).vehicle = nil end end

    -- strings in the 16 languages
    local want = {
        IG_UI = { "IGUI_MinidoracatPackThrow_Why_SAFEHOUSE", "IGUI_MinidoracatPackThrow_Why_SAFEHOUSE_RELEASE",
            "IGUI_MinidoracatPackThrow_Why_NO_TARGET", "IGUI_MinidoracatPackThrow_CaptureFits", "IGUI_MinidoracatPackThrow_CaptureTarget",
            "IGUI_MinidoracatPackThrow_CaptureNoFit", "IGUI_MinidoracatPackThrow_Captured", "IGUI_MinidoracatPackThrow_CaptureFailed",
            "IGUI_MinidoracatPackThrow_CaptureDropped", "IGUI_MinidoracatPackThrow_DroppedAtFeet",
            "IGUI_MinidoracatPackThrow_CapturedHere", "IGUI_MinidoracatPackThrow_CaptureKept" },
        ContextMenu = { "ContextMenu_MinidoracatPackThrow_Capture" },
        UI = { "UI_MinidoracatPackThrow_Why_SAFEHOUSE" },
    }
    local missing = {}
    for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
        for file, keys in pairs(want) do
            local f = io.open(MEDIA .. "/shared/Translate/" .. lang .. "/" .. file .. ".json", "rb")
            local data = f and Json.decode(f:read("*a")) or {}
            if f then f:close() end
            for _, k in ipairs(keys) do
                if type(data[k]) ~= "string" or data[k] == "" then missing[#missing + 1] = lang .. ":" .. k end
            end
        end
    end
    check(#missing == 0, "16 種語言都有抓取與安全屋的字串（" .. table.concat(missing, ",", 1, math.min(#missing, 12)) .. "）")
end
captureCases()

print("Sphere：帕魯球（成功率與三種加成、膠囊只收車／帕魯球只抓動物、放出在身旁、NO_ROOM、不能丟或按、還同等級）")
local function sphereCases() -- 獨立函式：主程式的 local 已接近 200 個上限
    local Ball, Mega, Legend, Steam = M.FIRST_SPHERE, M.TYPE_BY_ID.SphereMega, M.TYPE_BY_ID.SphereLegend, M.TYPE_BY_ID.Steam
    local Throw, Unpack = M.Throw, M.Unpack
    -- a live animal on (x, y) facing +y unless o says otherwise; alerted unless o.unaware
    local function animal(o)
        local a = { x = o.x or 12, y = o.y or 10 }
        function a:getX() return self.x + 0.5 end
        function a:getY() return self.y + 0.5 end
        function a:getSquare() return sq(self.x, self.y) end
        function a:isWild() return o.wild == true end
        function a:getHealth() return o.health or 1 end
        function a:isBaby() return o.baby == true end
        function a:isAlerted() return not o.unaware end
        function a:getForwardDirectionX() return o.fx or 0 end
        function a:getForwardDirectionY() return o.fy or 1 end
        function a:isDead() return false end
        function a:isOnHook() return false end
        function a:isExistInTheWorld() return true end
        function a:getData() return { getAttachedPlayer = function() end, getAttachedTree = function() end } end
        function a:getOnlineID() return 55 end
        function a:getAnimalID() return 5555 end
        return a
    end
    local function player(name, x, y)
        local p = newPlayer(name, false)
        function p:getX() return x + 0.5 end
        function p:getY() return y + 0.5 end
        function p:getCurrentSquare() return sq(x, y) end
        p.inv.containsID = function(c, id) return c:getItemWithIDRecursiv(id) ~= nil end
        return p
    end
    local me = player("me", 12, 7) -- three squares north of the animal: in front of one facing -y, behind one facing +y
    local function chance(o, t, sb)
        SandboxVars = { MinidoracatPackThrow = sb or {} }
        local c = Rules.captureChance(me, animal(o), t and t.id)
        if not c then return "tame" end
        local parts = { tostring(c.total) }
        for _, f in ipairs(c.factors) do parts[#parts + 1] = f[1] .. f[2] end
        return table.concat(parts, " ")
    end
    check(chance({}, Ball) == "tame" and chance({ wild = true }, Ball) == "50" and chance({ wild = true }, Mega) == "65 Tier15"
        and chance({ wild = true }, M.TYPE_BY_ID.SphereGiga) == "80 Tier30" and chance({ wild = true }, Legend) == "100 Tier50",
        "成功率：家養沒有（一律成功）；基本 50，帕魯球 +0、高級 +15、優質 +30、傳奇 +50")
    check(chance({ wild = true, health = 0.6 }, Ball) == "62 Injured12" and chance({ wild = true, health = 0 }, Ball) == "80 Injured30"
        and chance({ wild = true, health = 1.7 }, Ball) == "50" and chance({ wild = true, baby = true }, Ball) == "65 Young15",
        "受傷：round((1 - 健康) × 30)（0.6 → +12、0 → +30，超過 1 不加）；幼崽 +15")
    me.sneak = false
    local behind = chance({ wild = true, unaware = true }, Ball)                       -- facing +y, me at -y: behind it
    local front = chance({ wild = true, unaware = true, fy = -1 }, Ball)              -- facing me
    local alerted = chance({ wild = true, fy = 1 }, Ball)                             -- behind it but alerted
    me.sneak = true
    local sneaking = chance({ wild = true, unaware = true, fy = -1 }, Ball)
    local sneakAlerted = chance({ wild = true, fy = -1 }, Ball)
    me.sneak = nil
    check(behind == "70 Unaware20" and front == "50" and alerted == "50" and sneaking == "70 Unaware20" and sneakAlerted == "50",
        "沒發現你：沒在警戒，而且在牠背後（夾角大於 90 度）或潛行才 +20；警戒中一律不加")
    check(chance({ wild = true, health = 0.5, baby = true, unaware = true }, Mega) == "100 Tier15 Injured15 Young15 Unaware20"
        and chance({ wild = true, health = 0.5, baby = true }, Mega, { WildCaptureChance = 10, WildCaptureInjuredBonus = 0,
            WildCaptureYoungBonus = 40 }) == "65 Tier15 Young40"
        and chance({ wild = true, health = 0.5, baby = true }, Legend, { WildCaptureChance = 0 }) == "0",
        "上限 100；沙盒加成 0＝關掉那項（不列）、可調大；基本 0 時加成救不回來（WILD_OFF）")

    -- capsules take vehicles, spheres animals: menu rules, the server's pack, the capture cursor
    SandboxVars = { MinidoracatPackThrow = { PackPermission = 2 } }
    local hare = animal({ wild = true })
    local car = { getId = function() return 9 end }
    local p = player("p", 12, 9)
    local steamEmpty, ballEmpty = p.inv:AddItem(instanceItem(Steam.empty)), p.inv:AddItem(instanceItem(Ball.empty))
    local savedV = Rules.vehicleWhyNot
    Rules.vehicleWhyNot = function() return nil end
    check(Rules.packAnimalWhyNot(p, hare, Steam) == "WRONG_ITEM" and Rules.packAnimalWhyNot(p, hare, Ball) == nil
        and Rules.captureWhyNot(p, hare, true, Steam) == "WRONG_ITEM" and Rules.captureWhyNot(p, hare, true, Ball) == nil
        and Rules.captureWhyNot(p, car, false, Ball) == "WRONG_ITEM" and Rules.captureWhyNot(p, car, false, Steam) == nil
        and Rules.packWhyNot(p, car, Ball) == "WRONG_ITEM",
        "規則：膠囊收動物、帕魯球收車都是 WRONG_ITEM（選單、丟出抓取的游標與伺服器同一條）")
    Rules.vehicleWhyNot = savedV
    local byType = M.Pack.packAnimal(p, hare, { capsule = steamEmpty, typeId = "Steam" })
    local byItem = M.Pack.packAnimal(p, hare, { capsule = steamEmpty, typeId = "SphereBasic" })
    local sphereCar = M.Pack.pack(p, car, { type = Ball, empty = ballEmpty })
    check(byType.why == "WRONG_ITEM" and byItem.why == "WRONG_ITEM" and sphereCar.why == "WRONG_ITEM"
        and p.inv:getItemWithIDRecursiv(steamEmpty.id) == steamEmpty and p.inv:getItemWithIDRecursiv(ballEmpty.id) == ballEmpty,
        "伺服器：Pack.packAnimal 只收帕魯球（款式或那顆是膠囊都拒）、Pack.pack 只收膠囊，拒絕時什麼都不動")

    -- where the animal comes out: the faced square first, then the nearest to it; NO_ROOM when none fits
    SafeHouse = nil
    local r = player("r", 10, 10)
    r.fx, r.fy = 1, 0 -- facing east
    local function spot() local x, y = Rules.releaseSpot(r); return x and (x .. "," .. y) or y end
    local first = spot()
    sq(11, 10).free = false
    local second = spot()
    local ring = {}
    for dx = -1, 1 do for dy = -1, 1 do if dx ~= 0 or dy ~= 0 then ring[#ring + 1] = sq(10 + dx, 10 + dy) end end end
    for _, s in ipairs(ring) do s.free = false end
    sq(9, 11).free = true
    local last = spot()
    sq(9, 11).water = true
    local none = spot()
    sq(9, 11).water = nil
    for _, s in ipairs(ring) do s.free = true end
    losBlocked = true
    local blind = spot()
    losBlocked = false
    SafeHouse = { getSafehouseList = function() return javaList({ 1 }) end,
        isSafehouseAllowInteract = function(s) return not (s:getX() == 11 and s:getY() == 10) end }
    local house = spot()
    SafeHouse = nil
    check(first == "11,10" and second == "11,9" and last == "9,11" and none == "NO_ROOM" and blind == "NO_ROOM" and house == "11,9",
        "放出的位置：面向的那格（東 11,10）優先，擋住就換最接近面向的（11,9），只剩背後也可以；八格都不行（水、家具、看不到）NO_ROOM；別人的安全屋那格跳過")

    -- Play.release: intent, the spot, the landing at once (press path); refusals keep the sphere
    local scheduled, savedSchedule = {}, Throw.schedule
    Throw.schedule = function(pp, at) scheduled[#scheduled + 1] = { p = pp, at = at } end
    local function loaded(t, owner)
        local it = owner.inv:AddItem(instanceItem(t.loaded))
        Store.write(it.id, { kind = "animal", animal = { type = "rabbit", breed = "swamp", name = "Hop", animalId = 77 },
            state = "PACKED", settled = true, packedBy = "r", history = { { t = 1, ev = "PACKED", x = 5, y = 5, z = 0, animal = 77 } } })
        return it
    end
    local function lastSent() local s = sent[#sent]; return s and s[4] or {} end
    local ball = loaded(Mega, r)
    quiet = true
    local noIntent = Play.release(r, ball)
    clientCommand(M.MODULE, "intent", r, { kind = "release", id = ball.id })
    local ok = Play.release(r, ball)
    r.vehicle = {}
    clientCommand(M.MODULE, "intent", r, { kind = "release", id = ball.id })
    local inCar = Play.release(r, ball)
    local carSent = lastSent()
    r.vehicle = nil
    for _, s in ipairs(ring) do s.free = false end
    clientCommand(M.MODULE, "intent", r, { kind = "release", id = ball.id })
    local full = Play.release(r, ball)
    local fullSent = lastSent()
    for _, s in ipairs(ring) do s.free = true end
    local capsule = r.inv:AddItem(instanceItem(Steam.loaded))
    clientCommand(M.MODULE, "intent", r, { kind = "release", id = capsule.id })
    local notSphere = Play.release(r, capsule)
    -- a loaded sphere is never thrown nor pressed, even with a forged intent
    clientCommand(M.MODULE, "intent", r, { kind = "throw", id = ball.id })
    local thrown = Play.throw({ character = r, item = ball, x = 14, y = 10, z = 0 })
    local throwSent = lastSent()
    local savedWorld = ball.getWorldItem
    ball.getWorldItem = function() return { getSquare = function() return sq(11, 10) end } end
    clientCommand(M.MODULE, "intent", r, { kind = "press", id = ball.id })
    local pressed = Play.press(r, ball.id, 12, 10, 0)
    local pressSent = lastSent()
    ball.getWorldItem = savedWorld
    quiet = false
    local sp = scheduled[1] and scheduled[1].p or {}
    check(noIntent == false and ok == true and #scheduled == 1 and sp.mode == "release" and sp.x == 11 and sp.y == 10
        and sp.capsuleId == ball.id and scheduled[1].at == nowMs,
        "Play.release：要有 release intent；排一次 mode=release 的落地，就在面向那格、馬上（照按按鈕的流程）")
    check(inCar == false and carSent.why == "IN_VEHICLE" and full == false and fullSent.why == "NO_ROOM" and fullSent.mode == "release"
        and notSphere == false and #scheduled == 1 and r.inv:getItemWithIDRecursiv(ball.id) == ball,
        "在車上不能放（IN_VEHICLE）；四周都擋住回 NO_ROOM；膠囊不能「放出」；帕魯球都留在背包")
    check(thrown == false and throwSent.why == "WRONG_ITEM" and pressed == false and pressSent.why == "WRONG_ITEM" and #scheduled == 1,
        "硬送裝了動物的帕魯球的 throw／press intent：伺服器拒絕 WRONG_ITEM，不排落地")
    Throw.schedule = savedSchedule

    -- the landing: Unpack as for a capsule; ReturnEmptySphere gives back an empty sphere of the same tier
    local savedSpawn, savedFx, savedOnline = Unpack.spawn, M.Fx.broadcast, getOnlinePlayers
    local fx = {}
    Unpack.spawn = function(_, square)
        return { getSquare = function() return square end, getAnimalID = function() return 77 end,
            getOnlineID = function() return 701 end }, { home = 0, other = 0, ground = 0 }
    end
    M.Fx.broadcast = function(kind, args) fx[#fx + 1] = { kind, args } end
    getOnlinePlayers = function() return javaList({ r }) end
    SandboxVars = { MinidoracatPackThrow = {} }
    quiet = true
    Throw.land(sp)
    local landed, megaBack = lastSent(), r.inv:getCountTypeRecurse(Mega.empty)
    SandboxVars.MinidoracatPackThrow.ReturnEmptySphere = false
    local legend = loaded(Legend, r)
    Throw.land({ player = r, capsuleId = legend.id, x = 11, y = 10, z = 0, mode = "release", dir = "E" })
    local noBack = lastSent()
    -- the two options are independent: capsules follow ReturnEmptyCapsule, spheres ReturnEmptySphere
    SandboxVars.MinidoracatPackThrow = { ReturnEmptyCapsule = false }
    local mega2 = loaded(Mega, r)
    Throw.land({ player = r, capsuleId = mega2.id, x = 12, y = 10, z = 0, mode = "release", dir = "E" })
    local sphereStill = lastSent()
    local capOff = Unpack.unpack(r, loaded(Steam, r), getCell():getGridSquare(13, 10, 0), "E")
    local steamAfterOff = r.inv:getCountTypeRecurse(Steam.empty)
    SandboxVars.MinidoracatPackThrow = { ReturnEmptySphere = false }
    local capOn = Unpack.unpack(r, loaded(Steam, r), getCell():getGridSquare(14, 10, 0), "E")
    local steamAfterOn = r.inv:getCountTypeRecurse(Steam.empty)
    quiet = false
    check(landed.ok and landed.mode == "release" and landed.kind == "animal" and landed.type == "SphereMega" and landed.returned
        and r.inv:getItemWithIDRecursiv(ball.id) == nil and megaBack == 1
        and Store.read(ball.id).state == "UNPACKED" and fx[1] and fx[1][1] == "unpack" and fx[1][2].style == Mega.index
        and fx[1][2].capsuleId == ball.id,
        "放出落地：紀錄 UNPACKED、帕魯球拿走、還一顆空的高級帕魯球（同等級），特效用它的款式（科幻）、帶那顆的編號")
    check(noBack.ok and not noBack.returned and r.inv:getCountTypeRecurse(Legend.empty) == 0,
        "ReturnEmptySphere 關掉時不還空帕魯球")
    check(sphereStill.ok and sphereStill.returned and capOff.ok and not capOff.returned and capOn.ok and capOn.returned
        and steamAfterOn == steamAfterOff + 1 and M.Rules.returnsEmpty(Steam) and not M.Rules.returnsEmpty(Mega),
        "兩個設定互不影響：ReturnEmptyCapsule 關、帕魯球照還；ReturnEmptySphere 關、膠囊照還（伺服器 Unpack 與 Rules.returnsEmpty）")
    check(Mega.smoke == M.TYPE_BY_ID.SciFi.smoke and Mega.pop == M.TYPE_BY_ID.SciFi.pop and Mega.pack == M.TYPE_BY_ID.SciFi.pack,
        "帕魯球的煙霧與音效＝科幻款")
    Unpack.spawn, M.Fx.broadcast, getOnlinePlayers = savedSpawn, savedFx, savedOnline
    SandboxVars = nil
end
sphereCases()

print("Notify：Toast 沒有第二行時只寫一次")
local function toastCases() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved, shown, dialogs = MinidoracatUI, {}, {}
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 18, CAPABILITIES = { toast = true, dialog = true },
        Toast = { show = function(o) shown[#shown + 1] = o end },
        Dialog = { show = function(o) dialogs[#dialogs + 1] = o end } } }
    loaded["MinidoracatUI/V1"] = true
    -- Info and Effects pull in vanilla UI classes; the toast only needs the animal's name
    loaded["MinidoracatPackThrow/Info"], loaded["MinidoracatPackThrow/Effects"] = true, true
    local savedInfo = M.Info
    M.Info = { animalName = function(a) return a.name end, itemName = function(ft) return "name:" .. tostring(ft) end }
    require "MinidoracatPackThrow/Notify"
    -- unpacked with ReturnEmptyCapsule off (no "empty capsule is back" line), then on
    local cow = { type = "cow", name = "E2E Bessie" }
    M.onServerCommand("landed", { ok = true, mode = "throw", kind = "animal", animal = cow })
    M.onServerCommand("landed", { ok = true, mode = "throw", kind = "animal", animal = cow, returned = true })
    local one, two = shown[1] or {}, shown[2] or {}
    check(#shown == 2 and one.title == nil and one.message == "IGUI_MinidoracatPackThrow_Unpacked"
        and two.title == "IGUI_MinidoracatPackThrow_Unpacked" and two.message == "IGUI_MinidoracatPackThrow_EmptyBack",
        "展開的 Toast：ReturnEmptyCapsule 關掉時只有一行（標題不再當內文重複），開著時標題＋空膠囊回來")
    -- a missed capture: the reason goes in the message, which wraps; the title is one line the framework never wraps
    -- (the French reason ran past the toast's edge, vcap-capture-fr-1013r)
    local savedText, savedOrNull = getText, getTextOrNull
    getText = function(key, a) return a and (key .. "(" .. a .. ")") or key end
    -- like the game: getTextOrNull is nil for a key no file has (only these _VEHICLE / _RELEASE variants exist)
    local real = { IGUI_MinidoracatPackThrow_Why_WRONG_ITEM_VEHICLE = true, IGUI_MinidoracatPackThrow_Why_WRONG_ITEM_RELEASE = true,
        IGUI_MinidoracatPackThrow_Why_SAFEHOUSE_RELEASE = true }
    getTextOrNull = function(key)
        if (key:find("_VEHICLE$") or key:find("_RELEASE$")) and not real[key] then return nil end
        return key
    end
    M.onServerCommand("landed", { ok = false, mode = "capture", why = "NO_TARGET", dropped = true })
    M.onServerCommand("landed", { ok = false, mode = "capture", why = "TOO_FAR" })
    -- a wild animal that broke free (ESCAPED) says the chance it had, thrown or by menu; the tooltip row for a wild
    -- animal only, and none while wild ones are switched off (WILD_OFF is the reason row then)
    M.onServerCommand("landed", { ok = false, mode = "capture", why = "ESCAPED", chance = 35, dropped = true })
    M.onServerCommand("packed", { ok = false, kind = "animal", why = "ESCAPED", chance = 35 })
    SandboxVars = { MinidoracatPackThrow = { WildCaptureChance = 35 } }
    local me = newPlayer("me", false)
    local function beast(o)
        local a = { isWild = function() return o.wild == true end, getHealth = function() return o.health or 1 end,
            isBaby = function() return o.baby == true end, isAlerted = function() return true end,
            getForwardDirectionX = function() return 0 end, getForwardDirectionY = function() return 1 end,
            getX = function() return 100.5 end, getY = function() return 199.5 end }
        return a
    end
    local wildOne, tameOne, Ball = beast({ wild = true }), beast({}), M.FIRST_SPHERE
    local row, tameRow = M.Notify.chanceRows(me, wildOne, Ball), M.Notify.chanceRows(me, tameOne, Ball)
    SandboxVars.MinidoracatPackThrow.WildCaptureChance = 0
    local offRow = M.Notify.chanceRows(me, wildOne, Ball)
    -- WildCaptureFailConsumes on: the row warns a miss takes the sphere (not at 100: no miss); a consumed escape says
    -- the sphere is gone instead of where it lies
    SandboxVars.MinidoracatPackThrow = { WildCaptureChance = 35, WildCaptureFailConsumes = true }
    local goneRow = M.Notify.chanceRows(me, wildOne, Ball)
    SandboxVars.MinidoracatPackThrow.WildCaptureChance = 100
    local sureRow = M.Notify.chanceRows(me, wildOne, Ball)
    M.onServerCommand("landed", { ok = false, mode = "capture", why = "ESCAPED", chance = 35, consumed = true })
    M.onServerCommand("packed", { ok = false, kind = "animal", why = "ESCAPED", chance = 35, consumed = true })
    SandboxVars = nil
    local goneToast, goneDlg = shown[6] or {}, dialogs[2] or {}
    check(goneRow:find("IGUI_MinidoracatPackThrow_WildChanceGone(35)", 1, true) ~= nil
        and sureRow:find("IGUI_MinidoracatPackThrow_WildChance(100)", 1, true) ~= nil and row:find("Gone", 1, true) == nil
        and goneToast.title == "IGUI_MinidoracatPackThrow_CaptureFailed"
        and goneToast.message == "IGUI_MinidoracatPackThrow_EscapedGone(35)"
        and goneDlg.text == "IGUI_MinidoracatPackThrow_EscapedGone(35)",
        "沒抓到時膠囊消失：開著時成功率列加「沒抓到膠囊會消失」（100 不加、關著不加）；掙脫的 Toast 與對話框寫膠囊也消失了")
    -- the factor row under the chance: the tier by its item name, then the non-zero bonuses
    SandboxVars = { MinidoracatPackThrow = { WildCaptureChance = 40 } }
    local mega = M.TYPE_BY_ID.SphereMega
    local factorRow = M.Notify.chanceRows(me, beast({ wild = true, health = 0.5, baby = true }), mega)
    local plainRow = M.Notify.chanceRows(me, wildOne, Ball)
    -- WRONG_ITEM: a capsule at an animal says "use a Pal Sphere", a sphere at a vehicle its own line; a release refused
    M.onServerCommand("packed", { ok = false, kind = "animal", why = "WRONG_ITEM" })
    M.onServerCommand("packed", { ok = false, why = "WRONG_ITEM" })
    M.onServerCommand("landed", { ok = false, mode = "capture", why = "WRONG_ITEM", kind = "animal" })
    M.onServerCommand("landed", { ok = false, mode = "release", why = "NO_ROOM", kind = "animal" })
    M.onServerCommand("landed", { ok = true, mode = "release", kind = "animal", animal = cow, returned = true, type = "SphereMega" })
    M.onServerCommand("landed", { ok = false, mode = "throw", why = "WRONG_ITEM", capsuleId = 5 }) -- a forged sphere throw
    SandboxVars = nil
    local n = #dialogs
    local animalDlg, vehicleDlg, roomDlg = dialogs[n - 3] or {}, dialogs[n - 2] or {}, dialogs[n - 1] or {}
    local throwDlg = dialogs[n] or {}
    local wrongToast, releasedToast = shown[#shown - 1] or {}, shown[#shown] or {}
    check(factorRow:find("IGUI_MinidoracatPackThrow_WildChance(85)", 1, true) ~= nil
        and factorRow:find("IGUI_MinidoracatPackThrow_ChanceFactor(name:MinidoracatPackThrow.SphereMega)", 1, true) ~= nil
        and factorRow:find("IGUI_MinidoracatPackThrow_ChanceFactor(IGUI_MinidoracatPackThrow_Factor_Injured)", 1, true) ~= nil
        and factorRow:find("IGUI_MinidoracatPackThrow_ChanceFactor(IGUI_MinidoracatPackThrow_Factor_Young)", 1, true) ~= nil
        and factorRow:find("Unaware", 1, true) == nil and factorRow:find("IGUI_MinidoracatPackThrow_FactorSep", 1, true) ~= nil
        and plainRow:find("ChanceFactor", 1, true) == nil,
        "成功率列下面列出非 0 的加成（高級帕魯球、受傷、幼崽；40＋15＋15＋15＝85）；沒有加成就只有成功率一列")
    check(animalDlg.title == "IGUI_MinidoracatPackThrow_PackAnimalFailed" and animalDlg.text == "IGUI_MinidoracatPackThrow_Why_WRONG_ITEM"
        and vehicleDlg.title == "IGUI_MinidoracatPackThrow_PackFailed" and vehicleDlg.text == "IGUI_MinidoracatPackThrow_Why_WRONG_ITEM_VEHICLE"
        and wrongToast.message == "IGUI_MinidoracatPackThrow_CaptureKept(IGUI_MinidoracatPackThrow_Why_WRONG_ITEM)",
        "WRONG_ITEM：膠囊收動物寫「要用帕魯球」、帕魯球收車寫「帕魯球收不了車」（選單與抓取）")
    check(roomDlg.title == "IGUI_MinidoracatPackThrow_ReleaseFailed" and roomDlg.text == "IGUI_MinidoracatPackThrow_Why_NO_ROOM"
        and releasedToast.title == "IGUI_MinidoracatPackThrow_Released(E2E Bessie)"
        and releasedToast.message == "IGUI_MinidoracatPackThrow_SphereBack(name:MinidoracatPackThrow.SphereMega)"
        and throwDlg.title == "IGUI_MinidoracatPackThrow_ReleaseFailed" and throwDlg.text == "IGUI_MinidoracatPackThrow_Why_WRONG_ITEM_RELEASE",
        "放出：沒空地的對話框寫「沒有放出動物：旁邊沒有空地」；成功的 Toast 寫已放出與同等級的空帕魯球回來；"
            .. "硬送丟出帕魯球被拒的對話框也是「沒有放出動物」＋「從物品欄放出」")
    getText, getTextOrNull = savedText, savedOrNull
    local drop, kept, esc, dlg = shown[3] or {}, shown[4] or {}, shown[5] or {}, dialogs[1] or {}
    check(drop.title == "IGUI_MinidoracatPackThrow_CaptureFailed"
        and drop.message == "IGUI_MinidoracatPackThrow_CaptureDropped(IGUI_MinidoracatPackThrow_Why_NO_TARGET)"
        and kept.title == "IGUI_MinidoracatPackThrow_CaptureFailed"
        and kept.message == "IGUI_MinidoracatPackThrow_CaptureKept(IGUI_MinidoracatPackThrow_Why_TOO_FAR)",
        "沒抓到的 Toast：標題只有「沒抓到」，原因和膠囊在哪都在會換行的內文")
    check(esc.title == "IGUI_MinidoracatPackThrow_CaptureFailed"
        and esc.message == "IGUI_MinidoracatPackThrow_CaptureDropped(IGUI_MinidoracatPackThrow_Why_ESCAPED(35))"
        and dlg.title == "IGUI_MinidoracatPackThrow_PackAnimalFailed" and dlg.text == "IGUI_MinidoracatPackThrow_Why_ESCAPED(35)",
        "野生動物掙脫：抓取的 Toast 與選單收的通知都寫出成功率")
    check(row:find("IGUI_MinidoracatPackThrow_WildChance(35)", 1, true) ~= nil and tameRow == "" and offRow == "",
        "成功率列：野生動物才有、寫出沙盒的成功率；家養動物與成功率 0 沒有")
    MinidoracatUI, M.Info = saved, savedInfo
end
toastCases()

print("Info：查詢合併成一批、伺服器丟掉的會重送；放出選單不用物品名（不會出現「放出：高級帕魯球：Hop」）")
local function infoCases() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved = { Info = M.Info, Events = Events, isClient = isClient, getText = getText, gsp = getSpecificPlayer,
        send = sendClientCommand }
    local ticks, batches, srv = {}, {}, nil
    Events = setmetatable({ OnTickEvenPaused = { Add = function(fn) ticks[#ticks + 1] = fn end },
        OnServerCommand = { Add = function(fn) srv = srv or fn end } },
        { __index = function() return { Add = function() end } end })
    ISInventoryPane, ISInventoryPage = { refreshContainer = function() end }, { renderDirty = false }
    loaded["ISUI/ISInventoryPane"] = true
    isClient = function() return true end
    local me = newPlayer("me", false)
    getSpecificPlayer = function() return me end
    sendClientCommand = function(_, _, cmd, args) if cmd == "query" then batches[#batches + 1] = args.ids end end
    getText = function(key, a) return a and (key .. "(" .. tostring(a) .. ")") or key end
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/Info.lua")()
    local Info = M.Info
    local function tick(ms) nowMs = nowMs + (ms or 0); for _, fn in ipairs(ticks) do fn() end end
    local function reply(items) srv(M.MODULE, "query", { items = items }) end
    -- three loaded items reach the inventory in the same tick (and one is asked twice)
    local got = { Info.get(501), Info.get(502), Info.get(503), Info.get(501) }
    tick(1)
    local first = batches[1] and table.concat(batches[1], ",") or "-"
    -- the server dropped that request (MIN_GAP_MS): nothing comes back; after RETRY_MS the same ids go again
    tick(Info.RETRY_MS - 10)
    local early = #batches
    tick(20)
    local again = batches[2] and table.concat(batches[2], ",") or "-"
    -- a new id within SEND_GAP_MS of the last batch waits for the gap, then goes alone
    Info.get(504)
    tick(Info.SEND_GAP_MS - 50)
    local gapped = #batches
    tick(60)
    local late = batches[3] and table.concat(batches[3], ",") or "-"
    reply({ { ok = true, id = 501, kind = "animal", animal = { name = "Hop" } }, { ok = false, id = 502, why = "FAR" },
        { ok = true, id = 503, kind = "animal", animal = { name = "Kit" } }, { ok = true, id = 504, kind = "animal",
        animal = { name = "Bun" } } })
    tick(Info.RETRY_MS + 10)
    check(#got == 0 and first == "501,502,503" and early == 1 and again == "501,502,503" and gapped == 2 and late == "504"
        and #batches == 3 and Info.get(501).ok and Info.get(502).why == "FAR",
        "同一個 tick 的三顆合成一個請求（同一顆只問一次）；伺服器丟掉時 RETRY_MS 後整批重送；間隔不到 SEND_GAP_MS 先等；回覆後不再重送")
    Info.drop(501)
    check(Info.knownName(501) == "Hop" and Info.get(501) == nil and Info.knownName(502) == nil,
        "紀錄改寫丟掉快取後，這個客戶端讀過的名字照樣記得（Info.knownName）")

    -- the release entry: never the item's own name, a plain "Release" until the summary comes, then renamed in place
    for _, n in ipairs({ "Vehicles/ISUI/ISVehicleMenu", "ISUI/Animal/ISAnimalContextMenu", "MinidoracatPackThrow/ThrowCursor",
        "TimedActions/ISPackVehicleAction", "TimedActions/ISPackAnimalAction", "TimedActions/ISReleaseSphereAction" }) do
        loaded[n] = true
    end
    ISVehicleMenu, AnimalContextMenu = { FillMenuOutsideVehicle = function() end }, { doMenu = function() end }
    loaded["MinidoracatPackThrow/Notify"] = nil
    require "MinidoracatPackThrow/Notify"
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/Menu.lua")()
    local Menu = M.Menu
    local function ball(id) return { getID = function() return id end, getName = function() return "SphereMega: doubled" end } end
    local known = Menu.releaseLabel(ball(503))
    local plain, named = Menu.releaseLabel(ball(505))
    local b505 = ball(505)
    local option = { name = plain, onSelect = Menu.onRelease, param1 = b505 }
    local widths = 0
    local menu = { calcWidth = function() return 1 end, setWidth = function() widths = widths + 1 end }
    Menu.releasePending = { id = 505, item = b505, option = option, menu = menu }
    local b506 = ball(506)
    Menu.releaseLabel(b506)
    local pooled = { name = "Other", onSelect = function() end, param1 = b506 } -- the pool gave this option to another menu
    tick(Info.SEND_GAP_MS + 10)
    reply({ { ok = true, id = 505, kind = "animal", animal = { name = "Hop2" } } })
    Menu.releasePending = { id = 506, item = b506, option = pooled, menu = menu }
    reply({ { ok = true, id = 506, kind = "animal", animal = { name = "Hop3" } } })
    check(known == "ContextMenu_MinidoracatPackThrow_Release(Kit)" and plain == "ContextMenu_MinidoracatPackThrow_ReleasePlain"
        and named == false and not known:find("doubled", 1, true) and not plain:find("doubled", 1, true)
        and option.name == "ContextMenu_MinidoracatPackThrow_Release(Hop2)" and widths == 1 and pooled.name == "Other"
        and Menu.releasePending == nil,
        "放出選單：有名字寫「放出：名字」，還沒有就只寫「放出」（從不用物品名）；紀錄到了就把開著的那一項改名、重算寬度；被別的選單拿去用的選項不動")
    -- the strings
    local missing = {}
    for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
        local f = io.open(MEDIA .. "/shared/Translate/" .. lang .. "/ContextMenu.json", "rb")
        local v = Json.decode(f:read("*a")).ContextMenu_MinidoracatPackThrow_ReleasePlain or ""
        f:close()
        if v == "" or v:find("%", 1, true) then missing[#missing + 1] = lang end
    end
    check(#missing == 0, "16 種語言都有 ReleasePlain（沒有 %）（" .. table.concat(missing, ",") .. "）")
    M.Info, Events, isClient, getText, getSpecificPlayer, sendClientCommand = saved.Info, saved.Events, saved.isClient,
        saved.getText, saved.gsp, saved.send
end
infoCases()

print("CargoLock：容器欄不列容器是空的裝車膠囊與帕魯球（貨物在貨物倉的也算空）；容器裡有貨物的膠囊、別的空袋子照列，照版面往前補位")
local function shellCases() -- 獨立函式：主程式的 local 已接近 200 個上限
    local keys = { "MinidoracatPackThrow/Info", "TimedActions/ISInventoryTransferAction", "ISUI/ISInventoryPaneContextMenu" }
    local saved = { Events = Events, xfer = ISInventoryTransferAction, menu = ISInventoryPaneContextMenu, loaded = {} }
    for _, k in ipairs(keys) do saved.loaded[k] = loaded[k]; loaded[k] = true end
    local refresh = {}
    Events = setmetatable({ OnRefreshInventoryWindowContainers = { Add = function(fn) refresh[#refresh + 1] = fn end } },
        { __index = function() return { Add = function() end } end })
    ISInventoryTransferAction = { isValid = function() return true end }
    ISInventoryPaneContextMenu = { getContainers = function(list) return list end }
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/CargoLock.lua")()
    -- the loot window's buttons in vanilla order: a capsule with its cargo in its container, one with its cargo in its
    -- store (CargoWeight off), a sphere, an empty school bag, a capsule whose car had no cargo, the floor
    local heavy, light, sphere = instanceItem(M.TYPES[1].loaded), instanceItem(M.TYPES[2].loaded), instanceItem(M.FIRST_SPHERE.loaded)
    local bag, bare, floor = newItem("Base.Bag_Schoolbag", true), instanceItem(M.TYPES[3].loaded), newContainer(nil)
    heavy.inv:AddItem(newItem("Base.WaterBottle"))
    light.store.list[1] = newItem("Base.Lighter")
    -- CleanUI's layout: a padded two-column grid (CleanUI ISInventoryPage:cleanUIGetContainerButtonPosition); vanilla's
    -- single column is the same rule with one column. Buttons move into the slots before them, not by buttonSize.
    local SIZE, PAD = 32, 3
    local function slot(i) return PAD + ((i - 1) % 2) * (SIZE + PAD), PAD + math.floor((i - 1) / 2) * (SIZE + PAD) end
    local page = { backpacks = {}, buttonPool = {}, buttonSize = SIZE, removed = {} }
    page.containerButtonPanel = { removeChild = function(_, b) page.removed[#page.removed + 1] = b.inventory end }
    for i, inv in ipairs({ heavy.inv, light.inv, sphere.inv, bag.inv, bare.inv, floor }) do
        local x, y = slot(i)
        page.backpacks[i] = { inventory = inv, x = x, y = y, getX = function(b) return b.x end,
            setX = function(b, v) b.x = v end, getY = function(b) return b.y end, setY = function(b, v) b.y = v end }
    end
    for _, fn in ipairs(refresh) do fn(page, "buttonsAdded") end
    local b, placed = page.backpacks, true
    for i, button in ipairs(page.backpacks) do
        local x, y = slot(i)
        placed = placed and button.x == x and button.y == y
    end
    check(#b == 3 and b[1].inventory == heavy.inv and b[2].inventory == bag.inv and b[3].inventory == floor and placed,
        "照列：容器裡有貨物的膠囊、別的空袋子、地板，依序補進前面的格子（兩欄網格），中間沒有空位（" .. #b .. " 個）")
    check(#page.removed == 3 and page.removed[1] == light.inv and page.removed[2] == sphere.inv
        and page.removed[3] == bare.inv and #page.buttonPool == 3,
        "不列：貨物在貨物倉的膠囊、帕魯球、車上沒有貨物的膠囊；按鈕從容器欄拿掉、放回按鈕池")
    Events, ISInventoryTransferAction, ISInventoryPaneContextMenu = saved.Events, saved.xfer, saved.menu
    for _, k in ipairs(keys) do loaded[k] = saved.loaded[k] end
end
shellCases()

print("Effects：每個落地結果用膠囊編號收掉那次飛行（收車煙霧在別格、丟出展開、落地被拒、沒中），預覽照同格、沒結果的照舊最多停 1.5 秒")
local function effectsCases() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved = { Events = Events, getCell = getCell }
    local draw
    Events = setmetatable({ OnPreUIDraw = { Add = function(fn) draw = fn end } },
        { __index = function() return { Add = function() end } end })
    getTexture = function(p) return p end
    getCell = function() return { addLamppost = function() end } end
    IsoLightSource = { new = function() return {} end }
    getSoundManager = function() return { PlayWorldSoundImpl = function() end } end
    getNumActivePlayers = function() return 0 end
    UIManager = { DrawTexture = function() end }
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/Effects.lua")()
    local E = M.Effects
    local function at(ms) nowMs = nowMs + ms; draw() end
    local function fly(id, capsuleId) E.play({ id = id, kind = "flight", x0 = 1, y0 = 1, z0 = 0, x = 5, y = 1, z = 0, capsuleId = capsuleId }) end
    -- landed miss after arrival: gone at the reply
    fly("f1", 7)
    at(600)
    local before = E.active.f1 ~= nil
    E.play({ id = "m1", kind = "miss", x = 5, y = 1, z = 0, capsuleId = 7 })
    at(1)
    local missGone = E.active.f1 == nil and E.active.m1 == nil
    -- no outcome at all (a lost message): capped at FLIGHT_MS + REST_MS
    fly("f2", 8)
    at(500 + 1500 - 10)
    local restsOn = E.active.f2 ~= nil
    at(20)
    local restEnds = E.active.f2 == nil
    -- an outcome while still in the air: it finishes flying, then goes (no jump back mid-air)
    fly("f3", 9)
    at(200)
    local age = E.endFlight(9, "miss")
    at(200)
    local stillFlying = E.active.f3 ~= nil
    at(110)
    local landedGone = E.active.f3 == nil
    -- another capsule's outcome does not touch this flight
    fly("f4", 10)
    at(700)
    local unknown = E.endFlight(11, "miss")
    at(1)
    check(before and missGone and restsOn and restEnds and age == 200 and stillFlying and landedGone and unknown == nil
        and E.active.f4 ~= nil,
        "沒中：落地後回覆一到就收掉；回覆比落地早就飛完再收；別的膠囊的結果不影響；完全沒有結果的照舊最多停 1.5 秒")
    E.active = {}
    -- a vehicle capture: the pack smoke plays on the vehicle's centre (7,3), not the aim square (5,1); same id ends it
    fly("v1", 20)
    at(600)
    E.play({ id = "p1", kind = "pack", x = 7, y = 3, z = 0, capsuleId = 20 })
    at(1)
    local vehicleGone = E.active.v1 == nil and E.active.p1 ~= nil
    -- a throw that unpacks: the unpack smoke with the thrown id ends it (on any square)
    fly("t1", 21)
    at(600)
    E.play({ id = "u1", kind = "unpack", x = 6, y = 2, z = 0, capsuleId = 21 })
    at(1)
    local unpackGone = E.active.t1 == nil
    -- a throw refused at the landing (BLOCKED, SAFEHOUSE, record refusal): "miss" with the id ends it at the reply
    fly("t2", 22)
    at(650)
    E.play({ id = "r1", kind = "miss", x = 5, y = 1, z = 0, capsuleId = 22 })
    at(1)
    local refusedGone = E.active.t2 == nil
    -- smoke with an id never pops a flight of another id lying on its square
    fly("t3", 23)
    at(600)
    E.play({ id = "u2", kind = "unpack", x = 5, y = 1, z = 0, capsuleId = 99 })
    at(1)
    local otherKept = E.active.t3 ~= nil
    E.active = {}
    -- the admin preview: no ids; its unpack on the same square pops its flight
    E.play({ id = "pf", kind = "flight", x0 = 1, y0 = 1, z0 = 0, x = 5, y = 1, z = 0 })
    at(500)
    E.play({ id = "pu", kind = "unpack", x = 5, y = 1, z = 0 })
    at(1)
    local previewGone = E.active.pf == nil and E.active.pu ~= nil
    check(vehicleGone and unpackGone and refusedGone and otherKept and previewGone,
        "收車煙霧在車心（不在落點）也用編號收掉飛行；丟出展開、落地被拒同樣馬上收；別的編號的煙霧不動這次飛行；預覽沒有編號，照同格收")
    E.active = {}
    Events, getCell = saved.Events, saved.getCell
end
effectsCases()

print("Tooltip：帕魯球（空的四級與裝了動物的）多一列「時間靜止」說明，膠囊沒有；說明在每種語言都在框內換行")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved = { Info = M.Info, typeOn = M.Rules.typeOn, tm = getTextManager, core = getCore, tip = ISToolTipInv,
        infoLoaded = loaded["MinidoracatPackThrow/Info"], tipLoaded = loaded["ISUI/ISToolTipInv"], sandbox = SandboxVars }
    local strings = {}
    local function width(s) return 7 * select(2, s:gsub("[^\128-\191]", "")) end
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return width(s) end, getFontHeight = function() return 16 end }
    end
    getCore = function() return { getScreenHeight = function() return 4000 end } end
    M.Rules.typeOn = function() return true end
    local records = {}
    M.Info = {
        T = function(k) return strings[k] or ("T:" .. k) end,
        get = function(id) return records[id] end,
        status = function() return nil end,
        rows = function(r)
            if r.kind == "vehicle" then
                return { { strings.Vehicle or "T:Vehicle", "Chevalier D6 Pickup Truck (Military Surplus Edition)" },
                    { "", "Wrench, Jack, Tire Pump, Gas Can, Duct Tape, Hammer, Screwdriver, Spare Tire, First Aid Kit" } }
            end
            return { { strings.Animal or "T:Animal", "Hop" }, { strings.AgeDays or "T:AgeDays", "12" } }
        end,
        thingName = function() return "Hop" end,
    }
    loaded["MinidoracatPackThrow/Info"], loaded["ISUI/ISToolTipInv"] = true, true
    ISToolTipInv = { render = function(self) self:drawRect(0, 0, self.width, 120, 1, 0, 0, 0) end }
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/Tooltip.lua")()
    local Tip = M.Tooltip
    Tip.install()
    local capsule, sphere
    for _, t in ipairs(M.TYPES) do
        if t.sphere then sphere = sphere or t else capsule = capsule or t end
    end
    local nextId = 700
    local function item(ft, kind)
        nextId = nextId + 1
        local id = nextId
        if kind then records[id] = { ok = true, kind = kind, state = "PACKED" } end
        return { getFullType = function() return ft end, getID = function() return id end }
    end
    local function hasNote(rows)
        for _, row in ipairs(rows or {}) do if row[2] == M.Info.T("SphereTime") then return row[1] == "" and row[3] == "muted" end end
        return false
    end
    local spheresEmpty = true
    for _, t in ipairs(M.TYPES) do
        if t.sphere and not hasNote(Tip.rows(item(t.empty))) then spheresEmpty = false end
    end
    check(spheresEmpty and hasNote(Tip.rows(item(sphere.loaded, "animal")))
        and not hasNote(Tip.rows(item(capsule.empty))) and not hasNote(Tip.rows(item(capsule.loaded, "vehicle"))),
        "四級空帕魯球與裝了動物的帕魯球都有「時間靜止」說明列（灰色說明）；空膠囊與裝了車的膠囊沒有")
    -- whether the empty one comes back: every item, both states, the right key and colour; the lost-on-a-miss line
    -- only on empty spheres with WildCaptureFailConsumes on; a live change shows on the next hover (cache keys)
    local function find(rows, key)
        for _, row in ipairs(rows or {}) do if row[2] == "T:" .. key then return row end end
        return nil
    end
    -- capsule return, sphere return, lost on a miss (the two returns are separate options since 2026-10-17)
    local function setSandbox(cap, sph, gone)
        SandboxVars = { MinidoracatPackThrow = { ReturnEmptyCapsule = cap, ReturnEmptySphere = sph,
            WildCaptureFailConsumes = gone } }
    end
    local kinds = {
        { name = "空膠囊", ft = capsule.empty, key = "Empty" },
        { name = "裝了車的膠囊", ft = capsule.loaded, kind = "vehicle", key = "Loaded" },
        { name = "空帕魯球", ft = sphere.empty, key = "EmptySphere", sphere = true },
        { name = "裝了動物的帕魯球", ft = sphere.loaded, kind = "animal", key = "LoadedSphere", sphere = true },
    }
    local wrong = {}
    for _, state in ipairs({ { true, true, false }, { false, false, true }, { true, false, true }, { false, true, false } }) do
        setSandbox(state[1], state[2], state[3])
        for _, k in ipairs(kinds) do
            local back = k.sphere and state[2] or (not k.sphere and state[1])
            local rows = Tip.rows(item(k.ft, k.kind))
            local on, off = find(rows, "ReturnOn_" .. k.key), find(rows, "ReturnOff_" .. k.key)
            local row = back and on or off
            local fail = find(rows, "FailGone")
            local wantFail = k.ft == sphere.empty and state[3]
            if not row or (back and off) or (not back and on) or row[1] ~= "" or row[3] ~= (back and "muted" or "warn")
                or (fail ~= nil) ~= wantFail or (fail and fail[3] ~= "warn") then
                wrong[#wrong + 1] = k.name .. (back and "/歸還" or "/不歸還") .. (state[3] and "/會消失" or "")
            end
        end
    end
    -- order on an empty sphere: usage, return, fail, time note
    setSandbox(false, false, true)
    local es = Tip.rows(item(sphere.empty))
    local order = {}
    for i, row in ipairs(es) do order[row[2]] = i end
    local a, b, c, d = order["T:EmptySphere"], order["T:ReturnOff_EmptySphere"], order["T:FailGone"], order["T:SphereTime"]
    local okOrder = a ~= nil and b ~= nil and c ~= nil and d ~= nil and a < b and b < c and c < d
    -- a loaded capsule: return line before the preview hint (the last row)
    local lc = Tip.rows(item(capsule.loaded, "vehicle"))
    local okLoaded = lc[#lc][2] == "T:PreviewHint" and lc[#lc - 1][2] == "T:ReturnOff_Loaded"
    -- a live change: the same item, hovered again after the admin switched it, shows the other line
    local same = item(capsule.loaded, "vehicle")
    setSandbox(true, true, false)
    local before = find(Tip.rows(same), "ReturnOn_Loaded") ~= nil
    setSandbox(false, true, false)
    local after = find(Tip.rows(same), "ReturnOff_Loaded") ~= nil
    SandboxVars = nil
    local default = find(Tip.rows(item(capsule.empty)), "ReturnOn_Empty") ~= nil and find(Tip.rows(item(sphere.empty)), "FailGone") == nil
    check(#wrong == 0 and okOrder and okLoaded and before and after and default,
        "會不會歸還：四種物品各照自己的設定（膠囊看 ReturnEmptyCapsule、帕魯球看 ReturnEmptySphere，膠囊開帕魯球關與反過來都對）寫對應的一列（開＝灰字、關＝警告色），空帕魯球在「沒抓到會消失」開著時多一列警告；"
            .. "順序是用法→歸還→會消失→時間靜止、裝了車的膠囊歸還列在預覽提示前；管理員改設定後下一次滑過就換；沒有沙盒值時照預設（歸還、不消失）（"
            .. table.concat(wrong, ",") .. "）")
    -- every language, every capsule and sphere, empty and loaded: every value wraps inside the box (framework
    -- Text.wrap), labelled rows too (the French type row made the box 805-930 px wide, user 2026-10-17); the sphere
    -- note is drawn whole
    local UI = MinidoracatUI and MinidoracatUI.v1
    if not (UI and UI.CAPABILITIES and UI.CAPABILITIES.textWrap) then
        print("  SKIP  沒有框架 Text.wrap（見上方 UI 段），跳過換行檢查")
    else
        local bad, frWidest, renders = {}, 0, 0
        for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
          for _, state in ipairs({ { true, false }, { false, true } }) do
            setSandbox(state[1], state[1], state[2])
            local fh = assert(io.open(MEDIA .. "/shared/Translate/" .. lang .. "/Tooltip.json", "rb"))
            local data = Json.decode(fh:read("*a"))
            fh:close()
            strings = {}
            for k, v in pairs(data) do strings[k:gsub("^Tooltip_MinidoracatPackThrow_", "")] = v end
            -- a fresh copy per language: the rows are built once and kept (empty capsules per type)
            ISToolTipInv = { render = function(self) self:drawRect(0, 0, self.width, 120, 1, 0, 0, 0) end }
            loadfile(MEDIA .. "/client/MinidoracatPackThrow/Tooltip.lua")()
            M.Tooltip.install()
            for _, t in ipairs(M.TYPES) do
                for _, ft in ipairs({ t.empty, t.loaded }) do
                    local loadedOne = ft == t.loaded
                    local texts, box = {}, nil
                    local cls = {
                        drawRect = function(_, x, y, w) if y > 0 then box = { x = x, w = w } end end,
                        drawRectBorder = function() end,
                        drawText = function(_, s, x) texts[#texts + 1] = { s = s, x = x } end,
                    }
                    local self = setmetatable({ width = 200, y = 0,
                        item = item(ft, loadedOne and (t.sphere and "animal" or "vehicle") or nil),
                        tooltip = { getFont = function() return "Small" end },
                        backgroundColor = { a = 0.5, r = 0, g = 0, b = 0 }, borderColor = { a = 1, r = 1, g = 1, b = 1 } },
                        { __index = cls })
                    ISToolTipInv.render(self)
                    renders = renders + 1
                    local inside = box ~= nil
                    for _, tx in ipairs(texts) do
                        if box and tx.x + width(tx.s) > box.x + box.w - 5 then inside = false end
                    end
                    if lang == "FR" and box then frWidest = math.max(frWidest, box.w) end
                    local ok = inside
                    if t.sphere then
                        -- the note is the last row: its lines are the texts at the end that are pieces of it
                        local note, lines = (strings.SphereTime or ""):gsub(" ", ""), {}
                        for k = #texts, 1, -1 do
                            local s = texts[k].s
                            if note == "" or s == "" or not note:find((s:gsub(" ", "")), 1, true) then break end
                            table.insert(lines, 1, s)
                        end
                        ok = ok and note ~= "" and table.concat(lines):gsub(" ", "") == note
                            and not (lang == "FR" and #lines < 2)
                    end
                    if not ok then bad[#bad + 1] = lang .. ":" .. ft end
                end
            end
          end
        end
        check(#bad == 0 and renders == 16 * 2 * 2 * #M.TYPES,
            "16 種語言、歸還開與關（沒抓到會消失關與開）、七種膠囊與四級帕魯球的空的與裝了的提示框：每一行（含有標籤的款式列、歸還列）都在框內，帕魯球說明整段畫出（法文至少兩行）（"
                .. table.concat(bad, ",") .. "）")
        check(frWidest > 0 and frWidest <= 400,
            "法文提示框不再被款式列撐寬：最寬 " .. frWidest .. " px（上限 400；舊版只換無標籤的列時約 750）")
    end
    M.Info, M.Rules.typeOn, getTextManager, getCore, ISToolTipInv = saved.Info, saved.typeOn, saved.tm, saved.core, saved.tip
    SandboxVars = saved.sandbox
    loaded["MinidoracatPackThrow/Info"], loaded["ISUI/ISToolTipInv"] = saved.infoLoaded, saved.tipLoaded
end)() end

print("Preview：預覽視窗的清單放不下時少列幾種貨物、最後一列「其餘 N 種」，收進的人照樣看得到；短清單不變")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    local Kit = M.UIKit
    if not (Kit and Kit.ok) then
        print("  SKIP  沒有框架（見上方 UI 段），跳過預覽視窗版面")
        return
    end
    local UI = Kit.UI
    local saved = { tm = getTextManager, core = getCore, text = getText, orNull = getTextOrNull, sm = getScriptManager,
        panel = ISPanel, scene = ISUI3DScene, win = UI.Window, button = UI.Button, fh = Kit.FH, info = M.Info,
        preview = M.Preview, infoLoaded = loaded["MinidoracatPackThrow/Info"] }
    -- EN strings (%1, %2 filled in) and an EN-like font: taller than the harness default, 7 px per character
    local en = {}
    for _, file in ipairs({ "Tooltip", "UI" }) do
        local fh = assert(io.open(MEDIA .. "/shared/Translate/EN/" .. file .. ".json", "rb"))
        for k, v in pairs(Json.decode(fh:read("*a"))) do en[k] = v end
        fh:close()
    end
    getText = function(k, a, b)
        local s = en[k] or k
        s = s:gsub("%%1", tostring(a)):gsub("%%2", tostring(b)):gsub("%%%%", "%%")
        return s
    end
    getTextOrNull = function(k) return en[k] end
    local function width(s) return 7 * select(2, tostring(s):gsub("[^\128-\191]", "")) end
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return width(s) end,
            getFontHeight = function(_, font) return font == UIFont.Medium and 23 or 19 end }
    end
    getCore = function() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
    getScriptManager = function() return { getVehicle = function() return nil end, FindItem = function() return nil end } end
    Kit.FH = 19
    ISPanel = {}
    function ISPanel:derive() local c = setmetatable({}, { __index = self }); c.__index = c; return c end
    function ISPanel:new(x, y, w, h) return setmetatable({ x = x, y = y, width = w, height = h }, self) end
    function ISPanel:initialise() end
    function ISPanel:addChild() end
    local java = { fromLua1 = function() end, fromLua2 = function() end, fromLua3 = function() end }
    ISUI3DScene = { new = function(_, x, y)
        return { javaObject = java, initialise = function() end, instantiate = function() end, setView = function() end,
            getX = function() return x end, getY = function() return y end }
    end }
    UI.Window = { new = function()
        local nop = function() end
        return { contentTop = function() return 24 end, setHeight = nop, addChild = nop, addToUIManager = nop,
            setVisible = nop, bringToTop = nop, getIsVisible = function() return true end }
    end }
    UI.Button = { new = function() return {} end }
    for _, n in ipairs({ "Vehicles/ISUI/ISUI3DScene", "ISUI/ISInventoryPaneContextMenu" }) do loaded[n] = true end
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/Info.lua")()
    local Info = M.Info
    loaded["MinidoracatPackThrow/Info"] = true
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/Preview.lua")()
    local Preview = M.Preview
    -- a pickup with twelve cargo kinds and six modifications (the Mods row wraps to two lines)
    local function record(kinds, mods)
        local d = { engine = 80, body = 64, fuel = 7.5, fuelCap = 20, battery = 37, missing = {}, mods = {}, cargo = {},
            cargoN = 0 }
        for i = 1, mods do d.mods[i] = "Heavy Duty Part " .. i end
        for i = 1, kinds do
            d.cargo[i] = { name = "Cargo Item " .. string.char(64 + i), n = 20 - i }
            d.cargoN = d.cargoN + 20 - i
        end
        return { ok = true, script = "Base.PickUpTruck", name = "Chevalier Pickup", by = "test", state = "PACKED", d = d }
    end
    local current
    Info.get = function() return current end
    local function open(r)
        current = r
        local w = Preview.open(1)
        local drawn = {}
        w.body.drawText = function(_, s, x, y) drawn[#drawn + 1] = { s = s, x = x, y = y } end
        w.body:render()
        local rowsDrawn = 0
        for _, t in ipairs(drawn) do -- values only: labels and the title sit at the list's left edge (12 + 440 + 12)
            if t.y >= 0 and t.y < w.noteY and t.x > 12 + 440 + 12 then
                rowsDrawn = rowsDrawn + 1
            end
        end
        return w, rowsDrawn
    end
    local function count(w, pattern)
        local n = 0
        for _, line in ipairs(w.lines) do if line[2]:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    local long = record(12, 6)
    local w, drawnLong = open(long)
    local fit, shownKinds = w:listRows(), count(w, "Cargo Item ")
    local packedBy = false
    for _, line in ipairs(w.lines) do if line[1] == en.Tooltip_MinidoracatPackThrow_PackedBy then packedBy = true end end
    local more = getText("Tooltip_MinidoracatPackThrow_CargoMore", tostring(12 - shownKinds))
    -- the Mods row wraps: its label line plus the label-less lines up to the next labelled row
    local modsLines, inMods = 0, false
    for _, line in ipairs(w.lines) do
        if line[1] == en.Tooltip_MinidoracatPackThrow_Mods then inMods, modsLines = true, 1
        elseif inMods and line[1] == "" then modsLines = modsLines + 1
        else inMods = false end
    end
    check(#w.lines <= fit and drawnLong == #w.lines and packedBy and shownKinds < 12 and count(w, more) == 1
        and modsLines >= 2 and w.lines[#w.lines][1] == en.Tooltip_MinidoracatPackThrow_PackedBy,
        "12 種貨物＋換兩行的改裝（EN 字高 19）：清單 " .. #w.lines .. " 行 ≤ 放得下的 " .. fit .. " 行、每行都畫出；列 "
            .. shownKinds .. " 種，其餘 " .. (12 - shownKinds) .. " 種寫在「and N more kinds」；最後一列「Packed by」")
    -- a short list is exactly the uncut one
    local short = record(2, 0)
    local ws = open(short)
    local direct = Info.rows(short, true)
    check(#ws.lines == #direct - 1 and count(ws, "more kinds") == 0 and count(ws, "Cargo Item ") == 2,
        "短清單（2 種貨物、沒有改裝）不受影響：全部列出、沒有「其餘 N 種」")
    getTextManager, getCore, getText, getTextOrNull, getScriptManager = saved.tm, saved.core, saved.text, saved.orNull, saved.sm
    ISPanel, ISUI3DScene, UI.Window, UI.Button, Kit.FH = saved.panel, saved.scene, saved.win, saved.button, saved.fh
    M.Info, M.Preview, loaded["MinidoracatPackThrow/Info"] = saved.info, saved.preview, saved.infoLoaded
end)() end

print("ThrowCursor：丟出與抓取的游標開著時，站著的角色轉向瞄準的那一格（按下時已經面向目標，不用等轉身）")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved = { core = getCore, queue = ISTimedActionQueue }
    for _, n in ipairs({ "TimedActions/ISThrowCapsuleAction", "TimedActions/ISPressCapsuleAction" }) do loaded[n] = true end
    loadfile(MEDIA .. "/client/MinidoracatPackThrow/ThrowCursor.lua")()
    local Cursor = M.ThrowCursor
    local busy = false
    ISTimedActionQueue = { isPlayerDoingAction = function() return busy end }
    local function player(o)
        o = o or {}
        local p = { faced = {} }
        function p:isPlayerMoving() return o.moving == true end
        function p:getVehicle() return o.vehicle end
        function p:isSitOnGround() return o.sitting == true end
        function p:getX() return 10.5 end
        function p:getY() return 20.5 end
        function p:faceLocation(x, y) self.faced[#self.faced + 1] = x .. "," .. y end
        return p
    end
    local function cursor(mode, p) return setmetatable({ mode = mode, character = p }, { __index = Cursor }) end
    local function turned(mode, o, x, y)
        local p = player(o)
        local r = cursor(mode, p):face(x or 15, y or 20)
        return r and table.concat(p.faced, ";") or "-"
    end
    busy = true
    local whileBusy = turned("throw")
    busy = false
    check(turned("throw") == "15,20" and turned("capture", nil, 8, 24) == "8,24" and turned("press") == "-"
        and turned("restore") == "-",
        "丟出與抓取的游標轉向瞄準的那一格（faceLocation 那一格的中心，跟丟出動作同一點）；按下按鈕與管理員補回不轉")
    check(turned("throw", { moving = true }) == "-" and turned("throw", { vehicle = {} }) == "-"
        and turned("throw", { sitting = true }) == "-" and whileBusy == "-" and turned("throw", nil, 10, 20) == "-",
        "走路中（沒在瞄準的走路沿面向走，轉身會改走向）、在車上、坐在地上、正在做別的動作、瞄準自己那一格：都不轉")
    -- the engine calls render every frame with the square under the mouse: that is where the turn happens
    getCore = function()
        local col = { getR = function() return 1 end, getG = function() return 1 end, getB = function() return 1 end }
        return { getGoodHighlitedColor = function() return col end, getBadHighlitedColor = function() return col end }
    end
    local p = player()
    local c = cursor("throw", p)
    c.getFloorCursorSprite = function() return { RenderGhostTileColor = function() end } end
    c.renderTooltip = function() end
    c:render(13, 17, 0, {})
    check(table.concat(p.faced, ";") == "13,17", "游標每一幀的 render 都轉向滑鼠下的那一格")
    getCore, ISTimedActionQueue = saved.core, saved.queue
end)() end

print("ISThrowCapsuleAction:waitToStart：只等真的要轉身的角度；腰扭得過去的小角度馬上丟（使用者 2026-10-16 還是等一兩秒）")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    local saved = { base = ISBaseTimedAction, now = nowMs }
    ISBaseTimedAction = { derive = function(self, name) return setmetatable({ Type = name }, { __index = self }) end }
    loaded["TimedActions/ISBaseTimedAction"] = true
    loadfile(MEDIA .. "/shared/TimedActions/ISThrowCapsuleAction.lua")()
    -- anim = the body's angle, dir = the facing just set; the engine twists the waist up to getMaxTwist() (15 deg)
    local function waits(anim, dir, turning, startedMsAgo)
        local p = {}
        function p:faceLocation() end
        function p:getAnimAngle() return anim end
        function p:getDirectionAngle() return dir end
        function p:getMaxTwist() return 15 end
        function p:shouldBeTurning() return turning == true end
        local a = setmetatable({ character = p, x = 15, y = 20 }, { __index = ISThrowCapsuleAction })
        if startedMsAgo then a.waitMs = nowMs - startedMsAgo end
        return a:waitToStart()
    end
    check(waits(0, 10) == false and waits(0, 16) == false and waits(175, -175) == false and waits(30, 30) == false,
        "落點偏 10 度、16 度（含跨 180 度）：腰扭得過去，身體不會轉，馬上開始丟")
    check(waits(0, 40) == true and waits(170, -150) == true and waits(0, 10, true) == true,
        "偏 40 度（引擎下一幀才開始轉）或正在轉身：等身體轉過去再丟（動作片段要等轉身，伺服器從 start 起算）")
    check(waits(0, 90, true, 1600) == false, "等超過 1.5 秒一定開始，卡住的狀態不會堵住佇列")
    ISBaseTimedAction, nowMs = saved.base, saved.now
    loaded["TimedActions/ISBaseTimedAction"] = nil
end)() end

print("Craft：配方腳本（每種一條、膠囊材料相同、帕魯球逐級升級、電瓶按件）、沙盒閘門（預設關、款式停用）、Neat Crafting 過濾、16 種語言")
do (function() -- 獨立函式：主程式的 local 已接近 200 個上限
    require "MinidoracatPackThrow/Recipes"
    local Recipes, Rules = M.Recipes, M.Rules
    local f = io.open(MEDIA .. "/../scripts/MinidoracatPackThrow_recipes.txt", "rb")
    local txt = f:read("*a"):gsub("/%*.-%*/", "")
    f:close()
    local bad, inputs, n = {}, {}, 0
    for name, body in txt:gmatch("craftRecipe%s+([%w_]+)%s*(%b{})") do
        n = n + 1
        local t = Recipes.TYPE[name]
        if not t then
            bad[#bad + 1] = name .. " no type"
        else
            local fn = "MinidoracatPackThrow_craft" .. t.id
            if not (body:find("OnTest = " .. fn .. ",", 1, true) and body:find("OnAddToMenu = " .. fn .. ",", 1, true)
                and type(_G[fn]) == "function") then bad[#bad + 1] = name .. " hooks" end
            local out = body:match("outputs%s*(%b{})") or ""
            if not out:find("item 1 " .. t.empty .. ",", 1, true) then bad[#bad + 1] = name .. " output" end
            inputs[t.id] = body:match("inputs%s*(%b{})") or ""
            for line in inputs[t.id]:gmatch("[^\n]+") do
                if line:find("carbattery", 1, true) and not (line:find("mode:destroy", 1, true)
                    and line:find("ItemCount", 1, true)) then bad[#bad + 1] = name .. " battery" end
            end
        end
    end
    local same, chain = true, true
    for _, t in ipairs(M.TYPES) do
        if not t.sphere and inputs[t.id] ~= inputs.Cartoon then same = false end
        local below = M.TYPES[t.index - 1]
        local takes = (inputs[t.id] or ""):find("[" .. (below and below.empty or "-") .. "]", 1, true) ~= nil
        if t.sphere and takes ~= (t ~= M.FIRST_SPHERE) then chain = false end
    end
    check(n == #M.TYPES and #bad == 0, "每種一條配方，OnTest 與 OnAddToMenu 都指向存在的全域函式、產出那一種空的；"
        .. "汽車電瓶 destroy 帶 ItemCount（" .. n .. " 條；" .. table.concat(bad, ",") .. "）")
    check(same and inputs.Cartoon:find("carbattery", 1, true) ~= nil, "七種膠囊的材料與工具完全相同（款式只差外觀）")
    check(chain, "帕魯球從零件做起，高級以上各用下一級的空帕魯球升級")

    local saved = SandboxVars
    local function on(id) return _G["MinidoracatPackThrow_craft" .. id]() == true end
    local function agrees()
        for _, t in ipairs(M.TYPES) do
            if on(t.id) ~= Rules.craftOn(t) or Recipes.hidden(t.recipe) == on(t.id) then return false end
        end
        return true
    end
    SandboxVars = nil
    check(not on("Cartoon") and not on("SphereBasic") and agrees(), "沙盒還沒讀到（主選單）：一律不能做")
    SandboxVars = { MinidoracatPackThrow = {} }
    check(not on("Cartoon") and not on("SphereLegend") and agrees(), "預設關：膠囊與帕魯球都不能做")
    SandboxVars = { MinidoracatPackThrow = { AllowCraftCapsules = true } }
    check(on("Cartoon") and on("Shock") and not on("SphereBasic") and agrees(), "只開膠囊：七種膠囊能做，帕魯球不能")
    SandboxVars = { MinidoracatPackThrow = { AllowCraftSpheres = true, TypeSphereGiga = false } }
    check(on("SphereBasic") and on("SphereLegend") and not on("SphereGiga") and not on("Cartoon") and agrees(),
        "只開帕魯球：停用的優質帕魯球不能做，其他等級能做，膠囊不能")
    SandboxVars = { MinidoracatPackThrow = { AllowCraftCapsules = true, AllowCraftSpheres = true, TypeSteam = false } }
    check(not on("Steam") and on("Real") and on("SphereGiga") and agrees(), "兩個都開：停用的蒸汽膠囊不能做")
    check(Recipes.hidden("CraftMinidoracatPackThrowCapsuleSteam") and not Recipes.hidden("CraftMinidoracatPackThrowCapsuleReal")
        and not Recipes.hidden("OpenCannedFood") and not Recipes.hidden(nil), "清單過濾只藏本 MOD 不能做的配方，其他配方不碰")

    local function recipe(name) return { getName = function() return name end } end
    local savedNC = NC_FilterBar
    NC_FilterBar = { shouldIncludeRecipe = function(_, r) return r:getName() ~= "OriginalNo" end }
    local first, again = Recipes.wrapNeatCrafting(), Recipes.wrapNeatCrafting()
    local F = NC_FilterBar
    check(first and not again and not F:shouldIncludeRecipe(recipe("CraftMinidoracatPackThrowCapsuleSteam"))
        and F:shouldIncludeRecipe(recipe("CraftMinidoracatPackThrowCapsuleReal")) and F:shouldIncludeRecipe(recipe("OpenCannedFood"))
        and not F:shouldIncludeRecipe(recipe("OriginalNo")),
        "Neat Crafting：包一次就好，不能做的配方不列，其他照它原本的判斷")
    NC_FilterBar = nil
    check(Recipes.wrapNeatCrafting() == false, "沒裝 Neat Crafting：什麼都不包")
    NC_FilterBar, SandboxVars = savedNC, saved

    local missing = {}
    for _, lang in ipairs({ "AR", "CH", "CN", "DE", "EN", "ES", "ES_CL", "ES_MX", "FR", "JP", "KO", "PL", "PT", "PTBR", "RU", "TR" }) do
        local dir = MEDIA .. "/shared/Translate/" .. lang .. "/"
        local function json(file)
            local h = io.open(dir .. file, "rb")
            if not h then return {} end
            local s = h:read("*a")
            h:close()
            return M.Json.decode(s) or {}
        end
        local names, sb = json("Recipes.json"), json("Sandbox.json")
        for _, t in ipairs(M.TYPES) do
            if not names[t.recipe] then missing[#missing + 1] = lang .. ":" .. t.recipe end
        end
        for _, k in ipairs({ "AllowCraftCapsules", "AllowCraftSpheres" }) do
            for _, s in ipairs({ "", "_tooltip" }) do
                if not sb["Sandbox_MinidoracatPackThrow_" .. k .. s] then missing[#missing + 1] = lang .. ":" .. k .. s end
            end
        end
    end
    check(#missing == 0, "16 種語言都有 11 條配方名與兩個製作開關（" .. table.concat(missing, ",", 1, math.min(#missing, 12)) .. "）")
end)() end

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
