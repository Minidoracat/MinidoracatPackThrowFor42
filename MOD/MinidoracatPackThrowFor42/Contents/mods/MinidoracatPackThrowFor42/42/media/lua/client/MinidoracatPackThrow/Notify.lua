-- Pack & Throw (client): server messages for players (module MinidoracatPackThrow). Effects go to Effects.lua,
-- capsule info to the landing cursor, results become a Toast or a Dialog of the family UI framework
-- (MinidoracatUIFor42, API 1 rev 7: toast + dialog). Without the framework: halo text above the player.
-- SP has no server->client channel; the server code calls M.onServerCommand directly (PlayerCommands.send).
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Effects"
require "MinidoracatPackThrow/Info"
require "MinidoracatPackThrow/Rules"
local okUI = pcall(require, "MinidoracatUI/V1")
local M = MinidoracatPackThrow
local Notify = { shown = {} }
M.Notify = Notify

local function ui()
    local UI = okUI and MinidoracatUI and MinidoracatUI.v1
    if UI and UI.API_MAJOR == 1 and (UI.API_REVISION or 0) >= 7 then return UI end
    return nil
end

-- Update note (framework rev 24, WhatsNew): the first game after an update shows this version's note at the top right.
-- The release train's ready reads this block with a regex: literal strings, one field per line; since moves to the new
-- version only when a release writes a new note (family conventions.md, in-game update note).
pcall(require, "MinidoracatUI/WhatsNew")
do
    local UI = ui()
    if UI and UI.API_REVISION >= 24 and UI.CAPABILITIES.whatsNew and UI.WhatsNew then
        UI.WhatsNew.register({
            modId = "MinidoracatPackThrowFor42",
            since = "0.5.4",
            name = "UI_MinidoracatPackThrow_OptionsTitle",
            text = "IGUI_MinidoracatPackThrow_WhatsNew",
        })
    end
end

