# Project layout

The resource half follows Minecraft Java Edition's namespaced layout: client-facing resources live under `assets/<namespace>/`, while registries, recipes, loot tables, tags, and world-generation data live under `data/<namespace>/`.

The code half uses normal D package paths under `source/minecraftd/`:

- `client/`: window, input, frame loop, and presentation
- `audio/`: sound registry, streaming, mixing, and XAudio2 integration
- `common/`: reusable primitives and utilities
- `game/`: gameplay state and systems shared by client/server
- `network/`: protocol, serialization, and transport
- `platform/desktop/`: shared SDL window/input and portable desktop audio boundary
- `platform/windows/dx12/`: Win32, DXGI, D3D12, shaders, and GPU resource management
- `platform/windows/vulkan/`: current Windows Vulkan implementation while the surface boundary is generalized
- `platform/macos/`: app-bundle and MoltenVK-specific glue that cannot be shared
- `platform/linux/`: Linux-specific paths and runtime integration that cannot be shared
- `server/`: integrated and dedicated server behavior
- `world/`: chunks, blocks, entities, lighting, and generation

The DirectX 12 layer is intentionally isolated so game and world code do not depend directly on Windows graphics APIs. Platform-native packaging is similarly isolated under `distribution/windows/`, `distribution/macos/`, and `distribution/linux/`; all builds continue to use the shared network protocol.
