require "TimedActions/ISBaseTimedAction"
require "MinidoracatPackThrow/Core"

-- Release the animal of a loaded Pal Sphere in the player's inventory: a short action, then it appears next to the
-- player (Palworld v0.3.11: no throw; the server picks the square, Rules.releaseSpot). The client sends a "release"
-- intent when it queues this (client/MinidoracatPackThrow/Menu.lua); complete() runs on the server (SP: locally) and
-- checks everything in MinidoracatPackThrow.Play.release.
ISReleaseSphereAction = ISBaseTimedAction:derive("ISReleaseSphereAction")
local M = MinidoracatPackThrow

function ISReleaseSphereAction:isValid()
    return M.isLoaded(self.item) and M.carries(self.character, self.item)
end

function ISReleaseSphereAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Mid")
end

-- MP: server only (LuaTimedActionNew.java:163-170); SP: local.
function ISReleaseSphereAction:complete()
    return M.Play.release(self.character, self.item)
end

function ISReleaseSphereAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 30 -- 1 unit = 20 ms (NetTimedAction.getDuration)
end

-- MP: the server rebuilds the action from the fields named like these parameters (NetTimedAction.java:36-55).
function ISReleaseSphereAction:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end
