# Discord Social SDK dependency

This directory is the local landing area for the official Discord Social SDK
used by Minecraft: D Edition. The SDK is distributed through the Discord
Developer Portal and must not be copied into the public source repository.

## Expected local layout

Download the latest **C++** Social SDK archive and extract its
`discord_social_sdk` directory here without rearranging it:

```text
third_party/discord/
  README.md
  application.example.json
  discord_social_sdk/             # ignored; supplied locally
    include/discordpp.h
    lib/release/
      discord_partner_sdk.lib     # Windows import library
      libdiscord_partner_sdk.dylib
      libdiscord_partner_sdk.so
    bin/release/
      discord_partner_sdk.dll
```

The exact platform files in an SDK release may differ. Keep every file from
the official archive until the build preparation scripts select the required
runtime:

- Windows x64: `discord_partner_sdk.dll` and its import library.
- macOS arm64: `libdiscord_partner_sdk.dylib`.
- Linux x64: `libdiscord_partner_sdk.so`.

Do not place a bot token, OAuth client secret, webhook URL, user token, or
Discord password anywhere in this directory. Direct Rich Presence needs the
public Discord Application ID, the SDK runtime, and a running Discord desktop
client. Secrets are neither required nor safe to ship inside a game client.

## Planned presence contract

The Social SDK activity supplies the public first line independently from the
filename-safe Developer Portal/application identity:

```text
Playing Minecraft: D Edition
```

`native/discord_abi_bridge.cpp` sets this with `Activity::SetName`, while the
internal application and executable remain `Minecraft D Edition`.

Minecraft: D Edition will update the Activity details when the client changes
state:

| Game state | Activity details | Activity state |
| --- | --- | --- |
| Main menu and submenus | `In Menu` | empty |
| Local world | `Singleplayer` | optional world/dimension text |
| Remote or hosted world | `Multiplayer` | server display name |

The multiplayer server name is public to anyone allowed to view the player's
Discord activity. A later in-game privacy setting should allow players to hide
it while retaining the generic `Multiplayer` status.

Presence must be optional and failure-safe: a missing SDK, Discord not running,
activity sharing disabled, or an SDK error must never stop the game from
launching or disconnect a world. Updates should occur on state transitions,
not every render frame, and the presence should be cleared during clean exit.

## Configured application

The release build uses public Application ID `1544456552436469790`. Its large
activity art is loaded from the HTTPS-hosted canonical project image, so no
private credentials and no separately uploaded Discord art asset are needed.
The official C++ Social SDK must still be extracted as shown above for local
release builds.

`application.local.json`, the downloaded SDK, and packaged SDK runtimes are
ignored by Git. The Application ID itself is public and may be moved into the
release build configuration once the integration is enabled.
