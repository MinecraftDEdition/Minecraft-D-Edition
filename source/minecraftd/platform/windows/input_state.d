module minecraftd.platform.windows.input_state;

/// A physical key being held is not permission to send it to the game.
/// Overlay-intercepted keys never enter this window-delivered input state.
struct WindowInputState
{
    bool[256] held;
    bool[256] blocked;

    bool press(int key, bool repeat=false) nothrow
    {
        if(key<0||key>=held.length||blocked[key])return false;
        if(repeat)return held[key];
        held[key]=true;
        return true;
    }

    void release(int key) nothrow
    {
        if(key<0||key>=held.length)return;
        held[key]=false;blocked[key]=false;
    }

    void reset() nothrow { held[]=false;blocked[]=false; }

    void suppressHeld(int key, bool physicallyDown) nothrow
    {
        if(key<0||key>=held.length)return;
        held[key]=false;blocked[key]=physicallyDown;
    }

    bool down(int key) const nothrow
    {return key>=0&&key<held.length&&held[key]&&!blocked[key];}
}

unittest
{
    WindowInputState input;
    assert(!input.down(87)); // Physical polling alone cannot start movement.
    assert(input.press(87));assert(input.down(87));
    input.reset();input.suppressHeld(87,true);
    assert(!input.press(87,true));assert(!input.press(87));
    assert(!input.down(87));
    input.release(87);assert(input.press(87));assert(input.down(87));
    input.reset();assert(!input.press(87,true)); // Stale repeat after overlay.
    assert(input.press(1));input.release(1);assert(!input.down(1));
    assert(!input.press(-1)&&!input.down(256));
}
