module minecraftd.platform.windows.window;

version (Windows):

import core.sys.windows.windows;
import core.stdc.string : memcpy;
import std.conv : to;
import std.file : exists, getcwd, readText, write;
import std.path : buildPath;
import std.string : toStringz;
import std.string : split;
import std.utf : toUTF16, toUTF16z, toUTF8;

import minecraftd.platform.desktop.gamepad : SdlGamepad;
import minecraftd.platform.input : GamepadState;

private __gshared int pendingWheelDelta;
private __gshared wchar[256] pendingCharacters;
private __gshared size_t pendingCharacterCount;
private __gshared int pendingClientWidth;
private __gshared int pendingClientHeight;
private __gshared HCURSOR desiredCursor;
private __gshared bool closeRequested;
private __gshared bool[256] framePressed;
private __gshared bool[256] frameRepeated;

enum CursorShape : ubyte
{
    arrow,
    text,
    hand,
    horizontalResize,
}

extern (Windows) LRESULT windowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (message)
    {
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
            // Bit 30 is set for auto-repeated key-down messages. `pressed`
            // represents a physical up-to-down edge, so latch only the first.
            if (wParam < framePressed.length)
            {
                if ((lParam & (1L << 30)) == 0)
                    framePressed[cast(size_t) wParam] = true;
                else
                    frameRepeated[cast(size_t) wParam] = true;
            }
            return DefWindowProcW(window, message, wParam, lParam);
        case WM_LBUTTONDOWN:
            framePressed[VK_LBUTTON] = true;
            return DefWindowProcW(window, message, wParam, lParam);
        case WM_RBUTTONDOWN:
            framePressed[VK_RBUTTON] = true;
            return DefWindowProcW(window, message, wParam, lParam);
        case WM_MBUTTONDOWN:
            framePressed[VK_MBUTTON] = true;
            return DefWindowProcW(window, message, wParam, lParam);
        case WM_CLOSE:
            // Let GameWindow's destructor persist placement/fullscreen state
            // while the HWND is still valid, then destroy it during teardown.
            closeRequested = true;
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_ERASEBKGND:
            return 1;
        case WM_MOUSEWHEEL:
            pendingWheelDelta += cast(short) ((wParam >> 16) & 0xFFFF);
            return 0;
        case WM_CHAR:
            if (pendingCharacterCount < pendingCharacters.length)
                pendingCharacters[pendingCharacterCount++] = cast(wchar) wParam;
            return 0;
        case WM_SIZE:
            if (wParam != SIZE_MINIMIZED)
            {
                pendingClientWidth = cast(ushort) (lParam & 0xFFFF);
                pendingClientHeight = cast(ushort) ((lParam >> 16) & 0xFFFF);
            }
            return 0;
        case WM_SETCURSOR:
            if (cast(ushort) (lParam & 0xFFFF) == HTCLIENT
                && desiredCursor !is null)
            {
                SetCursor(desiredCursor);
                return TRUE;
            }
            return DefWindowProcW(window, message, wParam, lParam);
        default:
            return DefWindowProcW(window, message, wParam, lParam);
    }
}

final class GameWindow
{
    enum int defaultWidth = 1280;
    enum int defaultHeight = 720;

    HWND handle;
    int width;
    int height;
    bool running = true;
    bool mouseCaptured = false;
    bool fullscreen;
    bool cursorVisible = true;

    private string statePath;
    private WINDOWPLACEMENT windowedPlacement;
    private LONG_PTR windowedStyle;
    private bool persistWindowState = true;
    private SdlGamepad gamepadBackend;
    private GamepadState gamepad;

