# First zombie prototype

Creative inventory → Spawn Eggs → **Spawn Zombie**. Select the egg and use it
while aiming at a block within five blocks. The zombie's feet are placed on
that block's top. Placement requires room for its body and rejects another
zombie occupying the same space. Creative does not consume the egg.

The zombie is deliberately stationary: no AI, navigation, tracking, attacks,
gravity, knockback movement, natural spawning, equipment or loot. It has 20
health, can be hit within three blocks, displays hurt/death effects, and
disappears after its death animation. No attacks pass through nearer blocks
or players. Zombies save with the world in `zombies.dat`. A world currently
allows up to 128 zombies; simulation runs near players and respects singleplayer
pause. Both multiplayer clients receive the same authoritative state.

The shared DX12/Vulkan model uses the wide player body, mirrored zombie limb
UVs, and the zombie head overlay. Idle holds arms at 90 degrees forward;
walking, attacking, crouching and swimming animation code remains available
for later development. Idle does not bob the arms. The shared renderer also
serves macOS through MoltenVK.

Resource packs override `minecraft:textures/entity/zombie/zombie.png`,
`minecraft:textures/item/zombie_spawn_egg.png`, the zombie OGG assets and
`entity.zombie.ambient`, `.hurt`, `.death` sound definitions. 64×64 and legacy
64×32 zombie skin proportions (including scaled resolutions) use the same
mirrored limb layout. The Hostile Mobs slider controls its voice.

## Sunlight and sounds

Minecraft's sun check uses daylight, brightness, exposure at eye height, and
water/rain/snow protection. It checks sky visibility rather than limiting how
many blocks above the head a roof may be. The prototype checks the whole
loaded column to the build limit. Opaque blocks and water provide shelter;
glass transmits sky light. Unknown/unloaded terrain is not treated as open sky.

D Edition currently has a fixed daytime sky, with no day/night or weather
cycle. Full daylight has a 4% ignition chance per 20 Hz tick and refreshes an
eight-second burn. Existing fire continues briefly after shelter is added;
water extinguishes it. Burning deals one damage per second. Nether zombies
do not ignite from daylight.

Ambient voice uses Minecraft's randomized counter rule: after a groan or hurt
sound, 80 ticks (four seconds) of quiet precede an increasing random chance.
This is not a fixed four-second loop. Hurt audio follows accepted damage;
death audio replaces the final hurt sound. Network sound counters prevent
replayed snapshots from duplicating sounds. Stationary mobs do not play steps.

References inspected: [Mob sunlight/ambient implementation](https://github.com/mahtomedi/minecraft/blob/main/src/main/java/net/minecraft/world/entity/Mob.java),
[Zombie ignition and sound events](https://github.com/mahtomedi/minecraft/blob/main/src/main/java/net/minecraft/world/entity/monster/Zombie.java),
[Humanoid mirrored limb UV layout](https://github.com/mahtomedi/minecraft/blob/main/src/main/java/net/minecraft/client/model/HumanoidModel.java).

## Compatibility and checks

Item IDs were already using all 256 byte values. Item IDs and inventory-action
targets now use 16 bits; existing numeric IDs are unchanged. Block IDs remain
bytes. Protocol 25 rejects older clients before they can misread snapshots.
All machines in a multiplayer session must use the new build.

Tests cover distant shelter, water/Nether protection, damage/death, stationary
position, spawning/reach/obstruction, persistence, high item-ID round trips,
sound deduplication and idle/animation/UV geometry. `zombie_network_smoke.d`
exercises the creative egg and shared zombie through two real connections.
`zombie_render_smoke.d` captures front/side/back using DX12 and Vulkan.
