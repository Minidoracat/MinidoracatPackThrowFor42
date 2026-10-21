-- Pack & Throw: server guards over loaded capsules, driven by one OnTickEvenPaused handler.
--   * Store.settleDue every tick. OnTick stops on an empty dedicated server with PauseEmpty; OnTickEvenPaused fires
--     at the top of IngameState.updateInternal, before the pause check (IngameState.java:1347 vs 1517-1520).
--   * Every PASS_MS, for loaded capsules in online players' inventories (any depth) and on the ground around them:
--     a stale record (UNPACKED and settled, or VOID) means the cargo is a second copy -> replace with an empty capsule
--     (Guard.stale: an unpack newer than the world save is cleared only when its car is loaded, else an admin
--     checks); otherwise sealed cargo that left the capsule is put back when the player carries it (cargo lock).
--     Vanilla item transfers are pure Java (ItemTransactionPacket -> TransactionManager.isConsistent/
--     Transaction.update, no Lua hook on the source), so the server can only undo them, not refuse them.
--     Each capsule's sighting is noted (Store.seen). Cargo is inside when it is in the capsule's container or in its
--     cargo store (M.cargoItems; a light record keeps it in the store, where no vanilla transfer reaches).
--   * Sandbox AllowCargoTakeOut and a confirmed PACKED record (Rules.cargoOpen): cargo that left stays out; the
--     record drops it (sealed, manifest) so the tooltip, the preview and the admin panel list what is still inside.
--   * Record retention (Index.prune) right after start, then every PRUNE_MS.
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Store"
local M = MinidoracatPackThrow
local Store = M.Store
local Guard = {}
M.Guard = Guard

Guard.PASS_MS = 1000
Guard.GROUND_RANGE = 2 -- squares around each player searched for capsules on the ground
Guard.PRUNE_MS = 3600000 -- record retention runs right after start, then hourly
Guard.PRUNE_BUCKETS = 8  -- buckets rewritten per pass while a retention backlog lasts

