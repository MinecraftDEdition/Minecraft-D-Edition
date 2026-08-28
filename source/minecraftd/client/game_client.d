module minecraftd.client.game_client;

version (Windows)
    import core.sys.windows.com : CoInitializeEx, CoUninitialize,
        COINIT_MULTITHREADED;
import std.file : thisExePath;
import std.math : fmin;
import std.conv : to;
import std.process : Config, spawnProcess, thisProcessID;

import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.client.chat.chat_state : ChatState;
import minecraftd.client.network.game_connection : GameConnection,
    ServerEndpoint, parseServerAddress;
import minecraftd.client.network.eos_service : EosHostBridge, EosService,
    EosStatus;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.render.game_renderer : GameRenderer;
import minecraftd.client.render.graphics_device : GraphicsApi;
import minecraftd.client.render.title_screen_renderer : TitleAction;
import minecraftd.client.render.title_screen_renderer : MultiplayerMenuAction;
import minecraftd.client.render.title_screen_renderer : WorldMenuAction;
import minecraftd.client.menu.multiplayer_menu_state : MultiplayerField,
    MultiplayerMenuState;
import minecraftd.client.menu.world_menu_state : WorldCreationTab, WorldField,
    WorldMenuScreen, WorldMenuState;
import minecraftd.client.menu.pause_menu : PauseAction, PauseMenuState,
    PauseScreen;
import minecraftd.client.menu.death_screen : DeathAction, DeathScreenState;
import minecraftd.client.menu.options_menu : OptionsAction, OptionsMenuState;
import minecraftd.client.menu.inventory_menu:InventoryMenuState;
import minecraftd.platform.clock : monotonicMilliseconds, monotonicSeconds,
    sleepMilliseconds;
import minecraftd.platform.input;
import minecraftd.platform.paths : platformPaths;
import minecraftd.platform.window : CursorShape, GameWindow;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : WorldEntry, WorldType,
    saveWorldMetadata;
import minecraftd.network.game_protocol : PlayerActionType,PlayerInputCommand, inputAttack,
    inputBack, inputCrouch, inputForward, inputJump, inputLeft, inputRight,
    inputSprint;
import std.socket : SocketOSException;

