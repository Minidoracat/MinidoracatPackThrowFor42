-- Pack & Throw: player rules shared by the client menus (what the tooltip rows show) and the server actions
-- (what complete() enforces). The client copy only decides the menu; the server checks again before anything moves.
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Footprint"
local M = MinidoracatPackThrow
local Rules = {}
M.Rules = Rules

Rules.PACK_SECONDS = 10
Rules.THROW_RANGE = 8 -- tiles from the thrower to the landing point
Rules.PRESS_RANGE = 3 -- tiles from a capsule on the ground to the landing point
-- tiles from a capture's thrower to its target: the aim point is within THROW_RANGE (Footprint.reach), the target on or
-- next to it, and a vehicle's centre up to half a body further
Rules.CAPTURE_REACH = Rules.THROW_RANGE + 4

function Rules.sandbox()
    return SandboxVars and SandboxVars.MinidoracatPackThrow or {}
end

-- Whether unpacking (a capsule) or releasing (a Pal Sphere) gives an empty one of the same type or tier back: sandbox
-- ReturnEmptyCapsule for capsules, ReturnEmptySphere for spheres, both default on (split by the user 2026-10-17; the
-- capsule key kept its name so servers keep their setting). The server's Unpack and the client's tooltip ask here.
function Rules.returnsEmpty(t)
    local s = Rules.sandbox()
    if t and t.sphere then return s.ReturnEmptySphere ~= false end
    return s.ReturnEmptyCapsule ~= false
end

-- Sandbox AllowCargoTakeOut: cargo may leave a loaded capsule whose record is a confirmed PACKED one (settled, so
-- never one still settling, left uncertain by a crash, unpacked or void). rec: a snapshot, a Store.status entry or
-- a Query reply. Nothing can be put into a capsule either way (MaxItemSize in the item script).
function Rules.cargoOpen(rec)
    return Rules.sandbox().AllowCargoTakeOut == true and rec ~= nil and rec.state == "PACKED" and rec.settled == true
end

-- Sandbox CargoWeight (default on; user 2026-10-21): a packed vehicle's cargo goes into the capsule's container and
-- weighs with it. Off: into its cargo store (M.cargoStore), so the capsule weighs only itself and nothing can be taken
-- out before unpacking. Read when packing (Pack.pack writes snap.light); capsules packed earlier keep theirs.
function Rules.cargoWeighs()
    return Rules.sandbox().CargoWeight ~= false
end

-- Admin on either side: the server asks the connection (M.isAdmin, SP host = admin); an MP client reads its own role.
function Rules.isAdmin(player)
    if not isClient() then return M.isAdmin(player) end
    local role = player and player:getRole()
    return role ~= nil and Capability ~= nil and role:hasCapability(Capability.ManipulateVehicle) == true
end

-- SAFEHOUSE when a square of box (floor z) lies in a safehouse this player may not touch, else nil: the vanilla rule
-- SafeHouse.isSafehouseAllowInteract (no safehouse there, the owner or a member, Capability.CanGoInsideSafehouses, or
-- at war: SafeHouse.java:245-260; works on both sides, SP has no safehouses). With `vehicle` only the squares under
-- its body count (getVehicleContainer, Footprint.bodyBox). Packing (menu or capture) asks for the vehicle's body or
-- the animal's square; releasing (throw, press, admin restore) for the landing ground (Footprint.clear's box).
function Rules.safehouseWhyNot(player, box, z, vehicle)
    local list = SafeHouse and SafeHouse.getSafehouseList()
    if not (list and list:size() > 0) then return nil end
    for _, sq in ipairs(M.Footprint.squares(box, z)) do
        if (not vehicle or sq:getVehicleContainer() == vehicle) and not SafeHouse.isSafehouseAllowInteract(sq, player) then
            return "SAFEHOUSE"
        end
    end
    return nil
end

function Rules.occupied(vehicle)
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if vehicle:getCharacter(seat) then return true end
    end
    return false
end

