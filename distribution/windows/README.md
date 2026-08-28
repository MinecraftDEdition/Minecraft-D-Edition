# Windows distribution

This directory owns Windows-only player distribution components:

- `installer/` contains the Inno Setup offline and GitHub-backed web installers.
- `launcher/` contains the WinForms launcher and differential updater.

The existing entry point remains `tools/build_distribution.ps1` so current
developer and release commands continue to work. Its outputs are placed in
`dist/` and are Windows-only until a top-level multi-platform release
orchestrator is introduced.

Windows runtime dependencies include the game `.exe`, the launcher `.exe`,
the EOS Windows DLL, and either the DirectX 12 or Vulkan renderer selected by
the player.

