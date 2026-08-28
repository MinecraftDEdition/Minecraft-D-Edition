module minecraftd.world.world_settings;

import std.algorithm : sort;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse,
    read, readText, rmdirRecurse, write;
import std.path : baseName, buildPath;
import std.string : indexOf, replace, splitLines, strip;
import minecraftd.common.math3d : Vec3;

enum GameMode : ubyte
{
    survival,
    creative,
    adventure,
    spectator,
}

enum Difficulty : ubyte
{
    peaceful,
    easy,
    normal,
    hard,
}

enum WorldType : ubyte
{
    normal,
    flat,
}

enum DimensionId : ubyte
{
    overworld,
    nether,
}

string gameModeName(GameMode mode)
{
    final switch (mode)
    {
        case GameMode.survival: return "Survival";
        case GameMode.creative: return "Creative";
        case GameMode.adventure: return "Adventure";
        case GameMode.spectator: return "Spectator";
    }
}

string difficultyName(Difficulty difficulty)
{
    final switch (difficulty)
    {
        case Difficulty.peaceful: return "Peaceful";
        case Difficulty.easy: return "Easy";
        case Difficulty.normal: return "Normal";
        case Difficulty.hard: return "Hard";
    }
}

struct WorldSettings
{
    string name = "New World";
    string folder;
    long seed;
    GameMode gameMode = GameMode.survival;
    Difficulty difficulty = Difficulty.normal;
    WorldType worldType = WorldType.normal;
    bool hardcore;
    bool allowCommands;
    bool generateStructures = true;
    bool bonusChest;
    Vec3 spawn = Vec3(32.5f, 16.0f, 32.5f);

    GameMode effectiveGameMode() const
    {
        return hardcore ? GameMode.survival : gameMode;
    }
}

struct WorldEntry
{
    WorldSettings settings;
    string directory;
}

string savesDirectory(string root)
{
    return buildPath(root, "saves");
}

string safeFolderName(string value)
{
    char[] output;
    foreach (character; value)
    {
        const invalid = character == '<' || character == '>' || character == ':'
            || character == '"' || character == '/' || character == '\\'
            || character == '|' || character == '?' || character == '*'
            || character == '\r' || character == '\n' || character == '\t';
        output ~= invalid ? '_' : character;
    }
    auto result = strip(output.idup);
    return result.length ? result : "New World";
}

string uniqueWorldFolder(string root, string requested)
{
    const base = safeFolderName(requested);
    string candidate = base;
    int suffix = 1;
    while (exists(buildPath(savesDirectory(root), candidate)))
        candidate = base ~ " (" ~ to!string(++suffix) ~ ")";
    return candidate;
}

void saveWorldMetadata(string directory, const WorldSettings settings)
{
    mkdirRecurse(directory);
    string cleanName = settings.name;
    cleanName = cleanName.replace("\r", " ").replace("\n", " ");
    const contents = "name=" ~ cleanName ~ "\n"
        ~ "folder=" ~ settings.folder ~ "\n"
        ~ "seed=" ~ to!string(settings.seed) ~ "\n"
        ~ "gamemode=" ~ to!string(cast(ubyte) settings.gameMode) ~ "\n"
        ~ "difficulty=" ~ to!string(cast(ubyte) settings.difficulty) ~ "\n"
        ~ "worldtype=" ~ to!string(cast(ubyte) settings.worldType) ~ "\n"
        ~ "hardcore=" ~ (settings.hardcore ? "1" : "0") ~ "\n"
        ~ "commands=" ~ (settings.allowCommands ? "1" : "0") ~ "\n"
        ~ "structures=" ~ (settings.generateStructures ? "1" : "0") ~ "\n"
        ~ "bonus=" ~ (settings.bonusChest ? "1" : "0") ~ "\n"
        ~ "spawnx=" ~ to!string(settings.spawn.x) ~ "\n"
        ~ "spawny=" ~ to!string(settings.spawn.y) ~ "\n"
        ~ "spawnz=" ~ to!string(settings.spawn.z) ~ "\n";
    write(buildPath(directory, "level.dat"), contents);
}

WorldSettings loadWorldMetadata(string directory)
{
    WorldSettings settings;
    settings.folder = baseName(directory);
    settings.name = settings.folder;
    const path = buildPath(directory, "level.dat");
    if (!exists(path))
        return settings;
    foreach (line; splitLines(readText(path)))
    {
        const separator = indexOf(line, '=');
        if (separator < 0) continue;
        const key = line[0 .. separator];
        const value = line[separator + 1 .. $];
        try
        {
            switch (key)
            {
                case "name": settings.name = value; break;
                case "folder": settings.folder = value; break;
                case "seed": settings.seed = to!long(value); break;
                case "gamemode": settings.gameMode = cast(GameMode) to!ubyte(value); break;
                case "difficulty": settings.difficulty = cast(Difficulty) to!ubyte(value); break;
                case "worldtype": settings.worldType = cast(WorldType) to!ubyte(value); break;
                case "hardcore": settings.hardcore = value == "1"; break;
                case "commands": settings.allowCommands = value == "1"; break;
                case "structures": settings.generateStructures = value != "0"; break;
                case "bonus": settings.bonusChest = value == "1"; break;
                case "spawnx": settings.spawn.x = to!float(value); break;
                case "spawny": settings.spawn.y = to!float(value); break;
                case "spawnz": settings.spawn.z = to!float(value); break;
                default: break;
            }
        }
        catch (Exception) {}
    }
    if (settings.hardcore)
    {
        settings.gameMode = GameMode.survival;
        settings.difficulty = Difficulty.hard;
    }
    return settings;
}

WorldEntry[] listWorlds(string root)
{
    const saves = savesDirectory(root);
    if (!exists(saves))
        return [];
    WorldEntry[] result;
    foreach (entry; dirEntries(saves, SpanMode.shallow))
    {
        if (!entry.isDir || !exists(buildPath(entry.name, "level.dat")))
            continue;
        result ~= WorldEntry(loadWorldMetadata(entry.name), entry.name);
    }
    sort!((a, b) => a.settings.name < b.settings.name)(result);
    return result;
}

void deleteWorld(const WorldEntry entry)
{
    if (entry.directory.length && exists(entry.directory) && isDir(entry.directory))
        rmdirRecurse(entry.directory);
}
