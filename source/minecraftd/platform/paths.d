module minecraftd.platform.paths;

import std.file : exists, getcwd, mkdirRecurse, thisExePath;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : environment;

struct PlatformPaths
{
    string resources;
    string userData;
    string cache;
}

PlatformPaths platformPaths()
{
    version (OSX)
    {
        const executable = absolutePath(thisExePath());
        // Minecraft D Edition.app/Contents/MacOS/<executable>
        const contents = dirName(dirName(executable));
        const resources = buildNormalizedPath(contents, "Resources");
        const home = environment.get("HOME", "");
        if (home.length == 0)
            throw new Exception("macOS HOME directory is unavailable");
        const userData = buildPath(home, "Library", "Application Support",
            "Minecraft D Edition");
        const cache = buildPath(home, "Library", "Caches",
            "com.minecraftdedition.game");
        mkdirRecurse(userData);
        mkdirRecurse(cache);
        mkdirRecurse(buildPath(userData, "data"));
        mkdirRecurse(buildPath(userData, "saves"));
        return PlatformPaths(resources, userData, cache);
    }
    else
    {
        const root = getcwd();
        return PlatformPaths(root, root, buildPath(root, "data", "cache"));
    }
}

