module minecraftd.game.resources.resource_packs;

import std.algorithm : canFind, sort;
import std.array : array;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.exception : enforce;
import std.file : exists, isDir, isFile, isSymlink, dirEntries, SpanMode,
    read, readText, write, mkdirRecurse, getSize;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, baseName, dirName;
import std.regex : regex, matchFirst;
import std.string : split, startsWith, endsWith, toLower, replace;
import std.zip : ZipArchive;

// Java compatibility profile for versioned overlays (1.21.11), independent
// of D Edition's release number. Advance with future resource-schema imports.
enum int javaResourceFormat = 75;
enum ulong maximumArchiveBytes = 512UL * 1024 * 1024;
enum ulong maximumExpandedBytes = 1024UL * 1024 * 1024;
enum ulong maximumEntryBytes = 64UL * 1024 * 1024;

bool safeResourcePath(string value)
{
    if(!value.length || value.canFind('\\') || value.canFind(':') || value.canFind('\0'))return false;
    foreach(part;value.split('/'))
        if(!part.length || part=="." || part==".." || part.endsWith(".") || part.endsWith(" "))return false;
    return true;
}

struct ResourceFilter { string namespacePattern=".*", pathPattern=".*"; }
struct PackMount
{
    string id;
    string[] roots; // highest-priority matching overlay first, then base
    string[string] files; // case-sensitive resource locations on every OS
    ResourceFilter[] filters;
    bool blocks(string space,string path) const
    {
        foreach(filter;filters)
            if(!matchFirst(space,regex("^(?:"~filter.namespacePattern~")$")).empty
                && !matchFirst(path,regex("^(?:"~filter.pathPattern~")$")).empty)return true;
        return false;
    }
}

struct ResourcePack
{
    string id,source,root,description,icon,warning,error;
    string[] overlays;
    ResourceFilter[] filters;
    bool archive;
}

private JSONValue member(JSONValue value,string key)
{
    if(value.type==JSONType.object)
        if(auto found=key in value.object)return *found;
    return JSONValue.init;
}

private int major(JSONValue value,int fallback)
{
    if(value.type==JSONType.integer)return cast(int)value.integer;
    if(value.type==JSONType.array&&value.array.length)return major(value.array[0],fallback);
    return fallback;
}

private bool matchesFormat(JSONValue data,string legacy)
{
    const minimum=member(data,"min_format"),maximum=member(data,"max_format");
    if(minimum.type!=JSONType.null_)
    {
        ulong bound(JSONValue value,bool upper)
        {
            const m=major(value,upper?int.max:0);
            uint minor=upper?int.max:0;
            if(value.type==JSONType.array&&value.array.length>1)
                minor=cast(uint)value.array[1].integer;
            return (cast(ulong)m<<32)|minor;
        }
        const target=cast(ulong)javaResourceFormat<<32;
        return bound(minimum,false)<=target&&bound(maximum,true)>=target;
    }
    const range=member(data,legacy);
    if(range.type==JSONType.array&&range.array.length==2)
        return major(range.array[0],0)<=javaResourceFormat&&major(range.array[1],int.max)>=javaResourceFormat;
    if(range.type==JSONType.object)
        return major(member(range,"min_inclusive"),0)<=javaResourceFormat
            && major(member(range,"max_inclusive"),int.max)>=javaResourceFormat;
    return major(range,javaResourceFormat)==javaResourceFormat;
}

private string descriptionText(JSONValue value)
{
    if(value.type==JSONType.string)return value.str;
    string result;
    if(value.type==JSONType.array)foreach(part;value.array)result~=descriptionText(part);
    if(value.type==JSONType.object)
    {
        result=descriptionText(member(value,"text"));
        result~=descriptionText(member(value,"extra"));
    }
    // The current bitmap UI has no styled text-component renderer.
    return result;
}