-- Why this vehicle cannot be packed by anyone right now, or nil (Pack.whyNot). Player rules are in packWhyNot.
-- range: tiles from the player to the vehicle (default M.PACK_RANGE; a capture: CAPTURE_REACH).
function Rules.vehicleWhyNot(player, vehicle, range)
    if not vehicle or not vehicle:getSquare() then return "NO_VEHICLE" end
    local dx, dy, r = player:getX() - vehicle:getX(), player:getY() - vehicle:getY(), range or M.PACK_RANGE
    if dx * dx + dy * dy > r * r then return "TOO_FAR" end
    if Rules.occupied(vehicle) then return "OCCUPIED" end
    if vehicle:getVehicleTowing() or vehicle:getVehicleTowedBy() then return "TOWING" end
    local animals = vehicle:getAnimals()
    if animals and animals:size() > 0 then return "ANIMALS" end
    if vehicle:isEngineRunning() then return "ENGINE_RUNNING" end
    for i = 0, vehicle:getPartCount() - 1 do
        local inv = vehicle:getPartByIndex(i):getItemContainer()
        if inv then
            for _, t in ipairs(M.TYPES) do
                if inv:containsTypeRecurse(t.loaded) then return "CAPSULE_INSIDE" end
            end
        end
    end
    return Rules.safehouseWhyNot(player, M.Footprint.bodyBox(vehicle), math.floor(vehicle:getZ()), vehicle)
end

-- Who may pack: a vehicle claimed in VehicleManager needs its Tow permission (the owner, players the owner or the
-- faction shared Tow with, or an admin with its override on): packing takes the vehicle away like towing does, and
-- Tow is never part of a share with everyone. Any other vehicle: admins always, others by SandboxVars PackPermission
-- (1 key in the inventory or in the ignition, 2 anyone, 3 admins only).
-- Returns ok, mode, why. mode: "VM" (VehicleManager's owner, or its refusal), "SHARED" (Tow shared with this
-- player), "KEY"/"ANY"/"ADMIN" (an admin passing in mode 1 or by VM override reports "ADMIN"); why: VM's reason code.
function Rules.mayPack(player, vehicle)
    local vm = MinidoracatVehicleManagerAPI
    if vm and vm.canUse then
        local ok, why = vm.canUse(player, vehicle, "TOW")
        -- An unclaimed vehicle has no owner there (VM allows anyone): the sandbox rule below decides instead
        if why ~= "UNCLAIMED" then
            if ok ~= true then return false, "VM", why end
            if why == "ADMIN" then return true, "ADMIN", why end
            return true, why == "OWNER" and "VM" or "SHARED", why
        end
    end
    local mode = tonumber(Rules.sandbox().PackPermission) or 1
    if mode == 2 then return true, "ANY" end
    if Rules.isAdmin(player) then return true, "ADMIN" end
    if mode == 3 then return false, "ADMIN" end
    local key = vehicle:isKeysInIgnition() or vehicle:getCurrentKey() ~= nil
        or player:getInventory():haveThisKeyId(vehicle:getKeyId()) ~= nil
    return key, "KEY"
end

-- Sandbox Type<id>: whether players may use this type (a capsule: pack vehicles; a sphere: catch animals). Off only
-- stops that; loaded ones of the type still land or let their animal out, so nothing is ever shut in (vcap-types-1012).
function Rules.typeOn(t)
    return t ~= nil and Rules.sandbox()["Type" .. t.id] ~= false
end

-- Whether players may craft an empty one of type t (its recipe t.recipe, Recipes.lua): sandbox AllowCraftCapsules for
-- capsules, AllowCraftSpheres for spheres, both off by default (user 2026-10-19), and never a type switched off.
function Rules.craftOn(t)
    return t ~= nil and Rules.sandbox()[t.sphere and "AllowCraftSpheres" or "AllowCraftCapsules"] == true
        and Rules.typeOn(t)
end

-- The player's first empty capsule of type t (any depth in the inventory), or nil.
function Rules.emptyCapsule(player, t)
    return t and player:getInventory():getFirstTypeRecurse(t.empty)
end

