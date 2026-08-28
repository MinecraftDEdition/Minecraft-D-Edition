# macOS distribution target

This directory builds the native Apple Silicon test package. It shares the D
game client and game data with Windows while using SDL3 for the Cocoa window,
input, and clipboard; Vulkan through MoltenVK for rendering; miniaudio/Core
Audio for sound; and Sparkle for signed in-place updates.

## Planned player artifact

GitHub asset: `Minecraft.D.Edition-macOS-arm64.dmg`

The disk image will contain `Minecraft D Edition.app` and an Applications
alias. The app bundle will use this layout:

```text
Minecraft D Edition.app/
  Contents/
    Info.plist
    MacOS/Minecraft D Edition
    Resources/assets/
    Resources/shaders/spirv/
    Frameworks/SDL3.framework
    Frameworks/libMoltenVK.dylib
    Frameworks/libEOSSDK-Mac-Shipping.dylib
    Frameworks/Sparkle.framework
```

The initial tester build targets Apple Silicon (`arm64`) and macOS 12.0 or
newer. An Intel slice can be added after the first physical-Mac validation.

The Test release also hosts `mde-macos-appcast.xml`. Sparkle verifies every
update with the repository's private Ed25519 key before replacing the app.
The private key belongs only in the ignored `private/` directory and the
`MACOS_SPARKLE_ED25519` GitHub Actions secret.

Epic Online Services is compiled only when the licensed macOS EOS SDK is made
available to the build. The automated tester package currently retains TCP/LAN
multiplayer but reports EOS as unavailable instead of embedding an unlicensed
SDK copy.

## Release gate

A macOS artifact must not be uploaded until all of the following succeed on a
Mac build host:

1. Build the intended architecture with LDC and the current Xcode SDK.
2. Verify every Mach-O architecture and runtime library path.
3. Assemble the bundle from `Info.plist.in` without relying on the working
   directory for resources or user data.
4. Run protocol, save-format, renderer, audio, input, launch, and update smoke tests.
5. Sign nested frameworks first and the application last with hardened runtime.
6. Notarize and staple the application/DMG.
7. Generate and sign the Sparkle appcast and any delta updates.

Small-group Test builds are ad-hoc signed and therefore require macOS's Open /
Open Anyway flow on first launch. Wider public builds must use Developer ID
signing and notarization.
