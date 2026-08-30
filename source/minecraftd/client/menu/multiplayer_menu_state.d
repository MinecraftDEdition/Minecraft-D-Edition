module minecraftd.client.menu.multiplayer_menu_state;

import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.string : splitLines;
import minecraftd.client.input.text_edit_state : TextEditState;

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
    private TextEditState[3] editors;

    this(string userDataDirectory)
    {
        const dataDirectory = buildPath(userDataDirectory, "data");
        mkdirRecurse(dataDirectory);
        storagePath = buildPath(dataDirectory, "server_entry.txt");
        load();
        editors[cast(size_t) MultiplayerField.serverName].moveToEnd(serverName);
        editors[cast(size_t) MultiplayerField.serverAddress].moveToEnd(serverAddress);
    }

    void activate(MultiplayerField field)
    {
        activeField = field;
        if (field != MultiplayerField.none)
            activeEditor().clamp(activeValue());
        error = "";
    }

    void insertCharacters(const(wchar)[] characters)
    {
        foreach (value; characters)
        {
            if (value < 32 || value > 126)
                continue;
            insert(cast(char) value);
        }
    }

    void paste(string value)
    {
        foreach (ubyte character; cast(const(ubyte)[]) value)
            if (character >= 32 && character <= 126)
                insert(cast(char) character);
    }

    void backspace()
    {
        if (activeField != MultiplayerField.none)
            activeEditor().backspace(activeValue());
    }

    void deleteForward()
    {
        if (activeField != MultiplayerField.none)
            activeEditor().deleteForward(activeValue());
    }

    void moveCursor(int amount, bool selecting = false)
    {
        if (activeField != MultiplayerField.none)
            activeEditor().moveCursor(activeValue(), amount, selecting);
    }

    void moveToStart(bool selecting = false)
    {
        if (activeField != MultiplayerField.none)
            activeEditor().moveToStart(activeValue(), selecting);
    }

    void moveToEnd(bool selecting = false)
    {
        if (activeField != MultiplayerField.none)
            activeEditor().moveToEnd(activeValue(), selecting);
    }

    void setCursor(size_t position, bool selecting = false)
    {
        if (activeField != MultiplayerField.none)
            activeEditor().setCursor(activeValue(), position, selecting);
    }

    void selectAll()
    {
        if (activeField != MultiplayerField.none)
            activeEditor().selectAll(activeValue());
    }

    bool hasSelection() const
    {
        return activeField != MultiplayerField.none
            && editors[cast(size_t) activeField].hasSelection;
    }

    size_t cursor() const
    {
        return activeField == MultiplayerField.none ? 0
            : editors[cast(size_t) activeField].cursor;
    }

    size_t selectionAnchor() const
    {
        return activeField == MultiplayerField.none ? 0
            : editors[cast(size_t) activeField].selectionAnchor;
    }

    string selectedText() const
    {
        return activeField == MultiplayerField.none ? ""
            : editors[cast(size_t) activeField].selectedText(activeValueConst());
    }

    void cutSelection()
    {
        if (activeField != MultiplayerField.none)
            activeEditor().eraseSelection(activeValue());
    }

    void selectNextField()
    {
        activate(activeField == MultiplayerField.serverName
            ? MultiplayerField.serverAddress : MultiplayerField.serverName);
    }

    void save()
    {
        write(storagePath, serverName ~ "\n" ~ serverAddress ~ "\n");
    }

private:
    ref TextEditState activeEditor()
    {
        return editors[cast(size_t) activeField];
    }

    ref string activeValue()
    {
        final switch (activeField)
        {
            case MultiplayerField.serverName: return serverName;
            case MultiplayerField.serverAddress: return serverAddress;
            case MultiplayerField.none: return serverAddress;
        }
    }

    string activeValueConst() const
    {
        final switch (activeField)
        {
            case MultiplayerField.serverName: return serverName;
            case MultiplayerField.serverAddress: return serverAddress;
            case MultiplayerField.none: return "";
        }
    }

    void insert(char value)
    {
        final switch (activeField)
        {
            case MultiplayerField.serverName:
                activeEditor().insert(serverName, value, maximumNameLength);
                break;
            case MultiplayerField.serverAddress:
                activeEditor().insert(serverAddress, value, maximumAddressLength);
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
    import std.file : rmdirRecurse, tempDir;

    const directory = buildPath(tempDir(),
        "minecraft-d-edition-multiplayer-menu-test");
    scope (exit) if (exists(directory)) rmdirRecurse(directory);
    auto state = new MultiplayerMenuState(directory);
    state.serverAddress = "";
    state.activate(MultiplayerField.serverAddress);
    state.paste("127.0.0.1:25565\r\n");
    assert(state.serverAddress == "127.0.0.1:25565");
    state.moveCursor(-1);
    state.moveCursor(-1, true);
    assert(state.selectedText == "6");
    state.paste("7");
    assert(state.serverAddress == "127.0.0.1:25575");
    state.selectAll();
    state.paste("example.test:25565");
    assert(state.serverAddress == "example.test:25565");
    state.save();
    assert(exists(buildPath(directory, "data", "server_entry.txt")));
}
