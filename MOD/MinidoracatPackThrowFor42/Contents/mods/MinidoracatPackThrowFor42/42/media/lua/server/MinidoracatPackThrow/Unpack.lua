-- Pack & Throw: unpack a capsule into a vehicle (server authority). The snapshot is claimed (UNPACKED)
-- before the vehicle exists; any failure before the vehicle is in the world puts it back to PACKED.
-- Unpack.spawn is the one place that builds a vehicle from a snapshot (also used by Admin.restore).
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Store"
require "MinidoracatPackThrow/Snapshot"
require "MinidoracatPackThrow/Animal"
require "MinidoracatPackThrow/Guard"
local M = MinidoracatPackThrow
local Store, Snapshot, Guard = M.Store, M.Snapshot, M.Guard
local Unpack = {}
M.Unpack = Unpack

-- OnSpawnVehicleStart/End fire inside createPhysics, before addToWorld's trySpawnKey (BaseVehicle.java:811,904,7989-7996):
-- a restored vehicle must not drop a random key in the world.
local spawning = false
Events.OnSpawnVehicleEnd.Add(function(vehicle)
    if spawning then vehicle:setPreviouslyMoved(true) end
end)

-- Server-side lookup by id: the player's inventory (recursive), then ground items within PACK_RANGE.
function Unpack.findCapsule(player, capsuleId)
    local item = player:getInventory():getItemWithIDRecursiv(capsuleId)
    if item then return item end
    local cell, r = getCell(), M.PACK_RANGE
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -r, r do
        for dy = -r, r do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            local objs = sq and sq:getWorldObjects()
            if objs then
                for i = 0, objs:size() - 1 do
                    local it = objs:get(i):getItem()
                    if it and it:getID() == capsuleId then return it end
                end
            end
        end
    end
    return nil
end

-- Removes the capsule wherever it is and tells clients.
local function removeCapsule(player, capsule)
    local wo = capsule:getWorldItem()
    if wo and wo:getSquare() then
        wo:getSquare():transmitRemoveItemFromSquare(wo)
        capsule:setWorldItem(nil)
        return
    end
    local c = capsule:getContainer()
    if c then
        player:removeFromHands(capsule)
        c:DoRemoveItem(capsule)
        sendRemoveItemFromContainer(c, capsule)
    end
end

-- Spawns the record's vehicle (or animal, kind "animal") on square and writes the snapshot back in the same tick. With
-- `capsule` its cargo goes back into the part containers; without (admin restore) the containers stay empty.
-- opts.transmit: flag every transmit* after the restore (test knob).
-- opts.persist (default true): queue a vehicles.db UPDATE right away; addVehicleDebug INSERTed the random spawn state.
-- player: the animal's acceptance goes to them (the record has the packer's).
-- Returns vehicle (or animal), cargo { home, other, ground } or nil, why ("CORRUPT" / "SCRIPT_MISSING" / "BLOCKED").
function Unpack.spawn(snap, square, dir, opts, capsule, player)
    opts = opts or {}
    if snap.kind == "animal" then
        if not (type(snap.animal) == "table" and snap.animal.type and snap.animal.breed) then
            M.log("animal record incomplete, not spawning")
            return nil, "CORRUPT"
        end
        if not square then return nil, "BLOCKED" end
        local ok, animal, why = pcall(M.Animal.restore, snap.animal, square, player)
        if not ok then
            M.log("animal restore failed: " .. tostring(animal))
            return nil, "BLOCKED"
        end
        if not animal then return nil, why end
        return animal, { home = 0, other = 0, ground = 0 }
    end
    local bad = Snapshot.missing(snap)
    if bad then
        M.log("snapshot missing " .. bad .. ", not spawning")
        return nil, "CORRUPT"
    end
    if not getScriptManager():getVehicle(snap.script) then return nil, "SCRIPT_MISSING" end
    if not square then return nil, "BLOCKED" end
    -- SP and hosted games run damnlib's client Init inside addVehicleDebug, before the snapshot is written back: each
    -- slot empty in the fresh spawn gets a random default sent as a queued silentPartInstall command, which lands
    -- after Snapshot.restore and replaces the restored part (KI5 bull bar). Skip those defaults while we spawn; after
    -- the restore every slot holds its part or a defaultPartSet_ flag (damnlib DAMN_Parts.lua:345-408).
    local facing = IsoDirections[dir or "N"] or IsoDirections.N
    local damn = DAMN and DAMN.Parts
    local defaults = damn and damn.processDefaults
    if defaults then damn.processDefaults = function() end end -- nothing may throw before it is put back
    spawning = true
    local ok, vehicle = pcall(addVehicleDebug, snap.script, facing, nil, square)
    spawning = false
    if defaults then damn.processDefaults = defaults end
    -- An invalid spot (indoors outside a vehicle zone; Footprint.clear refuses it first, the debug commands skip that)
    -- skips addToWorld and VehiclesDB2.addVehicle yet returns the vehicle (LuaManager.java:10817-10828,
    -- IsoChunk.java:1240-1268); its sqlId stays -1, since only VehiclesDB2 numbers one (VehiclesDB2.java:301-320).
    -- getSquare() is no test: it is worked out from x, y, z (BaseVehicle.java:9769-9771). Check before exit(nil), which
    -- would number it (VehiclesDB2.java:333-336).
    if not ok or not vehicle or vehicle:getSqlId() == -1 then
        M.log(not ok and ("addVehicleDebug failed: " .. tostring(vehicle)) or ("engine did not place " .. snap.script))
        return nil, "BLOCKED"
    end
    Snapshot.restore(vehicle, snap, opts)
    local cargo = { home = 0, other = 0, ground = 0 }
    if capsule then cargo = Snapshot.restoreCargo(capsule, vehicle, snap) end
    if opts.persist ~= false then vehicle:exit(nil) end -- exit(null) only runs VehiclesDB2.updateVehicleAndTrailer (BaseVehicle.java:2543-2549)
    return vehicle, cargo
