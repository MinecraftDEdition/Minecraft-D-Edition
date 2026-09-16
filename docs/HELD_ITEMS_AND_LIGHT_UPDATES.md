# Held items and synchronized lighting

Light-affecting block edits are coalesced into a set of affected cached chunks.
The shared section budget builds replacement meshes across frames, uploading
one completed column at a time. The old meshes remain visible until the whole
lighting group is ready, then all replacements become visible together.
Revisions are checked again before publication; stale work is discarded.
This avoids the previous unbounded nine-column synchronous rebuild. It does
not promise zero update latency: complex terrain can need several frames.
Skylight propagation queues only the frontier instead of every open-sky cell.

Third-person items are transformed into world-space vertices before submission.
Previously only their clip-space matrix included their world location, while
the fog shader read untransformed item coordinates. This caused distant
Overworld items to turn fog-colored. Items now sample the same world-light
position as the player and update directional shading with their posed normals.
Shared cached inventory geometry is copied before shading or transformation.

Player arms and held items share calculateArmPose, including the ordering of
idle sway and the carrying pose, head-dependent attack motion, crouching and
swimming. The rigid-attachment test derives an arm-local basis from the actual
rendered skin vertices and checks three item points across animation poses,
both hands and classic/slim arms.

Grip references were inspected directly in the installed Minecraft 1.21.9
client JAR: models/block/block.json, models/item/generated.json,
models/item/handheld.json and models/item/flint_and_steel.json. Block third-person
display uses rotation [75,45,0], translation [0,2.5,0], scale 0.375. Flint and
steel inherits generated: translation [0,3,1], scale 0.55. These transforms are
composed before the hand attachment rotation. Existing weapon and stick grip
layouts are retained as requested.

Model display documentation:
https://docs.fabricmc.net/develop/items/item-models

Tests: held_item_pose_smoke checks attachment to real arm vertices;
render_units exercises 36 imported modules, including bounded, grouped neighbor
updates, world-space item coordinates and Nether light response.


Geometry visibility hotfix: block/section patches remain eligible while a
lighting batch is pending. Breaking a block removes standalone cached faces
immediately, and the prioritized section patch handles merged faces and newly
exposed neighbors. Lighting transactions must never block geometry updates.
The renderer regression test breaks a block in a merged surface while lighting
is pending and compares the patched mesh with a fresh mesh before publication.
