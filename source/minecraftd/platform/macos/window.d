module minecraftd.platform.macos.window;

version (OSX):

import std.string : fromStringz, toStringz;
import std.utf : toUTF16;

import minecraftd.platform.input : Point;

enum CursorShape : ubyte
{
    arrow,
    text,
    hand,
    horizontalResize,
}

private extern(C) nothrow
{
    void* mcdPlatformCreateWindow(const(char)* title, int width, int height,
        int localTestIndex, char* error, uint errorCapacity);
    void mcdPlatformDestroyWindow(void* context);
    void* mcdPlatformRendererWindow(void* context);
    void mcdPlatformPump(void* context);
    int mcdPlatformRunning(void* context);
    int mcdPlatformConsumeResize(void* context, int* width, int* height);
    int mcdPlatformKeyDown(void* context, int key);
    int mcdPlatformKeyPressed(void* context, int key);
    int mcdPlatformFirstPressedKey(void* context);
    int mcdPlatformConsumeWheel(void* context);
    uint mcdPlatformConsumeText(void* context, char* output, uint capacity);
    void mcdPlatformClearText(void* context);
    void mcdPlatformMouseDelta(void* context, int* x, int* y);
    void mcdPlatformCursorPosition(void* context, int* x, int* y);
    void mcdPlatformSetCursor(void* context, int shape);
    void mcdPlatformSetFullscreen(void* context, int enabled);
    int mcdPlatformFullscreen(void* context);
    void mcdPlatformSetMouseCapture(void* context, int captured);
    int mcdPlatformSetClipboard(const(char)* value);
    uint mcdPlatformGetClipboard(char* output, uint capacity);
    int mcdPlatformShortcutDown(void* context);
    void mcdPlatformWindowSize(void* context, int* width, int* height);
}

final class GameWindow
{
    enum int defaultWidth = 1280;
    enum int defaultHeight = 720;

    void* handle;
    int width;
    int height;
    bool running = true;
    bool mouseCaptured;
    bool fullscreen;

    private void* context;

    this(string title, int requestedWidth = defaultWidth,
        int requestedHeight = defaultHeight, int localTestIndex = 0)
    {
        char[1024] error = 0;
        context = mcdPlatformCreateWindow(title.toStringz(), requestedWidth,
            requestedHeight, localTestIndex, error.ptr,
            cast(uint) error.length);
        if (context is null)
            throw new Exception(error[0] ? fromStringz(error.ptr).idup
                : "Unable to create the macOS game window");
        handle = mcdPlatformRendererWindow(context);
        updateSize();
        fullscreen = mcdPlatformFullscreen(context) != 0;
        setMouseCapture(true);
    }

    ~this()
    {
        if (context !is null)
        {
            mcdPlatformDestroyWindow(context);
            context = null;
            handle = null;
        }
    }

    void pumpMessages()
    {
        mcdPlatformPump(context);
        running = mcdPlatformRunning(context) != 0;
    }

    bool consumeResize(out int resizedWidth, out int resizedHeight)
    {
        if (!mcdPlatformConsumeResize(context, &resizedWidth, &resizedHeight))
            return false;
        width = resizedWidth;
        height = resizedHeight;
        return true;
    }

    bool down(int key) const { return mcdPlatformKeyDown(context, key) != 0; }
    bool pressed(int key) const
    {
        return mcdPlatformKeyPressed(context, key) != 0;
    }
    int firstPressedKey() const { return mcdPlatformFirstPressedKey(context); }
    int consumeWheelSteps() { return mcdPlatformConsumeWheel(context); }

    wstring consumeTextInput()
    {
        char[4096] encoded = 0;
        const length = mcdPlatformConsumeText(context, encoded.ptr,
            cast(uint) encoded.length);
        if (length == 0)
            return null;
        return toUTF16(encoded[0 .. length]).idup;
    }

    void clearTextInput() { mcdPlatformClearText(context); }

    Point mouseDelta()
    {
        Point result;
        mcdPlatformMouseDelta(context, &result.x, &result.y);
        return result;
    }

    Point cursorPosition()
    {
        Point result;
        mcdPlatformCursorPosition(context, &result.x, &result.y);
        return result;
    }

    void setCursorShape(CursorShape shape)
    {
        mcdPlatformSetCursor(context, cast(int) shape);
    }

    void toggleFullscreen() { setFullscreen(!fullscreen); }
    void setFullscreen(bool enabled)
    {
        mcdPlatformSetFullscreen(context, enabled ? 1 : 0);
        fullscreen = mcdPlatformFullscreen(context) != 0;
        updateSize();
    }

    void setMouseCapture(bool capture)
    {
        mouseCaptured = capture;
        mcdPlatformSetMouseCapture(context, capture ? 1 : 0);
    }

    bool setClipboardText(string value)
    {
        return mcdPlatformSetClipboard(value.toStringz()) != 0;
    }

    string clipboardText()
    {
        char[8192] encoded = 0;
        const length = mcdPlatformGetClipboard(encoded.ptr,
            cast(uint) encoded.length);
        return length ? encoded[0 .. length].idup : "";
    }

    bool shortcutDown() const
    {
        return mcdPlatformShortcutDown(context) != 0;
    }

private:
    void updateSize()
    {
        mcdPlatformWindowSize(context, &width, &height);
    }
}

