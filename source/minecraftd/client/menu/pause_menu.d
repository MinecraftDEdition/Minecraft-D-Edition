module minecraftd.client.menu.pause_menu;

import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.render.mesh : Color, DrawLayer, FrameMesh, Vertex,
    appendQuad;
import minecraftd.common.math3d : Mat4, Vec2, Vec3;

enum PauseAction : ubyte
{
    none,
    resume,
    options,
    publish,
    quit,
    confirmPublish,
    declinePublish,
    copyAddress,
    cancelSubscreen,
}

enum PauseScreen : ubyte
{
    gameMenu,
    publishConfirmation,
    serverInformation,
}

struct PauseTextureSet
{
    uint button;
    uint buttonHighlighted;
    uint buttonDisabled;
    uint white;
}

final class PauseMenuState
{
    bool active;
    bool published;
    string address;
    string notice;
    PauseScreen screen;

    void open()
    {
        active = true;
        screen = PauseScreen.gameMenu;
        notice = "";
    }

    void close()
    {
        active = false;
        screen = PauseScreen.gameMenu;
        notice = "";
    }

    bool back()
    {
        if (screen != PauseScreen.gameMenu)
        {
            screen = PauseScreen.gameMenu;
            notice = "";
            return true;
        }
        close();
        return false;
    }
}

final class PauseMenuRenderer
{
    PauseAction hitTest(uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, bool canPublish,
        const PauseMenuState state) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(int) viewportWidth / scale;
        const logicalHeight = cast(int) viewportHeight / scale;
        const x = mouseX / scale;
        const y = mouseY / scale;
        const center = logicalWidth / 2;
        final switch (state.screen)
        {
            case PauseScreen.publishConfirmation:
                const buttonY = logicalHeight / 2 + 30;
                if (inside(x,y,center-102,buttonY,100,20))
                    return PauseAction.confirmPublish;
                if (inside(x,y,center+2,buttonY,100,20))
                    return PauseAction.declinePublish;
                return PauseAction.none;
            case PauseScreen.serverInformation:
                const copyY = logicalHeight / 2 - 10;
                if (inside(x,y,center-100,copyY,200,20))
                    return PauseAction.copyAddress;
                if (inside(x,y,center-100,copyY+72,200,20))
                    return PauseAction.cancelSubscreen;
                return PauseAction.none;
            case PauseScreen.gameMenu:
                break;
        }
        const firstY = logicalHeight / 4 + 24;
        if (inside(x,y,center-100,firstY,200,20)) return PauseAction.resume;
        if (inside(x,y,center-100,firstY+24,200,20)) return PauseAction.options;
        if (canPublish && inside(x,y,center-100,firstY+48,200,20))
            return PauseAction.publish;
        if (inside(x,y,center-100,firstY+84,200,20)) return PauseAction.quit;
        return PauseAction.none;
    }

    void append(ref FrameMesh frame, uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, bool canPublish, const PauseMenuState state,
        const PauseTextureSet textures, const FontRenderer font,
        uint fontTexture) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(float) viewportWidth / scale;
        const logicalHeight = cast(float) viewportHeight / scale;
        const center = cast(int) logicalWidth / 2;
        const firstY = cast(int) logicalHeight / 4 + 24;
        const hovered = hitTest(viewportWidth, viewportHeight,
            mouseX, mouseY, canPublish, state);

        rect(frame, textures.white, 0, 0, cast(int)logicalWidth,
            cast(int)logicalHeight, logicalWidth, logicalHeight,
            Color(0,0,0,0.52f));
        final switch (state.screen)
        {
            case PauseScreen.publishConfirmation:
                appendConfirmation(frame, hovered, logicalWidth,
                    logicalHeight, center, textures, font, fontTexture);
                return;
            case PauseScreen.serverInformation:
                appendServerInformation(frame, hovered, state,
                    logicalWidth, logicalHeight, center, textures, font,
                    fontTexture);
                return;
            case PauseScreen.gameMenu:
                break;
        }

        centered(frame, "Game Menu", 30, logicalWidth, logicalHeight,
            textures, font, fontTexture, Color(1,1,1,1));
        button(frame, center-100, firstY, 200, "Back to Game",
            hovered == PauseAction.resume, true, logicalWidth, logicalHeight,
            textures, font, fontTexture);
        button(frame, center-100, firstY+24, 200, "Options...",
            hovered == PauseAction.options, true, logicalWidth, logicalHeight,
            textures, font, fontTexture);
        const publishLabel = state.published
            ? "Server information"
            : (canPublish ? "Connect server to multiplayer"
                : "Only the world owner can host");
        button(frame, center-100, firstY+48, 200, publishLabel,
            hovered == PauseAction.publish, canPublish,
            logicalWidth, logicalHeight, textures, font, fontTexture);
        button(frame, center-100, firstY+84, 200, "Save & Quit",
            hovered == PauseAction.quit, true, logicalWidth, logicalHeight,
            textures, font, fontTexture);

        if (state.notice.length)
            centered(frame, state.notice, firstY + 71,
                logicalWidth, logicalHeight, textures, font, fontTexture,
                Color(1.0f,0.75f,0.3f,1));
    }

