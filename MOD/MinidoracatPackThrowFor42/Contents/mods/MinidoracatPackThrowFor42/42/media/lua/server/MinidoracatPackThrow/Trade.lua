-- Pack & Throw: loaded capsules traded through Minidoracat Economy (market listings, auctions), cargo included.
-- Economy (API rev 6, unique item types) keeps a snapshot of the capsule and builds a new item when it hands it over,
-- which would come back with a new id, away from its record, and empty. Economy keeps only `ext`: the capsule id and
-- what the listing shows (view). The cargo goes into the record (snap.escrow) through Economy's own codec
-- (v1.snapshotItem) when Economy takes the capsule; when Economy hands a new capsule over (rebuilt: before it puts it
-- anywhere) the cargo is rebuilt into it (v1.rebuildItem) and the capsule and every cargo item get their old ids back
-- (InventoryItem.setID, as vanilla does when it swaps a world item: IsoWorldInventoryObject.java:125). The record, its
-- cargo map (part per item id), the sealed list and the duplicate-capsule rules then hold as before. A light record's
-- cargo (sandbox CargoWeight off at packing) goes through the container for the codec and back into the cargo store.
-- The escrowed cargo stays in the record until the next listing or state change: a delivery Economy repeats after a
-- crash rolled the world back gets the same capsule again, and of two copies only one can ever unpack.
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Store"
require "MinidoracatPackThrow/Query"
require "MinidoracatPackThrow/Condition"
require "MinidoracatPackThrow/Snapshot"
local M = MinidoracatPackThrow
local Store = M.Store
local Trade = {}
M.Trade = Trade

Trade.MAX_CARGO = 300 -- items at any depth (bag contents, keys on a ring, weapon parts): the record carries them

local function economy()
    local e = MinidoracatEconomy
    return e and e.v1
end

-- What an item holds, as a Java list, and how it holds it: a bag's container, or a key ring's keys (KeyRing.java:36,
-- not an ItemContainer). nil for anything else.
local function inner(it)
    if instanceof(it, "InventoryContainer") then return it:getInventory():getItems(), "bag" end
    local keys = it.getKeys and it:getKeys()
    if keys then return keys, "keys" end
    return nil
end

local function weaponParts(it)
    local parts = it.getAllWeaponParts and it:getAllWeaponParts()
    return parts and parts:size() > 0 and parts or nil
end

-- The capsule Economy handed over is in the world again (Guard sees it with a player, or its holder offers it again):
-- the trade is over. Economy may build a capsule more than once and keep only one of them (a buyer asked to confirm
-- mail delivery, a claim the backpack cannot take), so rebuilt cannot tell when the capsule left Economy; this can.
function Trade.landed(capsuleId, player)
    local snap = Store.read(capsuleId)
    local e = snap and type(snap.escrow) == "table" and snap.escrow
    if not (e and e.active) then return end
    e.active = nil
    local last = type(e.last) == "table" and e.last or {}
    Store.event(capsuleId, snap, "TRADED", player, { why = tostring(last.kind) .. " " .. tostring(last.ref) })
end

-- true, or false plus the detail the seller's client words (Info.refusalText). Economy asks when it lists the
-- seller's items and again right before it takes the capsule (escrow). Cargo is tried with the same codec call the
-- escrow makes; weapon parts count as items of their own (they are taken off first). A capsule still marked as in a
-- trade is out of it: its holder is offering it.
function Trade.check(item, player)
    local eco = economy()
    if not eco then return false, { code = "OTHER" } end
    local id = item:getID()
    local snap = Store.read(id)
    if not snap then return false, { code = "NO_RECORD" } end
    if snap.state ~= "PACKED" then return false, { code = "NOT_PACKED" } end
    if snap.settled ~= true then return false, { code = Store.uncertain(id, snap) and "UNCERTAIN" or "NOT_READY" } end
    if type(snap.escrow) == "table" and snap.escrow.active then Trade.landed(id, player) end
    local n, bad = 0, nil
    local function try(it)
        n = n + 1
        if bad then return end
        local s, why = eco.snapshotItem(it, { contents = true })
        if not s then bad = { code = "CARGO", type = it:getFullType(), why = tostring(why) } end
    end
    local walk
    local function visit(it)
        try(it)
        local parts = weaponParts(it)
        for j = 0, (parts and parts:size() or 0) - 1 do try(parts:get(j)) end
        local kids = inner(it)
        if kids then walk(kids) end
    end
    walk = function(list)
        for i = 0, list:size() - 1 do visit(list:get(i)) end
    end
    for _, it in ipairs(M.cargoItems(item)) do visit(it) end
    if bad then return false, bad end
    if n > Trade.MAX_CARGO then return false, { code = "TOO_MANY", n = n, max = Trade.MAX_CARGO } end
    return true
