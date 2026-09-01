# Windows distribution

This directory owns Windows-only player distribution components:

- `installer/` contains the Inno Setup offline and GitHub-backed web installers.
- `launcher/` contains the WinForms launcher and differential updater.

The existing entry point remains `tools/build_distribution.ps1` so current
developer and release commands continue to work. Its outputs are placed in
`dist/` and are Windows-only until a top-level multi-platform release
orchestrator is introduced.

Windows runtime dependencies include the game `.exe`, the launcher `.exe`,
the EOS Windows DLL, SDL3 for the shared controller layer, and either the
DirectX 12 or Vulkan renderer selected by the player.

The installed launcher is the updater; the original Setup executable is not
needed after installation. On every launch it verifies the size and SHA-256
of each managed file against the signed release manifest, even when the
installed version already matches the current release. The published pointer,
manifest, shards, and every extracted file are SHA-256 verified. Only missing
or changed managed files are applied. Replacements are staged, verified,
installed atomically, and rolled back if any part of the update fails.

Launcher updates use `Minecraft D Edition Launcher.update.exe` as a managed
sidecar. This lets both older and current installations replace the updater
only after its running process has exited, without requiring users to rerun
Setup. Saves, options, account sessions, skins, screenshots, logs, and caches
are never part of the managed update manifest.
