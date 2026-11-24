require "TimedActions/ISBaseTimedAction"
require "MinidoracatPackThrow/Core"

-- Throw a loaded capsule at (x, y, z), or an empty one at an animal or a vehicle to capture it (the server tells the
-- two apart by the item; a capture's target goes with the "capture" intent, SP: self.capture). Plays the vanilla
-- Molotov clip through our own action node (AnimSets/player/actions/MinidoracatPackThrowThrow.xml): the vanilla Throw
-- node only matches Weapon=throwing, and a capsule is a container, not a HandWeapon.
-- CapsuleRelease (30%) is when the capsule leaves the hand (nearby clients see it fly); CapsuleEnd (75%) ends
-- the action. The dedicated server plays no animations, so serverStart emulates both events with the same
-- timing (emulateAnimEventOnce, LuaManager.java:12237; same approach as Workshop 3809762635).
-- Only complete() changes the world (server, or SP): an action stopped after the release never gets there.
-- The client sends a "throw" intent when it queues this (client/MinidoracatPackThrow/Menu.lua).
ISThrowCapsuleAction = ISBaseTimedAction:derive("ISThrowCapsuleAction")

ISThrowCapsuleAction.ANIM = "MinidoracatPackThrowThrow"

-- Bob_AttackThrowMolotov lasts 7040 ticks at 4800 ticks/s; the node plays it at m_SpeedScale 0.8.
local ANIM_MS = 7040 / 4800 / 0.8 * 1000
local RELEASE_PC, END_PC = 0.3, 0.75
local M = MinidoracatPackThrow

local function side()
    if isServer() then return "server" end
    return isClient() and "client" or "sp"
end

function ISThrowCapsuleAction:isValid()
    return (M.isLoaded(self.item) or M.isEmpty(self.item)) and M.carries(self.character, self.item)
end

-- faceLocation sets the direction at once, but the body (animAngle) turns only when the gap is more than the waist
-- twist covers (IsoGameCharacter.shouldBeTurning: excess over getMaxTwist(), 15 deg, above 1 deg; the turn then runs
-- until the gap is under 1 deg). The clip waits for that turn while the server emulates the release from start():
-- wait for it (E2E throw-mp 1010c: 40 deg late = release 250 ms late, 170 deg = 680 ms; server completed before the
-- client clip reached CapsuleEnd). A gap the twist covers never turns the body, so it must not be waited for: a
-- 5 deg test hung there until the cap (user report 2026-10-16: 1-2 s with the target slightly off the facing).
-- shouldBeTurning lags a frame behind a new direction (the anim player updates after this), hence the gap test.
-- The throw cursor already turns the standing player toward the aimed square (ThrowCursor Cursor:face), so a turn is
-- rare here; it stays for a click while walking and for E2E queues. The 1.5 s cap only keeps an odd state from
-- blocking the queue.
function ISThrowCapsuleAction:waitToStart()
    local c = self.character
    c:faceLocation(self.x, self.y)
    self.waitMs = self.waitMs or getTimestampMs()
    if getTimestampMs() - self.waitMs > 1500 then return false end
    local gap = math.abs(c:getAnimAngle() - c:getDirectionAngle()) % 360
    return c:shouldBeTurning() or math.min(gap, 360 - gap) > c:getMaxTwist() + 1
end

function ISThrowCapsuleAction:update()
    self.character:faceLocation(self.x, self.y)
end

function ISThrowCapsuleAction:start()
    self.startMs = getTimestampMs()
    self:setActionAnim(ISThrowCapsuleAction.ANIM)
    self:setOverrideHandModels(self.item, self.character:getSecondaryHandItem())
end

function ISThrowCapsuleAction:serverStart()
    self.startMs = getTimestampMs()
    emulateAnimEventOnce(self.netAction, math.floor(ANIM_MS * RELEASE_PC), "CapsuleRelease", nil)
    emulateAnimEventOnce(self.netAction, math.floor(ANIM_MS * END_PC), "CapsuleEnd", nil)
end

function ISThrowCapsuleAction:animEvent(event, parameter)
    if event == "CapsuleRelease" then
        if self.released then return end
        self.released = getTimestampMs()
        M.log(string.format("release side=%s player=%s item=%d sinceStart=%d ts=%d", side(),
            self.character:getUsername(), self.item and self.item:getID() or -1,
            self.released - (self.startMs or self.released), self.released))
        if not isServer() then
            self:setOverrideHandModels(nil, self.character:getSecondaryHandItem())
        end
        if not isClient() and M.Play then M.Play.released(self) end
    elseif event == "CapsuleEnd" and self.maxTime == -1 then
        if isServer() then
            self.netAction:forceComplete()
        else
            self:forceComplete()
        end
    end
end

-- MP: server only (LuaTimedActionNew.java:163-170); SP: local.
function ISThrowCapsuleAction:complete()
    return M.Play.throw(self)
end

function ISThrowCapsuleAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return -1 -- ends at CapsuleEnd
end

-- MP: the server rebuilds the action from the fields named like these parameters (NetTimedAction.java:36-55).
function ISThrowCapsuleAction:new(character, item, x, y, z)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.x, o.y, o.z = x, y, z
    o.stopOnWalk = true
    o.stopOnRun = true
    o.useProgressBar = false
    o.maxTime = o:getDuration()
    return o
end
