-- Pack & Throw: admin index over the records, <Store.dir>/index.json. One row per capsule (state, vehicle,
-- players, times, recorded spot, last sighting); the admin panel pages through it 50 rows at a time so a server never
-- sends more than one page (sendServerCommand caps a packet at ~1 MB).
-- The rows follow every Store read and write (Store.listeners). index.json also keeps each bucket's generation: on
-- load only buckets whose files moved on since the last flush are read again (a crash between a record write and
-- the next flush). The index is derived data: a missing or broken file is rebuilt from every bucket.
-- Retention (Index.prune): closed records older than the sandbox RecordRetentionDays leave their buckets.
if isClient() then return end
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Json"
require "MinidoracatPackThrow/Store"
local M = MinidoracatPackThrow
local Json, Store = M.Json, M.Store
local Index = {}
M.Index = Index

Index.PAGE_SIZE = 50
Index.FLUSH_MS = 1000
-- Rows JSON-encoded per tick while a flush catches up. Each row's text is kept until the row changes, so a flush only
-- encodes what changed; a whole index (after a load) is spread over ticks this way. Encoding all of the live server's
-- 3750 rows in one tick stalled it about 0.5 s (E2E indexflush-sp).
Index.ENCODE_ROWS = 250
Index.UNSEEN_MS = 7 * 86400000 -- the "not seen for a week" filter: packed capsules nobody has been near
Index.STATES = { "PACKED", "UNPACKED", "RESTORED", "VOID" }

local rows       -- capsuleId -> row; nil until loaded
local gens       -- bucket -> generation the rows reflect
local order      -- capsule ids, newest pack first; nil when it has to be rebuilt
local enc        -- capsuleId -> the row's JSON member text ("#<id>":{...}); missing until the next flush encodes it
local dirty, lastFlush, badRow = false, nil, nil

function Index.file() return Store.dir() .. "index.json" end

-- Stable iterative merge sort (the family gate bans the recursive built-in sort: Kahlua depth limits on big inputs).
local function msort(a, less)
    local n = #a
    if n < 2 then return a end
    local src, dst, width = a, {}, 1
    while width < n do
        local i = 1
        while i <= n do
            local mid, hi = math.min(i + width, n + 1), math.min(i + 2 * width, n + 1)
            local l, r, k = i, mid, i
            while l < mid and r < hi do
                if less(src[r], src[l]) then dst[k] = src[r]; r = r + 1 else dst[k] = src[l]; l = l + 1 end
                k = k + 1
            end
            while l < mid do dst[k] = src[l]; l = l + 1; k = k + 1 end
            while r < hi do dst[k] = src[r]; r = r + 1; k = k + 1 end
            i = i + 2 * width
        end
        src, dst = dst, src
        width = width * 2
    end
    return src
end
Index.sort = msort

