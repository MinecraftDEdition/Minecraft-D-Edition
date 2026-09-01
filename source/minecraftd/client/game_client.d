module minecraftd.client.game_client;

version (Windows)
    import core.sys.windows.com : CoInitializeEx, CoUninitialize,
        COINIT_MULTITHREADED;
import std.math : fmin;
import std.conv : to;
import std.process : thisProcessID;

import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.client.chat.chat_state : ChatState;
import minecraftd.client.input.ui_navigation : UiDirection, UiHitTest,
    UiNavigation;
import minecraftd.client.network.game_connection : GameConnection,
    ServerEndpoint, parseServerAddress;
import minecraftd.client.network.eos_service : EosHostBridge, EosService,
    EosStatus;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.render.game_renderer : GameRenderer;
import minecraftd.client.render.graphics_device : GraphicsApi;
import minecraftd.client.render.title_screen_renderer : TitleAction;
import minecraftd.client.render.title_screen_renderer : AccountMenuAction;
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
import minecraftd.client.account.account_service : AccountService,
    AccountSnapshot;
import minecraftd.client.menu.account_menu_state : AccountDialog,
    AccountMenuState;
import minecraftd.platform.clock : monotonicMilliseconds, monotonicSeconds,
    sleepMilliseconds;
import minecraftd.platform.input;
import minecraftd.platform.paths : platformPaths;
import minecraftd.platform.update : startUpdater;
import minecraftd.platform.web : chooseSkinPng, openExternalUrl;
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
    void run(string rendererOverride = "")
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
            GameWindow.defaultWidth, GameWindow.defaultHeight);
        scope (exit) destroy(window);
        UiNavigation uiNavigation;
        startUpdater();
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
        auto accounts = new AccountService(paths.userData,paths.cache);
        scope (exit) destroy(accounts);
        auto accountMenu = new AccountMenuState();
        scope (exit) destroy(accountMenu);
        EosService eos;
        scope (exit) if (eos !is null) destroy(eos);

        EosService ensureEos()
        {
            if (eos is null)
                eos = new EosService(playerName(accounts.snapshot));
            return eos;
        }

        void tickEos()
        {
            if (eos !is null)
                eos.tick();
        }

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
        auto serverMenu = new MultiplayerMenuState(paths.userData);
        scope (exit) destroy(serverMenu);
        auto worldMenu = new WorldMenuState(paths.userData);
        scope (exit) destroy(worldMenu);
        bool multiplayerScreen;
        initialSession = false;
        bool worldScreen;
        bool worldTextMouseSelecting;
        bool serverTextMouseSelecting;
        string lastAccountMessage;

        bool startLocalWorld(const WorldEntry entry)
        {
            try
            {
                renderer.renderLoadingScreen("Preparing world", 0);
                integratedServer = new IntegratedGameServer(entry.settings,
                    entry.directory, (int percent) {
                        window.pumpMessages();
                        tickEos();
                        renderer.renderLoadingScreen("Generating world", percent);
                    });
                connectionPort = integratedServer.port;
                connectionEndpoint.host = connectionHost;
                connectionEndpoint.port = connectionPort;
                connectionEndpoint.eos = false;
                connectionEndpoint.valid = true;
                const identity=accounts.snapshot;
                gameConnection = new GameConnection(playerName(identity),
                    connectionHost,connectionPort,identity.id,
                    sharedSkinVersion(identity),identity.skinModel);
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
            tickEos();
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
            const gamepad = window.gamepadState();
            const mouseCursor = window.cursorPosition();
            uiNavigation.observe(mouseCursor, gamepad);
            ulong navigationToken;
            int navigationNone;
            UiHitTest navigationHitTest;
            const navigationAccount = accounts.snapshot;
            if (options.active && !options.fromGame)
            {
                navigationToken = 100 + cast(ulong)options.screen;
                navigationHitTest = (int x,int y) => cast(int)
                    renderer.optionsActionAt(x,y);
            }
            else if (accountMenu.active)
            {
                navigationToken = 200 + cast(ulong)accountMenu.dialog * 4
                    + (navigationAccount.loggedIn ? 1 : 0);
                navigationHitTest = (int x,int y) => cast(int)
                    renderer.accountActionAt(x,y,accountMenu,navigationAccount);
            }
            else if (worldScreen)
            {
                navigationToken = 300 + cast(ulong)worldMenu.screen * 8
                    + cast(ulong)worldMenu.tab;
                navigationHitTest = (int x,int y) => cast(int)
                    renderer.worldMenuActionAt(x,y,worldMenu);
            }
            else if (multiplayerScreen)
            {
                navigationToken = 400;
                navigationHitTest = (int x,int y) => cast(int)
                    renderer.multiplayerMenuActionAt(x,y);
            }
            else
            {
                navigationToken = 500;
                navigationHitTest = (int x,int y) => cast(int)
                    renderer.titleActionAt(x,y);
            }
            uiNavigation.prepare(navigationToken,navigationNone,
                navigationHitTest,window.width,window.height);
            const navigationDirection = uiNavigation.takeDirection(gamepad,
                monotonicMilliseconds());
            bool navigationConsumed;
            if (worldScreen && worldMenu.screen == WorldMenuScreen.selection
                && cast(WorldMenuAction)uiNavigation.focusedId
                    == WorldMenuAction.worldList
                && (navigationDirection == UiDirection.up
                    || navigationDirection == UiDirection.down)
                && worldMenu.worlds.length)
            {
                const delta = navigationDirection == UiDirection.down ? 1 : -1;
                worldMenu.selected += delta;
                if (worldMenu.selected < 0) worldMenu.selected = 0;
                if (worldMenu.selected >= worldMenu.worlds.length)
                    worldMenu.selected = cast(int)worldMenu.worlds.length - 1;
                navigationConsumed = true;
            }
            if (options.active && !options.fromGame
                && (navigationDirection == UiDirection.left
                    || navigationDirection == UiDirection.right))
            {
                const focused = cast(OptionsAction)uiNavigation.focusedId;
                if (options.slider(focused))
                {
                    options.adjustSliderStep(focused,
                        navigationDirection == UiDirection.right ? 1 : -1,
                        window.width,window.height);
                    renderer.applyOptions();
                    navigationConsumed = true;
                }
            }
            if (!navigationConsumed)
                uiNavigation.move(navigationDirection);
            const cursor = uiNavigation.cursor(mouseCursor);
            window.setCursorVisible(!uiNavigation.usingController);
            const uiAcceptPressed = window.pressed(VK_LBUTTON)
                || gamepad.pressed(GamepadButton.a);
            const uiPrimaryDown = window.down(VK_LBUTTON)
                || gamepad.down(GamepadButton.a);
            const uiCancelPressed = window.pressed(VK_ESCAPE)
                || gamepad.pressed(GamepadButton.b);
            const menuTime = cast(float) monotonicMilliseconds() / 1000.0f;
            accounts.refreshWhenDue();
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
                else if (uiCancelPressed)
                    options.back();
                else if (hovered != OptionsAction.none
                    && options.slider(hovered) && uiPrimaryDown)
                {
                    if (uiAcceptPressed) renderer.playUiButtonClick();
                    options.adjustSlider(hovered,cursor.x,window.width,window.height);
                    renderer.applyOptions();
                }
                else if (uiAcceptPressed
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
            if (accountMenu.active)
            {
                auto account = accounts.snapshot();
                accountMenu.sync(account);
                if (account.message == "That's not a skin, silly!"
                    && account.message != lastAccountMessage)
                    accountMenu.showMessage(account.message);
                lastAccountMessage = account.message.idup;
                const hovered = renderer.accountActionAt(cursor.x,cursor.y,
                    accountMenu,account);
                window.setCursorShape(hovered==AccountMenuAction.username
                    ?CursorShape.text:(hovered==AccountMenuAction.none
                        ?CursorShape.arrow:CursorShape.hand));
                if (account.loggedIn && accountMenu.editingUsername
                    && accountMenu.dialog == AccountDialog.none)
                {
                    const input=window.consumeTextInput();
                    const textBackspace=containsCharacter(input,8);
                    const shortcut=window.shortcutDown();
                    if(shortcut&&window.pressed('A'))
                    {window.clearTextInput();accountMenu.selectAll();}
                    else if(shortcut&&window.pressed('C'))
                    {
                        window.clearTextInput();
                        if(accountMenu.hasSelection)
                            window.setClipboardText(accountMenu.selectedText);
                    }
                    else if(shortcut&&window.pressed('X'))
                    {
                        window.clearTextInput();
                        if(accountMenu.hasSelection
                            &&window.setClipboardText(accountMenu.selectedText))
                            accountMenu.cutSelection();
                    }
                    else if(shortcut&&window.pressed('V'))
                    {window.clearTextInput();accountMenu.paste(window.clipboardText());}
                    else accountMenu.insertCharacters(input);
                    const selecting=window.down(VK_SHIFT);
                    if(window.pressed(VK_LEFT)||window.repeated(VK_LEFT))
                        accountMenu.moveCursor(-1,selecting);
                    if(window.pressed(VK_RIGHT)||window.repeated(VK_RIGHT))
                        accountMenu.moveCursor(1,selecting);
                    if(window.pressed(VK_HOME))accountMenu.moveToStart(selecting);
                    if(window.pressed(VK_END))accountMenu.moveToEnd(selecting);
                    if(window.pressed(VK_BACK)||window.repeated(VK_BACK)
                        ||textBackspace)accountMenu.backspace();
                    if(window.pressed(VK_DELETE)||window.repeated(VK_DELETE))
                        accountMenu.deleteForward();
                    if(window.pressed(VK_RETURN))accountMenu.requestUsernameChange();
                    if(accountMenu.mouseSelecting&&uiPrimaryDown)
                    {
                        const at=renderer.accountTextCursorAt(cursor.x,accountMenu);
                        if(at>=0)accountMenu.setCursor(cast(size_t)at,true);
                    }
                }
                else window.clearTextInput();
                if(!uiPrimaryDown)accountMenu.mouseSelecting=false;
                if(uiCancelPressed)
                {
                    if(accountMenu.dialog!=AccountDialog.none)
                        accountMenu.dismissDialog();
                    else accountMenu.close();
                }
                if(uiAcceptPressed)
                {
                    if(hovered!=AccountMenuAction.none)renderer.playUiButtonClick();
                    final switch(hovered)
                    {
                        case AccountMenuAction.cancel: accountMenu.close(); break;
                        case AccountMenuAction.login: accounts.beginAuthentication(false); break;
                        case AccountMenuAction.signup: accounts.beginAuthentication(true); break;
                        case AccountMenuAction.username:
                            accountMenu.beginEditing();
                            const at=renderer.accountTextCursorAt(cursor.x,accountMenu);
                            if(at>=0)accountMenu.setCursor(cast(size_t)at);
                            accountMenu.mouseSelecting=true;
                            break;
                        case AccountMenuAction.changePassword:
                            openExternalUrl(accounts.passwordUrl()); break;
                        case AccountMenuAction.changeSkin:
                            const selected=chooseSkinPng();
                            if(selected.length)accounts.changeSkin(selected);
                            break;
                        case AccountMenuAction.classicArms:
                            accounts.changeSkinModel("classic"); break;
                        case AccountMenuAction.slimArms:
                            accounts.changeSkinModel("slim"); break;
                        case AccountMenuAction.copyId:
                            window.setClipboardText(account.id); break;
                        case AccountMenuAction.signOut: accounts.signOut(); break;
                        case AccountMenuAction.confirmYes:
                            accounts.changeUsername(accountMenu.usernameInput);
                            accountMenu.originalUsername=accountMenu.usernameInput.idup;
                            accountMenu.dismissDialog(); break;
                        case AccountMenuAction.confirmNo:
                            accountMenu.usernameInput=accountMenu.originalUsername.idup;
                            accountMenu.edit.moveToEnd(accountMenu.usernameInput);
                            accountMenu.dismissDialog(); break;
                        case AccountMenuAction.okay: accountMenu.dismissDialog(); break;
                        case AccountMenuAction.none: break;
                    }
                }
                renderer.renderAccountScreen(cursor.x,cursor.y,menuTime,
                    accountMenu,account,player);
                continue;
            }
            if (worldScreen)
            {
                const hovered = renderer.worldMenuActionAt(cursor.x,cursor.y,worldMenu);
                const textAction = hovered == WorldMenuAction.name
                    || hovered == WorldMenuAction.seed && !worldMenu.editing;
                window.setCursorShape(textAction ? CursorShape.text
                    : (hovered == WorldMenuAction.none ? CursorShape.arrow : CursorShape.hand));
                const worldTextInput = window.consumeTextInput();
                const worldTextBackspace = containsCharacter(worldTextInput, 8);
                const worldShortcut = window.shortcutDown();
                if (worldShortcut && window.pressed('A'))
                {
                    window.clearTextInput();
                    worldMenu.selectAll();
                }
                else if (worldShortcut && window.pressed('C'))
                {
                    window.clearTextInput();
                    if (worldMenu.hasTextSelection)
                        window.setClipboardText(worldMenu.selectedText);
                }
                else if (worldShortcut && window.pressed('X'))
                {
                    window.clearTextInput();
                    if (worldMenu.hasTextSelection
                        && window.setClipboardText(worldMenu.selectedText))
                        worldMenu.cutSelection();
                }
                else if (worldShortcut && window.pressed('V'))
                {
                    window.clearTextInput();
                    worldMenu.insertCharacters(window.clipboardText());
                }
                else
                    worldMenu.insertCharacters(worldTextInput);
                const worldSelecting = window.down(VK_SHIFT);
                if (window.pressed(VK_LEFT) || window.repeated(VK_LEFT))
                    worldMenu.moveCursor(-1, worldSelecting);
                if (window.pressed(VK_RIGHT) || window.repeated(VK_RIGHT))
                    worldMenu.moveCursor(1, worldSelecting);
                if (window.pressed(VK_HOME))
                    worldMenu.moveToStart(worldSelecting);
                if (window.pressed(VK_END))
                    worldMenu.moveToEnd(worldSelecting);
                if (window.pressed(VK_BACK) || window.repeated(VK_BACK)
                    || worldTextBackspace)
                    worldMenu.backspace();
                if (window.pressed(VK_DELETE) || window.repeated(VK_DELETE))
                    worldMenu.deleteForward();

                if (uiAcceptPressed && textAction)
                {
                    const clickedField = hovered == WorldMenuAction.name
                        ? WorldField.name : WorldField.seed;
                    worldMenu.activate(clickedField);
                    const textCursor = renderer.worldTextCursorAt(cursor.x,
                        worldMenu, clickedField);
                    if (textCursor >= 0)
                        worldMenu.setCursor(cast(size_t) textCursor);
                    worldTextMouseSelecting = true;
                }
                else if (worldTextMouseSelecting && uiPrimaryDown)
                {
                    const textCursor = renderer.worldTextCursorAt(cursor.x,
                        worldMenu, worldMenu.field);
                    if (textCursor >= 0)
                        worldMenu.setCursor(cast(size_t) textCursor, true);
                }
                if (!uiPrimaryDown)
                    worldTextMouseSelecting = false;
                if (uiCancelPressed)
                {
                    if (worldMenu.screen == WorldMenuScreen.selection)
                        worldScreen = false;
                    else
                    {
                        worldMenu.screen = WorldMenuScreen.selection;
                        worldMenu.activate(WorldField.none);
                        worldTextMouseSelecting = false;
                        worldMenu.refresh();
                    }
                }
                if (uiAcceptPressed)
                {
                    if (hovered != WorldMenuAction.none) renderer.playUiButtonClick();
                    final switch (hovered)
                    {
                        case WorldMenuAction.worldList:
                            if (!uiNavigation.usingController)
                            {
                                const row = renderer.worldRowAt(cursor.y,worldMenu);
                                if (row >= 0) worldMenu.selected = row;
                            }
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
                        case WorldMenuAction.tabGame: worldMenu.tab=WorldCreationTab.game; worldMenu.activate(WorldField.none); break;
                        case WorldMenuAction.tabWorld: worldMenu.tab=WorldCreationTab.world; worldMenu.activate(WorldField.none); break;
                        case WorldMenuAction.tabMore: worldMenu.tab=WorldCreationTab.more; worldMenu.activate(WorldField.none); break;
                        case WorldMenuAction.name: worldMenu.activate(WorldField.name); break;
                        case WorldMenuAction.seed: if(!worldMenu.editing) worldMenu.activate(WorldField.seed); break;
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
                        case WorldMenuAction.caves:
                            if(!worldMenu.editing)worldMenu.draft.generateCaves=!worldMenu.draft.generateCaves;
                            break;
                        case WorldMenuAction.rivers:
                            if(!worldMenu.editing)worldMenu.draft.generateRivers=!worldMenu.draft.generateRivers;
                            break;
                        case WorldMenuAction.oceans:
                            if(!worldMenu.editing)worldMenu.draft.generateOceans=!worldMenu.draft.generateOceans;
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
                                worldMenu.activate(WorldField.none);
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
                            worldMenu.screen=WorldMenuScreen.selection;
                            worldMenu.activate(WorldField.none);
                            worldMenu.refresh(); break;
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
                const serverTextInput = window.consumeTextInput();
                const serverTextBackspace = containsCharacter(serverTextInput, 8);
                const serverShortcut = window.shortcutDown();
                if (serverShortcut && window.pressed('A'))
                {
                    window.clearTextInput();
                    serverMenu.selectAll();
                }
                else if (serverShortcut && window.pressed('C'))
                {
                    window.clearTextInput();
                    if (serverMenu.hasSelection)
                        window.setClipboardText(serverMenu.selectedText);
                }
                else if (serverShortcut && window.pressed('X'))
                {
                    window.clearTextInput();
                    if (serverMenu.hasSelection
                        && window.setClipboardText(serverMenu.selectedText))
                        serverMenu.cutSelection();
                }
                else if (serverShortcut && window.pressed('V'))
                {
                    window.clearTextInput();
                    serverMenu.paste(window.clipboardText());
                }
                else
                    serverMenu.insertCharacters(serverTextInput);
                const serverSelecting = window.down(VK_SHIFT);
                if (window.pressed(VK_LEFT) || window.repeated(VK_LEFT))
                    serverMenu.moveCursor(-1, serverSelecting);
                if (window.pressed(VK_RIGHT) || window.repeated(VK_RIGHT))
                    serverMenu.moveCursor(1, serverSelecting);
                if (window.pressed(VK_HOME))
                    serverMenu.moveToStart(serverSelecting);
                if (window.pressed(VK_END))
                    serverMenu.moveToEnd(serverSelecting);
                if (window.pressed(VK_BACK) || window.repeated(VK_BACK)
                    || serverTextBackspace)
                    serverMenu.backspace();
                if (window.pressed(VK_DELETE) || window.repeated(VK_DELETE))
                    serverMenu.deleteForward();
                if (window.pressed(VK_TAB))
                    serverMenu.selectNextField();

                if (uiAcceptPressed && overText)
                {
                    const clickedField = hovered == MultiplayerMenuAction.serverName
                        ? MultiplayerField.serverName : MultiplayerField.serverAddress;
                    serverMenu.activate(clickedField);
                    const textCursor = renderer.multiplayerTextCursorAt(cursor.x,
                        serverMenu, clickedField);
                    if (textCursor >= 0)
                        serverMenu.setCursor(cast(size_t) textCursor);
                    serverTextMouseSelecting = true;
                }
                else if (serverTextMouseSelecting && uiPrimaryDown)
                {
                    const textCursor = renderer.multiplayerTextCursorAt(cursor.x,
                        serverMenu, serverMenu.activeField);
                    if (textCursor >= 0)
                        serverMenu.setCursor(cast(size_t) textCursor, true);
                }
                if (!uiPrimaryDown)
                    serverTextMouseSelecting = false;

                bool connectRequested = window.pressed(VK_RETURN);
                if (uiCancelPressed)
                {
                    multiplayerScreen = false;
                    serverMenu.error = "";
                    serverTextMouseSelecting = false;
                }
                if (uiAcceptPressed)
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
                            serverTextMouseSelecting = false;
                            break;
                        case MultiplayerMenuAction.none:
                            break;
                    }
                }
                if (connectRequested)
                {
                    gameConnection = connectFromMenu(serverMenu,
                        accounts.snapshot,
                        eos, connectionEndpoint, connectionHost,
                        connectionPort);
                    // Do not allocate another menu frame between receiving the
                    // connection and leaving this loop. LDC can otherwise
                    // expose a short GC liveness gap for the captured local.
                    if (gameConnection !is null)
                        break;
                }
                renderer.renderMultiplayerScreen(cursor.x, cursor.y,
                    menuTime, serverMenu);
                continue;
            }

            window.clearTextInput();
            const hoveredAction = renderer.titleActionAt(cursor.x, cursor.y);
            window.setCursorShape(hoveredAction == TitleAction.none
                ? CursorShape.arrow : CursorShape.hand);
            if (uiCancelPressed)
            {
                window.running = false;
                break;
            }
            if (uiAcceptPressed)
            {
                if (hoveredAction != TitleAction.none)
                    renderer.playUiButtonClick();
                final switch (hoveredAction)
                {
                    case TitleAction.singleplayer:
                        worldMenu.refresh();
                        worldScreen = true;
                        if (!worldMenu.worlds.length) worldMenu.beginCreate();
                        else
                        {
                            worldMenu.screen = WorldMenuScreen.selection;
                            worldMenu.activate(WorldField.none);
                        }
                        break;
                    case TitleAction.multiplayer:
                        ensureEos();
                        multiplayerScreen = true;
                        serverMenu.error = "";
                        break;
                    case TitleAction.options:
                        options.open(false);
                        break;
                    case TitleAction.account:
                        accountMenu.open(accounts.snapshot);
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
        const connectionStarted = monotonicMilliseconds();
        enum uint connectionTimeoutMilliseconds = 30_000;
        while (window.running && multiplayer.connected()
            && !multiplayer.loginComplete
            && monotonicMilliseconds() - connectionStarted
                < connectionTimeoutMilliseconds)
        {
            window.pumpMessages();
            tickEos();
            const loadingGamepad = window.gamepadState();
            if (window.pressed(VK_ESCAPE)
                || loadingGamepad.pressed(GamepadButton.b)
                || loadingGamepad.pressed(GamepadButton.menu)) break;
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
                renderer.setTitleNotice(multiplayer.disconnectReason.length
                    ? multiplayer.disconnectReason
                    : (integratedServer is null
                        ? "Connection timed out or the host closed the world"
                        : "The local world server did not finish loading"));
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
        bool controllerSprintLatched;
        bool attackToggleState;
        bool useToggleState;
        bool chatMouseSelecting;
        uint lastJumpTapMilliseconds;
        uint dropHeldTicks;
        bool suppressPrimaryUntilRelease = window.down(VK_LBUTTON)
            || window.gamepadState().rightTrigger > 0;
        bool returnToTitle;
        auto announcedAccount=accounts.snapshot;
        string announcedSkinVersion=sharedSkinVersion(announcedAccount);
        string announcedSkinModel=announcedAccount.skinModel.idup;

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
            tickEos();
            if (eosHostBridge !is null)
                eosHostBridge.pump();
            if (!window.running)
                break;
            const current = monotonicSeconds();
            const frameSeconds = fmin(current - previous, 0.25);
            previous = current;
            const gamepad = window.gamepadState();
            const controllerDeadzone = options.number("controllerDeadzone",.05f);
            const controllerLeftX = controllerAxis(gamepad.leftX,
                controllerDeadzone);
            const controllerLeftY = controllerAxis(gamepad.leftY,
                controllerDeadzone);
            const controllerRightX = controllerAxis(gamepad.rightX,
                controllerDeadzone);
            const controllerRightY = controllerAxis(gamepad.rightY,
                controllerDeadzone);
            const controllerUiActive = options.active || deathScreen.active
                || inventoryMenu.active || pauseMenu.active || chat.active;
            const mouseCursor = window.cursorPosition();
            uiNavigation.observe(mouseCursor,gamepad,controllerUiActive);
            Point uiCursor = mouseCursor;
            UiHitTest gameNavigationHitTest;
            ulong gameNavigationToken;
            int gameNavigationNone;
            bool gameNavigationActive;
            if(options.active&&options.fromGame)
            {
                gameNavigationActive=true;
                gameNavigationToken=600+cast(ulong)options.screen;
                gameNavigationHitTest=(int x,int y)=>cast(int)
                    renderer.optionsActionAt(x,y);
            }
            else if(deathScreen.active)
            {
                gameNavigationActive=true;
                gameNavigationToken=700+(deathScreen.hardcore?1:0);
                gameNavigationHitTest=(int x,int y)=>cast(int)
                    renderer.deathActionAt(x,y,deathScreen);
            }
            else if(inventoryMenu.active)
            {
                gameNavigationActive=true;
                gameNavigationToken=800;
                gameNavigationNone=-1;
                gameNavigationHitTest=(int x,int y)=>
                    renderer.inventorySlotAt(x,y);
            }
            else if(pauseMenu.active)
            {
                gameNavigationActive=true;
                gameNavigationToken=900+cast(ulong)pauseMenu.screen;
                const canPublish=integratedServer !is null;
                gameNavigationHitTest=(int x,int y)=>cast(int)
                    renderer.pauseActionAt(x,y,canPublish,pauseMenu);
            }
            if(gameNavigationActive)
            {
                uiNavigation.prepare(gameNavigationToken,gameNavigationNone,
                    gameNavigationHitTest,window.width,window.height);
                const direction=uiNavigation.takeDirection(gamepad,
                    monotonicMilliseconds());
                bool consumed;
                if(options.active&&options.fromGame
                    &&(direction==UiDirection.left
                        ||direction==UiDirection.right))
                {
                    const focused=cast(OptionsAction)uiNavigation.focusedId;
                    if(options.slider(focused))
                    {
                        options.adjustSliderStep(focused,
                            direction==UiDirection.right?1:-1,
                            window.width,window.height);
                        renderer.applyOptions();
                        consumed=true;
                    }
                }
                if(!consumed)uiNavigation.move(direction);
                uiCursor=uiNavigation.cursor(mouseCursor);
            }
            if(controllerUiActive)
                window.setCursorVisible(!uiNavigation.usingController);
            const uiAcceptPressed = window.pressed(VK_LBUTTON)
                || gamepad.pressed(GamepadButton.a);
            const uiPrimaryDown = window.down(VK_LBUTTON)
                || gamepad.down(GamepadButton.a);
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
            if (!multiplayer.loginComplete
                && multiplayer.disconnectReason.length)
            {
                renderer.setTitleNotice(multiplayer.disconnectReason);
                returnToTitle = true;
            }
            accounts.refreshWhenDue();
            const refreshedAccount=accounts.snapshot;
            renderer.syncAccountSkin(refreshedAccount);
            const refreshedSkinVersion=sharedSkinVersion(refreshedAccount);
            if(refreshedSkinVersion!=announcedSkinVersion
                ||refreshedAccount.skinModel!=announcedSkinModel)
            {
                multiplayer.sendProfileUpdate(refreshedSkinVersion,
                    refreshedAccount.skinModel);
                announcedSkinVersion=refreshedSkinVersion.idup;
                announcedSkinModel=refreshedAccount.skinModel.idup;
            }
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
                options.key(OptionsAction.bindChat))
                || gamepad.pressed(GamepadButton.dpadUp)
                || gamepad.pressed(GamepadButton.view);
            const escapePressed = window.pressed(VK_ESCAPE)
                || gamepad.pressed(GamepadButton.menu)
                || (controllerUiActive && gamepad.pressed(GamepadButton.b));
            const enterPressed = window.pressed(VK_RETURN)
                || (chat.active && gamepad.pressed(GamepadButton.a));
            const leftPressed = window.pressed(VK_LEFT);
            const rightPressed = window.pressed(VK_RIGHT);
            const homePressed = window.pressed(VK_HOME);
            const endPressed = window.pressed(VK_END);
            const deletePressed = window.pressed(VK_DELETE);
            const backspacePressed = window.pressed(VK_BACK)
                || window.repeated(VK_BACK);
            const perspectivePressed = window.pressed(
                options.key(OptionsAction.bindPerspective))
                || gamepad.pressed(GamepadButton.rightStick);
            const attackPressed = window.pressed(
                options.key(OptionsAction.bindAttack))
                || gamepad.rightTriggerPressed;
            const pickBlockPressed = window.pressed(
                options.key(OptionsAction.bindPickBlock))
                || gamepad.pressed(GamepadButton.x);
            const dropPressed = window.pressed(
                options.key(OptionsAction.bindDrop))
                || gamepad.pressed(GamepadButton.dpadDown);
            const jumpPressed = window.pressed(
                options.key(OptionsAction.bindJump))
                || gamepad.pressed(GamepadButton.a);
            const inventoryPressed=window.pressed(
                options.key(OptionsAction.bindInventory))
                || gamepad.pressed(GamepadButton.y);
            if (!window.down(VK_LBUTTON) && gamepad.rightTrigger <= 0)
                suppressPrimaryUntilRelease = false;
            if (!chat.active && !pauseMenu.active && !deathScreen.active)
                pendingUse = pendingUse || ((window.pressed(
                    options.key(OptionsAction.bindUse))
                    || gamepad.leftTriggerPressed)
                    && player.gameMode != player.gameMode.adventure
                    && player.gameMode != player.gameMode.spectator);

            if (options.active && options.fromGame)
            {
                window.clearTextInput();
                const cursor = uiCursor;
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
                    && options.slider(hovered) && uiPrimaryDown)
                {
                    if (uiAcceptPressed) renderer.playUiButtonClick();
                    options.adjustSlider(hovered,cursor.x,window.width,window.height);
                    renderer.applyOptions();
                }
                else if (uiAcceptPressed
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
                const cursor = uiCursor;
                const hovered = renderer.deathActionAt(cursor.x,cursor.y,
                    deathScreen);
                window.setCursorShape(hovered == DeathAction.none
                    ? CursorShape.arrow : CursorShape.hand);
                if (uiAcceptPressed
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
                const cursor=uiCursor;
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
                        const pressed=button==0
                            ?uiAcceptPressed
                            :(window.pressed(VK_RBUTTON)
                                ||gamepad.leftTriggerPressed);
                        if(!pressed)continue;
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
                const cursor = uiCursor;
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
                else if (uiAcceptPressed)
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
                                ensureEos();
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
                chatMouseSelecting = false;
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
                const mouse = uiCursor;
                const chatTextInput = window.consumeTextInput();
                const chatTextBackspace = containsCharacter(chatTextInput, 8);
                const chatCursorIndex = renderer.chatCursorAt(mouse.x, mouse.y, chat);
                if (uiAcceptPressed && chatCursorIndex >= 0)
                {
                    chat.setCursor(cast(size_t) chatCursorIndex);
                    chatMouseSelecting = true;
                }
                else if (chatMouseSelecting && uiPrimaryDown
                    && chatCursorIndex >= 0)
                    chat.setCursor(cast(size_t) chatCursorIndex, true);
                if (!uiPrimaryDown)
                    chatMouseSelecting = false;

                const shortcut = window.shortcutDown();
                if (shortcut && window.pressed('A'))
                {
                    window.clearTextInput();
                    chat.selectAll();
                }
                else if (shortcut && window.pressed('C'))
                {
                    window.clearTextInput();
                    if (chat.hasSelection)
                        window.setClipboardText(chat.selectedText);
                }
                else if (shortcut && window.pressed('X'))
                {
                    window.clearTextInput();
                    if (chat.hasSelection)
                    {
                        if (window.setClipboardText(chat.selectedText))
                            chat.cutSelection();
                    }
                }
                else if (shortcut && window.pressed('V'))
                {
                    window.clearTextInput();
                    chat.paste(window.clipboardText());
                }
                else
                    chat.insertCharacters(chatTextInput);
                if (escapePressed)
                {
                    chat.close(options.boolean("chatDrafts",true));
                    chatMouseSelecting = false;
                    window.setMouseCapture(true);
                    window.setCursorShape(CursorShape.arrow);
                }
                else if (enterPressed)
                {
                    chat.submit(multiplayer);
                    chatMouseSelecting = false;
                    window.setMouseCapture(true);
                    window.setCursorShape(CursorShape.arrow);
                }
                else
                {
                    const selecting = window.down(VK_SHIFT);
                    if (leftPressed || window.repeated(VK_LEFT))
                        chat.moveCursor(-1, selecting);
                    if (rightPressed || window.repeated(VK_RIGHT))
                        chat.moveCursor(1, selecting);
                    if (homePressed) chat.moveToStart(selecting);
                    if (endPressed) chat.moveToEnd(selecting);
                    if (backspacePressed || chatTextBackspace) chat.backspace();
                    if (deletePressed || window.repeated(VK_DELETE))
                        chat.deleteForward();
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
                    && (window.pressed(options.key(OptionsAction.bindSneak))
                        || gamepad.pressed(GamepadButton.b)))
                    crouchToggleState=!crouchToggleState;
                if (window.pressed(options.key(OptionsAction.bindSprint)))
                {
                    if (options.integer("sprintMode",0)==1)
                        sprintLatched=!sprintLatched;
                    else
                        sprintLatched=true;
                }
                if (gamepad.pressed(GamepadButton.leftStick))
                    controllerSprintLatched = true;
                if (options.integer("attackMode",0)==1
                    && (window.pressed(options.key(OptionsAction.bindAttack))
                        || gamepad.rightTriggerPressed))
                    attackToggleState=!attackToggleState;
                if (options.integer("useMode",0)==1
                    && (window.pressed(options.key(OptionsAction.bindUse))
                        || gamepad.leftTriggerPressed))
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
            {
                player.look(cast(float) mouse.x * options.mouseSensitivity
                        * (options.invertMouseX ? -1.0f : 1.0f),
                    cast(float) mouse.y * options.mouseSensitivity
                        * (options.invertMouse ? -1.0f : 1.0f));
                // Controller speed is measured directly in degrees/second.
                // At full deflection the 15% default is 348 degrees/second;
                // the options slider spans 240..960 degrees/second.
                const controllerDegreesPerSecond = 240.0f
                    + options.number("controllerSensitivity",.15f) * 720.0f;
                player.lookDegrees(controllerRightX * controllerDegreesPerSecond
                        * cast(float)frameSeconds,
                    -controllerRightY * controllerDegreesPerSecond
                        * cast(float)frameSeconds
                        * (options.boolean("invertControllerY",false)
                            ? -1.0f : 1.0f));
            }
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
            if (controlsActive && gamepad.pressed(GamepadButton.leftBumper))
                player.selectedSlot = (player.selectedSlot + 8) % 9;
            if (controlsActive && gamepad.pressed(GamepadButton.rightBumper))
                player.selectedSlot = (player.selectedSlot + 1) % 9;
            if (controlsActive && gamepad.pressed(GamepadButton.dpadLeft))
                player.selectedSlot = (player.selectedSlot + 8) % 9;
            if (controlsActive && gamepad.pressed(GamepadButton.dpadRight))
                player.selectedSlot = (player.selectedSlot + 1) % 9;
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
                const keyboardForward = (window.down(options.key(
                    OptionsAction.bindForward)) ? 1.0f : 0.0f)
                    - (window.down(options.key(OptionsAction.bindBack))
                        ? 1.0f : 0.0f);
                const keyboardStrafe = (window.down(options.key(
                    OptionsAction.bindRight)) ? 1.0f : 0.0f)
                    - (window.down(options.key(OptionsAction.bindLeft))
                        ? 1.0f : 0.0f);
                const forwardAxis = controlsActive
                    ? (keyboardForward != 0 ? keyboardForward : controllerLeftY)
                    : 0.0f;
                const strafeAxis = controlsActive
                    ? (keyboardStrafe != 0 ? keyboardStrafe : controllerLeftX)
                    : 0.0f;
                const forward = forwardAxis > 0;
                const back = forwardAxis < 0;
                const left = strafeAxis < 0;
                const right = strafeAxis > 0;
                const manualJumping = controlsActive && (window.down(
                    options.key(OptionsAction.bindJump))
                    || gamepad.down(GamepadButton.a));
                const jumping = manualJumping || (controlsActive
                    && options.boolean("autoJump",false)
                    && player.shouldAutoJump(world,forward,back,left,right));
                const crouching = controlsActive && (options.integer("sneakMode",0)==1
                    ? crouchToggleState : (window.down(
                        options.key(OptionsAction.bindSneak))
                        || gamepad.down(GamepadButton.b)));
                const sprintKeyDown = controlsActive
                    && window.down(options.key(OptionsAction.bindSprint));
                if (options.integer("sprintMode",0) == 0)
                    sprintLatched = sprintKeyDown;
                const sprintEligible = controlsActive && forward && !back
                    && !crouching && player.foodLevel > 6;
                if (!sprintEligible
                    || (player.horizontalCollision && !sprintKeyDown))
                {
                    sprintLatched=false;
                    controllerSprintLatched=false;
                }
                const sprinting = sprintEligible
                    && (sprintLatched || controllerSprintLatched)
                    && !player.horizontalCollision;
                const attacking = controlsActive && !suppressPrimaryUntilRelease
                    && (options.integer("attackMode",0)==1 ? attackToggleState
                        : (window.down(options.key(OptionsAction.bindAttack))
                            || gamepad.rightTrigger > 0));
                const dropDown = controlsActive && (window.down(
                    options.key(OptionsAction.bindDrop))
                    || gamepad.down(GamepadButton.dpadDown));
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
                    player.simulateTick(world,forwardAxis,strafeAxis,jumping,
                        crouching,sprinting);
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
                auto inputCommand=PlayerInputCommand(++inputSequence,
                    flags, cast(ubyte) player.selectedSlot, pendingUse,
                    player.yaw, player.pitch, pendingAttack, flightToggle,
                    options.skinParts(),options.mainHandRight());
                inputCommand.moveForward=forwardAxis;
                inputCommand.moveStrafe=strafeAxis;
                auto configuredView=options.integer("renderDistance",6);
                if(configuredView<2)configuredView=2;
                if(configuredView>12)configuredView=12;
                auto configuredSimulation=options.integer("simulationDistance",5);
                if(configuredSimulation<5)configuredSimulation=5;
                if(configuredSimulation>12)configuredSimulation=12;
                inputCommand.viewDistance=cast(ubyte)configuredView;
                inputCommand.simulationDistance=cast(ubyte)configuredSimulation;
                multiplayer.sendPredictedInput(inputCommand);
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
                        accounts.snapshot, connectionEndpoint));
                    catch (Exception) {}
                }
                else if (multiplayer.connected())
                    reconnectTicks = 0;
                accumulator -= tickSeconds;
            }

            const menuCursor = pauseMenu.active
                ? uiCursor : Point(0,0);
            const deathCursor = deathScreen.active
                ? uiCursor : Point(0,0);
            const inventoryCursor=inventoryMenu.active
                ?uiCursor:Point(0,0);
            // A paused client has no next simulation tick to interpolate
            // toward. Render the current authoritative endpoint instead of
            // forcing alpha zero (the stale previous endpoint), which could
            // leave a newly joined client with only the clear sky and HUD.
            const renderPartialTick = worldPaused ? 1.0f
                : cast(float) (accumulator / tickSeconds);
            foreach(remote;multiplayer.remotePlayers())
            {
                const skinPath=accounts.ensureRemoteSkin(remote.accountId,
                    remote.skinVersion);
                if(skinPath.length)renderer.syncRemoteSkin(remote.accountId,
                    remote.skinVersion,skinPath);
            }
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
    static bool containsCharacter(const(wchar)[] text, wchar value)
    {
        foreach (character; text)
            if (character == value) return true;
        return false;
    }

    static GameConnection connectFromMenu(MultiplayerMenuState menu,
        AccountSnapshot account,EosService eos, out ServerEndpoint selected,
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
            auto connection = createConnection(eos, account, endpoint);
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

    static GameConnection createConnection(EosService eos,AccountSnapshot account,
        ServerEndpoint endpoint)
    {
        const name=playerName(account);
        const versionValue=sharedSkinVersion(account);
        if (!endpoint.eos)
            return new GameConnection(name,endpoint.host,endpoint.port,
                account.id,versionValue,account.skinModel);
        if (eos is null || !eos.ready)
        {
            if (eos !is null && eos.status == EosStatus.initializing)
                throw new Exception("EOS is still signing in. Try again in a moment.");
            const detail = eos is null ? "EOS is unavailable" : eos.error;
            throw new Exception(detail.length ? detail : "EOS is unavailable");
        }
        if(endpoint.localPort!=0&&endpoint.eosUserId==eos.localUserId())
            return new GameConnection(name,"127.0.0.1",endpoint.localPort,
                account.id,versionValue,account.skinModel);
        version (MCD_EOS)
            return new GameConnection(eos,name,endpoint,account.id,
                versionValue,account.skinModel);
        else
            throw new Exception("EOS multiplayer is not included in this build");
    }

    static string playerName(const AccountSnapshot account)
    {
        return account.loggedIn&&account.username.length?account.username:"Steve";
    }

    static string sharedSkinVersion(const AccountSnapshot account)
    {
        return account.loggedIn&&account.skinPath.length
            ?to!string(account.updatedAt):"";
    }
}
