module minecraftd.client.render.game_renderer;

import core.stdc.math : fabsf, floorf, sinf, sqrtf, tanf;
import std.algorithm : sort;
import std.format : format;
version (Windows)
    import core.sys.windows.windows : HWND;

import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.client.chat.chat_state : ChatState;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.particle.particle_system : ParticleSystem, ParticleTextureSet;
import minecraftd.client.audio.sound_manager : SoundManager;
import minecraftd.client.render.block_renderer : BlockRenderer, BlockTextureSet,
    WaterGeometry;
import minecraftd.client.render.camera : Camera;
import minecraftd.client.render.chat_renderer : ChatRenderer;
import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.render.entity_shadow_renderer : EntityShadowRenderer,
    EntityShadowStyle;
import minecraftd.client.render.hud_renderer : HudRenderer, HudTextureSet;
import minecraftd.client.render.mesh : Color, DrawLayer, FogSettings,
    FrameMesh, MeshHandle, Vertex, appendQuad;
import minecraftd.common.math3d : Mat4, Vec2, Vec3, clamp, cross,
    forwardFromYawPitch, lerp;
import minecraftd.client.render.player_renderer : PlayerRenderer, SkinLayers;
import minecraftd.client.render.sky_renderer : SkyRenderer;
import minecraftd.client.render.texture_manager : ImageData, TextureManager;
import minecraftd.client.render.graphics_device : GraphicsApi, GraphicsDevice,
    TextureHandle;
import minecraftd.client.render.title_screen_renderer : TitleAction,
    AccountMenuAction, MultiplayerMenuAction, TitleScreenRenderer, TitleTextureSet,
    WorldMenuAction;
import minecraftd.client.account.account_service : AccountSnapshot;
import minecraftd.client.menu.account_menu_state : AccountMenuState;
import minecraftd.client.menu.multiplayer_menu_state : MultiplayerField,
    MultiplayerMenuState;
import minecraftd.client.menu.world_menu_state : WorldField, WorldMenuState;
import minecraftd.client.menu.pause_menu : PauseAction, PauseMenuRenderer,
    PauseMenuState, PauseTextureSet;
import minecraftd.client.menu.death_screen : DeathAction, DeathScreenRenderer,
    DeathScreenState, DeathTextureSet;
import minecraftd.client.menu.options_menu : OptionsAction, OptionsMenuRenderer,
    OptionsMenuState, OptionsTextureSet;
import minecraftd.client.menu.inventory_menu:InventoryMenuRenderer,
    InventoryMenuState,InventoryTextureSet;
import minecraftd.game.resources.resource_manager : ResourceManager;
import minecraftd.game.item.inventory : ItemId, ItemStack, placedBlock,
    sameHeldStack;
import minecraftd.game.entity.player : Player;
version (Windows)
    import minecraftd.platform.windows.dx12.device : Dx12Device;
import minecraftd.platform.desktop.vulkan.device : VulkanDevice;
import minecraftd.platform.clock : monotonicSeconds;
import minecraftd.world.block : BlockId, bareHandDestroyProgress,
    isNetherPortal, isWater, isWaterSource;
import minecraftd.world.world : BlockHit, World;
import minecraftd.world.chunk : ChunkCoordinate, chunkCoordinate;
import minecraftd.world.world_settings : GameMode;
import minecraftd.world.world_settings : DimensionId;

enum CameraPerspective : ubyte
{
    firstPerson,
    thirdPersonBack,
    thirdPersonFront,
}

private struct ResidentRange
{
    uint firstVertex;
    uint vertexCount;
    uint textureIndex;
}

private struct RenderChunkSection
{
    Vertex[][uint] blocks;
    Vertex[] portals;
    WaterGeometry water;
    ResidentRange[] opaqueRanges;
    ResidentRange glassRange;
    ResidentRange portalRange;
    ResidentRange waterUndersideRange;
    ResidentRange waterSurfaceRange;
    ResidentRange waterWallsRange;
    int minimumY;
    int maximumY;
}

private struct RenderChunkGeometry
{
    RenderChunkSection[] sections;
    MeshHandle mesh;
    uint vertexCount;
    uint revision;
    int minimumY;
    int maximumY;
}

/// Coordinates the same broad passes as Minecraft's client renderer: sky,
/// opaque world geometry, entities, and a camera-space first-person hand.
final class GameRenderer
{
    private uint width;
    private uint height;
    private GraphicsDevice graphics;
    private TextureManager images;
    private ResourceManager resources;
    private BlockRenderer blocks;
    private PlayerRenderer players;
    private EntityShadowRenderer entityShadows;
    private SkyRenderer sky;
    private HudRenderer hud;
    private ParticleSystem particles;
    private SoundManager sounds;
    private ChatRenderer chatRenderer;
    private FontRenderer hudFont;
    private uint fontTexture;
    private uint whiteTexture;
    private TitleScreenRenderer titleScreen;
    private TitleTextureSet titleTextures;
    private PauseMenuRenderer pauseMenu;
    private PauseTextureSet pauseTextures;
    private DeathScreenRenderer deathScreen;
    private DeathTextureSet deathTextures;
    private OptionsMenuRenderer optionsMenu;
    private OptionsTextureSet optionsTextures;
    private InventoryMenuRenderer inventoryMenu;
    private InventoryTextureSet inventoryTextures;
    private OptionsMenuState options;
    private World world;
    private FrameMesh frame;
    private RenderChunkGeometry[ChunkCoordinate] chunkMeshes;
    private ChunkCoordinate[] admittedRenderChunks;
    private bool meshJobActive;
    private ChunkCoordinate meshJobCoordinate;
    private int meshJobNextY;
    private int meshJobMaximumY;
    private uint meshJobRevision;
    private RenderChunkGeometry meshJobGeometry;
    private uint[] portalFrames;
    private uint[] waterStillFrames;
    private uint[] waterFlowFrames;
    private Vertex[][uint][ItemId] itemMeshes;
    private BlockTextureSet blockTextures;
    private bool meshSmoothLighting=true;
    private float meshGamma=0.5f;

    private TextureHandle steve;
    private TextureHandle accountSkin;
    private string accountSkinPath;
    private string accountSkinModel = "classic";
    private long accountSkinRevision = long.min;
    private TextureHandle[string] remoteSkins;
    private string[string] remoteSkinVersions;
    private TextureHandle sun;
    private TextureHandle clouds;
    private TextureHandle crosshair;
    private TextureHandle entityShadow;
    private TextureHandle[10] destroyStages;
    private HudTextureSet hudTextures;
    private bool mining;
    private BlockHit miningHit;
    private float miningProgress;
    private int miningTicks;
    private uint creativeBreakCooldown;
    private float previousElapsedSeconds;
    private ItemStack displayedMainHand;
    private ItemStack lastItemHighlight;
    private int itemHighlightTicks;
    private float mainHandHeight = 1.0f;
    private float previousMainHandHeight = 1.0f;
    private CameraPerspective perspective = CameraPerspective.firstPerson;
    private bool[uint] remoteDeathPoofed;
    private bool localDeathPoofed;
    private float previousPortalProgress;
    private float portalSpinTime;
    private float portalSpinSpeed;
    private uint portalDisplayTicks;
    private uint visualRandomState=0x9E3779B9u;
    private int netherAmbienceTicks;
    private int underwaterAmbienceTicks;
    private uint waterDisplayTicks;
    private float lastMeshMilliseconds;
    private float lastAssemblyMilliseconds;
    private float lastGraphicsMilliseconds;
    private size_t lastResidentVertices;