private void metadata(ref ResourcePack pack,string text)
{
    const document=parseJSON(text),details=member(document,"pack");
    enforce(details.type==JSONType.object,"pack.mcmeta is missing its pack object");
    enforce(member(details,"pack_format").type!=JSONType.null_
        ||member(details,"min_format").type!=JSONType.null_,"pack.mcmeta has no resource format");
    pack.description=descriptionText(member(details,"description"));
    if(pack.description.length>2048)pack.description=pack.description[0..2048];
    if(!matchesFormat(details,member(details,"supported_formats").type==JSONType.null_
        ?"pack_format":"supported_formats"))pack.warning="Made for a different Java version";
    const overlays=member(member(document,"overlays"),"entries");
    if(overlays.type==JSONType.array)foreach(overlay;overlays.array)
    {
        const directory=member(overlay,"directory");
        enforce(directory.type==JSONType.string&&safeResourcePath(directory.str),"Invalid overlay directory");
        if(matchesFormat(overlay,"formats"))pack.overlays=directory.str~pack.overlays;
    }
    const filters=member(member(document,"filter"),"block");
    if(filters.type==JSONType.array)foreach(entry;filters.array)
    {
        ResourceFilter filter;
        const space=member(entry,"namespace"),path=member(entry,"path");
        if(space.type==JSONType.string)filter.namespacePattern=space.str;
        if(path.type==JSONType.string)filter.pathPattern=path.str;
        regex(filter.namespacePattern);regex(filter.pathPattern);
        pack.filters~=filter;
    }
}

/// Java ZIP/folder discovery and saved ordering. Packs remain outside the
/// installation's assets; the default resources are never overwritten.
final class ResourcePackRepository
{
    string folder,cache,selectionFile;
    ResourcePack[] packs;
    string[] selected,applied;
    string notice;
    bool reloadRequested;
    bool changedOnDisk;
    uint revision;

    this(string userRoot)
    {
        folder=buildPath(userRoot,"resourcepacks");
        cache=buildPath(userRoot,"data","cache","resourcepacks");
        selectionFile=buildPath(userRoot,"data","resource-packs.json");
        mkdirRecurse(folder);mkdirRecurse(cache);
        if(exists(selectionFile))try
        {
            const json=parseJSON(readText(selectionFile));
            foreach(entry;json.array)if(entry.type==JSONType.string)applied~=entry.str;
        }catch(Exception){notice="Saved pack selection could not be read.";}
        selected=applied.dup;
        refresh();
    }

    int indexOf(string id) const
    {
        foreach(i,pack;packs)if(pack.id==id)return cast(int)i;
        return -1;
    }

    void refresh()
    {
        string[string] previousRoots;
        foreach(pack;packs)previousRoots[pack.id]=pack.root;
        packs.length=0;
        foreach(entry;dirEntries(folder,SpanMode.shallow))
        {
            if(packs.length>=256){notice="Only the first 256 packs are listed.";break;}
            if(entry.isSymlink)continue;
            const zipped=entry.isFile&&toLower(entry.name).endsWith(".zip");
            if(!zipped&&!(entry.isDir&&exists(buildPath(entry.name,"pack.mcmeta"))))continue;
            ResourcePack pack;
            pack.id=baseName(entry.name);pack.source=entry.name;pack.archive=zipped;
            try
            {
                if(zipped)
                {
                    enforce(entry.size<=maximumArchiveBytes,"ZIP exceeds the 512 MiB compressed limit");
                    auto data=cast(ubyte[])read(entry.name);
                    auto zip=new ZipArchive(data);
                    enforce(zip.totalEntries<=65535,"ZIP has too many entries");
                    auto info="pack.mcmeta" in zip.directory;
                    enforce(info !is null,"ZIP must contain pack.mcmeta at its root");
                    enforce((*info).expandedSize<=1024*1024,"pack.mcmeta is too large");
                    metadata(pack,cast(string)zip.expand(*info));
                    pack.root=buildPath(cache,toHexString(sha256Of(data)));
                    mkdirRecurse(pack.root);
                    if(auto icon="pack.png" in zip.directory)try
                    {
                        enforce((*icon).expandedSize<=maximumEntryBytes,"Pack icon is too large");
                        pack.icon=buildPath(pack.root,"pack.png");
                        write(pack.icon,zip.expand(*icon));
                    }
                    catch(Exception){pack.icon="";}
                }
                else
                {
                    pack.root=entry.name;
                    enforce(!isSymlink(buildPath(pack.root,"pack.mcmeta")),"Pack metadata cannot be a symbolic link");
                    enforce(getSize(buildPath(pack.root,"pack.mcmeta"))<=1024*1024,"pack.mcmeta is too large");
                    metadata(pack,readText(buildPath(pack.root,"pack.mcmeta")));
                    const icon=buildPath(pack.root,"pack.png");
                    if(exists(icon)&&!isSymlink(icon))pack.icon=icon;
                }
            }
            catch(Exception error){pack.error=error.msg;}
            if(applied.canFind(pack.id))
            {
                if(auto previous=pack.id in previousRoots)
                    if(*previous!=pack.root||!pack.archive)changedOnDisk=true;
            }
            packs~=pack;
        }
        packs.sort!((a,b)=>a.id<b.id);
        string[] present;
        foreach(id;selected)if(indexOf(id)>=0)present~=id;
        selected=present;
        ++revision;
    }

