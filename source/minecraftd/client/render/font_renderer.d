module minecraftd.client.render.font_renderer;

import minecraftd.client.render.mesh : Color, Vertex, appendQuad;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.common.math3d : Vec2, Vec3, cross, forwardFromYawPitch;
import minecraftd.client.render.unicode_font : FontGlyph;
import std.utf : decode;
import minecraftd.client.render.text_layout : visualText;

/// Minecraft's bitmap provider for font/ascii.png. Glyphs occupy an 8x8 cell;
/// their advances are derived from the last nontransparent source column.
final class FontRenderer
{
    enum int glyphHeight = 8;
    enum int lineHeight = 9;

    private ubyte[256] advances;
    private FontGlyph[dchar] glyphs;

    this(const ImageData atlas,FontGlyph[dchar] glyphs=null)
    {
        this.glyphs=glyphs;
        const cellWidth=atlas.width/16,cellHeight=atlas.height/16;
        if(!cellWidth||!cellHeight)throw new Exception("Font atlas must contain a 16 by 16 glyph grid");
        foreach (code; 0 .. 256)
        {
            const cellX = (code & 15) * cellWidth;
            const cellY = (code >> 4) * cellHeight;
            int right = -1;
            foreach (y; 0 .. cellHeight)
            foreach (x; 0 .. cellWidth)
            {
                const pixel = ((cellY + y) * atlas.width + cellX + x) * 4;
                if (pixel + 3 < atlas.rgba.length && atlas.rgba[pixel + 3] != 0
                    && cast(int)x > right)
                    right = cast(int)x;
            }
            advances[code] = cast(ubyte) (right >= 0 ? ((right+1)*8+cellWidth-1)/cellWidth+1 : 4);
        }
        advances[' '] = 4;
    }

    int width(string text) const
    {
        int result;
        foreach (dchar value; visualText(text))
            result += glyph(value).advance;
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
                auto nextEnd=end;
                const value = decode(text,nextEnd);
                const next = used + glyph(value).advance;
                if (next > maximumWidth && end > start)
                    break;
                used = next;
                if (value == ' ')
                    lastSpace = end;
                end=nextEnd;
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
        foreach (dchar code; visualText(value))
        {
            if (code != ' ')
            {
                const g=glyph(code);
                const visibleWidth = g.width;
                const left = cursor;
                const rightEdge = cursor + visibleWidth;
                const bottom = -4.0f;
                const top = 4.0f;
                Vec3 point(float x, float y)
                {
                    return anchor + right * (x * pixelScale)
                        + up * (y * pixelScale);
                }
                const u0=g.u0,u1=g.u1,v0=g.v0,v1=g.v1;
                appendQuad(output, point(left,bottom), point(rightEdge,bottom),
                    point(rightEdge,top), point(left,top), Vec2(u0,v1),
                    Vec2(u1,v1), Vec2(u1,v0), Vec2(u0,v0), color, color,
                    color, color);
            }
            cursor += glyph(code).advance;
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
    FontGlyph glyph(dchar code) const
    {
        if(auto found=code in glyphs)return *found;
        if(glyphs.length){if(auto fallback=cast(dchar)'?' in glyphs)return *fallback;}
        if(code>=256)code='?';
        const width=advances[code]>1?advances[code]-1:1;
        return FontGlyph(cast(float)(code&15)/16,cast(float)(code>>4)/16,
            cast(float)((code&15)*8+width)/128,cast(float)((code>>4)*8+8)/128,width,advances[code]);
    }
    void appendText(ref Vertex[] output, string text, int x, int y,
        float logicalWidth, float logicalHeight, Color color) const
    {
        int cursorX = x;
        foreach (dchar value; visualText(text))
        {
            if (value != ' ')
                appendGlyph(output, value, cursorX, y, logicalWidth, logicalHeight, color);
            cursorX += glyph(value).advance;
        }
    }

    void appendGlyph(ref Vertex[] output, dchar code, int x, int y,
        float logicalWidth, float logicalHeight, Color color) const
    {
        const g=glyph(code);
        const visibleWidth = g.width;
        const left = cast(float) x / logicalWidth * 2.0f - 1.0f;
        const right = cast(float) (x + visibleWidth) / logicalWidth * 2.0f - 1.0f;
        const top = 1.0f - cast(float) y / logicalHeight * 2.0f;
        const bottom = 1.0f - cast(float) (y + glyphHeight) / logicalHeight * 2.0f;
        const u0=g.u0,u1=g.u1,v0=g.v0,v1=g.v1;
        appendQuad(output,
            Vec3(left, bottom, 0), Vec3(right, bottom, 0),
            Vec3(right, top, 0), Vec3(left, top, 0),
            Vec2(u0,v1), Vec2(u1,v1), Vec2(u1,v0), Vec2(u0,v0),
            color, color, color, color);
    }
}

unittest
{
    FontGlyph[dchar] glyphs;
    glyphs['?']=FontGlyph(0,0,1,1,3,4);
    glyphs['é']=FontGlyph(0,0,1,1,5,6);
    glyphs['中']=FontGlyph(0,0,1,1,7,8);
    auto unicodeFont=new FontRenderer(ImageData(128,128,new ubyte[128*128*4]),glyphs);
    assert(unicodeFont.width("é中")==14);
    assert(unicodeFont.wrap("é中",6)==["é","中"]);
    // Unsigned atlas coordinates must still compare above the -1 sentinel.
    // Check both the default atlas and a higher-resolution pack atlas.
    foreach(scale;[1u,2u])
    {
        auto atlas=ImageData(128*scale,128*scale,new ubyte[128*128*4*scale*scale]);
        foreach(code;[cast(uint)'W',cast(uint)'i'])
        {
            const inkWidth=(code=='W'?6u:1u)*scale;
            foreach(y;0..7*scale)foreach(x;0..inkWidth)
            {
                const pixel=(((code>>4)*8*scale+y)*atlas.width
                    +(code&15)*8*scale+x)*4;
                atlas.rgba[pixel+3]=255;
            }
        }
        auto font=new FontRenderer(atlas);
        assert(font.width("W")==7);
        assert(font.width("i")==2);
        assert(font.width("Wi W")==20);
    }
}