    this(void* window, uint width, uint height, string projectRoot, World world,
        OptionsMenuState options, GraphicsApi graphicsApi = GraphicsApi.directX12)
    {
        this.width = width;
        this.height = height;
        this.world = world;
        this.options = options;
        resources = new ResourceManager(projectRoot);
        images = new TextureManager();
        final switch (graphicsApi)
        {
            case GraphicsApi.directX12:
                version (Windows)
                    graphics = new Dx12Device(cast(HWND) window, width, height);
                else
                    throw new Exception("DirectX 12 is available only on Windows");
                break;
            case GraphicsApi.vulkan:
                graphics = new VulkanDevice(window, width, height, projectRoot);
                break;
        }
        blocks = new BlockRenderer(world);
        players = new PlayerRenderer();
        entityShadows = new EntityShadowRenderer(world);
        hud = new HudRenderer();
        titleScreen = new TitleScreenRenderer(graphicsApi == GraphicsApi.vulkan
            ? "D + Vulkan" : "D + DirectX 12");
        pauseMenu = new PauseMenuRenderer();
        deathScreen = new DeathScreenRenderer();
        optionsMenu = new OptionsMenuRenderer();
        inventoryMenu=new InventoryMenuRenderer();

        portalFrames = loadAnimatedFrames("textures/block/nether_portal.png");
        waterStillFrames=loadAnimatedFrames("textures/block/water_still.png");
        waterFlowFrames=loadAnimatedFrames("textures/block/water_flow.png");
        const flintImage=images.loadPng(resources.resolveAsset("minecraft",
            "textures/item/flint_and_steel.png"));
        const flintTexture=graphics.uploadTexture(flintImage);
        blockTextures = BlockTextureSet(
            load("textures/block/grass_block_top.png"),
            load("textures/block/grass_block_side.png"),
            load("textures/block/dirt.png"),
            load("textures/block/stone.png"),
            load("textures/block/obsidian.png"),
            load("textures/block/netherrack.png"),
            load("textures/block/bedrock.png"),
            load("textures/block/bricks.png"),
            load("textures/block/oak_planks.png"),
            load("textures/block/spruce_planks.png"),
            load("textures/block/birch_planks.png"),
            load("textures/block/jungle_planks.png"),
            load("textures/block/acacia_planks.png"),
            load("textures/block/dark_oak_planks.png"),
            load("textures/block/mangrove_planks.png"),
            load("textures/block/cherry_planks.png"),
            load("textures/block/bamboo_planks.png"),
            load("textures/block/pale_oak_planks.png"),
            load("textures/block/crimson_planks.png"),
            load("textures/block/warped_planks.png"),
            load("textures/block/cobblestone.png"),
            load("textures/block/glass.png"),
            waterStillFrames[0],
            waterFlowFrames[0],
            portalFrames[0],
            flintTexture.descriptorIndex,
        );
        steve = loadHandle("textures/entity/player/wide/steve.png");
        accountSkin = steve;
        sun = graphics.uploadTexture(images.loadAdditivePngAsAlpha(
            resources.resolveAsset("minecraft", "textures/environment/celestial/sun.png")));
        auto cloudImage = images.loadPng(
            resources.resolveAsset("minecraft", "textures/environment/clouds.png"));
        clouds = graphics.uploadTexture(cloudImage);
        sky = new SkyRenderer(cloudImage);
        crosshair = loadHandle("textures/gui/sprites/hud/crosshair.png");
        entityShadow = loadHandle("textures/misc/shadow.png");
        foreach (stage; 0 .. 10)
        {
            import std.conv : to;
            destroyStages[stage] = loadHandle("textures/block/destroy_stage_"
                ~ to!string(stage) ~ ".png");
        }
        hudTextures = HudTextureSet(
            load("textures/gui/sprites/hud/hotbar.png"),
            load("textures/gui/sprites/hud/hotbar_selection.png"),
            load("textures/gui/sprites/hud/heart/container.png"),
            load("textures/gui/sprites/hud/heart/container_blinking.png"),
            load("textures/gui/sprites/hud/heart/full.png"),
            load("textures/gui/sprites/hud/heart/half.png"),
            load("textures/gui/sprites/hud/heart/full_blinking.png"),
            load("textures/gui/sprites/hud/heart/half_blinking.png"),
            load("textures/gui/sprites/hud/heart/container_hardcore.png"),
            load("textures/gui/sprites/hud/heart/container_hardcore_blinking.png"),
            load("textures/gui/sprites/hud/heart/hardcore_full.png"),
            load("textures/gui/sprites/hud/heart/hardcore_half.png"),
            load("textures/gui/sprites/hud/heart/hardcore_full_blinking.png"),
            load("textures/gui/sprites/hud/heart/hardcore_half_blinking.png"),
            load("textures/gui/sprites/hud/food_empty.png"),
            load("textures/gui/sprites/hud/food_full.png"),
            load("textures/gui/sprites/hud/food_half.png"),
            load("textures/gui/sprites/hud/air.png"),
            load("textures/gui/sprites/hud/air_bursting.png"),
            load("textures/gui/sprites/hud/air_empty.png"),
            load("textures/gui/sprites/hud/experience_bar_background.png"),
            load("textures/gui/sprites/hud/experience_bar_progress.png"),
        );
        auto asciiImage = images.loadPng(
            resources.resolveAsset("minecraft", "textures/font/ascii.png"));
        const asciiTexture = graphics.uploadTexture(asciiImage);
        fontTexture = asciiTexture.descriptorIndex;
        hudFont = new FontRenderer(asciiImage);
        ImageData solidImage;
        solidImage.width = solidImage.height = 1;
        solidImage.rgba = [cast(ubyte) 255, 255, 255, 255];
        const solidTexture = graphics.uploadTexture(solidImage);
        whiteTexture = solidTexture.descriptorIndex;
        uint[6] panoramaTextures;
        foreach (face; 0 .. 6)
        {
            import std.conv : to;
            panoramaTextures[face] = load(
                "textures/gui/title/background/panorama_"
                ~ to!string(face) ~ ".png");
        }
        titleTextures = TitleTextureSet(
            panoramaTextures,
            loadFrom("minecraft_d", "textures/gui/title/minecraft.png"),
            loadFrom("minecraft_d", "textures/gui/title/edition.png"),
            load("textures/gui/sprites/widget/button.png"),
            load("textures/gui/sprites/widget/button_highlighted.png"),
            load("textures/gui/sprites/widget/button_disabled.png"),
            solidTexture.descriptorIndex,
            load("textures/gui/menu_background.png"),
            blockTextures.dirt,
        );
        pauseTextures = PauseTextureSet(titleTextures.button,
            titleTextures.buttonHighlighted, titleTextures.buttonDisabled,
            titleTextures.white);
        deathTextures = DeathTextureSet(titleTextures.button,
            titleTextures.buttonHighlighted, titleTextures.buttonDisabled,
            titleTextures.white);
        optionsTextures = OptionsTextureSet(titleTextures.button,
            titleTextures.buttonHighlighted, titleTextures.buttonDisabled,
            titleTextures.white, titleTextures.menuBackground);
        inventoryTextures=InventoryTextureSet(
            load("textures/gui/container/inventory.png"),whiteTexture,
            load("textures/gui/sprites/tooltip/background.png"),
            load("textures/gui/sprites/tooltip/frame.png"),
            load("textures/gui/sprites/container/slot_highlight_back.png"),
            load("textures/gui/sprites/container/slot_highlight_front.png"));
        chatRenderer = new ChatRenderer(asciiImage, asciiTexture.descriptorIndex,
            solidTexture.descriptorIndex);
        itemMeshes[ItemId.grassBlock] = blocks.buildItem(BlockId.grass, blockTextures);
        itemMeshes[ItemId.dirt] = blocks.buildItem(BlockId.dirt, blockTextures);
        itemMeshes[ItemId.stone] = blocks.buildItem(BlockId.stone, blockTextures);
        itemMeshes[ItemId.obsidian] = blocks.buildItem(BlockId.obsidian,
            blockTextures);
        itemMeshes[ItemId.netherrack] = blocks.buildItem(BlockId.netherrack,
            blockTextures);
        itemMeshes[ItemId.bricks] = blocks.buildItem(BlockId.bricks, blockTextures);
        itemMeshes[ItemId.oakPlanks] = blocks.buildItem(BlockId.oakPlanks, blockTextures);
        itemMeshes[ItemId.sprucePlanks] = blocks.buildItem(BlockId.sprucePlanks, blockTextures);
        itemMeshes[ItemId.birchPlanks] = blocks.buildItem(BlockId.birchPlanks, blockTextures);
        itemMeshes[ItemId.junglePlanks] = blocks.buildItem(BlockId.junglePlanks, blockTextures);
        itemMeshes[ItemId.acaciaPlanks] = blocks.buildItem(BlockId.acaciaPlanks, blockTextures);
        itemMeshes[ItemId.darkOakPlanks] = blocks.buildItem(BlockId.darkOakPlanks, blockTextures);
        itemMeshes[ItemId.mangrovePlanks] = blocks.buildItem(BlockId.mangrovePlanks, blockTextures);
        itemMeshes[ItemId.cherryPlanks] = blocks.buildItem(BlockId.cherryPlanks, blockTextures);
        itemMeshes[ItemId.bambooPlanks] = blocks.buildItem(BlockId.bambooPlanks, blockTextures);
        itemMeshes[ItemId.paleOakPlanks] = blocks.buildItem(BlockId.paleOakPlanks, blockTextures);
        itemMeshes[ItemId.crimsonPlanks] = blocks.buildItem(BlockId.crimsonPlanks, blockTextures);
        itemMeshes[ItemId.warpedPlanks] = blocks.buildItem(BlockId.warpedPlanks, blockTextures);
        itemMeshes[ItemId.cobblestone] = blocks.buildItem(BlockId.cobblestone, blockTextures);
        itemMeshes[ItemId.glass] = blocks.buildItem(BlockId.glass, blockTextures);
        itemMeshes[ItemId.bedrock] = blocks.buildItem(BlockId.bedrock,
            blockTextures);
        itemMeshes[ItemId.flintAndSteel] = blocks.buildGeneratedItem(
            blockTextures.flintAndSteel,flintImage);
        uint[8] poofTextures;
        uint[8] portalTextures;
        foreach (index; 0 .. 8)
        {
            import std.conv : to;
            poofTextures[index]=load("textures/particle/generic_"
                ~to!string(7-index)~".png");
            portalTextures[index]=load("textures/particle/generic_"
                ~to!string(index)~".png");
        }
        uint[4] splashTextures;
        foreach(index;0..4)
        {
            import std.conv:to;
            splashTextures[index]=load("textures/particle/splash_"
                ~to!string(index)~".png");
        }
        uint[5] bubblePopTextures;
        foreach(index;0..5)
        {
            import std.conv:to;
            bubblePopTextures[index]=load("textures/particle/bubble_pop_"
                ~to!string(index)~".png");
        }
        particles = new ParticleSystem(world, ParticleTextureSet(
            blockTextures.grassSide, blockTextures.dirt, blockTextures.stone,
            blockTextures.obsidian, blockTextures.netherrack,
            blockTextures.bedrock,
            blockTextures.bricks, blockTextures.oakPlanks,
            blockTextures.sprucePlanks, blockTextures.birchPlanks,
            blockTextures.junglePlanks, blockTextures.acaciaPlanks,
            blockTextures.darkOakPlanks, blockTextures.mangrovePlanks,
            blockTextures.cherryPlanks, blockTextures.bambooPlanks,
            blockTextures.paleOakPlanks, blockTextures.crimsonPlanks,
            blockTextures.warpedPlanks, blockTextures.cobblestone,
            blockTextures.glass,
            load("textures/particle/critical_hit.png"),poofTextures,
            portalTextures,splashTextures,load("textures/particle/bubble.png"),
            bubblePopTextures));
        sounds = new SoundManager(resources);
        applyOptions();
    }

    ~this()
    {
        if (sounds !is null)
        {
            destroy(sounds);
            sounds = null;
        }
        // The swap chain must release its HWND-dependent resources before
        // GameWindow destroys the native window. Leaving this to GC timing can
        // crash during a normal WM_CLOSE teardown.
        if (graphics !is null)
        {
            clearChunkMeshes();
            destroy(graphics);
            graphics = null;
        }
        if (images !is null)
        {
            destroy(images);
            images = null;
        }
        if (resources !is null)
        {
            destroy(resources);
            resources = null;
        }
    }

    void cyclePerspective()
    {
        final switch (perspective)
        {
            case CameraPerspective.firstPerson:
                perspective = CameraPerspective.thirdPersonBack;
                break;
            case CameraPerspective.thirdPersonBack:
                perspective = CameraPerspective.thirdPersonFront;
                break;
            case CameraPerspective.thirdPersonFront:
                perspective = CameraPerspective.firstPerson;
                break;
        }
    }

    void resize(uint resizedWidth, uint resizedHeight)
    {
        if (resizedWidth == 0 || resizedHeight == 0
            || (resizedWidth == width && resizedHeight == height))
            return;
        graphics.resize(resizedWidth, resizedHeight);
        width = resizedWidth;
        height = resizedHeight;
    }