private:
    static void appendConfirmation(ref FrameMesh frame, PauseAction hovered,
        float logicalWidth, float logicalHeight, int center,
        const PauseTextureSet textures, const FontRenderer font,
        uint fontTexture)
    {
        centered(frame, "Connect server to multiplayer?", 45,
            logicalWidth, logicalHeight, textures, font, fontTexture,
            Color(1,1,1,1));
        centered(frame, "Are you sure you want to connect the server",
            cast(int)logicalHeight / 2 - 18, logicalWidth, logicalHeight,
            textures, font, fontTexture, Color(0.8f,0.8f,0.8f,1));
        centered(frame, "to multiplayer?", cast(int)logicalHeight / 2 - 7,
            logicalWidth, logicalHeight, textures, font, fontTexture,
            Color(0.8f,0.8f,0.8f,1));
        const buttonY = cast(int)logicalHeight / 2 + 30;
        button(frame, center-102, buttonY, 100, "Yes",
            hovered == PauseAction.confirmPublish, true, logicalWidth,
            logicalHeight, textures, font, fontTexture);
        button(frame, center+2, buttonY, 100, "No",
            hovered == PauseAction.declinePublish, true, logicalWidth,
            logicalHeight, textures, font, fontTexture);
    }

    static void appendServerInformation(ref FrameMesh frame,
        PauseAction hovered, const PauseMenuState state, float logicalWidth,
        float logicalHeight, int center, const PauseTextureSet textures,
        const FontRenderer font, uint fontTexture)
    {
        centered(frame, "Multiplayer Server", 45, logicalWidth,
            logicalHeight, textures, font, fontTexture, Color(1,1,1,1));
        centered(frame, "Players can join this world while you are online.",
            cast(int)logicalHeight / 2 - 43, logicalWidth, logicalHeight,
            textures, font, fontTexture, Color(0.8f,0.8f,0.8f,1));
        const copyY = cast(int)logicalHeight / 2 - 10;
        button(frame, center-100, copyY, 200, "Copy to clipboard",
            hovered == PauseAction.copyAddress, true, logicalWidth,
            logicalHeight, textures, font, fontTexture);
        const eosInvitation = state.address.length > 10
            && state.address[0 .. 10] == "mcd://eos/";
        centered(frame, eosInvitation ? "Private EOS Invitation" : "Server Address",
            copyY + 27, logicalWidth,
            logicalHeight, textures, font, fontTexture,
            Color(0.8f,0.8f,0.8f,1));
        // A deliberately non-interactive Java-style text field.
        rect(frame, textures.white, center-100, copyY+38, 200, 20,
            logicalWidth, logicalHeight, Color(0.63f,0.63f,0.63f,1));
        rect(frame, textures.white, center-99, copyY+39, 198, 18,
            logicalWidth, logicalHeight, Color(0.02f,0.02f,0.02f,1));
        text(frame, fitMiddle(state.address, 190, font), center-95, copyY+45, logicalWidth,
            logicalHeight, font, fontTexture, Color(1,1,1,1));
        button(frame, center-100, copyY+72, 200, "Cancel",
            hovered == PauseAction.cancelSubscreen, true, logicalWidth,
            logicalHeight, textures, font, fontTexture);
        if (state.notice.length)
            centered(frame, state.notice, copyY+96, logicalWidth,
                logicalHeight, textures, font, fontTexture,
                Color(0.55f,1.0f,0.55f,1));
    }

    static string fitMiddle(string value, int maximumWidth,
        const FontRenderer font)
    {
        if (font.width(value) <= maximumWidth)
            return value;
        size_t kept = value.length / 2;
        while (kept > 2)
        {
            const left = kept / 2;
            const right = kept - left;
            const candidate = value[0 .. left] ~ "..." ~ value[$ - right .. $];
            if (font.width(candidate) <= maximumWidth)
                return candidate;
            --kept;
        }
        return "...";
    }

    static int guiScale(uint width, uint height)
    {
        int result = 1;
        while (result < 8 && width / (result + 1) >= 320
            && height / (result + 1) >= 240) ++result;
        return result;
    }

    static bool inside(int px,int py,int x,int y,int width,int height)
    {
        return px>=x && px<x+width && py>=y && py<y+height;
    }

    static void button(ref FrameMesh frame, int x, int y, int width,
        string label, bool highlighted, bool enabled, float logicalWidth,
        float logicalHeight, const PauseTextureSet textures,
        const FontRenderer font, uint fontTexture)
    {
        const texture = !enabled ? textures.buttonDisabled
            : (highlighted ? textures.buttonHighlighted : textures.button);
        rect(frame, texture, x, y, width, 20, logicalWidth, logicalHeight,
            Color(1,1,1,1));
        const color = !enabled ? Color(0.63f,0.63f,0.63f,1)
            : (highlighted ? Color(1,1,0.63f,1) : Color(1,1,1,1));
        text(frame, label, x+(width-font.width(label))/2, y+6,
            logicalWidth, logicalHeight, font, fontTexture, color);
    }

    static void centered(ref FrameMesh frame, string value, int y,
        float logicalWidth, float logicalHeight,
        const PauseTextureSet textures, const FontRenderer font,
        uint fontTexture, Color color)
    {
        text(frame,value,(cast(int)logicalWidth-font.width(value))/2,y,
            logicalWidth,logicalHeight,font,fontTexture,color);
    }

    static void text(ref FrameMesh frame, string value, int x, int y,
        float logicalWidth, float logicalHeight, const FontRenderer font,
        uint fontTexture, Color color)
    {
        frame.append(font.buildText(value,x,y,logicalWidth,logicalHeight,color),
            fontTexture,Mat4.identity(),DrawLayer.overlay);
    }

    static void rect(ref FrameMesh frame, uint texture, int x, int y,
        int width, int height, float logicalWidth, float logicalHeight,
        Color color)
    {
        Vertex[] output;
        const left=cast(float)x/logicalWidth*2.0f-1.0f;
        const right=cast(float)(x+width)/logicalWidth*2.0f-1.0f;
        const top=1.0f-cast(float)y/logicalHeight*2.0f;
        const bottom=1.0f-cast(float)(y+height)/logicalHeight*2.0f;
        appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
            Vec3(right,top,0),Vec3(left,top,0),Vec2(0,1),Vec2(1,1),
            Vec2(1,0),Vec2(0,0),color,color,color,color);
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }
}

unittest
{
    auto state = new PauseMenuState();
    state.open();
    assert(state.active);
    assert(state.screen == PauseScreen.gameMenu);
    state.screen = PauseScreen.publishConfirmation;
    assert(state.back());
    assert(state.active && state.screen == PauseScreen.gameMenu);
    assert(!state.back());
    assert(!state.active);
}