end

-- The history fields for what Unpack.spawn put in the world: where it stands and which vehicle (`car`) or animal.
function Unpack.placed(snap, thing)
    local sq = thing:getSquare()
    local e = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
    if snap.kind == "animal" then e.animal = thing:getAnimalID() else e.car = thing:getSqlId() end
    return e
end

-- Returns { ok = true, vehicleId, sqlId, returned, script, ... } (an animal: kind = "animal", animal = { type, breed,
-- name }, animalId, onlineId) or { ok = false, why }. A capsule whose record is stale (its cargo is a second copy) is
-- replaced by an empty one: why = "CLEARED"; when the world save is older than that unpack and its car is not loaded,
-- an admin checks first: why = "UNCERTAIN" (Guard.stale). An empty capsule of the same type (a sphere: of the same
-- tier) goes back to the player when Rules.returnsEmpty says so (sandbox ReturnEmptyCapsule / ReturnEmptySphere;
-- returned = true), also when that type is switched off: nothing turns into another type.
function Unpack.unpack(player, capsule, square, dir, opts)
    local capsuleId = capsule:getID()
    local snap, why, stale = Store.claim(capsuleId, player)
    if why == "STALE" then
        return { ok = false, why = Guard.stale(player, capsule, capsuleId, stale, "unpack") and "CLEARED" or "UNCERTAIN" }
    end
    if not snap then return { ok = false, why = why } end
    local thing, cargo = Unpack.spawn(snap, square, dir, opts, capsule, player)
    if not thing then
        Store.release(capsuleId, snap, player, cargo)
        return { ok = false, why = cargo }
    end
    local t = M.typeOf(capsule) or M.TYPES[1]
    removeCapsule(player, capsule)
    local inv = player:getInventory()
    local empty = M.Rules.returnsEmpty(t) and instanceItem(t.empty)
    if empty then
        inv:AddItem(empty)
        sendAddItemToContainer(inv, empty)
    end
    local e = Unpack.placed(snap, thing)
    Store.event(capsuleId, snap, "UNPACKED", player, e)
    local res = { ok = true, capsuleId = capsuleId, x = e.x, y = e.y, z = e.z, returned = empty ~= nil and empty ~= false }
    if snap.kind == "animal" then
        local a = snap.animal
        res.kind, res.animal = "animal", { type = a.type, breed = a.breed, name = a.name }
        res.animalId, res.onlineId = e.animal, thing:getOnlineID()
        return res
    end
    res.vehicleId, res.sqlId, res.keyId, res.skin = thing:getId(), e.car, thing:getKeyId(), thing:getSkinIndex()
    res.home, res.other, res.ground, res.script = cargo.home, cargo.other, cargo.ground, snap.script
    return res
end

return Unpack