    TitleAction titleActionAt(int mouseX, int mouseY) const
    {
        return titleScreen.hitTest(width, height, mouseX, mouseY);
    }

    AccountMenuAction accountActionAt(int mouseX,int mouseY,
        const AccountMenuState state,const AccountSnapshot account)const
    {
        return titleScreen.accountHitTest(width,height,mouseX,mouseY,state,account);
    }

    long accountTextCursorAt(int mouseX,const AccountMenuState state)const
    {
        return titleScreen.accountTextCursorAt(width,height,mouseX,state,hudFont);
    }

    MultiplayerMenuAction multiplayerMenuActionAt(int mouseX, int mouseY) const
    {
        return titleScreen.multiplayerHitTest(width, height, mouseX, mouseY);
    }

    long multiplayerTextCursorAt(int mouseX,
        const MultiplayerMenuState state, MultiplayerField field) const
    {
        return titleScreen.multiplayerTextCursorAt(width, height, mouseX,
            state, field, hudFont);
    }

    WorldMenuAction worldMenuActionAt(int mouseX, int mouseY,
        const WorldMenuState state) const
    {
        return titleScreen.worldMenuHitTest(width,height,mouseX,mouseY,state);
    }

    long worldTextCursorAt(int mouseX, const WorldMenuState state,
        WorldField field) const
    {
        return titleScreen.worldTextCursorAt(width, height, mouseX,
            state, field, hudFont);
    }

    int worldRowAt(int mouseY, const WorldMenuState state) const
    {
        return titleScreen.worldRowAt(width,height,mouseY,state);
    }

    PauseAction pauseActionAt(int mouseX, int mouseY, bool canPublish,
        const PauseMenuState state) const
    {
        return pauseMenu.hitTest(width, height, mouseX, mouseY, canPublish,
            state);
    }

    DeathAction deathActionAt(int mouseX, int mouseY,
        const DeathScreenState state) const
    {
        return deathScreen.hitTest(width,height,mouseX,mouseY,state);
    }

    OptionsAction optionsActionAt(int mouseX, int mouseY) const
    {
        return optionsMenu.hitTest(width,height,mouseX,mouseY,options);
    }

    int inventorySlotAt(int mouseX,int mouseY)const
    {
        return inventoryMenu.hitSlot(width,height,mouseX,mouseY);
    }

    bool inventoryOutside(int mouseX,int mouseY)const
    {
        return inventoryMenu.outside(width,height,mouseX,mouseY);
    }

    void applyOptions()
    {
        if (sounds !is null && options !is null)
            sounds.setVolumes(options.masterVolume, options.soundVolume,
                options.number("soundCategory_player",1),
                options.number("soundCategory_ui",1),
                options.number("soundCategory_music",1),
                options.boolean("directionalAudio",false));
        if(graphics !is null)graphics.setVsync(options.boolean("vsync",true));
        if(blocks !is null)
        {
            const smooth=options.integer("ao",2)!=0;
            const gamma=options.number("gamma",0.5f);
            if(smooth!=meshSmoothLighting||gamma!=meshGamma)
            {
                clearChunkMeshes();
                meshJobActive=false;
            }
            meshSmoothLighting=smooth;meshGamma=gamma;
            blocks.configure(smooth,gamma);
        }
        if(particles !is null)particles.setLevel(options.integer("particles",0));
    }

    void setTitleNotice(string notice)
    {
        titleScreen.setNotice(notice);
    }

    void playUiButtonClick()
    {
        sounds.playUiButton();
    }

    void tickMenuMusic()
    {
        sounds.tickMenuMusic(options.integer("musicFrequency", 0));
    }

    void tickGameMusic(DimensionId dimension, bool paused)
    {
        sounds.tickGameMusic(dimension,
            options.integer("musicFrequency", 0), paused);
    }

    void renderTitleScreen(int mouseX, int mouseY, float elapsedSeconds)
    {
        frame.clear();
        titleScreen.append(frame, width, height, mouseX, mouseY, elapsedSeconds,
            titleTextures, hudFont, fontTexture);
        graphics.render(frame);
    }

    void renderAccountScreen(int mouseX,int mouseY,float elapsedSeconds,
        const AccountMenuState state,const AccountSnapshot account,
        const Player player)
    {
        syncAccountSkin(account);
        frame.clear();
        titleScreen.appendAccount(frame,width,height,mouseX,mouseY,
            elapsedSeconds,state,account,titleTextures,hudFont,fontTexture);
        if(account.loggedIn)
        {
            int scale=1;
            while(scale<8&&width/(scale+1)>=320&&height/(scale+1)>=240)++scale;
            const logicalWidth=cast(float)width/scale;
            const logicalHeight=cast(float)height/scale;
            const center=cast(int)logicalWidth/2;
            inventoryMenu.appendPlayerShowcase(frame,center-150,74,140,112,
                mouseX/scale,mouseY/scale,logicalWidth,logicalHeight,players,
                player,accountSkin.descriptorIndex,1.0f,elapsedSeconds*20.0f,
                accountSkinModel=="slim");
        }
        graphics.render(frame);
    }

    void syncAccountSkin(const AccountSnapshot account)
    {
        if(accountSkinRevision==account.updatedAt
            &&accountSkinPath==account.skinPath
            &&accountSkinModel==account.skinModel)return;
        accountSkinRevision=account.updatedAt;
        accountSkinPath=account.skinPath.idup;
        accountSkinModel=account.skinModel=="slim"?"slim":"classic";
        accountSkin=steve;
        if(!account.skinPath.length)return;
        try
        {
            const image=images.loadPng(account.skinPath);
            if(image.width==64&&image.height==64)
                accountSkin=graphics.uploadTexture(image);
        }
        catch(Exception) {}
    }

    void syncRemoteSkin(string accountId,string versionValue,string path)
    {
        if(!accountId.length||!path.length)return;
        if(auto found=accountId in remoteSkinVersions)
            if(*found==versionValue)return;
        try
        {
            const image=images.loadPng(path);
            if(image.width!=64||image.height!=64)return;
            remoteSkins[accountId]=graphics.uploadTexture(image);
            remoteSkinVersions[accountId]=versionValue.idup;
        }
        catch(Exception){}
    }

    void renderMultiplayerScreen(int mouseX, int mouseY, float elapsedSeconds,
        const MultiplayerMenuState state)
    {
        frame.clear();
        titleScreen.appendMultiplayer(frame, width, height, mouseX, mouseY,
            elapsedSeconds, state, titleTextures, hudFont, fontTexture);
        graphics.render(frame);
    }

    void renderWorldMenu(int mouseX, int mouseY, const WorldMenuState state)
    {
        frame.clear();
        titleScreen.appendWorldMenu(frame,width,height,mouseX,mouseY,state,
            titleTextures,hudFont,fontTexture);
        graphics.render(frame);
    }

    void renderOptionsScreen(int mouseX, int mouseY, float elapsedSeconds)
    {
        frame.clear();
        titleScreen.appendOptionsBackground(frame,width,height,elapsedSeconds,
            titleTextures);
        optionsMenu.append(frame,width,height,mouseX,mouseY,options,true,
            optionsTextures,hudFont,fontTexture);
        graphics.render(frame);
    }

    void renderLoadingScreen(string status, int percent)
    {
        frame.clear();
        titleScreen.appendLoading(frame,width,height,status,percent,
            titleTextures,hudFont,fontTexture);
        graphics.render(frame);
    }

    void simulateTick(LocalPlayer player, MultiplayerClient multiplayer)
    {
        updateHeldItem(player);
        ItemStack selected;
        if(player.selectedSlot>=0&&player.selectedSlot<player.inventory.hotbar.length)
            selected=player.inventory.hotbar[player.selectedSlot];
        if(!sameHeldStack(selected,lastItemHighlight))
        {
            lastItemHighlight=selected;
            itemHighlightTicks=selected.empty()?0:40;
        }
        else if(itemHighlightTicks>0)
            --itemHighlightTicks;
        sounds.setListener(player.eyePosition(1.0f), player.yaw);
        if (player.portalProgress > 0.0f && previousPortalProgress <= 0.0f)
            sounds.playPortalTrigger(nearestPortalPosition(player.position));
        portalSpinSpeed=player.portalProgress>0.0f?20.0f:0.0f;
        portalSpinTime+=portalSpinSpeed;
        previousPortalProgress = player.portalProgress;
        tickPortalBlocks(player);
        tickWaterBlocks(player);
        if (player.dimension == DimensionId.nether)
        {
            if (netherAmbienceTicks-- <= 0)
            {
                sounds.playNetherAmbience();
                netherAmbienceTicks = 3600;
            }
        }
        else
            netherAmbienceTicks = 0;
        if(player.eyeInWater)
        {
            if(underwaterAmbienceTicks--<=0)
            {
                sounds.playUnderwaterAmbience();
                underwaterAmbienceTicks=1200;
            }
            if(++waterDisplayTicks%10==0)particles.spawnSwimming(player);
        }
        else
        {
            underwaterAmbienceTicks=0;
            waterDisplayTicks=0;
        }
        if (player.stepSoundDue)
        {
            import core.stdc.math : floorf;
            const ground = world.getBlock(
                cast(int) floorf(player.position.x),
                cast(int) floorf(player.position.y - 0.05f),
                cast(int) floorf(player.position.z));
            if (ground != BlockId.air)
                sounds.playStep(ground,player.position);
        }
        if (player.sprinting && player.onGround
            && player.velocity.horizontalLength() > 0.01f)
            particles.spawnSprint(player);
        if (player.landingParticlesDue)
        {
            particles.spawnLanding(player, player.lastLandedFallDistance);
            player.landingParticlesDue = false;
        }
        foreach (remote; multiplayer.remotePlayers())
        {
            if (remote.sprinting && remote.onGround
                && remote.velocity.horizontalLength() > 0.01f)
                particles.spawnSprint(remote);
            if (remote.landingParticlesDue)
            {
                particles.spawnLanding(remote, remote.lastLandedFallDistance);
                remote.landingParticlesDue = false;
            }
            if(remote.deathTime>=20 && remote.networkId !in remoteDeathPoofed)
            {
                particles.spawnPoof(remote.position,remote.height());
                remoteDeathPoofed[remote.networkId]=true;
            }
            else if(remote.health>0)
                remoteDeathPoofed.remove(remote.networkId);
        }
        if(player.deathTime>=20&&!localDeathPoofed)
        {
            particles.spawnPoof(player.position,player.height());
            localDeathPoofed=true;
        }
        else if(player.health>0)
            localDeathPoofed=false;
        if (player.hurtSoundDue)
        {
            sounds.playPlayerHurt();
            player.hurtSoundDue = false;
        }
        if (player.fallSoundDue != 0)
        {
            sounds.playFall(player.fallSoundDue == 2);
            player.fallSoundDue = 0;
        }
        if(player.waterEntryDue)
        {
            sounds.playWaterEntry(player.position,player.velocity.length());
            particles.spawnWaterEntry(player);
        }
        if(player.waterExitDue)sounds.playWaterExit();
        if(player.swimSoundDue)
        {
            sounds.playSwim(player.position);
            particles.spawnSwimming(player);
        }
        particles.tick();
    }

