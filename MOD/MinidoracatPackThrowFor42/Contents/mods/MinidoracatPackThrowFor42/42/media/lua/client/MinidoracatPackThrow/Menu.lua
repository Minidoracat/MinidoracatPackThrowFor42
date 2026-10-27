-- Pack & Throw (client): context menu entries.
--   * "Pack into capsule" at the end of the vanilla outside-vehicle menu, and "Catch in Pal Sphere" in a live animal's
--     own submenu (the vanilla animal menu, AnimalContextMenu.doMenu): capsules take vehicles, spheres animals (user
--     2026-10-14). With two or more types (sphere tiers) it opens a submenu, one entry per type ("Steam Capsule x2");
--     with one type or none it is a single entry. Each entry has a tooltip that checks every requirement (vehicle:
--     permission, engine off and nobody inside; animal: catching animals on, its state, and a wild one's chance with
--     its bonuses; both: one of an enabled type) and says how to fix it; greyed out until all pass. Without
--     permission a vehicle entry stays clickable with a minus icon, and a click shows the reason in a toast; no red
--     text (it drops to 1.09:1 on the hover highlight, design vcap-types-1012 review). The tooltip background is
--     opaque. The server checks again in complete().
--   * A loaded capsule: "Throw capsule" when the player carries it, "Press the button" when it lies on the ground
--     (inventory/loot window and world right click). Both open the landing cursor (ThrowCursor.lua). A loaded Pal
--     Sphere the player carries: "Release: <name>" (the animal appears next to the player; no throw, no press).
--   * An empty capsule or sphere the player carries: "Throw to capture" (inventory window), the capture cursor: a
--     vehicle (capsule) or an animal (sphere) at the spot is packed into it when it lands, under the menus' rules.
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Notify"
require "MinidoracatPackThrow/ThrowCursor"
require "Vehicles/ISUI/ISVehicleMenu"
require "ISUI/Animal/ISAnimalContextMenu"
require "TimedActions/ISPackVehicleAction"
require "TimedActions/ISPackAnimalAction"
require "TimedActions/ISReleaseSphereAction"
local M = MinidoracatPackThrow
local Rules, Notify = M.Rules, M.Notify
local Menu = {}
M.Menu = Menu

local function tr(key, ...) return getText("IGUI_MinidoracatPackThrow_" .. key, ...) end

local IDLE = { OCCUPIED = true, ENGINE_RUNNING = true }

local MISS_ICON = "media/ui/Moodle_internal_minus_red.png" -- the tooltip's own mark for a failed row (Notify.row)

local function typeName(t) return M.Info.itemName(t.empty) end

-- The capsule row of a pack tooltip and whether it passes. t: the type of the entry (nil: the player carries none);
-- single: the only entry, so a passing row names the type; sphere: the animal menu's wording (Pal Spheres).
local function capsuleRow(t, single, sphere)
    local ok = t ~= nil and Rules.typeOn(t)
    local kind = sphere and "Sphere" or "Capsule"
    if not t then return false, Notify.row(false, tr("Has" .. kind .. "No")) end
    if not ok then return false, Notify.row(false, tr(sphere and "TypeOffRowSphere" or "TypeOffRow", typeName(t))) end
    return true, single and Notify.row(true, tr("Has" .. kind .. "Kind", typeName(t))) or ""
end

-- Tooltip rows for packing this vehicle with a capsule of type t (nil: the player carries none). single: the only
-- entry, so a passing capsule row names the type. Returns ok (every row passes), rich text, may (permission),
-- permission text.
function Menu.packTooltip(player, vehicle, t, single)
    local may, permText = Notify.permission(player, vehicle)
    local idle = not vehicle:isEngineRunning() and not Rules.occupied(vehicle)
    local other = Rules.vehicleWhyNot(player, vehicle)
    if IDLE[other] then other = nil end
    local text = Notify.row(may, permText) .. Notify.row(idle, tr(idle and "Idle" or "IdleNo"))
    local capsule, row = capsuleRow(t, single)
    text = text .. row
    if other then text = text .. Notify.row(false, Notify.reason(other)) end
    text = text .. " <RGB:1,1,1> <LINE> " .. tr("PackInfo", Rules.cargoCount(vehicle), Rules.PACK_SECONDS)
    return may and idle and capsule and other == nil, text, may, permText
