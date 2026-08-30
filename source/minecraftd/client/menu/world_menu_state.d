module minecraftd.client.menu.world_menu_state;

import std.conv : to;
import std.file : getcwd;
import std.string : strip;
import std.utf : toUTF8;
import minecraftd.client.input.text_edit_state : TextEditState;
import minecraftd.world.world_settings : Difficulty, GameMode, WorldEntry,
    WorldSettings, WorldType, listWorlds, safeFolderName, uniqueWorldFolder;

enum WorldMenuScreen : ubyte
{
    selection,
    creation,
    confirmDelete,
}

enum WorldCreationTab : ubyte
{
    game,
    world,
    more,
}

enum WorldField : ubyte
{
    none,
    name,
    seed,
}

final class WorldMenuState
{
    string root;
    WorldEntry[] worlds;
    int selected = -1;
    WorldMenuScreen screen = WorldMenuScreen.selection;
    WorldCreationTab tab = WorldCreationTab.game;
    WorldField field;
    WorldSettings draft;
    string seedInput;
    bool editing;
    string editingDirectory;
    string notice;

    private TextEditState[3] editors;

    this(string root = getcwd())
    {
        this.root = root;
        refresh();
        resetDraft();
        field = WorldField.none;
    }

    void refresh()
    {
        worlds = listWorlds(root);
        if (!worlds.length) selected = -1;
        else if (selected < 0 || selected >= worlds.length) selected = 0;
    }

    void resetDraft()
    {
        draft = WorldSettings.init;
        draft.name = "New World";
        draft.seed = 0;
        draft.folder = "";
        seedInput = "";
        tab = WorldCreationTab.game;
        field = WorldField.name;
        editing = false;
        editingDirectory = "";
        notice = "";
        editors[cast(size_t) WorldField.name].moveToEnd(draft.name);
        editors[cast(size_t) WorldField.seed].moveToEnd(seedInput);
    }

    void beginCreate()
    {
        resetDraft();
        screen = WorldMenuScreen.creation;
    }

    void beginEdit()
    {
        if (!hasSelection) return;
        draft = worlds[selected].settings;
        seedInput = to!string(draft.seed);
        editing = true;
        editingDirectory = worlds[selected].directory;
        field = WorldField.name;
        tab = WorldCreationTab.game;
        notice = "World seed and terrain type are fixed after creation.";
        screen = WorldMenuScreen.creation;
        editors[cast(size_t) WorldField.name].moveToEnd(draft.name);
        editors[cast(size_t) WorldField.seed].moveToEnd(seedInput);
    }

    void beginRecreate()
    {
        if (!hasSelection) return;
        draft = worlds[selected].settings;
        seedInput = to!string(draft.seed);
        draft.name = "Copy of " ~ draft.name;
        draft.folder = "";
        editing = false;
        editingDirectory = "";
        field = WorldField.name;
        tab = WorldCreationTab.game;
        notice = "";
        screen = WorldMenuScreen.creation;
        editors[cast(size_t) WorldField.name].moveToEnd(draft.name);
        editors[cast(size_t) WorldField.seed].moveToEnd(seedInput);
    }

    bool hasSelection() const
    {
        return selected >= 0 && selected < worlds.length;
    }

    void insertCharacters(const(wchar)[] characters)
    {
        insertCharacters(toUTF8(characters));
    }

    void insertCharacters(string text)
    {
        if (field == WorldField.none) return;
        foreach (character; text)
        {
            if (character < 32 || character == 127) continue;
            final switch (field)
            {
                case WorldField.name:
                    activeEditor().insert(draft.name, character, 40);
                    break;
                case WorldField.seed:
                    if (activeEditor().insert(seedInput, character, 19,
                        &validSeedInput)) updateSeed();
                    break;
                case WorldField.none: break;
            }
        }
    }

    void backspace()
    {
        final switch (field)
        {
            case WorldField.name:
                activeEditor().backspace(draft.name);
                break;
            case WorldField.seed:
                activeEditor().backspace(seedInput);
                updateSeed();
                break;
            case WorldField.none: break;
        }
    }

    void deleteForward()
    {
        final switch (field)
        {
            case WorldField.name: activeEditor().deleteForward(draft.name); break;
            case WorldField.seed:
                activeEditor().deleteForward(seedInput);
                updateSeed();
                break;
            case WorldField.none: break;
        }
    }

    void activate(WorldField next)
    {
        field = next;
        if (field != WorldField.none)
            activeEditor().clamp(activeValue());
    }

