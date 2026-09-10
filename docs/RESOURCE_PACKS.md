# Resource packs

D Edition loads Minecraft Java resource packs from ZIP files or unpacked folders.
Open **Options → Resource Packs → Open Resource Pack Folder**, place packs there,
return to the game, select packs, and press **Done**. Use the arrows to change
their order. The top selected pack has priority; missing assets fall through to
lower packs and finally Default. Removing a pack from Selected does not delete it.

`pack.mcmeta` must be at the ZIP/folder root, alongside `assets/` and optional
`pack.png`. A ZIP containing an extra outer folder must be repackaged first.
Different-version packs show a warning and remain selectable.

## Storage and updates

Windows stores packs in `resourcepacks/` under the game's user-data directory
(the Admin installation for local testing). macOS uses
`~/Library/Application Support/Minecraft D Edition/resourcepacks/`.
The folder button opens the actual location for the current session.
Selection is saved in `data/resource-packs.json`; extracted ZIPs are cached under
`data/cache/resourcepacks/` using the archive's SHA-256 hash. Packs never replace
built-in assets and are excluded from update packages. Returning from the folder
refreshes discovery. Pressing Done applies changed packs by rebuilding rendering
resources; this can briefly pause the game. Invalid resources restore the previous
selection, or Default if the previous selection also cannot load.

## Compatibility

Supported for assets that D Edition currently uses:

- Standard, case-sensitive `assets/<namespace>/...` paths in ZIP and folder packs.
- Block, item, entity and other existing PNG texture replacements, including higher
  resolutions. The existing bitmap font atlas scales its character measurements.
- Texture `.png.mcmeta` animation frame sizes, order, durations and interpolation.
- Direct OGG sound replacements and layered `sounds.json` music definitions,
  including `replace` behavior.
- Pack descriptions, optional icons, version warnings, resource filters and
  version-selected overlays. Descriptions are displayed as plain text.

This is **not complete Minecraft Java rendering compatibility**. Custom block/item
model JSON, custom geometry, Java font providers, shaders, OptiFine/CTM/CIT features,
and arbitrary sound-event remapping are not implemented. A pack that requires those
features may load its textures but will not reproduce all of its Java appearance.
Legacy block/item directories and common historical names are resolved through
virtual aliases. The table covers wood and color families, common terrain,
plants, rails, doors and tools. Exact paths win within a pack; pack ordering still
takes precedence over aliases. A pack's standard Minecraft logo/edition texture
can override D Edition branding, while explicit `minecraft_d` overrides win in
that same pack. Older split logos and common widget/HUD sheets are converted in
memory, including buttons, hotbar, hearts, food, air and experience bars. These
adapters do not edit the ZIP. Windows ZIP caches use extended-length paths.
The untouched local Geekcraft ZIP has been exercised through the GPU smoke test;
its logo and panorama were visually checked. This is not a claim that every
historical texture layout or most published packs have been tested.
Bedrock `.mcpack` files are
not supported. Missing resources normally use Default; explicit pack filters can
block that fallback, and a required blocked resource may prevent a pack from loading.

The current versioned-overlay compatibility profile is Java resource format 75.0.
The loader accepts legacy `pack_format` / `supported_formats` and modern
`min_format` / `max_format` metadata. Minecraft documents modern format ranges in
[Java 1.21.9's release notes](https://www.minecraft.net/en-us/article/minecraft-java-edition-1-21-9)
and layered asset directories in the
[23w31a overlay specification](https://www.minecraft.net/nb-no/article/minecraft-snapshot-23w31a).
This profile is independent of D Edition's release number and does not imply that
every Java feature from that version is implemented.

## Adding future content

New content should request a namespaced resource through `ResourceManager`, and
renderer textures should use the shared resource-texture loader. For example,
`minecraft:textures/entity/new_creature.png` then automatically participates in
pack ordering, overlays and fallback. There is no pack-specific block registry.
Adding a new rendering feature still requires its consumer (for example a model
loader); the resource resolver already supports arbitrary namespaces and paths.
Advance the central `javaResourceFormat` profile when adopting a new asset schema.

## Limits and verification

Discovery lists up to 256 packs. ZIPs are limited to 512 MiB compressed, 1 GiB
expanded and 65,535 entries; individual resources are limited to 64 MiB. Images
are limited to 4096 pixels per dimension. Texture uploads have an estimated
512 MiB budget, in addition to the renderer's texture-count limit. Large animated
or interpolated packs can reach these limits earlier. Unsafe archive paths and
symbolic-link assets are rejected. Only 64 distinct pack icons are uploaded per
renderer instance; further icons use a placeholder.

`tests/Run-ResourcePackSmoke.ps1` covers discovery, real ZIP extraction, saved
ordering, fallback, overlays, filters, future namespaces, animation and a DX12 menu
render. It also verifies that a malformed PNG releases the failed renderer and
allows Default to load on the same window. Run it after the local-test build and
`tests/Run-BlurSmoke.ps1`, which provides the native readback test bridge.

`tests/Run-ResourcePackSmoke-macos.sh` runs the same repository, animation and
renderer recovery tests through MoltenVK after a native Mac app build. The macOS
test workflow runs this alongside application launch and existing blur checks.

Verified September 10, 2026: the Windows Admin local-test release build, all 37
unit-test modules, and the resource-pack smoke tests passed. Native Apple Silicon
pack loading, animation, MoltenVK menu rendering, malformed-texture recovery and
packaged application launch passed in
[Mac verification run 34441161767](https://github.com/MinecraftDEdition/Minecraft-D-Edition/actions/runs/34441161767).
The workflow was dispatched with player-update publication disabled.
