module minecraftd.client.menu.death_screen;

import std.conv : to;

import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.render.mesh : Color, DrawLayer, FrameMesh, Vertex,
    appendQuad;
import minecraftd.common.math3d : Mat4, Vec2, Vec3;

enum DeathAction : ubyte
{
    none,
    respawn,
    titleScreen,
}

struct DeathTextureSet
{
    uint button;
    uint buttonHighlighted;
    uint buttonDisabled;
    uint white;
}

final class DeathScreenState
{
    bool active;
    bool hardcore;
    bool awaitingServer;
    uint ticksSinceDeath;
    int score;
    string cause;

    void open(bool hardcore, int score, string cause)
    {
        active = true;
        this.hardcore = hardcore;
        this.score = score;
        this.cause = cause;
        ticksSinceDeath = 0;
        awaitingServer = false;
    }

    void close()
    {
        active = false;
        awaitingServer = false;
        ticksSinceDeath = 0;
        cause = "";
    }

    void tick()
    {
        if (active && ticksSinceDeath < uint.max)
            ++ticksSinceDeath;
    }

    bool buttonsEnabled() const
    {
        // DeathScreen.delayTicker enables both buttons after one second.
        return ticksSinceDeath >= 20 && !awaitingServer;
    }
}

final class DeathScreenRenderer
{
    DeathAction hitTest(uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, const DeathScreenState state) const
    {
        if (!state.buttonsEnabled)
            return DeathAction.none;
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(int) viewportWidth / scale;
        const logicalHeight = cast(int) viewportHeight / scale;
        const x = mouseX / scale;
        const y = mouseY / scale;
        const center = logicalWidth / 2;
        const firstY = logicalHeight / 4 + 72;
        if (inside(x,y,center-100,firstY,200,20))
            return DeathAction.respawn;
        if (inside(x,y,center-100,firstY+24,200,20))
            return DeathAction.titleScreen;
        return DeathAction.none;
    }

    void append(ref FrameMesh frame, uint viewportWidth, uint viewportHeight,
        int mouseX, int mouseY, const DeathScreenState state,
        const DeathTextureSet textures, const FontRenderer font,
        uint fontTexture) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(float) viewportWidth / scale;
        const logicalHeight = cast(float) viewportHeight / scale;
        const center = cast(int) logicalWidth / 2;
        const firstY = cast(int) logicalHeight / 4 + 72;
        const hovered = hitTest(viewportWidth, viewportHeight,
            mouseX, mouseY, state);

        // DeathScreen.renderDeathBackground uses ARGB 0x60500000 at the top
        // and 0xA0803030 at the bottom.
        gradient(frame, textures.white, 0, 0, cast(int)logicalWidth,
            cast(int)logicalHeight, logicalWidth, logicalHeight,
            Color(80.0f/255.0f,0,0,96.0f/255.0f),
            Color(128.0f/255.0f,48.0f/255.0f,48.0f/255.0f,160.0f/255.0f));

        const title = state.hardcore ? "Game Over!" : "You Died!";
        // Vanilla renders the title with a 2x pose-stack scale at y=30.
        const halfWidth = logicalWidth * 0.5f;
        const halfHeight = logicalHeight * 0.5f;
        text(frame, title,
            (cast(int)halfWidth-font.width(title))/2, 15,
            halfWidth, halfHeight, font, fontTexture, Color(1,1,1,1));

        if (state.cause.length)
            centered(frame, state.cause, 85, logicalWidth, logicalHeight,
                font, fontTexture, Color(1,1,1,1));

        const prefix = "Score: ";
        const scoreValue = to!string(state.score);
        const scoreX = center - (font.width(prefix)+font.width(scoreValue))/2;
        text(frame, prefix, scoreX, 100, logicalWidth, logicalHeight,
            font, fontTexture, Color(1,1,1,1));
        text(frame, scoreValue, scoreX+font.width(prefix), 100,
            logicalWidth, logicalHeight, font, fontTexture,
            Color(1,1,85.0f/255.0f,1));

        const enabled = state.buttonsEnabled;
        button(frame, center-100, firstY, 200,
            state.hardcore ? "Spectate World" : "Respawn",
            hovered == DeathAction.respawn, enabled, logicalWidth,
            logicalHeight, textures, font, fontTexture);
        button(frame, center-100, firstY+24, 200, "Title Screen",
            hovered == DeathAction.titleScreen, enabled, logicalWidth,
            logicalHeight, textures, font, fontTexture);
    }

private:
    static int guiScale(uint width, uint height)
    {
        int result = 1;
        while (result < 8 && width/(result+1) >= 320
            && height/(result+1) >= 240) ++result;
        return result;
    }

    static bool inside(int px,int py,int x,int y,int width,int height)
    {
        return px>=x && px<x+width && py>=y && py<y+height;
    }

    static void button(ref FrameMesh frame, int x, int y, int width,
        string label, bool highlighted, bool enabled, float logicalWidth,
        float logicalHeight, const DeathTextureSet textures,
        const FontRenderer font, uint fontTexture)
    {
        const texture = !enabled ? textures.buttonDisabled
            : (highlighted ? textures.buttonHighlighted : textures.button);
        rect(frame,texture,x,y,width,20,logicalWidth,logicalHeight,
            Color(1,1,1,1));
        const color = !enabled ? Color(.63f,.63f,.63f,1)
            : (highlighted ? Color(1,1,.63f,1) : Color(1,1,1,1));
        text(frame,label,x+(width-font.width(label))/2,y+6,
            logicalWidth,logicalHeight,font,fontTexture,color);
    }

    static void centered(ref FrameMesh frame, string value, int y,
        float logicalWidth, float logicalHeight, const FontRenderer font,
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
        gradient(frame,texture,x,y,width,height,logicalWidth,logicalHeight,
            color,color);
    }

    static void gradient(ref FrameMesh frame, uint texture, int x, int y,
        int width, int height, float logicalWidth, float logicalHeight,
        Color topColor, Color bottomColor)
    {
        Vertex[] output;
        const left=cast(float)x/logicalWidth*2.0f-1.0f;
        const right=cast(float)(x+width)/logicalWidth*2.0f-1.0f;
        const top=1.0f-cast(float)y/logicalHeight*2.0f;
        const bottom=1.0f-cast(float)(y+height)/logicalHeight*2.0f;
        appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
            Vec3(right,top,0),Vec3(left,top,0),Vec2(0,1),Vec2(1,1),
            Vec2(1,0),Vec2(0,0),bottomColor,bottomColor,topColor,topColor);
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }
}

unittest
{
    auto state = new DeathScreenState();
    state.open(false, 42, "Steve fell from a high place");
    assert(state.active && !state.buttonsEnabled && state.score == 42);
    foreach (_; 0 .. 20) state.tick();
    assert(state.buttonsEnabled);
    state.awaitingServer = true;
    assert(!state.buttonsEnabled);
}