    void updateMining(LocalPlayer player, bool held, bool pressed = false)
    {
        if (player.gameMode == GameMode.creative)
        {
            cancelMining();
            if (!held && !pressed)
            {
                creativeBreakCooldown = 0;
                return;
            }
            if (creativeBreakCooldown > 0)
                --creativeBreakCooldown;
            if (pressed || creativeBreakCooldown == 0)
            {
                player.attack(true);
                creativeBreakCooldown = 6;
            }
            return;
        }
        if (!held)
        {
            cancelMining();
            creativeBreakCooldown = 0;
            return;
        }
        const hit = world.rayCast(player.eyePosition(1.0f),
            forwardFromYawPitch(player.yaw, player.pitch), 5.0f);
        if (!hit.hit)
        {
            cancelMining();
            return;
        }
        if (!mining || hit.x != miningHit.x || hit.y != miningHit.y
            || hit.z != miningHit.z || hit.block != miningHit.block)
        {
            mining = true;
            miningHit = hit;
            miningProgress = 0.0f;
            miningTicks = 0;
        }

        const center = Vec3(hit.x + 0.5f, hit.y + 0.5f, hit.z + 0.5f);
        if (miningTicks % 4 == 0)
            sounds.playHit(hit.block, center);
        // continueAttack swings every mining tick. LocalPlayer applies Java's
        // halfway restart guard, so both view-model and body repeat together.
        player.attack(true);
        ++miningTicks;
        float destroyProgress=bareHandDestroyProgress(hit.block);
        // SUBMERGED_MINING_SPEED defaults to .2; being airborne applies the
        // separate Java /5 penalty as well.
        if(player.eyeInWater)destroyProgress*=0.2f;
        if(!player.onGround)destroyProgress*=0.2f;
        miningProgress += player.gameMode == GameMode.creative
            ? 1.0f : destroyProgress;
        if (miningProgress >= 1.0f)
            miningProgress = 0.999f; // await the authoritative block-change packet
    }

    void applyBlockChange(int x, int y, int z, BlockId oldBlock,
        BlockId newBlock)
    {
        const center = Vec3(x + 0.5f, y + 0.5f, z + 0.5f);
        if (newBlock == BlockId.air && oldBlock != BlockId.air
            && !isNetherPortal(oldBlock) && !isWater(oldBlock))
        {
            // The authoritative world is already empty, but a tall chunk's
            // replacement mesh is intentionally assembled over several
            // frames. Remove the old block's cached quads now so its break
            // particles can never appear while the cube is still visible.
            discardCachedBlockFaces(x,y,z,oldBlock);
            sounds.playBreak(oldBlock, center);
            particles.spawnBlockBreak(x, y, z, oldBlock);
        }
        else if (newBlock != BlockId.air && !isNetherPortal(newBlock)
            && !isWater(newBlock))
            sounds.playPlace(newBlock,center);
        // Render coalesces all changes received this tick into one revision
        // rebuild, avoiding a full remesh for every cell in a flowing front.
        if (mining && miningHit.x == x && miningHit.y == y && miningHit.z == z)
            cancelMining();
    }

    void playPickup(Vec3 position)
    {
        sounds.playPickup(position);
    }

    void applyCriticalHit(Vec3 targetPosition)
    {
        particles.spawnCriticalHit(targetPosition);
        sounds.playCriticalHit(targetPosition);
    }

    void applyDimensionTravel(DimensionId dimension)
    {
        sounds.playPortalTravel();
        if (dimension == DimensionId.nether)
        {
            sounds.playNetherAmbience();
            netherAmbienceTicks = 3600;
        }
        clearChunkMeshes();
        meshJobActive=false;
        cancelMining();
    }

    long chatCursorAt(int mouseX, int mouseY, const ChatState chat) const
    {
        return chatRenderer.cursorAt(mouseX, mouseY, width, height, chat);
    }

