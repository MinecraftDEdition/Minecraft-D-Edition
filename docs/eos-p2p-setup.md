# EOS P2P setup for Minecraft: D Edition

## Intended topology

EOS does not own or simulate the world. The creator's PC continues to run the
existing `IntegratedGameServer` at 20 TPS and remains authoritative for world
state, movement, collision, survival, inventory, mining, combat, and saving.

```text
Host's local client --loopback TCP--> IntegratedGameServer
                                           ^
                                           |
                                    EOS P2P bridge
                                           |
                                    Remote clients
```

Direct TCP remains available for LAN play and local smoke tests. Internet
players use a private EOS invitation to identify the host and EOS P2P to carry
the existing game protocol without router or firewall configuration.

## Developer Portal prerequisites

These steps must be completed by the EOS product owner because they require an
Epic Games account and acceptance of Epic's developer agreement.

1. Create an organization and a product named `Minecraft: D Edition` in the
   Epic Games Developer Portal.
2. Create or select a development sandbox and deployment.
3. Configure an EOS client policy that permits the minimum services needed by
   the first integration: Connect and P2P. Lobby permission can be added later
   when public/friends-only server discovery is implemented.
4. Create client credentials using that policy.
5. Download the latest Windows C SDK. The currently verified version is
   1.19.1.2.
6. Arrange the SDK as `third_party/eos/SDK/Bin`, `Include`, `Lib`, and `Tools`.
7. Copy `data/eos.example.json` to `data/eos.local.json` and replace every
   placeholder with the product's Product ID, Sandbox ID, Deployment ID,
   Client ID, and Client Secret.

`forceRelays` is a diagnostic switch. Leave it `false` normally. Set it to
`true` on both test PCs to prove that an Internet session works through EOS
relay infrastructure rather than a direct or accidental LAN route.

Do not paste product credentials into chat, screenshots, documentation, or
source files. `data/eos.local.json` is intentionally ignored by Git.

Release builds validate that private Admin file and copy it only into the
generated runtime as `data/eos.client.json`. The game prefers an untracked
`eos.local.json` when one exists, then falls back to the packaged client
configuration. Neither credential file is committed to Git source history.
Because a client configuration shipped to players can be recovered, its EOS
client policy must grant only the minimum Connect and P2P actions required by
the game.

## Implemented player flow

1. On first online use, the game authenticates the local player through EOS
   Connect. Development builds will initially use a device identity so a
   separate account screen is not required for the first two-PC test.
2. Publishing generates a new cryptographically random EOS socket name. The
   socket name is an ephemeral session secret and is not saved with the world.
3. The pause menu displays a copyable
   `mcd://eos/<host-product-user-id>/<socket-secret>` invitation rather than a
   public IP address.
4. A remote player pastes the complete invitation into Multiplayer. Treat the
   invitation as private while the hosted world is open.
5. The invitation identifies the host's EOS Product User ID and the only P2P
   socket that the host will accept for this session.
6. EOS P2P establishes a direct route when possible and uses Epic's relay
   network when required.
7. A packet bridge reconstructs the existing length-framed game stream and
   forwards it to the host's local `IntegratedGameServer`.
8. If the host leaves, the session ends. EOS does not make the world persistent
   and does not transfer authority to another player.

## Integration acceptance tests

- Existing loopback and LAN TCP connections remain available alongside EOS.
- `Minecraft D Edition.exe --eos-smoke-test` validates the local configuration,
  device login, and P2P interface without opening a game window.
- Two PCs on different internet connections can create, join, play, disconnect,
  and reconnect without port forwarding.
- A forced-relay test succeeds, proving that the result is not accidentally a
  direct LAN or public-IP connection.
- Protocol-version mismatch, malformed invitation, rejected connection, EOS
  outage, and host shutdown each produce a useful menu error.
- Large terrain snapshots are fragmented and reassembled without exceeding EOS
  packet limits or blocking the render loop.
- The server continues validating all gameplay; EOS identity never grants a
  client authority over world state.
