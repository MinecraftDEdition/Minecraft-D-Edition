# SDL3 dependency

Minecraft: D Edition uses the SDL3 gamepad API as its common controller layer
on Windows, macOS, and future Linux builds. The dependency is pinned to SDL
3.4.14.

- Windows builds run `tools/Prepare-Sdl3Windows.ps1`, verify the official
  Visual C++ development archive with its GitHub release SHA-256 digest, and
  stage the x64 import library and runtime DLL locally.
- macOS builds use the matching official `SDL3.framework` prepared by
  `distribution/macos/prepare_dependencies.sh`.

Downloaded archives and extracted binaries are intentionally ignored. Player
packages include the appropriate SDL runtime for their operating system.
