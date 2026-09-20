module terrain_render_smoke;

import core.sys.windows.windows;
import core.sys.windows.com : CoInitializeEx,CoUninitialize,COINIT_MULTITHREADED;
import std.file : mkdirRecurse,write;
import std.format : format;
import std.stdio : writeln;
import minecraftd.client.render.graphics_device;
import minecraftd.client.render.mesh;
import minecraftd.client.render.texture_manager;
import minecraftd.client.render.block_renderer;
import minecraftd.client.render.sky_renderer;
import minecraftd.common.math3d;
import minecraftd.world.world;
import minecraftd.world.world_settings;
import minecraftd.world.chunk;
import minecraftd.world.block;
import minecraftd.world.generation.overworld;
import minecraftd.world.generation.biomes;
import minecraftd.platform.windows.dx12.device : Dx12Device;
import minecraftd.platform.desktop.vulkan.device : VulkanDevice;

void main()
{
    assert(CoInitializeEx(null,COINIT_MULTITHREADED)>=0);
    scope(exit)CoUninitialize();
    mkdirRecurse("test-output/terrain");
    auto world=new World();world.clearChunks();world.settings.seed=42;
    scope(exit)destroy(world);
    int cx,cz;bool found;
    foreach(z;-32..33){foreach(x;-32..33)
    {
        const c=columnAt(x*32,z*32,world.settings);
        if(!c.water&&definition(c.biome).trees>=50)
        {cx=x*2;cz=z*2;found=true;break;}
    }if(found)break;}
    foreach(z;cz-4..cz+5)foreach(x;cx-4..cx+5)
    {
        auto chunk=new Chunk(x,z);generateOverworld(chunk,world.settings);
        world.installDetachedChunk(chunk);
    }
    const ground=columnAt(cx*16,cz*16,world.settings).height;
    writeln("Forest camera center ",cx*16,",",ground,",",cz*16);
    foreach(vulkan;[false,true])
    {
        auto window=CreateWindowExW(0,"STATIC"w.ptr,"Terrain render test"w.ptr,
            WS_OVERLAPPEDWINDOW,0,0,960,540,null,null,GetModuleHandleW(null),null);
        assert(window !is null);scope(exit)DestroyWindow(window);
        GraphicsDevice graphics=vulkan?cast(GraphicsDevice)new VulkanDevice(window,960,540,".")
            :cast(GraphicsDevice)new Dx12Device(window,960,540);
        scope(exit)destroy(graphics);
        auto images=new TextureManager();scope(exit)destroy(images);
        auto blocks=new BlockRenderer(world);scope(exit)destroy(blocks);
        blocks.configure(true,.7f);
        uint[string] textures;
        uint load(string name)
        {
            if(auto found=name in textures)return *found;
            auto image=images.loadPng("assets/minecraft/textures/block/"~name~".png");
            if(image.height>image.width)
            {image.height=image.width;image.rgba=image.rgba[0..image.width*image.height*4];}
            const texture=graphics.uploadTexture(image,2).descriptorIndex;
            textures[name]=texture;return texture;
        }
        BlockTextureSet set;
        set.grassTop=load("grass_block_top");set.grassSide=load("grass_block_side");
        set.dirt=load("dirt");set.stone=load("stone");set.bedrock=load("bedrock");
        set.waterStill=load("water_still");set.waterFlow=load("water_flow");
        foreach(raw;cast(int)firstCatalogBlock..cast(int)lastCatalogBlock+1)
        {
            const b=cast(BlockId)raw,d=catalogBlockDefinition(b);
            set.catalogSide[b]=load(d.sideTexture);set.catalogTop[b]=load(d.topTexture);
            set.catalogBottom[b]=load(d.bottomTexture);
            if(isLeaves(b))set.cutoutTextures[set.catalogSide[b]]=true;
        }
        const eye=Vec3(cx*16+42,ground+29,cz*16-48);
        const at=Vec3(cx*16,ground+3,cz*16+8);
        const view=lookToLH(eye,(at-eye).normalized(),Vec3(0,1,0))
            *perspectiveFovLH(64*DEG_TO_RAD,960.0f/540,.05f,400);
        FrameMesh frame;
        foreach(texture,geometry;blocks.build(set))
        {
            auto mesh=graphics.uploadStaticMesh(geometry);
            auto fog=FogSettings.init;
            if(texture in set.cutoutTextures)fog.alphaCutoff=.45f;
            frame.appendResident(mesh,0,mesh.vertexCount,texture,view,DrawLayer.world,fog);
        }
        auto water=blocks.buildWater();
        frame.append(water.walls,set.waterFlow,view,DrawLayer.translucentCulled);
        frame.append(water.surface,set.waterStill,view,DrawLayer.translucentCulled);
        Vertex[] quad;const white=Color(1,1,1,1);
        appendQuad(quad,Vec3(-1,1,0),Vec3(1,1,0),Vec3(1,-1,0),Vec3(-1,-1,0),
            Vec2(0,0),Vec2(1,0),Vec2(1,1),Vec2(0,1),white,white,white,white);
        frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
            DrawLayer.blurBackdrop,FogSettings.blur(960,540,.01f));
        foreach(_;0..3)graphics.render(frame);
        auto pixels=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
            :(cast(Dx12Device)graphics).readBlurPixels();
        ubyte[] rgb;size_t green;
        foreach(i;0..pixels.width*pixels.height)
        {
            const p=pixels.rgba[i*4..i*4+4];rgb~=p[0..3];
            if(p[1]>p[0]*1.15f&&p[1]>p[2]*1.15f)++green;
        }
        assert(green>5000,"Textured foliage/grass did not render");
        const name=vulkan?"vulkan":"dx12";
        write("test-output/terrain/"~name~".ppm",
            format("P6\n%s %s\n255\n",pixels.width,pixels.height)~cast(string)rgb);
        writeln(name," terrain rendered: ",frame.vertices.length," vertices, green pixels ",green);
        foreach(alpha;[128,32])
        {
            frame.clear(Color(0,0,1,1));
            auto leaf=graphics.uploadTexture(ImageData(1,1,[0,255,0,cast(ubyte)alpha]));
            auto cutout=FogSettings.init;cutout.alphaCutoff=.45f;
            frame.append(quad,leaf.descriptorIndex,Mat4.identity(),DrawLayer.worldDoubleSided,cutout);
            frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
                DrawLayer.blurBackdrop,FogSettings.blur(960,540,.01f));
            foreach(_;0..3)graphics.render(frame);
            auto sample=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
                :(cast(Dx12Device)graphics).readBlurPixels();
            const i=((sample.height/2)*sample.width+sample.width/2)*4;
            if(alpha==128)assert(sample.rgba[i+1]>245&&sample.rgba[i+2]<5,
                "Surviving leaf pixels must be opaque, independent of what was drawn behind");
            else assert(sample.rgba[i+1]<5&&sample.rgba[i+2]>245,
                "Leaf holes must discard without writing color");
        }
        writeln(name," cutout opacity and discard passed");
        // Fire must use depth even when sections arrive in the wrong order.
        auto nearQuad=quad.dup,farQuad=quad.dup;
        foreach(ref v;nearQuad)v.position[2]=.2f;
        foreach(ref v;farQuad)v.position[2]=.8f;
        const greenTexture=graphics.uploadTexture(ImageData(1,1,[0,255,0,255])).descriptorIndex;
        const redTexture=graphics.uploadTexture(ImageData(1,1,[255,0,0,255])).descriptorIndex;
        auto fireFog=FogSettings.init;fireFog.alphaCutoff=.1f;
        foreach(reverse;[false,true])
        {
            frame.clear(Color(0,0,1,1));
            if(reverse)frame.append(farQuad,redTexture,Mat4.identity(),DrawLayer.worldDoubleSided,fireFog);
            frame.append(nearQuad,greenTexture,Mat4.identity(),DrawLayer.worldDoubleSided,fireFog);
            if(!reverse)frame.append(farQuad,redTexture,Mat4.identity(),DrawLayer.worldDoubleSided,fireFog);
            frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
                DrawLayer.blurBackdrop,FogSettings.blur(960,540,.01f));
            foreach(_;0..3)graphics.render(frame);
            auto sample=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
                :(cast(Dx12Device)graphics).readBlurPixels();
            const i=((sample.height/2)*sample.width+sample.width/2)*4;
            assert(sample.rgba[i+1]>245&&sample.rgba[i]<5,"Rear fire drew over nearer fire");
        }
        writeln(name," fire depth ordering passed");
        // A closed room with stepped walls/ceiling spans chunk and section
        // boundaries. Any magenta pixel is an actual raster hole, not texture.
        auto sealedWorld=new World();sealedWorld.clearChunks();
        scope(exit)destroy(sealedWorld);
        foreach(z;-2..2)foreach(x;-2..2)sealedWorld.installDetachedChunk(new Chunk(x,z));
        foreach(z;-18..19)foreach(x;-18..19)foreach(y;0..21)
        {
            const ceiling=17+((x+18)/3)%3;
            if(x==-18||x==18||z==-18||z==18||y==0||y>=ceiling)
                sealedWorld.setBlock(x,y,z,BlockId.stone);
        }
        auto sealedBlocks=new BlockRenderer(sealedWorld);scope(exit)destroy(sealedBlocks);
        sealedBlocks.configure(false,0);
        BlockTextureSet sealedTextures;sealedTextures.stone=greenTexture;
        auto sealedGeometry=sealedBlocks.build(sealedTextures);
        foreach(angle;0..24)
        {
            const roomEye=Vec3(.137f+angle*.021f,8.317f,-.193f);
            const direction=forwardFromYawPitch(angle*15.0f+.37f,angle%2?37.3f:-29.7f);
            const camera=lookToLH(roomEye,direction,Vec3(0,1,0))
                *perspectiveFovLH(83*DEG_TO_RAD,960.0f/540,.05f,128);
            frame.clear(Color(1,0,1,1));
            foreach(texture,geometry;sealedGeometry)
                frame.append(geometry,texture,camera,DrawLayer.world);
            frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
                DrawLayer.blurBackdrop,FogSettings.blur(960,540,.01f));
            foreach(_;0..3)graphics.render(frame);
            const sample=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
                :(cast(Dx12Device)graphics).readBlurPixels();
            size_t leaks;
            foreach(i;0..sample.width*sample.height)
                if(sample.rgba[i*4]>=16||sample.rgba[i*4+2]>=16)++leaks;
            if(leaks)
            {
                ubyte[] pixelsRgb;foreach(i;0..sample.width*sample.height)pixelsRgb~=sample.rgba[i*4..i*4+3];
                write("test-output/terrain/leaks.ppm",format("P6\n%s %s\n255\n",sample.width,sample.height)~cast(string)pixelsRgb);
                writeln("Leaks: ",leaks," angle: ",angle);
            }
            assert(leaks==0,"Background leaked through closed terrain while moving the camera");
        }
        writeln(name," sealed terrain: 24 moving camera views, no background leaks");
        auto sky=new SkyRenderer(ImageData.init);
        const skyColor=Color(.48f,.70f,1,1),haze=FogSettings.init.color;
        const skyView=lookToLH(Vec3(0,0,0),Vec3(0,.25f,1).normalized(),Vec3(0,1,0))
            *perspectiveFovLH(70*DEG_TO_RAD,960.0f/540,.05f,512);
        const whiteTexture=graphics.uploadTexture(ImageData(1,1,[255,255,255,255])).descriptorIndex;
        frame.clear(skyColor);
        frame.append(sky.buildHorizon(Vec3(0,0,0),haze,skyColor),whiteTexture,skyView,DrawLayer.sky);
        frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
            DrawLayer.blurBackdrop,FogSettings.blur(960,540,.01f));
        foreach(_;0..3)graphics.render(frame);
        auto atmosphere=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
            :(cast(Dx12Device)graphics).readBlurPixels();
        const top=((atmosphere.height/4)*atmosphere.width+atmosphere.width/2)*4;
        const bottom=((atmosphere.height*3/4)*atmosphere.width+atmosphere.width/2)*4;
        assert(atmosphere.rgba[bottom]>atmosphere.rgba[top]+20,
            "Horizon fog must fade into clear sky above");
        ubyte[] skyRgb;foreach(i;0..atmosphere.width*atmosphere.height)skyRgb~=atmosphere.rgba[i*4..i*4+3];
        write("test-output/terrain/"~name~"-sky.ppm",
            format("P6\n%s %s\n255\n",atmosphere.width,atmosphere.height)~cast(string)skyRgb);
        destroy(sky);writeln(name," horizon fog gradient passed");
    }
}

