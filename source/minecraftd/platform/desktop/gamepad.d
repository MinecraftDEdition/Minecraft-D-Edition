module minecraftd.platform.desktop.gamepad;

import minecraftd.platform.input : GamepadButton, GamepadState,
    normalizeStick;

private enum uint sdlInitGamepad = 0x00002000;
private enum int reconnectPollFrames = 30;
private enum int leftStickDeadzone = 7849;
private enum int rightStickDeadzone = 8689;

private enum SdlGamepadAxis : int
{
    leftX,
    leftY,
    rightX,
    rightY,
    leftTrigger,
    rightTrigger,
}

private enum SdlGamepadButton : int
{
    south,
    east,
    west,
    north,
    back,
    guide,
    start,
    leftStick,
    rightStick,
    leftShoulder,
    rightShoulder,
    dpadUp,
    dpadDown,
    dpadLeft,
    dpadRight,
    count,
}

private extern(C) nothrow
{
    bool SDL_InitSubSystem(uint flags);
    void SDL_QuitSubSystem(uint flags);
    void SDL_SetGamepadEventsEnabled(bool enabled);
    void SDL_UpdateGamepads();
    uint* SDL_GetGamepads(int* count);
    void* SDL_OpenGamepad(uint instanceId);
    void SDL_CloseGamepad(void* gamepad);
    bool SDL_GamepadConnected(void* gamepad);
    uint SDL_GetGamepadID(void* gamepad);
    short SDL_GetGamepadAxis(void* gamepad, SdlGamepadAxis axis);
    bool SDL_GetGamepadButton(void* gamepad, SdlGamepadButton button);
    void SDL_free(void* memory);
}

/// SDL owns device discovery and platform-specific controller drivers. This
/// class converts its standard gamepad layout into the stable input contract
/// consumed by gameplay on Windows, macOS, and future Linux builds.
final class SdlGamepad
{
    private bool initialized;
    private void* device;
    private uint reconnectCountdown;
    private GamepadState previous;

    this()
    {
        initialized = SDL_InitSubSystem(sdlInitGamepad);
        if (initialized)
        {
            // The native window backends do not consume controller events.
            // Poll explicitly so the same path behaves identically everywhere.
            SDL_SetGamepadEventsEnabled(false);
            openFirstAvailable();
        }
    }

    ~this()
    {
        shutdown();
    }

    void shutdown()
    {
        if (!initialized)
            return;
        closeDevice();
        SDL_QuitSubSystem(sdlInitGamepad);
        initialized = false;
        previous = GamepadState.init;
    }

    GamepadState poll()
    {
        if (!initialized)
            return GamepadState.init;

        SDL_UpdateGamepads();
        if (device !is null && !SDL_GamepadConnected(device))
        {
            closeDevice();
            reconnectCountdown = 0;
        }
        if (device is null)
        {
            if (reconnectCountdown == 0)
            {
                openFirstAvailable();
                reconnectCountdown = reconnectPollFrames;
            }
            else
                --reconnectCountdown;
        }

        GamepadState next;
        if (device is null)
        {
            next.releasedButtons = previous.buttons;
            previous = next;
            return next;
        }

        next.connected = true;
        next.deviceIndex = SDL_GetGamepadID(device);
        uint sdlButtonMask;
        foreach (button; SdlGamepadButton.south .. SdlGamepadButton.count)
            if (SDL_GetGamepadButton(device, button))
                sdlButtonMask |= 1u << cast(uint)button;
        next.buttons = translateButtonMask(sdlButtonMask);
        next.pressedButtons = cast(ushort)(next.buttons & ~previous.buttons);
        next.releasedButtons = cast(ushort)(previous.buttons & ~next.buttons);

        const left = normalizeStick(
            SDL_GetGamepadAxis(device, SdlGamepadAxis.leftX),
            invertVerticalAxis(SDL_GetGamepadAxis(device,
                SdlGamepadAxis.leftY)), leftStickDeadzone);
        const right = normalizeStick(
            SDL_GetGamepadAxis(device, SdlGamepadAxis.rightX),
            invertVerticalAxis(SDL_GetGamepadAxis(device,
                SdlGamepadAxis.rightY)), rightStickDeadzone);
        next.leftX = left.x;
        next.leftY = left.y;
        next.rightX = right.x;
        next.rightY = right.y;
        next.leftTrigger = normalizeSdlTrigger(SDL_GetGamepadAxis(device,
            SdlGamepadAxis.leftTrigger));
        next.rightTrigger = normalizeSdlTrigger(SDL_GetGamepadAxis(device,
            SdlGamepadAxis.rightTrigger));
        next.leftTriggerPressed = next.leftTrigger > 0
            && previous.leftTrigger <= 0;
        next.rightTriggerPressed = next.rightTrigger > 0
            && previous.rightTrigger <= 0;
        previous = next;
        return next;
    }

private:
    void openFirstAvailable()
    {
        int count;
        auto identifiers = SDL_GetGamepads(&count);
        scope (exit) if (identifiers !is null) SDL_free(identifiers);
        foreach (index; 0 .. count)
        {
            device = SDL_OpenGamepad(identifiers[index]);
            if (device !is null)
                return;
        }
    }

