# macOS distribution target

This directory is the home of the future native macOS package. It deliberately
contains no placeholder executable: a Mac release is publishable only after a
real macOS build passes the platform checks below.

## Planned player artifact

GitHub asset: `Minecraft.D.Edition-macOS-Universal.dmg`

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
    Frameworks/MoltenVK.framework
    Frameworks/libEOSSDK-Mac-Shipping.dylib
    Frameworks/Sparkle.framework
```

The main executable and every embedded native library must contain compatible
`arm64` and `x86_64` slices for the Universal 2 package. The initial deployment
target is macOS 12.0.

## Release gate

A macOS artifact must not be uploaded until all of the following succeed on a
Mac build host:

1. Build both architectures with LDC and the current Xcode SDK.
2. Verify every Mach-O architecture and runtime library path.
3. Assemble the bundle from `Info.plist.in` without relying on the working
   directory for resources or user data.
4. Run protocol, save-format, renderer, audio, input, and update smoke tests.
5. Sign nested frameworks first and the application last with hardened runtime.
6. Notarize and staple the application/DMG.
7. Generate and sign the Sparkle appcast and any delta updates.

Development builds may be ad-hoc signed for a small tester group. Public builds
must use Developer ID signing and notarization.

