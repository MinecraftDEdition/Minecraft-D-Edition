module minecraftd.world.atomic_file;

import std.file : write, rename, mkdirRecurse;
import std.path : dirName;
import std.exception : enforce;

// Replace complete files rather than truncating the last good save in place.
// A process crash during the write leaves the previous committed file intact.
void atomicWrite(string path, const(void)[] bytes)
{
    mkdirRecurse(dirName(path));
    const temporary=path~".tmp";
    write(temporary,bytes);
    version(Windows)
    {
        import core.sys.windows.windows : MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH;
        import std.utf : toUTF16z;
        enforce(MoveFileExW(temporary.toUTF16z,path.toUTF16z,
            MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0,"Could not commit save: "~path);
    }
    else rename(temporary,path);
}