    void render(LocalPlayer player, const ChatState chat,
        MultiplayerClient multiplayer, float partialTick, float elapsedSeconds,
        const PauseMenuState pauseState = null, int menuMouseX = 0,
        int menuMouseY = 0, bool canPublish = false,
        const DeathScreenState deathState = null, int deathMouseX = 0,
        int deathMouseY = 0,const InventoryMenuState inventoryState=null,
        int inventoryMouseX=0,int inventoryMouseY=0,
        bool debugVisible=false,float debugFps=0.0f)
    {
        const renderStarted=monotonicSeconds();
        const frameSeconds = elapsedSeconds >= previousElapsedSeconds
            ? elapsedSeconds - previousElapsedSeconds : 0.0f;
        previousElapsedSeconds = elapsedSeconds;
        multiplayer.advanceDroppedItems(frameSeconds > 0.1f ? 0.1f : frameSeconds);
        // Only one 16-block-high chunk section is meshed per presented frame.
        // This keeps procedural terrain work out of a single long frame.
        syncChunkMeshes(player.position,player.yaw,1);
        const meshingFinished=monotonicSeconds();
        lastMeshMilliseconds=cast(float)((meshingFinished-renderStarted)*1000.0);
        frame.clear(player.dimension == DimensionId.nether
            ? Color(0.20f,0.03f,0.03f,1.0f)
            : Color(0.48f,0.70f,1.0f,1.0f));
        Camera camera;
        const eye = player.interpolatedEyePosition(partialTick);
        const facing = forwardFromYawPitch(player.yaw, player.pitch);
        camera.position = eye;
        camera.yaw = player.yaw;
        camera.pitch = player.pitch;
        camera.fovDegrees = options.fov
            * player.interpolatedFovModifier(partialTick);
        camera.fovDegrees = camera.deathFov(player,partialTick);
        final switch (perspective)
        {
            case CameraPerspective.firstPerson:
                break;
            case CameraPerspective.thirdPersonBack:
                camera.position = world.clipCamera(eye, eye - facing * 4.0f);
                break;
            case CameraPerspective.thirdPersonFront:
                camera.position = world.clipCamera(eye, eye + facing * 4.0f);
                camera.yaw = player.yaw + 180.0f;
                camera.pitch = -player.pitch;
                break;
        }
        const aspect = cast(float) width / cast(float) height;
        sounds.setListener(camera.position, camera.yaw);
        auto viewProjection = camera.viewMatrix(player, partialTick,
            options.viewBobbing) * camera.projectionMatrix(aspect);
        const portalAmount = clamp(player.portalProgress,0.0f,1.0f);
        if (portalAmount > 0.0f)
        {
            // Modern Java rotates the projection around the diagonal Y/Z axis,
            // squeezes X with this intensity curve, then rotates it back. The
            // hand is rendered through a separate projection and is therefore
            // deliberately unaffected.
            const strength=portalAmount*portalAmount;
            float skew=5.0f/(strength+5.0f)-portalAmount*0.04f;
            skew*=skew;
            const angle=(portalSpinTime+partialTick*portalSpinSpeed)
                *3.14159265f/180.0f;
            const axis=Vec3(0,0.70710678f,0.70710678f);
            viewProjection = viewProjection
                *Mat4.rotationAxis(axis,angle)
                *Mat4.scale(Vec3(1.0f/skew,1,1))
                *Mat4.rotationAxis(axis,-angle);
        }

        // Draw sky texture geometry first. Depth testing keeps it behind the world.
        int viewChunks=options.integer("renderDistance",6);
        if(viewChunks<2)viewChunks=2;if(viewChunks>12)viewChunks=12;
        const fogEnd=cast(float)(viewChunks*16);
        const fogStart=player.dimension==DimensionId.nether
            ?fogEnd*0.35f:fogEnd*0.72f;
        auto terrainFog=FogSettings.distance(camera.position,fogStart,fogEnd);
        if (player.dimension == DimensionId.nether)
            terrainFog.color = Color(0x33/255.0f,0x08/255.0f,0x08/255.0f,1);
        if(world.isPointInWater(camera.position))
        {
            // Java's water fog is short and blue-green; it replaces the sky
            // distance fog while the camera itself is submerged.
            terrainFog=FogSettings.distance(camera.position,0.0f,16.0f);
            terrainFog.color=Color(0.02f,0.18f,0.24f,1.0f);
        }
        const cloudFog = FogSettings.distance(camera.position, 300.0f, 380.0f);
        if (player.dimension == DimensionId.overworld)
            frame.append(sky.buildSun(camera.position), sun.descriptorIndex,
                viewProjection, DrawLayer.sky);
        const cloudMode=options.integer("renderClouds",options.clouds?2:0);
        if (cloudMode!=0 && player.dimension == DimensionId.overworld)
            frame.append(sky.buildClouds(camera.position, elapsedSeconds,
                    cloudMode==2),
                clouds.descriptorIndex, viewProjection, DrawLayer.world, cloudFog);

        admittedRenderChunks.length=0;
        lastResidentVertices=0;
        foreach(coordinate;visibleChunkCoordinates(camera))
        {
            auto chunkGeometry=coordinate in chunkMeshes;
            if(chunkGeometry is null||!chunkGeometry.mesh.valid)continue;
            admittedRenderChunks~=coordinate;
        }
        // Terrain vertices remain in device-local buffers after a chunk is
        // meshed. A frame now records only small section draw ranges instead
        // of rebuilding and copying close to a million vertices every tick.
        foreach(coordinate;admittedRenderChunks)
        {
            auto chunkGeometry=coordinate in chunkMeshes;
            if(chunkGeometry is null)continue;
            foreach(section;chunkGeometry.sections)
            {
                if(!sectionIntersectsFrustum(camera,coordinate,
                    section.minimumY,section.maximumY))continue;
                foreach(range;section.opaqueRanges)
                {
                    frame.appendResident(chunkGeometry.mesh,range.firstVertex,
                        range.vertexCount,range.textureIndex,viewProjection,
                        DrawLayer.world,terrainFog);
                    lastResidentVertices+=range.vertexCount;
                }
            }
        }
        const portalTexture=portalFrames.length
            ?portalFrames[cast(size_t)(elapsedSeconds*20.0f)%portalFrames.length]
            :blockTextures.netherPortal;
        const waterFrame=cast(size_t)(elapsedSeconds*10.0f);
        const stillTexture=waterStillFrames.length
            ?waterStillFrames[waterFrame%waterStillFrames.length]
            :blockTextures.waterStill;
        const flowTexture=waterFlowFrames.length
            ?waterFlowFrames[waterFrame%waterFlowFrames.length]
            :blockTextures.waterFlow;

        const targeted=world.rayCast(player.eyePosition(partialTick),
            forwardFromYawPitch(player.yaw,player.pitch),5.0f);
        if(targeted.hit&&player.health>0)
            frame.append(blocks.buildOutline(targeted.x,targeted.y,targeted.z),
                whiteTexture,viewProjection,DrawLayer.world,terrainFog);

        if (mining)
        {
            int stage = cast(int) (miningProgress * 10.0f);
            if (stage > 9) stage = 9;
            frame.append(blocks.buildDamageOverlay(miningHit.x, miningHit.y, miningHit.z),
                destroyStages[stage].descriptorIndex, viewProjection,
                DrawLayer.world, terrainFog);
        }
        foreach (remote; multiplayer.remotePlayers())
        {
            if (!remote.mining)
                continue;
            int stage = cast(int) (remote.miningProgress * 10.0f);
            if (stage < 0) stage = 0;
            if (stage > 9) stage = 9;
            frame.append(blocks.buildDamageOverlay(remote.miningX,
                    remote.miningY, remote.miningZ),
                destroyStages[stage].descriptorIndex, viewProjection,
                DrawLayer.world, terrainFog);
        }

        // Java renders entity shadows as one depth-tested, non-depth-writing
        // decal pass. Each piece is clipped to the block top beneath it.
        if (options.entityShadows)
        {
            const playerShadow = EntityShadowStyle.fromFootprint(
                Player.width, Player.width);
            const itemShadow = EntityShadowStyle(0.15f, 0.75f);
            foreach (renderItem; multiplayer.droppedItems())
                frame.append(entityShadows.build(renderItem.interpolatedPosition(),
                    itemShadow, camera.position), entityShadow.descriptorIndex,
                    viewProjection, DrawLayer.entityShadow, terrainFog);
            foreach (remote; multiplayer.remotePlayers())
                if (remote.gameMode != GameMode.spectator
                    && !(remote.health<=0&&remote.deathTime>=20))
                    frame.append(entityShadows.build(
                        remote.interpolatedPosition(partialTick), playerShadow,
                        camera.position), entityShadow.descriptorIndex, viewProjection,
                        DrawLayer.entityShadow, terrainFog);
            if (perspective != CameraPerspective.firstPerson
                && player.gameMode != GameMode.spectator
                && !(player.health<=0&&player.deathTime>=20))
                frame.append(entityShadows.build(
                    player.interpolatedPosition(partialTick), playerShadow,
                    camera.position), entityShadow.descriptorIndex, viewProjection,
                    DrawLayer.entityShadow, terrainFog);
        }

        foreach (textureIndex, geometry; particles.build(camera, partialTick))
            frame.append(geometry, textureIndex, viewProjection,
                DrawLayer.worldDoubleSided, terrainFog);

        foreach (renderItem; multiplayer.droppedItems())
        {
            const item = renderItem.state;
            auto mesh = item.item in itemMeshes;
            if (mesh is null) continue;
            const time = elapsedSeconds * 20.0f + item.id;
            const bob = 0.1f + sinf(time / 10.0f + item.id) * 0.1f;
            const model = Mat4.translation(Vec3(-0.5f,-0.5f,-0.5f))
                * Mat4.scale(Vec3(0.25f,0.25f,0.25f))
                * Mat4.rotationY(time * 0.05f)
                * Mat4.translation(renderItem.interpolatedPosition()
                    + Vec3(0,bob,0));
            foreach (textureIndex, geometry; *mesh)
                frame.append(geometry, textureIndex, model * viewProjection,
                    stackLayer(item.item, textureIndex), terrainFog);
        }

        foreach (remote; multiplayer.remotePlayers())
        {
            if(remote.health<=0&&remote.deathTime>=20)
                continue;
            ItemStack remoteHeld;
            if(remote.selectedSlot>=0
                &&remote.selectedSlot<remote.inventory.hotbar.length)
                remoteHeld=remote.inventory.hotbar[remote.selectedSlot];
            auto geometry = remote.gameMode == GameMode.spectator
                ? players.buildSpectatorHead(remote.interpolatedPosition(partialTick),
                    remote.interpolatedBodyYaw(partialTick)+180.0f,
                    remote.headYawOffset(partialTick),remote.pitch)
                : players.buildSteve(remote.interpolatedPosition(partialTick),
                    remote.interpolatedBodyYaw(partialTick) + 180.0f,
                    remote.headYawOffset(partialTick), remote.pitch,
                    remote.interpolatedWalkAnimationPosition(partialTick),
                    remote.interpolatedWalkAnimationSpeed(partialTick),
                    remote.interpolatedAttackProgress(partialTick), remote.crouching,
                     elapsedSeconds * 20.0f, SkinLayers.fromBits(remote.skinParts),
                     !remoteHeld.empty(),remote.mainHandRight,remote.swimming,
                     remote.skinModel=="slim");
            if (remote.gameMode != GameMode.spectator)
                players.applyDeathPose(geometry,
                    remote.interpolatedPosition(partialTick),
                    remote.interpolatedBodyYaw(partialTick)+180.0f,
                    remote.interpolatedDeathTime(partialTick));
            applyHurtTint(geometry, remote.hurtTime, remote.health <= 0.0f);
            players.applyWorldLight(geometry,blocks.lightAt(
                remote.interpolatedPosition(partialTick)+Vec3(0,1.0f,0)));
            uint remoteTexture=steve.descriptorIndex;
            if(auto custom=remote.accountId in remoteSkins)
                if(auto revision=remote.accountId in remoteSkinVersions)
                    if(remote.skinVersion.length&&*revision==remote.skinVersion)
                        remoteTexture=custom.descriptorIndex;
            frame.append(geometry, remoteTexture, viewProjection,
                remote.gameMode == GameMode.spectator
                    ? DrawLayer.entityShadow : DrawLayer.worldDoubleSided,
                terrainFog);
            if(remote.gameMode!=GameMode.spectator&&!remoteHeld.empty())
                appendHeldBlock(remoteHeld,remote.interpolatedPosition(partialTick),
                    remote.interpolatedBodyYaw(partialTick)+180.0f,
                    remote.mainHandRight,remote.interpolatedWalkAnimationPosition(partialTick),
                    remote.interpolatedWalkAnimationSpeed(partialTick),
                    remote.interpolatedAttackProgress(partialTick),remote.crouching,
                    elapsedSeconds*20.0f,remote.skinModel=="slim",
                    viewProjection,terrainFog);
        }

        if (perspective != CameraPerspective.firstPerson)
        {
            const localPosition = player.interpolatedPosition(partialTick);
            const modelBodyYaw = player.interpolatedBodyYaw(partialTick) + 180.0f;
            auto geometry = player.gameMode == GameMode.spectator
                ? players.buildSpectatorHead(localPosition,modelBodyYaw,
                    player.headYawOffset(partialTick),player.pitch)
                : players.buildSteve(localPosition, modelBodyYaw,
                    player.headYawOffset(partialTick), player.pitch,
                    player.interpolatedWalkAnimationPosition(partialTick),
                    player.interpolatedWalkAnimationSpeed(partialTick),
                    player.interpolatedAttackProgress(partialTick), player.crouching,
                     elapsedSeconds * 20.0f, SkinLayers.fromBits(player.skinParts),
                     !displayedMainHand.empty(),player.mainHandRight,player.swimming,
                     accountSkinModel=="slim");
            if (player.gameMode != GameMode.spectator)
                players.applyDeathPose(geometry,localPosition,modelBodyYaw,
                    player.interpolatedDeathTime(partialTick));
            applyHurtTint(geometry, player.hurtTime, player.health <= 0.0f);
            players.applyWorldLight(geometry,blocks.lightAt(
                localPosition+Vec3(0,1.0f,0)));
            if(!(player.health<=0&&player.deathTime>=20))
                frame.append(geometry, accountSkin.descriptorIndex, viewProjection,
                    player.gameMode == GameMode.spectator
                        ? DrawLayer.entityShadow : DrawLayer.worldDoubleSided,
                    terrainFog);
            if(player.gameMode!=GameMode.spectator&&!displayedMainHand.empty()
                &&player.health>0)
                appendHeldBlock(displayedMainHand,localPosition,modelBodyYaw,
                    player.mainHandRight,
                    player.interpolatedWalkAnimationPosition(partialTick),
                    player.interpolatedWalkAnimationSpeed(partialTick),
                    player.interpolatedAttackProgress(partialTick),player.crouching,
                    elapsedSeconds*20.0f,accountSkinModel=="slim",
                    viewProjection,terrainFog);
            appendTranslucentWorld(camera,portalTexture,stillTexture,flowTexture,
                viewProjection,terrainFog);
        }
        else
        {
            appendTranslucentWorld(camera,portalTexture,stillTexture,flowTexture,
                viewProjection,terrainFog);
            const equipProgress = 1.0f - lerp(partialTick,
                previousMainHandHeight, mainHandHeight);
            // View bob and fall pitch share the smoothed camera-space transform
            // used by the world, so the hand never snaps when leaving the ground.
            const viewModelMotion=players.firstPersonLookSwayTransform(
                    player.viewPitchSway(partialTick), player.viewYawSway(partialTick))
                *camera.effectsMatrix(player,partialTick,options.viewBobbing);
            const viewModelLight=blocks.lightAt(
                player.interpolatedPosition(partialTick)+Vec3(0,1.0f,0));
            // View models stay in camera space, so their render transform has
            // no yaw/pitch. Map their final normals back to world space for
            // lighting; otherwise turning the camera leaves a frozen shade.
            const cameraForward=forwardFromYawPitch(camera.yaw,camera.pitch);
            const cameraRight=cross(Vec3(0,1,0),cameraForward).normalized();
            const cameraUp=cross(cameraForward,cameraRight).normalized();
            auto cameraToWorld=Mat4.identity();
            cameraToWorld.m[0]=cameraRight.x;
            cameraToWorld.m[1]=cameraRight.y;
            cameraToWorld.m[2]=cameraRight.z;
            cameraToWorld.m[4]=cameraUp.x;
            cameraToWorld.m[5]=cameraUp.y;
            cameraToWorld.m[6]=cameraUp.z;
            cameraToWorld.m[8]=cameraForward.x;
            cameraToWorld.m[9]=cameraForward.y;
            cameraToWorld.m[10]=cameraForward.z;
            const armPose=players.firstPersonArmTransform(
                player.interpolatedAttackProgress(partialTick),aspect,
                equipProgress)*viewModelMotion;
            const handProjection=armPose*camera.viewModelProjectionMatrix(aspect);
            if (displayedMainHand.empty() && player.health > 0.0f
                && player.gameMode != GameMode.spectator)
            {
                const sleeveBit=player.mainHandRight?Player.skinRightSleeve
                    :Player.skinLeftSleeve;
                auto arm=players.buildFirstPersonArm(
                    (player.skinParts&sleeveBit)!=0,
                    accountSkinModel=="slim");
                players.applyPosedLight(arm,armPose*cameraToWorld,
                    viewModelLight);
                frame.append(arm, accountSkin.descriptorIndex,
                    handProjection, DrawLayer.viewModel);
            }

            if (!displayedMainHand.empty() && player.health > 0.0f
                && player.gameMode != GameMode.spectator)
            {
                auto heldMesh = displayedMainHand.item in itemMeshes;
                if (heldMesh !is null)
                {
                    const generated=displayedMainHand.item==ItemId.flintAndSteel;
                    const itemPose=generated
                        ? players.firstPersonGeneratedItemTransform(
                            player.interpolatedAttackProgress(partialTick),
                            equipProgress)
                        : players.firstPersonBlockTransform(
                            player.interpolatedAttackProgress(partialTick),
                            equipProgress);
                    const itemModel=itemPose*viewModelMotion;
                    const itemProjection=itemModel
                        *camera.viewModelProjectionMatrix(aspect);
                    foreach (textureIndex, geometry; *heldMesh)
                    {
                        auto litGeometry=geometry.dup;
                        players.applyPosedLight(litGeometry,
                            itemModel*cameraToWorld,
                            viewModelLight,!generated,false);
                        frame.append(litGeometry,textureIndex,itemProjection,
                            DrawLayer.viewModel);
                    }
                }
            }
        }

        // Vanilla positions labels at entity height + 0.5 blocks and renders
        // them as camera-facing text. Sneaking reduces the range to 32 blocks
        // and keeps the label depth-tested; standing labels use the normal
        // 64-block range and remain readable through intervening geometry.
        foreach (remote; multiplayer.remotePlayers())
        {
            if(remote.health<=0&&remote.deathTime>=20)
                continue;
            const position = remote.interpolatedPosition(partialTick);
            const maximum = remote.crouching ? 32.0f : 64.0f;
            if ((position - camera.position).lengthSquared()
                > maximum * maximum)
                continue;
            const anchor = position + Vec3(0, remote.height() + 0.5f, 0);
            const layer = remote.crouching ? DrawLayer.worldDoubleSided
                : DrawLayer.overlay;
            frame.append(hudFont.buildWorldBackground(remote.name, anchor,
                    camera.yaw, camera.pitch, Color(0,0,0,0.25f)),
                whiteTexture, viewProjection, layer);
            frame.append(hudFont.buildWorldText(remote.name, anchor,
                    camera.yaw, camera.pitch, Color(1,1,1,1)),
                fontTexture, viewProjection, layer);
        }
        if (deathState is null || !deathState.active)
        {
            if (portalAmount > 0.0f && perspective == CameraPerspective.firstPerson)
                appendPortalOverlay(portalAmount);
            hud.appendSurvivalHud(frame, width, height, player, hudTextures,
                blockTextures, hudFont, fontTexture, partialTick);
            hud.appendSelectedItemName(frame,width,height,lastItemHighlight,
                itemHighlightTicks,partialTick,player,hudFont,fontTexture);
        }
        chatRenderer.append(frame,width,height,chat,options);
        if (perspective == CameraPerspective.firstPerson
            && (pauseState is null || !pauseState.active)
            && (inventoryState is null||!inventoryState.active)
            && (deathState is null || !deathState.active))
            frame.append(hud.buildCrosshair(width, height), crosshair.descriptorIndex,
                Mat4.identity(), DrawLayer.invertedOverlay);
        if ((options !is null && options.active && options.fromGame)
            || (pauseState !is null && pauseState.active))
            appendMenuBlur();
        if (options !is null && options.active && options.fromGame)
            optionsMenu.append(frame,width,height,menuMouseX,menuMouseY,
                options,true,optionsTextures,hudFont,fontTexture);
        else if (pauseState !is null && pauseState.active)
            pauseMenu.append(frame, width, height, menuMouseX, menuMouseY,
                canPublish, pauseState, pauseTextures, hudFont, fontTexture);
        if (deathState !is null && deathState.active)
            deathScreen.append(frame,width,height,deathMouseX,deathMouseY,
                deathState,deathTextures,hudFont,fontTexture);
        else if(inventoryState !is null&&inventoryState.active)
            inventoryMenu.append(frame,width,height,inventoryMouseX,
                inventoryMouseY,player.inventory,inventoryTextures,blockTextures,
                hud,hudFont,fontTexture,partialTick,players,player,
                accountSkin.descriptorIndex,elapsedSeconds*20.0f,
                accountSkinModel=="slim");
        lastAssemblyMilliseconds=cast(float)((monotonicSeconds()
            -meshingFinished)*1000.0);
        if(debugVisible)
            appendDebugOverlay(player,debugFps);
        const graphicsStarted=monotonicSeconds();
        graphics.render(frame);
        lastGraphicsMilliseconds=cast(float)((monotonicSeconds()
            -graphicsStarted)*1000.0);
    }

private:
    void tickWaterBlocks(const LocalPlayer player)
    {
        const centerX=cast(int)floorf(player.position.x);
        const centerY=cast(int)floorf(player.position.y);
        const centerZ=cast(int)floorf(player.position.z);
        int chosenX,chosenY,chosenZ;
        uint seen;
        foreach(y;centerY-4..centerY+5)
        foreach(z;centerZ-8..centerZ+9)
        foreach(x;centerX-8..centerX+9)
        {
            const block=world.getBlock(x,y,z);
            if(!isWater(block)||isWaterSource(block)||block==BlockId.waterFalling)
                continue;
            ++seen;
            if(cast(uint)(visualRandom()*seen)==0)
            {chosenX=x;chosenY=y;chosenZ=z;}
        }
        if(seen)
            sounds.randomFlowingWaterAmbient(Vec3(chosenX+0.5f,chosenY+0.5f,
                chosenZ+0.5f));
    }

