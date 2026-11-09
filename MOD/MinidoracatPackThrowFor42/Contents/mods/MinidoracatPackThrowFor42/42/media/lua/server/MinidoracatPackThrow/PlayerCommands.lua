-- Pack & Throw: what players do (pack, throw, press, release a Pal Sphere), server side. SP runs the same
-- functions locally.
-- MP timed actions run complete() on the server only, rebuilt from the new() arguments the client sent
-- (NetTimedAction.java:142-170). 42.21 let `character` name anyone. 42.22 takes the action's player from the sending
-- connection's local player index (Action's ConnectionPlayer) and rejects an action whose `character` is someone
-- else (NetTimedActionPacket.processServer). The intent stays the server's own check: identity comes from
-- OnClientCommand (the server maps the connection to the player), the client sends an intent when it queues the
-- action, and complete() only goes ahead when that same player sent a matching intent (same scheme as
-- VehicleManager's prepareAction). The intent also carries what the menu picked (capsule type, capture target).
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Footprint"
require "MinidoracatPackThrow/Store"
require "MinidoracatPackThrow/Pack"
require "MinidoracatPackThrow/Unpack"
require "MinidoracatPackThrow/Throw"
require "MinidoracatPackThrow/Fx"
local M = MinidoracatPackThrow
local Rules, Footprint, Store, Throw, Fx = M.Rules, M.Footprint, M.Store, M.Throw, M.Fx
local Play = { intents = {} }
M.Play = Play

local INTENT_TTL_MS = 60000 -- queue (walk there) + action time
local INTENTS_PER_PLAYER = 8
local KINDS = { pack = true, packAnimal = true, throw = true, press = true, capture = true, release = true }
local TARGETS = { animal = true, vehicle = true }

-- Server -> one client. SP has no channel (sendServerCommand is a no-op there): hand it to the client code directly.
function Play.send(player, cmd, args)
    if isServer() then
        sendServerCommand(player, M.MODULE, cmd, args)
    elseif M.onServerCommand then
        M.onServerCommand(cmd, args)
    end
end

local function now() return getTimestampMs() end

local function liveIntents(player)
    local list = Play.intents[player:getUsername()]
    if not list then return nil end
    local t = now()
    for i = #list, 1, -1 do
        if list[i].exp < t then table.remove(list, i) end
    end
    return list
end

local function findIntent(player, kind, id)
    local list = liveIntents(player)
    for i, it in ipairs(list or {}) do
        if it.kind == kind and it.id == id then return it, i, list end
    end
    return nil
end

-- The matching intent (removed), or nil. SP has one local player and no forged actions: always passes.
function Play.takeIntent(player, kind, id)
    if not isServer() then return {} end
    local it, i, list = findIntent(player, kind, id)
    if it then table.remove(list, i) end
    return it
end

function Play.hasIntent(player, kind, id)
    return not isServer() or findIntent(player, kind, id) ~= nil
end

local function refuse(player, what, why, id)
    M.log(what .. " refused by=" .. tostring(player and player:getUsername()) .. " why=" .. why .. " id=" .. tostring(id))
    return false
end

-- ---------------------------------------------------------------- client commands
local Handlers = {}

-- args: kind ("pack" / "packAnimal" / "throw" / "press" / "capture" / "release"), id (vehicle id for pack, the
-- animal's online id for packAnimal, capsule id otherwise), type (packing only: the id of the capsule type to pack
-- with, M.TYPES; Play.pack / Play.packAnimal check the player carries one and that it is enabled). capture also names
-- its target: target ("animal" / "vehicle") and tid (the animal's online id / the vehicle id); the landing finds it
-- again near the aim.
function Handlers.intent(player, args)
    local id = tonumber(args.id)
    if not (KINDS[args.kind] and id) then return end
    local cap
    if args.kind == "capture" then
        cap = { kind = args.target, tid = tonumber(args.tid) }
        if not (TARGETS[cap.kind] and cap.tid) then return end
    end
    local list = liveIntents(player) or {}
    Play.intents[player:getUsername()] = list
    if #list >= INTENTS_PER_PLAYER then table.remove(list, 1) end
    list[#list + 1] = { kind = args.kind, id = id, type = M.TYPE_BY_ID[tostring(args.type)], cap = cap,
        exp = now() + INTENT_TTL_MS }
end

-- The vehicle script (or for an animal record kind "animal" and the animal's names) of a capsule the player holds or
-- stands near: the landing cursor needs the vehicle's size, an animal takes one square.
function Play.capsuleInfo(player, capsuleId)
    local capsule = capsuleId and M.Unpack.findCapsule(player, capsuleId)
    local snap = capsule and Store.read(capsuleId)
    local a = snap and snap.kind == "animal" and type(snap.animal) == "table" and snap.animal or nil
    Play.send(player, "capsuleInfo", { capsuleId = capsuleId, ok = snap ~= nil, script = snap and snap.script,
        state = snap and snap.state, kind = snap and snap.kind,
        animal = a and { type = a.type, breed = a.breed, name = a.name } or nil })
end

function Handlers.capsuleInfo(player, args)
    Play.capsuleInfo(player, tonumber(args.capsuleId))
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= M.MODULE or not player then return end
    local fn = Handlers[command]
    if fn then fn(player, args or {}) end
end)

-- ---------------------------------------------------------------- action results (complete() on the server)
-- ISPackVehicleAction. typeId: the SP client's choice (MP takes it from the intent).
function Play.pack(player, vehicle, typeId)
    local id = vehicle and vehicle:getId()
    local intent = Play.takeIntent(player, "pack", id)
    if not intent then return refuse(player, "pack", "NO_INTENT", id) end
    local t = intent.type or M.TYPE_BY_ID[tostring(typeId)]
    local why = Rules.packWhyNot(player, vehicle, t)
    local res = why and { ok = false, why = why, vehicleId = id, type = t and t.id } -- the client words NOT_ALLOWED
        or M.Pack.pack(player, vehicle, { type = t, empty = Rules.emptyCapsule(player, t) }) -- like its menu row
    if not res.ok then refuse(player, "pack", tostring(res.why), id) end
    Play.send(player, "packed", res)
    return res.ok == true
end

-- ISPackAnimalAction. The intent names the animal by its online id (what the client sees; the server rebuilt the
-- action's animal from it). typeId: the SP client's choice (MP takes it from the intent).
function Play.packAnimal(player, animal, typeId)
    local id = animal and animal:getOnlineID()
    local intent = Play.takeIntent(player, "packAnimal", id)
    if not intent then return refuse(player, "packAnimal", "NO_INTENT", id) end
    local t = intent.type or M.TYPE_BY_ID[tostring(typeId)]
    local why = Rules.packAnimalWhyNot(player, animal, t)
    local res = why and { ok = false, why = why, kind = "animal", type = t and t.id }
        or M.Pack.packAnimal(player, animal, { capsule = Rules.emptyCapsule(player, t), typeId = t.id })
    if not res.ok then
        res.kind = "animal"
        refuse(player, "packAnimal", tostring(res.why), id)
    end
    Play.send(player, "packed", res)
    return res.ok == true
end

-- The capsule leaves the hand: every client nearby sees it fly, drawn and heard as its own type (an empty one: plain).
-- capsuleId ties the flight to its landing: a capture that misses ends it (Throw.capture, Fx "miss").
local function fly(action)
    local player, t = action.character, M.typeOf(action.item)
    action.flightAt = now()
    Fx.broadcast("flight", { x0 = player:getX(), y0 = player:getY(), z0 = player:getZ(),
        x = action.x, y = action.y, z = action.z, style = t and t.index, empty = M.isEmpty(action.item) or nil,
        capsuleId = action.item:getID() })
end

-- The target of a capture: MP from the intent (the client named it), SP from the action (Cursor.queue sets it).
local function captureOf(action, intent)
    if isServer() then return intent and intent.cap end
    return action.capture
end

-- Why this throw may not go ahead, or nil. A loaded capsule: the aim point in range and in sight, and its ground
-- outside other players' safehouses (spec C). An empty capsule (capture, spec B): the target it names on or next to
-- the aim point, and every rule packing it by menu has (Rules.captureWhyNot). Asked at the release (a refused throw
-- shows no flight) and in complete (a refused one is never scheduled: the capsule stays in the inventory).
local function throwWhyNot(action, intent)
    local player, item, x, y, z = action.character, action.item, action.x, action.y, action.z
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local why = Footprint.reach(px, py, pz, x, y, z, Rules.THROW_RANGE + 1, true)
    if why then return why end
    if M.isEmpty(item) then
        local cap = captureOf(action, intent)
        local thing = cap and Footprint.find(cap, x, y, z)
        if not thing then return "NO_TARGET" end
        return Rules.captureWhyNot(player, thing, cap.kind == "animal", M.typeOf(item))
    end
    return Throw.safehouse(player, Store.read(item:getID()), x, y, z, Footprint.dirOf(x - px, y - py))
end

local function intentKind(item) return M.isEmpty(item) and "capture" or "throw" end

-- A loaded Pal Sphere is never thrown nor pressed: its animal comes out next to the player (Play.release).
local function loadedSphere(item)
    local t = M.typeOf(item)
    return t ~= nil and t.sphere and M.isLoaded(item)
end

-- ISThrowCapsuleAction release (server / SP).
function Play.released(action)
    local item = action.item
    if not item or loadedSphere(item) then return end
    local intent = {} -- SP: no intents (Play.takeIntent)
    if isServer() then intent = findIntent(action.character, intentKind(item), item:getID()) end
    if not intent or throwWhyNot(action, intent) then return end
    fly(action)
end

-- ISThrowCapsuleAction complete: re-check the capsule, the spot (and a capture's target), then land FLIGHT_MS after the
-- release. A refusal leaves the capsule in the inventory and tells the player why.
function Play.throw(action)
    local player, item, x, y, z = action.character, action.item, action.x, action.y, action.z
    local id = item and item:getID()
    if not (item and (M.isLoaded(item) or M.isEmpty(item)) and player:getInventory():containsID(id)) then
        return refuse(player, "throw", "NO_CAPSULE", id)
    end
    local kind = intentKind(item)
    if loadedSphere(item) then
        Play.send(player, "landed", { ok = false, why = "WRONG_ITEM", capsuleId = id, mode = kind })
        return refuse(player, kind, "WRONG_ITEM", id)
    end
    local intent = Play.takeIntent(player, kind, id)
    if not intent then return refuse(player, kind, "NO_INTENT", id) end
    local why = throwWhyNot(action, intent)
    if why then
        -- the release may already have shown it flying (the target or the spot changed in between): end that flight,
        -- the capsule stayed in the inventory
        if action.flightAt then Fx.broadcast("miss", { x = x, y = y, z = z, capsuleId = id }) end
        Play.send(player, "landed", { ok = false, why = why, capsuleId = id, mode = kind })
        return refuse(player, kind, why, id)
    end
    -- No release event: the admin power "timed action instant" ends the action on its first tick, before the clip
    -- or the server's emulated events. The intent is already taken, so fly here (Play.released would refuse).
    if not action.flightAt then fly(action) end
    local px, py = player:getX(), player:getY()
    Throw.schedule({ player = player, capsuleId = id, x = x, y = y, z = z, mode = kind,
        dir = Footprint.dirOf(x - px, y - py), cap = captureOf(action, intent) }, action.flightAt + Throw.FLIGHT_MS)
    return true
end

-- ISPressCapsuleAction complete: a capsule on the ground near the player; the vehicle lands within PRESS_RANGE of it.
function Play.press(player, capsuleId, x, y, z)
    if not Play.takeIntent(player, "press", capsuleId) then return refuse(player, "press", "NO_INTENT", capsuleId) end
    local capsule = M.Unpack.findCapsule(player, capsuleId)
    local wo = capsule and capsule:getWorldItem()
    local sq = wo and wo:getSquare()
    if not (sq and M.isLoaded(capsule)) then return refuse(player, "press", "NO_CAPSULE", capsuleId) end
    if loadedSphere(capsule) then
        Play.send(player, "landed", { ok = false, why = "WRONG_ITEM", capsuleId = capsuleId, mode = "press" })
        return refuse(player, "press", "WRONG_ITEM", capsuleId)
    end
    local cx, cy = sq:getX() + 0.5, sq:getY() + 0.5
    local dir = Footprint.dirOf(x - cx, y - cy)
    local why = Footprint.reach(cx, cy, sq:getZ(), x, y, z, Rules.PRESS_RANGE + 0.5, false)
        or Throw.safehouse(player, Store.read(capsuleId), x, y, z, dir)
    if why then
        Play.send(player, "landed", { ok = false, why = why, capsuleId = capsuleId, mode = "press" })
        return refuse(player, "press", why, capsuleId)
    end
    Throw.schedule({ player = player, capsuleId = capsuleId, x = x, y = y, z = z, mode = "press", dir = dir }, now())
    return true
end

-- ISReleaseSphereAction complete: a loaded Pal Sphere in the player's inventory lets its animal out next to them
-- (Palworld v0.3.11: no throw). Rules.releaseSpot picks the square (none: NO_ROOM, the sphere stays); the landing is
-- the press path (Throw.land mode "release": record check, Unpack, ReturnEmptyCapsule gives the same tier back).
function Play.release(player, item)
    local id = item and item:getID()
    if not Play.takeIntent(player, "release", id) then return refuse(player, "release", "NO_INTENT", id) end
    local why, x, y, z
    if not (loadedSphere(item) and player:getInventory():containsID(id)) then
        why = "NO_CAPSULE"
    elseif player:getVehicle() then
        why = "IN_VEHICLE"
    else
        x, y, z = Rules.releaseSpot(player)
        if not x then why = y end
    end
    if why then
        Play.send(player, "landed", { ok = false, why = why, capsuleId = id, mode = "release", kind = "animal" })
        return refuse(player, "release", why, id)
    end
    Throw.schedule({ player = player, capsuleId = id, x = x, y = y, z = z, mode = "release",
        dir = Footprint.dirOf(x + 0.5 - player:getX(), y + 0.5 - player:getY()) }, now())
    return true
end

return Play