end

-- Tooltip rows for catching this animal with a sphere of type t: catching animals switched off, the sphere, then the
-- animal's own state (held, tied, gone), and for a wild one the chance with this tier (Notify.chanceRows). Anyone may
-- catch an animal. Returns ok, rich text.
function Menu.packAnimalTooltip(player, animal, t, single)
    local why = Rules.animalWhyNot(player, animal)
    local text = why == "ANIMALS_OFF" and Notify.row(false, Notify.reason(why)) or ""
    local capsule, row = capsuleRow(t, single, true)
    text = text .. row
    if why and why ~= "ANIMALS_OFF" then text = text .. Notify.row(false, Notify.reason(why)) end
    text = text .. Notify.chanceRows(player, animal, t) .. " <RGB:1,1,1> <LINE> " .. tr("PackAnimalInfo", Rules.PACK_SECONDS)
    return why == nil and capsule, text
end

-- Clicked without permission: the reason as a toast, kept up long enough to read (review: 3 s was too short).
function Menu.onDenied(text)
    Notify.toast(Notify.reason("NOT_ALLOWED"), text, true, 8000)
end

-- Walks next to the vehicle, tells the server who asks and with which capsule type, and packs.
function Menu.onPack(player, vehicle, t)
    if player:DistToSquared(vehicle) > 9 then ISTimedActionQueue.add(ISPathFindAction:pathToVehicleAdjacent(player, vehicle)) end
    if isClient() then
        sendClientCommand(player, M.MODULE, "intent", { kind = "pack", id = vehicle:getId(), type = t.id })
    end
    local action = ISPackVehicleAction:new(player, vehicle)
    action.typeId = t.id -- SP: complete() runs on this very object
    ISTimedActionQueue.add(action)
    return action
end

-- The pack tooltip box: title, rich text, opaque.
local function tooltip(option, title, text)
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip:setName(title)
    tip.description = text
    tip.maxLineWidth = 420 -- keeps a long "how to fix" row on the line of its mark
    tip.backgroundColor.a = 1 -- opaque under the vanilla 0.7 layer; ISToolTip:reset puts it back for the pool
    option.toolTip = tip
    return option
end

local function addPackOption(menu, player, vehicle, t, label, title, single)
    local ok, text, may, permText = Menu.packTooltip(player, vehicle, t, single)
    local option
    if may then
        option = menu:addOption(label, player, Menu.onPack, vehicle, t)
        option.notAvailable = not ok
    else
        option = menu:addOption(label, permText, Menu.onDenied)
        option.iconTexture = getTexture(MISS_ICON)
    end
    return tooltip(option, title, text)
end

-- "Pack into capsule" / "Catch in Pal Sphere" in context: one entry, or a submenu with one entry per type the player
-- carries (spheres: the tiers). addOne(menu, t, label, title, single) adds an entry.
local function addEntries(context, player, addOne, spheres)
    local label = getText(spheres and "ContextMenu_MinidoracatPackThrow_PackSphere" or "ContextMenu_MinidoracatPackThrow_Pack")
    local kinds = Rules.emptyTypes(player, spheres)
    if #kinds < 2 then return addOne(context, kinds[1] and kinds[1].type, label, label, true) end
    local parent = context:addOption(label)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(parent, sub)
    for _, k in ipairs(kinds) do
        local name = typeName(k.type)
        addOne(sub, k.type, getText("ContextMenu_MinidoracatPackThrow_PackKind", name, k.n), tr("PackInto", name), false)
    end
    return parent
end

function Menu.addPack(playerNum, context, vehicle)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    return addEntries(context, player, function(menu, t, label, title, single)
        return addPackOption(menu, player, vehicle, t, label, title, single)
    end)
end