    void tickPortalBlocks(const LocalPlayer player)
    {
        // Sound and particles share NetherPortalBlock.animateTick, but the old
        // implementation sampled the one-percent sound only once per eight
        // ticks. Sample it every client tick; retain the lower particle rate.
        ++portalDisplayTicks;
        const centerX = cast(int) floorf(player.position.x);
        const centerY = cast(int) floorf(player.position.y);
        const centerZ = cast(int) floorf(player.position.z);
        int chosenX,chosenY,chosenZ;
        BlockId chosen=BlockId.air;
        uint seen;
        foreach (y; centerY-4 .. centerY+5)
        foreach (z; centerZ-8 .. centerZ+9)
        foreach (x; centerX-8 .. centerX+9)
        {
            const block = world.getBlock(x,y,z);
            if (!isNetherPortal(block)) continue;
            ++seen;
            if(cast(uint)(visualRandom()*seen)==0)
            {chosenX=x;chosenY=y;chosenZ=z;chosen=block;}
        }
        if(chosen==BlockId.air)return;
        const source=Vec3(chosenX+0.5f,chosenY+0.5f,chosenZ+0.5f);
        sounds.randomPortalAmbient(source);
        if(portalDisplayTicks%8==0)
            particles.spawnPortalBlock(chosenX,chosenY,chosenZ,
                chosen==BlockId.netherPortalX);
    }

    Vec3 nearestPortalPosition(Vec3 position) const
    {
        const centerX=cast(int)floorf(position.x);
        const centerY=cast(int)floorf(position.y);
        const centerZ=cast(int)floorf(position.z);
        Vec3 best=position;
        float bestDistance=float.max;
        foreach(y;centerY-2..centerY+4)
        foreach(z;centerZ-2..centerZ+3)
        foreach(x;centerX-2..centerX+3)
        {
            if(!isNetherPortal(world.getBlock(x,y,z)))continue;
            const candidate=Vec3(x+0.5f,y+0.5f,z+0.5f);
            const distance=(candidate-position).lengthSquared();
            if(distance<bestDistance){bestDistance=distance;best=candidate;}
        }
        return best;
    }

    float visualRandom()
    {
        visualRandomState^=visualRandomState<<13;
        visualRandomState^=visualRandomState>>17;
        visualRandomState^=visualRandomState<<5;
        return cast(float)(visualRandomState&0x00FFFFFFu)/16777216.0f;
    }

    void appendPortalOverlay(float amount)
    {
        Vertex[] output;
        float alpha=amount;
        if(alpha<1.0f)
        {
            alpha*=alpha;
            alpha*=alpha;
            alpha=alpha*0.8f+0.2f;
        }
        const color = Color(1,1,1,alpha);
        appendQuad(output,Vec3(-1,-1,0),Vec3(1,-1,0),Vec3(1,1,0),
            Vec3(-1,1,0),Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
            color,color,color,color);
        frame.append(output,blockTextures.netherPortal,Mat4.identity(),
            DrawLayer.overlay);
    }

