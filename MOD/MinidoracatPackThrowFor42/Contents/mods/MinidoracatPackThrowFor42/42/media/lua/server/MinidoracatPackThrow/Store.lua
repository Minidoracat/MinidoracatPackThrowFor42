-- Pack & Throw: the server's capsule records, the only source of truth for a capsule. States:
--   PACKED   -> UNPACKED (unpack) | RESTORED (admin restore) | VOID (admin: the original car is still there)
--   UNPACKED -> PACKED (spawn failed, or admin: the new car is gone) | RESTORED (admin, uncertain records only)
-- Every change that touched vehicles.db is marked `settled` SETTLE_MS later. A record without it that is not
-- pending in this server run was cut short by a crash: "uncertain", unpack refuses it until an admin resolves it.
--
-- Files: Zomboid/Lua/MinidoracatPackThrow/<world>/ (Store.dir): "MP_<server>" or "SP_<mode>_<save>". Zomboid/Lua
-- is one folder for every save and server on the machine (LuaManager.getLuaCacheDir, LuaManager.java:1265-1271).
-- Lua can create and overwrite files there but never delete them, so records live in BUCKETS fixed bucket files
-- (capsule id mod BUCKETS) and dropping a record means writing its bucket without it. Each bucket has two copies,
-- b<NNN>a.txt and b<NNN>b.txt, written in turn:
--   MVC1 <gen>
--   <capsuleId> <record json>          one line per record
--   END <gen> <record count>
-- A write goes to the older copy with gen + 1 and is read back; a reader takes the newest complete copy, so a write
-- cut short by a crash only loses itself. Server Lua runs on one thread: no two events write a bucket at once.
--
-- Global ModData (saved with the world, so it goes back with a world rollback; the files do not) keeps `ended`
-- marks for unpacks: a stale record without its mark is newer than the world save (Guard.stale).
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Json"
local M = MinidoracatPackThrow
local Json = M.Json
local Store = {}
M.Store = Store

Store.ROOT = "MinidoracatPackThrow/"
Store.BUCKETS = 256
-- vehicles.db INSERT/UPDATE/DELETE commit on the SPV thread about every 500 ms (VehiclesDB2.java:327-331,879-889).
Store.SETTLE_MS = 5000
Store.SEEN_MS = 3600000 -- a sighting is written at most once an hour unless the place or the holder changed
Store.MODDATA = "MinidoracatPackThrow"

local pending = {} -- capsuleId -> ms when it settles; this server run only
local status = {}  -- capsuleId -> { state, settled, sealed, seen } or false (no readable record); kept fresh
local warned = {}  -- capsuleId -> true once its uncertain record was logged in this server run
local buckets = {} -- bucket -> { gen, side } once looked at ({ corrupt = true } when no copy is complete)
local dir          -- resolved on first use: the world name is known once the game loaded

local function clean(s)
    s = string.gsub(tostring(s or ""), "[^%w%-_]", "_")
    return s ~= "" and s or "unknown"
end

-- This world's folder: one per dedicated (or hosted) server, one per single-player save.
function Store.dir()
    if not dir then
        local world = getWorld():getWorld()
        local name = isServer() and ("MP_" .. clean(world)) or ("SP_" .. clean(getCore():getGameMode()) .. "_" .. clean(world))
        dir = Store.ROOT .. name .. "/"
    end
    return dir
end

-- Kahlua's % truncates toward zero (pitfalls.md): fold negative ids back into 0..BUCKETS-1.
function Store.bucketOf(capsuleId)
    local b = math.floor(capsuleId) % Store.BUCKETS
    if b < 0 then b = b + Store.BUCKETS end
    return b
end

function Store.path(b, side)
    local n = tostring(b)
    while #n < 3 do n = "0" .. n end
    return Store.dir() .. "b" .. n .. side .. ".txt"
end