final class GameClient
{
    void run(int localTestIndex = 0, string rendererOverride = "")
    {
        version (Windows)
        {
            const comResult = CoInitializeEx(null, COINIT_MULTITHREADED);
            if (comResult < 0)
                throw new Exception("COM initialization failed");
            scope (exit) CoUninitialize();
        }

        const paths = platformPaths();
        auto options = new OptionsMenuState(paths.userData);
        scope (exit) destroy(options);
        auto window = new GameWindow("Minecraft: D Edition",
            GameWindow.defaultWidth, GameWindow.defaultHeight, localTestIndex);
        scope (exit) destroy(window);
        if (localTestIndex == 0)
            window.setFullscreen(options.fullscreen);
        auto world = new World();
        scope (exit) destroy(world);
        auto player = new LocalPlayer();
        scope (exit) destroy(player);
        GraphicsApi graphicsApi = options.integer("graphicsApi", 0) == 1
            ? GraphicsApi.vulkan : GraphicsApi.directX12;
        version (OSX) graphicsApi = GraphicsApi.vulkan;
        if (rendererOverride == "vulkan") graphicsApi = GraphicsApi.vulkan;
        else if (rendererOverride == "dx12") graphicsApi = GraphicsApi.directX12;
        auto renderer = new GameRenderer(window.handle, window.width,
            window.height, paths.resources, world, options, graphicsApi);
        scope (exit) destroy(renderer);
        auto eos = new EosService("Steve");
        scope (exit) destroy(eos);

        bool initialSession = true;
        while (window.running)
        {
        IntegratedGameServer integratedServer;
        EosHostBridge eosHostBridge;
        GameConnection gameConnection;
        string connectionHost = "127.0.0.1";
        ushort connectionPort = GameConnection.defaultPort;
        ServerEndpoint connectionEndpoint;
        connectionEndpoint.host = connectionHost;
        connectionEndpoint.port = connectionPort;
        connectionEndpoint.valid = true;
        auto serverMenu = new MultiplayerMenuState();
        scope (exit) destroy(serverMenu);
        auto worldMenu = new WorldMenuState(paths.userData);
        scope (exit) destroy(worldMenu);
        bool multiplayerScreen = initialSession && localTestIndex > 0;
        initialSession = false;
        bool worldScreen;

        bool startLocalWorld(const WorldEntry entry)
        {
            try
            {
                renderer.renderLoadingScreen("Preparing world", 0);
                integratedServer = new IntegratedGameServer(entry.settings,
                    entry.directory, (int percent) {
                        window.pumpMessages();
                        eos.tick();
                        renderer.renderLoadingScreen("Generating world", percent);
                    });
                connectionPort = integratedServer.port;
                connectionEndpoint.host = connectionHost;
                connectionEndpoint.port = connectionPort;
                connectionEndpoint.eos = false;
                connectionEndpoint.valid = true;
                gameConnection = new GameConnection("Steve",
                    connectionHost, connectionPort);
                return true;
            }
            catch (SocketOSException)
            {
                if (integratedServer !is null)
                {
                    destroy(integratedServer);
                    integratedServer = null;
                }
                renderer.setTitleNotice("Unable to start the local world server");
                return false;
            }
        }
        window.setMouseCapture(false);
        while (window.running && gameConnection is null)
        {
            window.pumpMessages();
            eos.tick();
            if (!window.running)
                break;
            int resizedWidth;
            int resizedHeight;
            if (window.consumeResize(resizedWidth, resizedHeight))
                renderer.resize(resizedWidth, resizedHeight);
            if (window.pressed(VK_F11))
            {
                window.toggleFullscreen();
                options.fullscreen = window.fullscreen;
                options.save();
                renderer.resize(window.width, window.height);
            }
            renderer.tickMenuMusic();
            const cursor = window.cursorPosition();
            const menuTime = cast(float) monotonicMilliseconds() / 1000.0f;
            if (options.active && !options.fromGame)
            {
                const hovered = renderer.optionsActionAt(cursor.x,cursor.y);
                window.setCursorShape(hovered == OptionsAction.none
                    || !options.allowCursorChanges ? CursorShape.arrow
                    : (options.slider(hovered) ? CursorShape.horizontalResize
                        : CursorShape.hand));
                options.scroll(window.consumeWheelSteps(),window.width,window.height);
                if (options.bindingCapture != OptionsAction.none)
                {
                    const captured = window.firstPressedKey();
                    if (captured == VK_ESCAPE) options.cancelBindingCapture();
                    else if (captured >= 0) options.captureKey(captured);
                }
                else if (window.pressed(VK_ESCAPE))
                    options.back();
                else if (hovered != OptionsAction.none
                    && options.slider(hovered) && window.down(VK_LBUTTON))
                {
                    if (window.pressed(VK_LBUTTON)) renderer.playUiButtonClick();
                    options.adjustSlider(hovered,cursor.x,window.width,window.height);
                    renderer.applyOptions();
                }
                else if (window.pressed(VK_LBUTTON)
                    && hovered != OptionsAction.none)
                {
                    renderer.playUiButtonClick();
                    options.activate(hovered);
                    renderer.applyOptions();
                    if (hovered == OptionsAction.fullscreen)
                    {
                        window.setFullscreen(options.fullscreen);
                        renderer.resize(window.width,window.height);
                    }
                }
                renderer.renderOptionsScreen(cursor.x,cursor.y,menuTime);
                continue;
            }
            if (worldScreen)
            {
                const hovered = renderer.worldMenuActionAt(cursor.x,cursor.y,worldMenu);
                const textAction = hovered == WorldMenuAction.name
                    || hovered == WorldMenuAction.seed;
                window.setCursorShape(textAction ? CursorShape.text
                    : (hovered == WorldMenuAction.none ? CursorShape.arrow : CursorShape.hand));
                worldMenu.insertCharacters(window.consumeTextInput());
                if (window.pressed(VK_BACK)) worldMenu.backspace();
                if (window.shortcutDown() && window.pressed('V'))
                    worldMenu.insertCharacters(window.clipboardText());
                if (window.pressed(VK_ESCAPE))
                {
                    if (worldMenu.screen == WorldMenuScreen.selection)
                        worldScreen = false;
                    else
                    {
                        worldMenu.screen = WorldMenuScreen.selection;
                        worldMenu.field = WorldField.none;
                        worldMenu.refresh();
                    }
                }
                if (window.pressed(VK_LBUTTON))
                {
                    if (hovered != WorldMenuAction.none) renderer.playUiButtonClick();
                    final switch (hovered)
                    {
                        case WorldMenuAction.worldList:
                            const row = renderer.worldRowAt(cursor.y,worldMenu);
                            if (row >= 0) worldMenu.selected = row;
                            break;
                        case WorldMenuAction.play:
                            if (worldMenu.hasSelection)
                                startLocalWorld(worldMenu.worlds[worldMenu.selected]);
                            break;
                        case WorldMenuAction.create: worldMenu.beginCreate(); break;
                        case WorldMenuAction.edit: worldMenu.beginEdit(); break;
                        case WorldMenuAction.deleteWorld:
                            if (worldMenu.hasSelection)
                                worldMenu.screen = WorldMenuScreen.confirmDelete;
                            break;
                        case WorldMenuAction.recreate: worldMenu.beginRecreate(); break;
                        case WorldMenuAction.cancel: worldScreen = false; break;
                        case WorldMenuAction.tabGame: worldMenu.tab=WorldCreationTab.game; worldMenu.field=WorldField.none; break;
                        case WorldMenuAction.tabWorld: worldMenu.tab=WorldCreationTab.world; worldMenu.field=WorldField.none; break;
                        case WorldMenuAction.tabMore: worldMenu.tab=WorldCreationTab.more; worldMenu.field=WorldField.none; break;
                        case WorldMenuAction.name: worldMenu.field=WorldField.name; break;
                        case WorldMenuAction.seed: if(!worldMenu.editing) worldMenu.field=WorldField.seed; break;
                        case WorldMenuAction.mode: worldMenu.cycleMode(); break;
                        case WorldMenuAction.difficulty: worldMenu.cycleDifficulty(); break;
                        case WorldMenuAction.commands:
                            if(!worldMenu.draft.hardcore) worldMenu.draft.allowCommands=!worldMenu.draft.allowCommands;
                            break;
                        case WorldMenuAction.worldType:
                            if(!worldMenu.editing) worldMenu.draft.worldType=worldMenu.draft.worldType==WorldType.normal?WorldType.flat:WorldType.normal;
                            break;
                        case WorldMenuAction.structures:
                            if(!worldMenu.editing) worldMenu.draft.generateStructures=!worldMenu.draft.generateStructures;
                            break;
                        case WorldMenuAction.bonusChest:
                            if(!worldMenu.editing) worldMenu.draft.bonusChest=!worldMenu.draft.bonusChest;
                            break;
                        case WorldMenuAction.gameRules:
                            worldMenu.notice="Game-rule editing will expand as rule systems are added.";
                            break;
                        case WorldMenuAction.dataPacks:
                            worldMenu.notice="Data packs require custom registries and are not active yet.";
                            break;
                        case WorldMenuAction.confirmCreate:
                        {
                            const directory = worldMenu.prepareFolder();
                            if (worldMenu.editing)
                            {
                                saveWorldMetadata(directory,worldMenu.draft);
                                worldMenu.screen=WorldMenuScreen.selection;
                                worldMenu.refresh();
                            }
                            else
                            {
                                if (worldMenu.draft.seed == 0)
                                    worldMenu.draft.seed = cast(long)monotonicMilliseconds()
                                        ^ (cast(long)thisProcessID << 32);
                                const entry = WorldEntry(worldMenu.draft,directory);
                                startLocalWorld(entry);
                            }
                            break;
                        }
                        case WorldMenuAction.cancelCreate:
                            worldMenu.screen=WorldMenuScreen.selection; worldMenu.refresh(); break;
                        case WorldMenuAction.confirmDelete:
                            import minecraftd.world.world_settings : deleteWorld;
                            if(worldMenu.hasSelection) deleteWorld(worldMenu.worlds[worldMenu.selected]);
                            worldMenu.screen=WorldMenuScreen.selection; worldMenu.refresh(); break;
                        case WorldMenuAction.cancelDelete:
                            worldMenu.screen=WorldMenuScreen.selection; break;
                        case WorldMenuAction.none: break;
                    }
                }
                renderer.renderWorldMenu(cursor.x,cursor.y,worldMenu);
                continue;
            }
            if (multiplayerScreen)
            {
                const hovered = renderer.multiplayerMenuActionAt(
                    cursor.x, cursor.y);
                const overText = hovered == MultiplayerMenuAction.serverName
                    || hovered == MultiplayerMenuAction.serverAddress;
                window.setCursorShape(overText ? CursorShape.text
                    : (hovered == MultiplayerMenuAction.none
                        ? CursorShape.arrow : CursorShape.hand));
                serverMenu.insertCharacters(window.consumeTextInput());
                if (window.shortcutDown() && window.pressed('V'))
                    serverMenu.paste(window.clipboardText());
                if (window.pressed(VK_TAB))
                    serverMenu.selectNextField();

                bool connectRequested = window.pressed(VK_RETURN);
                if (window.pressed(VK_ESCAPE))
                {
                    multiplayerScreen = false;
                    serverMenu.error = "";
                }
                if (window.pressed(VK_LBUTTON))
                {
                    final switch (hovered)
                    {
                        case MultiplayerMenuAction.serverName:
                            serverMenu.activate(MultiplayerField.serverName);
                            break;
                        case MultiplayerMenuAction.serverAddress:
                            serverMenu.activate(MultiplayerField.serverAddress);
                            break;
                        case MultiplayerMenuAction.connect:
                            renderer.playUiButtonClick();
                            connectRequested = true;
                            break;
                        case MultiplayerMenuAction.cancel:
                            renderer.playUiButtonClick();
                            multiplayerScreen = false;
                            serverMenu.error = "";
                            break;
                        case MultiplayerMenuAction.none:
                            break;
                    }
                }
                if (connectRequested)
                    gameConnection = connectFromMenu(serverMenu,
                        eos, connectionEndpoint, connectionHost,
                        connectionPort);
                renderer.renderMultiplayerScreen(cursor.x, cursor.y,
                    menuTime, serverMenu);
                continue;
            }

            window.clearTextInput();
            const hoveredAction = renderer.titleActionAt(cursor.x, cursor.y);
            window.setCursorShape(hoveredAction == TitleAction.none
                ? CursorShape.arrow : CursorShape.hand);
            if (window.down(VK_RSHIFT)
                && (window.down(VK_OEM_PLUS) || window.down(VK_ADD)))
            {
                foreach (count; 1 .. 10)
                    if (window.pressed('0' + count))
                        launchLocalClients(count);
            }
            if (window.pressed(VK_ESCAPE))
            {
                window.running = false;
                break;
            }
            if (window.pressed(VK_LBUTTON))
            {
                if (hoveredAction != TitleAction.none)
                    renderer.playUiButtonClick();
                final switch (hoveredAction)
                {
                    case TitleAction.singleplayer:
                        worldMenu.refresh();
                        worldScreen = true;
                        if (!worldMenu.worlds.length) worldMenu.beginCreate();
                        else worldMenu.screen = WorldMenuScreen.selection;
                        break;
                    case TitleAction.multiplayer:
                        multiplayerScreen = true;
                        serverMenu.error = "";
                        break;
                    case TitleAction.options:
                        options.open(false);
                        break;
                    case TitleAction.quit:
                        window.running = false;
                        break;
                    case TitleAction.none:
                        break;
                }
            }
            renderer.renderTitleScreen(cursor.x, cursor.y, menuTime);
        }
        if (!window.running || gameConnection is null)
        {
            if (integratedServer !is null) destroy(integratedServer);
            if (!window.running) break;
            continue;
        }
        window.setMouseCapture(true);
        window.setCursorShape(CursorShape.arrow);
        window.mouseDelta(); // discard the recenter event before gameplay

        auto chat = new ChatState();
        scope (exit) destroy(chat);
        auto multiplayer = new MultiplayerClient(gameConnection, world, player);
        uint loadingFrames;
        while (window.running && multiplayer.connected()
            && !multiplayer.loginComplete && loadingFrames++ < 600)
        {
            window.pumpMessages();
            eos.tick();
            if (window.pressed(VK_ESCAPE)) break;
            int loadingWidth, loadingHeight;
            if (window.consumeResize(loadingWidth,loadingHeight))
                renderer.resize(loadingWidth,loadingHeight);
            multiplayer.poll(chat);
            renderer.renderLoadingScreen(integratedServer is null
                ? "Connecting to server" : "Loading world",
                multiplayer.loginComplete ? 100 : 35);
        }
        if (!window.running || !multiplayer.loginComplete)
        {
            if (window.running)
                renderer.setTitleNotice(integratedServer is null
                    ? "Connection timed out or the host closed the world"
                    : "The local world server did not finish loading");
            destroy(multiplayer);
            if (integratedServer !is null) destroy(integratedServer);
            if (!window.running) break;
            continue;
        }
        auto pauseMenu = new PauseMenuState();
        scope (exit) destroy(pauseMenu);
        auto deathScreen = new DeathScreenState();
        scope (exit) destroy(deathScreen);
        auto inventoryMenu=new InventoryMenuState();
        scope(exit)destroy(inventoryMenu);
        scope (exit)
        {
            if (eosHostBridge !is null) destroy(eosHostBridge);
            multiplayer.requestDisconnect();
            destroy(multiplayer);
            if (integratedServer !is null) destroy(integratedServer);
        }

        double previous = monotonicSeconds();
        double accumulator = 0.0;
        double elapsed = 0.0;
        enum double tickSeconds = 1.0 / 20.0;
        uint inputSequence;
        uint reconnectTicks;
        bool pendingUse;
        bool pendingAttack;
        bool pendingDrop;
        bool pendingDropStack;
        bool pendingFlightToggle;
        bool crouchToggleState;
        bool sprintLatched;
        bool attackToggleState;
        bool useToggleState;
        uint lastJumpTapMilliseconds;
        uint dropHeldTicks;
        bool suppressPrimaryUntilRelease = window.down(VK_LBUTTON);
        bool returnToTitle;

        void setPauseMenu(bool active)
        {
            if (active)
                pauseMenu.open();
            else
                pauseMenu.close();
            if (integratedServer !is null)
                integratedServer.setPaused(active);
            window.setMouseCapture(!active);
            window.setCursorShape(CursorShape.arrow);
            if (!active)
            {
                window.mouseDelta();
                // A menu click must be released before it can become a world
                // attack/mining input on the following frame.
                suppressPrimaryUntilRelease = true;
                pendingAttack = false;
            }
        }

        void setInventoryMenu(bool active)
        {
            if(active)
                inventoryMenu.open();
            else
            {
                inventoryMenu.close();
                multiplayer.requestInventoryAction(
                    PlayerActionType.inventoryClose);
            }
            window.setMouseCapture(!active);
            window.setCursorShape(CursorShape.arrow);
            pendingAttack=pendingUse=false;
            if(!active)
            {
                suppressPrimaryUntilRelease=true;
                window.mouseDelta();
            }
        }

        while (window.running)
        {
            window.pumpMessages();
            eos.tick();
            if (eosHostBridge !is null)
                eosHostBridge.pump();
            if (!window.running)
                break;
            int resizedWidth;
            int resizedHeight;
            if (window.consumeResize(resizedWidth, resizedHeight))
                renderer.resize(resizedWidth, resizedHeight);
            if (window.pressed(VK_F11))
            {
                window.toggleFullscreen();
                options.fullscreen = window.fullscreen;
                options.save();
                renderer.resize(window.width, window.height);
            }

            multiplayer.poll(chat);
            if (!deathScreen.active && player.health <= 0.0f
                && player.gameMode != player.gameMode.spectator)
            {
                if (pauseMenu.active)
                {
                    pauseMenu.close();
                    if (integratedServer !is null)
                        integratedServer.setPaused(false);
                }
                if (options.active) options.close();
                if(inventoryMenu.active)setInventoryMenu(false);
                deathScreen.open(player.hardcore,player.totalExperience,
                    multiplayer.localDeathMessage);
                window.setMouseCapture(false);
                window.setCursorShape(CursorShape.arrow);
                pendingAttack = pendingUse = false;
            }
            else if (deathScreen.active && (player.health > 0.0f
                || player.gameMode == player.gameMode.spectator))
            {
                deathScreen.close();
                suppressPrimaryUntilRelease = true;
                window.setMouseCapture(true);
                window.setCursorShape(CursorShape.arrow);
                window.mouseDelta();
            }
            foreach (event; multiplayer.consumeBlockEvents())
                renderer.applyBlockChange(event.x, event.y, event.z,
                    event.oldBlock, event.newBlock);
            foreach (event; multiplayer.consumePickupEvents())
                renderer.playPickup(event.position);
            foreach (event; multiplayer.consumeCriticalHitEvents())
                renderer.applyCriticalHit(event.targetPosition);
            if (multiplayer.consumeDimensionTravel())
                renderer.applyDimensionTravel(player.dimension);

            const openChatPressed = window.pressed(
                options.key(OptionsAction.bindChat));
            const escapePressed = window.pressed(VK_ESCAPE);
            const enterPressed = window.pressed(VK_RETURN);
            const leftPressed = window.pressed(VK_LEFT);
            const rightPressed = window.pressed(VK_RIGHT);
            const homePressed = window.pressed(VK_HOME);
            const endPressed = window.pressed(VK_END);
            const deletePressed = window.pressed(VK_DELETE);
            const perspectivePressed = window.pressed(
                options.key(OptionsAction.bindPerspective));
            const attackPressed = window.pressed(
                options.key(OptionsAction.bindAttack));
            const pickBlockPressed = window.pressed(
                options.key(OptionsAction.bindPickBlock));
            const dropPressed = window.pressed(
                options.key(OptionsAction.bindDrop));
            const jumpPressed = window.pressed(
                options.key(OptionsAction.bindJump));
            const inventoryPressed=window.pressed(
                options.key(OptionsAction.bindInventory));
            if (!window.down(VK_LBUTTON))
                suppressPrimaryUntilRelease = false;
            if (!chat.active && !pauseMenu.active && !deathScreen.active)
                pendingUse = pendingUse || (window.pressed(
                    options.key(OptionsAction.bindUse))
                    && player.gameMode != player.gameMode.adventure
                    && player.gameMode != player.gameMode.spectator);

            if (options.active && options.fromGame)
            {
                window.clearTextInput();
                const cursor = window.cursorPosition();
                const hovered = renderer.optionsActionAt(cursor.x,cursor.y);
                window.setCursorShape(hovered == OptionsAction.none
                    || !options.allowCursorChanges ? CursorShape.arrow
                    : (options.slider(hovered) ? CursorShape.horizontalResize
                        : CursorShape.hand));
                options.scroll(window.consumeWheelSteps(),window.width,window.height);
                if (options.bindingCapture != OptionsAction.none)
                {
                    const captured = window.firstPressedKey();
                    if (captured == VK_ESCAPE) options.cancelBindingCapture();
                    else if (captured >= 0) options.captureKey(captured);
                }
                else if (escapePressed)
                    options.back();
                else if (hovered != OptionsAction.none
                    && options.slider(hovered) && window.down(VK_LBUTTON))
                {
                    if (window.pressed(VK_LBUTTON)) renderer.playUiButtonClick();
                    options.adjustSlider(hovered,cursor.x,window.width,window.height);
                    renderer.applyOptions();
                }
                else if (window.pressed(VK_LBUTTON)
                    && hovered != OptionsAction.none)
                {
                    renderer.playUiButtonClick();
                    options.activate(hovered);
                    renderer.applyOptions();
                    if (hovered == OptionsAction.fullscreen)
                    {
                        window.setFullscreen(options.fullscreen);
                        renderer.resize(window.width,window.height);
                    }
                }
            }
            else if (deathScreen.active)
            {
                window.clearTextInput();
                const cursor = window.cursorPosition();
                const hovered = renderer.deathActionAt(cursor.x,cursor.y,
                    deathScreen);
                window.setCursorShape(hovered == DeathAction.none
                    ? CursorShape.arrow : CursorShape.hand);
                if (window.pressed(VK_LBUTTON)
                    && hovered != DeathAction.none)
                {
                    renderer.playUiButtonClick();
                    suppressPrimaryUntilRelease = true;
                    final switch (hovered)
                    {
                        case DeathAction.respawn:
                            deathScreen.awaitingServer = true;
                            multiplayer.requestRespawn();
                            break;
                        case DeathAction.titleScreen:
                            returnToTitle = true;
                            break;
                        case DeathAction.none:
                            break;
                    }
                }
            }
            else if(inventoryMenu.active)
            {
                window.clearTextInput();
                const cursor=window.cursorPosition();
                const hovered=renderer.inventorySlotAt(cursor.x,cursor.y);
                window.setCursorShape(CursorShape.arrow);
                if(escapePressed||inventoryPressed)
                    setInventoryMenu(false);
                else
                {
                    const dropKey=window.pressed(
                        options.key(OptionsAction.bindDrop));
                    if(dropKey&&hovered>=0)
                        multiplayer.requestInventoryAction(
                            PlayerActionType.inventoryDrop,cast(ubyte)hovered,
                            window.down(VK_CONTROL)?1:0);
                    foreach(slot;0..9)
                        if(window.pressed(options.key(cast(OptionsAction)
                            (cast(int)OptionsAction.bindHotbar1+slot)))
                            &&hovered>=0)
                            multiplayer.requestInventoryAction(
                                PlayerActionType.inventoryHotbarSwap,
                                cast(ubyte)hovered,cast(ubyte)slot);
                    foreach(button;0..2)
                    {
                        const key=button==0?VK_LBUTTON:VK_RBUTTON;
                        if(!window.pressed(key))continue;
                        if(hovered>=0)
                        {
                            if(button==0&&window.down(VK_SHIFT))
                                multiplayer.requestInventoryAction(
                                    PlayerActionType.inventoryQuickMove,
                                    cast(ubyte)hovered);
                            else if(button==0&&inventoryMenu.doubleClick(
                                hovered,button,monotonicMilliseconds()))
                                multiplayer.requestInventoryAction(
                                    PlayerActionType.inventoryCollect,
                                    cast(ubyte)hovered);
                            else
                                multiplayer.requestInventoryAction(
                                    PlayerActionType.inventoryClick,
                                    cast(ubyte)hovered,cast(ubyte)button);
                        }
                        else if(renderer.inventoryOutside(cursor.x,cursor.y)
                            &&!player.inventory.carried.empty())
                            multiplayer.requestInventoryAction(
                                PlayerActionType.inventoryDrop,ubyte.max,
                                button==0?1:0);
                    }
                }
            }
            else if (pauseMenu.active)
            {
                window.clearTextInput();
                const cursor = window.cursorPosition();
                const canPublish = integratedServer !is null;
                const hovered = renderer.pauseActionAt(cursor.x, cursor.y,
                    canPublish, pauseMenu);
                window.setCursorShape(hovered == PauseAction.none
                    ? CursorShape.arrow : CursorShape.hand);
                if (escapePressed)
                {
                    if (pauseMenu.screen == PauseScreen.gameMenu)
                        setPauseMenu(false);
                    else
                    {
                        pauseMenu.screen = PauseScreen.gameMenu;
                        pauseMenu.notice = "";
                    }
                }
                else if (window.pressed(VK_LBUTTON))
                {
                    if (hovered != PauseAction.none)
                        renderer.playUiButtonClick();
                    final switch (hovered)
                    {
                        case PauseAction.resume:
                            setPauseMenu(false);
                            break;
                        case PauseAction.options:
                            options.open(true);
                            break;
                        case PauseAction.publish:
                            if (integratedServer !is null)
                            {
                                pauseMenu.notice = "";
                                pauseMenu.screen = pauseMenu.published
                                    ? PauseScreen.serverInformation
                                    : PauseScreen.publishConfirmation;
                            }
                            break;
                        case PauseAction.confirmPublish:
                            if (integratedServer !is null)
                            {
                                if (eos.ready)
                                {
                                    try
                                    {
                                        if (eosHostBridge is null)
                                            eosHostBridge = new EosHostBridge(eos,
                                                integratedServer.port);
                                        pauseMenu.address = eosHostBridge.invitation;
                                        pauseMenu.published = true;
                                        pauseMenu.notice = "";
                                        pauseMenu.screen = PauseScreen.serverInformation;
                                    }
                                    catch (Exception error)
                                        pauseMenu.notice = error.msg;
                                }
                                else if (eos.status == EosStatus.initializing)
                                    pauseMenu.notice =
                                        "EOS is still signing in. Try again in a moment.";
                                else
                                {
                                    // Keep the existing same-network path usable
                                    // when EOS credentials or its service are down.
                                    pauseMenu.address = integratedServer.publish();
                                    pauseMenu.published = true;
                                    pauseMenu.notice = "EOS unavailable; this address is LAN only";
                                    pauseMenu.screen = PauseScreen.serverInformation;
                                }
                            }
                            break;
                        case PauseAction.declinePublish:
                        case PauseAction.cancelSubscreen:
                            pauseMenu.screen = PauseScreen.gameMenu;
                            pauseMenu.notice = "";
                            break;
                        case PauseAction.copyAddress:
                            pauseMenu.notice = window.setClipboardText(
                                pauseMenu.address)
                                ? "Server address copied"
                                : "Could not access the clipboard";
                            break;
                        case PauseAction.quit:
                            returnToTitle = true;
                            break;
                        case PauseAction.none:
                            break;
                    }
                }
            }
            else if (!chat.active && openChatPressed)
            {
                chat.open();
                window.clearTextInput();
                window.setMouseCapture(false);
                window.setCursorShape(CursorShape.text);
            }
            else if(!chat.active&&inventoryPressed
                &&player.gameMode!=player.gameMode.spectator)
            {
                setInventoryMenu(true);
            }
            else if (chat.active)
            {
                chat.insertCharacters(window.consumeTextInput());
                if (escapePressed)
                {
                    chat.close(options.boolean("chatDrafts",true));
                    window.setMouseCapture(true);
                    window.setCursorShape(CursorShape.arrow);
                }
                else if (enterPressed)
                {
                    chat.submit(multiplayer);
                    window.setMouseCapture(true);
                    window.setCursorShape(CursorShape.arrow);
                }
                else
                {
                    if (leftPressed) chat.moveCursor(-1);
                    if (rightPressed) chat.moveCursor(1);
                    if (homePressed) chat.cursor = 0;
                    if (endPressed) chat.cursor = chat.input.length;
                    if (deletePressed) chat.deleteForward();
                }
            }
            else
            {
                window.clearTextInput();
                pendingDrop = pendingDrop || dropPressed;
                if (dropPressed)
                    pendingDropStack = window.down(VK_CONTROL);
                if (escapePressed)
                {
                    setPauseMenu(true);
                    continue;
                }
            }

            if (returnToTitle)
                break;

            const controlsActive = !chat.active && !pauseMenu.active
                &&!inventoryMenu.active
                && !deathScreen.active;
            player.skinParts=options.skinParts();
            player.mainHandRight=options.mainHandRight();
            if (controlsActive)
            {
                if (options.integer("sneakMode",0)==1
                    && window.pressed(options.key(OptionsAction.bindSneak)))
                    crouchToggleState=!crouchToggleState;
                if (window.pressed(options.key(OptionsAction.bindSprint)))
                {
                    if (options.integer("sprintMode",0)==1)
                        sprintLatched=!sprintLatched;
                    else
                        sprintLatched=true;
                }
                if (options.integer("attackMode",0)==1
                    && window.pressed(options.key(OptionsAction.bindAttack)))
                    attackToggleState=!attackToggleState;
                if (options.integer("useMode",0)==1
                    && window.pressed(options.key(OptionsAction.bindUse)))
                    useToggleState=!useToggleState;
            }
            if (controlsActive && jumpPressed
                && player.gameMode == player.gameMode.creative)
            {
                const now = monotonicMilliseconds();
                if (lastJumpTapMilliseconds != 0
                    && now - lastJumpTapMilliseconds <= 300)
                {
                    pendingFlightToggle = true;
                    lastJumpTapMilliseconds = 0;
                }
                else
                    lastJumpTapMilliseconds = now;
            }
            const mouse = controlsActive ? window.mouseDelta() : Point(0, 0);
            if (controlsActive)
                player.look(cast(float) mouse.x * options.mouseSensitivity
                        * (options.invertMouseX ? -1.0f : 1.0f),
                    cast(float) mouse.y * options.mouseSensitivity
                        * (options.invertMouse ? -1.0f : 1.0f));
            if (controlsActive && perspectivePressed)
                renderer.cyclePerspective();
            if (controlsActive && pickBlockPressed
                && player.gameMode == player.gameMode.creative)
                multiplayer.requestInventoryAction(PlayerActionType.pickBlock);
            if (controlsActive && attackPressed
                && !suppressPrimaryUntilRelease
                && player.gameMode != player.gameMode.spectator)
            {
                player.attack();
                pendingAttack = true;
            }
            foreach (slot; 0 .. 9)
            {
                const slotPressed = window.pressed(options.key(cast(OptionsAction)
                    (cast(int)OptionsAction.bindHotbar1 + slot)));
                if (controlsActive && slotPressed)
                    player.selectedSlot = slot;
            }
            const pendingWheel = window.consumeWheelSteps();
            const wheel = controlsActive ? pendingWheel : 0;
            if (wheel != 0)
            {
                player.selectedSlot = (player.selectedSlot - wheel) % 9;
                if (player.selectedSlot < 0)
                    player.selectedSlot += 9;
            }

            const current = monotonicSeconds();
            const frameSeconds = fmin(current - previous, 0.25);
            previous = current;
            // An open menu only freezes a genuinely singleplayer integrated
            // server. In multiplayer the client keeps ticking and sends neutral
            // input while controls are captured by the menu.
            const worldPaused = multiplayer.serverPaused;
            renderer.tickGameMusic(player.dimension, worldPaused);
            if (worldPaused)
                accumulator = 0.0;
            else
            {
                accumulator += frameSeconds;
                elapsed += frameSeconds;
            }

            while (!worldPaused && accumulator >= tickSeconds)
            {
                const forward = controlsActive && window.down(options.key(OptionsAction.bindForward));
                const back = controlsActive && window.down(options.key(OptionsAction.bindBack));
                const left = controlsActive && window.down(options.key(OptionsAction.bindLeft));
                const right = controlsActive && window.down(options.key(OptionsAction.bindRight));
                const manualJumping = controlsActive && window.down(options.key(OptionsAction.bindJump));
                const jumping = manualJumping || (controlsActive
                    && options.boolean("autoJump",false)
                    && player.shouldAutoJump(world,forward,back,left,right));
                const crouching = controlsActive && (options.integer("sneakMode",0)==1
                    ? crouchToggleState : window.down(options.key(OptionsAction.bindSneak)));
                const sprintKeyDown = controlsActive
                    && window.down(options.key(OptionsAction.bindSprint));
                if (options.integer("sprintMode",0) == 0)
                    sprintLatched = sprintKeyDown;
                const sprintEligible = controlsActive && forward && !back
                    && !crouching && player.foodLevel > 6;
                if (!sprintEligible
                    || (player.horizontalCollision && !sprintKeyDown))
                    sprintLatched=false;
                const sprinting = sprintEligible && sprintLatched
                    && !player.horizontalCollision;
                const attacking = controlsActive && !suppressPrimaryUntilRelease
                    && (options.integer("attackMode",0)==1 ? attackToggleState
                        : window.down(options.key(OptionsAction.bindAttack)));
                const dropDown = controlsActive && window.down(options.key(OptionsAction.bindDrop));
                if (dropDown)
                    ++dropHeldTicks;
                else
                    dropHeldTicks = 0;
                // Java consumes repeated drop-key clicks. Win32's async key
                // state has no portable repeat queue, so reproduce the feel at
                // 20 TPS: immediate, a short hold delay, then ten items/second.
                const dropRequested = controlsActive && (pendingDrop
                    || dropHeldTicks == 1
                    || (dropHeldTicks >= 8 && (dropHeldTicks - 8) % 2 == 0));
                const dropWholeStack = pendingDropStack
                    || window.down(VK_CONTROL);
                pendingDrop = false;
                pendingDropStack = false;
                const flightToggle = pendingFlightToggle;
                pendingFlightToggle = false;
                if (flightToggle) player.toggleFlight();
                if (controlsActive && options.integer("useMode",0)==1
                    && useToggleState) pendingUse=true;
                if (dropRequested && player.selectedSlot >= 0
                    && player.selectedSlot < player.inventory.hotbar.length
                    && !player.inventory.hotbar[player.selectedSlot].empty())
                    player.attack(true);
                if (!deathScreen.active)
                    player.simulateTick(world, forward, back, left, right,
                        jumping, crouching, sprinting);
                renderer.simulateTick(player, multiplayer);
                renderer.updateMining(player, attacking
                    && player.gameMode != player.gameMode.adventure
                    && player.gameMode != player.gameMode.spectator,
                    pendingAttack);
                ubyte flags;
                if (forward) flags |= inputForward;
                if (back) flags |= inputBack;
                if (left) flags |= inputLeft;
                if (right) flags |= inputRight;
                if (jumping) flags |= inputJump;
                if (crouching) flags |= inputCrouch;
                if (sprinting) flags |= inputSprint;
                if (attacking) flags |= inputAttack;
                multiplayer.sendPredictedInput(PlayerInputCommand(++inputSequence,
                    flags, cast(ubyte) player.selectedSlot, pendingUse,
                    player.yaw, player.pitch, pendingAttack, flightToggle,
                    options.skinParts(),options.mainHandRight()));
                if (dropRequested)
                    multiplayer.requestDrop(cast(ubyte) player.selectedSlot,
                        dropWholeStack);
                pendingUse = false;
                pendingAttack = false;
                chat.tick();
                deathScreen.tick();
                if (!multiplayer.connected() && ++reconnectTicks >= 40)
                {
                    reconnectTicks = 0;
                    try multiplayer.replaceConnection(createConnection(eos,
                        "Steve", connectionEndpoint));
                    catch (Exception) {}
                }
                else if (multiplayer.connected())
                    reconnectTicks = 0;
                accumulator -= tickSeconds;
            }

            const menuCursor = pauseMenu.active
                ? window.cursorPosition() : Point(0,0);
            const deathCursor = deathScreen.active
                ? window.cursorPosition() : Point(0,0);
            const inventoryCursor=inventoryMenu.active
                ?window.cursorPosition():Point(0,0);
            // A paused client has no next simulation tick to interpolate
            // toward. Render the current authoritative endpoint instead of
            // forcing alpha zero (the stale previous endpoint), which could
            // leave a newly joined client with only the clear sky and HUD.
            const renderPartialTick = worldPaused ? 1.0f
                : cast(float) (accumulator / tickSeconds);
            renderer.render(player, chat, multiplayer,
                renderPartialTick, cast(float) elapsed,
                pauseMenu, menuCursor.x, menuCursor.y,
                integratedServer !is null, deathScreen,
                deathCursor.x, deathCursor.y,inventoryMenu,
                inventoryCursor.x,inventoryCursor.y);
            const frameFinished = monotonicSeconds();
            const maximumFps=options.integer("maxFps",120);
            if(maximumFps>0)
            {
                const spent=frameFinished-current;
                const remaining=1.0/maximumFps-spent;
                if(remaining>=0.001)
                    sleepMilliseconds(cast(uint)(remaining*1000.0));
            }
        }
        window.setMouseCapture(false);
        window.setCursorShape(CursorShape.arrow);
        }
    }

private:
    static GameConnection connectFromMenu(MultiplayerMenuState menu,
        EosService eos, out ServerEndpoint selected,
        out string host, out ushort port)
    {
        const endpoint = parseServerAddress(menu.serverAddress);
        if (!endpoint.valid)
        {
            menu.error = "Enter an IP:port or a complete mcd://eos invitation";
            return null;
        }
        try
        {
            auto connection = createConnection(eos, "Steve", endpoint);
            selected = endpoint;
            if (!endpoint.eos)
            {
                host = endpoint.host;
                port = endpoint.port;
            }
            menu.error = "";
            menu.save();
            return connection;
        }
        catch (SocketOSException)
        {
            menu.error = "Server host is not online. Please try again later.";
            return null;
        }
        catch (Exception error)
        {
            menu.error = error.msg;
            return null;
        }
    }

    static GameConnection createConnection(EosService eos, string playerName,
        ServerEndpoint endpoint)
    {
        if (!endpoint.eos)
            return new GameConnection(playerName, endpoint.host, endpoint.port);
        if (eos is null || !eos.ready)
        {
            if (eos !is null && eos.status == EosStatus.initializing)
                throw new Exception("EOS is still signing in. Try again in a moment.");
            const detail = eos is null ? "EOS is unavailable" : eos.error;
            throw new Exception(detail.length ? detail : "EOS is unavailable");
        }
        if(endpoint.localPort!=0&&endpoint.eosUserId==eos.localUserId())
            return new GameConnection(playerName,"127.0.0.1",endpoint.localPort);
        return new GameConnection(eos, playerName, endpoint);
    }

    static void launchLocalClients(int requestedCount)
    {
        // The current window is client one, so launch only the remainder.
        foreach (index; 2 .. requestedCount + 1)
            spawnProcess([thisExePath(), "--local-test-client="
                ~ to!string(index)], null, Config.detached);
    }
}