    void appendTranslucentWorld(const Camera camera,uint portalTexture,
        uint stillTexture,uint flowTexture,Mat4 viewProjection,FogSettings fog)
    {
        // Chunk order is back-to-front for alpha blending; section order is
        // reversed as well. All ranges point at the same retained chunk buffer.
        foreach_reverse(index;0..admittedRenderChunks.length)
        {
            const coordinate=admittedRenderChunks[index];
            auto geometry=coordinate in chunkMeshes;
            if(geometry is null)continue;
            foreach_reverse(sectionIndex;0..geometry.sections.length)
            {
                const section=geometry.sections[sectionIndex];
                if(!sectionIntersectsFrustum(camera,coordinate,
                    section.minimumY,section.maximumY))continue;
                appendResidentRange(geometry.mesh,section.portalRange,
                    portalTexture,viewProjection,DrawLayer.translucent,fog);
                appendResidentRange(geometry.mesh,section.glassRange,
                    blockTextures.glass,viewProjection,
                    DrawLayer.translucentCulled,fog);
                appendResidentRange(geometry.mesh,section.waterUndersideRange,
                    stillTexture,viewProjection,DrawLayer.translucent,fog);
                appendResidentRange(geometry.mesh,section.waterSurfaceRange,
                    stillTexture,viewProjection,DrawLayer.translucent,fog);
                appendResidentRange(geometry.mesh,section.waterWallsRange,
                    flowTexture,viewProjection,DrawLayer.translucent,fog);
            }
        }
    }

    void appendResidentRange(MeshHandle mesh,ResidentRange range,uint texture,
        Mat4 transform,DrawLayer layer,FogSettings fog)
    {
        if(range.vertexCount==0)return;
        frame.appendResident(mesh,range.firstVertex,range.vertexCount,texture,
            transform,layer,fog);
        lastResidentVertices+=range.vertexCount;
    }

    bool sectionIntersectsFrustum(const Camera camera,
        ChunkCoordinate coordinate,int minimumY,int maximumY) const
    {
        const forward=forwardFromYawPitch(camera.yaw,camera.pitch);
        const yawForward=forwardFromYawPitch(camera.yaw,0);
        const right=Vec3(yawForward.z,0,-yawForward.x);
        const up=cross(forward,right).normalized();
        const verticalTangent=tanf(camera.fovDegrees*0.5f
            *3.14159265f/180.0f);
        const horizontalTangent=verticalTangent
            *cast(float)width/cast(float)(height==0?1:height);
        const upper=maximumY>=minimumY?maximumY+1:minimumY+1;
        const center=Vec3(coordinate.x*16+8,(minimumY+upper)*0.5f,
            coordinate.z*16+8);
        const extents=Vec3(8,(upper-minimumY)*0.5f,8);
        const relative=center-camera.position;
        const depth=relative.x*forward.x+relative.y*forward.y
            +relative.z*forward.z;
        const side=relative.x*right.x+relative.y*right.y
            +relative.z*right.z;
        const vertical=relative.x*up.x+relative.y*up.y
            +relative.z*up.z;
        const depthRadius=fabsf(forward.x)*extents.x
            +fabsf(forward.y)*extents.y+fabsf(forward.z)*extents.z;
        const sideRadius=fabsf(right.x)*extents.x
            +fabsf(right.y)*extents.y+fabsf(right.z)*extents.z;
        const verticalRadius=fabsf(up.x)*extents.x
            +fabsf(up.y)*extents.y+fabsf(up.z)*extents.z;
        if(depth+depthRadius<0.05f)return false;
        if(fabsf(side)-depth*horizontalTangent
            >sideRadius+depthRadius*horizontalTangent)return false;
        if(fabsf(vertical)-depth*verticalTangent
            >verticalRadius+depthRadius*verticalTangent)return false;
        return true;
    }

    ChunkCoordinate[] visibleChunkCoordinates(const Camera camera) const
    {
        ChunkCoordinate[] result;
        int distance=options.integer("renderDistance",6);
        if(distance<2)distance=2;
        if(distance>12)distance=12;
        const centerX=chunkCoordinate(cast(int)floorf(camera.position.x));
        const centerZ=chunkCoordinate(cast(int)floorf(camera.position.z));
        const forward=forwardFromYawPitch(camera.yaw,camera.pitch);
        // Derive right from yaw rather than cross(up,forward), which becomes
        // degenerate while looking exactly up or down.
        const yawForward=forwardFromYawPitch(camera.yaw,0);
        const right=Vec3(yawForward.z,0,-yawForward.x);
        const up=cross(forward,right).normalized();
        const verticalTangent=tanf(camera.fovDegrees*0.5f
            *3.14159265f/180.0f);
        const horizontalTangent=verticalTangent
            *cast(float)width/cast(float)height;
        foreach(coordinate,geometry;chunkMeshes)
        {
            int dx=coordinate.x-centerX, dz=coordinate.z-centerZ;
            int ax=dx<0?-dx:dx,az=dz<0?-dz:dz;
            if(ax>distance||az>distance)continue;
            const minimumY=geometry.minimumY;
            const maximumY=geometry.maximumY>=minimumY
                ?geometry.maximumY+1:minimumY+1;
            const center=Vec3(coordinate.x*16+8,
                (minimumY+maximumY)*0.5f,coordinate.z*16+8);
            const extents=Vec3(8,(maximumY-minimumY)*0.5f,8);
            const relative=center-camera.position;
            const depth=relative.x*forward.x+relative.y*forward.y
                +relative.z*forward.z;
            const side=relative.x*right.x+relative.y*right.y
                +relative.z*right.z;
            const vertical=relative.x*up.x+relative.y*up.y
                +relative.z*up.z;
            const depthRadius=fabsf(forward.x)*extents.x
                +fabsf(forward.y)*extents.y+fabsf(forward.z)*extents.z;
            const sideRadius=fabsf(right.x)*extents.x
                +fabsf(right.y)*extents.y+fabsf(right.z)*extents.z;
            const verticalRadius=fabsf(up.x)*extents.x
                +fabsf(up.y)*extents.y+fabsf(up.z)*extents.z;
            if(depth+depthRadius<0.05f)continue;
            if(fabsf(side)-depth*horizontalTangent
                >sideRadius+depthRadius*horizontalTangent)continue;
            if(fabsf(vertical)-depth*verticalTangent
                >verticalRadius+depthRadius*verticalTangent)continue;
            result~=coordinate;
        }
        sort!((a,b){
            const adx=a.x-centerX,adz=a.z-centerZ;
            const bdx=b.x-centerX,bdz=b.z-centerZ;
            return adx*adx+adz*adz<bdx*bdx+bdz*bdz;
        })(result);
        return result;
    }

    void appendDebugOverlay(const LocalPlayer player,float fps)
    {
        int scale=1;
        while(scale<8&&width/(scale+1)>=320&&height/(scale+1)>=240)++scale;
        const logicalWidth=cast(float)width/scale;
        const logicalHeight=cast(float)height/scale;
        const milliseconds=fps>0.001f?1000.0f/fps:0.0f;
        const loaded=world.loadedChunkCoordinates().length;
        const lines=[
            format("Minecraft: D Edition  %.0f fps (%.1f ms)",fps,milliseconds),
            format("XYZ: %.2f / %.2f / %.2f",player.position.x,
                player.position.y,player.position.z),
            format("Chunks: %s rendered / %s meshed / %s loaded",
                admittedRenderChunks.length,chunkMeshes.length,loaded),
            format("Vertices: %s resident / %s dynamic  Draw calls: %s",
                lastResidentVertices,frame.vertices.length,frame.draws.length),
            format("CPU mesh: %.1f ms  frame: %.1f ms  graphics: %.1f ms",
                lastMeshMilliseconds,lastAssemblyMilliseconds,
                lastGraphicsMilliseconds),
        ];
        foreach(index,line;lines)
            frame.append(hudFont.buildText(line,4,4+cast(int)index*10,
                    logicalWidth,logicalHeight,Color(1,1,1,1)),
                fontTexture,Mat4.identity(),DrawLayer.overlay);
    }

    void syncChunkMeshes(Vec3 position,float yaw,int maximumSections)
    {
        ChunkCoordinate[] stale;
        foreach(coordinate,geometry;chunkMeshes)
            if(!world.hasChunk(coordinate.x,coordinate.z))stale~=coordinate;
        foreach(coordinate;stale)
        {
            auto geometry=coordinate in chunkMeshes;
            if(geometry !is null)graphics.releaseStaticMesh(geometry.mesh);
            chunkMeshes.remove(coordinate);
        }

        if(meshJobActive&&(!world.hasChunk(meshJobCoordinate.x,
            meshJobCoordinate.z)||world.chunkRevision(meshJobCoordinate.x,
                meshJobCoordinate.z)!=meshJobRevision))
            meshJobActive=false;

        const centerX=chunkCoordinate(cast(int)floorf(position.x));
        const centerZ=chunkCoordinate(cast(int)floorf(position.z));
        const meshFacing=forwardFromYawPitch(yaw,0);
        foreach(sectionIndex;0..maximumSections)
        {
            if(!meshJobActive)
            {
                bool found;
                ChunkCoordinate best;
                int bestDistance=int.max;
                foreach(coordinate;world.loadedChunkCoordinates())
                {
                    const expected=world.chunkRevision(coordinate.x,coordinate.z);
                    auto cached=coordinate in chunkMeshes;
                    if(cached !is null&&cached.revision==expected)continue;
                    const dx=coordinate.x-centerX,dz=coordinate.z-centerZ;
                    int distance=dx*dx+dz*dz;
                    if(dx*meshFacing.x+dz*meshFacing.z<0)distance+=10_000;
                    if(!found||distance<bestDistance)
                    {found=true;best=coordinate;bestDistance=distance;}
                }
                if(!found)break;
                const loaded=world.chunkAt(best.x,best.z);
                if(loaded is null)continue;
                if(loaded.empty)
                {
                    RenderChunkGeometry empty;
                    empty.revision=world.chunkRevision(best.x,best.z);
                    if(auto previous=best in chunkMeshes)
                        graphics.releaseStaticMesh(previous.mesh);
                    chunkMeshes[best]=empty;
                    continue;
                }
                meshJobActive=true;
                meshJobCoordinate=best;
                meshJobNextY=loaded.minimumOccupiedY();
                meshJobMaximumY=loaded.maximumOccupiedY();
                meshJobRevision=world.chunkRevision(best.x,best.z);
                meshJobGeometry=RenderChunkGeometry.init;
                meshJobGeometry.minimumY=meshJobNextY;
                meshJobGeometry.maximumY=meshJobMaximumY;
            }

            int sectionMaximum=meshJobNextY+15;
            if(sectionMaximum>meshJobMaximumY)sectionMaximum=meshJobMaximumY;
            RenderChunkSection section;
            section.minimumY=meshJobNextY;
            section.maximumY=sectionMaximum;
            section.blocks=blocks.buildChunkRange(blockTextures,
                meshJobCoordinate,meshJobNextY,sectionMaximum);
            section.portals=blocks.buildPortalsChunkRange(
                meshJobCoordinate,meshJobNextY,sectionMaximum);
            section.water=blocks.buildWaterChunkRange(meshJobCoordinate,
                meshJobNextY,sectionMaximum);
            meshJobGeometry.sections~=section;
            meshJobNextY=sectionMaximum+1;
            if(meshJobNextY>meshJobMaximumY)
            {
                if(world.chunkRevision(meshJobCoordinate.x,
                    meshJobCoordinate.z)==meshJobRevision)
                {
                    meshJobGeometry.revision=meshJobRevision;
                    finalizeChunkGeometry(meshJobGeometry);
                    if(auto previous=meshJobCoordinate in chunkMeshes)
                        graphics.releaseStaticMesh(previous.mesh);
                    chunkMeshes[meshJobCoordinate]=meshJobGeometry;
                }
                meshJobActive=false;
            }
        }
    }