    void moveCursor(int amount, bool selecting = false)
    {
        if (field != WorldField.none)
            activeEditor().moveCursor(activeValue(), amount, selecting);
    }

    void moveToStart(bool selecting = false)
    {
        if (field != WorldField.none)
            activeEditor().moveToStart(activeValue(), selecting);
    }

    void moveToEnd(bool selecting = false)
    {
        if (field != WorldField.none)
            activeEditor().moveToEnd(activeValue(), selecting);
    }

    void setCursor(size_t position, bool selecting = false)
    {
        if (field != WorldField.none)
            activeEditor().setCursor(activeValue(), position, selecting);
    }

    void selectAll()
    {
        if (field != WorldField.none)
            activeEditor().selectAll(activeValue());
    }

    bool hasTextSelection() const
    {
        return field != WorldField.none
            && editors[cast(size_t) field].hasSelection;
    }

    size_t cursor() const
    {
        return field == WorldField.none ? 0
            : editors[cast(size_t) field].cursor;
    }

    size_t selectionAnchor() const
    {
        return field == WorldField.none ? 0
            : editors[cast(size_t) field].selectionAnchor;
    }

    string selectedText() const
    {
        return field == WorldField.none ? ""
            : editors[cast(size_t) field].selectedText(activeValueConst());
    }

    void cutSelection()
    {
        if (field == WorldField.none) return;
        activeEditor().eraseSelection(activeValue());
        if (field == WorldField.seed) updateSeed();
    }

    void cycleMode()
    {
        if (draft.hardcore)
        {
            draft.hardcore = false;
            draft.gameMode = GameMode.creative;
            draft.difficulty = Difficulty.normal;
            draft.allowCommands = true;
            return;
        }
        final switch (draft.gameMode)
        {
            case GameMode.survival:
                draft.hardcore = true;
                draft.difficulty = Difficulty.hard;
                draft.allowCommands = false;
                break;
            case GameMode.creative: draft.gameMode = GameMode.adventure; break;
            case GameMode.adventure: draft.gameMode = GameMode.spectator; break;
            case GameMode.spectator:
                draft.gameMode = GameMode.survival;
                draft.allowCommands = false;
                break;
        }
    }

    string modeLabel() const
    {
        if (draft.hardcore) return "Hardcore";
        import minecraftd.world.world_settings : gameModeName;
        return gameModeName(draft.gameMode);
    }

    void cycleDifficulty()
    {
        if (draft.hardcore) return;
        draft.difficulty = cast(Difficulty) ((cast(int) draft.difficulty + 1) % 4);
    }

    string prepareFolder()
    {
        draft.name = strip(draft.name);
        if (!draft.name.length) draft.name = "New World";
        if (editing) return editingDirectory;
        draft.folder = uniqueWorldFolder(root, safeFolderName(draft.name));
        import minecraftd.world.world_settings : savesDirectory;
        import std.path : buildPath;
        return buildPath(savesDirectory(root), draft.folder);
    }

private:
    ref TextEditState activeEditor()
    {
        return editors[cast(size_t) field];
    }

    ref string activeValue()
    {
        final switch (field)
        {
            case WorldField.name: return draft.name;
            case WorldField.seed: return seedInput;
            case WorldField.none: return seedInput;
        }
    }

    string activeValueConst() const
    {
        final switch (field)
        {
            case WorldField.name: return draft.name;
            case WorldField.seed: return seedInput;
            case WorldField.none: return "";
        }
    }

    static bool validSeedInput(string value)
    {
        if (!value.length) return true;
        foreach (index, character; value)
            if (!(character >= '0' && character <= '9')
                && !(character == '-' && index == 0))
                return false;
        return true;
    }

    void updateSeed()
    {
        try draft.seed = seedInput.length && seedInput != "-"
            ? to!long(seedInput) : 0;
        catch (Exception) { draft.seed = 0; }
    }
}

unittest
{
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;

    const directory = buildPath(tempDir(), "minecraft-d-edition-world-text-test");
    scope (exit) if (exists(directory)) rmdirRecurse(directory);
    auto state = new WorldMenuState(directory);
    state.beginCreate();
    state.activate(WorldField.name);
    state.selectAll();
    state.insertCharacters("Test World");
    state.moveCursor(-1, true);
    assert(state.selectedText == "d");
    state.backspace();
    assert(state.draft.name == "Test Worl");
    state.activate(WorldField.seed);
    state.insertCharacters("-123");
    assert(state.seedInput == "-123" && state.draft.seed == -123);
}
