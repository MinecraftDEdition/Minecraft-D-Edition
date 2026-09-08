# Multiplayer terrain stability

Local test build: `C:\Minecraft D Edition_Admin\Minecraft D Edition Test.exe`.
Run it from the Admin directory so it finds the assets and DLLs. The September 7
Test-channel update includes these changes. All participants need protocol **24**;
older versions are rejected because they can reorder terrain across EOS channels.

## Changes

- Empty vertical intersections return an empty mesh before any unsigned mask
  allocation. This covers cached sections above/below a replacement chunk or
  sections whose last high block was removed.
- EOS uses one reliable ordered stream. Client terrain snapshots, block edits,
  and unloads share a deferred FIFO. Login and dimension changes discard the
  previous world's pending terrain. One snapshot and at most 256 operations
  are admitted per poll, with a three-millisecond soft budget checked between
  operations.
- Client block deltas never generate absent chunks. Servers send block deltas
  only to subscribed peers. New subscriptions receive current snapshots.
- Chunk revisions are not reused after unload/reload. Cached meshes also track
  the source chunk's identity, so replacing a chunk evicts its obsolete mesh
  before drawing, even if that frame cannot build new geometry.
- Edits are coalesced into vertical bands. At most one band (up to two cached
  sections when bands are unaligned) is patched per frame, with one chunk
  upload. Patch frames alternate with background meshing during sustained
  edits. A partial patch never marks an entire chunk revision complete.
- Deferred terrain is capped at 16 MiB/65,536 packets; the receive inbox and
  each EOS host outgoing queue are capped at 32 MiB with packet-count limits.
  An overloaded peer disconnects for resynchronization instead of allowing an
  unbounded backlog. Queue draining transfers ownership and releases consumed
  payloads rather than copying the remaining queue after every chunk.

## Automated validation

Run from the Admin directory:

```powershell
dub test
dmd '-i' '-Isource' '-of=terrain_network_smoke.exe' 'tests\network_smoke.d'
.\terrain_network_smoke.exe
dmd '-i' '-Isource' '-of=terrain_streaming_smoke.exe' 'tests\terrain_streaming_smoke.d'
.\terrain_streaming_smoke.exe
dub build --config=local-test --build=release
```

Passed: 37 unit-test modules, including negative-height meshing, chunk revision
reuse, queued snapshot/edit/unload ordering, absent-chunk edits, queue overflow,
coalesced patch uploads, and eviction of replaced meshes. The gameplay smoke
test passed with two TCP clients. The streaming smoke test passed with 40 raw
chunks per client followed by edits/unloads and replacement at a different
height in the Nether. DirectX 12 application startup remained responsive and
closed normally without a new crash log.

## Multiplayer playtest

Use a disposable world and the protocol-24 build on both machines. Fly across
chunk boundaries, return to earlier terrain, edit high isolated blocks, spread
water, and travel between dimensions. Verify that edits remain after terrain
arrives, unloaded terrain does not reappear, and both players agree on ground
height and collision. Watch the existing debug overlay's mesh/frame times and
loaded-chunk count while moving and after standing still.

The automated socket tests use TCP loopback; a distinct-machine EOS relay
session and sustained in-world FPS/memory measurements remain manual acceptance
checks. A single expensive mesh/lighting operation or GPU upload can still exceed
the soft budget; this change bounds burst work rather than promising a fixed FPS.
