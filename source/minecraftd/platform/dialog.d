module minecraftd.platform.dialog;

version (Windows)
{
    import core.sys.windows.windows : MessageBoxW, MB_ICONERROR, MB_OK;
    import std.utf : toUTF16z;

    void showFatalError(string title, string message)
    {
        MessageBoxW(null, message.toUTF16z(), title.toUTF16z(),
            MB_OK | MB_ICONERROR);
    }
}
else version (OSX)
{
    import std.stdio : stderr;
    import std.string : toStringz;

    private extern(C) nothrow void mcdPlatformShowError(
        const(char)* title, const(char)* message);

    void showFatalError(string title, string message)
    {
        stderr.writefln("%s: %s", title, message);
        mcdPlatformShowError(title.toStringz(), message.toStringz());
    }
}

