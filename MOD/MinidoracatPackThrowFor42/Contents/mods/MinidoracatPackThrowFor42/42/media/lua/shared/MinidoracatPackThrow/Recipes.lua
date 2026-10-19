-- Pack & Throw: crafting empty capsules and Pal Spheres (media/scripts/MinidoracatPackThrow_recipes.txt), off until an
-- admin turns it on: Rules.craftOn (sandbox AllowCraftCapsules / AllowCraftSpheres, and the type switched on).
-- Each type's recipe (t.recipe) names the global MinidoracatPackThrow_craft<id> as both of its hooks:
--   * OnTest: asked for every candidate input as (item, character) on the client, in SP, and again on the server when
--     the craft completes (ISHandcraftAction:performRecipe). A name that does not resolve lets everything through
--     (CraftRecipe.java:1010-1032), so this file is shared and every recipe has its own function.
--   * OnAddToMenu: the vanilla crafting list (ISRecipeScrollingListBox.lua:344-348, ISTiledIconPanel.lua:193-197) calls
--     it through callLuaBool, which looks the name up as a global only (LuaManager.java:5745-5746): no dotted name.
-- Neat Crafting (Workshop 3502080466) draws its own list and never asks OnAddToMenu; every list path there goes
-- through NC_FilterBar:shouldIncludeRecipe (NC_FilterBar.lua:351, 562, 608, 630), wrapped once the game has started
-- (the client loads it after this file). The right-click quick craft asks OnTest (CraftRecipeManager.java:1288).
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
local M = MinidoracatPackThrow
local Recipes = { TYPE = {} } -- recipe name -> type
M.Recipes = Recipes

for _, t in ipairs(M.TYPES) do
    Recipes.TYPE[t.recipe] = t
    _G["MinidoracatPackThrow_craft" .. t.id] = function() return M.Rules.craftOn(t) end
end

-- True for one of these recipes while it may not be crafted; false for every other recipe.
function Recipes.hidden(name)
    local t = Recipes.TYPE[name]
    return t ~= nil and not M.Rules.craftOn(t)
end

function Recipes.wrapNeatCrafting()
    local F = NC_FilterBar
    if type(F) ~= "table" or type(F.shouldIncludeRecipe) ~= "function" or F.packThrowFilter then return false end
    local orig = F.shouldIncludeRecipe
    F.shouldIncludeRecipe = function(self, recipe)
        if recipe ~= nil and Recipes.hidden(recipe:getName()) then return false end
        return orig(self, recipe)
    end
    F.packThrowFilter = true
    return true
end
Events.OnGameStart.Add(Recipes.wrapNeatCrafting)

return Recipes
