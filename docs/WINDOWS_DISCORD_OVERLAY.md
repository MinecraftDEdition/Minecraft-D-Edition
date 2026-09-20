# Windows Discord overlay compatibility

MCDE explicitly sets the Discord Social SDK game-window PID to its current
process. This works for the installed game and Admin Test executable; the
launcher is not the overlay target. The integration does not enable Discord's
user setting or claim automatic game recognition.

Windows fullscreen remains borderless, using the same HWND for DX12 and
Vulkan. No exclusive-fullscreen switch or renderer-specific overlay injection
is introduced. The current Discord overlay supplies its own presentation.

Keyboard/button holds now require a key-down event delivered to MCDE's window.
GetAsyncKeyState only clears missed releases; it cannot create movement or
attacks from keys intercepted by an overlay. Focus loss clears transient input,
releases capture, and resets mouse deltas. Focus return suppresses physically
held keys until released, eats the activation click, and waits for neutral
controller input. Left/right modifier bindings and mouse side buttons remain
supported. Existing game logic clears queued actions while unfocused; server
simulation continues normally in multiplayer.

There is no general overlay-open notification in the bundled Social SDK.
Interactive modern overlays must transfer input focus or intercept input using
their normal Windows integration. Passive notification widgets should not pause
the game. Do not guess overlay state from the default hotkey, window titles,
or presence availability. Legacy in-process overlay behavior needs live testing.

## Player test

1. Run Discord desktop and launch MCDE (not just the launcher).
2. In Discord's Registered Games / Game Overlay settings, add the running game
   if needed and enable its overlay. Admin Test may need its own entry.
3. Use the configured Discord overlay shortcut (default Shift + backtick).
4. Check DX12 and Vulkan, both windowed and F11 borderless fullscreen.
5. Type and click inside Discord: MCDE must not move, turn, attack, or place.
6. Return while holding a movement key or mouse button: release it before a
   fresh game action. Check camera direction, resize, Alt-Tab, and F11.
7. Check multiplayer keeps running, and Discord closed/disabled does not prevent
   normal play. Check controller return after releasing sticks and triggers.

Automated input-state tests and Windows compilation validate our changes.
End-to-end Discord overlay rendering and interception still require the live
Discord client. Discord controls its compatibility list and enablement.
macOS keeps its existing Rich Presence integration; Discord's standard overlay
is Windows-only.

References:
- https://support.discord.com/hc/en-us/articles/217659737-Game-Overlay-101
- https://support.discord.com/hc/en-us/articles/25289844838551--Known-Issue-Game-Overlay
- https://discord.com/developers/docs/social-sdk/authentication.html