local function remember(kind, title, text)
    Notify.shown[#Notify.shown + 1] = { kind = kind, title = title, text = text }
    M.log("NOTIFY " .. kind .. " " .. tostring(title) .. " | " .. tostring(text))
end

-- holdMs: how long it stays (framework default 3 s); failures the player must act on go to Notify.dialog instead.
-- No text: the title alone is the message, without a title bar (the toast needs a message; title and message both set
-- showed the line twice, e.g. "Unpacked: X" with ReturnEmptyCapsule off).
function Notify.toast(title, text, bad, holdMs)
    remember(bad and "toast-bad" or "toast", title, text)
    local UI = ui()
    if UI and UI.CAPABILITIES.toast then
        UI.Toast.show({ title = text and title or nil, message = text or title, maxLines = 6, holdMs = holdMs })
        return
    end
    local player = getPlayer()
    if player then
        local line = text and (title .. " " .. text) or title
        if bad then HaloTextHelper.addBadText(player, line) else HaloTextHelper.addGoodText(player, line) end
    end
end

function Notify.dialog(title, text)
    remember("dialog", title, text)
    local UI = ui()
    if UI and UI.CAPABILITIES.dialog then
        Notify.current = UI.Dialog.show({ title = title, text = text, width = 420, opaque = true,
            confirmText = getText("IGUI_MinidoracatPackThrow_GotIt") })
        return
    end
    local player = getPlayer()
    if player then HaloTextHelper.addBadText(player, title) end
end

-- Display name of a vehicle script in this client's language (same rule as ISVehicleMenu.getVehicleDisplayName).
function Notify.vehicleName(scriptName)
    local sc = scriptName and getScriptManager():getVehicle(scriptName)
    if not sc then return scriptName or "?" end
    local name = sc:getName()
    local text = getTextOrNull("IGUI_VehicleName" .. (sc:getCarModelName() or name))
    if string.find(name, "Burnt") then
        local unburnt = getTextOrNull("IGUI_VehicleName" .. string.gsub(name, "Burnt", ""))
        text = getText("IGUI_VehicleNameBurntCar", unburnt or text or name)
    end
    return text or name
end

-- Player-facing text for a reason code (cursor, dialogs, toasts). release: the code is about a landing spot (throw,
-- press, admin restore, a sphere's release), worded by Why_<code>_RELEASE where there is one (SAFEHOUSE: packing says
-- "in someone else's safehouse", landing "the spot is in someone else's safehouse"); vehicle: the target is a vehicle,
-- worded by Why_<code>_VEHICLE where there is one (WRONG_ITEM: a capsule at an animal says "use a Pal Sphere", a
-- sphere at a vehicle "a Pal Sphere can't take vehicles").
function Notify.reason(code, release, vehicle)
    local key = "IGUI_MinidoracatPackThrow_Why_" .. tostring(code)
    return (release and getTextOrNull(key .. "_RELEASE")) or (vehicle and getTextOrNull(key .. "_VEHICLE"))
        or getTextOrNull(key) or getText("IGUI_MinidoracatPackThrow_Why_OTHER", tostring(code))
end

-- Whether this player may pack this vehicle, and the permission text for the menu row and the refusal toast.
-- VehicleManager decides for a claimed vehicle (its Tow permission, Rules.mayPack); its own wording covers rental
-- locks, quarantine, paused faction shares, and an admin whose override is off (every override use is logged there).
local PERM_TEXT = { VM = "PermOwner", SHARED = "PermShared", KEY = "PermKey", ADMIN = "PermAdmin", ANY = "PermAny" }
local VM_REASON = { RENT_LOCKED = true, QUARANTINED = true, FACTION_PAUSED = true, NOT_READY = true }
function Notify.permission(player, vehicle)
    local may, mode, why = M.Rules.mayPack(player, vehicle)
    local tow = getTextOrNull("IGUI_MVM_ActionShort_TOW") or "Tow"
    if may then return true, getText("IGUI_MinidoracatPackThrow_" .. PERM_TEXT[mode], tow) end
    if mode == "VM" then
        local own = VM_REASON[why] and getTextOrNull("IGUI_MVM_Reason_" .. tostring(why))
            or M.Rules.isAdmin(player) and getTextOrNull("IGUI_MVM_ProtectedAdmin")
        if own then return false, own end
    end
    return false, getText("IGUI_MinidoracatPackThrow_" .. PERM_TEXT[mode] .. "No", tow)
end

-- local time like the admin panel (Kahlua's os.date is UTC: 06:28 for a 14:28 restore in UTC+8)
local function stamp(t)
    return t and M.Info.date(t) or "?"
end

-- One rich-text tooltip row (ISToolTip description): a check or a red mark, then the text in the player's
-- good / bad highlight colour. Vanilla icons instead of check / cross glyphs: those are missing from vanilla fonts.
local TICK, MISS = "media/ui/Tick_Mark-10.png", "media/ui/Moodle_internal_minus_red.png"
function Notify.row(ok, text)
    local c = ok and getCore():getGoodHighlitedColor() or getCore():getBadHighlitedColor()
    return string.format(" <IMAGE:%s,12,12> <RGB:%.2f,%.2f,%.2f> %s <LINE> ", ok and TICK or MISS,
        c:getR(), c:getG(), c:getB(), text)
end

-- The catch chance rows of a catch menu or capture tooltip for a wild animal with a sphere of type t (white, no mark):
-- "Chance: 77%" and, under it, the non-zero bonuses ("Mega Sphere +15 · Injured +12"), from Rules.captureChance; or
-- "" (a tame animal, or wild ones switched off: WILD_OFF says so). With WildCaptureFailConsumes on and a miss possible
-- (below 100) the first row says a miss takes the sphere. The client's own view of the animal and its SandboxVars (the
-- server sends every applied change); the server's numbers at the catch decide.
function Notify.chanceRows(player, animal, t)
    local c = animal and M.Rules.captureChance(player, animal, t and t.id)
    if not c or c.total <= 0 then return "" end
    local key = (c.total < 100 and M.Rules.wildFailConsumes()) and "IGUI_MinidoracatPackThrow_WildChanceGone"
        or "IGUI_MinidoracatPackThrow_WildChance"
    local text = " <RGB:1,1,1> " .. getText(key, c.total) .. " <LINE> "
    if #c.factors == 0 then return text end
    local parts = {}
    for i, f in ipairs(c.factors) do
        local name = f[1] == "Tier" and t and M.Info.itemName(t.empty)
            or getText("IGUI_MinidoracatPackThrow_Factor_" .. f[1])
        parts[i] = getText("IGUI_MinidoracatPackThrow_ChanceFactor", name, f[2])
    end
    return text .. " <RGB:0.85,0.85,0.85> " .. table.concat(parts, getText("IGUI_MinidoracatPackThrow_FactorSep"))
        .. " <LINE> "
end

-- Why a pack or a capture failed: a wild animal that broke free says the chance it had (and that the sphere went
-- with it: consumed); a refused permission the reason the vehicle menu row gives (VehicleManager's wording included).
local function failure(args)
    if args.why == "ESCAPED" then
        return getText(args.consumed and "IGUI_MinidoracatPackThrow_EscapedGone" or "IGUI_MinidoracatPackThrow_Why_ESCAPED",
            args.chance)
    end
    local vehicle = args.why == "NOT_ALLOWED" and args.vehicleId and getVehicleById(args.vehicleId)
    if vehicle then return select(2, Notify.permission(getPlayer(), vehicle)) end
    return Notify.reason(args.why, false, args.kind ~= "animal")
end

local Handlers = {}

function Handlers.fx(args) M.Effects.play(args) end

function Handlers.capsuleInfo(args)
    if M.ThrowCursor then M.ThrowCursor.onInfo(args) end
end

-- A refused pack stays until the player closes it (a toast faded in 3 s while they looked elsewhere; review).
function Handlers.packed(args)
    if args.ok then return end
    Notify.dialog(getText(args.kind == "animal" and "IGUI_MinidoracatPackThrow_PackAnimalFailed"
        or "IGUI_MinidoracatPackThrow_PackFailed"), failure(args))
end

-- A thrown empty capsule (mode "capture"): a toast either way; a miss says why and where the capsule went. The reason
-- goes in the message, which wraps freely: the toast title wraps to two lines at most (UI rev 19, the second ends in
-- "...") and not at all before rev 19, and the French reason ran past the toast's edge (vcap-capture-fr-1013r).
local function captured(args)
    if args.ok then
        local name = args.kind == "animal" and M.Info.animalName(args.animal) or Notify.vehicleName(args.script)
        Notify.toast(getText("IGUI_MinidoracatPackThrow_Captured", name), getText("IGUI_MinidoracatPackThrow_CapturedHere"))
        return
    end
    -- a consumed capsule is neither on the ground nor kept: the reason already says it is gone
    local text = args.consumed and failure(args)
        or getText(args.dropped and "IGUI_MinidoracatPackThrow_CaptureDropped" or "IGUI_MinidoracatPackThrow_CaptureKept",
            failure(args))
    Notify.toast(getText("IGUI_MinidoracatPackThrow_CaptureFailed"), text, true, 8000)
end

-- A landing (throw, press) or a Pal Sphere's release. A release says "Released: <name>" and names the tier that came
-- back; a refused one (NO_ROOM, IN_VEHICLE, a spot blocked at the last moment, or a loaded sphere sent to be thrown or
-- pressed: WRONG_ITEM) its own title.
function Handlers.landed(args)
    if args.mode == "capture" then return captured(args) end
    local animal = args.kind == "animal" and "Animal" or ""
    local release = args.mode == "release" or args.why == "WRONG_ITEM"
    if args.ok then
        local name = animal ~= "" and M.Info.animalName(args.animal) or Notify.vehicleName(args.script)
        local t = M.TYPE_BY_ID[tostring(args.type)]
        local back = args.returned and (release and t and getText("IGUI_MinidoracatPackThrow_SphereBack",
            M.Info.itemName(t.empty)) or getText("IGUI_MinidoracatPackThrow_EmptyBack")) or nil
        Notify.toast(getText(release and "IGUI_MinidoracatPackThrow_Released" or "IGUI_MinidoracatPackThrow_Unpacked", name),
            back)
    elseif args.why == "BLOCKED" and release then
        Notify.dialog(getText("IGUI_MinidoracatPackThrow_ReleaseFailed"), Notify.reason(args.reason, true))
    elseif args.why == "BLOCKED" then
        local body = args.mode == "press" and "IGUI_MinidoracatPackThrow_BlockedPress"
            or "IGUI_MinidoracatPackThrow_BlockedThrow"
        Notify.dialog(getText("IGUI_MinidoracatPackThrow_BlockedTitle"), getText(body, Notify.reason(args.reason)))
    elseif args.why == "UNCERTAIN" then
        Notify.dialog(getText("IGUI_MinidoracatPackThrow_UncertainTitle"),
            getText("IGUI_MinidoracatPackThrow_UncertainBody", tostring(args.capsuleId)))
    elseif args.why == "NOT_PACKED" or args.why == "CLEARED" then
        local state = getTextOrNull("IGUI_MinidoracatPackThrow_State_" .. tostring(args.state))
            or getText("IGUI_MinidoracatPackThrow_State_UNPACKED")
        Notify.dialog(getText("IGUI_MinidoracatPackThrow_UsedTitle"),
            getText("IGUI_MinidoracatPackThrow_UsedBody", stamp(args.t), state, tostring(args.capsuleId)))
    else
        local text = Notify.reason(args.why, true)
        if args.feet and args.dropped then text = getText("IGUI_MinidoracatPackThrow_DroppedAtFeet", text) end
        Notify.dialog(getText(release and "IGUI_MinidoracatPackThrow_ReleaseFailed"
            or "IGUI_MinidoracatPackThrow_UnpackFailed"), text)
    end
end

function M.onServerCommand(command, args)
    local fn = Handlers[command]
    if fn then fn(args or {}) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M.MODULE then return end
    M.onServerCommand(command, args)
end)

return Notify
