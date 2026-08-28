# Minecraft Java 26.2 options reference

This is the implementation checklist for D Edition's options UI. Labels were
verified against `assets/minecraft/lang/en_us.json` in the installed official
`26.2.jar`; layout was compared with the current Java Edition option-screen
gallery.

## Screen hierarchy

- Options: FOV, Online, Skin Customization, Music & Sounds, Video Settings,
  Controls, Language, Chat Settings, Resource Packs, Accessibility Settings,
  Telemetry Data, Credits & Attribution, Done.
- Online: Friends List, Allow Requests, In-Game Notification, Visibility, Xbox
  Settings, Allow Server Listings, Realms News & Invites.
- Skin Customization: Cape, Jacket, both Sleeves, both Pant Legs, Hat, Main Hand.
- Music & Sounds: Master, Music, Jukebox/Note Blocks, Weather, Blocks, Hostile
  Mobs, Friendly Mobs, Players, Ambient/Environment, Narrator/Voice, UI, Device,
  Closed Captions, Directional Audio, Music Frequency, Music Toast.
- Video / Display: Fullscreen Resolution, Max Framerate, VSync, Reduce FPS when,
  GUI Scale, Fullscreen, Exclusive Fullscreen, Brightness, Graphics API.
- Video / Quality & Performance: Preset, Biome Blend, Render Distance, Chunk
  Builder, Simulation Distance, Smooth Lighting, Clouds, Particles, Mipmap
  Levels, Entity Shadows, Entity Distance, Menu Background Blur, Cloud Distance,
  See-Through Leaves, Improved Transparency, Texture Filtering, Anisotropic
  Filtering, Weather Effect Radius.
- Video / Preferences: Autosave Indicator, Show Vignette, Attack Indicator,
  Chunk Fade.
- Controls: Mouse Settings, Key Binds, Sneak, Sprint, Attack/Destroy, Use
  Item/Place Block, Auto-Jump, Sprint Window, Operator Items Tab.
- Mouse: Sensitivity, Scroll Sensitivity, Discrete Scrolling, Invert Mouse X,
  Invert Mouse Y, Allow Cursor Changes, Raw Input. Touchscreen Mode is omitted
  because Java 26.2 removed it.
- Language: searchable language list and Font Settings. D Edition currently has
  only the bundled English (US) font/strings.
- Font: Force Unicode Font, Japanese Glyph Variants.
- Chat: Chat visibility, Colors, Web Links, Prompt on Links, Chat Text Opacity,
  Text Background Opacity, Chat Text Size, Line Spacing, Chat Delay, Width,
  Focused Height, Unfocused Height, Narrator, Command Suggestions, Hide Matched
  Names, Reduced Debug Info, Only Show Secure Chat, Save Unsent Chats.
- Resource Packs: Available/Selected columns, Open Pack Folder, Done.
- Accessibility: Narrator, Controls, Closed Captions, High Contrast, Menu
  Background Blur, Text Background Opacity/mode, Chat Text Opacity, Line Spacing,
  Chat Delay, Notification Time, View Bobbing, Distortion Effects, FOV Effects,
  Darkness Pulsing, Damage Tilt, Glint Speed/Strength, Hide Sky Flashes,
  Monochrome Logo, Panorama Scroll Speed, Hide Splash Texts, Narrator Hotkey,
  Rotate with Minecarts, High Contrast Block Outlines.
- Telemetry: Data Collection. D Edition reports `None` because it does not send
  Mojang telemetry.
- Credits & Attribution: Credits, Attribution, Licensing.

## D Edition capability notes

- Live now: FOV; mouse sensitivity and X/Y inversion; fullscreen, VSync and
  frame limiting; brightness, graphics preset, smooth lighting, cloud mode,
  particle level and entity shadows; view bobbing; auto-jump; hold/toggle
  behavior for sneak, sprint, attack and use; chat visibility, colors, opacity,
  spacing, width, heights and unsent drafts; master, block/effect, player and UI
  volume; and directional sound.
- Skin customization now controls the locally rendered hat, jacket, sleeves and
  pant legs. Those choices are included in protocol 9 player snapshots so other
  updated clients render the same layers.
- Key Binds now opens a device chooser. Keyboard & Mouse supports live rebinding
  for movement, jumping, sneaking, sprinting, attacking, using, dropping, chat,
  perspective, inventory and hotbar selection. Bindings save in
  `data/options.txt` and the Reset button restores Java defaults. Friends is
  shown disabled until that target screen exists. Controller has its own placeholder
  screen for the upcoming controller-input pass.
- Settings whose underlying engine feature does not exist are deliberately
  disabled instead of pretending to work. This currently includes music and
  weather categories, subtitles, resource/language packs, inventory/friends,
  most advanced video/post-processing controls, narrator/accessibility effects,
  and credits/external-service actions.
- D Edition remains DirectX 12 only, so Java's OpenGL/Vulkan API selection is
  informational and disabled.

## Sources

- Official 26.2 release notes:
  https://feedback.minecraft.net/hc/en-us/articles/46690753273997-Minecraft-Java-Edition-26-2
- Official Java chat settings:
  https://help.minecraft.net/hc/en-us/articles/43045760611469
- Current Java option descriptions and screenshot gallery:
  https://minecraft.wiki/w/Options
