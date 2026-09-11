module zombie_render_smoke;

import core.sys.windows.windows;
import core.sys.windows.com : CoInitializeEx,CoUninitialize,COINIT_MULTITHREADED;
import std.file : mkdirRecurse,write;
import std.format : format;
import std.stdio : writeln;
import minecraftd.client.render.graphics_device;
import minecraftd.client.render.mesh;
import minecraftd.client.render.texture_manager;
import minecraftd.client.render.player_renderer;
import minecraftd.common.math3d;
import minecraftd.platform.windows.dx12.device : Dx12Device;
import minecraftd.platform.desktop.vulkan.device : VulkanDevice;

void main()
{
    assert(CoInitializeEx(null,COINIT_MULTITHREADED)>=0);
    scope(exit)CoUninitialize();
    mkdirRecurse("test-output/zombie");
    foreach(vulkan;[false,true])
    {
        auto window=CreateWindowExW(0,"STATIC"w.ptr,"Zombie render test"w.ptr,
            WS_OVERLAPPEDWINDOW,0,0,960,540,null,null,GetModuleHandleW(null),null);
        assert(window !is null);scope(exit)DestroyWindow(window);
        GraphicsDevice graphics=vulkan?cast(GraphicsDevice)new VulkanDevice(window,960,540,".")
            :cast(GraphicsDevice)new Dx12Device(window,960,540);
        scope(exit)destroy(graphics);
        auto images=new TextureManager();auto players=new PlayerRenderer();
        auto skin=images.loadPng("assets/minecraft/textures/entity/zombie/zombie.png");
        const texture=graphics.uploadTexture(skin);
        auto view=lookToLH(Vec3(0,1,0),Vec3(0,0,1),Vec3(0,1,0))
            *perspectiveFovLH(60*DEG_TO_RAD,960.0f/540,.05f,100);
        FrameMesh frame;
        foreach(i,yaw;[0.0f,90.0f,180.0f])
        {
            auto mesh=players.buildSteve(Vec3((cast(float)i-1)*1.65f,0,5),yaw,
                0,0,0,0,0,false,0,SkinLayers(true,false,false,false,false,false),
                false,true,false,false,true);
            foreach(ref v;mesh)v.uv[1]*=cast(float)skin.width/skin.height;
            frame.append(mesh,texture.descriptorIndex,view,DrawLayer.worldDoubleSided);
        }
        // Copy the full rendered scene through the existing readback surface.
        Vertex[] quad;const white=Color(1,1,1,1);
        appendQuad(quad,Vec3(-1,1,0),Vec3(1,1,0),Vec3(1,-1,0),Vec3(-1,-1,0),
            Vec2(0,0),Vec2(1,0),Vec2(1,1),Vec2(0,1),white,white,white,white);
        frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
            DrawLayer.blurBackdrop,FogSettings.blur(960,540,0.01f));
        foreach(_;0..3)graphics.render(frame);
        auto pixels=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
            :(cast(Dx12Device)graphics).readBlurPixels();
        ubyte[] rgb;size_t green;
        foreach(i;0..pixels.width*pixels.height)
        {
            const p=pixels.rgba[i*4..i*4+4];rgb~=p[0..3];
            if(p[1]>p[0]*1.2f&&p[1]>p[2]*1.2f)++green;
        }
        assert(green>500,"Zombie skin must be visible");
        const name=vulkan?"vulkan":"dx12";
        write("test-output/zombie/"~name~".ppm",
            format("P6\n%s %s\n255\n",pixels.width,pixels.height)~cast(string)rgb);
        writeln(name," zombie front/side/back rendered");
    }
}
