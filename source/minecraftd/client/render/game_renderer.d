module minecraftd.client.render.game_renderer;

import core.stdc.math : floorf, sinf;
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
    FrameMesh, Vertex, appendQuad;
import minecraftd.common.math3d : Mat4, Vec2, Vec3, clamp, forwardFromYawPitch, lerp;
import minecraftd.client.render.player_renderer : PlayerRenderer, SkinLayers;
import minecraftd.client.render.sky_renderer : SkyRenderer;
import minecraftd.client.render.texture_manager : ImageData, TextureManager;
import minecraftd.client.render.title_screen_renderer : TitleAction,
    MultiplayerMenuAction, TitleScreenRenderer, TitleTextureSet,
    WorldMenuAction;
import minecraftd.client.menu.multiplayer_menu_state : MultiplayerMenuState;
import minecraftd.client.menu.world_menu_state : WorldMenuState;
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
import minecraftd.platform.windows.dx12.device : Dx12Device;
import minecraftd.platform.windows.dx12.gpu_resource : TextureHandle;
import minecraftd.world.block : BlockId, bareHandDestroyProgress,
    isNetherPortal, isWater, isWaterSource;
import minecraftd.world.world : BlockHit, World;
import minecraftd.world.world_settings : GameMode;
import minecraftd.world.world_settings : DimensionId;

enum CameraPerspective : ubyte
{
    firstPerson,
    thirdPersonBack,
    thirdPersonFront,
}

/// Coordinates the same broad passes as Minecraft's client renderer: sky,
/// opaque world geometry, entities, and a camera-space first-person hand.
final class GameRenderer
{
    private uint width;
    private uint height;
    private Dx12Device graphics;
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
    private Vertex[][uint] blockMeshes;
    private Vertex[] portalMesh;
    private WaterGeometry waterGeometry;
    private uint[] portalFrames;
    private uint[] waterStillFrames;
    private uint[] waterFlowFrames;
    private uint meshedWorldRevision;
    private Vertex[][uint][ItemId] itemMeshes;
    private BlockTextureSet blockTextures;

    private TextureHandle steve;
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

