# Block support baseline: Minecraft Java 26.2

This inventory uses the latest stable Java release available on 2026-09-03.
Snapshots for 26.3 are intentionally not treated as released content.

## Added in the full-cube pass

The game now registers 163 additional blocks without changing the existing
numeric IDs. Every entry has a creative-menu item, searchable display name,
world/save and multiplayer identity, collision, face-specific texture mapping,
inventory/held model, matching terrain particles, material sound family,
hardness, empty-hand harvest rule, and flammability where applicable.

- Terrain: coarse dirt, rooted dirt, podzol, mycelium, mud, clay, sand, red
  sand, gravel, moss, pale moss, packed mud, and mud bricks.
- Stone: granite/diorite/andesite and polished forms; the full deepslate,
  tuff, sandstone, red sandstone, and stone-brick cube families; calcite,
  dripstone block, and mossy cobblestone.
- Ores: all eight Overworld stone ores and all eight deepslate ores.
- Storage: coal, iron, raw iron, copper, raw copper, gold, raw gold, emerald,
  lapis, diamond, netherite, and amethyst blocks.
- Nether/End: soul soil; basalt variants; blackstone and Nether-brick cube
  families; both nyliums and wart blocks; Nether gold/quartz ore; ancient
  debris; end stone/bricks; purpur block; quartz cube variants; prismarine
  bricks; and dark prismarine.
- Resin: resin block, resin bricks, and chiseled resin bricks.
- Chaos Cubed: cinnabar, polished cinnabar, cinnabar bricks, chiseled
  cinnabar, sulfur, polished sulfur, sulfur bricks, and chiseled sulfur.
- Color families: all 16 wool, concrete, and terracotta colors.

## Blocks deferred until their engine feature exists

The following are not represented as fake full cubes. The names below cover
the complete released families; color and wood qualifiers mean every released
variant in that family.

### Block-state and non-cube model system

- Every slab, stair, wall, fence, fence gate, door, trapdoor, button, pressure
  plate, sign, hanging sign, shelf, pane, iron bar, chain, rail, carpet, bed,
  candle, cake, skull/head, banner, flower pot, and decorated-pot block.
- Logs, wood, stripped logs/wood, stems, hyphae, stripped stems/hyphae, bamboo
  block, bone block, hay bale, quartz pillar, purpur pillar, and every glazed
  terracotta need axis/facing state.
- Pumpkins, carved pumpkins, jack o'lanterns, melons/stems, mushroom blocks,
  observer, piston, sticky piston, dispenser, dropper, furnace, smoker, blast
  furnace, barrel, loom, stonecutter, cartography table, fletching table,
  smithing table, crafting table, crafter, beehive/bee nest, creaking heart,
  trial spawner, vault, and copper golem statue need facing or richer states.
- Anvils, bells, brewing stands, cauldrons, composters, conduits, end rods,
  grindstones, hoppers, ladders, lanterns, lightning rods, scaffolding, snow
  layers, pointed dripstone, amethyst buds/clusters, chorus plants/flowers,
  cactus, bamboo, big/small dripleaf, and sulfur spikes need custom geometry.

### Cutout vegetation, tinting, and lifecycle rules

- All leaves (including azalea, flowering azalea, mangrove, cherry, and pale
  oak), saplings, grass/fern/tall variants, dead bush, every flower, mushrooms,
  azaleas, crops, cocoa, sugar cane, cactus flower, sweet berry bush, nether
  sprouts/roots/fungi, vines, cave vines, weeping/twisting vines, lily pads,
  spore blossoms, hanging roots/moss, leaf litter, firefly bush, and all coral
  plants/fans.

### Transparency, fluids, and draw ordering

- All stained glass and stained-glass panes, tinted glass, ice/frosted ice,
  slime and honey blocks, cobweb, powder snow, bubble columns, lava, End
  portals/gateways, structure void, barrier, and light blocks.
- Animated block textures that do not yet have bespoke renderers, including
  ordinary prismarine.
- Oak-through-pale-oak leaves also depend on this renderer work in addition to
  foliage tinting and decay.

### Block entities, inventories, and data-bearing blocks

- Chests, trapped/ender/copper chests, all shulker boxes, barrels, furnaces,
  smokers, blast furnaces, hoppers, dispensers, droppers, brewing stands,
  enchanting tables, lecterns, jukeboxes, note blocks, beacons, respawn
  anchors, lodestones, chiseled bookshelves, shelves, decorated pots, signs,
  banners, heads, spawners, trial spawners, vaults, command blocks, structure
  blocks, jigsaw blocks, and test blocks.

### Simulation and special gameplay

- Falling-block simulation: every concrete powder color, suspicious sand,
  suspicious gravel, and anvil falling. Sand, red sand, and gravel are present
  now as ordinary terrain blocks; their falling tick is the remaining behavior.
- Redstone simulation: redstone wire/block/torches, repeaters, comparators,
  levers, buttons, plates, tripwire/hooks, target, lamps, pistons, observers,
  daylight detectors, TNT, crafter, copper bulbs, and powered rails.
- Dynamic light/emission: torches, soul torches, lanterns, soul lanterns,
  glowstone, sea lanterns, shroomlights, magma blocks, jack o'lanterns,
  froglights, redstone ore, crying obsidian, fire/campfires, candles, respawn
  anchors, and portals. Fire and Nether portals already have bespoke support;
  the remaining light emitters await block-light propagation.
- Environmental interaction: sponge/wet sponge, magma damage/bubbles,
  soul-sand slowdown/bubbles, ice slipperiness/melting, farmland/path/trampling,
  grass/mycelium/nylium spread, dirt-to-mud conversion, coral death, leaves
  decay, crop/sapling growth, sculk spread/sensors/catalysts/shriekers/veins,
  turtle eggs, frogspawn, beehives, dragon eggs, gravity blocks, and TNT.
- Copper lifecycle: every cut/chiseled/grate/bulb/door/trapdoor/copper-chest
  variant across exposed, weathered, oxidized, and waxed states.
- 26.2 special behavior: potent sulfur and sulfur spikes await their custom
  geometry/reaction rules. Cinnabar and ordinary sulfur building cubes are in.

## Required registry expansion

Block and item IDs are still one byte in chunk saves, inventory actions, item
entities, and multiplayer packets. This pass ends at ID 197, so 58 numeric
values remain. Before broadening beyond the families above, the format must be
versioned and migrated to at least 16-bit IDs. This pass ends at block ID 196,
leaving 59 numeric values; otherwise old worlds and network traffic would
silently wrap and corrupt blocks.
