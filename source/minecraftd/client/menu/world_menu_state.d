module minecraftd.client.menu.world_menu_state;

import std.conv : to;
import std.file : getcwd;
import std.string : strip;
import std.utf : toUTF8;
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

    this(string root = getcwd())
    {
        this.root = root;
        refresh();
        resetDraft();
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
                    if (draft.name.length < 40) draft.name ~= character;
                    break;
                case WorldField.seed:
                    if ((character >= '0' && character <= '9'
                        || character == '-' && seedInput.length == 0)
                        && seedInput.length < 19)
                    {
                        seedInput ~= character;
                        try draft.seed = seedInput == "-" ? 0 : to!long(seedInput);
                        catch (Exception) {}
                    }
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
                if (draft.name.length) draft.name = draft.name[0 .. $-1];
                break;
            case WorldField.seed:
                if (seedInput.length) seedInput = seedInput[0 .. $-1];
                try draft.seed = seedInput.length && seedInput != "-"
                    ? to!long(seedInput) : 0;
                catch (Exception) { draft.seed = 0; }
                break;
            case WorldField.none: break;
        }
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
}