    void finalizeChunkGeometry(ref RenderChunkGeometry geometry)
    {
        size_t vertexCount;
        foreach(section;geometry.sections)
        {
            foreach(unused,vertices;section.blocks)vertexCount+=vertices.length;
            vertexCount+=section.portals.length+section.water.underside.length
                +section.water.surface.length+section.water.walls.length;
        }
        Vertex[] packed;
        packed.reserve(vertexCount);
        foreach(ref section;geometry.sections)
        {
            section.opaqueRanges.length=0;
            section.glassRange=ResidentRange.init;
            foreach(texture,vertices;section.blocks)
            {
                ResidentRange range;
                appendPackedRange(packed,range,vertices,texture);
                if(texture==blockTextures.glass)section.glassRange=range;
                else if(range.vertexCount)section.opaqueRanges~=range;
            }
            appendPackedRange(packed,section.portalRange,section.portals,
                blockTextures.netherPortal);
            appendPackedRange(packed,section.waterUndersideRange,
                section.water.underside,blockTextures.waterStill);
            appendPackedRange(packed,section.waterSurfaceRange,
                section.water.surface,blockTextures.waterStill);
            appendPackedRange(packed,section.waterWallsRange,
                section.water.walls,blockTextures.waterFlow);
        }
        const replacement=graphics.uploadStaticMesh(packed);
        const previous=geometry.mesh;
        geometry.mesh=replacement;
        geometry.vertexCount=cast(uint)packed.length;
        if(previous.valid)graphics.releaseStaticMesh(previous);
    }

    static void appendPackedRange(ref Vertex[] packed,ref ResidentRange range,
        const(Vertex)[] source,uint texture)
    {
        range=ResidentRange(cast(uint)packed.length,cast(uint)source.length,
            texture);
        packed~=source;
    }

    void clearChunkMeshes()
    {
        if(graphics !is null)
            foreach(coordinate,geometry;chunkMeshes)
                graphics.releaseStaticMesh(geometry.mesh);
        chunkMeshes.clear();
    }

    void appendHeldBlock(ItemStack stack,Vec3 position,float bodyYawDegrees,
        bool rightHand,float walkPosition,float walkSpeed,float attackProgress,
        bool crouching,float ageInTicks,bool slimArms,Mat4 viewProjection,
        FogSettings fog)
    {
        auto heldMesh=stack.item in itemMeshes;
        if(heldMesh is null)return;
        const model=players.thirdPersonHeldItemTransform(
            stack.item==ItemId.flintAndSteel,position,bodyYawDegrees,rightHand,
            walkPosition,walkSpeed,attackProgress,crouching,ageInTicks,
            slimArms);
        foreach(textureIndex,geometry;*heldMesh)
            frame.append(geometry,textureIndex,model*viewProjection,
                stackLayer(stack.item,textureIndex),fog);
    }

    void discardCachedBlockFaces(int x,int y,int z,BlockId oldBlock)
    {
        const coordinate=ChunkCoordinate(chunkCoordinate(x),chunkCoordinate(z));
        auto cached=coordinate in chunkMeshes;
        if(cached is null)return;
        // Limit removal to textures used by the broken block. This avoids
        // touching a differently textured neighbor face sharing its boundary
        // (most notably an opaque block immediately behind glass).
        const blockModel=blocks.buildItem(oldBlock,blockTextures);
        bool changed;
        foreach(texture,unused;blockModel)
        {
            foreach(ref section;cached.sections)
            {
                if(y<section.minimumY||y>section.maximumY)continue;
                auto geometry=texture in section.blocks;
                if(geometry is null)continue;
                const before=geometry.length;
                removeBlockFaceQuads(*geometry,x,y,z);
                changed=changed||geometry.length!=before;
            }
        }
        if(changed)finalizeChunkGeometry(*cached);
    }

    static void removeBlockFaceQuads(ref Vertex[] geometry,int x,int y,int z)
    {
        Vertex[] retained;
        retained.reserve(geometry.length);
        size_t offset;
        for(;offset+6<=geometry.length;offset+=6)
        {
            bool belongs=true;
            foreach(vertex;geometry[offset..offset+6])
            {
                const px=vertex.position[0],py=vertex.position[1],
                    pz=vertex.position[2];
                if(px<x||px>x+1||py<y||py>y+1||pz<z||pz>z+1)
                {belongs=false;break;}
            }
            if(!belongs)retained~=geometry[offset..offset+6];
        }
        if(offset<geometry.length)retained~=geometry[offset..$];
        geometry=retained;
    }

    DrawLayer stackLayer(ItemId item, uint textureIndex) const
    {
        return item == ItemId.glass || textureIndex == blockTextures.glass
            ? DrawLayer.translucentCulled : DrawLayer.world;
    }

    void appendMenuBlur()
    {
        Vertex[] output;
        const white = Color(1,1,1,1);
        appendQuad(output,
            Vec3(-1, 1, 0), Vec3(1, 1, 0), Vec3(1,-1,0), Vec3(-1,-1,0),
            Vec2(0,0), Vec2(1,0), Vec2(1,1), Vec2(0,1),
            white,white,white,white);
        const setting = options is null ? 5
            : options.integer("menuBackgroundBlurriness",5);
        frame.append(output,graphics.menuBlurTexture().descriptorIndex,
            Mat4.identity(),DrawLayer.blurBackdrop,
            FogSettings.blur(width,height,0.5f+cast(float)setting*0.45f));
    }

    static void applyHurtTint(ref Vertex[] geometry, int hurtTime, bool dead)
    {
        if (hurtTime <= 0 && !dead)
            return;
        foreach (ref vertex; geometry)
        {
            vertex.color[0] = 1.0f;
            vertex.color[1] *= 0.25f;
            vertex.color[2] *= 0.25f;
        }
    }

    void updateHeldItem(const LocalPlayer player)
    {
        previousMainHandHeight = mainHandHeight;
        ItemStack selected;
        if (player.selectedSlot >= 0
            && player.selectedSlot < player.inventory.hotbar.length)
            selected = player.inventory.hotbar[player.selectedSlot];
        const sameStack = sameHeldStack(selected, displayedMainHand);
        const targetHeight = sameStack ? 1.0f : 0.0f;
        mainHandHeight += clamp(targetHeight - mainHandHeight, -0.4f, 0.4f);
        if (mainHandHeight < 0.1f && !sameStack)
            displayedMainHand = selected;
    }

    void cancelMining()
    {
        mining = false;
        miningProgress = 0.0f;
        miningTicks = 0;
    }

    TextureHandle loadHandle(string relativePath)
    {
        return graphics.uploadTexture(images.loadPng(resources.resolveAsset("minecraft", relativePath)));
    }

    uint[] loadAnimatedFrames(string relativePath)
    {
        auto source = images.loadPng(resources.resolveAsset("minecraft",
            relativePath));
        const side = source.width < source.height ? source.width : source.height;
        const frameCount = source.height / side;
        uint[] result;
        foreach (frameIndex; 0 .. frameCount)
        {
            ImageData frameImage;
            frameImage.width = frameImage.height = side;
            frameImage.rgba.length = cast(size_t) side * side * 4;
            foreach (row; 0 .. side)
            {
                const sourceStart = (cast(size_t)frameIndex*side+row)
                    * source.width * 4;
                const destinationStart = cast(size_t) row * side * 4;
                frameImage.rgba[destinationStart .. destinationStart + side*4]
                    = source.rgba[sourceStart .. sourceStart + side*4];
            }
            result ~= graphics.uploadTexture(frameImage).descriptorIndex;
        }
        return result;
    }

    uint load(string relativePath)
    {
        return loadHandle(relativePath).descriptorIndex;
    }

    uint loadFrom(string namespaceName, string relativePath)
    {
        return graphics.uploadTexture(images.loadPng(
            resources.resolveAsset(namespaceName, relativePath))).descriptorIndex;
    }
}

unittest
{
    Vertex[] geometry;
    const white=Color(1,1,1,1);
    appendQuad(geometry,
        Vec3(1,2,3),Vec3(2,2,3),Vec3(2,3,3),Vec3(1,3,3),
        Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
        white,white,white,white);
    appendQuad(geometry,
        Vec3(5,2,3),Vec3(6,2,3),Vec3(6,3,3),Vec3(5,3,3),
        Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
        white,white,white,white);
    assert(geometry.length==12);
    GameRenderer.removeBlockFaceQuads(geometry,1,2,3);
    assert(geometry.length==6);
    foreach(vertex;geometry)
        assert(vertex.position[0]>=5.0f);
}
