# Windows installer and differential updates

Minecraft D Edition ships through the GitHub release channel at
<https://github.com/MinecraftDEdition/Minecraft-D-Edition/releases/tag/Test>.

## Player experience

The approximately 2 MB web installer uses a per-user location by default, so
installation and updates do not require an administrator prompt. It contains
only the signed-style setup UI and `Minecraft D Edition Launcher.exe`; it does
not embed a copy of the game. Start Menu and optional desktop shortcuts open
the launcher, which obtains the real runtime files from GitHub Releases. It:

1. downloads the tiny `mde-update-pointer-v1.txt` release asset;
2. launches immediately when its installed version matches;
3. downloads and verifies the full manifest only for a new version;
4. compares the old and new SHA-256 file lists;
5. downloads only the content-addressed ZIP shards containing changed files;
6. stages and verifies every changed file before modifying the installation;
7. keeps rollback copies while applying the update; and
8. starts `Minecraft D Edition.exe` after a successful check.

The updater never manages `saves/`, `screenshots/`, `data/options.txt`,
`data/eos.local.json`, `data/eos-cache/`, `data/server_entry.txt`, or
`data/window_state.txt`. Uninstalling also leaves player-created files behind.

If GitHub is temporarily unreachable, the installed game starts normally. A
failed download or hash mismatch is applied to nothing and displays an error.
The default player installation is
`%LOCALAPPDATA%\Programs\Minecraft D Edition`. It contains no Git checkout,
GitHub credentials, source code, or release-publishing tools.

## Admin development checkout

Development and publishing use a separate checkout conventionally located at
`C:\Minecraft D Edition_Admin`. This is the folder to open in an editor or
Codex when changing the game. It holds the `.git` directory and publishing
scripts; player installations do not. GitHub CLI authentication belongs to the
Windows developer account and is never copied into an installer or update.

## Build a release

Install PowerShell 7 and Inno Setup 6, then run:

```powershell
.\tools\build_distribution.ps1 -Version 'Test-YYYY.MM.DD.N'
```

This performs a release game build, marks the shipped executable as a Windows
GUI application so it does not open a terminal, and produces:

- `dist/Minecraft.D.Edition.Setup.exe`, the small GitHub-backed web installer;
- `dist/updates/mde-update-pointer-v1.txt` for fast version checks;
- `dist/updates/mde-update-manifest-v1.txt` with per-file SHA-256 hashes; and
- content-addressed `dist/updates/mde-shard-*.zip` differential payloads.

The public release publisher uploads the web installer and update feed, not the
offline or portable packages. The 128-way stable path sharding means a changed
executable currently costs about 4 MB to update. Unchanged large textures and
sounds are not downloaded. The build script deliberately runs shard compression
under PowerShell 7 so rebuilding identical files produces reusable archive
hashes instead of a false full update.
Give every published build a new version string; reusing a version prevents
installed launchers from recognizing the change.

Pass `-BuildOfflineInstaller` and/or `-BuildPortable` only when those optional
packages are needed. They are deliberately omitted from normal public builds.

Run both distribution smoke tests before publishing:

```powershell
.\tests\updater_smoke.ps1
.\tests\installer_smoke.ps1
```

The updater test serves two synthetic releases locally and verifies changed,
added, removed, unchanged, and save files. The installer test performs a full
silent install, checks the installed launcher, then uninstalls it.

## Publish to the Test release

Install and authenticate GitHub CLI, then run:

```powershell
gh auth login
.\tools\publish_test_release.ps1
```

The publisher reuses matching content-addressed shards already on GitHub. It
uploads only changed shards first, then the manifest, the tiny pointer, and
finally the public web installer. This order prevents new installations from
observing an incomplete release. Obsolete content-addressed shards and the
legacy monolithic ZIP are removed only after the new feed is live.

GitHub CLI must be installed and authenticated on any workstation expected to
push source or publish builds. Run `gh auth login` once in that Windows account.
The project folder must also be a Git checkout with this remote:

```powershell
git remote -v
# origin  https://github.com/MinecraftDEdition/Minecraft-D-Edition.git
```

The launcher executable itself is intentionally outside its managed manifest,
because a process cannot safely replace itself. Changes to launcher behavior
therefore require users to run a newer installer. Game binaries and all managed
content update normally.

The installer and launcher are currently unsigned. Windows SmartScreen may
warn users until the project obtains and configures a trusted code-signing
certificate. Do not publish private EOS credentials or development SDK trees.
