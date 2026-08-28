# EOS two-PC Internet test

This test is specifically for two computers on different Internet connections.
No router port forwarding or public IP address is used.

## Put the same build on both PCs

Copy the complete game folder to the second PC. At minimum, the runnable folder
must contain:

- `Minecraft D Edition.exe`
- `EOSSDK-Win64-Shipping.dll`
- the `assets`, `data`, and `shaders` directories
- `data/eos.local.json` with the same EOS product, sandbox, deployment, and
  client credentials as the host

Do not copy `data/eos-cache`. EOS Connect creates a separate device identity on
each computer. Do not post `eos.local.json` or its client secret publicly.

On each PC, open PowerShell in the game folder and run:

```powershell
.\Minecraft D Edition.exe --eos-smoke-test
```

Both computers must report `EOS Connect login succeeded; P2P is ready.` before
testing the game.

## Normal Internet test

1. Leave `"forceRelays": false` in both copies of `data/eos.local.json`.
2. On the host PC, create or load a world.
3. Open the pause menu, choose **Connect server to multiplayer**, and confirm.
4. Choose **Copy to clipboard**. Send the complete `mcd://eos/...` invitation
   to the other tester through a private message.
5. On the remote PC, open **Multiplayer**, paste the invitation into **Server
   Address**, and choose **Connect**.
6. Confirm that both players appear, can move, chat, break/place blocks, take
   damage, and observe each other's replicated effects.
7. Pause the host while the remote player moves. The world must remain active.
8. Have the remote player leave and reconnect with the same invitation while
   the host world remains open.
9. Have the host choose **Save & Quit**. The remote client must lose the session;
   the host remains the only world authority and is not migrated.

The invitation expires when the host closes that world. Publishing it again in
a later session produces a different socket secret.

## Forced-relay proof

To prove that the test is not succeeding through a direct peer route, close the
game on both PCs, set this in both `data/eos.local.json` files, and repeat the
test:

```json
"forceRelays": true
```

EOS then permits only its relay route for new P2P connections. After the relay
test, restore `false` so normal sessions can use the lowest-latency route.

## Troubleshooting

- A malformed or partially copied invitation is rejected in the Multiplayer
  menu. Copy it again from the host's server-information screen.
- `EOS Connect login failed` usually means the two copies do not use the same
  active deployment/client policy, or that Device ID access is not enabled.
- If login succeeds but joining times out, verify that the EOS client policy
  permits P2P and that security software allows the game and EOS SDK outbound
  network access. Router configuration is still unnecessary.
- Both PCs need accurate system clocks. TLS and account requests can fail when
  a clock is substantially wrong.
- Forced relay must have the same setting on both peers; incompatible relay
  settings cannot negotiate a connection.
