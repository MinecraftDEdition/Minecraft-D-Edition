# Renderer backends

Minecraft D Edition builds renderer-neutral frame meshes in shared D code. A
small `GraphicsDevice` boundary owns only GPU-specific work: texture upload,
resize, presentation, VSync, and rendering the already-built draw list. This
keeps terrain generation, water geometry, particles, menus, HUD, gameplay,
textures, sounds, and world data shared between platforms.

## Current Windows test milestone

The Windows executable contains two selectable backends:

| Backend | Selection | Status |
| --- | --- | --- |
| DirectX 12 | default or `--renderer=dx12` | primary Windows backend |
| Vulkan | `--renderer=vulkan` | independent working test backend |

The Video Settings **Graphics API** control persists the preferred backend in
`data/options.txt`; changing it takes effect after restarting. A command-line
selection overrides that saved preference for one launch. The active backend is
shown in the title-screen technology label.

The Vulkan backend currently supports the passes used by the game: opaque and
translucent world geometry, depth-tested and non-depth-tested overlays,
first-person viewmodel depth clearing, inverted-color selection rendering,
texture upload, alpha blending, depth buffering, resize, and swapchain VSync.
It uses the existing Win32 window and input code so Windows testing isolates the
renderer itself.

Vulkan and DX12 both capture the completed scene and run the same nine-tap blur
shader behind in-world menus. Vulkan performs the capture between its main and
load-preserving overlay render passes, so subsequent menu and HUD draws remain
sharp while the world beneath them is blurred.

## Building on Windows

Install the Vulkan SDK and ensure `VULKAN_SDK` points to it. The normal DUB
build invokes `native/build_vulkan_bridge.ps1`, which compiles the shared HLSL
shader to SPIR-V, builds the native Vulkan bridge, and links the Vulkan loader
import library.

```powershell
dub build --build=debug --force
.\Minecraft D Edition.exe --renderer=vulkan
```

SPIR-V and native object/library files are generated build artifacts and are not
committed. Distribution creation copies the generated shader directory beside
the executable.

## Cross-platform target layout

The project should remain one source tree and one release family, while native
executables and small platform runtime dependencies are packaged per operating
system:

| Operating system | Window/input layer | Graphics backend | Shared content |
| --- | --- | --- | --- |
| Windows | Win32/raw input | DirectX 12 or Vulkan | all game assets/data |
| Linux | Linux window/input adapter | Vulkan | all game assets/data |
| macOS | Cocoa/AppKit adapter | Vulkan through MoltenVK | all game assets/data |

MoltenVK is a Vulkan portability implementation over Metal; it does not make a
Windows executable runnable on macOS. The macOS package will therefore contain
a native macOS executable plus MoltenVK, while reusing the same gameplay code,
SPIR-V shaders, textures, sounds, and data. Linux likewise needs a native D
build and window/input adapter but can reuse this Vulkan renderer directly.

The launcher/installer can present one game product and choose the matching
platform package automatically. Content-addressed asset shards can remain
common across all three packages so unchanged textures, sounds, and data are
downloaded only once; only executable and platform-runtime shards need to
differ.

## Next portability work

Before producing a macOS build, split remaining Win32 ownership out of the game
client (window lifecycle, keyboard/mouse events, cursor capture, paths, timing,
audio device creation, and process helpers) behind platform interfaces. Then:

1. create a Linux window/input adapter and validate the Vulkan backend outside
   Win32;
2. create a Cocoa/AppKit window/input adapter and connect its Metal layer to
   MoltenVK;
3. package the correct Vulkan loader/MoltenVK runtime per OS;
4. verify audio decoding and output independently from graphics;
5. add per-platform CI builds and real-hardware smoke tests.

Metal-native rendering can still be added later if profiling on physical Apple
hardware shows a reason to replace MoltenVK. It is not required for the first
functional macOS build.
