-- Pack & Throw (client): capsule summaries from the server (server/Query.lua), cached by capsule id, and the
-- wording the tooltip and the preview share. The item only carries its id; nothing here reads item modData.
-- A cached summary is dropped when the server writes that snapshot (queryChanged), so the next hover asks again.
-- Text is built in the player's language from raw data: vehicle and part names from the scripts, not the server.
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Condition"
require "ISUI/ISInventoryPane"
local M = MinidoracatPackThrow
local Info = {}
M.Info = Info

-- Requests are batched: Info.get only queues the id; once per SEND_GAP_MS the queue goes out as one "query" with up to
-- MAX_IDS ids. The server answers one request per player per 100 ms (server/Query.lua MIN_GAP_MS, MAX_IDS 20) and drops
-- the rest, so one id per call (several capsules listed in the same tick) used to lose all but the first. An id
-- still unanswered after RETRY_MS is queued again by the tick, whoever asked.
Info.RETRY_MS = 1000
Info.SEND_GAP_MS = 250
Info.MAX_IDS = 20
Info.CARGO_LINES = 4 -- cargo kinds listed before "N more"
Info.MODS_TIP = 3   -- modification parts named in the tooltip before "N more"
Info.MODS_FULL = 6  -- ... and in the preview list

local cache = {}     -- capsuleId -> reply ({ ok = true, ... } or { ok = false, why })
local asked = {}     -- capsuleId -> ms of the pending request (queued or sent, unanswered)
local queue, queued = {}, {} -- ids for the next batch, in order; id -> true while in it
local lastSend = nil
local waiting = {}   -- capsuleId -> true: shown in a window before its summary came (named when it comes)
local names = {}     -- capsuleId -> what it holds, in words, from the last good reply: kept when the cache is dropped
Info.listeners = {}  -- fn(capsuleId) when a summary arrives or is dropped (the preview window, the release menu)

local function T(key, a, b, c)
    local k = "Tooltip_MinidoracatPackThrow_" .. key
    if a == nil then return getText(k) end
    if b == nil then return getText(k, a) end
    if c == nil then return getText(k, a, b) end
    return getText(k, a, b, c)
end
Info.T = T

local function notify(id)
    for _, fn in ipairs(Info.listeners) do fn(id) end
end

local function store(reply)
    local id = tonumber(reply.id)
    if not id then return end
    cache[id], asked[id] = reply, nil
    if reply.ok and (reply.script or reply.kind == "animal") then names[id] = Info.thingName(reply) end
    notify(id)
    if waiting[id] then
        waiting[id] = nil
        ISInventoryPage.renderDirty = true -- the windows refresh once; the hook below names the capsule
    end
end

-- Forgets a summary (the server wrote that snapshot). Also called directly in SP (server/Query.lua listener). The
-- name it held stays known: what a packed capsule holds never changes.
function Info.drop(id)
    id = tonumber(id)
    if not id then return end
    cache[id], asked[id] = nil, nil
    notify(id)
end
M.QueryChanged = Info.drop

-- The vehicle's or animal's name this client last read for the capsule, or nil.
function Info.knownName(id)
    return names[tonumber(id)]
end