-- Plain row from a snapshot. `who` is every player name in the history, lower case, comma separated, for search.
-- st: last sighting, or the first event while the capsule has not been seen since. An animal record (kind "animal")
-- has no script: name is the animal's own name, atype / breed name it otherwise (client Info.animalName).
function Index.row(capsuleId, snap)
    local h = type(snap.history) == "table" and snap.history or {}
    local first, last, e = h[1] or {}, h[#h] or {}, Store.recordedCar(snap)
    local names, seen = {}, {}
    local function add(n)
        n = type(n) == "string" and string.lower(n) or nil
        if n and n ~= "" and n ~= "-" and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    add(snap.packedBy)
    for _, ev in ipairs(h) do add(ev.by) end
    local sight = type(snap.seen) == "table" and snap.seen or {}
    local a = snap.kind == "animal" and type(snap.animal) == "table" and snap.animal or nil
    return {
        id = capsuleId, state = snap.state, settled = snap.settled == true, kind = snap.kind,
        script = snap.script, name = a and a.name or snap.name, atype = a and a.type, breed = a and a.breed,
        by = snap.packedBy, t = tonumber(first.t) or 0, lt = tonumber(last.t) or 0, ev = last.ev,
        x = e.x, y = e.y, z = e.z, who = table.concat(names, ","),
        st = tonumber(sight.t) or tonumber(first.t) or 0,
    }
end

local FIELDS = { "state", "settled", "kind", "script", "name", "atype", "breed", "by", "t", "lt", "ev", "x", "y", "z",
    "who", "st" }
local function same(a, b)
    for _, k in ipairs(FIELDS) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- Stores the row of a record just read or written (Store listener) and, after a write, the bucket's new generation.
-- Loads first: a write that lands before anyone opened the panel must not leave index.json with the old state.
function Index.put(capsuleId, snap, written)
    Index.load()
    if written then
        local b = Store.bucketOf(capsuleId)
        gens[b] = Store.gen(b)
        dirty = true
    end
    local row = Index.row(capsuleId, snap)
    local old = rows[capsuleId]
    if old and same(old, row) then return end
    if not old or old.t ~= row.t then order = nil end
    rows[capsuleId], enc[capsuleId] = row, nil
    dirty = true
end

local function readText(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local lines, line = {}, r:readLine()
    while line do
        lines[#lines + 1] = line
        line = r:readLine()
    end
    r:close()
    return table.concat(lines, "\n")
end

-- Rows of bucket b from its records (the bucket moved on since index.json was written, or there is no index).
-- Stale rows are collected first and removed after the traversal.
local function reload(b)
    local recs, gen = Store.records(b)
    if not recs then return false end
    local stale = {}
    for id in pairs(rows) do
        if Store.bucketOf(id) == b and recs[id] == nil then stale[#stale + 1] = id end
    end
    for _, id in ipairs(stale) do rows[id], enc[id] = nil, nil end
    for id, snap in pairs(recs) do rows[id], enc[id] = Index.row(id, snap), nil end
    gens[b] = gen
    return true
end

-- Reads index.json, then compares each bucket's generation (file headers) with the one the rows were built from and
-- reads the buckets that differ. A missing or broken index therefore rebuilds itself from every bucket.
function Index.load()
    if rows then return end
    local text = readText(Index.file())
    local data = text and Json.decode(text)
    rows, gens, enc = {}, {}, {}
    if type(data) == "table" and type(data.rows) == "table" and type(data.gens) == "table" then
        for id, row in pairs(data.rows) do
            if type(id) == "number" and type(row) == "table" then rows[id] = row end
        end
        for b, g in pairs(data.gens) do
            if type(b) == "number" and type(g) == "number" then gens[b] = g end
        end
    elseif text then
        M.log("index unreadable, rebuilding from the record buckets")
    end
    local reloaded = 0
    for b = 0, Store.BUCKETS - 1 do
        if Store.headGen(b) ~= (gens[b] or 0) and reload(b) then reloaded = reloaded + 1 end
    end
    if reloaded > 0 then
        dirty = true
        M.log("index read " .. reloaded .. " bucket(s) again")
    end
    order = nil
end

-- Writes index.json when something changed and FLUSH_MS has passed. Derived data: a failed write only means the next
-- start reads more buckets. Rows without a cached text are encoded first, at most ENCODE_ROWS a tick; the file is
-- written on the tick the last one is done.
function Index.flush(now)
    if not dirty or not rows then return end
    if lastFlush and now >= lastFlush and now - lastFlush < Index.FLUSH_MS then return end
    local n = 0
    for id, row in pairs(rows) do
        if not enc[id] then
            if n >= Index.ENCODE_ROWS then return end
            local text, bad = Json.encode({ [id] = row })
            if not text then
                -- retried every FLUSH_MS, not every tick; logged once per row
                lastFlush = now
                if badRow ~= id then
                    badRow = id
                    M.log("index row " .. tostring(id) .. " cannot be written: " .. tostring(bad))
                end
                return
            end
            enc[id] = string.sub(text, 2, -2)
            n = n + 1
        end
    end
    lastFlush = now
    local gtext = Json.encode(gens)
    local w = gtext and getFileWriter(Index.file(), true, false)
    if not w then return end
    local parts, sep = { '{"v":2,"gens":', gtext, ',"rows":{' }, ""
    for id in pairs(rows) do
        parts[#parts + 1] = sep
        parts[#parts + 1] = enc[id]
        sep = ","
    end
    parts[#parts + 1] = "}}"
    w:write(table.concat(parts))
    w:close()
    dirty, badRow = false, nil
end

-- Closed records (unpacked and settled, restored, void) whose last event is older than `days`: dropped, at most
-- maxBuckets buckets per call so a long backlog is spread over ticks. Packed and uncertain records always stay:
-- they are the only way to restore a vehicle. Returns true when nothing is left to drop.
function Index.prune(now, days, maxBuckets)
    Index.load()
    local cutoff = now - days * 86400000
    local byBucket, count, more = {}, 0, false
    for id, row in pairs(rows) do
        local closed = row.state ~= "PACKED" and not Index.uncertain(row)
        if closed and (row.lt or 0) < cutoff then
            local b = Store.bucketOf(id)
            if byBucket[b] then
                byBucket[b][#byBucket[b] + 1] = id
            elseif count < maxBuckets then
                byBucket[b], count = { id }, count + 1
            else
                more = true
            end
        end
    end
    local dropped = 0
    for b, ids in pairs(byBucket) do
        local gone = Store.drop(ids)
        for _, id in ipairs(gone) do rows[id], enc[id] = nil, nil end
        gens[b] = Store.gen(b)
        dropped = dropped + #gone
    end
    if dropped > 0 then
        order, dirty = nil, true
        local line = M.LOG_PREFIX .. "PRUNED " .. dropped .. " closed record(s) older than " .. days .. " days"
        writeLog("PackThrow", line)
        print(line)
    end
    return not more
end

local function newestFirst(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.id > b.id
end

local function sorted()
    if not order then
        local list = {}
        for _, row in pairs(rows) do list[#list + 1] = row end
        list = msort(list, newestFirst)
        order = {}
        for i, row in ipairs(list) do order[i] = row.id end
    end
    return order
end

function Index.uncertain(row)
    return Store.uncertain(row.id, row)
end

-- A packed capsule nobody has been near for UNSEEN_MS: maybe lost (or stored somewhere nobody visits).
function Index.unseen(row, now)
    return row.state == "PACKED" and now - (row.st or 0) > Index.UNSEEN_MS
end

local function trim(s)
    s = string.gsub(tostring(s or ""), "^%s+", "")
    return string.lower((string.gsub(s, "%s+$", "")))
end

-- Matches the search text against the capsule id (substring) and every player name in its history.
local function matches(row, q)
    if q == "" then return true end
    return string.find(tostring(row.id), q, 1, true) ~= nil or string.find(row.who or "", q, 1, true) ~= nil
end

-- filter = { q = "text", state = "ALL" | "PACKED" | "UNPACKED" | "RESTORED" | "VOID" | "UNCERTAIN" | "UNSEEN" };
-- page from 1. Returns { rows, total, page, pages, counts = { ALL, PACKED, ..., UNCERTAIN, UNSEEN } } where counts
-- cover the search result before the state filter. Rows are copies with `uncertain` filled in.
function Index.page(filter, page, size)
    Index.load()
    filter = type(filter) == "table" and filter or {}
    size = size or Index.PAGE_SIZE
    local q = trim(filter.q)
    local state = filter.state or "ALL"
    local now = getTimestampMs()
    local counts = { ALL = 0, UNCERTAIN = 0, UNSEEN = 0 }
    for _, s in ipairs(Index.STATES) do counts[s] = 0 end
    local hits = {}
    for _, id in ipairs(sorted()) do
        local row = rows[id]
        if row and matches(row, q) then
            local unc, gone = Index.uncertain(row), Index.unseen(row, now)
            counts.ALL = counts.ALL + 1
            if counts[row.state] then counts[row.state] = counts[row.state] + 1 end
            if unc then counts.UNCERTAIN = counts.UNCERTAIN + 1 end
            if gone then counts.UNSEEN = counts.UNSEEN + 1 end
            if state == "ALL" or (state == "UNCERTAIN" and unc) or (state == "UNSEEN" and gone) or row.state == state then
                hits[#hits + 1] = row
            end
        end
    end
    local pages = math.max(1, math.ceil(#hits / size))
    page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
    local out = {}
    for i = (page - 1) * size + 1, math.min(#hits, page * size) do
        local r = hits[i]
        out[#out + 1] = { id = r.id, state = r.state, uncertain = Index.uncertain(r), name = r.name, script = r.script,
            kind = r.kind, atype = r.atype, breed = r.breed, by = r.by, t = r.t, lt = r.lt, ev = r.ev, st = r.st }
    end
    return { rows = out, total = #hits, page = page, pages = pages, counts = counts }
end

-- Test hook: forget everything in memory (the next call loads index.json again).
function Index._resetForTests()
    rows, gens, enc, order, dirty, lastFlush, badRow = nil, nil, nil, nil, false, nil, nil
end

Store.listeners[#Store.listeners + 1] = Index.put
Events.OnTickEvenPaused.Add(function() Index.flush(getTimestampMs()) end)

return Index
