module minecraftd.client.render.title_screen_renderer;

import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.menu.multiplayer_menu_state : MultiplayerField,
    MultiplayerMenuState;
import minecraftd.client.menu.account_menu_state : AccountDialog,
    AccountMenuState;
import minecraftd.client.account.account_service : AccountSnapshot,
    AccountStatus;
import minecraftd.client.menu.world_menu_state : WorldCreationTab, WorldField,
    WorldMenuScreen, WorldMenuState;
import minecraftd.world.world_settings : WorldType, difficultyName,
    gameModeName;
import std.conv : to;
import minecraftd.client.render.mesh : Color, DrawLayer, FrameMesh, Vertex,
    appendQuad;
import minecraftd.common.math3d : DEG_TO_RAD, Mat4, Vec2, Vec3,
    perspectiveFovLH;

enum TitleAction : ubyte
{
    none,
    singleplayer,
    multiplayer,
    options,
    quit,
    account,
}

enum AccountMenuAction : ubyte
{
    none,
    cancel,
    login,
    signup,
    username,
    changePassword,
    changeSkin,
    classicArms,
    slimArms,
    copyId,
    signOut,
    confirmYes,
    confirmNo,
    okay,
}

enum MultiplayerMenuAction : ubyte
{
    none,
    serverName,
    serverAddress,
    connect,
    cancel,
}

enum WorldMenuAction : ubyte
{
    none, worldList, play, create, edit, deleteWorld, recreate, cancel,
    tabGame, tabWorld, tabMore, name, seed, mode, difficulty, commands,
    worldType, structures, bonusChest, gameRules, dataPacks,
    confirmCreate, cancelCreate, confirmDelete, cancelDelete,
}

struct TitleTextureSet
{
    uint[6] panorama;
    uint logo;
    uint edition;
    uint button;
    uint buttonHighlighted;
    uint buttonDisabled;
    uint white;
    uint menuBackground;
    uint dirtBackground;
}

private struct MenuRect
{
    int x;
    int y;
    int width;
    int height;

    bool contains(int pointX, int pointY) const
    {
        return pointX >= x && pointX < x + width
            && pointY >= y && pointY < y + height;
    }
}

/// Builds the Java-style title GUI in logical GUI pixels. Its background is a
/// six-texture cubemap viewed from the center and slowly rotated, matching the
/// structure of Java Edition's PanoramaRenderer/CubeMap pair.
final class TitleScreenRenderer
{
    private string notice;
    private string technology;

    this(string technology)
    {
        this.technology = technology;
    }

    void setNotice(string value)
    {
        notice = value;
    }

