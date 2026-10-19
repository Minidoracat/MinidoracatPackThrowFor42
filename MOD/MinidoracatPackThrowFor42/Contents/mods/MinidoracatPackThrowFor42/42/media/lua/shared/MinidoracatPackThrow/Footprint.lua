-- Pack & Throw: where a capsule may land and the ground its vehicle needs. Shared by the landing cursor (client)
-- and the throw / landing checks (server), so both judge the same squares.
-- addVehicleDebug puts the vehicle centre on the target square's north-west corner and turns it up to 0.2 rad off
-- the asked direction (LuaManager.java:10806-10815). It only refuses indoor squares outside vehicle zones
-- (IsoChunk.java:1254-1256): its vehicle overlap test reads the new vehicle's physics transform, not set yet there, so
-- it never fires (E2E unplaced-mp). Other vehicles, walls, fences, trees, furniture and people are checked here.
require "MinidoracatPackThrow/Core"
local M = MinidoracatPackThrow
local Footprint = {}
M.Footprint = Footprint

local SLACK = math.sin(0.2) -- spawn angle jitter
local MARGIN = 0.1          -- tiles around the body; more would cover the square beside a pressed capsule

-- Facing for a throw from (0, 0) along (dx, dy) (x east, y south): the nearest of N/E/S/W.
function Footprint.dirOf(dx, dy)
    if math.abs(dx) >= math.abs(dy) then return dx >= 0 and "E" or "W" end
    return dy >= 0 and "S" or "N"
end

-- Body width (x) and length (z) in tiles from a VehicleScript.
function Footprint.size(script)
    local e = script and script:getExtents()
    if not e then return nil end
    return e:x(), e:z()
end

-- Inclusive tile box { x1, y1, x2, y2 } covered by a w x l body centred on point (x, y), facing dir.
function Footprint.box(x, y, dir, w, l)
    local ax = w / 2 + l / 2 * SLACK + MARGIN
    local ay = l / 2 + w / 2 * SLACK + MARGIN
    if dir == "E" or dir == "W" then ax, ay = ay, ax end
    return { x1 = math.floor(x - ax), y1 = math.floor(y - ay), x2 = math.ceil(x + ax) - 1, y2 = math.ceil(y + ay) - 1 }
end

local function squareWhy(sq)
    if not sq then return "UNLOADED" end
    if sq:getVehicleContainer() then return "VEHICLE" end
    local movers = sq:getMovingObjects()
    if movers and movers:size() > 0 then return "PERSON" end
    if not sq:isFree(false) then
        if sq:HasTree() then return "TREE" end
        if not sq:has(IsoFlagType.solidfloor) then return "NO_FLOOR" end
        return "SOLID"
    end
    return nil
end

-- First reason the box is not clear, or nil. getSquare(x, y, z) -> IsoGridSquare or nil.
-- Walls, fences, doors and windows between two squares of the box block too.
function Footprint.blocked(getSquare, box, z)
    for x = box.x1, box.x2 do
        for y = box.y1, box.y2 do
            local sq = getSquare(x, y, z)
            local why = squareWhy(sq)
            if why then return why, x, y end
            local east = x < box.x2 and getSquare(x + 1, y, z)
            local south = y < box.y2 and getSquare(x, y + 1, z)
            if (east and sq:isBlockedTo(east)) or (south and sq:isBlockedTo(south)) then return "WALL", x, y end
        end
    end
    return nil
end

local function cellSquare(x, y, z) return getCell():getGridSquare(x, y, z) end

-- Can a capsule sent from point (ox, oy, oz) land on square (x, y, z)? Reason or nil: TOO_FAR (range in tiles, same
-- floor only), NO_SIGHT (sight = the sender must see the square: throws do, a pressed capsule does not).
function Footprint.reach(ox, oy, oz, x, y, z, range, sight)
    local dx, dy = x - ox, y - oy
    if math.floor(oz) ~= z or dx * dx + dy * dy > range * range then return "TOO_FAR" end
    if sight then
        local res = LosUtil.lineClear(getCell(), math.floor(ox), math.floor(oy), z, x, y, z, false)
        if tostring(res) == "Blocked" then return "NO_SIGHT" end
    end
    return nil
end

