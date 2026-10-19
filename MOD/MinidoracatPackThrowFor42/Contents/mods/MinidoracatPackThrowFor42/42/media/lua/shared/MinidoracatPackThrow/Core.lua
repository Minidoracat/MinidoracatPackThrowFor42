-- Pack & Throw: shared constants and helpers.
MinidoracatPackThrow = MinidoracatPackThrow or {}
local M = MinidoracatPackThrow

M.MOD_ID = "MinidoracatPackThrowFor42"
M.MODULE = "MinidoracatPackThrow" -- client command module and item module
M.LOG_PREFIX = "[MinidoracatPackThrowFor42] "
M.PACK_RANGE = 8 -- tiles between player and vehicle (pack) or player and capsule on the ground (unpack)

-- The capsule types and the Pal Sphere tiers, in the order of the admin "Types" tab, the sandbox page and the style
-- index the server sends with an effect (Fx.broadcast args.style). Capsules take vehicles only, spheres animals only
-- (user 2026-10-14; a wrong one is WRONG_ITEM). id gives the rest: items Capsule<id> / LoadedCapsule<id>, a sphere
-- <id> / Loaded<id> (scripts/MinidoracatPackThrow_items.txt), icons Item_<icon>[Loaded].png (scripts/assets/
-- build_capsule.py, build_sphere.py), sandbox Type<id> (using it allowed) and Type<id>Loot (in loot), the craft
-- recipe CraftMinidoracatPackThrow<empty item> (scripts/MinidoracatPackThrow_recipes.txt, Recipes.lua), the
-- look-and-sound line Tooltip_MinidoracatPackThrow_Look_<id>. Look and sounds (client/Effects.lua): smoke =
-- texture name prefix of the frames <prefix>1.png .. <prefix><frames>.png (cartoon: scripts/assets/build_smoke.py, the
-- others design_smoke.py), px = drawn size at zoom 1, anchor = share of that size above the ground point, flash =
-- light colour; throw / pop / pack / button = sound script names (media/scripts/MinidoracatPackThrow_sounds.txt,
-- takes in scripts/assets/build_sfx.py). Only the looks and sounds differ (user, design vcap-types-1012).
M.TYPES = {
    { id = "Cartoon", smoke = "smoke_", frames = 8, frameMs = 150, px = 384, anchor = 0.7, flash = { 1, 0.95, 0.8 },
        throw = "PackThrowThrow", pop = "PackThrowPop", pack = "PackThrowPack",
        button = "PackThrowButton" },
    { id = "Real", smoke = "smoke_S1_", frames = 16, frameMs = 90, px = 576, anchor = 0.66, flash = { 0.85, 0.85, 0.82 },
        throw = "PackThrowThrowReal", pop = "PackThrowPopReal", pack = "PackThrowPackReal",
        button = "PackThrowButtonReal" },
    { id = "Dust", smoke = "smoke_S2_", frames = 16, frameMs = 90, px = 576, anchor = 0.62, flash = { 1, 0.85, 0.6 },
        throw = "PackThrowThrowReal2", pop = "PackThrowPopHeavyDrop", pack = "PackThrowPackHeavy",
        button = "PackThrowButtonDust" },
    { id = "Steam", smoke = "smoke_S3_", frames = 12, frameMs = 85, px = 480, anchor = 0.7, flash = { 0.9, 0.95, 1 },
        throw = "PackThrowThrowSteam", pop = "PackThrowPopSteam", pack = "PackThrowPackSteam",
        button = "PackThrowButtonSwitch" },
    { id = "SciFi", smoke = "smoke_S4_", frames = 12, frameMs = 85, px = 416, anchor = 0.78, flash = { 0.5, 0.9, 1 },
        throw = "PackThrowThrowSci", pop = "PackThrowPopSci", pack = "PackThrowPackSci",
        button = "PackThrowButtonSci" },
    { id = "Magic", smoke = "smoke_S5_", frames = 15, frameMs = 90, px = 576, anchor = 0.66, flash = { 0.95, 0.8, 1 },
        throw = "PackThrowThrowMagic", pop = "PackThrowPopMagic", pack = "PackThrowPackMagic",
        button = "PackThrowButtonMagic" },
    { id = "Shock", smoke = "smoke_S6_", frames = 18, frameMs = 90, px = 672, anchor = 0.75, flash = { 1, 0.85, 0.6 },
        throw = "PackThrowThrowShock", pop = "PackThrowPopExplosion", pack = "PackThrowPackShock",
        button = "PackThrowButtonShock" },
}
-- Pal Spheres (user 2026-10-14, after Palworld v0.3.11): caught by throwing an empty one, released next to the player
-- (no throw, no press). bonus: percent added to a wild catch (Rules.captureChance); rarity: share of a sphere loot
-- place (Loot.wanted). Fixed here, not sandbox options. Look and sounds: the SciFi capsule's, every tier alike.
local SCIFI = M.TYPES[5]
for _, s in ipairs({ { "Basic", 0, 8 }, { "Mega", 15, 4 }, { "Giga", 30, 2 }, { "Legend", 50, 1 } }) do
    local t = { id = "Sphere" .. s[1], tier = s[1], sphere = true, bonus = s[2], rarity = s[3] }
    for _, k in ipairs({ "smoke", "frames", "frameMs", "px", "anchor", "flash", "throw", "pop", "pack", "button" }) do
        t[k] = SCIFI[k]
    end
    M.TYPES[#M.TYPES + 1] = t
end
M.EMPTY, M.LOADED, M.TYPE_BY_ID = {}, {}, {} -- empty / loaded full type -> type; id -> type
for i, t in ipairs(M.TYPES) do
    t.index = i
    t.sphere = t.sphere == true
    t.rarity = t.rarity or 1
    t.empty = M.MODULE .. (t.sphere and "." or ".Capsule") .. t.id
    t.loaded = M.MODULE .. (t.sphere and ".Loaded" or ".LoadedCapsule") .. t.id
    t.icon = t.sphere and ("MinidoracatSphere" .. t.tier) or ("MinidoracatCapsule" .. t.id)
    t.recipe = "CraftMinidoracatPackThrow" .. (t.sphere and "" or "Capsule") .. t.id
    M.EMPTY[t.empty], M.LOADED[t.loaded], M.TYPE_BY_ID[t.id] = t, t, t
end
M.FIRST_SPHERE = M.TYPE_BY_ID.SphereBasic

-- The type of a capsule item (empty or loaded), or nil for anything else.
function M.typeOf(item)
    local ft = item and item:getFullType()
    return ft and (M.EMPTY[ft] or M.LOADED[ft])
end

function M.isLoaded(item)
    return item ~= nil and M.LOADED[item:getFullType()] ~= nil
end

function M.isEmpty(item)
    return item ~= nil and M.EMPTY[item:getFullType()] ~= nil
end

function M.log(msg)
    print(M.LOG_PREFIX .. tostring(msg))
end

-- True for a loaded capsule's own inventory and for any container nested inside one (a bag in the cargo).
function M.isCapsuleContainer(container)
    local holder = container and container:getContainingItem()
    if not holder then return false end
    return M.isLoaded(holder) or M.isCapsuleContainer(holder:getContainer())
end

-- True for cargo: an item anywhere inside a loaded capsule. The capsule itself is not inside one.
function M.inCapsule(item)
    return item ~= nil and M.isCapsuleContainer(item:getContainer())
end

-- Drops capsule containers from a java ArrayList<ItemContainer> in place (crafting and building input lists).
function M.withoutCapsules(list)
    if not list then return list end
    for i = list:size() - 1, 0, -1 do
        local c = list:get(i)
        if M.isCapsuleContainer(c) then list:remove(c) end
    end
    return list
end

-- Same rule as VehicleManager O.isAdmin: Capability.ManipulateVehicle on a dedicated server; SP host is admin.
function M.isAdmin(player)
    if player == nil then return false end
    if not isServer() then return not isClient() end
    if Capability == nil then return false end
    return checkPermissions(player, Capability.ManipulateVehicle) == true
end

return M
