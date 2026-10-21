<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3820792446 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Pack & Throw Mod Guide: Packing, Unpacking & Recovery -->
<!-- 摘要：Guide to the Minidoracat Pack & Throw mod: getting empty capsules and Pal Spheres, packing vehicles with capsules, catching and releasing animals with Pal Spheres, throwing to capture, throwing capsules and Press the Button, safehouse protection, cargo and what animals keep, the tooltip and 3D preview, trading vehicles and animals in the Economy Center, plus sandbox options, the admin panel, restoring vehicles and animals and what happens after a crash. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3820792412]丟出收納 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3820790323

{{img:01-overview-en.jpg}}
Pack & Throw lets you pack a parked vehicle into a capsule and carry it around. Throw the capsule when you need it: the vehicle appears exactly as it was, with its mods, condition and cargo. Live animals are caught in Pal Spheres instead: a caught animal is carried in the sphere and released right next to you when you want it. Packed vehicles are not in the world, so busy bases run smoother too.
The Pal Sphere names and looks are a tribute to Palworld; this mod is not affiliated with Pocketpair.
[olist]
[*] [b]Get empty capsules and Pal Spheres[/b]: loot, an admin or the Economy Center; when the server turns crafting on, you can also make them; see "Getting capsules and Pal Spheres".
[*] [b]Pack a vehicle[/b]: park, turn the engine off, make sure nobody is inside, carry an empty capsule, then right-click the vehicle and choose "Pack into Capsule". After about 10 seconds the vehicle is packed and the capsule drops where the vehicle stood.
[*] [b]Catch an animal[/b]: carry an empty Pal Sphere, right-click a live animal, open that animal's submenu and choose "Catch in Pal Sphere"; see "Catching an animal with a Pal Sphere".
[*] [b]Throw to capture[/b]: right-click an empty capsule or Pal Sphere in your inventory, choose "Throw to Capture", and throw the capsule at a vehicle or the sphere at an animal; see "Throwing to capture".
[*] [b]Release an animal[/b]: right-click a Pal Sphere holding an animal in your inventory and choose "Release: <name>"; the animal appears right next to you. See "Releasing an animal".
[*] [b]Throw a capsule[/b]: pick up a capsule holding a vehicle, right-click it in your inventory and choose "Throw Capsule"; the cursor outlines the vehicle, and you left-click when the outline is green.
[*] [b]Too heavy to pick up?[/b] Right-click it on the ground and choose "Press the Button"; the vehicle appears next to it.
[/olist]
=== 🧰 Getting capsules and Pal Spheres
{{img:03-lineup-en.jpg}}
[list]
[*] [b]Loot[/b]: all seven kinds of empty capsule show up in containers at mechanic shops, car supply stores and gas station repair bays; home garages are off by default. Each location's share is split evenly over the types that are on. Empty Pal Spheres have three locations of their own: barns, pet stores and hunting lockers (all on by default), and the four tiers are split 8:4:2:1 by rarity, so the better ones are rarer. Servers can toggle each location and tune its weight; see "Sandbox options and defaults".
[*] [b]Crafting[/b]: once the server turns on "Allow crafting empty capsules" or "Allow crafting empty Pal Spheres" (both off by default), you can make them next to a table or similar surface; see "Crafting" below for the parts.
[*] [b]Economy Center[/b]: with Minidoracat Economy installed, admins list the empty capsule (item ID [b]MinidoracatPackThrow.Capsule<Type>[/b], for example CapsuleCartoon) or empty Pal Sphere ([b]MinidoracatPackThrow.Sphere<Tier>[/b], for example SphereBasic) to sell it; "List..." in the admin panel's "Types" tab opens a product draft for that capsule or Pal Sphere in the Economy Center.
[*] [b]Capsules holding a vehicle and Pal Spheres holding an animal[/b]: can be listed or auctioned too; see "Trading vehicles and animals in the Economy Center".
[*] [b]From admins[/b]: hand out empty capsules and Pal Spheres with the vanilla item list or the /additem command.
[/list]
[h3]Crafting[/h3]
[list]
[*] [b]The server turns it on[/b]: "Allow crafting empty capsules" and "Allow crafting empty Pal Spheres" on the sandbox page "Minidoracat Pack & Throw" or the admin panel's "Settings" tab, both off by default; while they're off, the crafting window doesn't show these recipes.
[*] [b]Where[/b]: stand next to a table, counter or similar surface; the recipes are in the crafting window's "Electrical" category, and like the vanilla electrical recipes they need light.
[*] [b]Types and tiers switched off[/b]: a capsule type or Pal Sphere tier whose "Use" is off in the "Types" tab can't be crafted.
[*] [b]Pal Spheres go up one tier at a time[/b]: the Pal Sphere is made from parts; each higher tier takes an empty one of the tier below plus more parts, and that sphere is used up.
[*] [b]Tools[/b]: the screwdriver and the pliers are kept; the pliers may wear a little.
[/list]
[table]
[tr][th]Makes[/th][th]Parts[/th][th]Tools[/th][th]Skills[/th][/tr]
[tr][td]Empty capsule (one recipe per type, all with the same parts)[/td][td]Car Battery 1 (any charge), Steel Sheet - Small 1, Scrap Electronics 4, Amplifier 1, Electrical Wire 2, Screws 2[/td][td]Screwdriver, Pliers[/td][td]Electrical 4, Mechanics 2[/td][/tr]
[tr][td]Pal Sphere[/td][td]Baseball, Tennis Ball or Tin Can 1, Scrap Electronics 2, Electrical Wire 1[/td][td]Screwdriver[/td][td]Electrical 1[/td][/tr]
[tr][td]Mega Sphere[/td][td]Empty Pal Sphere 1, Amplifier 1, Scrap Electronics 2[/td][td]Screwdriver[/td][td]Electrical 3[/td][/tr]
[tr][td]Giga Sphere[/td][td]Empty Mega Sphere 1, Radio Receiver 1, Radio Transmitter 1, Scrap Electronics 3, Electrical Wire 1[/td][td]Screwdriver, Pliers[/td][td]Electrical 5[/td][/tr]
[tr][td]Legendary Sphere[/td][td]Empty Giga Sphere 1, Motion Sensor 1, Amplifier 1, Scrap Electronics 4, Electrical Wire 2[/td][td]Screwdriver, Pliers[/td][td]Electrical 7[/td][/tr]
[/table]
[h3]Seven capsule types[/h3]
[list]
[*] [b]Types[/b]: Cartoon, Realistic, Dust, Steam, Sci-Fi, Magic and Shockwave. The end cap color tells the type; a loaded capsule adds a patterned band.
[*] [b]Same function[/b]: requirements, time, permission and records are the same; only the look, the smoke and the four sounds (throw, pop, pack, button) differ.
[*] [b]Everyone sees the same type[/b]: the type you pack with is the smoke nearby players see when packing, throwing and unpacking.
[*] [b]After unpacking[/b]: the empty capsule you get back is the same type.
[*] [b]A type an admin switched off[/b]: can't pack vehicles any more; loaded ones still throw and unpack with the button. Its empty capsule's tooltip says so. Capsules only take vehicles; animals need a Pal Sphere.
[/list]
=== 🧰 Packing a vehicle
{{img:04-pack-menu-en.jpg}}
[h3]Menu and requirements[/h3]
[list]
[*] [b]The menu[/b]: right-click a vehicle and "Pack into Capsule" is at the end of the menu.
[*] [b]Each requirement listed[/b]: hover the option; checked rows are met, the others tell you what to do, and the option stays grayed out until they are.
[*] [b]Requirements[/b]:
[list]
[*] Engine off
[*] Nobody inside
[*] An empty capsule in your inventory (bags count) of a type an admin has not switched off
[*] Permission to pack this vehicle (see "Who can pack")
[*] The vehicle is not in someone else's safehouse (see "Safehouse protection")
[/list]
[*] [b]Can't be packed[/b]: a vehicle that is towing or being towed, has animals in its trailer, or holds another loaded capsule; the menu tells you why.
[*] [b]Choosing a type[/b]: with empty capsules of two or more types, "Pack into Capsule" opens a submenu with one entry per type (for example "Steam Capsule ×1"); the tooltip title says "Pack into Steam Capsule".
[/list]
[h3]Who can pack[/h3]
[list]
[*] [b]Vehicles claimed in Minidoracat Vehicle Manager[/b]: only the owner and players the owner shared Tow with can pack (a share with everyone never includes Tow).
[*] [b]Admins and claimed vehicles[/b]: must first turn on override in the Admin tab of the fleet window.
[*] [b]Without permission[/b]: the option has a minus mark, the tooltip row says why, and clicking it shows a notification.
[*] [b]Other vehicles[/b] (no Vehicle Manager, or not claimed): the sandbox option "Who can pack vehicles" decides. By default it is anyone carrying this vehicle's key (in the inventory or in the ignition); it can be changed to anyone or admins only.
[*] [b]Admins[/b]: not limited by this sandbox option and can always pack these.
[/list]
[h3]Packing[/h3]
[list]
[*] [b]Time[/b]: about 10 seconds.
[*] [b]The server checks again[/b]: permission, passengers and towing; it only packs when everything passes, saves the vehicle and its cargo first and removes the vehicle from the world last.
[*] [b]Key[/b]: a key left in the ignition moves to your inventory.
[*] [b]Afterwards[/b]: the empty capsule you used becomes a loaded capsule of the same type and drops where the vehicle stood.
[*] [b]Capsule name[/b]: "Type: vehicle", for example "Steam Capsule: Chevalier D6"; every player sees it in their own game language once the inventory or loot window lists it.
[*] [b]Effects[/b]: nearby players see that type's smoke and flash and hear its sound.
[/list]
[h3]What is saved[/h3]
[list]
[*] Vehicle type, paint
[*] Every part and its condition (including mods and removed parts)
[*] Fuel, tire pressure, battery
[*] Doors, windows and locks, the key ID
[*] The cargo in every container on the vehicle
[/list]
Vanilla and modded vehicles such as KI5's work the same way.
=== 🧰 Catching an animal with a Pal Sphere
{{img:02-capture-en.jpg}}
[h3]Four Pal Sphere tiers[/h3]
[list]
[*] [b]The tiers[/b]: Pal Sphere, Mega Sphere, Giga Sphere and Legendary Sphere, in blue, green, yellow and purple.
[*] [b]What differs[/b]: the tier bonus to the wild catch chance (+0, +15, +30, +50) and how rare they are in loot (8:4:2:1, so the better ones are rarer). Everything else is the same.
[*] [b]Look and effects[/b]: all four tiers share the Sci-Fi capsule's light column, smoke and energy sounds; only the color differs.
[*] [b]Capsules and Pal Spheres[/b]: capsules only take vehicles and Pal Spheres only take animals. Using the wrong one says "capsules can't take animals; use a Pal Sphere" or "Pal Spheres can't take vehicles".
[/list]
[h3]Menu and requirements[/h3]
[list]
[*] [b]The menu[/b]: right-click a live animal in the world. The vanilla menu has one entry per animal; open that animal's submenu and "Catch in Pal Sphere" is at the end.
[*] [b]Each requirement listed[/b]: hover the option; the tooltip shows the empty Pal Sphere in your inventory and the animal's state, says what is wrong, and the option stays grayed out until it's fixed. A wild animal gets one more row, "Success chance: 50%", with the bonuses on the next row (see "Catch chance for wild animals" below).
[*] [b]Requirements[/b]:
[list]
[*] An empty Pal Sphere in your inventory (bags count) of a tier an admin has not switched off
[*] The server has "Allow catching animals" on
[*] The animal is alive and out in the world (not being carried, not in a hutch or a trailer)
[*] No rope on it (untie it first)
[*] You are not in a vehicle
[*] The animal is not in someone else's safehouse (see "Safehouse protection")
[/list]
[*] [b]Can't be caught[/b]: dead animals and animals on a butcher hook.
[*] [b]Who can catch[/b]: any player, no key or permission needed; tame or wild, young or grown.
[*] [b]Choosing a tier[/b]: with empty Pal Spheres of two or more tiers, the entry opens a submenu with one row per tier (for example "Mega Sphere ×1"); each tooltip shows the success chance with that tier.
[*] [b]Rather not walk up?[/b] Throw an empty Pal Sphere at it instead; see "Throwing to capture". Wild animals run from people they see, so throwing is the easier way to catch them.
[/list]
[h3]Catching[/h3]
[list]
[*] [b]Time[/b]: your character walks next to the animal, then about 10 seconds; the animal stays put meanwhile.
[*] [b]The server checks again[/b]: the animal's state, the switch and the empty Pal Sphere; it only catches when everything passes, saves the animal first and removes it from the world last.
[*] [b]Afterwards[/b]: the empty Pal Sphere you used becomes a loaded Pal Sphere of the same tier and drops where the animal stood.
[*] [b]Pal Sphere name[/b]: "Tier: name", for example "Mega Sphere: Bessie"; an unnamed animal goes by its breed and kind the vanilla way. Every player sees it in their own game language.
[*] [b]Wild animals[/b]: a wild animal that can be domesticated (a wild rabbit, for example) becomes tame when caught, just like picking it up in vanilla; animals that can't be domesticated, such as deer, stay wild.
[*] [b]Weight[/b]: the animal is not inside the sphere, so a Pal Sphere holding one weighs the same as an empty one.
[/list]
[h3]What is kept[/h3]
[list]
[*] Name, breed, sex
[*] Age, size and weight
[*] Health, hunger and thirst, stress
[*] Genes and genetic disorders
[*] Milk, wool
[*] Pregnancy and fertilization, and how far along they are
[/list]
[h3]What is not kept[/h3]
[list]
[*] [b]Time stands still in a Pal Sphere[/b]: a caught animal doesn't grow, get hungry or move along in a pregnancy; it comes out just as it went in.
[*] [b]Vanilla timers restart[/b]: the milking and petting intervals, the eggs laid that day, and breeding cooldowns.
[*] [b]Herd[/b]: which herd a wild animal belonged to is not kept.
[*] [b]Coat pattern (multiplayer)[/b]: vanilla lets each player's game pick the pattern, so after release different players may see different patterns.
[/list]
[h3]When an admin switches animal catching off[/h3]
[list]
[*] [b]The switch[/b]: the sandbox option "Allow catching animals" (on by default), also in the admin panel's "Settings" tab.
[*] [b]When off[/b]: the option is grayed out with "An admin switched off packing animals"; throwing to capture can't take animals either (vehicles still can).
[*] [b]Pal Spheres already holding an animal[/b]: can still release it, and admins can still restore it.
[/list]
[h3]Catch chance for wild animals[/h3]
{{img:07-capture-cursor-en.jpg}}
[list]
[*] [b]Wild animals only[/b]: the menu and throwing to capture work the same; tame animals and vehicles always go in and show no success chance.
[*] [b]The formula[/b]: success chance = base chance + Pal Sphere tier bonus + injured + young + unaware of you, at most 100.
[/list]
[table]
[tr][th]Part[/th][th]Default[/th][th]Added when[/th][/tr]
[tr][td]Base chance[/td][td]50[/td][td]Always (sandbox option "Wild catch base chance")[/td][/tr]
[tr][td]Tier bonus[/td][td]+0 / +15 / +30 / +50[/td][td]Pal Sphere / Mega Sphere / Giga Sphere / Legendary Sphere[/td][/tr]
[tr][td]Injured bonus[/td][td]Up to +30[/td][td]In proportion to the health the animal lost; at half health it adds half[/td][/tr]
[tr][td]Young bonus[/td][td]+15[/td][td]The animal is young[/td][/tr]
[tr][td]Unaware bonus[/td][td]+20[/td][td]The animal is not alerted and you are sneaking or behind it[/td][/tr]
[/table]
[list]
[*] [b]The settings[/b]: the base chance and the three bonuses are sandbox options, also in the admin panel's "Settings" tab; setting a bonus to 0 turns it off.
[*] [b]Shown before you try[/b]: the tooltip of "Catch in Pal Sphere" in the animal's menu and the capture cursor's tooltip show "Success chance: 77%" for a wild animal, and the next row lists the bonuses that apply, for example "Mega Sphere +15 · Injured +12 · Young +15 · Unaware of you +20".
[*] [b]The cursor's number is an estimate[/b]: the server decides at the moment the throw lands.
[*] [b]On a miss[/b]: the animal breaks free and stays where it is, with "It broke free (success chance 50%)". The empty Pal Sphere is not used up: after the menu it is still in your inventory, a thrown one lies where it landed; pick it up and try again.
[*] [b]Pal Sphere lost on a failed catch[/b]: with the sandbox option "Pal Sphere lost on a failed catch" on (off by default), a wild animal that breaks free takes the empty Pal Sphere too (from the menu it leaves your inventory; a thrown one does not land). The tooltip then says "Success chance: 50% (a miss takes the Pal Sphere)" and the message "It broke free (success chance 50%) and the Pal Sphere is gone." Only breaking free counts; any other miss (the target ran off, the spot is blocked) keeps the Pal Sphere.
[*] [b]Base chance 0 and 100[/b]: at 0 wild animals can't be caught (the option is grayed out, the cursor red, with "An admin switched off catching wild animals") and the bonuses can't save it; at 100 it always works.
[/list]
=== 🧰 Throwing and pressing
[h3]Throwing a capsule[/h3]
{{img:05-throw-cursor-en.jpg}}
[list]
[*] [b]How[/b]: with the capsule on you, right-click it in the inventory and choose "Throw Capsule" to get the landing cursor. Left-click to throw, right-click to cancel.
[*] [b]Turning[/b]: while the cursor is open, a standing character turns toward the aimed square (as with vanilla aiming); a left-click throws at once, with no wait for the turn.
[*] [b]Landing spot[/b]: within about 8 tiles of you and in sight.
[*] [b]Green outline[/b]: the vehicle's footprint on the ground, with "Fits: <vehicle>" when it fits.
[*] [b]Red outline[/b]: it doesn't fit, with the reason: too far, can't see there, not loaded yet, another vehicle, a person, a tree, no ground to park on, furniture or other objects, a wall or fence, indoors, the spot is in someone else's safehouse.
[/list]
[h3]Landing[/h3]
{{img:06-unpacked-en.jpg}}
[list]
[*] [b]Unpacking[/b]: the capsule whooshes to the spot, lands with a pop, smoke and a flash, and the vehicle appears as it was with its cargo back on board; the screen says "Unpacked: <vehicle>".
[*] [b]Empty capsule back[/b]: with the sandbox option "Return an empty capsule" on (the default), an empty capsule of the same type goes back into your inventory, ready for the next vehicle.
[*] [b]Ownership[/b]: with Vehicle Manager installed, the unpacked vehicle is reattached to its original claim: the owner and the shared list stay the same and the old key still opens the doors.
[*] [b]While packed[/b]: the fleet window shows "Claimed - not here right now"; Vehicle Manager's inactivity release still counts, so an owner who stays offline too long loses the claim just as with a parked vehicle.
[*] [b]Zombies are not affected[/b]: the smoke and flash are drawn on screen only, so zombies don't lose track of you; the capsule's pop doesn't attract zombies by default (servers can turn that on in the sandbox options).
[/list]
[h3]Press the Button (capsule on the ground)[/h3]
[list]
[*] [b]When[/b]: heavy cargo can make a capsule too heavy to pick up, and so too heavy to throw.
[*] [b]How[/b]: right-click the capsule on the ground (in the world or the loot window) and choose "Press the Button". Your character walks to the capsule and the same landing cursor appears; left-click to press, right-click to cancel.
[*] [b]Where the vehicle appears[/b]: within about 3 tiles of the capsule.
[*] [b]Cargo[/b]: goes back into the vehicle as usual.
[/list]
[h3]When there is no room[/h3]
[list]
[*] [b]Two checks[/b]: the cursor checks the spot before you throw, and the server checks it again on landing.
[*] [b]Blocked in between[/b] (someone walked in, for example): no vehicle appears; a "No room for the vehicle here" window shows the reason.
[*] [b]Thrown[/b]: the capsule drops on the landing spot. Pick a clear spot and press the button on the ground, or pick it up and throw again.
[*] [b]Pressed[/b]: the capsule stays where it is; pick a clear spot and press again.
[*] [b]Nothing is lost[/b]: the vehicle and the cargo stay in the capsule.
[/list]
=== 🧰 Releasing an animal
{{img:09-released-en.jpg}}
[list]
[*] [b]Release[/b]: right-click a Pal Sphere holding an animal in your inventory (bags count) and choose "Release: <name>". Your character does a short action and the animal appears right next to you. No throwing and no walking anywhere.
[*] [b]Where it appears[/b]: the square you are facing first; if that doesn't work, the other squares around you (the ones closest to where you face first). Each needs just one free square: water, under a vehicle, a tree, no ground or something in the way won't do; indoors is fine.
[*] [b]No room[/b]: if none of the eight squares works, a "The animal was not released" window says "no free square next to you" and the Pal Sphere stays in your inventory; try again somewhere else.
[*] [b]In a vehicle[/b]: not possible; get out of the vehicle first.
[*] [b]Landing[/b]: smoke appears where the animal does, it comes out as it was, and the screen says "Released: <name>".
[*] [b]Empty Pal Sphere back[/b]: with "Return an empty Pal Sphere" on (the default), an empty Pal Sphere of the same tier goes back into your inventory: "An empty Mega Sphere is back in your inventory." This option is set separately from the capsules' "Return an empty capsule".
[*] [b]Not thrown, no button[/b]: a Pal Sphere has no "Throw" and the one on the ground has no "Press the Button"; release it from your inventory.
[*] [b]A tier an admin switched off[/b]: only stops catching with it; loaded ones still release.
[*] [b]No 3D preview[/b]: a Pal Sphere holding an animal has no "Preview vehicle" in its menu.
[/list]
=== 🧰 Throwing to capture
{{img:08-capture-throw-en.jpg}}
[h3]How to throw[/h3]
[list]
[*] [b]The menu[/b]: with an empty capsule or Pal Sphere on you (bags count), right-click it in the inventory and choose "Throw to Capture" to get the capture cursor. Left-click to throw, right-click to cancel.
[*] [b]Turning[/b]: as with Throw Capsule, a standing character turns toward the aimed square while the cursor is open, and a left-click throws at once.
[*] [b]Capsules take vehicles, Pal Spheres take animals[/b]: an empty capsule only recognizes vehicles, an empty Pal Sphere only animals.
[*] [b]Target[/b]: an animal or a vehicle on the square under the cursor or right next to it; any square of a vehicle's body counts.
[*] [b]Range[/b]: the spot you aim at must be within about 8 tiles of you and in sight.
[*] [b]Green outline[/b]: marks the target (the animal's square or the whole vehicle) with "Capture: <name>"; a Pal Sphere aimed at a wild animal adds "Success chance: 77%" and the bonus row under it.
[*] [b]Red outline[/b]: it can't be captured, with the reason: no animal or vehicle there, too far, can't see there, an admin switched off packing animals, catching wild animals or this type, in someone else's safehouse, the wrong item (an empty capsule aimed at an animal says "capsules can't take animals; use a Pal Sphere", an empty Pal Sphere aimed at a vehicle says "Pal Spheres can't take vehicles"), or the same state and permission reasons as packing from the menu.
[/list]
[h3]What can be captured[/h3]
[list]
[*] [b]Animals (with an empty Pal Sphere)[/b]: the same requirements as the menu: alive, out in the world, no rope, and "Allow catching animals" on. Tame or wild, young or grown; a wild animal that can be domesticated becomes tame when captured.
[*] [b]Vehicles (with an empty capsule)[/b]: the same permission as packing from the menu (Tow shared in Vehicle Manager, or the sandbox option "Who can pack vehicles", by default the vehicle's key), and the engine off, nobody inside and no trailer.
[*] [b]No walking up[/b]: it's just the throw, without the 10 seconds of catching.
[*] [b]Best for wild animals[/b]: wild animals run from people they see, so catching from the menu means getting right next to them; a throw works from a distance.
[/list]
[h3]Hit or miss[/h3]
[list]
[*] [b]Two checks[/b]: the cursor and the server each check before the throw; on landing the server looks for the target again within one square of the spot and checks the rules once more.
[*] [b]Captured[/b]: the empty capsule or Pal Sphere flies over, a puff of smoke appears at the target, and the target goes inside. The loaded one lies where the target stood and the screen says "Captured: <name>"; just walk over and pick it up.
[*] [b]Refused before the throw[/b]: nothing is thrown, and the screen gives the reason and "It is still in your inventory."
[*] [b]Missed[/b]: it takes a moment from release to landing. If the target moves more than a square away from where you aimed, dies, is picked up, or someone gets into the vehicle in that time, the throw misses. The empty capsule or Pal Sphere lies on the landing spot and a "Nothing captured" message gives the reason and "The thrown one fell on the ground."; pick it up and throw again.
[*] [b]A wild animal broke free[/b]: even a hit can fail by the catch chance. A "Nothing captured" message says "It broke free (success chance 50%)" and "The thrown one fell on the ground."; the animal is still there, so pick up the Pal Sphere and throw again. With "Pal Sphere lost on a failed catch" on, the message says the Pal Sphere is gone and nothing lies on the landing spot.
[*] [b]Landing spot in someone else's safehouse[/b]: a missed empty capsule or Pal Sphere falls at your feet instead.
[/list]
=== 🧰 Safehouse protection
{{img:13-safehouse-en.jpg}}
[list]
[*] [b]The rule[/b]: on a multiplayer server, nobody can pack, capture or release a vehicle or an animal in someone else's safehouse. Who is exempt follows vanilla: the safehouse owner and members, staff with the vanilla safehouse permission, and safehouse war time.
[*] [b]Single player[/b]: there are no safehouses, so nothing changes.
[/list]
[h3]Packing and capturing[/h3]
[list]
[*] [b]Squares checked[/b]: the animal's square; for a vehicle, every square under its body, and one square inside someone else's safehouse is enough to refuse.
[*] [b]From the menu[/b]: the option is grayed out with "in someone else's safehouse".
[*] [b]Throw to capture[/b]: the cursor turns red with the same reason and nothing is thrown.
[/list]
[h3]Unpacking and releasing[/h3]
[list]
[*] [b]Throwing a capsule to unpack a vehicle[/b]: the landing ground (the vehicle's footprint) is checked; one square inside someone else's safehouse is enough, and the cursor says "the spot is in someone else's safehouse".
[*] [b]Releasing an animal[/b]: a Pal Sphere only puts the animal on a square next to you that is not in someone else's safehouse; if none works it says "no free square next to you" and the Pal Sphere stays in your inventory.
[*] [b]Refused before the throw[/b]: the capsule is not thrown and stays in your inventory; a pressed one stays where it is.
[*] [b]Refused on landing[/b] (rare): a thrown capsule falls at your feet, never inside someone else's safehouse; a pressed one stays where it is. The vehicle is still in the capsule.
[*] [b]Admin restore[/b]: refused when the chosen spot is in someone else's safehouse; see "Restoring a vehicle or an animal".
[/list]
=== 🧰 Cargo
[h3]Kept as it was[/h3]
[list]
[*] [b]The original items go in[/b]: everything in the vehicle's containers goes into the capsule, so water in bottles, items inside bags, blood and dirt on clothes and food freshness are all kept.
[*] [b]On unpacking[/b]: items go back into their original container.
[*] [b]Original container gone[/b] (the part was removed, for example): they go into another container on the vehicle with room, and whatever still doesn't fit lands on the ground next to it.
[*] [b]Weight counts[/b]: a capsule weighs the capsule itself plus all of its cargo, in your hands too. A capsule with heavy cargo can't be picked up; use Press the Button.
[/list]
[h3]Unpack to get it out[/h3]
[list]
[*] [b]No taking cargo out directly[/b]: dragging, Take All, eating and drinking, loading ammo and crafting never use what is inside a capsule, and you get the message "Unpack the vehicle to get this out".
[*] [b]Why[/b]: this means a server rollback can't leave a second copy of the cargo.
[*] [b]No putting in[/b]: you can't put anything into a capsule either.
[*] [b]The server checks too[/b]: if cargo is taken out anyway, the server puts it back into the capsule within a second and logs it.
[/list]
[h3]When the server allows taking cargo out[/h3]
With the sandbox option "Allow taking cargo out of capsules" on:
[list]
[*] [b]Works directly[/b]: dragging, Take All, eating and drinking and loading ammo work straight from the capsule.
[*] [b]Crafting and building[/b]: still don't use what is inside, so take it out first.
[*] [b]Out only[/b]: items can only be taken out, never put in.
[*] [b]Still locked[/b]: a freshly packed capsule opens after about 5 seconds, and a capsule waiting for an admin stays locked.
[*] [b]Taken items[/b]: are removed from the record, so the tooltip, the preview and the admin panel list what is still inside, and only that comes back with the vehicle.
[/list]
=== 🧰 Already-unpacked capsules
[list]
[*] [b]Unpacks only once[/b]: after a normal unpack the loaded capsule is gone (replaced by an empty one of the same type when the option is on).
[*] [b]An unpacked capsule turns up again[/b] (the server rolled back to a save from before the unpack, or an admin already restored the vehicle): its tooltip shows its state, and throwing it shows "This capsule was already unpacked" with the record and the capsule number.
[*] [b]Vehicle missing[/b]: give the number to an admin; they can see where the capsule went.
[*] [b]Cargo still inside[/b]: it is a second copy; once the server knows the vehicle is in the world, it swaps the capsule for an empty one of the same type.
[*] [b]Rollback and no vehicle found[/b]: if the server rolled back to a save from before the unpack and the vehicle can't be found nearby, the capsule is put on hold for an admin instead (see "Unconfirmed after a crash"); its cargo is not cleared.
[*] [b]"This capsule needs an admin"[/b]: the server stopped before the capsule's last change was saved. Give the number to an admin (see "Unconfirmed after a crash").
[/list]
=== 🧰 Tooltip and 3D preview
[h3]Tooltip[/h3]
{{img:10-capsule-tooltip-en.jpg}}
[list]
[*] [b]Where[/b]: hover a capsule and an extra box appears under the vanilla tooltip.
[*] [b]It lists[/b]: the type (look and sounds), the vehicle name, type, paint, condition (engine and body), fuel, battery, missing parts, mods, cargo (count and the first items) and who packed it.
[*] [b]Loading[/b]: the data comes from the server, so it says "Reading vehicle condition..." for a moment.
[*] [b]Capsules on the ground[/b]: walk closer to see the details.
[*] [b]Other states[/b]: an empty capsule tells you its type and how to pack, with a "!" line when an admin switched its type off; already unpacked, restored by an admin, unconfirmed after a crash, or data missing on this server are all spelled out.
[*] [b]Does it come back[/b]: every capsule and Pal Sphere, empty or loaded, has a line saying whether the empty one comes back to your inventory after unpacking or release. When it does the line is grey, for example "After unpacking, the empty capsule comes back to your inventory."; when the server turns "Return an empty capsule" (capsules) or "Return an empty Pal Sphere" (Pal Spheres) off it is in the warning colour, for example "Single use: unpacking the vehicle uses up this capsule (server setting)."
[/list]
[h3]Pal Spheres holding an animal[/h3]
{{img:11-sphere-tooltip-en.jpg}}
[list]
[*] [b]It lists[/b]: the tier, the animal's kind and breed, name, sex, age, weight, health, milk (when it can be milked), wool (when it has some), whether it is wild, and who caught it.
[*] [b]Pregnancy and fertilization[/b]: as in vanilla, only shown to players with Husbandry level 3 or higher.
[*] [b]Empty Pal Spheres[/b]: the tooltip says "Empty Pal Sphere. Catch an animal from its animal menu, or throw it at one with Throw to Capture; a wild one may break free." With "Pal Sphere lost on a failed catch" on, a warning line adds "If a wild animal breaks free, this Pal Sphere is lost (server setting)."
[*] [b]Time stands still[/b]: empty and loaded Pal Spheres both end with a grey line, "Time stands still inside a Pal Sphere: the animal won't grow or get hungry or thirsty, and a pregnancy pauses."
[/list]
[h3]3D preview[/h3]
{{img:12-preview-en.jpg}}
[list]
[*] [b]Open it[/b]: right-click a capsule and choose "Preview vehicle".
[*] [b]Controls[/b]: left-drag to rotate, right-drag to pan, scroll to zoom, double-click to reset, or use the front, side and top view buttons.
[*] [b]It shows the model, not this vehicle[/b]: the preview draws the vehicle type's default look with every optional part, not this vehicle's actual paint and parts; the list next to it shows this vehicle's real state.
[/list]
=== 🧰 Trading vehicles and animals in the Economy Center
{{img:16-economy-en.jpg}}
[list]
[*] [b]Needs a recent Minidoracat Economy[/b]: a loaded capsule can be listed on the market or put up for auction, cargo included. Older Economy versions still refuse loaded capsules.
[*] [b]What buyers see[/b]: market and auction listings show the vehicle and its condition (engine and body, fuel, battery, number of missing parts, number of cargo items).
[*] [b]The buyer gets that very vehicle[/b]: the capsule they receive is the same as the original, with the same number and the same cargo; thrown, it's that vehicle, and the cargo goes back into its containers.
[*] [b]Not sold[/b]: when the seller cancels or an auction ends without a winner, the capsule comes back unchanged.
[*] [b]One capsule per listing[/b]: every capsule holds a different vehicle, so each one is its own listing; buy requests can't take them and the shop doesn't buy them.
[*] [b]When listing is refused[/b]: in the first seconds after packing, while a record is unconfirmed after a crash, or when the cargo holds something the Economy Center can't carry (for example written paper, mixed liquids, a radio with a disc inside, or more than 300 cargo items). The item picker says why; unpack, take that item out and pack again.
[*] [b]Weapon attachments[/b]: attachments come off when the capsule is listed and stay in the weapon's container, so the buyer gets the weapon and its attachments separately.
[/list]
[h3]Pal Spheres holding an animal[/h3]
[list]
[*] [b]Listed and auctioned the same way[/b]: with a recent Minidoracat Economy, a Pal Sphere holding an animal can be listed on the market or put up for auction. Empty Pal Spheres are ordinary goods, like empty capsules.
[*] [b]What buyers see[/b]: the tier, the name, and the animal's kind and breed, sex, age, weight, health, milk, wool and whether it is wild; pregnancy is not shown on the listing.
[*] [b]The buyer gets that very animal[/b]: the Pal Sphere they receive has the same number; released, it's that animal, in the same state as when it was listed.
[*] [b]One Pal Sphere per listing[/b]: as with loaded capsules, buy requests can't take them and the shop doesn't buy them; listing is refused in the first seconds after catching and while a record is unconfirmed after a crash.
[*] [b]Not sold[/b]: the Pal Sphere comes back unchanged.
[/list]
=== 🧰 Performance
[list]
[*] [b]Packed vehicles are not in the world[/b]: the game spends no time on them each frame. The more vehicles you pack, and the heavier they are (KI5's vehicles, for example), the smoother things get nearby.
[*] [b]What packing can't fix[/b]: vehicles being driven and vehicles that aren't packed cost the same as before, and the moment a vehicle is unpacked may hitch briefly.
[/list]
=== ⚙️ Sandbox options and defaults
The options are on the sandbox pages "Minidoracat Pack & Throw", "Minidoracat Pack & Throw - Types" and "Minidoracat Pack & Throw - Loot"; the admin panel's "Settings", "Types" and "Loot" tabs edit these same options.
[h3]Minidoracat Pack & Throw[/h3]
[table]
[tr][th]Option[/th][th]Default[/th][th]Notes[/th][/tr]
[tr][td]Return an empty capsule[/td][td]On[/td][td]After a capsule unpacks, an empty capsule of the same type goes back into the thrower's inventory. Every capsule tooltip says whether it comes back, in the warning colour when it doesn't[/td][/tr]
[tr][td]Return an empty Pal Sphere[/td][td]On[/td][td]After a Pal Sphere releases its animal, an empty Pal Sphere of the same tier goes back into your inventory. Every Pal Sphere tooltip says whether it comes back, in the warning colour when it doesn't[/td][/tr]
[tr][td]Allow crafting empty capsules[/td][td]Off[/td][td]When on, players can make all seven kinds of empty capsule from vanilla parts next to a table or similar surface; see "Crafting" for the parts. Types with "can pack" off can't be crafted[/td][/tr]
[tr][td]Allow crafting empty Pal Spheres[/td][td]Off[/td][td]When on, players can make empty Pal Spheres, each higher tier from an empty one of the tier below; see "Crafting" for the parts. Tiers with "can catch" off can't be crafted[/td][/tr]
[tr][td]Who can pack vehicles[/td][td]Key holders[/td][td]The key in the inventory or in the ignition; can be set to "Anyone" or "Admins only"[/td][/tr]
[tr][td]Zombie attraction radius of the capsule sound[/td][td]0 tiles (0–50)[/td][td]0 means the capsule's pop attracts no zombies[/td][/tr]
[tr][td]Allow taking cargo out of capsules[/td][td]Off[/td][td]When on, players can take cargo out of a loaded capsule without unpacking the vehicle, but can't put anything in; a capsule packed in the last ~5 seconds or left unconfirmed by a crash stays locked[/td][/tr]
[tr][td]Allow catching animals[/td][td]On[/td][td]Players can catch live animals in Pal Spheres, from the animal's menu or by throwing; off only stops catching animals, and Pal Spheres already holding one can still release it and be restored by admins[/td][/tr]
[tr][td]Wild catch base chance[/td][td]50 (0–100)[/td][td]Base chance in percent that catching a wild animal works. The final chance is the base plus the Pal Sphere tier bonus and the three bonuses below, at most 100; on a miss the animal breaks free and the Pal Sphere is not used up. 0: wild animals can't be caught (bonuses can't save it); 100: always works. Tame animals and vehicles are not affected[/td][/tr]
[tr][td]Pal Sphere lost on a failed catch[/td][td]Off[/td][td]When on, a wild animal that breaks free on the catch roll also takes the empty Pal Sphere: from the menu it leaves the inventory, a thrown one does not land. Any other miss keeps the Pal Sphere. When on, empty Pal Sphere tooltips show a warning line[/td][/tr]
[tr][td]Injured bonus[/td][td]30 (0–100)[/td][td]Points added to the catch chance of an injured wild animal, in proportion to the health it lost; 0 turns it off[/td][/tr]
[tr][td]Young bonus[/td][td]15 (0–100)[/td][td]Points added to the catch chance of a wild young animal; 0 turns it off[/td][/tr]
[tr][td]Unaware bonus[/td][td]20 (0–100)[/td][td]Points added when the wild animal is not alerted and you are sneaking or behind it; 0 turns it off[/td][/tr]
[tr][td]Days to keep closed records[/td][td]30 days (1–90)[/td][td]Records of capsules that were unpacked, restored or voided are deleted once their last event is older than this; packed and unconfirmed records are always kept[/td][/tr]
[/table]
[list]
[*] [b]Who can pack vehicles[/b]: admins are never limited. With Vehicle Manager installed, claimed vehicles follow it instead (the owner and players with Tow shared) and this option covers unclaimed vehicles.
[/list]
[h3]Minidoracat Pack & Throw - Types[/h3]
[table]
[tr][th]Option[/th][th]Default[/th][th]Notes[/th][/tr]
[tr][td]<Type>: can pack[/td][td]On[/td][td]Off: players can't pack vehicles with this type; loaded ones still throw or unpack with the button, and the empty capsule given back is the same type[/td][/tr]
[tr][td]<Type>: in loot[/td][td]On[/td][td]Whether this empty capsule turns up in loot; never while "can pack" is off[/td][/tr]
[tr][td]<Tier>: can catch[/td][td]On[/td][td]Off: players can't catch animals with this Pal Sphere tier; loaded ones still release their animal, and the empty one given back is the same tier[/td][/tr]
[tr][td]<Tier>: in loot[/td][td]On[/td][td]Whether this empty Pal Sphere turns up at the Pal Sphere loot places; never while "can catch" is off[/td][/tr]
[/table]
[list]
[*] [b]Two per type or tier[/b]: one pair each for the seven capsules (Cartoon, Realistic, Dust, Steam, Sci-Fi, Magic, Shockwave) and for the four Pal Sphere tiers (Pal Sphere, Mega Sphere, Giga Sphere, Legendary Sphere).
[*] [b]Capsule loot shared evenly[/b]: each capsule location's weight is split over the types that are on; the total stays the same.
[*] [b]Pal Sphere loot by rarity[/b]: each Pal Sphere location is split 8:4:2:1 over the tiers that are on.
[/list]
[h3]Minidoracat Pack & Throw - Loot[/h3]
[table]
[tr][th]Option[/th][th]Default[/th][th]Weight[/th][/tr]
[tr][td]Empty capsules and Pal Spheres appear as loot (master switch)[/td][td]On[/td][td]—[/td][/tr]
[tr][td]Mechanic shops[/td][td]On[/td][td]0.5[/td][/tr]
[tr][td]Car supply stores[/td][td]On[/td][td]0.5[/td][/tr]
[tr][td]Gas station repair bays[/td][td]On[/td][td]0.3[/td][/tr]
[tr][td]Home garages[/td][td]Off[/td][td]0.2[/td][/tr]
[tr][td]Barns (Pal Spheres)[/td][td]On[/td][td]0.4[/td][/tr]
[tr][td]Pet stores (Pal Spheres)[/td][td]On[/td][td]0.4[/td][/tr]
[tr][td]Hunting lockers (Pal Spheres)[/td][td]On[/td][td]0.3[/td][/tr]
[/table]
[list]
[*] [b]Master switch[/b]: when off, none of the seven locations spawn empty capsules or Pal Spheres.
[*] [b]Weights[/b]: 0 to 10, on the same scale as the vanilla loot tables; higher means more often.
[*] [b]When it applies[/b]: only to containers opened for the first time afterwards; containers already searched don't refill. Changes made while the server is running apply to containers opened from then on.
[/list]
=== ⚙️ Admin panel
{{img:14-admin-records-en.jpg}}
[list]
[*] [b]Opening it[/b]: admins see a Pack & Throw button on the family toolbar that opens "Pack & Throw Admin".
[*] [b]Hiding the button[/b]: it can be hidden in the options.
[*] [b]Who sees it[/b]: admins; regular players don't see it.
[/list]
[h3]Records[/h3]
[list]
[*] [b]Search[/b]: by capsule number or player name.
[*] [b]Filter by state[/b]: packed, unpacked, restored, voided, unconfirmed after a crash, not seen for 7 days.
[*] [b]Select a record[/b]: see its timeline (every pack, unpack, refusal, restore and verdict with time and player), its cargo list, its recorded spot and when and where the capsule was last seen.
[*] [b]Go to the recorded spot[/b]: teleports you next to the record's location, so you can check on site whether the vehicle is there.
[*] [b]Go to the last sighting[/b]: teleports you to where the server last saw the capsule (on a player, on the ground, in a container or in a vehicle). When a player says a capsule is lost, start looking there.
[*] [b]When sightings are noted[/b]: capsules on players and on the ground near them are noted all the time; one in a container or vehicle is noted when someone opens that container.
[*] [b]Not seen for 7 days[/b]: packed capsules nobody has been near for over 7 days; they may be forgotten somewhere or lost.
[*] [b]Everything is logged[/b]: every pack, unpack, refusal, restore and verdict is written to the capsule records and the server log.
[/list]
[h3]Settings, Types and Loot[/h3]
[list]
[*] [b]Settings[/b]: the general sandbox options of this mod can be changed here (return an empty capsule, return an empty Pal Sphere, allow crafting empty capsules, allow crafting empty Pal Spheres, who can pack, the zombie attraction radius of the capsule sound, taking cargo out of capsules, allow catching animals, wild catch base chance, Pal Sphere lost on a failed catch, injured bonus, young bonus, unaware bonus, days to keep closed records); they take effect as soon as you press "Apply". Long lists scroll, and "Discard changes" and "Apply" stay at the bottom.
[*] [b]Types[/b]: one row per capsule type and per Pal Sphere tier with its "Use" (capsules pack vehicles, Pal Spheres catch animals) and "Loot" switches.
[*] [b]Preview[/b]: press a row's "Preview": the panel steps aside and a capsule of that type is thrown beside you (the Sci-Fi effect for a Pal Sphere), seen by you only. It works before you press "Apply" too.
[*] [b]List...[/b]: with Minidoracat Economy installed, opens a product draft for that empty capsule or Pal Sphere on the Economy Center's shop page; set the price there. One already on sale is skipped.
[*] [b]Loot[/b]: the on/off switch and weight of each of the seven locations (four for capsules, three for Pal Spheres); after "Apply", newly opened containers follow the new settings right away.
[*] [b]Permission[/b]: these are the same values as the vanilla sandbox options; changing them needs the right to change sandbox settings.
[/list]
=== ⚙️ Restoring a vehicle or an animal
[list]
[*] [b]When[/b]: the capsule is gone (lost by the player, removed by a cleanup mod, or this mod was removed and reinstalled), or a server rollback made the vehicle disappear.
[*] [b]When a player dies[/b]: the capsule stays on the body or on the ground; if it can be found, there's nothing to restore.
[/list]
[h3]How to restore[/h3]
{{img:15-admin-restore-en.jpg}}
[olist]
[*] Select the capsule in the records and use "Go to the recorded spot" first.
[*] Press "Restore vehicle". The panel steps aside and a white frame shows on the ground: that's the recorded spot (where the vehicle was last packed or unpacked).
[*] Move the mouse to where the vehicle should go: its ground turns green where it fits, red with the reason where it doesn't. Clicking the white frame restores it at the recorded spot.
[*] Left-click and confirm, and the vehicle appears there facing away from you, with its saved condition. Right-click cancels and the panel comes back.
[/olist]
Records that are unconfirmed after a crash need "I checked on site" ticked first. When you're too far from the recorded spot the white frame isn't shown, and the tooltip asks you to use "Go to the recorded spot" first.
[list]
[*] [b]Go to the recorded spot[/b]: teleports you east of the spot, two tiles clear of the vehicle's ground, so clicking the white frame right away isn't blocked by you.
[/list]
[h3]Restore rules[/h3]
[list]
[*] [b]The cargo doesn't come back[/b]: the cargo lived inside the capsule and is gone with it. The record lists the cargo types and counts; whether to hand anything out is up to the admin, and you can leave a note (for example "replaced the water bottles").
[*] [b]Never an extra vehicle[/b]: restoring makes the original capsule void at the same time, so it can't be unpacked even if it turns up later.
[*] [b]Refused if the vehicle exists[/b]: if the server can find the recorded vehicle in the world, the restore is refused.
[*] [b]Not while trading[/b]: a capsule that is listed or up for auction in the Economy Center can't be restored; the seller cancels the listing first, or the auction ends.
[*] [b]Someone else's safehouse[/b]: a restore onto a spot in someone else's safehouse is refused ("The chosen spot is in someone else's safehouse. Pick another one."); admins with the vanilla safehouse permission are exempt.
[/list]
[h3]Restoring an animal[/h3]
[list]
[*] [b]The button[/b]: for the record of a Pal Sphere holding an animal the button reads "Restore animal" and works like restoring a vehicle.
[*] [b]Landing spot[/b]: the cursor marks a single square and the white frame is the recorded spot; as when releasing an animal, water or under a vehicle won't do, and indoors is fine.
[*] [b]Written back[/b]: the animal appears with its recorded state; the time in the Pal Sphere doesn't count here either.
[*] [b]Refused if the animal exists[/b]: if the server can find that animal near its recorded spot, the restore is refused; it only finds loaded animals, so check on site before deciding.
[*] [b]Go to the recorded spot[/b]: teleports you two tiles east of the spot.
[/list]
=== ⚙️ Unconfirmed after a crash
[list]
[*] [b]How it happens[/b]: the server marks a record as saved about 5 seconds after a pack or unpack. If the server crashes within those seconds, the record shows as "Unconfirmed (crash)" after the restart.
[*] [b]What the player sees[/b]: the capsule can't be unpacked for now, and the player sees "This capsule needs an admin".
[/list]
[h3]Deciding[/h3]
Select the record, check on site, tick "I checked on site", then press:
[list]
[*] [b]Car is there, close[/b]: the vehicle is in the world. A pack record is voided (the original vehicle is still there); an unpack record stays as it is.
[*] [b]Car is gone[/b]: a pack record can be restored as usual; an unpack record goes back to packed, so the player throws the capsule again and gets both the vehicle and the cargo back. If the server can find the vehicle, "Car is gone" is refused.
[/list]
[h3]Extra cargo[/h3]
[list]
[*] [b]Confirmed saved[/b]: when a record is confirmed saved and the vehicle has been unpacked, the server clears the extra cargo out of that capsule and swaps it for an empty one.
[*] [b]Unconfirmed is left alone[/b]: unconfirmed capsules are not touched, because their cargo may be the only copy.
[/list]
[h3]Rolled-back saves[/h3]
[list]
[*] [b]Back on hold[/b]: when the server goes back to a save from before an unpack and the vehicle can't be found nearby, the record goes back to "Unconfirmed (crash)" (the timeline says "Older save, needs a check") and the capsule and its cargo are left alone.
[*] [b]The vehicle really isn't there[/b]: press "Car is gone", so the player throws the capsule again.
[*] [b]The vehicle is there[/b]: press "Car is there, close"; the extra cargo is cleared afterwards.
[/list]
=== ⚙️ Recommended setup
[list]
[*] [b]With Minidoracat Cleaner[/b]: add the seven loaded capsules holding vehicles and the four loaded Pal Spheres holding animals to its "Protected item list" sandbox option so they are never cleaned up from the ground: [b]MinidoracatPackThrow.LoadedCapsuleCartoon[/b], LoadedCapsuleReal, LoadedCapsuleDust, LoadedCapsuleSteam, LoadedCapsuleSciFi, LoadedCapsuleMagic, LoadedCapsuleShock, and [b]MinidoracatPackThrow.LoadedSphereBasic[/b], LoadedSphereMega, LoadedSphereGiga and LoadedSphereLegend (each with the MinidoracatPackThrow. prefix).
[*] [b]Other ground-cleanup mods[/b]: please exclude these eleven items there too.
[*] [b]Back it up[/b]: every capsule's record and vehicle data live in the server's [b]Zomboid/Lua/MinidoracatPackThrow/[/b] folder (one subfolder per world; SP_<mode>_<save> in single player), not in the world save.
[*] [b]If that folder is deleted[/b]: packed vehicles can't be restored.
[*] [b]Back up and restore together[/b]: with the world save; if only the world save is restored, an admin has to check the already-unpacked capsules one by one.
[/list]
=== ⚠️ Known limitations
[list]
[*] [b]3D preview[/b]: draws the vehicle type's default look, not the actual paint and parts.
[*] [b]"Timed action instant"[/b]: with this admin power on, packing, catching, pressing and releasing finish at once and a thrown capsule has no throwing animation (the capsule still flies and unpacks).
[*] [b]Can't be packed[/b]: vehicles that are towing or being towed, carry animals in a trailer, have the engine running or have someone inside.
[*] [b]Animals that can't be caught[/b]: dead, on a butcher hook, being carried, in a hutch or a trailer, or tied with a rope.
[*] [b]Throw to capture[/b]: a target that moves more than a square away from where you aimed between release and landing is missed; an empty capsule only takes vehicles and an empty Pal Sphere only animals, so with both at the spot each takes its own.
[*] [b]Animal timers[/b]: time stands still in a Pal Sphere; after release the milking and petting intervals, the eggs laid that day and breeding cooldowns start over, and a wild animal's herd is not kept.
[*] [b]Animal coat (multiplayer)[/b]: vanilla lets each player's game pick the pattern, so after release different players may see different patterns.
[*] [b]Where it unpacks or appears[/b]: vehicles not indoors; a thrown capsule must land within about 8 tiles and in sight, and a pressed one puts the vehicle within about 3 tiles of the capsule. A released animal appears next to you (the square you face first, indoors is fine), and not while you are in a vehicle.
[*] [b]Vehicle mod removed[/b]: capsules holding its vehicles can't unpack (the tooltip says the server doesn't have this vehicle type); they work again once the vehicle mod is back.
[*] [b]Economy Center[/b]: loaded capsules can only be listed or auctioned: buy requests can't take them and the shop doesn't buy them, and a capsule whose cargo holds something the Economy Center can't carry has to be unpacked first. A recent Minidoracat Economy is needed; older versions refuse loaded capsules.
[*] [b]Capsule and Pal Sphere name[/b]: "Type: vehicle" or "Tier: animal" appears once the inventory or loot window lists it; Economy Center lists title it with the item's own name (for example "Steam Capsule (Loaded)" or "Mega Sphere (Loaded)") and put the vehicle or animal on the next line.
[*] [b]Restoring[/b]: brings back the vehicle, not the cargo; the server only finds vehicles that are loaded nearby, so check on site before deciding.
[*] [b]"Last seen"[/b]: only records the moment the server saw the capsule: one in a container or vehicle updates when someone opens that container, and who took it afterwards or where it went is not known.
[*] [b]After unpacking[/b]: this mod doesn't track the vehicle; use Vehicle Manager for owners and locations.
[*] [b]Crafting window[/b]: when an admin switches crafting, a capsule type or a Pal Sphere tier on or off, a crafting window that is already open shows the change after you close and reopen it.
[/list]
=== ❓ FAQ
[h3]Removing this mod?[/h3]
[list]
[*] Release every vehicle from its capsule and every animal from its Pal Sphere first, then remove it. Capsules and Pal Spheres that are still loaded disappear along with what they hold.
[*] The server records remain, so if you reinstall the mod later, admins can restore the vehicles and animals from the admin panel, but not the vehicles' cargo.
[/list]
[h3]My capsule is gone. What now?[/h3]
[list]
[*] Check bodies, the ground and the vehicle containers first.
[*] If it's really gone, give an admin the capsule number (shown in the tooltip or dialog) or your name.
[*] The admin can see where the capsule went and restore the vehicle (the cargo doesn't come back).
[/list]
[h3]Can I make capsules or Pal Spheres myself?[/h3]
[list]
[*] Only if the server turns on "Allow crafting empty capsules" or "Allow crafting empty Pal Spheres" (both off by default; the admin panel's "Settings" tab can turn them on).
[*] Then stand next to a table or similar surface and find the recipes in the crafting window's "Electrical" category; parts and skills are under "Crafting" in "Getting capsules and Pal Spheres".
[/list]
[h3]What happens to capsules after a server crash?[/h3]
[list]
[*] Mostly nothing.
[*] If the crash came within a few seconds of a pack or unpack, the capsule says it needs an admin; give the number to an admin.
[*] After the admin checks on site, the vehicle and the capsule end up in the right state, with no extra vehicle and no second copy of the cargo.
[/list]
[h3]Do the records keep growing?[/h3]
[list]
[*] No. Closed records are deleted after 30 days by default (sandbox option, 1–90 days); only packed records stay for good.
[*] The number of files is fixed at 513 per world at most.
[/list]
[h3]Can I sell a loaded capsule to someone?[/h3]
[list]
[*] Yes. List it on the Economy Center market or put it up for auction: the buyer gets the same capsule (same number, same cargo), and thrown it's that vehicle.
[*] You can also drop the capsule on the ground and let them pick it up.
[/list]
[h3]Why can't I take things out of a capsule?[/h3]
[list]
[*] By design you unpack the vehicle to get them, so a crash can never create a second copy of the cargo.
[*] Servers can turn on the sandbox option "Allow taking cargo out of capsules" to let players take things out directly; a capsule waiting for an admin still stays locked.
[/list]
[h3]I can't pick up the capsule?[/h3]
[list]
[*] The cargo is too heavy. Right-click the capsule on the ground and choose "Press the Button" to unpack it right there.
[/list]
[h3]Can I pack someone else's vehicle?[/h3]
[list]
[*] A vehicle claimed in Vehicle Manager: only if the owner shared Tow with you (admins need override on).
[*] Other vehicles depend on the server: by default you need the vehicle's key, and admins always can.
[/list]
[h3]I threw it and no vehicle appeared?[/h3]
[list]
[*] The landing spot was blocked when it landed; a window shows the reason and the capsule is on the landing spot.
[*] Pick a clear spot and press the button on the ground, or pick it up and throw again.
[/list]
[h3]Is it safe in multiplayer?[/h3]
[list]
[*] Packing, unpacking and restoring are all validated by the server.
[*] The vehicle data lives only on the server, and the capsule itself only carries its name.
[/list]
[h3]Do animals grow or get hungry inside a Pal Sphere?[/h3]
[list]
[*] No. Time stands still inside a Pal Sphere: the animal doesn't grow or get hungry or thirsty, and a pregnancy pauses; it comes out just as it went in.
[*] Hunger, thirst, health and genetic disorders come back exactly as they were when it was caught. A wild animal that became tame when caught starts getting hungry and thirsty after release, like one picked up in vanilla (vanilla wild animals never get hungry or thirsty).
[*] Only a few vanilla timers start over: the milking and petting intervals, the eggs laid today, and breeding cooldowns.
[/list]
[h3]Does a caught wild animal become mine?[/h3]
[list]
[*] One that can be domesticated (a wild rabbit, for example) becomes tame, just like picking it up in vanilla.
[*] Animals that can't be domesticated, such as deer, stay wild.
[/list]
[h3]Why can't I catch this animal?[/h3]
[list]
[*] Hover the option and read the tooltip: the server may have "Allow catching animals" off or "Wild catch base chance" at 0, you may have no empty Pal Sphere, or the animal is being carried, in a hutch or a trailer, or tied with a rope.
[*] Animals need a Pal Sphere; an empty capsule only takes vehicles, and aimed at an animal it says "capsules can't take animals; use a Pal Sphere".
[/list]
[h3]Why can't I release my animal?[/h3]
[list]
[*] If none of the eight squares around you works (water, under a vehicle, a tree, something in the way, or someone else's safehouse) it says "no free square next to you" and the Pal Sphere stays in your inventory; try somewhere more open.
[*] You can't release in a vehicle; get out first.
[/list]
[h3]Why did a wild animal get away when I hit it?[/h3]
[list]
[*] Wild animals have a catch chance (the base chance is a server setting, 50% by default, plus bonuses for the Pal Sphere tier and the animal's state): a hit or a finished menu catch can still fail. The tooltip shows "Success chance" before you try.
[*] To improve your odds: use a better Pal Sphere, catch an injured or young animal, or strike while it hasn't noticed you (sneak, or get behind it).
[*] The animal stays where it is and by default the empty Pal Sphere is not used up; pick it up and try again. With "Pal Sphere lost on a failed catch" on the sphere goes too, and the tooltip says so first. Tame animals and vehicles are not affected.
[/list]
[h3]Why did my throw miss?[/h3]
[list]
[*] The target moved away while the capsule or Pal Sphere was in the air (more than a square from where you aimed), or in that moment it died, was picked up, or someone got into the vehicle. The screen tells you why.
[*] The empty capsule or Pal Sphere lies on the landing spot (at your feet if that spot is in someone else's safehouse); pick it up and throw again. Aim where the animal is heading, or wait until it stops.
[/list]
[h3]Why can't I pack this in a safehouse?[/h3]
[list]
[*] It's someone else's safehouse: on a multiplayer server, vehicles and animals in someone else's safehouse can't be packed or captured, and nothing can be released there.
[*] The owner, members, staff with the vanilla safehouse permission and safehouse war time are exempt, as in vanilla; in your own safehouse you pack and release as usual.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatPackThrowFor42/issues]GitHub Issues[/url][/b]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]
[*] [b]Please include[/b]:
[list]
[*] your game version
[*] your mod list
[*] the vehicle or animal
[*] what happened (packing or unpacking, single player or multiplayer, and the capsule number from any dialog)
[/list]
[*] [b]Translation issues[/b]: please report them too.
[/list]