    void closeDevice()
    {
        if (device !is null)
        {
            SDL_CloseGamepad(device);
            device = null;
        }
    }
}

private ushort translateButtonMask(uint source) pure nothrow
{
    ushort result;
    void map(SdlGamepadButton from, GamepadButton to)
    {
        if (source & (1u << cast(uint)from))
            result |= cast(ushort)to;
    }
    map(SdlGamepadButton.south, GamepadButton.a);
    map(SdlGamepadButton.east, GamepadButton.b);
    map(SdlGamepadButton.west, GamepadButton.x);
    map(SdlGamepadButton.north, GamepadButton.y);
    map(SdlGamepadButton.back, GamepadButton.view);
    map(SdlGamepadButton.start, GamepadButton.menu);
    map(SdlGamepadButton.leftStick, GamepadButton.leftStick);
    map(SdlGamepadButton.rightStick, GamepadButton.rightStick);
    map(SdlGamepadButton.leftShoulder, GamepadButton.leftBumper);
    map(SdlGamepadButton.rightShoulder, GamepadButton.rightBumper);
    map(SdlGamepadButton.dpadUp, GamepadButton.dpadUp);
    map(SdlGamepadButton.dpadDown, GamepadButton.dpadDown);
    map(SdlGamepadButton.dpadLeft, GamepadButton.dpadLeft);
    map(SdlGamepadButton.dpadRight, GamepadButton.dpadRight);
    return result;
}

private short invertVerticalAxis(short value) pure nothrow
{
    return value == short.min ? short.max : cast(short)-value;
}

private float normalizeSdlTrigger(short value) pure nothrow
{
    // Match the approximately 12% native XInput trigger threshold used by the
    // first controller iteration, then rescale the remaining travel to 0..1.
    enum int threshold = 3_855;
    const positive = value > 0 ? cast(int)value : 0;
    if (positive <= threshold)
        return 0;
    const normalized = cast(float)(positive - threshold) / (32_767 - threshold);
    return normalized > 1 ? 1 : normalized;
}

unittest
{
    const source = (1u << SdlGamepadButton.south)
        | (1u << SdlGamepadButton.rightShoulder)
        | (1u << SdlGamepadButton.dpadLeft);
    const translated = translateButtonMask(source);
    assert((translated & GamepadButton.a) != 0);
    assert((translated & GamepadButton.rightBumper) != 0);
    assert((translated & GamepadButton.dpadLeft) != 0);
    assert((translated & GamepadButton.b) == 0);
    assert(invertVerticalAxis(short.min) == short.max);
    assert(invertVerticalAxis(12_000) == -12_000);
    assert(normalizeSdlTrigger(3_855) == 0);
    assert(normalizeSdlTrigger(short.max) == 1);
}