-- Every type the player has empty ones of, in M.TYPES order: { { type, n, on }, ... }; spheres: the Pal Sphere tiers
-- (the animal menu), else the capsules (the vehicle menu).
function Rules.emptyTypes(player, spheres)
    local inv, out = player:getInventory(), {}
    for _, t in ipairs(M.TYPES) do
        local n = t.sphere == (spheres == true) and inv:getCountTypeRecurse(t.empty) or 0
        if n > 0 then out[#out + 1] = { type = t, n = n, on = Rules.typeOn(t) } end
    end
    return out
end

local function countIn(inv)
    local items, n = inv:getItems(), 0
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        n = n + 1
        if instanceof(it, "InventoryContainer") then n = n + countIn(it:getInventory()) end
    end
    return n
end

-- Items (any depth) that would go into the capsule with the vehicle.
function Rules.cargoCount(vehicle)
    local n = 0
    for i = 0, vehicle:getPartCount() - 1 do
        local inv = vehicle:getPartByIndex(i):getItemContainer()
        if inv then n = n + countIn(inv) end
    end
    return n
end

-- Everything the server checks before a player's pack with a capsule of type t, or nil. A sphere takes no vehicle.
function Rules.packWhyNot(player, vehicle, t)
    local why = Rules.vehicleWhyNot(player, vehicle)
    if why then return why end
    if not Rules.mayPack(player, vehicle) then return "NOT_ALLOWED" end
    if t and t.sphere then return "WRONG_ITEM" end
    if not Rules.emptyCapsule(player, t) then return "NO_CAPSULE" end
    if not Rules.typeOn(t) then return "TYPE_OFF" end
    return nil
end

-- Sandbox AllowAnimals (default on). Off only stops packing animals: animal capsules still land, like Type<id>.
function Rules.animalsOn()
    return Rules.sandbox().AllowAnimals ~= false
end

-- Sandbox WildCaptureChance: the base percent chance (0-100, default 50) that catching a wild animal (menu or capture)
-- works; Rules.captureChance adds the bonuses. 0: wild animals can't be caught at all (WILD_OFF); tame ones never roll.
function Rules.wildChance()
    return Rules.percent("WildCaptureChance", 50)
end

-- An integer sandbox option clamped to 0-100 (default when unset).
function Rules.percent(key, default)
    local n = math.floor(tonumber(Rules.sandbox()[key]) or default)
    return math.max(0, math.min(100, n))
end

-- Sandbox WildCaptureFailConsumes (default off): a wild animal that breaks free (ESCAPED) also takes the empty sphere.
-- Only that miss: every other refusal or miss keeps it.
function Rules.wildFailConsumes()
    return Rules.sandbox().WildCaptureFailConsumes == true
end

-- The roll for a wild animal at `chance` percent: true = caught. A field so the harness and E2E can force it.
function Rules.rollWild(chance)
    return ZombRand(100) < chance
end

-- Not aware of the player: not alerted (IsoAnimal.isAlerted, synced by AnimalEventPacket) and the player sneaking or
-- behind it (the angle between its facing and the way to the player above 90 degrees: a negative dot product).
function Rules.unaware(player, animal)
    if animal:isAlerted() then return false end
    if player:isSneaking() then return true end
    local dx, dy = player:getX() - animal:getX(), player:getY() - animal:getY()
    return animal:getForwardDirectionX() * dx + animal:getForwardDirectionY() * dy < 0
end

-- The one source of the catch chance (server roll, menu and cursor rows, the failure toast): nil for a tame animal
-- (always caught, no chance shown), else { total, factors = { { key, value }, ... } } with the non-zero bonuses in a
-- fixed order: Tier (the sphere type's bonus, typeId = its M.TYPES id), Injured (round((1 - health) x
-- WildCaptureInjuredBonus)), Young (isBaby: WildCaptureYoungBonus), Unaware (Rules.unaware: WildCaptureUnawareBonus).
-- total = base + bonuses, at most 100; a base of 0 stays 0 (WILD_OFF: no bonus brings it back). The client computes
-- it from what it sees; the server's at the catch decides.
function Rules.captureChance(player, animal, typeId)
    if not (animal and animal:isWild()) then return nil end
    local base = Rules.wildChance()
    local out = { total = base, factors = {} }
    if base <= 0 then return out end
    local function add(key, value)
        if value > 0 then
            out.factors[#out.factors + 1] = { key, value }
            out.total = out.total + value
        end
    end
    local t = M.TYPE_BY_ID[tostring(typeId)]
    add("Tier", t and t.bonus or 0)
    local health = math.max(0, math.min(1, tonumber(animal:getHealth()) or 1))
    add("Injured", math.floor((1 - health) * Rules.percent("WildCaptureInjuredBonus", 30) + 0.5))
    add("Young", animal:isBaby() and Rules.percent("WildCaptureYoungBonus", 15) or 0)
    add("Unaware", Rules.unaware(player, animal) and Rules.percent("WildCaptureUnawareBonus", 20) or 0)
    out.total = math.min(100, out.total)
    return out
end

-- Why this animal cannot be packed by anyone right now, or nil: the menu (client), the timed action and the server
-- (Pack.packAnimal) ask the same. Any live animal in the world may be packed, wild or tame, young or grown; a wild one
-- not while WildCaptureChance is 0 (WILD_OFF), else it may break free (Pack.packAnimal). Not in
-- the world (isExistInTheWorld: carried, in a hutch or a trailer, IsoAnimal.java:2369) is ANIMAL_AWAY; a carcass or
-- an animal on a butcher hook is NO_ANIMAL; a rope to a player or a post has to come off first (ROPE); its square in
-- someone else's safehouse is SAFEHOUSE. range: as in vehicleWhyNot.
function Rules.animalWhyNot(player, animal, range)
    if not animal or animal:isDead() or animal:isOnHook() then return "NO_ANIMAL" end
    if not Rules.animalsOn() then return "ANIMALS_OFF" end
    if animal:isWild() and Rules.wildChance() <= 0 then return "WILD_OFF" end
    if not animal:isExistInTheWorld() then return "ANIMAL_AWAY" end
    local d = animal:getData()
    if d:getAttachedPlayer() or d:getAttachedTree() then return "ROPE" end
    local dx, dy, r = player:getX() - animal:getX(), player:getY() - animal:getY(), range or M.PACK_RANGE
    if dx * dx + dy * dy > r * r then return "TOO_FAR" end
    local sq = animal:getSquare()
    if not sq then return nil end
    return Rules.safehouseWhyNot(player, { x1 = sq:getX(), y1 = sq:getY(), x2 = sq:getX(), y2 = sq:getY() }, sq:getZ())
end

-- Everything the server checks before a player catches an animal with a sphere of type t, or nil. A capsule takes no
-- animal.
function Rules.packAnimalWhyNot(player, animal, t)
    local why = Rules.animalWhyNot(player, animal)
    if why then return why end
    if t and not t.sphere then return "WRONG_ITEM" end
    if not Rules.emptyCapsule(player, t) then return "NO_CAPSULE" end
    if not Rules.typeOn(t) then return "TYPE_OFF" end
    return nil
end

-- Everything the server checks before a thrown empty capsule or sphere of type t takes this animal (isAnimal) or
-- vehicle, or nil (spec B): a sphere takes animals, a capsule vehicles (WRONG_ITEM first: the cursor's red frame says
-- which one to use); then the menu's rules for the same thing (a vehicle: its state and who may pack it), with
-- CAPTURE_REACH for the distance, and the type switched on. The capsule is the thrown one.
function Rules.captureWhyNot(player, thing, isAnimal, t)
    if t and t.sphere ~= (isAnimal == true) then return "WRONG_ITEM" end
    local why
    if isAnimal then
        why = Rules.animalWhyNot(player, thing, Rules.CAPTURE_REACH)
    else
        why = Rules.vehicleWhyNot(player, thing, Rules.CAPTURE_REACH)
        if not why and not Rules.mayPack(player, thing) then why = "NOT_ALLOWED" end
    end
    if why then return why end
    if not Rules.typeOn(t) then return "TYPE_OFF" end
    return nil
end

-- Where a Pal Sphere lets its animal out (Palworld v0.3.11: next to the player, no throw): the square the player faces
-- first, then the other seven around them, nearest that facing first; each must be in sight (Footprint.reach), hold an
-- animal (Footprint.animalClear) and lie outside other players' safehouses. Returns x, y, z or nil, "NO_ROOM".
function Rules.releaseSpot(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local fx, fy = player:getForwardDirectionX(), player:getForwardDirectionY()
    local cx, cy, z = math.floor(px), math.floor(py), math.floor(pz)
    local list = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local d = (dx * fx + dy * fy) / math.sqrt(dx * dx + dy * dy)
                local i = #list + 1
                while i > 1 and list[i - 1].d < d do list[i] = list[i - 1]; i = i - 1 end
                list[i] = { x = cx + dx, y = cy + dy, d = d }
            end
        end
    end
    for _, c in ipairs(list) do
        local why, box = M.Footprint.animalClear(c.x, c.y, z)
        why = why or M.Footprint.reach(px, py, pz, c.x, c.y, z, 3, true) -- 3: a corner square's (x, y) from the far side
            or (box and Rules.safehouseWhyNot(player, box, z))
        if not why then return c.x, c.y, z end
    end
    return nil, "NO_ROOM"
end

return Rules
