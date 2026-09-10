module texture_animation_smoke;
import std.stdio : writeln;
import minecraftd.client.render.texture_animation;
import minecraftd.client.render.texture_manager : ImageData;

void main()
{
    auto image=ImageData(2,4,new ubyte[32]);
    image.rgba[0..16]=0;image.rgba[16..32]=200;
    auto animation=decodeTextureAnimation(image,`{"animation":{"frametime":2,"frames":[1,{"index":0,"time":3}]}}`);
    assert(animation.frames.length==2&&animation.ticks==[1,1,0,0,0]);
    assert(animation.frames[1].width==2&&animation.frames[1].height==2);
    assert(animation.frames[1].rgba[0]==200);
    animation=decodeTextureAnimation(image,`{"animation":{"frametime":2,"interpolate":true}}`);
    assert(animation.ticks.length==4);
    assert(animation.frames[animation.ticks[1]].rgba[0]==100);
    assert(animation.frames[animation.ticks[3]].rgba[0]==100);
    animation=decodeTextureAnimation(image,"");
    assert(animation.frames.length==1&&animation.frames[0].height==4);
    bool rejected;
    try{decodeTextureAnimation(image,`{"animation":{"frames":[99]}}`);}catch(Exception){rejected=true;}
    assert(rejected);
    writeln("Animation dimensions, ordering, frame time, interpolation, and invalid-frame checks passed");
}
