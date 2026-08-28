module minecraftd.client.menu.multiplayer_menu_state;

import std.file : exists, getcwd, readText, write;
import std.path : buildPath;
import std.string : splitLines;

enum MultiplayerField : ubyte
{
    none,
    serverName,
    serverAddress,
}

/// State for the first direct-connect screen. It persists one named entry now;
/// the same file format can grow into a full Java-style server list later.
final class MultiplayerMenuState
{
    enum size_t maximumNameLength = 48;
    enum size_t maximumAddressLength = 255;

    string serverName = "My Server";
    string serverAddress;
    string error;
    MultiplayerField activeField = MultiplayerField.serverAddress;

    private string storagePath;

    this()
    {
        storagePath = buildPath(getcwd(), "data", "server_entry.txt");
        load();
    }

    void activate(MultiplayerField field)
    {
        activeField = field;
        error = "";
    }

    void insertCharacters(const(wchar)[] characters)
    {
        foreach (value; characters)
        {
            if (value == 8)
            {
                backspace();
                continue;
            }
            if (value < 32 || value > 126)
                continue;
            append(cast(char) value);
        }
    }

    void paste(string value)
    {
        foreach (ubyte character; cast(const(ubyte)[]) value)
            if (character >= 32 && character <= 126)
                append(cast(char) character);
    }

    void backspace()
    {
        final switch (activeField)
        {
            case MultiplayerField.serverName:
                if (serverName.length) serverName = serverName[0 .. $ - 1];
                break;
            case MultiplayerField.serverAddress:
                if (serverAddress.length)
                    serverAddress = serverAddress[0 .. $ - 1];
                break;
            case MultiplayerField.none:
                break;
        }
    }

    void selectNextField()
    {
        activeField = activeField == MultiplayerField.serverName
            ? MultiplayerField.serverAddress : MultiplayerField.serverName;
    }

    void save()
    {
        write(storagePath, serverName ~ "\n" ~ serverAddress ~ "\n");
    }

private:
    void append(char value)
    {
        final switch (activeField)
        {
            case MultiplayerField.serverName:
                if (serverName.length < maximumNameLength)
                    serverName ~= value;
                break;
            case MultiplayerField.serverAddress:
                if (serverAddress.length < maximumAddressLength)
                    serverAddress ~= value;
                break;
            case MultiplayerField.none:
                break;
        }
    }

    void load()
    {
        if (!exists(storagePath))
            return;
        try
        {
            const lines = readText(storagePath).splitLines();
            if (lines.length > 0 && lines[0].length)
                serverName = lines[0].idup;
            if (lines.length > 1)
                serverAddress = lines[1].idup;
        }
        catch (Exception) {}
    }
}

unittest
{
    auto state = new MultiplayerMenuState();
    state.serverAddress = "";
    state.activate(MultiplayerField.serverAddress);
    state.paste("127.0.0.1:25565\r\n");
    assert(state.serverAddress == "127.0.0.1:25565");
}
