module minecraftd.game.resources.resource_manager;

import std.file : exists, isFile, isSymlink, readText;
import std.path : buildPath;
import std.string : split;
import std.exception : enforce;
import std.algorithm : canFind;
import minecraftd.game.resources.resource_packs : PackMount, safeResourcePath;
import std.json : JSONValue,JSONType,parseJSON;

final class ResourceManager
{
    private string projectRoot;
    private PackMount[] packs;

    this(string projectRoot,PackMount[] packs=null)
    {
        this.projectRoot = projectRoot;
        this.packs=packs;
    }

    string resolveAsset(string namespaceName, string relativePath) const
    {
        enforce(safeResourcePath(namespaceName)&&!namespaceName.canFind('/')
            &&safeResourcePath(relativePath),"Invalid resource location");
        foreach(pack;packs)
        {
            if(auto file=(namespaceName~"/"~relativePath) in pack.files)return *file;
            if(pack.blocks(namespaceName,relativePath))
                throw new Exception("Resource filtered by "~pack.id~": "~relativePath);
        }
        const path = buildPath(projectRoot, "assets", namespaceName, relativePath);
        if (!exists(path))
            throw new Exception("Missing asset: " ~ path);
        return path;
    }

    string root() const { return projectRoot; }
    string findAsset(string namespaceName,string path) const
    { try{return resolveAsset(namespaceName,path);}catch(Exception){return "";} }

    JSONValue soundDefinitions(string namespaceName) const
    {
        string[] paths;
        bool filtered;
        foreach(pack;packs)
        {
            if(auto path=(namespaceName~"/sounds.json") in pack.files)paths~=*path;
            if(pack.blocks(namespaceName,"sounds.json")){filtered=true;break;}
        }
        const builtin=buildPath(projectRoot,"assets",namespaceName,"sounds.json");
        if(!filtered&&exists(builtin))paths~=builtin;
        JSONValue[string] empty;
        auto result=JSONValue(empty);
        foreach_reverse(path;paths)
        {
            auto data=parseJSON(readText(path));
            if(data.type!=JSONType.object)continue;
            foreach(name,value;data.object)
            {
                if(value.type!=JSONType.object)continue;
                bool replace;
                if(auto p="replace" in value.object)replace=p.type==JSONType.true_;
                if(!replace)if(auto previous=name in result.object)
                {
                    auto a="sounds" in previous.object,b="sounds" in value.object;
                    if(a !is null&&b !is null&&a.type==JSONType.array&&b.type==JSONType.array)
                        value.object["sounds"]=JSONValue(a.array~b.array);
                }
                result.object[name]=value;
            }
        }
        return result;
    }
}
