# Player saving and foliage fixes

Player data is stored per world in `playerdata/<SHA-256 identity>.dat`.
The integrated owner uses `host`; guests use their account ID or offline
name. The versioned format is independent of network snapshots. It preserves
position, view, dimension, inventory (including cursor and crafting slots),
selected slot, game mode and player survival state. Invalid saves are rejected
with a load error instead of silently replaced.

Every 30 seconds, including while singleplayer is paused, the server saves
dirty chunks, mobs, workstations and players. Clients show a fading bottom-right
Saving World indicator. Save & Quit and normal window closing send pending
actions and final view direction, wait for server save confirmation, then
disconnect. Integrated-server shutdown also drains accepted inputs and saves.
Remote servers own multiplayer saves; clients do not supply authoritative
positions. A forced process kill cannot run graceful shutdown, so recovery uses
the last completed autosave.

Files are written to a sibling temporary file and atomically replaced. This
protects each previous file from interrupted writes; the entire world is not a
single transactional snapshot. Protocol 28 requires matching client/server
builds. Offline names are persistence identifiers, not authenticated identities.

Leaves retain all six faces regardless of neighbors. Leaf skylight attenuation
also applies during light propagation, so foliage shades the ground beneath it.
This uses the existing voxel lighting system. Fullscreen geometry changes reset
mouse deltas without changing the player's stored camera angles. New worlds no
longer receive a test portal at spawn; previously placed portal blocks remain.

Validation: player_persistence_smoke covers paused autosave, save acknowledgment,
restart, inventory metadata, final view, actual MultiplayerClient logout and
server shutdown. foliage_smoke covers surrounded leaf faces and canopy lighting.
fullscreen_mouse_smoke covers repeated Windows fullscreen transitions and the
window-close signal. Run-TerrainSmoke checks DX12/Vulkan foliage rendering and
multiplayer terrain/interaction regressions. Mac persistence is also in CI;
native Mac fullscreen behavior requires testing on macOS.
