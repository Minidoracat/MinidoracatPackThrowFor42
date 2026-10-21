-- Pack & Throw: read a vehicle into a plain snapshot table and write it back onto a fresh vehicle.
-- Cargo is never serialized: the original item objects travel inside the capsule (same Java objects), in its container
-- or, for a light record (sandbox CargoWeight off at packing), in its cargo store (M.cargoStore).
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Json"
local M = MinidoracatPackThrow
local copy = M.Json.copy
local Snapshot = {}
M.Snapshot = Snapshot

Snapshot.VERSION = 1
Snapshot.BLOOD = { "Front", "Rear", "Left", "Right" } -- BaseVehicle.bloodIntensity ids (BaseVehicle.java:6265)

-- Same rule as ISVehicleMenu.getVehicleDisplayName (client only), falling back to the script name.
function Snapshot.displayName(vehicle)
    local sc = vehicle:getScript()
    if not sc then return vehicle:getScriptName() end
    local name = sc:getName()
    local text = getTextOrNull("IGUI_VehicleName" .. (sc:getCarModelName() or name))
    if string.find(name, "Burnt") then
        local unburnt = getTextOrNull("IGUI_VehicleName" .. string.gsub(name, "Burnt", ""))
        text = getText("IGUI_VehicleNameBurntCar", unburnt or text or name)
    end
    return text or vehicle:getScriptName()
end