    this(string title, int width = defaultWidth, int height = defaultHeight,
        int localTestIndex = 0)
    {
        statePath = buildPath(getcwd(), "data", "window_state.txt");
        auto saved = loadState();
        if (localTestIndex > 0)
        {
            saved = SavedState.init;
            width = 960;
            height = 540;
            persistWindowState = false;
        }
        if (saved.valid)
        {
            width = saved.width;
            height = saved.height;
        }
        this.width = width;
        this.height = height;
        auto instance = GetModuleHandleW(null);
        const className = "MinecraftDEditionWindow"w;

        WNDCLASSEXW windowClass;
        windowClass.cbSize = WNDCLASSEXW.sizeof;
        windowClass.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
        windowClass.lpfnWndProc = &windowProcedure;
        windowClass.hInstance = instance;
        windowClass.hIcon = LoadIconW(instance, cast(LPCWSTR) 101);
        windowClass.hIconSm = windowClass.hIcon;
        desiredCursor = LoadCursorW(null, IDC_ARROW);
        windowClass.hCursor = desiredCursor;
        windowClass.lpszClassName = className.ptr;
        if (RegisterClassExW(&windowClass) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
            throw new Exception("RegisterClassExW failed");

        RECT rectangle = {0, 0, width, height};
        const style = WS_OVERLAPPEDWINDOW;
        AdjustWindowRect(&rectangle, style, FALSE);
        const initialX = localTestIndex > 0 ? 30 + localTestIndex * 36
            : (saved.valid ? saved.left : CW_USEDEFAULT);
        const initialY = localTestIndex > 0 ? 30 + localTestIndex * 28
            : (saved.valid ? saved.top : CW_USEDEFAULT);
        handle = CreateWindowExW(
            0,
            className.ptr,
            title.toUTF16z(),
            style,
            initialX,
            initialY,
            rectangle.right - rectangle.left,
            rectangle.bottom - rectangle.top,
            null,
            null,
            instance,
            null,
        );
        if (handle is null)
            throw new Exception("CreateWindowExW failed");
        windowedStyle = GetWindowLongPtrW(handle, GWL_STYLE);
        windowedPlacement.length = WINDOWPLACEMENT.sizeof;
        GetWindowPlacement(handle, &windowedPlacement);
        if (saved.valid)
        {
            windowedPlacement.showCmd = saved.maximized
                ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
            windowedPlacement.rcNormalPosition = RECT(saved.left, saved.top,
                saved.left + saved.width, saved.top + saved.height);
            SetWindowPlacement(handle, &windowedPlacement);
        }
        ShowWindow(handle, saved.valid && saved.maximized
            ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
        UpdateWindow(handle);
        SetForegroundWindow(handle);
        SetFocus(handle);
        if (localTestIndex == 0 && (!saved.valid || saved.fullscreen))
            enterFullscreen();
        updateClientSize();
        pendingClientWidth = pendingClientHeight = 0;
        gamepadBackend = new SdlGamepad();
        setMouseCapture(true);
    }

    ~this()
    {
        if (gamepadBackend !is null)
        {
            gamepadBackend.shutdown();
            gamepadBackend = null;
        }
        setMouseCapture(false);
        if (persistWindowState)
            saveState();
        if (handle !is null && IsWindow(handle))
            DestroyWindow(handle);
    }

    void pumpMessages()
    {
        // Win32's GetAsyncKeyState low bit can be consumed by another caller
        // and can miss a complete press/release between rendered frames. Keep
        // a frame-local event latch populated by the window procedure instead.
        framePressed[] = false;
        frameRepeated[] = false;
        MSG message;
        while (PeekMessageW(&message, null, 0, 0, PM_REMOVE))
        {
            if (message.message == WM_QUIT)
                running = false;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (closeRequested)
        {
            closeRequested = false;
            running = false;
        }
        pollGamepad();
    }

    GamepadState gamepadState() const
    {
        return gamepad;
    }

    bool consumeResize(out int resizedWidth, out int resizedHeight)
    {
        if (pendingClientWidth <= 0 || pendingClientHeight <= 0)
            return false;
        resizedWidth = pendingClientWidth;
        resizedHeight = pendingClientHeight;
        pendingClientWidth = pendingClientHeight = 0;
        width = resizedWidth;
        height = resizedHeight;
        return true;
    }

    bool down(int virtualKey) const
    {
        return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
    }

    bool pressed(int virtualKey) const
    {
        return virtualKey >= 0 && virtualKey < framePressed.length
            && framePressed[virtualKey];
    }

    bool repeated(int virtualKey) const
    {
        return virtualKey >= 0 && virtualKey < frameRepeated.length
            && frameRepeated[virtualKey];
    }

    int firstPressedKey() const
    {
        foreach (key, pressedNow; framePressed)
            if (pressedNow)
                return cast(int) key;
        return -1;
    }

    int consumeWheelSteps()
    {
        const steps = pendingWheelDelta / WHEEL_DELTA;
        pendingWheelDelta %= WHEEL_DELTA;
        return steps;
    }

    wstring consumeTextInput()
    {
        wstring result = pendingCharacters[0 .. pendingCharacterCount].dup;
        pendingCharacterCount = 0;
        return result;
    }

    void clearTextInput()
    {
        pendingCharacterCount = 0;
    }

    POINT mouseDelta()
    {
        POINT center = {width / 2, height / 2};
        ClientToScreen(handle, &center);
        POINT current;
        GetCursorPos(&current);
        POINT delta = {current.x - center.x, current.y - center.y};
        if (mouseCaptured && GetForegroundWindow() == handle)
            SetCursorPos(center.x, center.y);
        else
            delta = POINT(0, 0);
        return delta;
    }

    POINT cursorPosition()
    {
        POINT current;
        GetCursorPos(&current);
        ScreenToClient(handle, &current);
        return current;
    }

    void setCursorShape(CursorShape shape)
    {
        final switch (shape)
        {
            case CursorShape.arrow:
                desiredCursor = LoadCursorW(null, IDC_ARROW);
                break;
            case CursorShape.text:
                desiredCursor = LoadCursorW(null, IDC_IBEAM);
                break;
            case CursorShape.hand:
                desiredCursor = LoadCursorW(null, IDC_HAND);
                break;
            case CursorShape.horizontalResize:
                desiredCursor = LoadCursorW(null, IDC_SIZEWE);
                break;
        }
        if (!mouseCaptured)
            SetCursor(desiredCursor);
    }

    void setCursorVisible(bool visible)
    {
        if (mouseCaptured || cursorVisible == visible)
            return;
        if (visible)
            while (ShowCursor(TRUE) < 0) {}
        else
            while (ShowCursor(FALSE) >= 0) {}
        cursorVisible = visible;
    }

    void toggleFullscreen()
    {
        if (fullscreen)
            leaveFullscreen();
        else
            enterFullscreen();
        updateClientSize();
    }

    void setFullscreen(bool enabled)
    {
        if (fullscreen != enabled)
            toggleFullscreen();
    }

    bool setClipboardText(string value)
    {
        const encoded = toUTF16(value);
        if (!OpenClipboard(handle))
            return false;
        scope (exit) CloseClipboard();
        EmptyClipboard();
        const bytes = (encoded.length + 1) * wchar.sizeof;
        auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if (memory is null)
            return false;
        auto destination = cast(wchar*) GlobalLock(memory);
        if (destination is null)
        {
            GlobalFree(memory);
            return false;
        }
        if (encoded.length)
            memcpy(destination, encoded.ptr, encoded.length * wchar.sizeof);
        destination[encoded.length] = 0;
        GlobalUnlock(memory);
        if (SetClipboardData(CF_UNICODETEXT, memory) is null)
        {
            GlobalFree(memory);
            return false;
        }
        return true; // the clipboard now owns memory
    }

    string clipboardText()
    {
        if (!IsClipboardFormatAvailable(CF_UNICODETEXT)
            || !OpenClipboard(handle))
            return "";
        scope (exit) CloseClipboard();
        auto memory = GetClipboardData(CF_UNICODETEXT);
        if (memory is null)
            return "";
        auto source = cast(const(wchar)*) GlobalLock(memory);
        if (source is null)
            return "";
        scope (exit) GlobalUnlock(memory);
        size_t length;
        while (source[length] != 0) ++length;
        return toUTF8(source[0 .. length]);
    }

    bool shortcutDown() const
    {
        return down(VK_CONTROL);
    }

    void setMouseCapture(bool capture)
    {
        if (mouseCaptured == capture && handle !is null)
            return;
        mouseCaptured = capture;
        if (capture)
        {
            SetCapture(handle);
            POINT center = {width / 2, height / 2};
            ClientToScreen(handle, &center);
            SetCursorPos(center.x, center.y);
            while (ShowCursor(FALSE) >= 0) {}
            cursorVisible = false;
        }
        else
        {
            ReleaseCapture();
            while (ShowCursor(TRUE) < 0) {}
            cursorVisible = true;
        }
    }

private:
    void pollGamepad()
    {
        gamepad = gamepadBackend is null
            ? GamepadState.init : gamepadBackend.poll();
    }

    struct SavedState
    {
        bool valid;
        int left;
        int top;
        int width;
        int height;
        bool maximized;
        bool fullscreen;
    }

    SavedState loadState() const
    {
        SavedState result;
        if (!exists(statePath))
            return result;
        try
        {
            const values = readText(statePath).split();
            if (values.length < 6)
                return result;
            result.left = to!int(values[0]);
            result.top = to!int(values[1]);
            result.width = to!int(values[2]);
            result.height = to!int(values[3]);
            result.maximized = to!int(values[4]) != 0;
            result.fullscreen = to!int(values[5]) != 0;
            result.valid = result.width >= 320 && result.height >= 240;
        }
        catch (Exception) {}
        return result;
    }

    void saveState()
    {
        if (handle is null || !IsWindow(handle))
            return;
        WINDOWPLACEMENT placement;
        if (fullscreen)
            placement = windowedPlacement;
        else
        {
            placement.length = WINDOWPLACEMENT.sizeof;
            if (!GetWindowPlacement(handle, &placement))
                return;
        }
        const rect = placement.rcNormalPosition;
        const maximized = placement.showCmd == SW_SHOWMAXIMIZED
            || (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
        import std.format : format;
        write(statePath, format("%s %s %s %s %s %s\n",
            rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
            maximized ? 1 : 0, fullscreen ? 1 : 0));
    }

    void enterFullscreen()
    {
        if (fullscreen)
            return;
        windowedPlacement.length = WINDOWPLACEMENT.sizeof;
        GetWindowPlacement(handle, &windowedPlacement);
        windowedStyle = GetWindowLongPtrW(handle, GWL_STYLE);
        MONITORINFO monitor;
        monitor.cbSize = MONITORINFO.sizeof;
        auto display = MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST);
        GetMonitorInfoW(display, &monitor);
        SetWindowLongPtrW(handle, GWL_STYLE,
            cast(LONG_PTR) (WS_POPUP | WS_VISIBLE));
        SetWindowPos(handle, HWND_TOP, monitor.rcMonitor.left,
            monitor.rcMonitor.top,
            monitor.rcMonitor.right - monitor.rcMonitor.left,
            monitor.rcMonitor.bottom - monitor.rcMonitor.top,
            SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
        fullscreen = true;
    }

    void leaveFullscreen()
    {
        if (!fullscreen)
            return;
        SetWindowLongPtrW(handle, GWL_STYLE, windowedStyle);
        SetWindowPlacement(handle, &windowedPlacement);
        SetWindowPos(handle, null, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE
            | SWP_NOZORDER | SWP_NOOWNERZORDER);
        fullscreen = false;
    }

    void updateClientSize()
    {
        RECT client;
        GetClientRect(handle, &client);
        width = client.right - client.left;
        height = client.bottom - client.top;
    }
}