local function readText(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local lines = {}
    local line = r:readLine()
    while line do
        lines[#lines + 1] = line
        line = r:readLine()
    end
    r:close()
    return table.concat(lines, "\n")
end

-- A complete copy { gen, lines = { "<id> <json>", ... } }; nil when the file is missing, false when it is there but
-- incomplete (no header, footer, or a footer that does not match).
local function readCopy(b, side)
    local r = getFileReader(Store.path(b, side), false)
    if not r then return nil end
    local head = r:readLine()
    local lines, last = {}, nil
    local line = r:readLine()
    while line do
        if last then lines[#lines + 1] = last end
        last = line
        line = r:readLine()
    end
    r:close()
    local gen = head and tonumber(string.match(head, "^MVC1 (%d+)$"))
    local fgen, n = nil, nil
    if last then fgen, n = string.match(last, "^END (%d+) (%d+)$") end
    if not gen or tonumber(fgen) ~= gen or tonumber(n) ~= #lines then return false end
    return { gen = gen, lines = lines }
end

-- The bucket's current copy { gen, side } (side nil: nothing written yet), or nil plus "CORRUPT" when both copies are
-- there and neither is complete: its records are left as they are for an admin. A lone incomplete copy is an
-- unfinished first write. After the first look only this server writes the files, so the answer is kept.
local function state(b)
    local bk = buckets[b]
    if bk then
        if bk.corrupt then return nil, "CORRUPT" end
        return bk
    end
    local a, c = readCopy(b, "a"), readCopy(b, "b")
    if a and (not c or a.gen > c.gen) then
        bk = { gen = a.gen, side = "a" }
    elseif c then
        bk = { gen = c.gen, side = "b" }
    elseif a == false and c == false then
        M.log("bucket " .. b .. ": neither copy is complete, its records stay untouched until an admin fixes the files")
        buckets[b] = { corrupt = true }
        return nil, "CORRUPT"
    else
        if a == false or c == false then M.log("bucket " .. b .. ": ignored an unfinished first write") end
        bk = { gen = 0 }
    end
    buckets[b] = bk
    return bk
end

local function currentLines(b, bk)
    if not bk.side then return {} end
    local copy = readCopy(b, bk.side)
    if not copy or copy.gen ~= bk.gen then return nil end -- changed behind the server's back
    return copy.lines
end

local function find(lines, capsuleId)
    local prefix = tostring(capsuleId) .. " "
    for _, line in ipairs(lines) do
        if string.sub(line, 1, #prefix) == prefix then return string.sub(line, #prefix + 1) end
    end
    return nil
end

-- Writes bucket b with `changes` (capsuleId -> record json, or false to drop it) into the older copy and reads it
-- back. Returns true, or nil plus "CORRUPT" / "WRITE_FAILED" (getFileWriter swallows I/O errors).
local function rewrite(b, changes)
    local bk, why = state(b)
    if not bk then return nil, why end
    local lines = currentLines(b, bk)
    if not lines then return nil, "CORRUPT" end
    local gen = bk.gen + 1
    local out, done = { "MVC1 " .. gen }, {}
    for _, line in ipairs(lines) do
        local id = tonumber(string.match(line, "^(%-?%d+) "))
        local change = id and changes[id]
        if change == nil then
            out[#out + 1] = line
        else
            done[id] = true
            if change then out[#out + 1] = tostring(id) .. " " .. change end
        end
    end
    for id, change in pairs(changes) do
        if change and not done[id] then out[#out + 1] = tostring(id) .. " " .. change end
    end
    out[#out + 1] = "END " .. gen .. " " .. (#out - 1)
    local text = table.concat(out, "\n")
    local side = bk.side == "a" and "b" or "a"
    local file = Store.path(b, side)
    local w = getFileWriter(file, true, false)
    if not w then return nil, "WRITE_FAILED" end
    local ok = pcall(function()
        w:write(text)
        w:close()
    end)
    if not ok or readText(file) ~= text then return nil, "WRITE_FAILED" end
    bk.gen, bk.side = gen, side
    return true
end

-- fn(capsuleId, snap, written, quiet) after every successful read (written = false) and write (written = true): the
-- admin index follows both, the query cache invalidation only loud writes (quiet: a sighting, nothing players see).
-- A failing listener never breaks the Store.
Store.listeners = {}

local function remember(capsuleId, snap, written, quiet)
    status[capsuleId] = { state = snap.state, settled = snap.settled == true, sealed = snap.sealed, seen = snap.seen,
        light = snap.light == true, trade = type(snap.escrow) == "table" and snap.escrow.active == true }
    for _, fn in ipairs(Store.listeners) do
        local ok, err = pcall(fn, capsuleId, snap, written, quiet)
        if not ok then M.log("store listener failed: " .. tostring(err)) end
    end
end

-- Unsettled and not waiting to settle in this run: written right before a crash. VOID is final either way.
-- Works on a snapshot and on a Store.status entry.
function Store.uncertain(capsuleId, snap)
    return snap.state ~= "VOID" and snap.settled ~= true and pending[capsuleId] == nil
end

-- The capsule's cargo is a second copy: the spawned car was committed with it (UNPACKED, settled) or the original
-- car never left (VOID). Works on a snapshot and on a Store.status entry.
function Store.isStale(snap)
    return snap.state == "VOID" or (snap.state == "UNPACKED" and snap.settled == true)
end

-- Returns snap, or nil plus "NO_SNAPSHOT" / "CORRUPT". The first uncertain read of a run is logged for admins.
-- A record whose last event is newer than two settle windows is being written right now (the index loads inside
-- Store.write before the caller schedules the settle), not a crash leftover: no log for it.
function Store.read(capsuleId)
    local b = Store.bucketOf(capsuleId)
    local bk, bwhy = state(b)
    if not bk then return nil, bwhy end
    local lines = currentLines(b, bk)
    if not lines then return nil, "CORRUPT" end
    local text = find(lines, capsuleId)
    if not text then return nil, "NO_SNAPSHOT" end
    local snap, err = Json.decode(text)
    if type(snap) ~= "table" then
        M.log("record " .. tostring(capsuleId) .. " unreadable: " .. tostring(err))
        return nil, "CORRUPT"
    end
    remember(capsuleId, snap)
    if Store.uncertain(capsuleId, snap) and not warned[capsuleId] then
        local h = snap.history
        local last = h and h[#h] and tonumber(h[#h].t) or 0
        if getTimestampMs() - last > 2 * Store.SETTLE_MS then
            warned[capsuleId] = true
            local line = M.LOG_PREFIX .. "UNCERTAIN capsule=" .. tostring(capsuleId) .. " state=" .. tostring(snap.state)
                .. " (written right before a crash; an admin has to resolve it)"
            writeLog("PackThrow", line)
            print(line)
        end
    end
    return snap
end

-- Cached { state, settled, sealed, seen, light, trade } for the guard's scans: the record is read once, then every
-- read and write refreshes it. false when there is no readable record.
function Store.status(capsuleId)
    local st = status[capsuleId]
    if st == nil then
        if not Store.read(capsuleId) then status[capsuleId] = false end
        st = status[capsuleId]
    end
    return st
end

-- Writes the record into its bucket and reads it back. Returns true, or nil plus a reason ("MODDATA_UNSUPPORTED"
-- with the bad path, "WRITE_FAILED", "CORRUPT"). quiet: see Store.listeners.
function Store.write(capsuleId, snap, quiet)
    local text, bad = Json.encode(snap)
    if not text then return nil, "MODDATA_UNSUPPORTED", bad end
    local ok, why = rewrite(Store.bucketOf(capsuleId), { [capsuleId] = text })
    if not ok then
        M.log("record " .. tostring(capsuleId) .. " not written: " .. tostring(why))
        return nil, why
    end
    remember(capsuleId, snap, true, quiet)
    return true
end

-- Drops records (retention), one rewrite per bucket. Returns the ids that are gone; their status, pending settle and
-- ModData mark go with them.
function Store.drop(ids)
    local byBucket = {}
    for _, id in ipairs(ids) do
        local b = Store.bucketOf(id)
        byBucket[b] = byBucket[b] or {}
        byBucket[b][id] = false
    end
    local gone = {}
    for b, changes in pairs(byBucket) do
        if rewrite(b, changes) then
            for id in pairs(changes) do
                status[id], warned[id], pending[id] = nil, nil, nil
                Store.unmark(id)
                gone[#gone + 1] = id
            end
        end
    end
    return gone
end

-- Bucket b's current generation as this run knows it (0: nothing written), nil when the bucket is unreadable.
function Store.gen(b)
    local bk = state(b)
    return bk and bk.gen
end

-- Highest generation in the headers of bucket b's copies (first lines only). Completeness is checked when the bucket
-- is read; the index only uses this to see which buckets changed since its last flush.
function Store.headGen(b)
    local g = 0
    for _, side in ipairs({ "a", "b" }) do
        local r = getFileReader(Store.path(b, side), false)
        if r then
            local head = r:readLine()
            r:close()
            g = math.max(g, tonumber(head and string.match(head, "^MVC1 (%d+)$")) or 0)
        end
    end
    return g
end

-- Every record in bucket b, decoded: { [capsuleId] = snap }, and the bucket's generation; or nil plus "CORRUPT".
function Store.records(b)
    local bk, why = state(b)
    if not bk then return nil, why end
    local lines = currentLines(b, bk)
    if not lines then return nil, "CORRUPT" end
    local out = {}
    for _, line in ipairs(lines) do
        local id, text = string.match(line, "^(%-?%d+) (.*)$")
        local snap = text and Json.decode(text)
        if type(snap) == "table" then out[tonumber(id)] = snap end
    end
    return out, bk.gen
end

-- The record settles SETTLE_MS from now (pack, unpack, restore, release).
function Store.schedule(capsuleId)
    pending[capsuleId] = getTimestampMs() + Store.SETTLE_MS
end

-- Writes settled = true (read back). It leaves `pending` either way: a record that could not be marked is uncertain.
function Store.settle(capsuleId)
    local snap, why = Store.read(capsuleId)
    pending[capsuleId] = nil
    if not snap then
        M.log("settle " .. tostring(capsuleId) .. " failed: " .. tostring(why))
        return nil, why
    end
    if snap.settled == true then return true end
    snap.settled = true
    local ok, werr = Store.write(capsuleId, snap)
    if not ok then
        M.log("settle " .. tostring(capsuleId) .. " failed: " .. tostring(werr))
        return nil, werr
    end
    print(M.LOG_PREFIX .. "SETTLED capsule=" .. tostring(capsuleId) .. " state=" .. tostring(snap.state))
    return true
end

-- Settles every record that is due. Called every tick (Guard.lua).
function Store.settleDue(now)
    local due
    for id, at in pairs(pending) do
        if at <= now then
            due = due or {}
            due[#due + 1] = id
        end
    end
    if not due then return end
    for _, id in ipairs(due) do Store.settle(id) end
end

-- ---------------------------------------------------------------- unpack marks (ModData)

local function marks()
    local md = ModData.getOrCreate(Store.MODDATA)
    if type(md.ended) ~= "table" then md.ended = {} end
    return md.ended
end

function Store.mark(capsuleId) marks()[capsuleId] = true end
function Store.unmark(capsuleId) marks()[capsuleId] = nil end
function Store.marked(capsuleId) return marks()[capsuleId] == true end

-- ---------------------------------------------------------------- cars and sightings

-- Events that put a car somewhere. RESOLVED also names the car, but its x/y/z are where the admin stood
-- (vcap-admin-1010s restored the car at the admin's square after a "missing" verdict).
local PLACES_CAR = { PACKED = true, UNPACKED = true, RESTORED = true }

-- The last history entry that placed the record's vehicle (`car`, vehicles.db id) or animal (`animal`, its animal id):
-- PACKED -> the original, UNPACKED/RESTORED -> the spawned one.
function Store.recordedCar(snap)
    local h = snap.history or {}
    for i = #h, 1, -1 do
        if PLACES_CAR[h[i].ev] and (h[i].car ~= nil or h[i].animal ~= nil) then return h[i] end
    end
    return {}
end

Store.ANIMAL_RADIUS = 30 -- squares around the recorded spot searched for the record's animal (it wanders off)

-- A loaded animal by animal id within `radius` squares of (x, y) on floor z (default 0). Animal ids are not unique
-- (Rand.Next(10000) at birth, IsoAnimal.java:1509) and kept by restore, so this only answers "is that animal still
-- around here"; unloaded squares are skipped. SP has no AnimalInstanceManager, so squares are scanned on both.
function Store.findLoadedAnimal(animalId, x, y, radius, z)
    if type(animalId) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then return nil end
    local cell = getCell()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(x + dx, y + dy, z or 0)
            local list = sq and sq:getAnimals()
            for i = 0, (list and list:size() or 0) - 1 do
                local a = list:get(i)
                if a:getAnimalID() == animalId and not a:isDead() then return a end
            end
        end
    end
    return nil
end

-- The record's vehicle or animal when the server has it loaded (where the history last placed it), or nil.
function Store.findRecorded(snap)
    local e = Store.recordedCar(snap)
    if snap.kind == "animal" then
        local id = type(snap.animal) == "table" and snap.animal.animalId or e.animal
        return Store.findLoadedAnimal(id, e.x, e.y, Store.ANIMAL_RADIUS, e.z)
    end
    return Store.findLoadedVehicle(e.car, snap.script)
end

-- A loaded vehicle by vehicles.db id (cell scan, like the towing code: BaseVehicle.java:10346-10351). The script
-- has to match too: vehicles.db reuses the ids of deleted or crash-lost rows (crash-mp vcap-crashc1-1010d: the car
-- thrown after the crash got the packed car's 60).
function Store.findLoadedVehicle(sqlId, script)
    if type(sqlId) ~= "number" or sqlId < 0 then return nil end
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if v:getSqlId() == sqlId and (script == nil or v:getScriptName() == script) then return v end
    end
    return nil
end

-- Last sighting { t, where = "player" | "ground" | "container" | "vehicle", by, x, y, z }. Written (quietly, no
-- history entry) at most every SEEN_MS unless the holder or the kind of place changed, or a capsule off a player
-- moved to another square (a player's own square changes with every step).
function Store.seen(capsuleId, at)
    local st = Store.status(capsuleId)
    if not st then return end
    local now, prev = getTimestampMs(), st.seen
    if prev and now - (tonumber(prev.t) or 0) < Store.SEEN_MS and prev.where == at.where and prev.by == at.by
        and (at.where == "player" or (prev.x == at.x and prev.y == at.y and prev.z == at.z)) then return end
    local snap = Store.read(capsuleId)
    if not snap then return end
    snap.seen = { t = now, where = at.where, by = at.by, x = at.x, y = at.y, z = at.z }
    Store.write(capsuleId, snap, true)
end

-- ---------------------------------------------------------------- events and states

local function where(player, info)
    local e = { t = getTimestampMs(), by = player and player:getUsername() or "-" }
    if info then
        for k, v in pairs(info) do e[k] = v end
    end
    if e.x == nil and player then
        e.x, e.y, e.z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    end
    return e
end

local function logEvent(capsuleId, e, state)
    local line = M.LOG_PREFIX .. e.ev .. " capsule=" .. tostring(capsuleId) .. " state=" .. tostring(state)
        .. " by=" .. tostring(e.by) .. " x=" .. tostring(e.x) .. " y=" .. tostring(e.y) .. " z=" .. tostring(e.z)
        .. " car=" .. tostring(e.car)
    for _, k in ipairs({ "animal", "why", "verdict", "items", "note" }) do
        if e[k] ~= nil then line = line .. " " .. k .. "=" .. tostring(e[k]) end
    end
    writeLog("PackThrow", line)
    print(line)
end

-- Appends a history entry to snap (in memory) and writes the record. info: x, y, z, car, why, verdict, items, note.
function Store.event(capsuleId, snap, ev, player, info)
    local e = where(player, info)
    e.ev = ev
    snap.history = snap.history or {}
    snap.history[#snap.history + 1] = e
    local ok, why = Store.write(capsuleId, snap)
    logEvent(capsuleId, e, snap.state)
    return ok, why
end

local ALLOWED = {
    PACKED = { UNPACKED = true, RESTORED = true, VOID = true },
    UNPACKED = { PACKED = true, RESTORED = true },
}

-- Allowed transitions only; anything else is refused without touching the record. The history entry is `info.ev`
-- or the new state. The new state settles in SETTLE_MS unless `settled` (an admin verdict moves no vehicle).
function Store.setState(capsuleId, snap, to, player, info, settled)
    if not (ALLOWED[snap.state] and ALLOWED[snap.state][to]) then return nil, "BAD_TRANSITION" end
    snap.state = to
    snap.settled = settled and true or nil
    local ok, why = Store.event(capsuleId, snap, info and info.ev or to, player, info)
    if ok then
        if settled then pending[capsuleId] = nil else Store.schedule(capsuleId) end
        if to == "PACKED" then Store.unmark(capsuleId) end
    end
    return ok, why
end

-- Unpack may only start from a PACKED record that is not uncertain; it is marked UNPACKED before the vehicle exists.
-- Returns snap, or nil plus a reason:
--   "STALE" (+ snap): the capsule's cargo is a second copy, the caller hands it to Guard.stale;
--   "UNCERTAIN" / "NOT_PACKED": REJECTED event, the capsule is left alone (its cargo may be the only copy).
function Store.claim(capsuleId, player)
    local snap, why = Store.read(capsuleId)
    if not snap then return nil, why end
    if Store.isStale(snap) then return nil, "STALE", snap end
    local uncertain = Store.uncertain(capsuleId, snap)
    if snap.state ~= "PACKED" or uncertain then
        why = uncertain and "UNCERTAIN" or "NOT_PACKED"
        Store.event(capsuleId, snap, "REJECTED", player, { why = why })
        return nil, why
    end
    snap.state = "UNPACKED"
    snap.settled = nil
    snap.escrow = nil -- an Economy trade's cargo copy (Trade.lua) ends with the capsule
    local ok, werr = Store.write(capsuleId, snap)
    if not ok then return nil, werr end
    Store.schedule(capsuleId)
    Store.mark(capsuleId)
    return snap
end

-- A spawn that did not happen is undone: state and settled go back to `prev` = { state, settled, uncertain }, with
-- event `ev` and the reason in history. An uncertain record stays uncertain; a pending one settles again.
function Store.undo(capsuleId, snap, prev, player, ev, why)
    snap.state = prev.state
    snap.settled = prev.settled and true or nil
    pending[capsuleId] = nil
    local ok, werr = Store.event(capsuleId, snap, ev, player, { why = why })
    if ok and not prev.settled and not prev.uncertain then Store.schedule(capsuleId) end
    if ok and prev.state == "PACKED" then Store.unmark(capsuleId) end
    return ok, werr
end

-- Unpack spawn failed after claim: back to PACKED with the reason in history.
function Store.release(capsuleId, snap, player, why)
    if snap.state ~= "UNPACKED" then return nil, "BAD_TRANSITION" end
    return Store.undo(capsuleId, snap, { state = "PACKED" }, player, "UNPACK_FAILED", why)
end

-- A stale UNPACKED record the world save does not know about (no mark: a crash or a rollback since the unpack) whose
-- spawned car is not loaded: back to uncertain, so an admin checks on site before any cargo is cleared.
function Store.suspect(capsuleId, snap, player)
    snap.settled = nil
    pending[capsuleId] = nil
    return Store.event(capsuleId, snap, "SUSPECT", player, { why = "WORLD_OLDER" })
end

-- Test hook: forget what this run cached about the files (the next look reads them again).
function Store._resetForTests()
    buckets, status, warned, dir = {}, {}, {}, nil
end

return Store
