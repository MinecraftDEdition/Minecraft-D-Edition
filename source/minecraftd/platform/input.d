module minecraftd.platform.input;

import std.math : sqrt;

// Stable, platform-neutral key identifiers. Their numeric values intentionally
// match the existing Windows options file so player bindings migrate without a
// conversion. Native backends translate physical keys to these identifiers.
enum int KEY_MOUSE_LEFT = 0x01;
enum int KEY_MOUSE_RIGHT = 0x02;
enum int KEY_MOUSE_MIDDLE = 0x04;
enum int KEY_BACKSPACE = 0x08;
enum int KEY_TAB = 0x09;
enum int KEY_RETURN = 0x0D;
enum int KEY_SHIFT = 0x10;
enum int KEY_CONTROL = 0x11;
enum int KEY_ALT = 0x12;
enum int KEY_ESCAPE = 0x1B;
enum int KEY_SPACE = 0x20;
enum int KEY_END = 0x23;
enum int KEY_HOME = 0x24;
enum int KEY_LEFT = 0x25;
enum int KEY_UP = 0x26;
enum int KEY_RIGHT = 0x27;
enum int KEY_DOWN = 0x28;
enum int KEY_DELETE = 0x2E;
enum int KEY_F3 = 0x72;
enum int KEY_F5 = 0x74;
enum int KEY_F11 = 0x7A;
enum int KEY_LEFT_SHIFT = 0xA0;
enum int KEY_RIGHT_SHIFT = 0xA1;
enum int KEY_OEM_PLUS = 0xBB;
enum int KEY_NUMPAD_ADD = 0x6B;

// Temporary compatibility names keep the gameplay code and saved key values
// unchanged while the native implementations are separated.
alias VK_LBUTTON = KEY_MOUSE_LEFT;
alias VK_RBUTTON = KEY_MOUSE_RIGHT;
alias VK_MBUTTON = KEY_MOUSE_MIDDLE;
alias VK_BACK = KEY_BACKSPACE;
alias VK_TAB = KEY_TAB;
alias VK_RETURN = KEY_RETURN;
alias VK_SHIFT = KEY_SHIFT;
alias VK_CONTROL = KEY_CONTROL;
alias VK_ESCAPE = KEY_ESCAPE;
alias VK_SPACE = KEY_SPACE;
alias VK_END = KEY_END;
alias VK_HOME = KEY_HOME;
alias VK_LEFT = KEY_LEFT;
alias VK_RIGHT = KEY_RIGHT;
alias VK_DELETE = KEY_DELETE;
alias VK_F3 = KEY_F3;
alias VK_F11 = KEY_F11;
alias VK_RSHIFT = KEY_RIGHT_SHIFT;
alias VK_OEM_PLUS = KEY_OEM_PLUS;
alias VK_ADD = KEY_NUMPAD_ADD;

/// Stable Xbox-style controller buttons shared by every desktop backend.
/// Values retain the original XInput-compatible save/runtime contract while
/// the shared SDL backend translates its standardized gamepad layout here.
enum GamepadButton : ushort
{
    dpadUp = 0x0001,
    dpadDown = 0x0002,
    dpadLeft = 0x0004,
    dpadRight = 0x0008,
    menu = 0x0010,
    view = 0x0020,
    leftStick = 0x0040,
    rightStick = 0x0080,
    leftBumper = 0x0100,
    rightBumper = 0x0200,
    a = 0x1000,
    b = 0x2000,
    x = 0x4000,
    y = 0x8000,
}

struct GamepadState
{
    bool connected;
    uint deviceIndex;
    ushort buttons;
    ushort pressedButtons;
    ushort releasedButtons;
    float leftX = 0;
    float leftY = 0;
    float rightX = 0;
    float rightY = 0;
    float leftTrigger = 0;
    float rightTrigger = 0;
    bool leftTriggerPressed;
    bool rightTriggerPressed;

    bool down(GamepadButton button) const
    {
        return connected && (buttons & cast(ushort) button) != 0;
    }

    bool pressed(GamepadButton button) const
    {
        return connected && (pressedButtons & cast(ushort) button) != 0;
    }

    bool released(GamepadButton button) const
    {
        return (releasedButtons & cast(ushort) button) != 0;
    }

    bool hasStickActivity(float threshold = 0.08f) const
    {
        return absolute(leftX) > threshold || absolute(leftY) > threshold
            || absolute(rightX) > threshold || absolute(rightY) > threshold;
    }
}

struct NormalizedStick
{
    float x = 0;
    float y = 0;
}

/// Applies a radial deadzone, then rescales the remaining range back to 0..1.
/// This avoids diagonal drift and preserves full stick travel.
NormalizedStick normalizeStick(short rawX, short rawY, int deadzone)
{
    const x = rawX < 0 ? cast(float) rawX / 32768.0f
        : cast(float) rawX / 32767.0f;
    const y = rawY < 0 ? cast(float) rawY / 32768.0f
        : cast(float) rawY / 32767.0f;
    const magnitude = sqrt(x * x + y * y);
    const normalizedDeadzone = cast(float) deadzone / 32767.0f;
    if (magnitude <= normalizedDeadzone || magnitude <= 0.00001f)
        return NormalizedStick.init;
    const scaledMagnitude = clampUnit((magnitude - normalizedDeadzone)
        / (1.0f - normalizedDeadzone));
    return NormalizedStick(x / magnitude * scaledMagnitude,
        y / magnitude * scaledMagnitude);
}

float normalizeTrigger(ubyte rawValue, ubyte threshold = 30)
{
    if (rawValue <= threshold)
        return 0.0f;
    return clampUnit(cast(float)(rawValue - threshold) / (255 - threshold));
}

/// Optional user deadzone layered over the native hardware deadzone.
float controllerAxis(float value, float deadzone)
{
    const magnitude = absolute(value);
    if (magnitude <= deadzone)
        return 0.0f;
    const scaled = clampUnit((magnitude - deadzone) / (1.0f - deadzone));
    return value < 0 ? -scaled : scaled;
}

private float absolute(float value) pure nothrow
{
    return value < 0 ? -value : value;
}

private float clampUnit(float value) pure nothrow
{
    return value < 0 ? 0 : (value > 1 ? 1 : value);
}

version (Windows)
{
    import core.sys.windows.windows : POINT;
    alias Point = POINT;
}
else
{
    struct Point
    {
        int x;
        int y;
    }
}

unittest
{
    auto centered = normalizeStick(0, 0, 7849);
    assert(centered.x == 0 && centered.y == 0);
    auto right = normalizeStick(32767, 0, 7849);
    assert(right.x > 0.999f && right.y == 0);
    auto diagonal = normalizeStick(24000, 24000, 7849);
    assert(diagonal.x > 0.6f && diagonal.y > 0.6f);
    assert(normalizeTrigger(30) == 0);
    assert(normalizeTrigger(255) == 1);
    assert(controllerAxis(0.1f, 0.15f) == 0);
    assert(controllerAxis(-1.0f, 0.15f) == -1.0f);
}
