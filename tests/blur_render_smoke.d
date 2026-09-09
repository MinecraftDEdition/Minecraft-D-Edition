module blur_render_smoke;

import core.sys.windows.windows;
import std.file : mkdirRecurse,write;
import std.stdio : writeln;
import std.format : format;
import minecraftd.client.render.graphics_device;
import minecraftd.client.render.mesh;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.common.math3d;
import minecraftd.platform.windows.dx12.device : Dx12Device;
import minecraftd.platform.desktop.vulkan.device : VulkanDevice;

void main()
{
    mkdirRecurse("test-output/blur");
    foreach(vulkan;[false,true])
    {
        auto window=CreateWindowExW(0,"STATIC"w.ptr,"MCDE blur regression"w.ptr,
            WS_OVERLAPPEDWINDOW,0,0,640,384,null,null,GetModuleHandleW(null),null);
        assert(window !is null);
        scope(exit)DestroyWindow(window);
        GraphicsDevice graphics;
        foreach(size;[[640u,384u],[641u,385u],[320u,240u]])
        {
            const w=size[0],h=size[1];
            RECT rect=RECT(0,0,w,h);
            AdjustWindowRect(&rect,WS_OVERLAPPEDWINDOW,FALSE);
            SetWindowPos(window,null,0,0,rect.right-rect.left,rect.bottom-rect.top,
                SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);
            if(graphics is null)
                graphics=vulkan?cast(GraphicsDevice)new VulkanDevice(window,w,h,".")
                    :cast(GraphicsDevice)new Dx12Device(window,w,h);
            else graphics.resize(w,h);
            ImageData source=ImageData(w,h,new ubyte[w*h*4]);
            foreach(y;0..h)foreach(x;0..w)
            {
                const p=(y*w+x)*4;
                source.rgba[p..p+3]=x>=w/2&&y>=h/2?255:0;
                source.rgba[p+3]=255;
            }
            const texture=graphics.uploadTexture(source);
            Vertex[] quad;
            const white=Color(1,1,1,1);
            appendQuad(quad,Vec3(-1,1,0),Vec3(1,1,0),Vec3(1,-1,0),Vec3(-1,-1,0),
                Vec2(0,0),Vec2(1,0),Vec2(1,1),Vec2(0,1),white,white,white,white);
            foreach(sigma;[2.4f,12.0f,24.0f])
            {
                FrameMesh frame;
                frame.append(quad,texture.descriptorIndex,Mat4.identity(),DrawLayer.overlay);
                frame.append(quad,graphics.menuBlurTexture().descriptorIndex,Mat4.identity(),
                    DrawLayer.blurBackdrop,FogSettings.blur(w,h,sigma));
                // Repeated frames exercise read/write barriers and buffer reuse.
                foreach(_;0..3)graphics.render(frame);
                ImageData image=vulkan?(cast(VulkanDevice)graphics).readBlurPixels()
                    :(cast(Dx12Device)graphics).readBlurPixels();
                int pixel(uint x,uint y){return image.rgba[(y*image.width+x)*4];}
                assert(image.width==w/2&&image.height==h/2);
                const cx=image.width/2,cy=image.height/2;
                assert(pixel(0,0)==0&&pixel(0,image.height-1)==0,"Clamp edges must not wrap");
                assert(pixel(image.width-1,image.height-1)>250,"Blur must preserve a constant region");
                assert(pixel(cx,cy)>40&&pixel(cx,cy)<155,"Both blur axes must contribute at the corner");
                assert(pixel(cx-1,cy-1)>10,"Diagonal neighbors must receive blurred light");
                foreach(x;1..image.width)
                    assert(pixel(x,cy)+1>=pixel(x-1,cy),"Gaussian edge must be smooth and monotonic");
                foreach(y;1..image.height)
                    assert(pixel(cx,y)+1>=pixel(cx,y-1),"Vertical blur must be smooth and upright");
                ubyte[] rgb;
                foreach(p;0..image.width*image.height)rgb~=image.rgba[p*4..p*4+3];
                const name=format("test-output/blur/%s-%sx%s-%.1f.ppm",vulkan?"vulkan":"dx12",w,h,sigma);
                write(name,format("P6\n%s %s\n255\n",image.width,image.height)~cast(string)rgb);
                writeln(name," passed; corner=",pixel(cx,cy));
            }
            // Exercise leaving the pause menu between resized blur sequences.
            FrameMesh plain;
            plain.append(quad,texture.descriptorIndex,Mat4.identity(),DrawLayer.overlay);
            graphics.render(plain);
        }
        destroy(graphics);
    }
}
