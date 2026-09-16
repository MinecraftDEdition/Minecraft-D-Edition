# Overworld generation, version 2

New normal worlds use generator 2. Existing `level.dat` files without a
`generator` field use generator 1, including their unexplored chunks. Loaded
chunk snapshots are never regenerated. Flat worlds and the Nether retain their
existing algorithms. Create a new world to evaluate this terrain; changing an
existing world's generator manually can create seams and is not a migration.

## Findings in the original generator

* The river noise threshold replaced any intersecting column with a bed around
  Y=56–59. It did not account for the previous elevation or provide a valley
  shoulder. This directly explains the deep, sheer river cuts in the screenshot.
* Oceans switched to a different height formula at a hard continental threshold,
  producing another source of abrupt changes.
* Cave carving included a periodic sine/cosine expression. Its seed phase used
  only ten seed bits, creating repeated, unusually regular tunnel paths.
* There was one grass/dirt surface everywhere, without a climate/biome pass or
  tree features. Water filling did not distinguish terrain climate.
* Spawn selection assumed nearby grass and could fall back to an ocean floor.
  Its clearing operation also flattened a small grass platform regardless of
  the local surface.
* Adding leaves exposed an existing material limitation: partially transparent
  pixels were alpha blended while writing depth. Drawing foliage before terrain
  then left sky-colored pixels over that terrain. The shared shader now supports
  alpha cutout independently of transparent water/glass.

## Implementation

`world/generation/noise.d` provides deterministic, full-seed coordinate hashes,
double-precision noise coordinates, smooth value noise, and 3D gradient noise.
There is no global random-number state or dependence on worker order.

`overworld.d` combines broad continents, erosion, ridges, domain warping and
detail. Shorelines interpolate continuously. River valleys suppress mountain
relief over wide shoulders, and the final channel excavation is capped at 24
blocks instead of forcing every mountain down to sea level. Rivers here are
noise-based valley networks, not a drainage/erosion simulation.

Temperature, humidity, variation and elevation select the surface climate.
Surfaces include sand/sandstone, red sand and terracotta bands, gravel/stone,
snow, podzol, mud/clay, pale moss and mycelium. Cold water receives packed ice.
Deep stone becomes deepslate. Caves combine irregular chambers and intersections
of two noise fields with local gates. A world-aligned four-block density grid
limits noise evaluation cost. Underground cavities keep a roof beneath water;
rare dry entrances can reach the surface.

`biomes.d` owns surface materials, tree species and density. `trees.d` evaluates
8×8 anchor cells with jitter, samples neighboring anchors, and writes only the
part inside the destination chunk. Canopy/branch bounds stay within an
eight-block halo. This avoids cut-off trees and generation-order seams.

Nine log/leaf families are available in creative inventory: oak, spruce, birch,
jungle, acacia, dark oak, mangrove, cherry and pale oak. Logs craft into four
matching planks. Leaves are solid cutout blocks, attenuate skylight and shelter
zombies. Existing block/item IDs remain unchanged; new IDs are appended.
Protocol 27 prevents older clients from interpreting unsupported IDs.

Textures resolve through the existing resource-pack system using canonical
`textures/block/*_log.png`, `*_log_top.png` and `*_leaves.png` paths. Leaf color
and cutout settings apply to world, held, dropped and inventory rendering.
The HLSL shader and checked-in SPIR-V are updated together for DX12 and
Vulkan/MoltenVK. The shader constant buffer size is unchanged.

The existing structures option retains its meaning; it does not disable trees.
The saved `trees` field independently controls vegetation and defaults to on.

## Research baseline and biome catalog

Inspected the installed Java **26.2** JAR's `data/minecraft/worldgen/biome`,
`noise_settings/overworld.json`, and tree feature configuration. These data were
used to verify names, stages and parameters; this implementation is original
and does not reproduce Minecraft's generator code or its seed outputs.

The released surface Overworld catalog contains **51** entries:

| Family | Biomes |
|---|---|
| Open land | Plains, Sunflower Plains, Snowy Plains, Ice Spikes, Desert |
| Forest | Forest, Flower Forest, Birch Forest, Old Growth Birch Forest, Dark Forest, Pale Garden |
| Taiga | Taiga, Snowy Taiga, Old Growth Pine Taiga, Old Growth Spruce Taiga |
| Savanna | Savanna, Savanna Plateau, Windswept Savanna |
| Tropical/wetland | Jungle, Sparse Jungle, Bamboo Jungle, Swamp, Mangrove Swamp |
| Badlands | Badlands, Eroded Badlands, Wooded Badlands |
| Mountain | Meadow, Cherry Grove, Grove, Snowy Slopes, Jagged Peaks, Frozen Peaks, Stony Peaks |
| Windswept hills | Windswept Hills, Windswept Gravelly Hills, Windswept Forest |
| Island | Mushroom Fields |
| Coast | Beach, Snowy Beach, Stony Shore |
| River | River, Frozen River |
| Ocean | Ocean, Deep Ocean, Cold Ocean, Deep Cold Ocean, Frozen Ocean, Deep Frozen Ocean, Lukewarm Ocean, Deep Lukewarm Ocean, Warm Ocean |

Underground biomes (including 26.2 Sulfur Caves), Nether/End biomes and The Void
are outside this surface catalog. The 26.3 preview's Dappled Forest/poplar trees
are outside the released 26.2 baseline.

References:

* [Minecraft world-generation stages](https://learn.microsoft.com/en-us/minecraft/creator/documents/world-generation?view=minecraft-bedrock-stable)
  describes the separation of terrain, climate, surface and features. This is
  Bedrock documentation, not a claim that Java uses identical implementation.
* [Java 26.3 Snapshot 1](https://www.minecraft.net/en-us/article/minecraft-26-3-snapshot-1)
  identifies the preview generation additions separately from the baseline.

## Scope and remaining fidelity work

All 51 climate categories are reachable, but this is **not complete biome
feature parity**. Several variants currently share their family's surface and
trees. Flowers, sunflowers, bamboo plants, giant mushrooms, ice-spike structures,
coral, mangrove root blocks, vines and full eroded-mesa features need additional
blocks/features. Trees are static, with vertical bark axes, and do not yet have
sapling growth or leaf decay. Leaf tint uses species colors rather than a
networked per-biome colormap. Surface climate is calculated from seed rather
than stored as editable biome data.

The terrain surface remains a height field; full 3D overhang terrain, aquifers,
hydrological river flow, underground biomes, ores and generated buildings are
separate future passes. Flat/Nether generation intentionally remains unchanged.

## Validation

`tests/overworld_v2_smoke.d` samples five seeds over 6,144×6,144-block regions,
including negative seeds, high seed bits and near-border coordinates. Initial
results: 327,680 columns, heights 26–223, all 51 categories, maximum adjacent
height difference 4 blocks and maximum sampled shoreline difference 1 block.
These are measured samples, not a proof covering every seed.

The same test checks generation order, trees crossing edges, solid bedrock,
cave/vegetation toggles, block/item round trips, log crafting and metadata
version defaults. Fifty optimized test chunk generations took about 94 ms on
the development PC; this excludes lighting, meshing, I/O and network costs.

`world_generation_smoke.d` covers save/reload, spawn, world bounds and unchanged
Nether generation. Multiplayer tests include appended log inventory IDs and
leaf chunk data. `terrain_render_smoke.d` renders actual generated terrain in
DX12 and Vulkan and checks cutout opacity/discard with controlled texels.
Generated maps and renderer captures are written under `test-output/terrain`.
