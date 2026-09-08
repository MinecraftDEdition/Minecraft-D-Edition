# Functional blocks — local test build

Run `C:\Minecraft D Edition_Admin\Minecraft D Edition Test.exe` from the admin folder. Close any other game window first; the single-instance guard intentionally keeps the existing client. Do not move the executable away from its assets and DLLs.

This is an unpublished test build. Its protocol is 23; it cannot join the public protocol-22 build. Windows compilation and local authoritative/two-client tests were run. The gameplay and rendering changes are shared with macOS, but a macOS executable and hardware verification have not been performed for this pass.

## Included

- Crafting table: 3×3 inputs, mirrored/translated shaped recipes, ingredient consumption, protected output, and returning inputs when closed.
- Furnace: input/fuel/output, a 200-tick smelting cycle, shared multiplayer contents, saved furnace contents/timers, and dropping contents when broken. Supported recipes include meats/fish, raw metals/ores, glass, and cobblestone to stone.
- Enchanting table: tool slot, lapis slot, introductory Efficiency/Sharpness/Unbreaking upgrades, experience/lapis costs, and synchronized enchantments. Efficiency changes mining speed, Sharpness changes damage, and Unbreaking reduces wear.
- Seven tool material tiers (wood, stone, copper, iron, gold, diamond, netherite), each with sword/axe/pickaxe/shovel/hoe; durability, mining speeds, harvest tiers, weapon damage, and durability bars/tooltips.
- Fourteen staple raw/cooked foods, hunger/saturation restoration, 32-tick hold-to-eat behavior, eating/burp sounds, and first-person eating motion.
- Separate third-person tool, flat-item and block grip transforms; corrected first-person sprite rotation order/coordinate conversion, including flint and steel.
- Empty-air right-clicks no longer start a punch. Successful block placement, workstation use and fire/portal ignition still swing.
- Creative Search no longer resets its scroll every frame; later catalog indexes no longer overlap the trash target.
- Host-authoritative `/give`, `/kill`, `/clear`, `/tp` (`/teleport`), `/gamemode`, `/xp`, `/help`; command/item/player suggestions, Up/Down selection, and Tab/Enter completion.

## Quick test

Use a new disposable Creative world. Find the three workstations under Functional Blocks or Search; tools and food have their own tabs.

1. Place and open a crafting table. Four planks in a 2×2 square produce a crafting table; two vertical planks produce sticks. A row of three materials over two sticks produces a pickaxe. Check left/right click transfers and closing with inputs left in the grid.
2. Put raw beef in a furnace's top slot and coal in its lower slot. Cooked beef appears after ten active server seconds. Close/reopen, leave/rejoin, and try two viewers to verify shared contents. Break the furnace to recover remaining contents.
3. Put a pickaxe and lapis in the enchanting table. For a Survival cost test, use `/xp 15 @s`, then choose an upgrade. The current three requirement levels are 5/10/15, with costs of 1/2/3 levels and lapis respectively. Creative is free.
4. Compare wooden versus diamond pickaxe mining, check wear, and drop/recover an enchanted tool. Its wear/enchantment must survive.
5. Hold use with food selected. In Survival, hunger must be below full; Creative permits animation testing at full hunger. Releasing early must cancel without consuming food.
6. Test `/give @s diamond_pickaxe`, `/give @a bread 3`, `/clear @s bread`, `/tp @s ~2 ~ ~2`, and `/gamemode survival`. `/kill` is destructive to the selected character, so use it only in the disposable test world.

## Deliberately limited in this first pass

This is not full Java workstation/survival parity. Recipes are currently a starter set (workstations, sticks, basic tools, flint and steel, bread), not the complete recipe registry. Survival's personal 2×2 crafting grid/recipe book, smithing/netherite upgrades, full enchantment rolls/bookshelf scaling, enchanting-book animation/glint, status-effect foods, farming/hoe tilling and axe stripping are not implemented here. Furnace facing/lit-state visuals and workstation Shift-click routing also need expansion. These should be completed before calling this a finished survival progression update.

## Validation

- `dub test`: 37 modules passed, including authoritative crafting, shared furnace extraction/closure, furnace break drops, enchantment costs, food timing, and inventory/network metadata round trips.
- `tests/functional_blocks_smoke.d`: two real loopback clients passed login/protocol, host permission denial for a guest, item ID 255, stack limits, and give/clear/gamemode/xp/tp/kill.
- `dub build --config=local-test --build=release`: Windows release test executable.
- The admin application launched successfully. Full visual/gamepad/macOS acceptance remains for hands-on testing.

## Lighting seam diagnosis (not repaired in this build)

`tests/lighting_seam_diagnostic.d` reproduces a concrete invalidation bug: placing fire four cells before a chunk boundary changes the neighbor's block-light sample **0 → 11**, while that neighbor's mesh revision remains **2 → 2**. `WorldLighting` notices the changed neighbor dependency, but the resident mesh scheduler considers the old mesh current. Editing the affected chunk makes it remesh and pick up the correct light, matching the reported symptom.

`World.markBlockDirty` currently bumps neighbors only for edits directly on a geometric boundary, although light can reach 15 blocks. `WorldLighting` also computes skylight with only a one-cell horizontal border, so independent chunk solves can disagree near openings. A fix should track light-region dependencies separately from geometry dirtiness, enqueue all affected mesh sections, and use consistent boundary lighting. Simply rebuilding every chunk on every edit would undo the performance work.

The imported Java model references used for grips/layout are in `assets/minecraft/models/item/{generated,handheld}.json`, `assets/minecraft/models/block/{block,crafting_table,furnace,enchanting_table}.json`, and the corresponding GUI textures. Background reference: [Minecraft's crafting guide](https://www.minecraft.net/en-us/article/how-craft).