-- "full.Type*n,..." of a capsule's whole cargo (container and cargo store, any depth), for logs and history.
local function listing(capsule)
    local counts = {}
    local function walk(it)
        counts[it:getFullType()] = (counts[it:getFullType()] or 0) + 1
        if instanceof(it, "InventoryContainer") then
            local items = it:getInventory():getItems()
            for i = 0, items:size() - 1 do walk(items:get(i)) end
        end
    end
    for _, it in ipairs(M.cargoItems(capsule)) do walk(it) end
    local parts = {}
    for ft, n in pairs(counts) do parts[#parts + 1] = ft .. "*" .. n end
    return #parts > 0 and table.concat(parts, ",") or "-"
end

-- Puts an empty capsule of the same type where `capsule` is (same container, or the same square) and deletes it with
-- its cargo.
local function replaceWithEmpty(player, capsule)
    local empty = instanceItem((M.typeOf(capsule) or M.TYPES[1]).empty)
    local wo = capsule:getWorldItem()
    if wo and wo:getSquare() then
        local sq = wo:getSquare()
        sq:transmitRemoveItemFromSquare(wo)
        capsule:setWorldItem(nil)
        if empty then sq:AddWorldInventoryItem(empty, 0.5, 0.5, 0) end
        return
    end
    local c = capsule:getContainer()
    if not c then return end
    if player then player:removeFromHands(capsule) end
    c:DoRemoveItem(capsule)
    sendRemoveItemFromContainer(c, capsule)
    if empty then
        c:AddItem(empty)
        sendAddItemToContainer(c, empty)
    end
end

-- The capsule's cargo is a second copy (Store.isStale): swap the capsule for an empty one and record what went.
function Guard.clear(player, capsule, capsuleId, snap, why)
    local items = listing(capsule)
    replaceWithEmpty(player, capsule)
    Store.event(capsuleId, snap, "CLEARED", player, { why = why, items = items })
end

-- A stale record seen with its capsule. An unpack the world save does not know yet (no ModData mark: the world went
-- back to an older save, by a crash or a rollback) clears only when its spawned car is loaded here; otherwise the
-- car may have gone back with the world and the cargo is the only copy: an admin checks (Store.suspect).
-- Returns true when the capsule was cleared.
function Guard.stale(player, capsule, capsuleId, snap, why)
    if snap.state == "UNPACKED" and not Store.marked(capsuleId) then
        if not Store.findRecorded(snap) then
            Store.suspect(capsuleId, snap, player)
            return false
        end
        Store.mark(capsuleId)
    end
    Guard.clear(player, capsule, capsuleId, snap, why)
    return true
end

-- Ids of every item in `list` (a Lua array) and inside it, any depth.
local function idsIn(list, set)
    for _, it in ipairs(list) do
        set[it:getID()] = true
        if instanceof(it, "InventoryContainer") then
            local items, kids = it:getInventory():getItems(), {}
            for i = 0, items:size() - 1 do kids[#kids + 1] = items:get(i) end
            idsIn(kids, set)
        end
    end
    return set
end

local reported = {} -- "capsuleId:itemId" -> true: cargo that left and could not be put back, logged once per run

-- Puts sealed cargo the player took out back into the capsule (top level). Equipped, worn or attached items and
-- items the player does not carry are only logged.
local function lock(player, capsule, capsuleId, sealed)
    if not sealed or #sealed == 0 then return end
    local here = idsIn(M.cargoItems(capsule), {})
    local inv, box = player:getInventory(), capsule:getInventory()
    local back, gone = {}, {}
    for _, itemId in ipairs(sealed) do
        if not here[itemId] then
            local item = inv:getItemWithIDRecursiv(itemId)
            if item and M.inCapsule(item) then
                -- already back: it came inside a bag that was put back above (sealed lists bags before contents)
            elseif item and not (player:isEquipped(item) or player:isAttachedItem(item)) then
                local from = item:getContainer()
                from:Remove(item)
                sendRemoveItemFromContainer(from, item)
                box:AddItem(item)
                sendAddItemToContainer(box, item)
                back[#back + 1] = item:getFullType() .. "#" .. itemId
                idsIn({ item }, here)
            elseif not reported[capsuleId .. ":" .. itemId] then
                reported[capsuleId .. ":" .. itemId] = true
                gone[#gone + 1] = (item and (item:getFullType() .. "#equipped#") or "#") .. itemId
            end
        end
    end
    if #back == 0 and #gone == 0 then return end
    local snap = Store.read(capsuleId)
    if not snap then return end
    if #back > 0 then Store.event(capsuleId, snap, "CARGO_LOCK", player, { why = "returned", items = table.concat(back, ",") }) end
    if #gone > 0 then Store.event(capsuleId, snap, "CARGO_LOCK", player, { why = "missing", items = table.concat(gone, ",") }) end
end

-- Taking out is allowed: drop what left from the record. sealed keeps the ids still inside (any depth), manifest is
-- counted again from the top level like Snapshot.capture; the history names what left (fullType when the player
-- carries it, "#id" when it went elsewhere).
local function sync(player, capsule, capsuleId, sealed)
    if not sealed or #sealed == 0 then return end
    local cargo = M.cargoItems(capsule)
    local here = idsIn(cargo, {})
    local kept, taken = {}, {}
    for _, itemId in ipairs(sealed) do
        if here[itemId] then
            kept[#kept + 1] = itemId
        else
            local item = player:getInventory():getItemWithIDRecursiv(itemId)
            local name = item and item:getFullType() or ("#" .. itemId)
            taken[name] = (taken[name] or 0) + 1
        end
    end
    if #kept == #sealed then return end
    local snap = Store.read(capsuleId)
    if not snap then return end
    local manifest = {}
    for _, it in ipairs(cargo) do manifest[it:getFullType()] = (manifest[it:getFullType()] or 0) + 1 end
    local parts = {}
    for name, n in pairs(taken) do parts[#parts + 1] = name .. "*" .. n end
    snap.sealed, snap.manifest = kept, manifest
    Store.event(capsuleId, snap, "CARGO_TAKEN", player, { items = table.concat(parts, ",") })
end

-- One loaded capsule seen by a pass: clear it when stale, otherwise keep its cargo inside, or follow what was taken
-- when the server lets cargo out. A capsule out of an Economy trade ends that trade (Trade.landed; Trade.lua is
-- loaded whenever a record is in a trade, it put it there).
function Guard.check(player, capsule)
    local capsuleId = capsule:getID()
    local st = Store.status(capsuleId)
    if not st then return end
    if Store.isStale(st) then
        local snap = Store.read(capsuleId)
        if snap and Store.isStale(snap) then Guard.stale(player, capsule, capsuleId, snap, "scan") end
        return
    end
    if st.trade and M.Trade then M.Trade.landed(capsuleId, player) end
    if M.Rules.cargoOpen(st) then
        sync(player, capsule, capsuleId, st.sealed)
    else
        lock(player, capsule, capsuleId, st.sealed)
    end
end

local function groundCapsules(player, out)
    local cell, r = getCell(), Guard.GROUND_RANGE
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -r, r do
        for dy = -r, r do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            local objs = sq and sq:getWorldObjects()
            for i = 0, (objs and objs:size() or 0) - 1 do
                local it = objs:get(i):getItem()
                if it and M.isLoaded(it) then out[#out + 1] = it end
            end
        end
    end
    return out
end

-- Every loaded capsule on the player (any depth) and on the ground around them: checked, and its sighting noted
-- (where the admin panel's "go to the last sighting" leads).
function Guard.pass(player)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local held = { where = "player", by = player:getUsername(), x = px, y = py, z = pz }
    local inv = player:getInventory()
    for _, t in ipairs(M.TYPES) do
        local found = inv:getAllTypeRecurse(t.loaded)
        for i = 0, found:size() - 1 do
            local capsule = found:get(i)
            Guard.check(player, capsule)
            Store.seen(capsule:getID(), held)
        end
    end
    for _, capsule in ipairs(groundCapsules(player, {})) do
        Guard.check(player, capsule)
        local sq = capsule:getWorldItem() and capsule:getWorldItem():getSquare()
        if sq then Store.seen(capsule:getID(), { where = "ground", x = sq:getX(), y = sq:getY(), z = sq:getZ() }) end
    end
end

local function players()
    local out = {}
    if isServer() then
        local online = getOnlinePlayers()
        for i = 0, (online and online:size() or 0) - 1 do out[#out + 1] = online:get(i) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p then out[#out + 1] = p end
        end
    end
    return out
end

local function retentionDays()
    local d = math.floor(tonumber(M.Rules.sandbox().RecordRetentionDays) or 30)
    return math.max(1, math.min(90, d))
end

local nextPass, nextPrune = 0, 0
function Guard.tick()
    local now = getTimestampMs()
    Store.settleDue(now)
    if now < nextPass then return end
    nextPass = now + Guard.PASS_MS
    for _, p in ipairs(players()) do
        local ok, err = pcall(Guard.pass, p)
        if not ok then M.log("guard pass failed: " .. tostring(err)) end
    end
    -- retention (Index.prune): needs the index module, loaded with the other server files
    local Index = M.Index
    if Index and now >= nextPrune then
        local ok, done = pcall(Index.prune, now, retentionDays(), Guard.PRUNE_BUCKETS)
        if not ok then M.log("record retention failed: " .. tostring(done)) end
        if not ok or done then nextPrune = now + Guard.PRUNE_MS end
    end
end
Events.OnTickEvenPaused.Add(Guard.tick)

return Guard
