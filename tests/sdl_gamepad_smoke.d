module sdl_gamepad_smoke;

import std.stdio : writeln;

import minecraftd.platform.desktop.gamepad : SdlGamepad;

int main()
{
    auto backend = new SdlGamepad();
    scope (exit) backend.shutdown();
    const state = backend.poll();
    writeln("SDL gamepad backend initialized; connected=", state.connected,
        " device=", state.deviceIndex, " buttons=", state.buttons,
        " left=", state.leftX, ",", state.leftY,
        " right=", state.rightX, ",", state.rightY);
    return 0;
}
