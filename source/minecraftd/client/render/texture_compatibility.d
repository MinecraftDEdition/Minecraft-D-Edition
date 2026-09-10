module minecraftd.client.render.texture_compatibility;
import minecraftd.client.render.texture_manager : ImageData;
import std.string : replace, endsWith;
import minecraftd.game.resources.compatibility : legacySprites;

ImageData compatibleTexture(ImageData image,string space,string requested,string resolved)
{
    resolved=resolved.replace("\\","/");
    ImageData crop(uint x,uint y,uint width,uint height,uint scale)
    {
        auto result=ImageData(width*scale,height*scale,new ubyte[width*height*scale*scale*4]);
        foreach(row;0..result.height)
        {
            const start=((y*scale+row)*image.width+x*scale)*4;
            result.rgba[row*result.width*4..(row+1)*result.width*4]
                =image.rgba[start..start+result.width*4];
        }
        return result;
    }
    if(requested=="textures/gui/title/minecraft.png"
        &&resolved.endsWith("/minecraft/textures/gui/title/minecraft.png")
        &&image.width==image.height&&image.width>=256&&image.width%256==0)
    {
        // Old Java logos store their two horizontal sections on separate rows.
        const scale=image.width/256;
        auto left=crop(0,0,155,44,scale),right=crop(0,45,120,44,scale);
        auto result=ImageData(275*scale,44*scale,new ubyte[275*44*scale*scale*4]);
        foreach(y;0..result.height)
        {
            const start=y*result.width*4;
            result.rgba[start..start+left.width*4]=left.rgba[y*left.width*4..(y+1)*left.width*4];
            result.rgba[start+left.width*4..start+result.width*4]=right.rgba[y*right.width*4..(y+1)*right.width*4];
        }
        return result;
    }
    if(resolved.endsWith("/minecraft/textures/gui/widgets.png")
        &&image.width==image.height&&image.width>=256&&image.width%256==0)
    {
        uint y;bool button=true;
        switch(requested)
        {
            case "textures/gui/sprites/widget/button.png":y=66;break;
            case "textures/gui/sprites/widget/button_highlighted.png":y=86;break;
            case "textures/gui/sprites/widget/button_disabled.png":y=46;break;
            default:button=false;break;
        }
        if(button)return crop(0,y,200,20,image.width/256);
    }
    if(image.width==image.height&&image.width>=256&&image.width%256==0)
        foreach(sprite;legacySprites)
            if(requested=="textures/gui/sprites/"~sprite.name~".png"
                &&resolved.endsWith("/minecraft/textures/gui/"~sprite.sheet~".png"))
                return crop(sprite.x,sprite.y,sprite.width,sprite.height,image.width/256);
    return image;
}

unittest
{
    foreach(scale;[1u,2u])
    {
        auto source=ImageData(256*scale,256*scale,new ubyte[256*256*scale*scale*4]);
        foreach(y;0..source.height)foreach(x;0..source.width)
            source.rgba[(y*source.width+x)*4]=cast(ubyte)(y/scale);
        auto logo=compatibleTexture(source,"minecraft_d","textures/gui/title/minecraft.png",
            "/assets/minecraft/textures/gui/title/minecraft.png");
        assert(logo.width==275*scale&&logo.height==44*scale);
        assert(logo.rgba[155*scale*4]==45);
        auto button=compatibleTexture(source,"minecraft","textures/gui/sprites/widget/button.png",
            "/assets/minecraft/textures/gui/widgets.png");
        assert(button.width==200*scale&&button.height==20*scale&&button.rgba[0]==66);
    }
}
