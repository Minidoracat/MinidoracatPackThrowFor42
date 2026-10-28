-- Pack & Throw: pack a parked vehicle or a live animal into a capsule (server authority, fixed order; the vehicle
-- or the animal goes last).
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Store"
require "MinidoracatPackThrow/Snapshot"
require "MinidoracatPackThrow/Animal"
require "MinidoracatPackThrow/Fx"
local M = MinidoracatPackThrow
local Store, Snapshot = M.Store, M.Snapshot
local Pack = {}
M.Pack = Pack

-- Reason code why this vehicle cannot be packed right now, or nil (player rules: Rules.packWhyNot).
Pack.whyNot = M.Rules.vehicleWhyNot

-- The player's empty capsule is used up (the record is already on disk).
local function useUp(player, item)
    local c = item and item:getContainer()
    if not c then return false end
    player:removeFromHands(item)
    c:DoRemoveItem(item)
    sendRemoveItemFromContainer(c, item)
    return true
end

local function writeLine(line)
    writeLog("PackThrow", line)
    print(line)
end

-- opts.type: the capsule type (M.TYPES row) of opts.empty, the player's empty capsule, used up once the snapshot is on
-- disk; without them (debug commands) a cartoon capsule and nothing used up. A Pal Sphere takes no vehicle
-- (WRONG_ITEM). The capsule keeps the script's name: each client names it in its own language from the record
-- (client/Info.lua), so no packing client's language sticks.
-- opts.range: tiles from the player to the vehicle (a thrown capsule: Rules.CAPTURE_REACH; default M.PACK_RANGE).
-- Returns { ok = true, capsuleId, x, y, z, ... } or { ok = false, why, path? }.
function Pack.pack(player, vehicle, opts)
    opts = opts or {}
    local t = opts.type or M.TYPES[1]
    if t.sphere then return { ok = false, why = "WRONG_ITEM" } end
    local why = Pack.whyNot(player, vehicle, opts.range)
    if why then return { ok = false, why = why } end
    local sq = vehicle:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local car = vehicle:getSqlId()

    local snap = Snapshot.capture(vehicle)
    local capsule = instanceItem(t.loaded)
    if not capsule then return { ok = false, why = "NO_ITEM" } end
    local capsuleId = capsule:getID()
    snap.state = "PACKED"
    if not M.Rules.cargoWeighs() then snap.light = true end -- cargo goes into the capsule's store (Snapshot.packCargo)
    snap.packedBy = player:getUsername()
    snap.history = { { t = getTimestampMs(), ev = "PACKED", by = snap.packedBy, x = x, y = y, z = z, car = car } }
    snap.seen = { t = snap.history[1].t, where = "ground", x = x, y = y, z = z } -- the capsule drops where the car stood
    local ok, werr, path = Store.write(capsuleId, snap)
    if not ok then
        M.log("pack refused " .. tostring(werr) .. " " .. tostring(path or ""))
        return { ok = false, why = werr, path = path }
    end
    -- From here the snapshot is on disk; move things, delete the car last. Settles once the DELETE is committed.
    Store.schedule(capsuleId)
    local empty = useUp(player, opts.empty)
    local moved = Snapshot.packCargo(vehicle, capsule, snap)
    -- a key in the ignition stays there and goes with the car (snap.ignition): Snapshot.restore puts a new one in
    sq:AddWorldInventoryItem(capsule, 0.5, 0.5, 0) -- transmits the whole item (contents included) to clients
    vehicle:permanentlyRemove()
    -- capsuleId: the empty capsule used, which a capture threw; its flight ends with this smoke (client Effects.endFlight)
    M.Fx.broadcast("pack", { x = x, y = y, z = z, style = t.index, capsuleId = opts.empty and opts.empty:getID() })
    writeLine(M.LOG_PREFIX .. "PACKED capsule=" .. capsuleId .. " state=PACKED by=" .. snap.packedBy
        .. " x=" .. x .. " y=" .. y .. " z=" .. z .. " car=" .. tostring(car) .. " script=" .. tostring(snap.script)
        .. " type=" .. t.id
        .. " cargo=" .. moved .. " light=" .. tostring(snap.light == true) .. " key=" .. tostring(snap.ignition)
        .. " empty=" .. tostring(empty)
        .. " skipped=" .. (#snap.skipped > 0 and table.concat(snap.skipped, ",") or "-"))
    return { ok = true, capsuleId = capsuleId, x = x, y = y, z = z, cargo = moved,
        skipped = table.concat(snap.skipped, ","), script = snap.script, type = t.id }
end

-- Catches a live animal in a Pal Sphere: the record is { kind = "animal", animal = Animal.capture(...) } and the loaded
-- sphere (empty inside, the animal lives only in the record) drops on the animal's square. The menu action
-- (Play.packAnimal) and a thrown empty sphere share this. opts.capsule: the player's empty sphere, already checked by
-- the caller (used up once the record is on disk; none for debug); opts.typeId: its M.TYPES id (default the basic
-- sphere; a capsule type, or a capsule as opts.capsule, is WRONG_ITEM); opts.range: as in Pack.pack.
-- A wild animal rolls once every rule has passed, at Rules.captureChance's total: a miss touches nothing (no record;
-- the empty sphere is used up only with WildCaptureFailConsumes on: consumed = true) and answers ESCAPED with that
-- chance. A caught one is tamed like vanilla
-- picking up (ISPickupAnimal.complete) when its kind can be (setWild(false) is a no-op for the others,
-- IsoAnimal.java:3214-3225). The animal is removed last, once record and
-- sphere are in place (IsoAnimal.remove deletes it and tells every client).
-- Returns the vehicle result shape: { ok = true, capsuleId, x, y, z, type, kind = "animal", animal = { type, breed,
-- name } } or { ok = false, why, path?, chance?, consumed? }.
function Pack.packAnimal(player, animal, opts)
    opts = opts or {}
    local t = M.TYPE_BY_ID[tostring(opts.typeId)] or M.FIRST_SPHERE
    local held = opts.capsule and M.typeOf(opts.capsule)
    if not t.sphere or (opts.capsule and not (held and held.sphere)) then return { ok = false, why = "WRONG_ITEM" } end
    local why = M.Rules.animalWhyNot(player, animal, opts.range)
    if why then return { ok = false, why = why } end
    local odds = M.Rules.captureChance(player, animal, t.id)
    if odds then
        local chance = odds.total
        if not M.Rules.rollWild(chance) then
            -- sandbox WildCaptureFailConsumes: the empty sphere goes like a used one (menu: the one this action
            -- used; capture: the thrown one, still in the inventory until it lands, so Throw.capture drops nothing)
            local consumed = M.Rules.wildFailConsumes() and useUp(player, opts.capsule) or nil
            writeLine(M.LOG_PREFIX .. "ESCAPED animal=" .. tostring(animal:getAnimalID()) .. " chance=" .. chance
                .. " by=" .. player:getUsername() .. (consumed and " consumed=true" or ""))
            return { ok = false, why = "ESCAPED", chance = chance, consumed = consumed }
        end
    end
    local capsule = instanceItem(t.loaded)
    if not capsule then return { ok = false, why = "NO_ITEM" } end
    local capsuleId = capsule:getID()
    local sq = animal:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    animal:setWild(false)
    local a = M.Animal.capture(animal, player)
    local by = player:getUsername()
    local now = getTimestampMs()
    local snap = { kind = "animal", animal = a, state = "PACKED", packedBy = by,
        history = { { t = now, ev = "PACKED", by = by, x = x, y = y, z = z, animal = a.animalId } },
        seen = { t = now, where = "ground", x = x, y = y, z = z } }
    local ok, werr, path = Store.write(capsuleId, snap)
    if not ok then
        M.log("pack animal refused " .. tostring(werr) .. " " .. tostring(path or ""))
        return { ok = false, why = werr, path = path }
    end
    Store.schedule(capsuleId)
    local empty = useUp(player, opts.capsule)
    sq:AddWorldInventoryItem(capsule, 0.5, 0.5, 0)
    animal:remove()
    M.Fx.broadcast("pack", { x = x, y = y, z = z, style = t.index, capsuleId = opts.capsule and opts.capsule:getID() })
    writeLine(M.LOG_PREFIX .. "PACKED capsule=" .. capsuleId .. " state=PACKED by=" .. by .. " x=" .. x .. " y=" .. y
        .. " z=" .. z .. " kind=animal animal=" .. tostring(a.animalId) .. " animalType=" .. tostring(a.type)
        .. " breed=" .. tostring(a.breed) .. " name=" .. tostring(a.name) .. " wild=" .. tostring(a.wild)
        .. " type=" .. t.id .. " empty=" .. tostring(empty))
    return { ok = true, capsuleId = capsuleId, x = x, y = y, z = z, type = t.id, kind = "animal",
        animal = { type = a.type, breed = a.breed, name = a.name } }
end

return Pack
