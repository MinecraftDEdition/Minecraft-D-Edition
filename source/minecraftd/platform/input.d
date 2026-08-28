module minecraftd.platform.input;

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
alias VK_F11 = KEY_F11;
alias VK_RSHIFT = KEY_RIGHT_SHIFT;
alias VK_OEM_PLUS = KEY_OEM_PLUS;
alias VK_ADD = KEY_NUMPAD_ADD;

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

