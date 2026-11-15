require "TimedActions/ISBaseTimedAction"
require "MinidoracatPackThrow/Rules"

-- Pack a parked vehicle into the player's empty capsule. The client sends a "pack" intent (with the capsule name in
-- its own language) when it queues this (client/MinidoracatPackThrow/Menu.lua); complete() runs on the server
-- (SP: locally) and checks everything again (MinidoracatPackThrow.Play.pack).
ISPackVehicleAction = ISBaseTimedAction:derive("ISPackVehicleAction")
local M = MinidoracatPackThrow

function ISPackVehicleAction:isValid()
    return self.vehicle ~= nil and self.vehicle:getSquare() ~= nil
        and M.Rules.vehicleWhyNot(self.character, self.vehicle) == nil
end

function ISPackVehicleAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function ISPackVehicleAction:update()
    self.character:faceThisObject(self.vehicle)
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function ISPackVehicleAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function ISPackVehicleAction:complete()
    return M.Play.pack(self.character, self.vehicle, self.typeId)
end

-- MP server: the action was stopped before complete() (cancelled, or the vehicle went: Play.packStopped).
function ISPackVehicleAction:serverStop()
    M.Play.packStopped(self.character, self.vehicle)
end

function ISPackVehicleAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return M.Rules.PACK_SECONDS * 50 -- 1 unit = 20 ms (NetTimedAction.getDuration)
end

-- MP: the server rebuilds the action from these parameters (NetTimedAction.java:36-55); typeId (the capsule type picked
-- in the menu) is SP only, MP sends it with the intent.
function ISPackVehicleAction:new(character, vehicle)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
    o.maxTime = o:getDuration()
    return o
end