-- Walks next to the animal (vanilla AnimalContextMenu.onPickupAnimal), tells the server who asks, which animal (its
-- online id) and with which capsule type, and packs.
function Menu.onPackAnimal(player, animal, t)
    animal:stopAllMovementNow()
    if not luautils.walkAdj(player, animal:getSquare()) then return nil end
    if isClient() then
        sendClientCommand(player, M.MODULE, "intent", { kind = "packAnimal", id = animal:getOnlineID(), type = t.id })
    end
    local action = ISPackAnimalAction:new(player, animal)
    action.typeId = t.id -- SP: complete() runs on this very object
    ISTimedActionQueue.add(action)
    return action
end

-- The animal's own submenu (vanilla doMenu adds one option per animal, highlighted with onHighlightParams = { animal },
-- its submenu holding the animal actions), or nil. Newest first: pooled options can keep old fields.
local function animalMenu(context, animal)
    local opts = context.options or {}
    for i = #opts, 1, -1 do
        local opt = opts[i]
        if opt.subOption and type(opt.onHighlightParams) == "table" and opt.onHighlightParams[1] == animal then
            return context:getSubMenu(opt.subOption)
        end
    end
    return nil
end

function Menu.addPackAnimal(playerNum, context, animal)
    local player = getSpecificPlayer(playerNum)
    local menu = player and not player:getVehicle() and animalMenu(context, animal)
    if not menu then return nil end
    return addEntries(menu, player, function(sub, t, label, title, single)
        local ok, text = Menu.packAnimalTooltip(player, animal, t, single)
        local option = sub:addOption(label, player, Menu.onPackAnimal, animal, t)
        option.notAvailable = not ok
        return tooltip(option, title, text)
    end, true)
end

