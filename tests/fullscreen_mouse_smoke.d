module fullscreen_mouse_smoke;
import core.sys.windows.windows;
import std.stdio : writeln;
import minecraftd.platform.windows.window;

void main()
{
    auto window=new GameWindow("MCDE fullscreen regression",960,540,1);
    scope(exit)destroy(window);
    SetForegroundWindow(window.handle);
    window.pumpMessages();window.setMouseCapture(true);
    foreach(_;0..4)
    {
        window.toggleFullscreen();window.pumpMessages();
        int w,h;window.consumeResize(w,h);
        // A stale cursor position during transition must never turn the view.
        POINT corner=POINT(10,10);ClientToScreen(window.handle,&corner);
        SetCursorPos(corner.x,corner.y);
        const delta=window.mouseDelta();
        assert(delta.x==0&&delta.y==0);
        const settled=window.mouseDelta();assert(settled.x==0&&settled.y==0);
    }
    SendMessageW(window.handle,WM_CLOSE,0,0);
    window.pumpMessages();
    assert(!window.running&&IsWindow(window.handle),"Close must leave the window alive for orderly save/teardown");
    writeln("PASS: fullscreen camera delta reset and orderly close request");
}
