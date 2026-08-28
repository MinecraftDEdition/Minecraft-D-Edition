# Epic Online Services SDK

Minecraft: D Edition uses Epic Online Services (EOS) Connect and P2P for
router-free internet multiplayer. The world creator remains the authoritative
listen-server; EOS supplies device identity, NAT traversal, and relay transport.

The EOS SDK is not vendored in this repository. After accepting Epic's
developer agreement, download the latest **Windows C SDK** from the Epic Games
Developer Portal and arrange its runtime components here:

```text
third_party/eos/SDK/Include/eos_sdk.h
third_party/eos/SDK/Lib/EOSSDK-Win64-Shipping.lib
third_party/eos/SDK/Bin/EOSSDK-Win64-Shipping.dll
```

Keep Epic's original directory structure below `SDK`. The integration build
will locate the Win64 import library and runtime DLL from that tree.

Do not commit the SDK. Its directory is intentionally ignored by Git.

Product credentials belong in `data/eos.local.json`, copied from
`data/eos.example.json`. The local credentials file is also ignored.

See `docs/eos-p2p-setup.md` for the required Developer Portal configuration.
