module minecraftd.platform.update;

version (OSX)
{
    private extern(C) nothrow void mcdUpdaterStart();

    void startUpdater()
    {
        mcdUpdaterStart();
    }
}
else
{
    version (Windows)
    {
        import core.thread : Thread;
        import core.time : msecs;
        import std.file : copy, exists, getSize, PreserveAttributes,
            read, remove, rename, thisExePath;
        import std.path : buildPath, dirName;

        private bool sameFile(string left,string right)
        {
            return exists(left)&&exists(right)&&getSize(left)==getSize(right)
                &&read(left)==read(right);
        }

        /// Promotes the verified launcher sidecar after the launcher has handed
        /// control to the game. Older launchers can therefore receive the new
        /// updater without ever trying to overwrite their running executable.
        package bool promoteLauncherUpdateAt(string root)
        {
            const source=buildPath(root,
                "Minecraft D Edition Launcher.update.exe");
            const destination=buildPath(root,
                "Minecraft D Edition Launcher.exe");
            if(!exists(source)||sameFile(source,destination))return true;
            const temporary=destination~".mde-new";
            try
            {
                copy(source,temporary,PreserveAttributes.yes);
                foreach(attempt;0..30)
                {
                    try
                    {
                        rename(temporary,destination);
                        return true;
                    }
                    catch(Exception)
                    {
                        if(attempt+1<30)Thread.sleep(50.msecs);
                    }
                }
            }
            catch(Exception){}
            try{if(exists(temporary))remove(temporary);}catch(Exception){}
            return false;
        }
    }

    void startUpdater()
    {
        version (Windows)
        {
            // The executable directory is stable even if a user launches the
            // game directly with a different working directory.
            promoteLauncherUpdateAt(dirName(thisExePath()));
        }
    }
}

version (Windows) unittest
{
    import std.file : mkdirRecurse,rmdirRecurse,tempDir,write,readText;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    const root=buildPath(tempDir(),"mde-launcher-promote-"
        ~randomUUID().toString());
    mkdirRecurse(root);
    scope(exit)rmdirRecurse(root);
    write(buildPath(root,"Minecraft D Edition Launcher.exe"),"old");
    write(buildPath(root,"Minecraft D Edition Launcher.update.exe"),"new");
    assert(promoteLauncherUpdateAt(root));
    assert(readText(buildPath(root,"Minecraft D Edition Launcher.exe"))=="new");
}
