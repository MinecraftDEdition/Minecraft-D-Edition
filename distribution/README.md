# Desktop distributions

Minecraft: D Edition is one game built into separate native packages. The
repository, gameplay code, assets, world format, and multiplayer protocol are
shared; executables, native libraries, installers, and update mechanisms are
platform-specific.

| Target | Player package | Renderer | Status |
| --- | --- | --- | --- |
| Windows x86-64 | `Minecraft.D.Edition.Setup.exe` | DirectX 12 or Vulkan | Active |
| macOS Universal 2 | `Minecraft.D.Edition-macOS-Universal.dmg` | Vulkan through MoltenVK | Scaffolded |
| Linux x86-64 | To be selected | Vulkan | Reserved |

Platform packages must never include another platform's executable or SDK
binary. GitHub Releases may contain all platform assets under the same game
version, but each updater selects only the matching operating system and
architecture.

Cross-play does not depend on packaging. It is controlled by the shared
wire protocol documented in [`../docs/cross-platform.md`](../docs/cross-platform.md).
