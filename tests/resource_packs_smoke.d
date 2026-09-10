module resource_packs_smoke;
import std.file;
import std.path;
import std.uuid : randomUUID;
import std.zip;
import std.stdio : writeln;
import minecraftd.game.resources.resource_packs;
import minecraftd.game.resources.resource_manager;

void main()
{
    const root=buildPath(tempDir(),"mcde-packs-"~randomUUID().toString());
    mkdirRecurse(buildPath(root,"assets","minecraft","textures","block"));
    scope(exit)rmdirRecurse(root);
    const builtin=buildPath(root,"assets","minecraft","textures","block","stone.png");
    write(builtin,"default");
    write(builtin~".mcmeta",`{"animation":{"frametime":2}}`);
    auto repository=new ResourcePackRepository(root);
    void zipPack(string name,string[string] files)
    {
        auto zip=new ZipArchive();
        foreach(path,data;files)
        {
            auto entry=new ArchiveMember();entry.name=path;
            entry.expandedData=cast(ubyte[])data.dup;
            entry.compressionMethod=CompressionMethod.deflate;zip.addMember(entry);
        }
        write(buildPath(repository.folder,name),zip.build());
    }
    enum meta=`{"pack":{"pack_format":75,"description":{"text":"A pack","extra":[{"text":" with text"}]}}}`;
    zipPack("lower.zip",["pack.mcmeta":meta,"assets/minecraft/textures/block/stone.png":"lower",
        "assets/future/textures/entity/new.png":"future entity"]);
    zipPack("upper.zip",["pack.mcmeta":meta,"assets/minecraft/textures/block/stone.png":"upper"]);
    zipPack("bad.zip",["pack.mcmeta":meta,"../escaped.txt":"unsafe"]);
    zipPack("wrapped.zip",["nested/pack.mcmeta":meta]);
    repository.refresh();
    assert(repository.packs[repository.indexOf("wrapped.zip")].error.length);
    assert(repository.packs[repository.indexOf("lower.zip")].description=="A pack with text");
    repository.toggle("lower.zip");repository.toggle("upper.zip");
    repository.applied=repository.selected.dup;
    auto resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="upper");
    assert(resources.findAssetMetadata("minecraft","textures/block/stone.png")=="");
    assert(readText(resources.resolveAsset("future","textures/entity/new.png"))=="future entity");
    repository.move("upper.zip",1);repository.applied=repository.selected.dup;
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="lower");
    repository.save();
    auto restored=new ResourcePackRepository(root);
    assert(restored.applied==repository.applied);
    repository.applied=["bad.zip"];
    bool rejected;
    try{repository.mounts(true);}catch(Exception){rejected=true;}
    assert(rejected&&!exists(buildPath(root,"escaped.txt")));
    assert(readText(builtin)=="default");
    repository.applied=[];
    resources=new ResourceManager(root,repository.mounts());
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="default");
    assert(readText(resources.findAssetMetadata("minecraft","textures/block/stone.png"))
        ==readText(builtin~".mcmeta"));
    zipPack("metadata.zip",["pack.mcmeta":meta,
        "assets/minecraft/textures/block/stone.png.mcmeta":"higher metadata"]);
    repository.refresh();repository.applied=["metadata.zip","upper.zip"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.findAssetMetadata("minecraft","textures/block/stone.png"))=="higher metadata");
    foreach(path;["../secret","a/../../secret","a\\b","C:/escape","/absolute","a//b"])
        assert(!safeResourcePath(path));
    enum overlayMeta=`{"pack":{"min_format":75,"max_format":75,"description":"Overlay"},"overlays":{"entries":[{"directory":"new","min_format":75,"max_format":75}]}}`;
    zipPack("overlay.zip",["pack.mcmeta":overlayMeta,"assets/minecraft/textures/block/stone.png":"base",
        "new/assets/minecraft/textures/block/stone.png":"overlay"]);
    repository.refresh();repository.applied=["overlay.zip"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="overlay");
    const loose=buildPath(repository.folder,"Loose");
    mkdirRecurse(buildPath(loose,"assets","minecraft","textures","block"));
    write(buildPath(loose,"pack.mcmeta"),meta);
    write(buildPath(loose,"assets","minecraft","textures","block","STONE.png"),"wrong case");
    repository.refresh();repository.applied=["Loose"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="default");
    write(buildPath(loose,"assets","minecraft","sounds.json"),`{"music.game":{"replace":true,"sounds":["custom"]}}`);
    write(buildPath(root,"assets","minecraft","sounds.json"),`{"music.game":{"sounds":["default"]},"music.menu":{"sounds":["menu"]}}`);
    resources=new ResourceManager(root,repository.mounts(true));
    const sounds=resources.soundDefinitions("minecraft");
    assert(sounds.object["music.game"].object["sounds"].array.length==1);
    assert(sounds.object["music.game"].object["sounds"].array[0].str=="custom");
    assert("music.menu" in sounds.object);
    zipPack("minor.zip",["pack.mcmeta":`{"pack":{"min_format":[75,1],"max_format":[75,2],"description":"Newer minor version"}}`]);
    repository.refresh();assert(repository.packs[repository.indexOf("minor.zip")].warning.length);
    zipPack("filter.zip",["pack.mcmeta":`{"pack":{"pack_format":75,"description":"Filter"},"filter":{"block":[{"namespace":"minecraft","path":"textures/block/stone\\.png"}]}}`]);
    repository.refresh();repository.applied=["filter.zip","lower.zip"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(resources.findAsset("minecraft","textures/block/stone.png")=="");
    zipPack("legacy.zip",["pack.mcmeta":meta,
        "assets/minecraft/textures/blocks/stone.png":"legacy stone",
        "assets/minecraft/textures/blocks/grass_top.png":"legacy grass",
        "assets/minecraft/textures/items/wood_sword.png":"legacy sword",
        "assets/minecraft/textures/blocks/water_still.png":"legacy water",
        "assets/minecraft/textures/blocks/water_still.png.mcmeta":"animation",
        "assets/minecraft/textures/gui/title/minecraft.png":"legacy logo"]);
    repository.refresh();repository.applied=["legacy.zip","upper.zip"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="legacy stone");
    assert(readText(resources.resolveAsset("minecraft","textures/block/grass_block_top.png"))=="legacy grass");
    assert(readText(resources.resolveAsset("minecraft","textures/item/wooden_sword.png"))=="legacy sword");
    assert(readText(resources.findAssetMetadata("minecraft","textures/block/water_still.png"))=="animation");
    assert(readText(resources.resolveAsset("minecraft_d","textures/gui/title/minecraft.png"))=="legacy logo");
    zipPack("exact.zip",["pack.mcmeta":meta,
        "assets/minecraft/textures/block/stone.png":"exact stone",
        "assets/minecraft/textures/blocks/stone.png":"old stone",
        "assets/minecraft/textures/gui/title/minecraft.png":"Java logo",
        "assets/minecraft_d/textures/gui/title/minecraft.png":"D logo"]);
    repository.refresh();repository.applied=["exact.zip"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft","textures/block/stone.png"))=="exact stone");
    assert(readText(resources.resolveAsset("minecraft_d","textures/gui/title/minecraft.png"))=="D logo");
    repository.applied=["legacy.zip","exact.zip"];
    resources=new ResourceManager(root,repository.mounts(true));
    assert(readText(resources.resolveAsset("minecraft_d","textures/gui/title/minecraft.png"))=="legacy logo");
    writeln("ZIP discovery, ordering, overlays, aliases, future namespaces, defaults, persistence, and unsafe-path checks passed");
}