    /// Shared title panorama used behind Java's secondary title-menu screens.
    void appendOptionsBackground(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, float elapsedSeconds,
        const TitleTextureSet textures) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        appendMenuBackground(frame, viewportWidth, viewportHeight,
            elapsedSeconds, textures, cast(float) viewportWidth / scale,
            cast(float) viewportHeight / scale);
    }

    TitleAction hitTest(uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(int) viewportWidth / scale;
        const logicalHeight = cast(int) viewportHeight / scale;
        const logicalMouseX = mouseX / scale;
        const logicalMouseY = mouseY / scale;

        foreach (action; [TitleAction.singleplayer, TitleAction.multiplayer,
            TitleAction.options, TitleAction.quit, TitleAction.account])
        {
            if (buttonRect(action, logicalWidth, logicalHeight)
                .contains(logicalMouseX, logicalMouseY))
                return action;
        }
        return TitleAction.none;
    }

    void append(ref FrameMesh frame, uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, float elapsedSeconds,
        const TitleTextureSet textures,
        const FontRenderer font, uint fontTexture) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(float) viewportWidth / scale;
        const logicalHeight = cast(float) viewportHeight / scale;
        const hovered = hitTest(viewportWidth, viewportHeight, mouseX, mouseY);

        appendMenuBackground(frame, viewportWidth, viewportHeight,
            elapsedSeconds, textures, logicalWidth, logicalHeight);

        const logoWidth = 280;
        const logoHeight = 48;
        const logoX = (cast(int) logicalWidth - logoWidth) / 2;
        appendImage(frame, textures.logo, logoX, 24, logoWidth, logoHeight,
            logicalWidth, logicalHeight, Vec2(0, 0), Vec2(1, 1),
            Color(1, 1, 1, 1));
        const editionWidth = 144;
        const editionHeight = 20;
        appendImage(frame, textures.edition,
            (cast(int) logicalWidth - editionWidth) / 2, 67,
            editionWidth, editionHeight, logicalWidth, logicalHeight,
            Vec2(0, 0), Vec2(1, 1), Color(1, 1, 1, 1));

        appendButton(frame, TitleAction.singleplayer, "Singleplayer", hovered,
            cast(int) logicalWidth, cast(int) logicalHeight, textures,
            font, fontTexture);
        appendButton(frame, TitleAction.multiplayer, "Multiplayer", hovered,
            cast(int) logicalWidth, cast(int) logicalHeight, textures,
            font, fontTexture);
        appendButton(frame, TitleAction.options, "Options...", hovered,
            cast(int) logicalWidth, cast(int) logicalHeight, textures,
            font, fontTexture);
        appendButton(frame, TitleAction.quit, "Quit Game", hovered,
            cast(int) logicalWidth, cast(int) logicalHeight, textures,
            font, fontTexture);
        appendButton(frame, TitleAction.account, "Account", hovered,
            cast(int) logicalWidth, cast(int) logicalHeight, textures,
            font, fontTexture);

        if (notice.length != 0)
            appendCenteredText(frame, notice,
                buttonRect(TitleAction.options, cast(int) logicalWidth,
                    cast(int) logicalHeight).y - 12,
                logicalWidth, logicalHeight, font, fontTexture,
                Color(1.0f, 0.45f, 0.35f, 1.0f));

        appendText(frame, "Minecraft: D Edition - fan-made prototype", 2,
            cast(int) logicalHeight - 10, logicalWidth, logicalHeight,
            font, fontTexture, Color(1, 1, 1, 1));
        appendText(frame, technology,
            cast(int) logicalWidth - font.width(technology) - 2,
            cast(int) logicalHeight - 10, logicalWidth, logicalHeight,
            font, fontTexture, Color(1, 1, 1, 1));
    }

    AccountMenuAction accountHitTest(uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, const AccountMenuState state,
        const AccountSnapshot account) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const w = cast(int) viewportWidth / scale;
        const h = cast(int) viewportHeight / scale;
        const x = mouseX / scale, y = mouseY / scale, center = w / 2;
        if (state.dialog == AccountDialog.confirmUsername)
        {
            if (MenuRect(center-102,h/2+18,100,20).contains(x,y))
                return AccountMenuAction.confirmYes;
            if (MenuRect(center+2,h/2+18,100,20).contains(x,y))
                return AccountMenuAction.confirmNo;
            return AccountMenuAction.none;
        }
        if (state.dialog == AccountDialog.message)
            return MenuRect(center-50,h/2+18,100,20).contains(x,y)
                ? AccountMenuAction.okay : AccountMenuAction.none;
        if (!account.loggedIn)
        {
            if (MenuRect(center-120,72,240,20).contains(x,y))
                return AccountMenuAction.login;
            if (MenuRect(center-120,96,240,20).contains(x,y))
                return AccountMenuAction.signup;
            if (MenuRect(center-100,148,200,20).contains(x,y))
                return AccountMenuAction.cancel;
            return AccountMenuAction.none;
        }
        if (MenuRect(center-50,10,100,20).contains(x,y))
            return AccountMenuAction.cancel;
        if (MenuRect(center-150,49,140,20).contains(x,y))
            return AccountMenuAction.username;
        if (MenuRect(center+10,49,140,20).contains(x,y))
            return AccountMenuAction.changePassword;
        if (MenuRect(center+10,73,140,20).contains(x,y))
            return AccountMenuAction.changeSkin;
        if (MenuRect(center-150,201,68,20).contains(x,y))
            return AccountMenuAction.classicArms;
        if (MenuRect(center-78,201,68,20).contains(x,y))
            return AccountMenuAction.slimArms;
        if (MenuRect(center+10,136,140,20).contains(x,y))
            return AccountMenuAction.copyId;
        if (MenuRect(center+10,160,140,20).contains(x,y))
            return AccountMenuAction.signOut;
        return AccountMenuAction.none;
    }

    void appendAccount(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, int mouseX, int mouseY, float elapsedSeconds,
        const AccountMenuState state, const AccountSnapshot account,
        const TitleTextureSet textures, const FontRenderer font,
        uint fontTexture) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const w = cast(float) viewportWidth / scale;
        const h = cast(float) viewportHeight / scale;
        const center = cast(int) w / 2;
        const hovered = accountHitTest(viewportWidth, viewportHeight,
            mouseX, mouseY, state, account);
        appendMenuBackground(frame, viewportWidth, viewportHeight,
            elapsedSeconds, textures, w, h);

        if (!account.loggedIn)
        {
            appendCenteredText(frame, "Minecraft: D Edition Account", 30,
                w,h,font,fontTexture,Color(1,1,1,1));
            appendMenuButton(frame,center-120,72,240,
                "Log in to your MCDE account",hovered==AccountMenuAction.login,
                w,h,textures,font,fontTexture,!account.busy);
            appendMenuButton(frame,center-120,96,240,
                "Sign up for an MCDE account",hovered==AccountMenuAction.signup,
                w,h,textures,font,fontTexture,!account.busy);
            appendCenteredText(frame,"(Or optionally continue as a guest account)",
                126,w,h,font,fontTexture,Color(.72f,.72f,.72f,1));
            appendMenuButton(frame,center-100,148,200,"Cancel",
                hovered==AccountMenuAction.cancel,w,h,textures,font,fontTexture);
            if (account.message.length)
                appendCenteredText(frame,account.message,180,w,h,font,fontTexture,
                    account.status==AccountStatus.error
                        ?Color(1,.35f,.35f,1):Color(.75f,.75f,.75f,1));
            return;
        }

        appendMenuButton(frame,center-50,10,100,"Cancel",
            hovered==AccountMenuAction.cancel,w,h,textures,font,fontTexture);
        appendText(frame,"Username",center-150,38,w,h,font,fontTexture,
            Color(.75f,.75f,.75f,1));
        appendTextField(frame,center-150,49,140,state.usernameInput,
            state.editingUsername,state.edit.cursor,state.edit.selectionAnchor,
            w,h,textures,font,fontTexture);
        appendImage(frame,textures.white,center-150,74,140,112,w,h,
            Vec2(0,0),Vec2(1,1),Color(0,0,0,.88f));
        appendText(frame,"Arm style",center-150,190,w,h,font,fontTexture,
            Color(.75f,.75f,.75f,1));
        appendMenuButton(frame,center-150,201,68,"Classic",
            hovered==AccountMenuAction.classicArms
                ||account.skinModel!="slim",w,h,textures,font,fontTexture,
            !account.busy);
        appendMenuButton(frame,center-78,201,68,"Slim",
            hovered==AccountMenuAction.slimArms
                ||account.skinModel=="slim",w,h,textures,font,fontTexture,
            !account.busy);
        appendMenuButton(frame,center+10,49,140,"Change Password...",
            hovered==AccountMenuAction.changePassword,w,h,textures,font,
            fontTexture,!account.busy);
        appendMenuButton(frame,center+10,73,140,"Change Skin...",
            hovered==AccountMenuAction.changeSkin,w,h,textures,font,
            fontTexture,!account.busy);
        appendText(frame,"Player ID",center+10,101,w,h,font,fontTexture,
            Color(.75f,.75f,.75f,1));
        appendTextField(frame,center+10,112,140,account.id,false,0,0,w,h,
            textures,font,fontTexture);
        appendMenuButton(frame,center+10,136,140,"Copy to clipboard",
            hovered==AccountMenuAction.copyId,w,h,textures,font,fontTexture);
        appendMenuButton(frame,center+10,160,140,"Sign Out",
            hovered==AccountMenuAction.signOut,w,h,textures,font,fontTexture,
            !account.busy);
        if (account.message.length)
            appendCenteredText(frame,account.message,224,w,h,font,fontTexture,
                Color(.78f,.78f,.78f,1));

        if (state.dialog != AccountDialog.none)
        {
            appendImage(frame,textures.white,0,0,cast(int)w,cast(int)h,w,h,
                Vec2(0,0),Vec2(1,1),Color(0,0,0,.72f));
            if (state.dialog == AccountDialog.confirmUsername)
            {
                appendCenteredText(frame,"Are you sure you want to change",
                    cast(int)h/2-28,w,h,font,fontTexture,Color(1,1,1,1));
                appendCenteredText(frame,state.originalUsername~" to "
                    ~state.usernameInput~"?",cast(int)h/2-14,w,h,font,
                    fontTexture,Color(1,1,1,1));
                appendMenuButton(frame,center-102,cast(int)h/2+18,100,"Yes",
                    hovered==AccountMenuAction.confirmYes,w,h,textures,font,fontTexture);
                appendMenuButton(frame,center+2,cast(int)h/2+18,100,"No",
                    hovered==AccountMenuAction.confirmNo,w,h,textures,font,fontTexture);
            }
            else
            {
                appendCenteredText(frame,state.dialogMessage,cast(int)h/2-18,
                    w,h,font,fontTexture,Color(1,1,1,1));
                appendMenuButton(frame,center-50,cast(int)h/2+18,100,"Okay",
                    hovered==AccountMenuAction.okay,w,h,textures,font,fontTexture);
            }
        }
    }

    long accountTextCursorAt(uint viewportWidth, uint viewportHeight, int mouseX,
        const AccountMenuState state, const FontRenderer font) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const center = cast(int) viewportWidth / scale / 2;
        return textFieldCursorAt(state.usernameInput,state.edit.cursor,140,
            mouseX/scale-(center-150),font);
    }

    MultiplayerMenuAction multiplayerHitTest(uint viewportWidth,
        uint viewportHeight, int mouseX, int mouseY) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(int) viewportWidth / scale;
        const logicalHeight = cast(int) viewportHeight / scale;
        const x = mouseX / scale;
        const y = mouseY / scale;
        const center = logicalWidth / 2;
        if (MenuRect(center - 150, 64, 300, 20).contains(x, y))
            return MultiplayerMenuAction.serverName;
        if (MenuRect(center - 150, 103, 300, 20).contains(x, y))
            return MultiplayerMenuAction.serverAddress;
        const buttonY = logicalHeight / 2 + 28;
        if (MenuRect(center - 150, buttonY, 148, 20).contains(x, y))
            return MultiplayerMenuAction.connect;
        if (MenuRect(center + 2, buttonY, 148, 20).contains(x, y))
            return MultiplayerMenuAction.cancel;
        return MultiplayerMenuAction.none;
    }

    void appendMultiplayer(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, int mouseX, int mouseY, float elapsedSeconds,
        const MultiplayerMenuState state, const TitleTextureSet textures,
        const FontRenderer font, uint fontTexture) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(float) viewportWidth / scale;
        const logicalHeight = cast(float) viewportHeight / scale;
        const center = cast(int) logicalWidth / 2;
        const hovered = multiplayerHitTest(viewportWidth, viewportHeight,
            mouseX, mouseY);
        appendMenuBackground(frame, viewportWidth, viewportHeight,
            elapsedSeconds, textures, logicalWidth, logicalHeight);

        appendCenteredText(frame, "Play Multiplayer", 20, logicalWidth,
            logicalHeight, font, fontTexture, Color(1,1,1,1));
        appendText(frame, "Server Name", center - 150, 53, logicalWidth,
            logicalHeight, font, fontTexture, Color(0.75f,0.75f,0.75f,1));
        appendTextField(frame, center - 150, 64, 300, state.serverName,
            state.activeField == MultiplayerField.serverName,
            state.activeField == MultiplayerField.serverName ? state.cursor : 0,
            state.activeField == MultiplayerField.serverName
                ? state.selectionAnchor : 0,
            logicalWidth, logicalHeight, textures, font, fontTexture);
        appendText(frame, "Server Address", center - 150, 92, logicalWidth,
            logicalHeight, font, fontTexture, Color(0.75f,0.75f,0.75f,1));
        appendTextField(frame, center - 150, 103, 300, state.serverAddress,
            state.activeField == MultiplayerField.serverAddress,
            state.activeField == MultiplayerField.serverAddress ? state.cursor : 0,
            state.activeField == MultiplayerField.serverAddress
                ? state.selectionAnchor : 0,
            logicalWidth, logicalHeight, textures, font, fontTexture);

        const buttonY = cast(int) logicalHeight / 2 + 28;
        appendMenuButton(frame, center - 150, buttonY, 148, "Connect",
            hovered == MultiplayerMenuAction.connect, logicalWidth,
            logicalHeight, textures, font, fontTexture);
        appendMenuButton(frame, center + 2, buttonY, 148, "Cancel",
            hovered == MultiplayerMenuAction.cancel, logicalWidth,
            logicalHeight, textures, font, fontTexture);
        if (state.error.length)
            appendCenteredText(frame, state.error, buttonY + 28,
                logicalWidth, logicalHeight, font, fontTexture,
                Color(1.0f,0.35f,0.35f,1));
        else
            appendCenteredText(frame,
                "The server exists only while its owner is online.",
                buttonY + 28, logicalWidth, logicalHeight, font, fontTexture,
                Color(0.7f,0.7f,0.7f,1));
    }

    long multiplayerTextCursorAt(uint viewportWidth, uint viewportHeight,
        int mouseX, const MultiplayerMenuState state,
        MultiplayerField field, const FontRenderer font) const
    {
        if (field == MultiplayerField.none) return -1;
        const scale = guiScale(viewportWidth, viewportHeight);
        const center = cast(int) viewportWidth / scale / 2;
        const value = field == MultiplayerField.serverName
            ? state.serverName : state.serverAddress;
        const cursor = field == state.activeField ? state.cursor : value.length;
        return textFieldCursorAt(value, cursor, 300,
            mouseX / scale - (center - 150), font);
    }

    WorldMenuAction worldMenuHitTest(uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, const WorldMenuState state) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const w = cast(int) viewportWidth / scale;
        const h = cast(int) viewportHeight / scale;
        const x = mouseX / scale, y = mouseY / scale, center = w / 2;
        if (state.screen == WorldMenuScreen.confirmDelete)
        {
            if (MenuRect(center-102,h/2+18,100,20).contains(x,y)) return WorldMenuAction.confirmDelete;
            if (MenuRect(center+2,h/2+18,100,20).contains(x,y)) return WorldMenuAction.cancelDelete;
            return WorldMenuAction.none;
        }
        if (state.screen == WorldMenuScreen.selection)
        {
            if (MenuRect(center-150,42,300,h-106).contains(x,y)) return WorldMenuAction.worldList;
            const first = h-52, second = h-28;
            if (MenuRect(center-150,first,148,20).contains(x,y)) return WorldMenuAction.play;
            if (MenuRect(center+2,first,148,20).contains(x,y)) return WorldMenuAction.create;
            if (MenuRect(center-150,second,72,20).contains(x,y)) return WorldMenuAction.edit;
            if (MenuRect(center-74,second,72,20).contains(x,y)) return WorldMenuAction.deleteWorld;
            if (MenuRect(center+2,second,72,20).contains(x,y)) return WorldMenuAction.recreate;
            if (MenuRect(center+78,second,72,20).contains(x,y)) return WorldMenuAction.cancel;
            return WorldMenuAction.none;
        }
        if (MenuRect(center-150,30,98,20).contains(x,y)) return WorldMenuAction.tabGame;
        if (MenuRect(center-49,30,98,20).contains(x,y)) return WorldMenuAction.tabWorld;
        if (MenuRect(center+52,30,98,20).contains(x,y)) return WorldMenuAction.tabMore;
        if (MenuRect(center-150,h-28,148,20).contains(x,y)) return WorldMenuAction.confirmCreate;
        if (MenuRect(center+2,h-28,148,20).contains(x,y)) return WorldMenuAction.cancelCreate;
        final switch (state.tab)
        {
            case WorldCreationTab.game:
                if (MenuRect(center-150,68,300,20).contains(x,y)) return WorldMenuAction.name;
                if (MenuRect(center-150,105,148,20).contains(x,y)) return WorldMenuAction.mode;
                if (MenuRect(center+2,105,148,20).contains(x,y)) return WorldMenuAction.difficulty;
                if (MenuRect(center-150,138,300,20).contains(x,y)) return WorldMenuAction.commands;
                break;
            case WorldCreationTab.world:
                if (MenuRect(center-150,68,300,20).contains(x,y)) return WorldMenuAction.seed;
                if (MenuRect(center-150,105,300,20).contains(x,y)) return WorldMenuAction.worldType;
                if (MenuRect(center-150,138,148,20).contains(x,y)) return WorldMenuAction.structures;
                if (MenuRect(center+2,138,148,20).contains(x,y)) return WorldMenuAction.bonusChest;
                break;
            case WorldCreationTab.more:
                if (MenuRect(center-150,68,300,20).contains(x,y)) return WorldMenuAction.gameRules;
                if (MenuRect(center-150,92,300,20).contains(x,y)) return WorldMenuAction.dataPacks;
                break;
        }
        return WorldMenuAction.none;
    }

    int worldRowAt(uint viewportWidth, uint viewportHeight, int mouseY,
        const WorldMenuState state) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const y = mouseY / scale;
        const row = (y - 46) / 32;
        return y >= 46 && row >= 0 && row < state.worlds.length ? row : -1;
    }

    void appendWorldMenu(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, int mouseX, int mouseY,
        const WorldMenuState state, const TitleTextureSet textures,
        const FontRenderer font, uint fontTexture) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const w = cast(float) viewportWidth / scale;
        const h = cast(float) viewportHeight / scale;
        const center = cast(int) w / 2;
        appendDirtMenuBackground(frame, w, h, textures);
        const hovered = worldMenuHitTest(viewportWidth, viewportHeight,
            mouseX, mouseY, state);
        if (state.screen == WorldMenuScreen.confirmDelete)
        {
            appendCenteredText(frame, "Delete World?", cast(int)h/2-32,w,h,font,fontTexture,Color(1,1,1,1));
            const name = state.hasSelection ? state.worlds[state.selected].settings.name : "this world";
            appendCenteredText(frame, "'"~name~"' will be lost forever!",cast(int)h/2-12,w,h,font,fontTexture,Color(1,0.35f,0.35f,1));
            appendMenuButton(frame,center-102,cast(int)h/2+18,100,"Delete",hovered==WorldMenuAction.confirmDelete,w,h,textures,font,fontTexture);
            appendMenuButton(frame,center+2,cast(int)h/2+18,100,"Cancel",hovered==WorldMenuAction.cancelDelete,w,h,textures,font,fontTexture);
            return;
        }
        if (state.screen == WorldMenuScreen.selection)
        {
            appendCenteredText(frame,"Select World",18,w,h,font,fontTexture,Color(1,1,1,1));
            appendImage(frame,textures.white,center-150,42,300,cast(int)h-106,w,h,Vec2(0,0),Vec2(1,1),Color(0,0,0,0.62f));
            foreach (index, entry; state.worlds)
            {
                const y = 46 + cast(int)index*32;
                if (y+28 > h-64) break;
                if (cast(int)index == state.selected)
                    appendImage(frame,textures.white,center-146,y,292,28,w,h,Vec2(0,0),Vec2(1,1),Color(0.35f,0.35f,0.35f,0.8f));
                appendText(frame,entry.settings.name,center-138,y+4,w,h,font,fontTexture,Color(1,1,1,1));
                const detail = (entry.settings.hardcore ? "Hardcore" : gameModeName(entry.settings.gameMode))
                    ~ ", Seed: " ~ to!string(entry.settings.seed);
                appendText(frame,detail,center-138,y+16,w,h,font,fontTexture,Color(0.6f,0.6f,0.6f,1));
            }
            if (!state.worlds.length)
                appendCenteredText(frame,"No worlds found",cast(int)h/2-8,w,h,font,fontTexture,Color(0.7f,0.7f,0.7f,1));
            const first=cast(int)h-52, second=cast(int)h-28;
            appendMenuButton(frame,center-150,first,148,"Play Selected World",hovered==WorldMenuAction.play,w,h,textures,font,fontTexture,state.hasSelection);
            appendMenuButton(frame,center+2,first,148,"Create New World",hovered==WorldMenuAction.create,w,h,textures,font,fontTexture);
            appendMenuButton(frame,center-150,second,72,"Edit",hovered==WorldMenuAction.edit,w,h,textures,font,fontTexture,state.hasSelection);
            appendMenuButton(frame,center-74,second,72,"Delete",hovered==WorldMenuAction.deleteWorld,w,h,textures,font,fontTexture,state.hasSelection);
            appendMenuButton(frame,center+2,second,72,"Re-Create",hovered==WorldMenuAction.recreate,w,h,textures,font,fontTexture,state.hasSelection);
            appendMenuButton(frame,center+78,second,72,"Cancel",hovered==WorldMenuAction.cancel,w,h,textures,font,fontTexture);
            return;
        }
        appendCenteredText(frame,state.editing?"Edit World":"Create New World",12,w,h,font,fontTexture,Color(1,1,1,1));
        appendTab(frame,center-150,30,98,"Game",state.tab==WorldCreationTab.game,hovered==WorldMenuAction.tabGame,w,h,textures,font,fontTexture);
        appendTab(frame,center-49,30,98,"World",state.tab==WorldCreationTab.world,hovered==WorldMenuAction.tabWorld,w,h,textures,font,fontTexture);
        appendTab(frame,center+52,30,98,"More",state.tab==WorldCreationTab.more,hovered==WorldMenuAction.tabMore,w,h,textures,font,fontTexture);
        final switch(state.tab)
        {
            case WorldCreationTab.game:
                appendText(frame,"World Name",center-150,57,w,h,font,fontTexture,Color(.75f,.75f,.75f,1));
                appendTextField(frame,center-150,68,300,state.draft.name,
                    state.field==WorldField.name,
                    state.field==WorldField.name ? state.cursor : 0,
                    state.field==WorldField.name ? state.selectionAnchor : 0,
                    w,h,textures,font,fontTexture);
                appendMenuButton(frame,center-150,105,148,"Game Mode: "~state.modeLabel,hovered==WorldMenuAction.mode,w,h,textures,font,fontTexture);
                appendMenuButton(frame,center+2,105,148,"Difficulty: "~difficultyName(state.draft.difficulty),hovered==WorldMenuAction.difficulty,w,h,textures,font,fontTexture,!state.draft.hardcore);
                appendMenuButton(frame,center-150,138,300,"Allow Commands: "~(state.draft.allowCommands?"ON":"OFF"),hovered==WorldMenuAction.commands,w,h,textures,font,fontTexture,!state.draft.hardcore);
                break;
            case WorldCreationTab.world:
                appendText(frame,"Seed (blank = random)",center-150,57,w,h,font,fontTexture,Color(.75f,.75f,.75f,1));
                appendTextField(frame,center-150,68,300,state.seedInput,
                    state.field==WorldField.seed,
                    state.field==WorldField.seed ? state.cursor : 0,
                    state.field==WorldField.seed ? state.selectionAnchor : 0,
                    w,h,textures,font,fontTexture);
                appendMenuButton(frame,center-150,105,300,"World Type: "~(state.draft.worldType==WorldType.normal?"Normal":"Flat"),hovered==WorldMenuAction.worldType,w,h,textures,font,fontTexture,!state.editing);
                appendMenuButton(frame,center-150,138,148,"Structures: "~(state.draft.generateStructures?"ON":"OFF"),hovered==WorldMenuAction.structures,w,h,textures,font,fontTexture,!state.editing);
                appendMenuButton(frame,center+2,138,148,"Bonus Chest: "~(state.draft.bonusChest?"ON":"OFF"),hovered==WorldMenuAction.bonusChest,w,h,textures,font,fontTexture,!state.editing);
                break;
            case WorldCreationTab.more:
                appendMenuButton(frame,center-150,68,300,"Game Rules",hovered==WorldMenuAction.gameRules,w,h,textures,font,fontTexture);
                appendMenuButton(frame,center-150,92,300,"Data Packs",hovered==WorldMenuAction.dataPacks,w,h,textures,font,fontTexture,false);
                appendCenteredText(frame,"Data packs require custom registries and are not active yet.",124,w,h,font,fontTexture,Color(.65f,.65f,.65f,1));
                break;
        }
        if (state.notice.length) appendCenteredText(frame,state.notice,cast(int)h-42,w,h,font,fontTexture,Color(1,.8f,.3f,1));
        appendMenuButton(frame,center-150,cast(int)h-28,148,state.editing?"Save Changes":"Create New World",hovered==WorldMenuAction.confirmCreate,w,h,textures,font,fontTexture);
        appendMenuButton(frame,center+2,cast(int)h-28,148,"Cancel",hovered==WorldMenuAction.cancelCreate,w,h,textures,font,fontTexture);
    }

    long worldTextCursorAt(uint viewportWidth, uint viewportHeight,
        int mouseX, const WorldMenuState state, WorldField field,
        const FontRenderer font) const
    {
        if (field == WorldField.none) return -1;
        const scale = guiScale(viewportWidth, viewportHeight);
        const center = cast(int) viewportWidth / scale / 2;
        const value = field == WorldField.name ? state.draft.name : state.seedInput;
        const cursor = field == state.field ? state.cursor : value.length;
        return textFieldCursorAt(value, cursor, 300,
            mouseX / scale - (center - 150), font);
    }

    void appendLoading(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, string status, int percent,
        const TitleTextureSet textures, const FontRenderer font,
        uint fontTexture) const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const w=cast(float)viewportWidth/scale,h=cast(float)viewportHeight/scale;
        appendFlatMenuBackground(frame,w,h,textures);
        const center=cast(int)w/2, top=cast(int)h/2-58;
        appendCenteredText(frame,status,top-18,w,h,font,fontTexture,Color(1,1,1,1));
        appendImage(frame,textures.white,center-52,top,104,104,w,h,Vec2(0,0),Vec2(1,1),Color(0,0,0,1));
        foreach(z;0..9) foreach(x;0..9)
        {
            const dx=x-4,dz=z-4;
            const order=cast(int)(((dx*dx+dz*dz)*100)/33);
            const stage = percent - cast(int)(order * 0.72f);
            Color color;
            if(stage<=0) color=Color(0,0,0,1);
            else if(stage<9) color=rgb(0x545454);
            else if(stage<18) color=rgb(0x999999);
            else if(stage<27) color=rgb(0x5F6191);
            else if(stage<36) color=rgb(0x80B252);
            else if(stage<48) color=rgb(0xD1D1D1);
            else if(stage<58) color=rgb(0x726809);
            else if(stage<68) color=rgb(0x303572);
            else if(stage<78) color=rgb(0x21C600);
            else if(stage<87) color=rgb(0xCCCCCC);
            else if(stage<94) color=rgb(0xFFE0A0);
            else if(stage<100) color=rgb(0xF26060);
            else color=rgb(0xFFFFFF);
            appendImage(frame,textures.white,center-45+x*10,top+7+z*10,9,9,w,h,Vec2(0,0),Vec2(1,1),color);
        }
        appendCenteredText(frame,to!string(percent)~"%",top+112,w,h,font,fontTexture,Color(1,1,1,1));
        appendImage(frame,textures.white,center-50,top+124,100,2,w,h,
            Vec2(0,0),Vec2(1,1),Color(0,0,0,1));
        if(percent>0) appendImage(frame,textures.white,center-50,top+124,
            percent,2,w,h,Vec2(0,0),Vec2(1,1),Color(0,1,0,1));
    }

