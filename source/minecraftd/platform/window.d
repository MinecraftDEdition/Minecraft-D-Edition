module minecraftd.platform.window;

version (Windows)
    public import minecraftd.platform.windows.window : CursorShape, GameWindow;
else version (OSX)
    public import minecraftd.platform.macos.window : CursorShape, GameWindow;
else
    static assert(false, "Minecraft D Edition has no window backend for this platform");

