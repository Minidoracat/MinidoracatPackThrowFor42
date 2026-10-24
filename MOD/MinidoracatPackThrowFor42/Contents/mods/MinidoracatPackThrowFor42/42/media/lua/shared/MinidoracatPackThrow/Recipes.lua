-- Pack & Throw: crafting empty capsules and Pal Spheres (media/scripts/MinidoracatPackThrow_recipes.txt). Every type has
-- three recipes, one per level (Recipes.name: t.recipe .. Easy | Standard | Hard), all in the craft category
-- MinidoracatPackThrow (Recipes.CATEGORY; name IGUI_CraftingCategories_MinidoracatPackThrow, Neat Crafting's icon
-- media/ui/CategoryIcon/MinidoracatPackThrow.png). Sandbox Craft<id> picks the one level players get, or none, and a
-- type switched off is never crafted (user 2026-10-25, design packthrow-craft-1025): Rules.craftLevel / Rules.craftOn
-- decide, and every gate below asks them.
-- Each recipe names the global MinidoracatPackThrow_craft<id><Level> as both of its hooks:
--   * OnTest: asked for every candidate input as (item, character) on the client, in SP, and again on the server when
--     the craft completes (ISHandcraftAction:performRecipe). A name that does not resolve lets everything through
--     (CraftRecipe.java:1010-1032), so this file is shared and every recipe has its own function.
--   * OnAddToMenu: the vanilla crafting list (ISRecipeScrollingListBox.lua:344-348, ISTiledIconPanel.lua:193-197) calls
--     it through callLuaBool, which looks the name up as a global only (LuaManager.java:5745-5746): no dotted name.
-- Neat Crafting (Workshop 3502080466) draws its own list and never asks OnAddToMenu; every list path there goes
-- through NC_FilterBar:shouldIncludeRecipe (NC_FilterBar.lua:351, 562, 608, 630). The right-click quick craft asks
-- OnTest (CraftRecipeManager.java:1288).
-- Both windows list categories from every recipe of the window, before those filters (BaseCraftingLogic.java:97-108):
-- while no recipe of this mod may be crafted (the default) Recipes.categories takes the category out, or an empty
-- category would stay. The window code loads after this file (client), so it is wrapped once the game has started.
-- Open windows never rebuild on a sandbox change (no event for it): the client compares the levels every game minute
-- and rebuilds the open windows when they changed (Recipes.watch, as Safehouse CraftList.lua does).
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Rules"
local M = MinidoracatPackThrow
local Recipes = { VARIANT = {} } -- recipe name -> { t = type, level = 2 | 3 | 4 }
M.Recipes = Recipes
Recipes.CATEGORY = "MinidoracatPackThrow"
Recipes.LEVEL_NAME = { [2] = "Easy", [3] = "Standard", [4] = "Hard" }

function Recipes.name(t, level)
    return t.recipe .. Recipes.LEVEL_NAME[level]
end

for _, t in ipairs(M.TYPES) do
    for level = 2, 4 do
        local suffix = Recipes.LEVEL_NAME[level]
        Recipes.VARIANT[t.recipe .. suffix] = { t = t, level = level }
        _G["MinidoracatPackThrow_craft" .. t.id .. suffix] = function() return M.Rules.craftOn(t, level) end
    end
end

-- True for one of these recipes while it may not be crafted; false for every other recipe.
function Recipes.hidden(name)
    local v = Recipes.VARIANT[name]
    return v ~= nil and not M.Rules.craftOn(v.t, v.level)
end

-- True while at least one recipe of this mod may be crafted.
function Recipes.anyOpen()
    for _, t in ipairs(M.TYPES) do
        if M.Rules.craftLevel(t) > 1 and M.Rules.typeOn(t) then return true end
    end
    return false
end

-- A category list (a Java list of names) without this mod's category while none of its recipes may be crafted; the
-- same list otherwise.
function Recipes.categories(list)
    if list == nil or Recipes.anyOpen() then return list end
    local out, found = ArrayList.new(), false
    for i = 0, list:size() - 1 do
        local c = list:get(i)
        if c == Recipes.CATEGORY then found = true else out:add(c) end
    end
    return found and out or list
end

