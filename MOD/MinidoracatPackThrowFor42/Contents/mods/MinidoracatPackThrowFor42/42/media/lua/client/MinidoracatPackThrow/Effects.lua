-- Pack & Throw (client): draw the effects the server announces (server/MinidoracatPackThrow/Fx.lua).
--   pack / unpack: smoke frames, a ~0.2 s flash and a local sound.
--   flight: the capsule flies from the thrower to the landing point in 0.5 s whatever the distance, with a whoosh at
--   the thrower (one clip fits every throw); then it lies there only until its landing has an outcome.
--   Every outcome of a thrown capsule names it by capsuleId (Effects.endFlight): the pack smoke of a capture, the
--   unpack smoke of a throw, or "miss" (a capture that caught nothing, a throw refused at the landing: no sound, no
--   flash). The flight ends then, or when it reaches the ground if still in the air. By square it was not enough: a
--   vehicle's smoke plays on the vehicle's centre square, not where the capsule landed, and two capsules showed for
--   1.5 s (user 2026-10-14/15). REST_MS is only the cap for an outcome that never arrives.
-- The look and the sounds are the capsule's own type (Core M.TYPES): the server knows which capsule it is and sends
-- its index as args.style (Pack.lua, PlayerCommands.lua fly, Throw.lua), so every client draws the same thing. The
-- admin panel can also play one type here only (Effects.preview).
-- Drawn over the world in screen space (isoToScreenX/Y + UIManager.DrawTexture); nothing touches the world, so no
-- zombie reacts (the server's addSound is the only sound zombies hear). Timing is wall clock, not frames.
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
local M = MinidoracatPackThrow
local Effects = { active = {}, played = 0 }
M.Effects = Effects

local FLIGHT_MS, REST_MS = 500, 1500
local CAPSULE_PX, ARC_PX = 40, 90
local DIR = "media/textures/MinidoracatPackThrow/"

local SOUND = { pack = "pack", unpack = "pop", flight = "throw" }
local pending = {} -- { at, args }: plays the preview queued for later
local previews = 0

-- Frames and the flying capsule of a type, loaded when it first plays: only the types in use take texture memory.
local function frames(st)
    if not st.tex then
        st.tex = {}
        for i = 1, st.frames do st.tex[i] = getTexture(DIR .. st.smoke .. i .. ".png") end
        st.sprite = getTexture("media/textures/Item_" .. st.icon .. "Loaded.png")
        st.spriteEmpty = getTexture("media/textures/Item_" .. st.icon .. ".png")
    end
    return st.tex
end

-- No removal inside pairs: Kahlua tables are Java maps.
local function removeAll(ids)
    for _, id in ipairs(ids) do Effects.active[id] = nil end
end

-- args from the server: id, kind, x, y, z (flight: x0, y0, z0 too, capsuleId, and empty = an empty capsule thrown to
-- capture; pack / unpack: capsuleId of the thrown capsule when a throw caused it; miss: capsuleId), style (index into
-- M.TYPES; unknown = cartoon). The preview adds onDone (called when the effect ends).
function Effects.play(args)
    if not args.id or Effects.active[args.id] then return end -- split screen: one copy per message
    if args.kind == "miss" then return Effects.endFlight(args.capsuleId, "miss") end
    local st = M.TYPES[tonumber(args.style)] or M.TYPES[1]
    -- the frames load now, at the throw too, so the pop does not wait for them
    local fx = { kind = args.kind, st = st, tex = frames(st), t0 = getTimestampMs(), x = args.x, y = args.y, z = args.z,
        x0 = args.x0, y0 = args.y0, z0 = args.z0, onDone = args.onDone, empty = args.empty == true,
        capsuleId = args.capsuleId }
    Effects.played = Effects.played + 1
    local sound = st[SOUND[fx.kind] or "pop"]
    if fx.kind ~= "flight" then
        if fx.capsuleId ~= nil then
            Effects.endFlight(fx.capsuleId, fx.kind)
        else -- no thrown capsule named (the admin preview): the flight lying on this very square pops
            local landed = {}
            for id, other in pairs(Effects.active) do
                if other.kind == "flight" and other.capsuleId == nil and math.floor(other.x) == math.floor(fx.x)
                    and math.floor(other.y) == math.floor(fx.y) then
                    landed[#landed + 1] = id
                end
            end
            removeAll(landed)
        end
        local x, y, z = math.floor(fx.x), math.floor(fx.y), math.floor(fx.z)
        local c = st.flash
        getCell():addLamppost(IsoLightSource.new(x, y, z, c[1], c[2], c[3], 8, 6))
        getSoundManager():PlayWorldSoundImpl(sound, false, x, y, z, 0, 20, 1, false)
    else
        getSoundManager():PlayWorldSoundImpl(sound, false, math.floor(fx.x0), math.floor(fx.y0), math.floor(fx.z0),
            0, 20, 1, false)
    end
    Effects.active[args.id] = fx
end

-- The landing of thrown capsule capsuleId has an outcome (why: "miss", "pack" or "unpack"): its flight skips the rest
-- of REST_MS. Returns how long it had been flying (ms), or nil when no such flight is drawn here.
function Effects.endFlight(capsuleId, why)
    if capsuleId == nil then return nil end
    local now, age = getTimestampMs(), nil
    for _, fx in pairs(Effects.active) do
        if fx.kind == "flight" and fx.capsuleId == capsuleId then
            fx.noRest = true
            age = now - fx.t0
        end
    end
    if age then M.log("FX end capsule=" .. tostring(capsuleId) .. " by=" .. tostring(why) .. " flightAge=" .. age) end
    return age
end

-- How long an effect is drawn: a flight flies, then rests until its outcome (REST_MS at most); smoke plays its frames.
function Effects.lifetime(fx)
    if fx.kind == "flight" then return FLIGHT_MS + (fx.noRest and 0 or REST_MS) end
    return fx.st.frameMs * fx.st.frames
end

-- The admin panel's preview, on this client only: a capsule of type n (index into M.TYPES) thrown from the player to
-- (x, y, z) (its whoosh and flight, then the pop, the flash and the smoke); onDone() when the smoke is gone.
function Effects.preview(n, player, x, y, z, onDone)
    previews = previews + 1
    local id = "preview" .. previews
    Effects.play({ id = id .. "f", kind = "flight", style = n, x0 = player:getX(), y0 = player:getY(),
        z0 = player:getZ(), x = x, y = y, z = z })
    pending[#pending + 1] = { at = getTimestampMs() + FLIGHT_MS,
        args = { id = id .. "u", kind = "unpack", style = n, x = x, y = y, z = z, onDone = onDone } }
end

local function drawSmoke(p, fx, age)
    local st = fx.st
    local tex = fx.tex[math.floor(age / st.frameMs) + 1]
    if not tex then return end
    local w = st.px / getCore():getZoom(p)
    local sx, sy = isoToScreenX(p, fx.x, fx.y, fx.z), isoToScreenY(p, fx.x, fx.y, fx.z)
    UIManager.DrawTexture(tex, sx - w / 2, sy - w * st.anchor, w, w, 1)
end

local function drawFlight(p, fx, age)
    local sprite = fx.empty and fx.st.spriteEmpty or fx.st.sprite
    if not sprite then return end
    local t = math.min(age / FLIGHT_MS, 1)
    local x, y, z = fx.x0 + (fx.x - fx.x0) * t, fx.y0 + (fx.y - fx.y0) * t, fx.z0 + (fx.z - fx.z0) * t
    local zoom = getCore():getZoom(p)
    local w = CAPSULE_PX / zoom
    local lift = (4 * t * (1 - t) * ARC_PX + 30 * (1 - t)) / zoom -- arc, leaving from hand height
    local sx, sy = isoToScreenX(p, x, y, z), isoToScreenY(p, x, y, z) - lift
    UIManager.DrawTexture(sprite, sx - w / 2, sy - w / 2, w, w, 1)
end

-- Project Viewpoint (another author's first / third person 3D view): isoToScreenX/Y is the isometric camera's
-- projection, so under its view the pictures land nowhere near the spot. Nothing is drawn then; the sound, the flash
-- and the timing (onDone) stay. Viewpoint.Loot.viewOn is its own "the 3D view is on" (Viewpoint_Build.lua asks the
-- same); pcall: an error from another mod here would throw every frame and leave the effects stuck.
local function view3d()
    local loot = Viewpoint and Viewpoint.Loot
    if not (loot and loot.viewOn) then return false end
    local ok, on = pcall(loot.viewOn)
    return ok and on == true
end

Events.OnPreUIDraw.Add(function()
    local now, done, hide = getTimestampMs(), nil, nil -- hide: asked once a frame, only while something plays
    if #pending > 0 then
        local due = {}
        for i = #pending, 1, -1 do
            if now >= pending[i].at then due[#due + 1] = table.remove(pending, i).args end
        end
        for _, args in ipairs(due) do Effects.play(args) end
    end
    for id, fx in pairs(Effects.active) do
        local age = now - fx.t0
        if age >= Effects.lifetime(fx) then
            done = done or {}
            done[#done + 1] = id
        else
            if hide == nil then hide = view3d() end
            for p = 0, getNumActivePlayers() - 1 do
                if not hide and getSpecificPlayer(p) then
                    if fx.kind == "flight" then drawFlight(p, fx, age) else drawSmoke(p, fx, age) end
                end
            end
        end
    end
    if done then
        for _, id in ipairs(done) do
            local onDone = Effects.active[id].onDone
            Effects.active[id] = nil
            if onDone then onDone() end
        end
    end
end)

return Effects
