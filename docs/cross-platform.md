# Cross-platform and cross-play contract

Windows, macOS, and Linux builds are native packages of the same game. They do
not exchange renderer, window, input, audio, filesystem path, executable, or
installer data during multiplayer. Cross-play works because every platform
uses the same authoritative server rules and serializes the same network
protocol.

## Compatibility boundary

`source/minecraftd/network/game_protocol.d` owns the wire format and the
`gameProtocolVersion` value. A client includes that value in its login request;
the server rejects a different value before adding the player to the world.
The accepted login response also includes the protocol version and the client
validates it. This check is already independent of operating system.

The protocol version must be incremented whenever a packet changes in a way an
older client cannot safely read. Renderer fixes, installer changes, and other
platform-only work do not require a protocol increment.

## Rules for platform work

- Network packets use explicitly sized values and the existing packet readers
  and writers; never serialize native structs, pointers, handles, path
  separators, or platform enum values.
- The integrated server remains authoritative for world simulation, player
  state, inventory, combat, and saves on every operating system.
- EOS builds use the same product, sandbox, deployment, socket naming, and
  client policy. Only the native EOS SDK binary and cache path differ.
- All platforms in one public release use the same game data and protocol
  version. A platform may ship later only if it remains protocol-compatible.
- Automated protocol tests must cover TCP loopback and the transport-neutral
  packet layer. EOS relay testing is performed between distinct machines after
  the native platform integrations work.

The release version and protocol version serve different purposes. Release
versions identify downloadable builds; the protocol version decides whether
two builds can safely share a multiplayer session.