local function enqueue(id)
    if queued[id] then return end
    queued[id] = true
    queue[#queue + 1] = id
end

-- Sends the queue as one request (MP), at most every SEND_GAP_MS; ids answered meanwhile are skipped.
function Info.flush(now)
    if #queue == 0 or (lastSend and now >= lastSend and now - lastSend < Info.SEND_GAP_MS) then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local ids = {}
    while #ids < Info.MAX_IDS and #queue > 0 do
        local id = table.remove(queue, 1)
        queued[id] = nil
        if not cache[id] then
            ids[#ids + 1] = id
            asked[id] = now
        end
    end
    if #ids == 0 then return end
    lastSend = now
    sendClientCommand(player, M.MODULE, "query", { ids = ids })
end

-- Ids whose request went unanswered (dropped by the server, or lost) go back in the queue.
function Info.retry(now)
    for id, at in pairs(asked) do
        if not queued[id] and (now < at or now - at > Info.RETRY_MS) then enqueue(id) end
    end
end

-- The cached reply, or nil while it is being fetched (MP: queued for the next batch). In SP the answer is computed in
-- place, so it is returned right away.
function Info.get(id)
    local r = cache[id]
    if r then return r end
    if not isClient() then
        local player = getSpecificPlayer(0)
        if player and M.Query then -- SP: the server code is loaded in the same Lua state
            for _, x in ipairs(M.Query.query(player, { id }).items) do store(x) end
        end
        return cache[id]
    end
    if not asked[id] then
        asked[id] = getTimestampMs()
        enqueue(id)
    end
    return nil
end

Events.OnTickEvenPaused.Add(function()
    if not isClient() then return end
    local now = getTimestampMs()
    Info.retry(now)
    Info.flush(now)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M.MODULE or type(args) ~= "table" then return end
    if command == "query" and type(args.items) == "table" then
        for _, r in ipairs(args.items) do
            if type(r) == "table" then store(r) end
        end
    elseif command == "queryChanged" then
        Info.drop(args.id)
    end
end)

-- ---------------------------------------------------------------- wording

-- Same key rule as ISVehicleMenu.getVehicleDisplayName, in this player's language; the snapshot name (server
-- language) only when the vehicle script is gone.
function Info.carName(script, fallback)
    local sc = script and getScriptManager():getVehicle(script)
    if sc then
        local text = getTextOrNull("IGUI_VehicleName" .. (sc:getCarModelName() or sc:getName()))
        if text then return text end
    end
    return fallback or script or "?"
end

function Info.partName(id)
    return getTextOrNull("IGUI_VehiclePart" .. tostring(id)) or tostring(id)
end

function Info.itemName(fullType)
    local item = fullType and getScriptManager():FindItem(fullType)
    return item and item:getDisplayName() or tostring(fullType)
end

-- "10/09 18:40" in local time.
local sdf
function Info.date(ms)
    if type(ms) ~= "number" then return "-" end
    local ok, s = pcall(function()
        sdf = sdf or SimpleDateFormat.new("MM/dd HH:mm", Locale.ENGLISH)
        local cal = Calendar.getInstance()
        cal:setTimeInMillis(ms)
        return sdf:format(cal:getTime())
    end)
    return ok and tostring(s) or "-"
end

local function num1(v)
    local s = string.format("%.1f", v)
    return (string.gsub(s, "%.0$", ""))
end

-- An animal's breed and type the vanilla way (IsoAnimal.getFullName, IsoAnimal.java:2274-2290), in this player's
-- language. a = { type, breed, name } from a record (server Animal.view).
function Info.animalKind(a)
    if type(a) ~= "table" then return "?" end
    local kind = getTextOrNull("IGUI_AnimalType_" .. tostring(a.type)) or tostring(a.type)
    local breed = a.breed and getTextOrNull("IGUI_Breed_" .. tostring(a.breed))
    return breed and getText("IGUI_AnimalFullName", breed, kind) or kind
end

-- The animal's own name, or its breed and type (vanilla AnimalInventoryItem.initAnimalData).
function Info.animalName(a)
    if type(a) == "table" and type(a.name) == "string" and a.name ~= "" then return a.name end
    return Info.animalKind(a)
end

-- What a capsule holds, in words: the animal's name or the vehicle's. r: a summary, a detail or a capsuleInfo reply.
function Info.thingName(r)
    if r.kind == "animal" then return Info.animalName(r.animal) end
    return Info.carName(r.script, r.name)
end

-- Vanilla bands for wool (ISAnimalUI:getWoolText).
local function woolText(q)
    if q < 1 then return getText("IGUI_Animal_Wool_None") end
    if q < 5 then return getText("IGUI_Animal_Wool_Handful") end
    if q < 8 then return getText("IGUI_Animal_Wool_Little") end
    if q < 15 then return getText("IGUI_Animal_Wool_Moderate") end
    return getText("IGUI_Animal_Wool_Abundant")
end

-- { { label, value }, ... } describing a recorded animal, labels in vanilla's animal wording where it has one
-- (ISAnimalUI). Pregnancy and fertilization only come when the server sent them (Husbandry above 2).
function Info.animalRows(a)
    local rows = {}
    local function add(label, value) rows[#rows + 1] = { label, value } end
    if type(a) ~= "table" then return rows end
    add(T("Animal"), Info.animalKind(a))
    add(getText("UI_characreation_gender"), getText(a.female and "IGUI_Animal_Female" or "IGUI_Animal_Male"))
    if type(a.age) == "number" then add(getText("IGUI_char_Age"), T("AgeDays", tostring(a.age))) end
    local w = tonumber(a.weight)
    if w then
        add(T("Weight"), w > 1 and getText("IGUI_AnimalWeight", num1(w)) or getText("IGUI_AnimalWeightG", num1(w * 1000)))
    end
    local hp = tonumber(a.health)
    if hp then add(getText("IGUI_XP_Health"), T("Percent", tostring(math.floor(hp * 100 + 0.5)))) end
    if tonumber(a.milkMax) then add(T("Milk"), T("FuelOf", num1(tonumber(a.milk) or 0), num1(a.milkMax))) end
    if (tonumber(a.wool) or 0) > 0 then add(getText("IGUI_Animal_Wool"), woolText(a.wool)) end
    -- own "yes" and wild label: vanilla KO IGUI_Yes and IGUI_Animal_Wild are empty (KO showed the English fallback)
    if a.pregnant then add(getText("IGUI_Animal_Pregnant"), T("Yes")) end
    if a.fert then add(getText("IGUI_Animal_Fertilized"), T("Yes")) end
    if a.wild then add(T("Wild"), T("Yes")) end
    return rows
end

-- Insertion sort for short lists (cargo kinds, part names); the family gate bans the built-in sort.
local function isort(a, less)
    for i = 2, #a do
        local v, j = a[i], i - 1
        while j >= 1 and less(v, a[j]) do a[j + 1] = a[j]; j = j - 1 end
        a[j + 1] = v
    end
    return a
end
Info.isort = isort

-- Numbers and names for one summary, computed once per reply.
function Info.details(r)
    if r.d then return r.d end
    local c = M.Condition.of(r.parts)
    local d = { engine = c.engine, body = c.body, battery = c.battery, fuel = c.fuel, fuelCap = c.fuelCap,
        missing = {}, mods = {}, cargo = {}, cargoN = 0 }
    for i, id in ipairs(c.missing) do d.missing[i] = Info.partName(id) end
    for i, fullType in ipairs(c.mods) do d.mods[i] = Info.itemName(fullType) end
    local byName = function(a, b) return a < b end
    isort(d.missing, byName)
    isort(d.mods, byName)
    -- Parts can share one item (KI5 left and right window armor): list each name once, with " x2" for repeats.
    local merged = {}
    for _, name in ipairs(d.mods) do
        local last = merged[#merged]
        if last and last.name == name then last.n = last.n + 1 else merged[#merged + 1] = { name = name, n = 1 } end
    end
    d.mods = {}
    for i, m in ipairs(merged) do d.mods[i] = m.n > 1 and (m.name .. " x" .. m.n) or m.name end
    for _, e in ipairs(r.manifest or {}) do
        d.cargo[#d.cargo + 1] = { name = Info.itemName(e.ft), n = tonumber(e.n) or 0 }
        d.cargoN = d.cargoN + (tonumber(e.n) or 0)
    end
    isort(d.cargo, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    r.d = d
    return d
end

-- Lists in the tooltip: the separator is a translation key ("、" in Chinese), since Lua source stays ASCII.
local listSep
local function joinNames(list)
    listSep = listSep or T("ListSep")
    return table.concat(list, listSep)
end

-- Status text for a capsule that cannot be unpacked (or nil): unpacked, restored, void, crash-uncertain.
function Info.status(r)
    if r.state == "UNPACKED" then return T("Unpacked", Info.date(r.last and r.last.t)) end
    if r.state == "RESTORED" then return T("Restored") end
    if r.state == "VOID" then return T("Void") end
    if r.uncertain then return T("Uncertain") end
    return nil
end

-- { { label, value, token? }, ... } describing the vehicle (PACKED and uncertain ones): what the tooltip and the
-- preview list. `full` adds paint and the whole cargo list (preview), or at most `cargoCap` cargo kinds when given
-- (the preview window has a fixed height; the "N more" line counts the rest). An animal record lists the animal.
function Info.rows(r, full, cargoCap)
    if r.kind == "animal" then
        local rows = Info.animalRows(r.animal)
        if r.by then rows[#rows + 1] = { T("PackedBy"), tostring(r.by) } end
        return rows
    end
    local d = Info.details(r)
    local rows = {}
    local function add(label, value, token) rows[#rows + 1] = { T(label), value, token } end
    add("Vehicle", Info.carName(r.script, r.name))
    if full then
        local sc = r.script and getScriptManager():getVehicle(r.script)
        local n = sc and sc:getSkinCount() or 0
        if n > 0 and type(r.skin) == "number" then add("Paint", T("PaintOf", tostring(r.skin + 1), tostring(n))) end
    end
    if d.engine or d.body then
        add("Condition", T("EngineBody", d.engine and tostring(d.engine) or "-", d.body and tostring(d.body) or "-"))
    end
    if d.fuel then
        add("Fuel", d.fuelCap and T("FuelOf", num1(d.fuel), tostring(d.fuelCap)) or T("FuelL", num1(d.fuel)))
    end
    if d.battery then add("Battery", T("Percent", tostring(d.battery))) end
    if #d.missing > 0 then add("Missing", joinNames(d.missing)) end
    if #d.mods > 0 then
        -- KI5 trucks carry a dozen or more extra parts: list a few, count the rest (cargo must stay visible)
        local cap = full and Info.MODS_FULL or Info.MODS_TIP
        if #d.mods <= cap then
            add("Mods", joinNames(d.mods))
        else
            local some = {}
            for i = 1, cap do some[i] = d.mods[i] end
            add("Mods", joinNames(some) .. (listSep or T("ListSep")) .. T("CargoMore", tostring(#d.mods - cap)))
        end
    end
    if d.cargoN == 0 then
        add("Cargo", T("CargoNone"))
    else
        add("Cargo", T("CargoCount", tostring(d.cargoN)))
        local shown = full and math.min(#d.cargo, cargoCap or #d.cargo) or math.min(#d.cargo, Info.CARGO_LINES)
        for i = 1, shown do
            local e = d.cargo[i]
            rows[#rows + 1] = { "", T("CargoLine", e.name, tostring(e.n)) }
        end
        if shown < #d.cargo then rows[#rows + 1] = { "", T("CargoMore", tostring(#d.cargo - shown)) } end
    end
    if r.by then add("PackedBy", tostring(r.by)) end
    return rows
end

-- Lines Minidoracat Economy shows under a listed or auctioned capsule (server Trade.view): the vehicle in this
-- player's language and the numbers the tooltip shows; for an animal the capsule type, its name and the animal rows.
function Info.viewLines(v)
    local out = {}
    if type(v) ~= "table" then return out end
    local function add(label, value) out[#out + 1] = T("Row", T(label), value) end
    if v.kind == "animal" then
        local t = M.TYPE_BY_ID[tostring(v.style)]
        if t then add("Type", Info.itemName(t.empty)) end
        add("Name", Info.animalName(v.animal))
        for _, row in ipairs(Info.animalRows(v.animal)) do out[#out + 1] = T("Row", row[1], row[2]) end
        return out
    end
    add("Vehicle", Info.carName(v.script, v.name))
    if v.engine or v.body then
        add("Condition", T("EngineBody", v.engine and tostring(v.engine) or "-", v.body and tostring(v.body) or "-"))
    end
    if v.fuel then
        add("Fuel", v.fuelCap and T("FuelOf", num1(v.fuel), tostring(v.fuelCap)) or T("FuelL", num1(v.fuel)))
    end
    if v.battery then add("Battery", T("Percent", tostring(v.battery))) end
    add("Missing", T("MissingCount", tostring(tonumber(v.missing) or 0)))
    local n = tonumber(v.cargo) or 0
    add("Cargo", n > 0 and T("CargoCount", tostring(n)) or T("CargoNone"))
    return out
end

-- Why Economy will not take this capsule now (server Trade.check detail). A cargo item's reason is Economy's own
-- wording for that rule.
function Info.refusalText(d)
    local code = type(d) == "table" and tostring(d.code) or "OTHER"
    if code == "CARGO" then
        local why = tostring(d.why)
        local reason = getTextOrNull("IGUI_MinidoracatEconomy_Market_Reason_" .. why)
            or getTextOrNull("IGUI_MinidoracatEconomy_Market_Reason_not_whitelisted_" .. why) or why
        return getText("IGUI_MinidoracatPackThrow_Trade_CARGO", Info.itemName(d.type), reason)
    end
    if code == "TOO_MANY" then
        return getText("IGUI_MinidoracatPackThrow_Trade_TOO_MANY", tostring(d.n), tostring(d.max))
    end
    return getTextOrNull("IGUI_MinidoracatPackThrow_Trade_" .. code) or getText("IGUI_MinidoracatPackThrow_Trade_OTHER")
end

-- Minidoracat Economy's client facade (MinidoracatEconomy.v1.Client, rev 5 uniqueItemViews) is complete once every
-- client file has loaded. Older Economy keeps loaded capsules off its market: nothing to register.
Events.OnGameStart.Add(function()
    local api = MinidoracatEconomy and MinidoracatEconomy.v1 and MinidoracatEconomy.v1.Client
    local caps = api and api.CAPABILITIES
    if not (type(caps) == "table" and caps.uniqueItemViews == true and type(api.registerItemView) == "function"
        and type(api.registerRefusalText) == "function") then return end
    for _, t in ipairs(M.TYPES) do
        api.registerItemView(t.loaded, function(view) return Info.viewLines(view) end)
        api.registerRefusalText(t.loaded, function(detail) return Info.refusalText(detail) end)
    end
end)

-- A loaded capsule's name in this player's language, "<type>: <vehicle or animal>" (IG_UI LoadedName), from its
-- record; nil while there is none. The server leaves the script's name on the item (Pack.lua), so no packing client's
-- language sticks to it; each client renames its own copy.
function Info.capsuleName(item, r)
    local t = M.typeOf(item)
    if not (t and type(r) == "table" and r.ok and (r.script or r.kind == "animal")) then return nil end
    return getText("IGUI_MinidoracatPackThrow_LoadedName", Info.itemName(t.empty), Info.thingName(r))
end

local function rename(item)
    local id = item:getID()
    local r = Info.get(id)
    if r == nil then
        waiting[id] = true
        return
    end
    local name = Info.capsuleName(item, r)
    if name and item:getName() ~= name then item:setName(name) end
end

-- Capsules shown in the inventory and loot windows (a capsule's own container, or a capsule lying in a shown
-- container): their summaries are asked for now and they get their names. The server counts a capsule asked about
-- from nearby as a sighting (admin panel: last seen), and with cargo take-out on the first take is not refused while
-- the answer is on its way. The pane hook below covers what reaches a window without this full refresh.
-- Loaded capsules and spheres are containers, so the engine picks the containers out (getItemsFromCategory): Lua
-- does not walk the cargo of every capsule shown, which cost ~33 ms a refresh for 10 x 5000 items (vcap-lag-*-1022d).
local function renameIn(inv)
    local items = inv and inv:getItemsFromCategory("Container")
    for i = 0, (items and items:size() or 0) - 1 do
        local it = items:get(i)
        if M.isLoaded(it) then rename(it) end
    end
end

Events.OnRefreshInventoryWindowContainers.Add(function(page, state)
    if state ~= "end" then return end
    for _, button in ipairs(page.backpacks or {}) do
        local inv = button.inventory
        local holder = inv and inv:getContainingItem()
        if holder and M.isLoaded(holder) then rename(holder) end
        renameIn(inv)
    end
end)

-- A capsule that reaches a shown container without a window refresh only marks the pane dirty: a copy the server
-- sends (an admin's give, an Economy purchase, a transfer it finishes) or one put in by code. Named before the pane
-- lists it (ISInventoryPane:renderdetails refreshes a dirty container while the window is open).
local refreshContainer = ISInventoryPane.refreshContainer
function ISInventoryPane:refreshContainer()
    renameIn(self.inventory)
    return refreshContainer(self)
end

return Info