    this(HWND window, uint width, uint height, string projectRoot, World world,
        OptionsMenuState options)
    {
        this.width = width;
        this.height = height;
        this.world = world;
        this.options = options;
        resources = new ResourceManager(projectRoot);
        images = new TextureManager();
        graphics = new Dx12Device(window, width, height);
        blocks = new BlockRenderer(world);
        players = new PlayerRenderer();
        entityShadows = new EntityShadowRenderer(world);
        hud = new HudRenderer();
        titleScreen = new TitleScreenRenderer();
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
            waterStillFrames[0],
            waterFlowFrames[0],
            portalFrames[0],
            flintTexture.descriptorIndex,
        );
        steve = loadHandle("textures/entity/player/wide/steve.png");
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
        blockMeshes = blocks.build(blockTextures);
        portalMesh = blocks.buildPortals();
        waterGeometry = blocks.buildWater();
        meshedWorldRevision = world.revision;
        itemMeshes[ItemId.grassBlock] = blocks.buildItem(BlockId.grass, blockTextures);
        itemMeshes[ItemId.dirt] = blocks.buildItem(BlockId.dirt, blockTextures);
        itemMeshes[ItemId.stone] = blocks.buildItem(BlockId.stone, blockTextures);
        itemMeshes[ItemId.obsidian] = blocks.buildItem(BlockId.obsidian,
            blockTextures);
        itemMeshes[ItemId.netherrack] = blocks.buildItem(BlockId.netherrack,
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

    MultiplayerMenuAction multiplayerMenuActionAt(int mouseX, int mouseY) const
    {
        return titleScreen.multiplayerHitTest(width, height, mouseX, mouseY);
    }

    WorldMenuAction worldMenuActionAt(int mouseX, int mouseY,
        const WorldMenuState state) const
    {
        return titleScreen.worldMenuHitTest(width,height,mouseX,mouseY,state);
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
            blocks.configure(options.integer("ao",2)!=0,
                options.number("gamma",0.5f));
            meshedWorldRevision=uint.max;
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
        blockMeshes = blocks.build(blockTextures);
        portalMesh = blocks.buildPortals();
        waterGeometry = blocks.buildWater();
        meshedWorldRevision = world.revision;
        cancelMining();
    }

    void render(LocalPlayer player, const ChatState chat,
        MultiplayerClient multiplayer, float partialTick, float elapsedSeconds,
        const PauseMenuState pauseState = null, int menuMouseX = 0,
        int menuMouseY = 0, bool canPublish = false,
        const DeathScreenState deathState = null, int deathMouseX = 0,
        int deathMouseY = 0,const InventoryMenuState inventoryState=null,
        int inventoryMouseX=0,int inventoryMouseY=0)
    {
        const frameSeconds = elapsedSeconds >= previousElapsedSeconds
            ? elapsedSeconds - previousElapsedSeconds : 0.0f;
        previousElapsedSeconds = elapsedSeconds;
        multiplayer.advanceDroppedItems(frameSeconds > 0.1f ? 0.1f : frameSeconds);
        if (meshedWorldRevision != world.revision)
        {
            blockMeshes = blocks.build(blockTextures);
            portalMesh = blocks.buildPortals();
            waterGeometry = blocks.buildWater();
            meshedWorldRevision = world.revision;
        }
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
        auto terrainFog = player.dimension == DimensionId.nether
            ? FogSettings.distance(camera.position,10.0f,48.0f)
            : FogSettings.distance(camera.position,48.0f,80.0f);
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

        foreach (textureIndex, geometry; blockMeshes)
            frame.append(geometry, textureIndex, viewProjection,
                DrawLayer.world, terrainFog);
        if (portalMesh.length && portalFrames.length)
        {
            const portalFrame = cast(size_t)(elapsedSeconds * 20.0f)
                % portalFrames.length;
            frame.append(portalMesh,portalFrames[portalFrame],viewProjection,
                DrawLayer.world,terrainFog);
        }
        const waterFrame=cast(size_t)(elapsedSeconds*10.0f);
        const stillTexture=waterStillFrames.length
            ?waterStillFrames[waterFrame%waterStillFrames.length]
            :blockTextures.waterStill;
        const flowTexture=waterFlowFrames.length
            ?waterFlowFrames[waterFrame%waterFlowFrames.length]
            :blockTextures.waterFlow;
        // Vertical faces establish the volume; the exposed horizontal sheet
        // is deliberately last so it cannot disappear due to bucket ordering.
        frame.append(waterGeometry.underside,stillTexture,viewProjection,
            DrawLayer.translucent,terrainFog);
        frame.append(waterGeometry.walls,flowTexture,viewProjection,
            DrawLayer.translucent,terrainFog);
        frame.append(waterGeometry.surface,stillTexture,viewProjection,
            DrawLayer.translucent,terrainFog);

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
                DrawLayer.world, terrainFog);

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
                    DrawLayer.world, terrainFog);
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
                     !remoteHeld.empty(),remote.mainHandRight,remote.swimming);
            if (remote.gameMode != GameMode.spectator)
                players.applyDeathPose(geometry,
                    remote.interpolatedPosition(partialTick),
                    remote.interpolatedBodyYaw(partialTick)+180.0f,
                    remote.interpolatedDeathTime(partialTick));
            applyHurtTint(geometry, remote.hurtTime, remote.health <= 0.0f);
            frame.append(geometry, steve.descriptorIndex, viewProjection,
                remote.gameMode == GameMode.spectator
                    ? DrawLayer.entityShadow : DrawLayer.world, terrainFog);
            if(remote.gameMode!=GameMode.spectator&&!remoteHeld.empty())
                appendHeldBlock(remoteHeld,remote.interpolatedPosition(partialTick),
                    remote.interpolatedBodyYaw(partialTick)+180.0f,
                    remote.mainHandRight,remote.interpolatedWalkAnimationPosition(partialTick),
                    remote.interpolatedWalkAnimationSpeed(partialTick),
                    remote.interpolatedAttackProgress(partialTick),remote.crouching,
                    elapsedSeconds*20.0f,viewProjection,terrainFog);
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
                     !displayedMainHand.empty(),player.mainHandRight,player.swimming);
            if (player.gameMode != GameMode.spectator)
                players.applyDeathPose(geometry,localPosition,modelBodyYaw,
                    player.interpolatedDeathTime(partialTick));
            applyHurtTint(geometry, player.hurtTime, player.health <= 0.0f);
            if(!(player.health<=0&&player.deathTime>=20))
                frame.append(geometry, steve.descriptorIndex, viewProjection,
                    player.gameMode == GameMode.spectator
                        ? DrawLayer.entityShadow : DrawLayer.world, terrainFog);
            if(player.gameMode!=GameMode.spectator&&!displayedMainHand.empty()
                &&player.health>0)
                appendHeldBlock(displayedMainHand,localPosition,modelBodyYaw,
                    player.mainHandRight,
                    player.interpolatedWalkAnimationPosition(partialTick),
                    player.interpolatedWalkAnimationSpeed(partialTick),
                    player.interpolatedAttackProgress(partialTick),player.crouching,
                    elapsedSeconds*20.0f,viewProjection,terrainFog);
        }
        else
        {
            const equipProgress = 1.0f - lerp(partialTick,
                previousMainHandHeight, mainHandHeight);
            // View bob and fall pitch share the smoothed camera-space transform
            // used by the world, so the hand never snaps when leaving the ground.
            const handProjection = players.firstPersonArmTransform(
                    player.interpolatedAttackProgress(partialTick), aspect,
                    equipProgress)
                * players.firstPersonLookSwayTransform(
                    player.viewPitchSway(partialTick), player.viewYawSway(partialTick))
                * camera.effectsMatrix(player, partialTick, options.viewBobbing)
                * camera.viewModelProjectionMatrix(aspect);
            if (displayedMainHand.empty() && player.health > 0.0f
                && player.gameMode != GameMode.spectator)
            {
                const sleeveBit=player.mainHandRight?Player.skinRightSleeve
                    :Player.skinLeftSleeve;
                frame.append(players.buildFirstPersonArm(
                        (player.skinParts&sleeveBit)!=0), steve.descriptorIndex,
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
                    const itemProjection = itemPose
                        * players.firstPersonLookSwayTransform(
                            player.viewPitchSway(partialTick),
                            player.viewYawSway(partialTick))
                        * camera.effectsMatrix(player, partialTick,
                            options.viewBobbing)
                        * camera.viewModelProjectionMatrix(aspect);
                    foreach (textureIndex, geometry; *heldMesh)
                        frame.append(geometry, textureIndex, itemProjection,
                            DrawLayer.viewModel);
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
            const layer = remote.crouching ? DrawLayer.world
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
                steve.descriptorIndex,elapsedSeconds*20.0f);
        graphics.render(frame);
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

    void appendHeldBlock(ItemStack stack,Vec3 position,float bodyYawDegrees,
        bool rightHand,float walkPosition,float walkSpeed,float attackProgress,
        bool crouching,float ageInTicks,Mat4 viewProjection,FogSettings fog)
    {
        auto heldMesh=stack.item in itemMeshes;
        if(heldMesh is null)return;
        const model=players.thirdPersonHeldItemTransform(
            stack.item==ItemId.flintAndSteel,position,bodyYawDegrees,rightHand,
            walkPosition,walkSpeed,attackProgress,crouching,ageInTicks);
        foreach(textureIndex,geometry;*heldMesh)
            frame.append(geometry,textureIndex,model*viewProjection,
                DrawLayer.world,fog);
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
