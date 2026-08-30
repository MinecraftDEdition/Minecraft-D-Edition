# Minecraft: D Edition

An independent voxel game project written in D. Windows currently supports
interchangeable DirectX 12 and Vulkan renderers while the Vulkan path is being
prepared for Linux and MoltenVK on macOS.

[Website](https://minecraftdedition.com) ·
[Downloads](https://github.com/MinecraftDEdition/Minecraft-D-Edition/releases/tag/Test) ·
[Report a bug](https://github.com/MinecraftDEdition/Minecraft-D-Edition/issues)

> Minecraft: D Edition is an independent fan-made project. It is not affiliated
> with, endorsed by, or sponsored by Mojang Studios or Microsoft. Minecraft is
> a trademark of Microsoft.

## Install and update

Windows releases currently use a small per-user web installer and a lightweight launcher.
The setup executable contains no game archive: the launcher obtains verified
runtime files from the GitHub `Test` release, then downloads only the content
shards containing changed files on future launches. Worlds, options, EOS
configuration, and other player-owned files are never part of the update
manifest. Release building, publishing, rollback behavior, and smoke tests are documented in
[`docs/distribution.md`](docs/distribution.md).

macOS and Linux will be distributed as their own native packages rather than
including every operating system's executable in one installation. All desktop
builds continue to share the game rules, assets, world format, and multiplayer
protocol, so native packaging does not prevent cross-play. The target layout is
documented in [`distribution/`](distribution/README.md), and the protocol
compatibility boundary is documented in
[`docs/cross-platform.md`](docs/cross-platform.md).

Player installations default to
`%LOCALAPPDATA%\Programs\Minecraft D Edition` and contain no GitHub publishing
access. Development and releases use the separate Admin checkout at
`C:\Minecraft D Edition_Admin`.

## Layout

- `assets/minecraft/` mirrors Minecraft Java Edition's client-resource namespace.
- `data/minecraft/` mirrors the modern Java data-pack namespace.
- `source/minecraftd/` separates shared game code from client, server, audio,
  networking, world, and platform graphics code.
- `distribution/windows/` contains the active Windows installer and updater;
  `distribution/macos/` and `distribution/linux/` own their future native
  packaging without duplicating game code.
- `tools/` contains local asset-import utilities.
- `tests/` is reserved for unit and integration tests.
- `docs/` contains generated import manifests and project notes.
- `website/account/` contains the Cloudflare Worker account site and protected
  profile API; Auth0 handles credentials while D1 stores usernames, sessions,
  and validated player skins.

## Renderer selection

DirectX 12 remains the default Windows renderer. To test the independent
Vulkan backend on Windows, start the same game executable with:

```powershell
.\Minecraft D Edition.exe --renderer=vulkan
```

Use `--renderer=dx12` to force DirectX 12. The **Graphics API** option under
Video Settings also selects DirectX 12 or Vulkan for the next launch. Building
the Vulkan backend currently requires the Vulkan SDK through `VULKAN_SDK`; the
installed game only requires a working Vulkan graphics driver.

The shared-backend boundary, supported render passes, current limitations, and
planned Linux/macOS packaging are described in
[`docs/renderer-backends.md`](docs/renderer-backends.md).

Imported Minecraft assets are for local development only. They are not original project assets and should not be redistributed with the game without permission from their copyright owner.

## Current controls

- `WASD` moves, `Space` jumps, `Left Ctrl` sprints, and `Left Shift` crouches by
  default. These and the other implemented gameplay inputs can be rebound under
  **Options > Controls > Key Binds > Keyboard & Mouse**.
- Hold left mouse to mine; the arm, destroy-stage overlay, particles, and block-local sounds progress together.
- Right-click places the selected block stack when the target face is clear.
- `1` through `9` or the mouse wheel selects a hotbar slot.
- `F5` cycles first person, third person behind, and third person front.
- **Options...** is available from both the title screen and pause menu. Its
  Java 26.2-style hierarchy includes dedicated Online, Skin, Sound, Video,
  Controls, Mouse, Key Binds, Language, Font, Chat, Resource Packs,
  Accessibility, Telemetry, and Credits screens. Implemented controls apply
  immediately and persist in `data/options.txt`, including rebindable keys,
  auto-jump and hold/toggle controls, skin layers, sound categories, chat layout,
  VSync/frame limiting, brightness, smooth lighting, clouds and particles.
  Future-only settings are visible but disabled. Sliders support click-and-drag
  and use the horizontal resize cursor instead of the link-hand cursor.
- `T` opens Java-style chat. Type a message, press `Enter` to send it through
  the integrated TCP chat server, or press `Escape` to cancel.
- `Escape` opens the pause menu. The integrated server freezes only while the
  host is its sole player; joining immediately resumes the world, and menus do
  not pause multiplayer sessions. Publishing requires confirmation, then opens
  a read-only server information screen where the private EOS invitation can
  be copied. If EOS is unavailable, the screen clearly falls back to a LAN-only
  address.
- On the title screen, `Right Shift + Plus + 1-9` opens that many total local
  clients for multiplayer testing.

Each singleplayer world binds an authoritative integrated game server to a
Windows-assigned port. Publishing normally exposes a private
`mcd://eos/<host-id>/<session-secret>` invitation. EOS performs NAT traversal
and can relay traffic, so Internet players do not configure either router.
Direct-connect entries also continue to accept `host:port` for LAN play and
persist a display name and address. Additional local processes connect as
`Steve2` through `Steve9` in server join order.
The server owns the world at 20 TPS and validates movement, collision, mining,
block placement, survival state, dropped items, inventory changes, and chat.
Clients predict their own movement, reconcile acknowledged inputs, and
interpolate snapshots for remote players. The server processes every sequenced
input exactly once, including inputs arriving together in one network burst.
Disconnected clients retry every two seconds; idle peers time out after ten
seconds.

Joining clients receive a complete authoritative terrain snapshot before play.
Remote players render with camera-facing nameplates (64-block standing range;
32-block, depth-tested range while crouching), while the local player's own
nameplate remains hidden in third person. Bare-hand PvP is server-authoritative:
the server validates a three-block entity ray, applies health damage, hurt tint,
camera response, and Java-style normal or sprint-hit knockback. A hit made while
falling is a critical hit: it deals 1.5x damage and broadcasts the vanilla
critical-hit particles and sound to every client.

The currently registered empty-hand loot follows the imported vanilla tables:
grass blocks and dirt drop dirt, while stone breaks without a drop unless a
correct tool is added later. Dropped blocks bob and spin, have a ten-tick pickup
delay, play the vanilla pickup sound, and stack to 64. Hotbar block icons use an
isometric cube and the stack's five-tick count-change pop animation.

## Multiplayer integration smoke test

```powershell
C:\D\dmd2\windows\bin64\dmd.exe -i -Isource tests/network_smoke.d
.\network_smoke.exe
```

The smoke test opens two loopback clients, verifies unique login IDs and shared
snapshots, acknowledges predicted input, mines a block authoritatively, picks
up its drop, updates the inventory, and places the resulting stack.

To verify the installed EOS SDK and local Developer Portal credentials without
opening a window:

```powershell
.\Minecraft D Edition.exe --eos-smoke-test
```

For the final two-PC relay test, set `"forceRelays": true` in both PCs'
`data/eos.local.json`. This deliberately disables the direct peer route; a
successful connection then proves Epic's relay path is carrying the session.
Return it to `false` afterward for the lowest available latency.

The complete host/join and forced-relay checklist is in
[`docs/eos-two-pc-test.md`](docs/eos-two-pc-test.md).

## Import installed Java Edition sounds

```powershell
python tools/extract_minecraft_sounds.py --target-assets assets
```

The importer reads Mojang asset indexes, restores the logical `assets/minecraft/sounds/...` paths, verifies each object by SHA-1, and writes an audit manifest under `docs/`. Minecraft Java audio objects are already Ogg streams, so they are copied without re-encoding. If a discovered audio object is not Ogg, the tool can invoke FFmpeg when it is installed.

## Import installed Java Edition textures

```powershell
python tools/extract_minecraft_textures.py --target-assets assets
```

The texture importer verifies installed vanilla client JARs against their version metadata, ignores mod-loader wrappers, and reconstructs the union of namespaced textures under `assets/minecraft/textures/`. Newer installed versions win when a texture changed. PNG files, animation `.png.mcmeta` files, and atlas definitions are validated and recorded in a manifest under `docs/`.

## Import the remaining client resources and game data

```powershell
python tools/extract_minecraft_client_resources.py --project-root .
```

This importer selects the newest verified vanilla client and copies its remaining data-driven resources under `assets/minecraft/` and `data/minecraft/`. It also reconstructs non-audio files from that version's hashed asset index, including languages and font data. Compiled Java classes are deliberately not copied.
