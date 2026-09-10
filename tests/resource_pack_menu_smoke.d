module resource_pack_menu_smoke;
version(Windows)
{
    import core.sys.windows.windows;
    import core.sys.windows.com : CoInitializeEx,CoUninitialize,COINIT_MULTITHREADED;
}
version(OSX) import minecraftd.platform.macos.window : GameWindow;
import minecraftd.client.render.graphics_device : GraphicsApi;
import std.file;
import std.path;
import std.uuid : randomUUID;
import std.zip;
import std.format : format;
import std.stdio : writeln;
import minecraftd.client.menu.options_menu;
import minecraftd.client.render.game_renderer;
import minecraftd.world.world;

void main(string[] args)
{
    version(Windows)
    {
        assert(CoInitializeEx(null,COINIT_MULTITHREADED)>=0);
    }
    scope(exit) { version(Windows) CoUninitialize(); }
    const root=buildPath(tempDir(),"mcde-pack-menu-"~randomUUID().toString());
    mkdirRecurse(root);
    scope(exit)
    {
        version(Windows)rmdirRecurse("\\\\?\\"~root);
        else rmdirRecurse(root);
    }
    auto options=new OptionsMenuState(root);
    foreach(name;["Warm Stone.zip","Classic Grass.zip"])
    {
        auto zip=new ZipArchive();
        void add(string path,const(void)[] bytes)
        {
            auto member=new ArchiveMember();member.name=path;
            member.expandedData=cast(ubyte[])bytes.dup;zip.addMember(member);
        }
        add("pack.mcmeta",`{"pack":{"pack_format":75,"description":"A familiar look, with custom textures"}}`);
        add("pack.png",read("assets/minecraft/textures/block/grass_block_side.png"));
        add("assets/minecraft/textures/block/stone.png",read("assets/minecraft/textures/block/dirt.png"));
        write(buildPath(options.resourcePacks.folder,name),zip.build());
    }
    options.open(false);options.activate(OptionsAction.resourcePacksMenu);
    options.resourcePacks.toggle("Warm Stone.zip");
    if(args.length>1)
    {
        copy(args[1],buildPath(options.resourcePacks.folder,"Compatibility.zip"));
        options.resourcePacks.refresh();
        options.resourcePacks.selected=["Compatibility.zip"];
    }
    options.resourcePacks.applied=options.resourcePacks.selected.dup;
    options.resourcePacks.mounts(true);
    auto world=new World();scope(exit)destroy(world);
    version(Windows)
    {
    auto window=CreateWindowExW(0,"STATIC"w.ptr,"Resource pack menu test"w.ptr,
        WS_OVERLAPPEDWINDOW,0,0,960,540,null,null,GetModuleHandleW(null),null);
    enum api=GraphicsApi.directX12;
    }
    else version(OSX)
    {
        auto nativeWindow=new GameWindow("Resource pack menu test",960,540);
        auto window=nativeWindow.handle;
        enum api=GraphicsApi.vulkan;
    }
    assert(window !is null);
    scope(exit)
    {
        version(Windows) DestroyWindow(window);
        else version(OSX) destroy(nativeWindow);
    }
    auto renderer=new GameRenderer(window,960,540,getcwd(),world,options,api);
    scope(exit)destroy(renderer);
    renderer.preparePackIcons();
    renderer.renderOptionsScreen(-1,-1,0);
    if(args.length>1)renderer.renderTitleScreen(-1,-1,0);
    version(Windows)
    {
    auto image=renderer.captureTestFrame();
    ubyte[] rgb;
    foreach(i;0..image.width*image.height)rgb~=image.rgba[i*4..i*4+3];
    mkdirRecurse("test-output/resourcepacks");
    write("test-output/resourcepacks/menu.ppm",
        format("P6\n%s %s\n255\n",image.width,image.height)~cast(string)rgb);
    }
    writeln("Resource pack selected and options menu rendered on ",api);
    destroy(renderer);renderer=null;
    const badRoot=buildPath(options.resourcePacks.folder,"Broken Texture");
    mkdirRecurse(buildPath(badRoot,"assets","minecraft","textures","block"));
    write(buildPath(badRoot,"pack.mcmeta"),`{"pack":{"pack_format":75,"description":"Invalid PNG test"}}`);
    write(buildPath(badRoot,"assets","minecraft","textures","block","stone.png"),"not a PNG");
    options.resourcePacks.refresh();options.resourcePacks.applied=["Broken Texture"];
    bool rejected;
    try{renderer=new GameRenderer(window,960,540,getcwd(),world,options,api);}catch(Exception){rejected=true;}
    assert(rejected&&renderer is null);
    options.resourcePacks.applied=[];
    renderer=new GameRenderer(window,960,540,getcwd(),world,options,api);
    renderer.renderOptionsScreen(-1,-1,0);
    writeln("Invalid-pack GPU cleanup and Default reload passed");
}
