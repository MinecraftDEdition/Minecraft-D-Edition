module minecraftd.client.render.unicode_font;
import minecraftd.client.render.texture_manager : ImageData,TextureManager;
import minecraftd.game.resources.resource_manager : ResourceManager;
import std.algorithm : sort;
import std.format : format;

struct FontGlyph { float u0,v0,u1,v1; int width,advance; }
struct UnicodeFont { ImageData image; FontGlyph[dchar] glyphs; }

UnicodeFont buildUnicodeFont(ImageData ascii,TextureManager images,ResourceManager resources,string text)
{
    bool[dchar] needed;
    foreach(code;0..128)needed[cast(dchar)code]=true;
    foreach(dchar code;text)if(code>=32&&code<=0xffff)needed[code]=true;
    // ICU Arabic shaping emits presentation-form glyphs for the bitmap atlas.
    foreach(code;0xfb50..0xff00)needed[cast(dchar)code]=true;
    auto codes=needed.keys;codes.sort();
    uint side=256;
    while((side/16)*(side/16)<codes.length)side*=2;
    auto output=UnicodeFont(ImageData(side,side,new ubyte[side*side*4]));
    ImageData[uint] pages;
    foreach(index,code;codes)
    {
        ImageData source;uint x0,y0,cell;
        if(code<128)
        {source=ascii;cell=ascii.width/16;x0=(code&15)*cell;y0=(code>>4)*cell;}
        else
        {
            const page=code>>8;
            if(page !in pages)
            {
                const path=resources.findAsset("minecraft",format("textures/font/unicode_page_%02x.png",page));
                ImageData image;
                if(path.length)try{image=images.loadPng(path);}catch(Exception){}
                pages[page]=image;
            }
            source=pages[page];if(!source.width||source.width!=source.height||source.width%16)continue;
            cell=source.width/16;x0=(code&15)*cell;y0=((code&255)>>4)*cell;
        }
        const ox=cast(uint)(index%(side/16))*16,oy=cast(uint)(index/(side/16))*16;
        int right=-1,left=16;
        foreach(y;0..16)foreach(x;0..16)
        {
            const src=((y0+y*cell/16)*source.width+x0+x*cell/16)*4;
            const dst=((oy+y)*side+ox+x)*4;
            output.image.rgba[dst..dst+4]=source.rgba[src..src+4];
            if(source.rgba[src+3]){if(x>right)right=x;if(x<left)left=x;}
        }
        if(code<128)left=0;
        if(right<0){left=0;right=5;}
        const width=(right-left+2)/2;
        output.glyphs[code]=FontGlyph(cast(float)(ox+left)/side,cast(float)oy/side,
            cast(float)(ox+left+width*2)/side,cast(float)(oy+16)/side,width,code==' '?4:width+1);
    }
    return output;
}