-- Wraps the window code that lists recipes and categories; true when it wrapped anything. Each wrap happens once (a
-- flag on the wrapped table), so a reload never stacks them.
--   * Neat Crafting's recipe lists: NC_FilterBar:shouldIncludeRecipe.
--   * Vanilla categories: ISHandCraftPanel:getCategoryList feeds ISWidgetRecipeCategories:populateCategoryList
--     (ISHandCraftPanel.lua:305, ISWidgetRecipeCategories.lua:98).
--   * Neat Crafting's categories: NC_CategoryList_Panel:populateCategoryList reads self.logic:getCategoryList() itself
--     (NC_CategoryList_Panel.lua:131-138); for that call its logic is a stand-in that answers the filtered list.
function Recipes.wrapCraftWindows()
    local done = false
    local F = NC_FilterBar
    if type(F) == "table" and type(F.shouldIncludeRecipe) == "function" and not F.packThrowFilter then
        local orig = F.shouldIncludeRecipe
        F.shouldIncludeRecipe = function(self, recipe)
            if recipe ~= nil and Recipes.hidden(recipe:getName()) then return false end
            return orig(self, recipe)
        end
        F.packThrowFilter, done = true, true
    end
    local P = ISHandCraftPanel
    if type(P) == "table" and type(P.getCategoryList) == "function" and not P.packThrowCategories then
        local orig = P.getCategoryList
        P.getCategoryList = function(self) return Recipes.categories(orig(self)) end
        P.packThrowCategories, done = true, true
    end
    local C = NC_CategoryList_Panel
    if type(C) == "table" and type(C.populateCategoryList) == "function" and not C.packThrowCategories then
        local orig = C.populateCategoryList
        C.populateCategoryList = function(self)
            local logic = self.logic
            if logic == nil or Recipes.anyOpen() then return orig(self) end
            self.logic = { getCategoryList = function() return Recipes.categories(logic:getCategoryList()) end }
            local ok, err = pcall(orig, self)
            self.logic = logic
            if not ok then error(err) end
        end
        C.packThrowCategories, done = true, true
    end
    return done
end

-- Rebuilds every open crafting window; returns how many. Windows: ISEntityUI.players[n].windows[key].instance (nil once
-- closed, ISEntityUI.lua:407, 477). Vanilla refetches recipes and categories (refreshRecipeList(true),
-- ISHandCraftPanel.lua:176) and falls back to "All" when the selected category is gone (ISWidgetRecipeCategories.lua:109-
-- 112). Neat Crafting builds its category column once when the window opens (NC_CategoryList_Panel.lua:125), so that is
-- rebuilt as well as its list (updateRecipeDisplay, NC_handcraftPanel.lua:661), and a selection of this mod's vanished
-- category goes back to "All" (onCategoryChanged, NC_CategoryList_Panel.lua:272; true: no history step).
function Recipes.refreshOpen()
    local n = 0
    for _, p in pairs(ISEntityUI and ISEntityUI.players or {}) do
        for _, w in pairs(p.windows or {}) do
            local inst = w.instance
            local nc = inst and inst.HandCraftPanel
            if nc ~= nil and nc.updateRecipeDisplay then
                local cats = nc.categoryPanel
                if cats ~= nil and cats.populateCategoryList then
                    cats:populateCategoryList()
                    if cats.selectedCategory == Recipes.CATEGORY and not Recipes.anyOpen() then
                        cats:onCategoryChanged("", true)
                    end
                end
                nc:updateRecipeDisplay()
                n = n + 1
            end
            local van = inst and inst.handCraftPanel
            if van ~= nil and van.refreshRecipeList then
                van:refreshRecipeList(true)
                n = n + 1
            end
        end
    end
    return n
end

-- Every type's level, and an x for a type switched off, as one string.
function Recipes.levelsKey()
    local parts = {}
    for i, t in ipairs(M.TYPES) do parts[i] = M.Rules.craftLevel(t) .. (M.Rules.typeOn(t) and "" or "x") end
    return table.concat(parts)
end

-- Once a game minute on a client: open windows rebuild when the levels changed since the last look.
function Recipes.watch()
    local key = Recipes.levelsKey()
    if Recipes.lastKey ~= nil and key ~= Recipes.lastKey then Recipes.refreshOpen() end
    Recipes.lastKey = key
end

if not isServer() then
    Events.OnGameStart.Add(Recipes.wrapCraftWindows)
    Events.EveryOneMinute.Add(Recipes.watch)
end

return Recipes