private:
    static Color rgb(uint value)
    {
        return Color(cast(float)((value>>16)&255)/255.0f,
            cast(float)((value>>8)&255)/255.0f,
            cast(float)(value&255)/255.0f,1);
    }

    static void appendFlatMenuBackground(ref FrameMesh frame, float w,
        float h, const TitleTextureSet textures)
    {
        foreach (y; 0 .. cast(int)h / 32 + 1)
        foreach (x; 0 .. cast(int)w / 32 + 1)
            appendImage(frame,textures.menuBackground,x*32,y*32,32,32,
                w,h,Vec2(0,0),Vec2(1,1),Color(.58f,.58f,.58f,1));
        appendImage(frame,textures.white,0,0,cast(int)w,cast(int)h,
            w,h,Vec2(0,0),Vec2(1,1),Color(0,0,0,.28f));
    }

    static void appendDirtMenuBackground(ref FrameMesh frame, float w,
        float h, const TitleTextureSet textures)
    {
        foreach (y; 0 .. cast(int)h / 32 + 1)
        foreach (x; 0 .. cast(int)w / 32 + 1)
            appendImage(frame, textures.dirtBackground, x * 32, y * 32,
                32, 32, w, h, Vec2(0,0), Vec2(1,1),
                Color(0.52f,0.52f,0.52f,1));
    }

    static void appendTab(ref FrameMesh frame,int x,int y,int width,
        string label,bool active,bool highlighted,float w,float h,
        const TitleTextureSet textures,const FontRenderer font,uint fontTexture)
    {
        appendMenuButton(frame,x,y,width,label,highlighted,w,h,textures,font,
            fontTexture,!active);
    }

    static void appendMenuBackground(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, float elapsedSeconds,
        const TitleTextureSet textures, float logicalWidth, float logicalHeight)
    {
        const aspect = cast(float) viewportWidth / viewportHeight;
        const panoramaTransform = Mat4.rotationX(25.0f * DEG_TO_RAD)
            * Mat4.rotationY(-elapsedSeconds * 1.0f * DEG_TO_RAD)
            * perspectiveFovLH(85.0f * DEG_TO_RAD, aspect, 0.01f, 10.0f);
        appendPanorama(frame, textures.panorama, panoramaTransform);
        appendImage(frame, textures.white, 0, 0,
            cast(int) logicalWidth, cast(int) logicalHeight,
            logicalWidth, logicalHeight, Vec2(0, 0), Vec2(1, 1),
            Color(0.0f, 0.0f, 0.0f, 0.35f));
    }

    static void appendPanorama(ref FrameMesh frame, const uint[6] textures,
        Mat4 transform)
    {
        const white = Color(1, 1, 1, 1);
        void face(uint texture, Vec3 p0, Vec3 p1, Vec3 p2, Vec3 p3)
        {
            Vertex[] output;
            appendQuad(output, p0, p1, p2, p3,
                Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
                white, white, white, white);
            frame.append(output, texture, transform, DrawLayer.sky);
        }

        // panorama_0..5 are the four horizon faces, top, and bottom. These
        // windings are viewed from inside the cube; culling is disabled by the
        // shared sky pipeline, as in the game's other sky geometry.
        face(textures[0], Vec3(-1,-1, 1), Vec3( 1,-1, 1),
            Vec3( 1, 1, 1), Vec3(-1, 1, 1));
        face(textures[1], Vec3( 1,-1, 1), Vec3( 1,-1,-1),
            Vec3( 1, 1,-1), Vec3( 1, 1, 1));
        face(textures[2], Vec3( 1,-1,-1), Vec3(-1,-1,-1),
            Vec3(-1, 1,-1), Vec3( 1, 1,-1));
        face(textures[3], Vec3(-1,-1,-1), Vec3(-1,-1, 1),
            Vec3(-1, 1, 1), Vec3(-1, 1,-1));
        face(textures[4], Vec3(-1, 1, 1), Vec3( 1, 1, 1),
            Vec3( 1, 1,-1), Vec3(-1, 1,-1));
        face(textures[5], Vec3(-1,-1,-1), Vec3( 1,-1,-1),
            Vec3( 1,-1, 1), Vec3(-1,-1, 1));
    }

    static int guiScale(uint width, uint height)
    {
        int result = 1;
        while (result < 8 && width / (result + 1) >= 320
            && height / (result + 1) >= 240)
            ++result;
        return result;
    }

    static MenuRect buttonRect(TitleAction action, int logicalWidth,
        int logicalHeight)
    {
        const center = logicalWidth / 2;
        const firstY = logicalHeight / 4 + 48;
        final switch (action)
        {
            case TitleAction.singleplayer:
                return MenuRect(center - 100, firstY, 200, 20);
            case TitleAction.multiplayer:
                return MenuRect(center - 100, firstY + 24, 200, 20);
            case TitleAction.options:
                return MenuRect(center - 100, firstY + 48, 98, 20);
            case TitleAction.quit:
                return MenuRect(center + 2, firstY + 48, 98, 20);
            case TitleAction.account:
                return MenuRect(center - 100, firstY + 72, 200, 20);
            case TitleAction.none:
                return MenuRect.init;
        }
    }

    static void appendButton(ref FrameMesh frame, TitleAction action,
        string label, TitleAction hovered, int logicalWidth, int logicalHeight,
        const TitleTextureSet textures, const FontRenderer font,
        uint fontTexture)
    {
        const rect = buttonRect(action, logicalWidth, logicalHeight);
        const texture = hovered == action
            ? textures.buttonHighlighted : textures.button;
        appendImage(frame, texture, rect.x, rect.y, rect.width, rect.height,
            logicalWidth, logicalHeight, Vec2(0, 0), Vec2(1, 1),
            Color(1, 1, 1, 1));
        const color = hovered == action
            ? Color(1.0f, 1.0f, 0.63f, 1.0f) : Color(1, 1, 1, 1);
        appendText(frame, label,
            rect.x + (rect.width - font.width(label)) / 2, rect.y + 6,
            logicalWidth, logicalHeight, font, fontTexture, color);
    }

    static void appendMenuButton(ref FrameMesh frame, int x, int y, int width,
        string label, bool highlighted, float logicalWidth,
        float logicalHeight, const TitleTextureSet textures,
        const FontRenderer font, uint fontTexture, bool enabled = true)
    {
        appendImage(frame, !enabled ? textures.buttonDisabled
                : (highlighted ? textures.buttonHighlighted : textures.button),
            x, y, width, 20, logicalWidth, logicalHeight,
            Vec2(0,0), Vec2(1,1), Color(1,1,1,1));
        appendText(frame, label, x + (width - font.width(label)) / 2, y + 6,
            logicalWidth, logicalHeight, font, fontTexture,
            !enabled ? Color(.62f,.62f,.62f,1)
                : (highlighted ? Color(1,1,0.63f,1) : Color(1,1,1,1)));
    }

    static void appendTextField(ref FrameMesh frame, int x, int y, int width,
        string value, bool active, size_t cursor, size_t selectionAnchor,
        float logicalWidth, float logicalHeight,
        const TitleTextureSet textures, const FontRenderer font,
        uint fontTexture)
    {
        appendImage(frame, textures.white, x, y, width, 20,
            logicalWidth, logicalHeight, Vec2(0,0), Vec2(1,1),
            active ? Color(1,1,1,0.95f) : Color(0.63f,0.63f,0.63f,0.95f));
        appendImage(frame, textures.white, x + 1, y + 1, width - 2, 18,
            logicalWidth, logicalHeight, Vec2(0,0), Vec2(1,1),
            Color(0.04f,0.04f,0.04f,0.96f));
        size_t start, end;
        textFieldVisibleRange(value, cursor, width, font, start, end);
        if (active && cursor != selectionAnchor)
        {
            const selectionStart = cursor < selectionAnchor
                ? cursor : selectionAnchor;
            const selectionEnd = cursor > selectionAnchor
                ? cursor : selectionAnchor;
            const first = selectionStart > start ? selectionStart : start;
            const after = selectionEnd < end ? selectionEnd : end;
            if (first < after)
            {
                const left = x + 4 + font.width(value[start .. first]);
                const right = x + 4 + font.width(value[start .. after]);
                appendImage(frame, textures.white, left, y + 4,
                    right - left, 12, logicalWidth, logicalHeight,
                    Vec2(0,0), Vec2(1,1), Color(.25f,.45f,.85f,.8f));
            }
        }
        appendText(frame, value[start .. end], x + 4, y + 6,
            logicalWidth, logicalHeight, font, fontTexture,
            Color(1,1,1,1));
        if (active)
        {
            const caret = cursor <= value.length ? cursor : value.length;
            const caretX = x + 4 + font.width(value[start .. caret]);
            appendImage(frame, textures.white, caretX, y + 5, 1, 10,
                logicalWidth, logicalHeight, Vec2(0,0), Vec2(1,1),
                Color(1,1,1,1));
        }
    }

    static void textFieldVisibleRange(string value, size_t cursor, int width,
        const FontRenderer font, out size_t start, out size_t end)
    {
        cursor = cursor <= value.length ? cursor : value.length;
        start = cursor;
        while (start > 0
            && font.width(value[start - 1 .. cursor]) <= width - 12)
            --start;
        end = cursor;
        while (end < value.length
            && font.width(value[start .. end + 1]) <= width - 12)
            ++end;
    }

    static long textFieldCursorAt(string value, size_t cursor, int width,
        int localMouseX, const FontRenderer font)
    {
        size_t start, end;
        textFieldVisibleRange(value, cursor, width, font, start, end);
        const target = localMouseX - 4;
        if (target <= 0) return cast(long) start;
        if (target >= width - 8 && end < value.length)
            return cast(long) end + 1;
        int previous;
        foreach (position; start .. end)
        {
            const next = font.width(value[start .. position + 1]);
            if (target < previous + (next - previous) / 2)
                return cast(long) position;
            previous = next;
        }
        return cast(long) end;
    }

    static void appendCenteredText(ref FrameMesh frame, string value, int y,
        float logicalWidth, float logicalHeight, const FontRenderer font,
        uint fontTexture, Color color)
    {
        appendText(frame, value,
            (cast(int) logicalWidth - font.width(value)) / 2, y,
            logicalWidth, logicalHeight, font, fontTexture, color);
    }

    static void appendText(ref FrameMesh frame, string value, int x, int y,
        float logicalWidth, float logicalHeight, const FontRenderer font,
        uint fontTexture, Color color)
    {
        frame.append(font.buildText(value, x, y, logicalWidth, logicalHeight,
            color), fontTexture, Mat4.identity(), DrawLayer.overlay);
    }

    static void appendImage(ref FrameMesh frame, uint texture, int x, int y,
        int imageWidth, int imageHeight, float logicalWidth,
        float logicalHeight, Vec2 uvMin, Vec2 uvMax, Color color)
    {
        Vertex[] output;
        const left = cast(float) x / logicalWidth * 2.0f - 1.0f;
        const right = cast(float) (x + imageWidth) / logicalWidth * 2.0f - 1.0f;
        const top = 1.0f - cast(float) y / logicalHeight * 2.0f;
        const bottom = 1.0f - cast(float) (y + imageHeight) / logicalHeight * 2.0f;
        appendQuad(output,
            Vec3(left, bottom, 0), Vec3(right, bottom, 0),
            Vec3(right, top, 0), Vec3(left, top, 0),
            Vec2(uvMin.x,uvMax.y), Vec2(uvMax.x,uvMax.y),
            Vec2(uvMax.x,uvMin.y), Vec2(uvMin.x,uvMin.y),
            color, color, color, color);
        frame.append(output, texture, Mat4.identity(), DrawLayer.overlay);
    }
}
