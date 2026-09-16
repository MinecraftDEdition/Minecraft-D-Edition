# Environment and movement fixes

Spruce trunks now range from 6–8 blocks in ordinary biomes and 9–11 in tall
biomes, with a continuous tapered canopy instead of skipped foliage layers.
Other tall tree variants use a smaller height bonus. Existing saved trees are
not rewritten; use newly generated terrain to inspect these changes.

Collision sweeps now block unloaded terrain and tolerate tiny floating-point
overlaps at a contacted face. Both client prediction and server movement use
the same implementation. This addresses unloaded-boundary traversal and the
observed boundary precision failure; it is not a guarantee against every
possible collision/desynchronization issue.

Packed ice uses slipperiness 0.98, blue ice 0.989. Ground acceleration is scaled
by slipperiness cubed and horizontal drag retains 0.91 times slipperiness each
20 Hz tick. Ordinary walking, flight and swimming keep their existing controls.
Attack clicks swing even when aiming at air; empty use clicks do not swing.
Mining a target and successful server interactions still animate. The multiplayer tests cover empty clicks as well
as successful edits, paused actions and two-player delivery.

Fire combines four crossed inner sheets with four upright perimeter sheets.
It uses an alpha-tested, double-sided depth-writing pass
before transparent water/glass; section submission order cannot make distant
flames cover nearer ones.

Skylight is propagated through a full neighboring light radius, then cropped
back to compact cached chunk storage. Lighting-affecting edits invalidate
neighbor meshes even when the edited block is not on the exact chunk edge.
Server subscriptions retain three extra chunk rings, and world eviction keeps
one further ring, to reduce boundary loading/unloading churn. These remain
bounded by view distance; they do not imply terrain loading is instantaneous.

The Overworld now has a camera-centered horizon gradient matching terrain fog,
fading upward into the existing sky color. Water and Nether keep their distinct
fog handling. No renderer-specific shader change is needed.

References: Minecraft's developer notes distinguish environmental and sky fog:
https://www.minecraft.net/en-us/article/minecraft-snapshot-25w16a
The clientcommands API documents Minecraft block slipperiness (normal 0.6,
ice 0.98):
https://github.com/Earthcomputer/clientcommands-scripting/blob/master/docs/clientcommands.ts

Validation: environment_smoke checks skylight agreement across chunk caches,
fire geometry, collision barriers, precision and ice momentum. The DX12/Vulkan
terrain render test checks fire depth ordering in both submission orders and
the visible horizon gradient. Existing generation and multiplayer streaming
tests remain in Run-TerrainSmoke.ps1.


Follow-up regressions: attack clicks swing even when aiming at air; empty use
clicks remain silent. Terrain particles use the same species tint as block
faces (including untinted cherry and pale oak). Fire retains its four inner
sheets and now adds four upright perimeter sheets, with the existing
world-depth-tested, double-sided alpha-cutout rendering path.
