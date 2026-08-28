module minecraftd.client.render.chat_renderer;

import core.stdc.math : powf;
import minecraftd.client.chat.chat_state : ChatMessageKind, ChatState;
import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.render.mesh : Color, DrawLayer, FrameMesh, Vertex, appendQuad;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.common.math3d : Mat4, Vec2, Vec3, clamp;
import minecraftd.client.menu.options_menu : OptionsMenuState;

private struct VisibleChatLine
{
    string text;
    int age;
    ChatMessageKind kind;
}

final class ChatRenderer
{
    private FontRenderer font;
    private uint fontTexture;
    private uint solidTexture;

    this(const ImageData asciiAtlas, uint fontTexture, uint solidTexture)
    {
        font = new FontRenderer(asciiAtlas);
        this.fontTexture = fontTexture;
        this.solidTexture = solidTexture;
    }

    void append(ref FrameMesh frame, uint viewportWidth, uint viewportHeight,
        const ChatState chat, const OptionsMenuState options) const
    {
        const visibility=options.integer("chatVisibility",0);
        if(visibility==2)return;
        const scale = automaticGuiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(float) viewportWidth / scale;
        const logicalHeight = cast(float) viewportHeight / scale;
        const chatWidth = cast(int)clamp(40.0f
            + options.number("chatWidth",1)*280.0f,40.0f,logicalWidth-8.0f);
        const heightAmount=chat.active?options.number("chatHeightFocused",1)
            :options.number("chatHeightUnfocused",.44f);
        const lineStep=FontRenderer.lineHeight
            +cast(int)(options.number("chatLineSpacing",0)*8.0f);
        const chatHeight=20+cast(int)(heightAmount*160);
        const maximumLines=chatHeight/lineStep;
        const textOpacity=options.number("chatOpacity",1);
        const backgroundOpacity=options.number("textBackgroundOpacity",.5f);
        VisibleChatLine[] visible;

        foreach_reverse (message; chat.messages)
        {
            if(visibility==1&&message.kind!=ChatMessageKind.system)continue;
            const wrapped = font.wrap(message.text, chatWidth);
            foreach_reverse (line; wrapped)
            {
                visible ~= VisibleChatLine(line, message.age, message.kind);
                if (visible.length >= maximumLines)
                    break;
            }
            if (visible.length >= maximumLines)
                break;
        }

        const bottom = cast(int) logicalHeight - 40;
        foreach (index, line; visible)
        {
            float opacity = 1.0f;
            if (!chat.active)
            {
                float remaining = 1.0f - cast(float) line.age / 200.0f;
                opacity = clamp(remaining * 10.0f, 0.0f, 1.0f);
                opacity *= opacity;
            }
            if (opacity <= 0.01f)
                continue;
            opacity*=textOpacity;
            const lineBottom = bottom - cast(int) index * lineStep;
            appendRect(frame, 0, lineBottom - FontRenderer.lineHeight,
                chatWidth + 8, lineBottom, logicalWidth, logicalHeight,
                Color(0,0,0,backgroundOpacity*opacity));
            const colors=options.boolean("chatColors",true);
            const color = colors&&line.kind == ChatMessageKind.system
                ? Color(1,1,85.0f/255.0f,opacity)
                : Color(1,1,1,opacity);
            frame.append(font.buildText(line.text, 4, lineBottom - 8,
                    logicalWidth, logicalHeight, color),
                fontTexture, Mat4.identity(), DrawLayer.overlay);
        }

        if (!chat.active)
            return;

        appendRect(frame, 2, cast(int) logicalHeight - 14,
            cast(int) logicalWidth - 2, cast(int) logicalHeight - 2,
            logicalWidth, logicalHeight, Color(0,0,0,backgroundOpacity));

        const available = cast(int) logicalWidth - 12;
        size_t visibleStart;
        while (visibleStart < chat.cursor
            && font.width(chat.input[visibleStart .. chat.cursor]) > available)
            ++visibleStart;
        const shown = chat.input[visibleStart .. $];
        frame.append(font.buildText(shown, 4, cast(int) logicalHeight - 12,
                logicalWidth, logicalHeight, Color(1, 1, 1, 1)),
            fontTexture, Mat4.identity(), DrawLayer.overlay);

        if ((chat.screenTicks / 6) % 2 == 0)
        {
            const cursorX = 4 + font.width(chat.input[visibleStart .. chat.cursor]);
            appendRect(frame, cursorX, cast(int) logicalHeight - 12,
                cursorX + 1, cast(int) logicalHeight - 3,
                logicalWidth, logicalHeight, Color(1, 1, 1, 1));
        }
    }

private:
    static int automaticGuiScale(uint width, uint height)
    {
        int result = 1;
        while (result < 8 && width / (result + 1) >= 320
            && height / (result + 1) >= 240)
            ++result;
        return result;
    }

    void appendRect(ref FrameMesh frame, int leftPixel, int topPixel,
        int rightPixel, int bottomPixel, float logicalWidth, float logicalHeight,
        Color color) const
    {
        Vertex[] output;
        const left = cast(float) leftPixel / logicalWidth * 2.0f - 1.0f;
        const right = cast(float) rightPixel / logicalWidth * 2.0f - 1.0f;
        const top = 1.0f - cast(float) topPixel / logicalHeight * 2.0f;
        const bottom = 1.0f - cast(float) bottomPixel / logicalHeight * 2.0f;
        appendQuad(output,
            Vec3(left,bottom,0), Vec3(right,bottom,0),
            Vec3(right,top,0), Vec3(left,top,0),
            Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
            color,color,color,color);
        frame.append(output, solidTexture, Mat4.identity(), DrawLayer.overlay);
    }
}
