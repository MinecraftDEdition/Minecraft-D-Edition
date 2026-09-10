module minecraftd.client.render.texture_animation;

import std.json : JSONValue,JSONType,parseJSON;
import std.exception : enforce;
import minecraftd.client.render.texture_manager : ImageData;

struct TextureAnimation
{
    ImageData[] frames;
    uint[] ticks;
}

/// Decode Java animation metadata into a 20 Hz schedule. Repeated frames
/// share GPU textures; interpolated transitions are baked once on reload.
TextureAnimation decodeTextureAnimation(ImageData source,string metadata)
{
    if(!metadata.length)return TextureAnimation([source],[0u]);
    const root=parseJSON(metadata);
    if(root.type!=JSONType.object||"animation" !in root.object)
        return TextureAnimation([source],[0u]);
    const animation=root.object["animation"];
    enforce(animation.type==JSONType.object,"Invalid texture animation metadata");
    int integer(string key,int fallback)
    { auto p=key in animation.object;return p is null?fallback:cast(int)p.integer; }
    const hasWidth="width" in animation.object,hasHeight="height" in animation.object;
    const side=source.width<source.height?source.width:source.height;
    const w=integer("width",hasHeight?source.width:side);
    const h=integer("height",hasWidth?source.height:side);
    enforce(w>0&&h>0&&source.width%w==0&&source.height%h==0,"Animation frame dimensions do not divide the texture");
    const columns=source.width/w,count=columns*(source.height/h);
    enforce(count>0&&count<=1024,"Too many texture animation frames");
    TextureAnimation result;
    foreach(index;0..count)
    {
        ImageData frame=ImageData(w,h,new ubyte[w*h*4]);
        foreach(y;0..h)
        {
            const start=((index/columns*h+y)*source.width+index%columns*w)*4;
            frame.rgba[y*w*4..(y+1)*w*4]=source.rgba[start..start+w*4];
        }
        result.frames~=frame;
    }
    const defaultTime=integer("frametime",1);
    enforce(defaultTime>0&&defaultTime<=1200,"Invalid animation frame time");
    uint[] indices,durations;
    if(auto specified="frames" in animation.object)
    {
        enforce(specified.type==JSONType.array,"Animation frames must be an array");
        foreach(entry;specified.array)
        {
            int index,time=defaultTime;
            if(entry.type==JSONType.integer)index=cast(int)entry.integer;
            else
            {
                enforce(entry.type==JSONType.object&&"index" in entry.object,"Invalid animation frame");
                index=cast(int)entry.object["index"].integer;
                if(auto p="time" in entry.object)time=cast(int)p.integer;
            }
            enforce(index>=0&&index<count&&time>0&&time<=1200,"Animation frame index/time is out of range");
            indices~=index;durations~=time;
        }
    }
    if(!indices.length)foreach(index;0..count){indices~=index;durations~=defaultTime;}
    const interpolate="interpolate" in animation.object;
    foreach(i,index;indices)
    {
        const time=durations[i],next=indices[(i+1)%indices.length];
        enforce(result.ticks.length+time<=12000,"Animation schedule is too long");
        foreach(tick;0..time)
        {
            if(tick&&interpolate !is null&&interpolate.boolean&&next!=index)
            {
                enforce(cast(ulong)(result.frames.length+1)*w*h*4<=64UL*1024*1024,
                    "Interpolated animation exceeds the 64 MiB texture budget");
                auto frame=ImageData(w,h,new ubyte[w*h*4]);
                foreach(p;0..frame.rgba.length)
                    frame.rgba[p]=cast(ubyte)((result.frames[index].rgba[p]*(time-tick)
                        +result.frames[next].rgba[p]*tick)/time);
                result.ticks~=cast(uint)result.frames.length;result.frames~=frame;
            }
            else result.ticks~=index;
        }
    }
    return result;
}
