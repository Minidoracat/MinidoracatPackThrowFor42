-- Pack & Throw: a thrown or pressed capsule lands, or a Pal Sphere lets its animal out (server authority; SP runs
-- the same code locally). The action's complete() schedules the landing; the capsule stays where it is (inventory or
-- ground) until then.
-- Landing: a record that is not a usable PACKED one goes straight to Unpack (it refuses, logs and clears stale cargo);
-- otherwise the ground must be clear (the vehicle's body, or one square for an animal) and outside other players'
-- safehouses, then Unpack spawns it. A blocked throw drops the capsule on the landing square (a safehouse refusal: at
-- the thrower's feet); a pressed capsule stays where it lies, a released sphere in the inventory. A thrown empty
-- capsule or sphere captures instead (Throw.capture).
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Footprint"
require "MinidoracatPackThrow/Store"
require "MinidoracatPackThrow/Unpack"
require "MinidoracatPackThrow/Pack"
require "MinidoracatPackThrow/Fx"
local M = MinidoracatPackThrow
local Rules, Footprint, Store, Unpack, Fx = M.Rules, M.Footprint, M.Store, M.Unpack, M.Fx
local Throw = { pending = {} }
M.Throw = Throw

Throw.FLIGHT_MS = 500

-- Still connected (a player who left during the flight keeps the capsule; their inventory is already saved).
local function online(player)
    if not isServer() then return true end
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        if players:get(i) == player then return true end
    end
    return false
end

-- When the record left PACKED (unpack, admin restore or verdict), for the "already unpacked" dialog.
local LEFT_PACKED = { UNPACKED = true, RESTORE_START = true, RESTORED = true, RESOLVED = true }
local function stateTime(snap)
    for i = #(snap.history or {}), 1, -1 do
        local e = snap.history[i]
        if LEFT_PACKED[e.ev] then return e.t end
    end
    return nil
end

-- Drops a carried capsule on sq; never into a safehouse the player may not touch (spec C.3): their own square then.
local function dropAt(player, capsule, sq)
    local c = capsule:getContainer()
    if not c or capsule:getWorldItem() then return false end
    if not sq or Rules.safehouseWhyNot(player, { x1 = sq:getX(), y1 = sq:getY(), x2 = sq:getX(), y2 = sq:getY() }, sq:getZ()) then
        sq = player:getCurrentSquare()
    end
    if not sq then return false end
    player:removeFromHands(capsule)
    c:DoRemoveItem(capsule)
    sendRemoveItemFromContainer(c, capsule)
    sq:AddWorldInventoryItem(capsule, 0.5, 0.5, 0)
    return true
end

-- SAFEHOUSE when the ground the record needs at (x, y, z) (the vehicle's body facing dir, the animal's square) touches
-- a safehouse this player may not, else nil. Throw and press ask before they schedule a landing (the capsule stays
-- put) and the landing asks again. No record, or no such vehicle type: nil (the landing refuses those anyway).
function Throw.safehouse(player, snap, x, y, z, dir)
    if type(snap) ~= "table" then return nil end
    local box
    if snap.kind == "animal" then
        box = select(2, Footprint.animalClear(x, y, z))
    else
        local sc = getScriptManager():getVehicle(snap.script)
        box = sc and select(2, Footprint.clear(sc, x, y, z, dir))
    end
    return box and Rules.safehouseWhyNot(player, box, z) or nil
end

-- An empty capsule thrown at an animal or a vehicle (spec B) lands: p.cap names the target (Footprint.find). It must
-- still be on or next to the aim point and pass the same rules as at the throw (Rules.captureWhyNot, safehouse
-- included); then the menu's pack path takes it with this very capsule (Pack.packAnimal / Pack.pack: the loaded
-- capsule lies where the target stood, the pack effect plays there). A miss drops the empty capsule on the landing
-- square (in someone else's safehouse: at the thrower's feet) and the toast says why.
function Throw.capture(p)
    local player = p.player
    local capsule = Unpack.findCapsule(player, p.capsuleId)
    local res
    if not (capsule and M.isEmpty(capsule) and M.carries(player, capsule)) then
        res = { ok = false, why = "NO_CAPSULE" }
    else
        local t = M.typeOf(capsule)
        local animal = p.cap.kind == "animal"
        local thing = Footprint.find(p.cap, p.x, p.y, p.z)
        local why = "NO_TARGET"
        if thing then why = Rules.captureWhyNot(player, thing, animal, t) end
        if why then
            res = { ok = false, why = why }
        elseif animal then
            res = M.Pack.packAnimal(player, thing, { capsule = capsule, typeId = t.id, range = Rules.CAPTURE_REACH })
        else
            res = M.Pack.pack(player, thing, { type = t, empty = capsule, range = Rules.CAPTURE_REACH })
        end
        -- a wild animal that broke free with WildCaptureFailConsumes on took the capsule (consumed): nothing to drop
        if not res.ok and not res.consumed then res.dropped = dropAt(player, capsule, getCell():getGridSquare(p.x, p.y, p.z)) end
        res.loadedId = res.ok and res.capsuleId or nil -- the loaded capsule now lying where the target stood
        res.kind = animal and "animal" or nil
        if thing and not animal then res.vehicleId = thing:getId() end -- a NOT_ALLOWED toast words its permission
    end
    res.capsuleId, res.mode = p.capsuleId, "capture"
    M.log(string.format("CAPTURED capsule=%d by=%s target=%s:%s x=%d y=%d z=%d ok=%s why=%s loaded=%s dropped=%s",
        p.capsuleId, player:getUsername(), tostring(p.cap.kind), tostring(p.cap.tid), p.x, p.y, p.z, tostring(res.ok),
        tostring(res.why), tostring(res.loadedId), tostring(res.dropped)))
    -- a miss: the flying capsule stops resting at once (it lies on the ground now, or is gone); after dropAt, so the
    -- ground item goes out first. A catch keeps its rest: the pack smoke at the target covers it.
    if not res.ok then Fx.broadcast("miss", { x = p.x, y = p.y, z = p.z, capsuleId = p.capsuleId }) end
    M.Play.send(player, "landed", res)
end

-- p = { player, capsuleId, x, y, z, dir, mode = "throw" | "press" | "release" | "capture", cap (capture: the target) }
function Throw.land(p)
    local player = p.player
    if not online(player) then
        M.log("land skipped capsule=" .. p.capsuleId .. ": thrower left")
        return
    end
    if p.mode == "capture" then return Throw.capture(p) end
    local res
    local capsule = Unpack.findCapsule(player, p.capsuleId)
    -- thrown and released ones must still be on the player (the bag may have left, or Guard put it back among a
    -- capsule's cargo, while it flew); only a pressed one lies on the ground
    if capsule and p.mode ~= "press" and not M.carries(player, capsule) then capsule = nil end
    local t = capsule and M.typeOf(capsule) -- read now: a good unpack removes the capsule
    local sq = getCell():getGridSquare(p.x, p.y, p.z)
    if not capsule then
        res = { ok = false, why = "NO_CAPSULE" }
    else
        local snap = Store.read(p.capsuleId)
        local usable = snap and snap.state == "PACKED" and not Store.uncertain(p.capsuleId, snap)
        local reason
        if usable then reason = Throw.safehouse(player, snap, p.x, p.y, p.z, p.dir) end
        if reason then
            res = { ok = false, why = reason }
        elseif usable and snap.kind == "animal" then
            reason = Footprint.animalClear(p.x, p.y, p.z)
        elseif usable then
            reason = Footprint.clear(getScriptManager():getVehicle(snap.script), p.x, p.y, p.z, p.dir)
        end
        if res then
            -- in someone else's safehouse: a thrown capsule falls at the thrower's feet, a pressed one stays put
            if p.mode == "throw" then res.dropped, res.feet = dropAt(player, capsule, player:getCurrentSquare()), true end
        elseif reason and reason ~= "NO_SCRIPT" then
            res = { ok = false, why = "BLOCKED", reason = reason }
        else
            res = Unpack.unpack(player, capsule, sq, p.dir, {})
            if res.why == "BLOCKED" then res.reason = "SPAWN" end
        end
        res.kind = snap and snap.kind -- the client words the dialog for a vehicle or an animal
        if not res.ok and res.why ~= "BLOCKED" then
            snap = Store.read(p.capsuleId)
            if snap then res.state, res.t = snap.state, stateTime(snap) end
        end
        if res.why == "BLOCKED" and p.mode == "throw" and sq then res.dropped = dropAt(player, capsule, sq) end
    end
    res.capsuleId, res.mode, res.type = p.capsuleId, p.mode, t and t.id
    -- every outcome of a thrown capsule ends its flight by capsuleId (client Effects.endFlight): the unpack smoke, or
    -- "miss" for a throw refused at the landing (after dropAt: the dropped capsule goes out first)
    if res.ok then
        Fx.broadcast("unpack", { x = p.x, y = p.y, z = p.z, style = t and t.index, capsuleId = p.capsuleId })
    elseif p.mode == "throw" then
        Fx.broadcast("miss", { x = p.x, y = p.y, z = p.z, capsuleId = p.capsuleId })
    end
    M.log(string.format("LANDED capsule=%d by=%s mode=%s x=%d y=%d z=%d dir=%s ok=%s why=%s reason=%s dropped=%s",
        p.capsuleId, player:getUsername(), p.mode, p.x, p.y, p.z, tostring(p.dir), tostring(res.ok),
        tostring(res.why), tostring(res.reason), tostring(res.dropped)))
    M.Play.send(player, "landed", res)
end

-- Lands p at getTimestampMs() >= at.
function Throw.schedule(p, at)
    p.at = at
    Throw.pending[#Throw.pending + 1] = p
end

Events.OnTick.Add(function()
    if #Throw.pending == 0 then return end
    local now, due = getTimestampMs(), nil
    for i = #Throw.pending, 1, -1 do
        if Throw.pending[i].at <= now then
            due = due or {}
            table.insert(due, 1, table.remove(Throw.pending, i))
        end
    end
    if not due then return end
    for _, p in ipairs(due) do
        local ok, err = pcall(Throw.land, p)
        if not ok then M.log("land failed capsule=" .. tostring(p.capsuleId) .. ": " .. tostring(err)) end
    end
end)

return Throw