-- modData as the engine would save it; values it would drop (userdata, functions, e.g. damnlib's `_vehicle`)
-- are left out and their paths appended to `skipped`.
local function modDataOf(obj, path, skipped)
    if obj:hasModData() then return M.Json.storable(obj:getModData(), path, skipped) end
    return nil
end

local function capturePart(part, skipped)
    local id = part:getId()
    local ps = { cond = part:getCondition() }
    local item = part:getInventoryItem()
    if item then
        ps.item = item:getFullType()
        ps.icond = item:getCondition()
        ps.imodData = modDataOf(item, "parts." .. id .. ".imodData", skipped)
        if item:IsDrainable() then ps.uses = item:getCurrentUsesFloat() end
    end
    ps.modData = modDataOf(part, "parts." .. id .. ".modData", skipped)
    local inv = part:getItemContainer()
    if inv then
        ps.cap = inv:getCapacity()
    elseif part:isContainer() then
        ps.amount = part:getContainerContentAmount() -- fuel, air; also kept in part modData.contentAmount
    end
    local door = part:getDoor()
    if door then ps.door = { open = door:isOpen(), locked = door:isLocked(), broken = door:isLockBroken() } end
    local win = part:getWindow()
    if win then ps.window = { open = win:isOpen() } end
    local light = part:getLight()
    if light then ps.light = light:getActive() end
    return ps
end

-- Appends the ids of item and everything inside it (bags in the cargo) to list.
local function seal(item, list)
    list[#list + 1] = item:getID()
    if instanceof(item, "InventoryContainer") then
        local items = item:getInventory():getItems()
        for i = 0, items:size() - 1 do seal(items:get(i), list) end
    end
end

-- Plain table of everything we restore. snap.skipped lists modData paths the engine would not persist either.
function Snapshot.capture(vehicle)
    local snap = {
        v = Snapshot.VERSION,
        script = vehicle:getScriptName(),
        name = Snapshot.displayName(vehicle),
        skin = vehicle:getSkinIndex(),
        hsv = { vehicle:getColorHue(), vehicle:getColorSaturation(), vehicle:getColorValue() },
        rust = vehicle:getRust(),
        blood = {},
        engine = { vehicle:getEngineQuality(), vehicle:getEngineLoudness(), vehicle:getEnginePower() },
        keyId = vehicle:getKeyId(),
        hotwired = vehicle:isHotwired(),
        alarmed = vehicle:isAlarmed(),
        headlights = vehicle:getHeadlightsOn(),
        parts = {},
        cargo = {},    -- item id -> part id it came from
        manifest = {}, -- full type -> count (top-level items only)
        sealed = {},   -- every cargo item id at any depth: what the guard keeps inside the capsule
        skipped = {},
    }
    snap.modData = modDataOf(vehicle, "modData", snap.skipped)
    for _, id in ipairs(Snapshot.BLOOD) do snap.blood[id] = vehicle:getBloodIntensity(id) end
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        snap.parts[part:getId()] = capturePart(part, snap.skipped)
        local inv = part:getItemContainer()
        if inv then
            local items = inv:getItems()
            for j = 0, items:size() - 1 do
                local item = items:get(j)
                snap.cargo[item:getID()] = part:getId()
                local ft = item:getFullType()
                snap.manifest[ft] = (snap.manifest[ft] or 0) + 1
                seal(item, snap.sealed)
            end
        end
    end
    return snap
end

local function itemsOf(inv)
    local list, items = {}, inv:getItems()
    for j = 0, items:size() - 1 do list[#list + 1] = items:get(j) end
    return list
end

-- Moves every part container's items into the capsule (original objects): its container, then its cargo store for a
-- light record (snap.light). Returns the count.
function Snapshot.packCargo(vehicle, capsule, snap)
    local box, n = capsule:getInventory(), 0
    for i = 0, vehicle:getPartCount() - 1 do
        local inv = vehicle:getPartByIndex(i):getItemContainer()
        if inv then
            for _, item in ipairs(itemsOf(inv)) do
                box:AddItem(item)
                n = n + 1
            end
        end
    end
    if snap.light then Snapshot.storeCargo(capsule) end
    return n
end

-- The capsule container's top-level items into its cargo store (a bag keeps its contents). Server side, and no packet:
-- whoever calls it sends the whole capsule afterwards (a new world item, Economy's handover) or moves the items back in
-- the same tick. An item the store refuses stays in the container. Returns how many moved.
function Snapshot.storeCargo(capsule)
    local store, box, n = M.cargoStore(capsule), capsule:getInventory(), 0
    if not store then return 0 end
    for _, item in ipairs(itemsOf(box)) do
        box:Remove(item)
        -- force, no sync: Resource.sync sends a homogeneous list (ResourceItem.saveSync throws on mixed types)
        if store:offerItem(item, true, true, false) == nil then n = n + 1 else box:AddItem(item) end
    end
    return n
end

-- The other way: the cargo store's items back into the capsule container (unpacking, Trade.escrow). Returns how many.
function Snapshot.unstoreCargo(capsule)
    local store = M.cargoStore(capsule)
    if not store or store:isEmpty() then return 0 end
    local box, list = capsule:getInventory(), store:removeAllItems(ArrayList.new())
    for i = 0, list:size() - 1 do box:AddItem(list:get(i)) end
    return list:size()
end

-- Puts the capsule's cargo (container and cargo store) back into its original part containers; unknown/missing -> first
-- container with room, then the ground under the vehicle. Returns { home = n, other = n, ground = n }.
function Snapshot.restoreCargo(capsule, vehicle, snap)
    Snapshot.unstoreCargo(capsule)
    local box = capsule:getInventory()
    local res = { home = 0, other = 0, ground = 0 }
    for _, item in ipairs(itemsOf(box)) do
        local pid = snap.cargo and snap.cargo[item:getID()]
        local part = pid and vehicle:getPartById(pid)
        local inv = part and part:getItemContainer()
        if inv then
            inv:AddItem(item)
            res.home = res.home + 1
        else
            for i = 0, vehicle:getPartCount() - 1 do
                local c = vehicle:getPartByIndex(i):getItemContainer()
                if c and c:hasRoomFor(nil, item) then inv = c; break end
            end
            if inv then
                inv:AddItem(item)
                res.other = res.other + 1
            else
                box:Remove(item)
                vehicle:getSquare():AddWorldInventoryItem(item, 0.5, 0.5, 0)
                res.ground = res.ground + 1
            end
        end
    end
    return res
end

local function replaceModData(md, src)
    local keys = {}
    for k in pairs(md) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do md[k] = nil end
    if src then
        for k, v in pairs(src) do md[k] = copy(v) end
    end
end

local function callPartLua(vehicle, part, tableName, ...)
    local t = part:getTable(tableName)
    if not (t and t.complete) then return end
    local ok, err = pcall(VehicleUtils.callLua, t.complete, vehicle, part, ...)
    if not ok then M.log("part " .. part:getId() .. " " .. tableName .. ".complete failed: " .. tostring(err)) end
end

-- Condition and modData as captured. Runs again once every part is in: an install hook may write other parts
-- (tsarslib Tuning2 guards park the condition of the parts they protect in that part's modData and set it to 100).
local function restoreState(part, ps)
    part:setCondition(ps.cond) -- also writes item condition
    local item = part:getInventoryItem()
    if item and ps.icond then item:setConditionNoSound(ps.icond) end
    replaceModData(part:getModData(), ps.modData)
end

local function restorePart(vehicle, part, ps)
    -- hooks read the original modData: tsarslib Tuning2 takes the item back out of a slot whose tuning2 names no model
    -- (ATATuning2Utils.ModelByModData), and in a fresh spawn it names none unless that slot rolled a random part
    replaceModData(part:getModData(), ps.modData)
    local cur = part:getInventoryItem()
    local item = nil
    if ps.item then
        item = cur
        if not item or item:getFullType() ~= ps.item then item = instanceItem(ps.item) end
        if item then
            item:setConditionNoSound(ps.icond or ps.cond)
            replaceModData(item:getModData(), ps.imodData)
            part:setInventoryItem(item) -- recomputes capacity from item condition, model flags
            callPartLua(vehicle, part, "install") -- KI5/damnlib switch models here
        else
            M.log("part " .. part:getId() .. ": item type missing " .. tostring(ps.item))
        end
    elseif cur then
        part:setInventoryItem(nil)
        callPartLua(vehicle, part, "uninstall", cur)
    end
    restoreState(part, ps)
    if item and ps.uses then item:setCurrentUsesFloat(ps.uses) end
    if ps.amount then
        part:setContainerContentAmount(ps.amount, true, true)
        -- Physics-only (Bullet native); a dedicated server has no Bullet and throws UnsatisfiedLinkError.
        local wi = part:getWheelIndex()
        local capacity = part:getContainerCapacity()
        if not isServer() and wi >= 0 and capacity > 0 then vehicle:setTireInflation(wi, ps.amount / capacity) end
    end
    -- door/window/light last: InstallComplete.Door unlocks the door (Vehicles.lua:960-967)
    local door = part:getDoor()
    if door and ps.door then
        door:setOpen(ps.door.open == true)
        door:setLocked(ps.door.locked == true)
        door:setLockBroken(ps.door.broken == true)
    end
    local win = part:getWindow()
    if win and ps.window then win:setOpen(ps.window.open == true) end
    local light = part:getLight()
    if light and ps.light ~= nil then light:setActive(ps.light == true) end
end

local function transmitAll(vehicle)
    vehicle:transmitEngine()
    vehicle:transmitRust() -- flag 4096 carries skin, HSV, rust, blood, hotwired, alarmed together
    vehicle:transmitColorHSV()
    vehicle:transmitSkinIndex()
    vehicle:transmitBlood()
    vehicle:transmitAlarmed()
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        vehicle:transmitPartItem(part)
        vehicle:transmitPartCondition(part)
        vehicle:transmitPartModData(part)
        vehicle:transmitPartUsedDelta(part)
        if part:getDoor() then vehicle:transmitPartDoor(part) end
        if part:getWindow() then vehicle:transmitPartWindow(part) end
        if part:getLight() then vehicle:transmitPartLight(part) end
    end
end

-- First field Snapshot.restore needs that is missing or malformed, or nil. Unpack.spawn checks it before spawning,
-- so a truncated or hand-edited record fails cleanly instead of throwing after the vehicle already exists.
function Snapshot.missing(snap)
    if type(snap.script) ~= "string" then return "script" end
    if type(snap.keyId) ~= "number" then return "keyId" end
    if type(snap.rust) ~= "number" then return "rust" end
    if type(snap.parts) ~= "table" then return "parts" end
    for _, k in ipairs({ "hsv", "engine" }) do
        local t = snap[k]
        if type(t) ~= "table" or type(t[1]) ~= "number" or type(t[2]) ~= "number" or type(t[3]) ~= "number" then
            return k
        end
    end
    return nil
end

-- Writes the snapshot onto a freshly spawned vehicle in the same tick (before its first full update).
-- Part containers are emptied (spawn loot, random glovebox key); restoreCargo refills them.
-- opts.transmit: also flag every transmit* afterwards (test knob; the first full update already carries all).
function Snapshot.restore(vehicle, snap, opts)
    vehicle:setKeyId(snap.keyId)
    if snap.skin and snap.skin >= 0 then vehicle:setSkinIndex(snap.skin) end
    vehicle:setColorHSV(snap.hsv[1], snap.hsv[2], snap.hsv[3])
    vehicle:setRust(snap.rust)
    for id, v in pairs(snap.blood or {}) do vehicle:setBloodIntensity(id, v) end
    vehicle:setEngineFeature(snap.engine[1], snap.engine[2], snap.engine[3])
    vehicle:setHotwired(snap.hotwired == true)
    vehicle:setAlarmed(snap.alarmed == true)
    -- before the parts so install.complete sees the original data, again after to undo what it wrote
    -- (damnlib migrates/saves vehicle modData from its part hooks)
    replaceModData(vehicle:getModData(), snap.modData)
    local emptySlots = {}
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        local ps = snap.parts[part:getId()]
        if ps then
            restorePart(vehicle, part, ps)
            local types = part:getItemType()
            if not ps.item and types and not types:isEmpty() then emptySlots[#emptySlots + 1] = part:getId() end
        end
        local inv = part:getItemContainer()
        if inv then inv:removeAllItems() end
    end
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        local ps = snap.parts[part:getId()]
        if ps then restoreState(part, ps) end
    end
    local md = vehicle:getModData()
    replaceModData(md, snap.modData)
    -- damnlib's client Init puts a random default into an empty slot unless defaultPartSet_<part> is set
    -- (damnlib DAMN_Parts.lua:345-408); an empty slot in the snapshot is the owner's choice, keep it empty.
    if DAMN and DAMN.Parts then
        for _, id in ipairs(emptySlots) do md["defaultPartSet_" .. id] = "true" end
    end
    vehicle:setHeadlightsOn(snap.headlights == true)
    vehicle:updatePartStats()
    vehicle:updateBulletStats()
    vehicle:doDamageOverlay()
    if opts and opts.transmit then transmitAll(vehicle) end
end

return Snapshot
