module minecraftd.game.resources.resource_manager;

import std.file : exists;
import std.path : buildPath;

final class ResourceManager
{
    private string projectRoot;

    this(string projectRoot)
    {
        this.projectRoot = projectRoot;
    }

    string resolveAsset(string namespaceName, string relativePath) const
    {
        const path = buildPath(projectRoot, "assets", namespaceName, relativePath);
        if (!exists(path))
            throw new Exception("Missing asset: " ~ path);
        return path;
    }

    string root() const { return projectRoot; }
}