    void toggle(string id)
    {
        if(selected.canFind(id))
        {
            string[] next;foreach(entry;selected)if(entry!=id)next~=entry;selected=next;
        }
        else if(indexOf(id)>=0&&!packs[indexOf(id)].error.length)selected=id~selected;
    }

    void move(string id,int direction)
    {
        foreach(i,entry;selected)if(entry==id)
        {
            const target=cast(int)i+direction;
            if(target>=0&&target<selected.length)
            { const other=selected[target];selected[target]=selected[i];selected[i]=other; }
            break;
        }
    }

    PackMount[] mounts(bool strict=false)
    {
        PackMount[] result;
        foreach(id;applied)
        {
            const i=indexOf(id);
            if(i<0){notice="Missing resource pack: "~id;enforce(!strict,notice);continue;}
            const pack=packs[i];
            if(pack.error.length)
            { notice=id~": "~pack.error;enforce(!strict,notice);continue; }
            if(pack.archive)try { extract(pack); }
            catch(Exception failure)
            { notice=id~": "~failure.msg;enforce(!strict,notice);continue; }
            PackMount mount;mount.id=id;mount.filters=pack.filters.dup;
            foreach(overlay;pack.overlays)mount.roots~=buildPath(pack.root,overlay);
            mount.roots~=pack.root;
            try { indexFiles(mount); }
            catch(Exception failure)
            { notice=id~": "~failure.msg;enforce(!strict,notice);continue; }
            result~=mount;
        }
        return result;
    }

    void save()
    {
        mkdirRecurse(dirName(selectionFile));
        write(selectionFile,JSONValue(applied).toString());
    }

    private void extract(const ResourcePack pack)
    {
        const complete=buildPath(pack.root,".complete");
        if(exists(complete))return;
        enforce(getSize(pack.source)<=maximumArchiveBytes,"ZIP exceeds the compressed size limit");
        auto data=cast(ubyte[])read(pack.source);
        enforce(buildPath(cache,toHexString(sha256Of(data)))==pack.root,
            "Pack changed while being loaded; reopen the pack menu");
        auto zip=new ZipArchive(data);
        ulong total;
        foreach(name,entry;zip.directory)
        {
            if(name.endsWith("/"))continue;
            enforce(safeResourcePath(name)&&name!=".complete","Unsafe path in resource pack: "~name);
            enforce(entry.expandedSize<=maximumEntryBytes,"Resource exceeds the 64 MiB file limit");
            total+=entry.expandedSize;
            enforce(total<=maximumExpandedBytes,"Pack exceeds the 1 GiB expanded limit");
        }
        foreach(name,entry;zip.directory)
        {
            if(name.endsWith("/"))continue;
            const destination=buildPath(pack.root,name);
            mkdirRecurse(dirName(destination));
            enforce(!exists(destination)||!isSymlink(destination),"Resource cache contains a symbolic link");
            auto bytes=zip.expand(entry);
            write(destination,bytes);
            // std.zip otherwise retains every expanded member for this pass.
            entry.expandedData=null;
        }
        write(complete,"1");
    }

    private void indexFiles(ref PackMount mount)
    {
        foreach(root;mount.roots)
        {
            const assets=buildPath(root,"assets");
            if(!exists(assets))continue;
            enforce(!isSymlink(root)&&!isSymlink(assets),"Resource roots cannot be symbolic links");
            string[] pending=[assets];
            while(pending.length)
            {
                const directory=pending[$-1];pending.length--;
                foreach(entry;dirEntries(directory,SpanMode.shallow))
                {
                    enforce(!entry.isSymlink,"Resource packs cannot contain symbolic links");
                    if(entry.isDir){pending~=entry.name;continue;}
                    if(!entry.isFile)continue;
                    const key=entry.name[assets.length+1..$].replace("\\","/");
                    enforce(safeResourcePath(key),"Invalid resource path: "~key);
                    enforce(entry.size<=maximumEntryBytes,"Resource exceeds the 64 MiB file limit");
                    enforce(mount.files.length<65535,"Resource pack has too many assets");
                    if(key !in mount.files)mount.files[key]=entry.name;
                }
            }
        }
    }
}
