-- Pack & Throw (client): cargo inside a loaded capsule stays there until the vehicle is unpacked. This is the
-- player-facing side only; the server puts back anything that leaves (server/MinidoracatPackThrow/Guard.lua).
--   * every vanilla way of taking an item out (drag, loot all, grab, eat/drink/equip/reload/craft, which all move the
--     item into the main inventory first) is an ISInventoryTransferAction: refuse it and say why;
--   * the context menu of cargo shows only that hint;
--   * capsule containers are not offered to crafting and building (ISInventoryPaneContextMenu.getContainers).
-- Sandbox AllowCargoTakeOut opens the first two for a capsule whose record is a confirmed PACKED one (Rules.cargoOpen);
-- crafting and building still use nothing inside a capsule, and nothing can be put in (MaxItemSize).
-- The inventory and loot windows show no container button for a loaded capsule or sphere whose container is empty.
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
require "MinidoracatPackThrow/Info"
require "TimedActions/ISInventoryTransferAction"
require "ISUI/ISInventoryPaneContextMenu"
local M = MinidoracatPackThrow
local CargoLock = { notices = 0 }
M.CargoLock = CargoLock

local lastHalo = 0
function CargoLock.notify(player)
    CargoLock.notices = CargoLock.notices + 1
    local now = getTimestampMs()
    if player and now - lastHalo > 1500 then
        lastHalo = now
        HaloTextHelper.addBadText(player, getText("IGUI_MinidoracatPackThrow_CargoLocked"))
    end
end

local function takeOut() return M.Rules.sandbox().AllowCargoTakeOut == true end

-- capsuleId -> may its cargo leave, from the last answer. Kept while Info asks again after the server rewrote the
-- record (every take does), so a loot-all queue is not cut off halfway.
local open = {}

-- True when every loaded capsule around `container` lets its cargo out. Closed until the first answer arrives.
function CargoLock.open(container)
    if not takeOut() then return false end
    local holder = container and container:getContainingItem()
    while holder do
        if M.isLoaded(holder) then
            local id = holder:getID()
            local r = M.Info.get(id)
            if r then open[id] = r.ok == true and M.Rules.cargoOpen(r) end
            if open[id] ~= true then return false end
        end
        local c = holder:getContainer()
        holder = c and c:getContainingItem()
    end
    return true
end

local isValid = ISInventoryTransferAction.isValid
function ISInventoryTransferAction:isValid()
    if self.srcContainer and M.isCapsuleContainer(self.srcContainer) and not CargoLock.open(self.srcContainer) then
        CargoLock.notify(self.character)
        return false
    end
    return isValid(self)
end

local getContainers = ISInventoryPaneContextMenu.getContainers
ISInventoryPaneContextMenu.getContainers = function(character)
    return M.withoutCapsules(getContainers(character))
end

Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
    local locked = false
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        if M.inCapsule(item) and not CargoLock.open(item:getContainer()) then locked = true; break end
    end
    if not locked then return end
    context:clear()
    local option = context:addOption(getText("IGUI_MinidoracatPackThrow_CargoLocked"))
    option.notAvailable = true
end)

-- The windows' container buttons (ISInventoryPage.refreshBackpacks): vanilla gives one to every container item held in
-- the hands, lying on the floor around the player, or in a vehicle's seats and trunk. A loaded capsule or sphere whose
-- own container is empty gets none: a sphere never holds anything there, and a capsule packed with sandbox CargoWeight
-- off keeps its cargo in its cargo store (M.cargoStore); the tooltip and the preview list the cargo either way. A
-- capsule with cargo in its container keeps its button. Dropped at "buttonsAdded", before the window picks the shown
-- container and sizes the button column from this list. The buttons after a dropped one move into the slots before
-- them: each takes the place the button with its new index had, so any layout keeps working (vanilla's column,
-- CleanUI's padded one- or two-column grid, whose drag-sort later reuses whatever slots the buttons hold).
Events.OnRefreshInventoryWindowContainers.Add(function(page, state)
    if state ~= "buttonsAdded" then return end
    local list, kept, xs, ys = page.backpacks, {}, {}, {}
    for i, button in ipairs(list) do
        xs[i], ys[i] = button:getX(), button:getY()
        local inv = button.inventory
        local holder = inv and inv:getContainingItem()
        if holder and M.isLoaded(holder) and inv:isEmpty() then
            page.containerButtonPanel:removeChild(button)
            table.insert(page.buttonPool, button)
        else
            kept[#kept + 1] = button
        end
    end
    if #kept == #list then return end
    for i = 1, #list do
        local button = kept[i]
        list[i] = button
        if button then
            button:setX(xs[i])
            button:setY(ys[i])
        end
    end
end)

return CargoLock
