module minecraftd.client.render.font_renderer;

import minecraftd.client.render.mesh : Color, Vertex, appendQuad;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.common.math3d : Vec2, Vec3, cross, forwardFromYawPitch;

/// Minecraft's bitmap provider for font/ascii.png. Glyphs occupy an 8x8 cell;
/// their advances are derived from the last nontransparent source column.
final class FontRenderer
{
    enum int glyphHeight = 8;
    enum int lineHeight = 9;

    private ubyte[256] advances;

    this(const ImageData atlas)
    {
        foreach (code; 0 .. 256)
        {
            const cellX = (code & 15) * 8;
            const cellY = (code >> 4) * 8;
            int right = -1;
            foreach (y; 0 .. 8)
            foreach (x; 0 .. 8)
            {
                const pixel = ((cellY + y) * atlas.width + cellX + x) * 4;
                if (pixel + 3 < atlas.rgba.length && atlas.rgba[pixel + 3] != 0
                    && x > right)
                    right = x;
            }
            advances[code] = cast(ubyte) (right >= 0 ? right + 2 : 4);
        }
        advances[' '] = 4;
    }

    int width(string text) const
    {
        int result;
        foreach (ubyte value; cast(const(ubyte)[]) text)
            result += advances[value];
        return result;
    }

    string[] wrap(string text, int maximumWidth) const
    {
        string[] result;
        size_t start;
        while (start < text.length)
        {
            size_t end = start;
            size_t lastSpace = size_t.max;
            int used;
            while (end < text.length)
            {
                const value = cast(ubyte) text[end];
                const next = used + advances[value];
                if (next > maximumWidth && end > start)
                    break;
                used = next;
                if (value == ' ')
                    lastSpace = end;
                ++end;
            }
            if (end < text.length && lastSpace != size_t.max && lastSpace >= start)
            {
                result ~= text[start .. lastSpace];
                start = lastSpace + 1;
            }
            else
            {
                result ~= text[start .. end];
                start = end;
            }
            while (start < text.length && text[start] == ' ')
                ++start;
        }
        if (result.length == 0)
            result ~= "";
        return result;
    }

    Vertex[] buildText(string text, int x, int y, float logicalWidth,
        float logicalHeight, Color color, bool shadow = true) const
    {
        Vertex[] output;
        if (shadow)
            appendText(output, text, x + 1, y + 1, logicalWidth, logicalHeight,
                Color(0, 0, 0, color.a * 0.25f));
        appendText(output, text, x, y, logicalWidth, logicalHeight, color);
        return output;
    }

    /// Java nameplates are camera-facing world text scaled at 0.025 blocks per
    /// font pixel. `anchor` is the center of the label above the entity.
    Vertex[] buildWorldText(string value, Vec3 anchor, float cameraYaw,
        float cameraPitch, Color color) const
    {
        Vertex[] output;
        const forward = forwardFromYawPitch(cameraYaw, cameraPitch);
        const right = cross(Vec3(0, 1, 0), forward).normalized();
        const up = cross(forward, right).normalized();
        enum float pixelScale = 0.025f;
        float cursor = -cast(float) width(value) * 0.5f;
        foreach (ubyte code; cast(const(ubyte)[]) value)
        {
            if (code != ' ')
            {
                const visibleWidth = advances[code] > 1
                    ? advances[code] - 1 : 1;
                const left = cursor;
                const rightEdge = cursor + visibleWidth;
                const bottom = -4.0f;
                const top = 4.0f;
                Vec3 point(float x, float y)
                {
                    return anchor + right * (x * pixelScale)
                        + up * (y * pixelScale);
                }
                const cellX = code & 15;
                const cellY = code >> 4;
                const u0 = cast(float) (cellX * 8) / 128.0f;
                const u1 = cast(float) (cellX * 8 + visibleWidth) / 128.0f;
                const v0 = cast(float) (cellY * 8) / 128.0f;
                const v1 = cast(float) (cellY * 8 + 8) / 128.0f;
                appendQuad(output, point(left,bottom), point(rightEdge,bottom),
                    point(rightEdge,top), point(left,top), Vec2(u0,v1),
                    Vec2(u1,v1), Vec2(u1,v0), Vec2(u0,v0), color, color,
                    color, color);
            }
            cursor += advances[code];
        }
        return output;
    }

    Vertex[] buildWorldBackground(string value, Vec3 anchor, float cameraYaw,
        float cameraPitch, Color color) const
    {
        Vertex[] output;
        const forward = forwardFromYawPitch(cameraYaw, cameraPitch);
        const right = cross(Vec3(0, 1, 0), forward).normalized();
        const up = cross(forward, right).normalized();
        enum float pixelScale = 0.025f;
        const halfWidth = (cast(float) width(value) * 0.5f + 1.0f)
            * pixelScale;
        const halfHeight = 5.0f * pixelScale;
        // Move the background a fraction away from the text to avoid z-fight.
        const center = anchor + forward * 0.001f;
        appendQuad(output,
            center - right * halfWidth - up * halfHeight,
            center + right * halfWidth - up * halfHeight,
            center + right * halfWidth + up * halfHeight,
            center - right * halfWidth + up * halfHeight,
            Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
            color, color, color, color);
        return output;
    }

private:
    void appendText(ref Vertex[] output, string text, int x, int y,
        float logicalWidth, float logicalHeight, Color color) const
    {
        int cursorX = x;
        foreach (ubyte value; cast(const(ubyte)[]) text)
        {
            if (value != ' ')
                appendGlyph(output, value, cursorX, y, logicalWidth, logicalHeight, color);
            cursorX += advances[value];
        }
    }

    void appendGlyph(ref Vertex[] output, ubyte code, int x, int y,
        float logicalWidth, float logicalHeight, Color color) const
    {
        const visibleWidth = advances[code] > 1 ? advances[code] - 1 : 1;
        const left = cast(float) x / logicalWidth * 2.0f - 1.0f;
        const right = cast(float) (x + visibleWidth) / logicalWidth * 2.0f - 1.0f;
        const top = 1.0f - cast(float) y / logicalHeight * 2.0f;
        const bottom = 1.0f - cast(float) (y + glyphHeight) / logicalHeight * 2.0f;
        const cellX = code & 15;
        const cellY = code >> 4;
        const u0 = cast(float) (cellX * 8) / 128.0f;
        const u1 = cast(float) (cellX * 8 + visibleWidth) / 128.0f;
        const v0 = cast(float) (cellY * 8) / 128.0f;
        const v1 = cast(float) (cellY * 8 + 8) / 128.0f;
        appendQuad(output,
            Vec3(left, bottom, 0), Vec3(right, bottom, 0),
            Vec3(right, top, 0), Vec3(left, top, 0),
            Vec2(u0,v1), Vec2(u1,v1), Vec2(u1,v0), Vec2(u0,v0),
            color, color, color, color);
    }
}