end

-- Economy's snapshot carries a bare weapon (ECCodec detachParts): parts go into the weapon's container first, and the
-- record follows them (sealed; a top-level part goes back to the vehicle part its weapon came from).
local function detachAll(container, top, eco, snap)
    local weapons, bags = {}, {}
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if weaponParts(it) then weapons[#weapons + 1] = it end
        if instanceof(it, "InventoryContainer") then bags[#bags + 1] = it end
    end
    for _, w in ipairs(weapons) do
        local parts, list = weaponParts(w), {}
        for j = 0, parts:size() - 1 do list[#list + 1] = parts:get(j) end
        eco.detachParts(w, container)
        for _, p in ipairs(list) do
            snap.sealed = snap.sealed or {}
            snap.sealed[#snap.sealed + 1] = p:getID()
            if container == top then
                snap.cargo = snap.cargo or {}
                snap.cargo[p:getID()] = snap.cargo[w:getID()]
                snap.manifest = snap.manifest or {}
                snap.manifest[p:getFullType()] = (snap.manifest[p:getFullType()] or 0) + 1
            end
        end
    end
    for _, b in ipairs(bags) do detachAll(b:getInventory(), top, eco, snap) end
end

-- { { id, s = codec snapshot, c = children, k = "bag" / "keys" }, ... } for a Java list of items.
local function pack(list, eco)
    local out = {}
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        local s, why = eco.snapshotItem(it, { contents = true })
        if not s then return nil, { code = "CARGO", type = it:getFullType(), why = tostring(why) } end
        local node = { id = it:getID(), s = s }
        local kids, kind = inner(it)
        if kids and kids:size() > 0 then
            local sub, err = pack(kids, eco)
            if not sub then return nil, err end
            node.c, node.k = sub, kind
        end
        out[#out + 1] = node
    end
    return out
end

-- Rebuilds nodes into container (or onto keyRing), every item with its old id. Lost ones: "type:reason".
local function refill(container, nodes, eco, lost, keyRing)
    for _, node in ipairs(nodes) do
        local it, why = eco.rebuildItem(node.s)
        if it then
            it:setID(node.id)
            if keyRing then keyRing:addKey(it) else container:AddItem(it) end
            if node.c and node.k == "keys" then
                refill(nil, node.c, eco, lost, it)
            elseif node.c and instanceof(it, "InventoryContainer") then
                refill(it:getInventory(), node.c, eco, lost)
            end
        else
            lost[#lost + 1] = tostring(type(node.s) == "table" and node.s.type) .. ":" .. tostring(why)
        end
    end
end

-- What the listing shows under the capsule (client Info.viewLines): the vehicle and the tooltip's numbers, or for an
-- animal record the capsule type (`style`, M.TYPES id) and the animal (Animal.view without breeding: every buyer sees
-- it). Small: Economy sends it with every listing row.
function Trade.view(capsuleId, snap, style)
    if snap.kind == "animal" then
        return { kind = "animal", style = style, animal = M.Animal.view(snap.animal, false) }
    end
    local s = M.Query.summary(capsuleId, snap)
    local c = M.Condition.of(s.parts)
    local n = 0
    for _, e in ipairs(s.manifest or {}) do n = n + (tonumber(e.n) or 0) end
    return { script = snap.script, name = snap.name, engine = c.engine, body = c.body, fuel = c.fuel, fuelCap = c.fuelCap,
        battery = c.battery, missing = #c.missing, cargo = n }
end

-- Economy takes the capsule (listed or put up for auction) in this tick. Returns ext, or nil plus a refusal detail.
-- An animal capsule carries nothing (the animal is the record): no cargo goes into the escrow.
function Trade.escrow(item, player, channel, ref)
    local ok, detail = Trade.check(item, player)
    if not ok then return nil, detail end
    local eco, id = economy(), item:getID()
    local snap = Store.read(id)
    -- The capsule's own weight comes from its script: on a dedicated server this mod's items have no display name (the
    -- name is the full type) and such an item weighs 0 (InventoryItem.getActualWeightUnmodded, InventoryItem.java:2740-
    -- 2742), so getUnequippedWeight left the capsule out (an animal capsule was listed at 0.0, vcap-tam-1012c). Read
    -- before a light capsule's cargo leaves its store below: the rebuilt one puts it back there.
    local weight = item:getScriptItem():getActualWeight() + item:getContentsWeight()
    local cargo, moved = nil, 0
    if snap.kind ~= "animal" then
        local box = item:getInventory()
        moved = M.Snapshot.unstoreCargo(item)
        detachAll(box, box, eco, snap)
        local err
        cargo, err = pack(box:getItems(), eco)
        if not cargo then
            if moved > 0 then M.Snapshot.storeCargo(item) end
            return nil, err
        end
    end
    local now, by = getTimestampMs(), player and player:getUsername() or "-"
    snap.escrow = { active = true, t = now, by = by, channel = tostring(channel), ref = tostring(ref), cargo = cargo }
    snap.seen = { t = now, where = "economy", by = by }
    if not Store.event(id, snap, "ESCROW", player, { why = tostring(channel) .. " " .. tostring(ref) }) then
        if moved > 0 then M.Snapshot.storeCargo(item) end
        return nil, { code = "OTHER" }
    end
    local t = M.typeOf(item)
    return { capsuleId = id, view = Trade.view(id, snap, t and t.id), weight = weight }
end

-- Economy built a capsule from its snapshot to hand over (buyer, auction winner, the seller on a cancel or an expiry):
-- the record's id and cargo go into it before Economy puts it anywhere. Economy may build more than once for one
-- delivery and drop the extra item, so this only fills the item and notes which delivery it was; the trade ends when
-- the capsule shows up in the world (Trade.landed).
function Trade.rebuilt(ext, item, player, ctx)
    local id = type(ext) == "table" and tonumber(ext.capsuleId)
    local snap = id and Store.read(id)
    local to = player and player:getUsername() or "-"
    if not (snap and snap.state == "PACKED" and type(snap.escrow) == "table") then
        M.log("TRADE_ORPHAN capsule=" .. tostring(id) .. " to=" .. to .. " state=" .. tostring(snap and snap.state))
        return
    end
    item:setID(id)
    local lost = {}
    refill(item:getInventory(), snap.escrow.cargo or {}, economy(), lost)
    if snap.light then M.Snapshot.storeCargo(item) end
    if #lost > 0 then M.log("TRADE_LOST capsule=" .. id .. " to=" .. to .. " items=" .. table.concat(lost, ",")) end
    ctx = type(ctx) == "table" and ctx or {}
    snap.escrow.last = { kind = ctx.kind, ref = ctx.ref, to = to, t = getTimestampMs() }
    Store.write(id, snap, true)
end

-- Economy stopped after escrow returned (the capsule stayed with the seller).
function Trade.aborted(ext, player, ref)
    local id = type(ext) == "table" and tonumber(ext.capsuleId)
    local snap = id and Store.read(id)
    if not (snap and type(snap.escrow) == "table" and snap.escrow.active) then return end
    snap.escrow = nil
    Store.event(id, snap, "ESCROW_ABORTED", player, { why = tostring(ref) })
end

Trade.handler = {
    check = function(item, player) return Trade.check(item, player) end,
    escrow = Trade.escrow,
    rebuilt = Trade.rebuilt,
    aborted = Trade.aborted,
}

return Trade