-- Vanilla's right-click names the first vehicle whose outline holds the mouse point, on any floor
-- (IsoObjectPicker.PickVehicle, IsoObjectPicker.java:554-566). A car landed on an upper floor can stand over another,
-- so the vehicle on the player's floor under the mouse takes its place for vanilla's rows, Pack and the menu hooks of
-- mods loaded before this one (they run inside this wrapper; one loaded after wraps it and still gets vanilla's pick).
-- 2026-10-27: packing from the 4th floor took the car below. None there: vanilla's pick stays, Pack reads TOO_FAR.
local function onPlayerFloor(playerNum, vehicle)
    local player = getSpecificPlayer(playerNum)
    local z = player and math.floor(player:getZ())
    if not z or math.floor(vehicle:getZ()) == z then return vehicle end
    local mx, my = getMouseXScaled(), getMouseYScaled()
    local wx, wy = IsoUtils.XToIso(mx, my, z), IsoUtils.YToIso(mx, my, z)
    local it = getCell():getVehicles():iterator() -- a HashSet (IsoCell.java:159,2732)
    while it:hasNext() do
        local v = it:next()
        if math.floor(v:getZ()) == z and v:isInBounds(wx, wy) then return v end
    end
    return vehicle
end

local fillOutside = ISVehicleMenu.FillMenuOutsideVehicle
function ISVehicleMenu.FillMenuOutsideVehicle(playerNum, context, vehicle, test)
    vehicle = onPlayerFloor(playerNum, vehicle)
    local r = fillOutside(playerNum, context, vehicle, test)
    if test then return r end
    Menu.addPack(playerNum, context, vehicle)
    return r
end

local doMenu = AnimalContextMenu.doMenu
function AnimalContextMenu.doMenu(player, context, animal, test)
    local r = doMenu(player, context, animal, test)
    if not test then Menu.addPackAnimal(player, context, animal) end
    return r
end

-- ------------------------------------------------------------------ capsule
function Menu.onThrow(player, item) M.ThrowCursor.open(player, item, "throw") end
function Menu.onCapture(player, item) M.ThrowCursor.open(player, item, "capture") end

-- A loaded Pal Sphere: tells the server who asks and lets the animal out next to the player (Play.release).
function Menu.onRelease(player, item)
    ISInventoryPaneContextMenu.transferIfNeeded(player, item)
    if isClient() then sendClientCommand(player, M.MODULE, "intent", { kind = "release", id = item:getID() }) end
    local action = ISReleaseSphereAction:new(player, item)
    ISTimedActionQueue.add(action)
    return action
end

-- Walk next to the capsule first, then pick the spot: the player then stands where the cursor can see them.
function Menu.onPress(player, item)
    local wo = item:getWorldItem()
    local sq = wo and wo:getSquare()
    if not (sq and luautils.walkAdj(player, sq)) then return end
    local queue = ISTimedActionQueue.getTimedActionQueue(player).queue
    local walk = queue[#queue]
    if walk and walk.Type == "ISWalkToTimedAction" then
        walk:setOnComplete(M.ThrowCursor.open, player, item, "press")
    else
        M.ThrowCursor.open(player, item, "press")
    end
end

-- "Release: <name>": the animal's name from the record (Info), or the name this client last read for it (a written
-- record drops the cached summary, e.g. 5 s after the catch when it settles); never the item's own name, which is the
-- capsule name "<tier>: <animal>" and read doubled ("Release: Mega Sphere: Hop"). Neither yet: a plain "Release",
-- renamed in place when the summary comes (Menu.releasePending, the Info listener below).
function Menu.releaseLabel(item)
    local id = item:getID()
    local r = M.Info.get(id)
    local name = type(r) == "table" and r.ok and r.kind == "animal" and M.Info.thingName(r) or M.Info.knownName(id)
    if name then return getText("ContextMenu_MinidoracatPackThrow_Release", name), true end
    return getText("ContextMenu_MinidoracatPackThrow_ReleasePlain"), false
end

-- { id, item, option, menu }: the open menu's plain "Release" entry. Menus pool their options: rename it only while
-- it is still this sphere's entry.
Menu.releasePending = nil
M.Info.listeners[#M.Info.listeners + 1] = function(id)
    local p = Menu.releasePending
    if not (p and p.id == id) then return end
    local name = M.Info.knownName(id)
    if not name then return end
    Menu.releasePending = nil
    if p.option.onSelect ~= Menu.onRelease or p.option.param1 ~= p.item then return end
    p.option.name = getText("ContextMenu_MinidoracatPackThrow_Release", name)
    if p.menu.calcWidth then p.menu:setWidth(p.menu:calcWidth()) end
end

-- A loaded Pal Sphere is only released from the inventory, never pressed on the ground nor thrown, nor in a vehicle.
local function addCapsule(context, player, item)
    local carried = not item:getWorldItem() and player:getInventory():containsRecursive(item)
    if M.typeOf(item).sphere then
        if carried and not player:getVehicle() then
            local label, named = Menu.releaseLabel(item)
            local option = context:addOption(label, player, Menu.onRelease, item)
            Menu.releasePending = not named and { id = item:getID(), item = item, option = option, menu = context } or nil
            return option
        end
        return nil
    end
    if item:getWorldItem() then
        return context:addOption(getText("ContextMenu_MinidoracatPackThrow_Press"), player, Menu.onPress, item)
    end
    if carried then
        return context:addOption(getText("ContextMenu_MinidoracatPackThrow_Throw"), player, Menu.onThrow, item)
    end
end

Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        if M.isLoaded(item) and not M.inCapsule(item) then
            addCapsule(context, player, item)
            return
        end
        if M.isEmpty(item) and not M.inCapsule(item) and not item:getWorldItem()
            and player:getInventory():containsRecursive(item) then
            context:addOption(getText("ContextMenu_MinidoracatPackThrow_Capture"), player, Menu.onCapture, item)
            return
        end
    end
end)

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local seen = {}
    for _, obj in ipairs(worldobjects) do
        local sq = obj:getSquare()
        if sq and not seen[sq] then
            seen[sq] = true
            local wos = sq:getWorldObjects()
            for i = 0, wos:size() - 1 do
                local item = wos:get(i):getItem()
                if item and M.isLoaded(item) and not M.typeOf(item).sphere then -- a sphere has no button
                    addCapsule(context, player, item)
                    return
                end
            end
        end
    end
end)

return Menu