-- Is the ground at (x, y, z) clear for the vehicle of `script` facing dir? Reason or nil (INDOORS, see squareWhy,
-- WALL), then the box. Vehicles need the centre square outside (vehicle zones aside, IsoChunk.java:1254-1256).
function Footprint.clear(script, x, y, z, dir)
    local w, l = Footprint.size(script)
    if not w then return "NO_SCRIPT" end
    local box = Footprint.box(x, y, dir, w, l)
    local centre = cellSquare(x, y, z)
    if centre and not centre:isOutside() then return "INDOORS", box end
    return Footprint.blocked(cellSquare, box, z), box
end

-- The one square an animal lands on: loaded, not water (IsoAnimal.new skips its init there), not under a vehicle and
-- free (isFree(false): no solid object, tree or missing floor; people and other animals may stand there). Indoors is
-- fine. Reason or nil, then the one-square box (the cursor draws it). Shared by the cursor and every landing check.
function Footprint.animalClear(x, y, z)
    local box = { x1 = x, y1 = y, x2 = x, y2 = y }
    local sq = cellSquare(x, y, z)
    if not sq then return "UNLOADED", box end
    if sq:has(IsoFlagType.water) then return "WATER", box end
    if sq:getVehicleContainer() then return "VEHICLE", box end
    if not sq:isFree(false) then
        if sq:HasTree() then return "TREE", box end
        if not sq:has(IsoFlagType.solidfloor) then return "NO_FLOOR", box end
        return "SOLID", box
    end
    return nil, box
end

-- The loaded squares of box on floor z, as a list.
function Footprint.squares(box, z)
    local out = {}
    for x = box.x1, box.x2 do
        for y = box.y1, box.y2 do
            local sq = cellSquare(x, y, z)
            if sq then out[#out + 1] = sq end
        end
    end
    return out
end

-- A box around a parked vehicle that holds its whole body whatever way it faces: its longest side, centred on it,
-- plus a square. The squares under the body are those of this box whose getVehicleContainer() is the vehicle.
function Footprint.bodyBox(vehicle)
    local w, l = Footprint.size(vehicle:getScript())
    local r = math.ceil(math.max(w or 0, l or 0) / 2) + 1
    local x, y = math.floor(vehicle:getX()), math.floor(vehicle:getY())
    return { x1 = x - r, y1 = y - r, x2 = x + r, y2 = y + r }
end

-- What an empty capsule thrown at square (x, y, z) captures (spec B): an animal on that square, else a vehicle over
-- it, else the nearest animal on the eight squares around it, else a vehicle over one of them. Returns thing, isAnimal
-- or nil. Dead animals and animals on a hook are not on a square's list (IsoGridSquare.getAnimals).
function Footprint.target(x, y, z)
    local best, bestScore, animal
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq = cellSquare(x + dx, y + dy, z)
            if sq then
                local far = (dx ~= 0 or dy ~= 0) and 2 or 0
                local list = sq:getAnimals()
                for i = 0, list:size() - 1 do
                    local a = list:get(i)
                    local ax, ay = a:getX() - x - 0.5, a:getY() - y - 0.5
                    local score = far + math.min(ax * ax + ay * ay, 0.9)
                    if not bestScore or score < bestScore then best, bestScore, animal = a, score, true end
                end
                local v = sq:getVehicleContainer()
                if v and (not bestScore or far + 1 < bestScore) then best, bestScore, animal = v, far + 1, false end
            end
        end
    end
    return best, animal
end

-- The target a capture named, if it is still on or next to square (x, y, z) (the landing re-finds it there), or nil.
-- cap = { kind = "animal" | "vehicle", tid = its online id (animal) or vehicle id: MP, what the client saw } or
-- { kind, thing = the object itself: SP, where the throw never crossed the network }. An animal's own position counts,
-- not only the square list it is on: one moved this tick still sits on its old square's list (vcap-capture-1013b).
function Footprint.find(cap, x, y, z)
    local function named(o)
        if cap.thing ~= nil then return o == cap.thing end
        return (cap.kind == "animal" and o:getOnlineID() or o:getId()) == cap.tid
    end
    local function near(a)
        return math.abs(math.floor(a:getX()) - x) <= 1 and math.abs(math.floor(a:getY()) - y) <= 1
    end
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq = cellSquare(x + dx, y + dy, z)
            if sq and cap.kind == "animal" then
                local list = sq:getAnimals()
                for i = 0, list:size() - 1 do
                    local a = list:get(i)
                    if named(a) and near(a) then return a end
                end
            elseif sq then
                local v = sq:getVehicleContainer()
                if v and named(v) then return v end
            end
        end
    end
    return nil
end

return Footprint
