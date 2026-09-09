# Gaussian pause-menu blur

The pause background now uses the same separable Gaussian shader in DX12 and Vulkan, including macOS through MoltenVK. The normal texture sampler is unchanged; the blur uses its own linear, clamp-to-edge sampler.

The render sequence is:

1. Copy the scene after the HUD and before pause-menu controls.
2. Linearly downsample into a half-resolution target.
3. Blur horizontally into a second half-resolution target.
4. Blur vertically back into the first target.
5. Linearly upscale the result, then draw the menu controls sharply over it.

The setting now controls Gaussian standard deviation in screen pixels: 2.4 pixels per setting increment, 12 at the default setting, and 24 at maximum. Each one-dimensional kernel covers three standard deviations and combines adjacent taps using linear sampling. Strength zero skips the blur draw entirely. The old nine-sample cross only increased sample spacing; this kernel covers the full neighborhood.

Two reusable half-resolution targets add approximately 4 MiB at 1920×1080 or 16 MiB at 3840×2160, beyond the existing full-resolution scene copy (allocation alignment may add overhead). They are recreated safely on resize. The live scene is processed every paused frame, including multiplayer; no stale background is cached. Hardware-specific frame-time measurements remain a playtest task.

Vulkan validation also exposed issues in the existing pause-rendering path. Scene and resumed-overlay render passes now have compatible dependencies, the overlay load is synchronized for reads, presentation uses a semaphore per swapchain image, and texture uploads wait before resetting the shared frame command pool. The semaphore approach follows [Khronos guidance](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html).

## Validation

- Windows release build and all 37 unit-test modules passed.
- `tests/Run-BlurSmoke.ps1` renders and reads pixels back from the GPU on both DX12 and Vulkan. It covers three strengths, three sizes (including odd dimensions), repeated frames, resize, and returning to unblurred rendering.
- Checks verify diagonal coverage, monotonic transitions on both axes, preserved constant regions, and clamped edges. DX12 and Vulkan produced identical output for all nine combinations on the test machine.
- DX12 debug-layer errors are checked in the readback helper. Vulkan synchronization validation completed without errors or warnings after the fixes.
- The macOS workflow now builds and runs `tests/blur_macos_smoke.cpp` against the bundled MoltenVK. All nine native Mac combinations passed in [the development CI run](https://github.com/MinecraftDEdition/Minecraft-D-Edition/actions/runs/34378181733).
- That CI run also completed the Apple Silicon app and DMG build, application launch test, and package/signature inspection successfully. The test installer is available as a workflow artifact; release publication was skipped.

The checked-in `shaders/spirv/world.blur.frag.spv` was regenerated from `shaders/world.hlsl`; the Mac app packaging copies that shader and compiles the same Vulkan bridge. Test readback helpers are excluded from normal builds. No Metal renderer is introduced.

This work is on `codex/pause-gaussian-blur`. CI publication is disabled; it does not replace the player update feed.
