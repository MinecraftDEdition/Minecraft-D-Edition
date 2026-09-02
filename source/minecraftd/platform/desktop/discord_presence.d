module minecraftd.platform.desktop.discord_presence;

version (MCD_DISCORD)
{
    import std.string : toStringz;

    extern (C) int mcdDiscordInitialize(ulong applicationId);
    extern (C) void mcdDiscordUpdate(const(char)* details,
        const(char)* state, const(char)* largeImage, const(char)* largeText);
    extern (C) void mcdDiscordRunCallbacks();
    extern (C) void mcdDiscordShutdown();
}

/// Failure-safe Discord activity integration shared by Windows and macOS.
final class DiscordPresence
{
    enum ulong applicationId = 1544456552436469790UL;
    enum string largeImage =
        "https://minecraftdedition.com/site-assets/mcde-logo.png";
    enum string largeText = "Minecraft: D Edition";

    private bool active;
    private string currentDetails;
    private string currentState;

    this()
    {
        version (MCD_DISCORD)
            active = mcdDiscordInitialize(applicationId) != 0;
    }

    ~this()
    {
        version (MCD_DISCORD)
        {
            if (active)
                mcdDiscordShutdown();
        }
    }

    void menu()
    {
        update("In Menu", "");
    }

    void singleplayer(string gameMode)
    {
        update("Singleplayer"~(gameMode.length?" · "~gameMode:""), "");
    }

    void multiplayer(string serverName,string gameMode)
    {
        update("Multiplayer"~(gameMode.length?" · "~gameMode:""),
            serverName.length ? serverName : "Multiplayer Server");
    }

    void tick()
    {
        version (MCD_DISCORD)
        {
            if (active)
                mcdDiscordRunCallbacks();
        }
    }

    private void update(string details, string state)
    {
        if (!active || (details == currentDetails && state == currentState))
            return;
        currentDetails = details.idup;
        currentState = state.idup;
        version (MCD_DISCORD)
            mcdDiscordUpdate(details.toStringz, state.toStringz,
                largeImage.toStringz, largeText.toStringz);
    }
}
