# Epic Online Services SDK

Minecraft: D Edition uses Epic Online Services (EOS) Connect and P2P for
router-free internet multiplayer. The world creator remains the authoritative
listen-server; EOS supplies device identity, NAT traversal, and relay transport.

The EOS SDK is not vendored in this repository. After accepting Epic's
developer agreement, download the current **C SDK** from the Epic Games
Developer Portal and arrange its runtime components here:

```text
third_party/eos/SDK/Include/eos_sdk.h
third_party/eos/SDK/Lib/EOSSDK-Win64-Shipping.lib
third_party/eos/SDK/Bin/EOSSDK-Win64-Shipping.dll
third_party/eos/SDK/Bin/libEOSSDK-Mac-Shipping.dylib
```

Keep Epic's original directory structure below `SDK`. The integration build
will locate the platform-specific library and runtime from that tree. Public
macOS automation receives its licensed input through the encrypted private
build-dependency release instead of committing the SDK.

Do not commit the SDK. Its directory is intentionally ignored by Git.

Product credentials belong in `data/eos.local.json`, copied from
`data/eos.example.json`. The local credentials file is also ignored.

See `docs/eos-p2p-setup.md` for the required Developer Portal configuration.
