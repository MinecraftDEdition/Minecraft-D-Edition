module minecraftd.platform.desktop.vulkan.device;
import std.path : buildPath;
import std.string : fromStringz, toStringz;

import minecraftd.client.render.graphics_device : GraphicsDevice, TextureHandle;
import minecraftd.client.render.mesh : FrameMesh, MeshHandle, Vertex;
import minecraftd.client.render.texture_manager : ImageData, buildMipChain;

private extern(C) nothrow
{
    void* mdVkCreate(void* window, uint width, uint height,
        const(char)* vertexShader, const(char)* pixelShader,
        const(char)* blurPixelShader,
        char* error, uint errorCapacity);
    void mdVkDestroy(void* context);
    int mdVkUploadTexture(void* context,const(ubyte)* rgba,uint width,
        uint height,uint mipLevels,uint* index,char* error,
        uint errorCapacity);
    int mdVkUploadStaticMesh(void* context, const(Vertex)* vertices,
        uint vertexCount, ulong* id, char* error, uint errorCapacity);
    int mdVkReleaseStaticMesh(void* context, ulong id, char* error,
        uint errorCapacity);
    void mdVkResize(void* context, uint width, uint height);
    void mdVkSetVsync(void* context, int enabled);
    int mdVkRender(void* context, const(Vertex)* vertices, uint vertexCount,
        const(VulkanDraw)* draws, uint drawCount, const(float)* clearColor,
        char* error, uint errorCapacity);
    uint mdVkBlurTexture(const(void)* context);
}

private struct VulkanDraw
{
    ulong meshId;
    uint firstVertex;
    uint vertexCount;
    uint textureIndex;
    uint layer;
    float[16] transform;
    float[12] fog;
}
static assert(VulkanDraw.sizeof == 136,
    "VulkanDraw must match native/vulkan_abi_bridge.cpp");

final class VulkanDevice : GraphicsDevice
{
    private void* context;
    private VulkanDraw[] nativeDraws;

    this(void* window, uint width, uint height, string projectRoot)
    {
        char[1024] error = 0;
        const vertexShader = buildPath(projectRoot, "shaders", "spirv",
            "world.vert.spv");
        const pixelShader = buildPath(projectRoot, "shaders", "spirv",
            "world.frag.spv");
        const blurPixelShader = buildPath(projectRoot, "shaders", "spirv",
            "world.blur.frag.spv");
        context = mdVkCreate(window, width, height,
            vertexShader.toStringz(), pixelShader.toStringz(),
            blurPixelShader.toStringz(), error.ptr, cast(uint) error.length);
        if (context is null)
            throw new Exception(message(error, "Unable to create Vulkan renderer"));
    }

    ~this()
    {
        if (context !is null)
        {
            mdVkDestroy(context);
            context = null;
        }
    }

    override TextureHandle uploadTexture(const ImageData image,
        uint additionalMipLevels)
    {
        const mipChain=buildMipChain(image,additionalMipLevels);
        size_t byteCount;
        foreach(mip;mipChain)byteCount+=mip.rgba.length;
        ubyte[] packed;
        packed.length=byteCount;
        size_t destination;
        foreach(mip;mipChain)
        {
            packed[destination..destination+mip.rgba.length]=mip.rgba;
            destination+=mip.rgba.length;
        }
        char[1024] error = 0;
        uint index;
        if(!mdVkUploadTexture(context,packed.ptr,image.width,image.height,
            cast(uint)mipChain.length,&index,error.ptr,cast(uint)error.length))
            throw new Exception(message(error, "Unable to upload Vulkan texture"));
        return TextureHandle(index);
    }

    override MeshHandle uploadStaticMesh(const Vertex[] vertices)
    {
        if (vertices.length == 0) return MeshHandle.init;
        if (vertices.length > uint.max)
            throw new Exception("Vulkan static mesh is too large");
        char[1024] error = 0;
        ulong id;
        if (!mdVkUploadStaticMesh(context, vertices.ptr,
            cast(uint) vertices.length, &id, error.ptr, cast(uint) error.length))
            throw new Exception(message(error, "Unable to upload Vulkan terrain mesh"));
        return MeshHandle(id, cast(uint) vertices.length);
    }

    override void releaseStaticMesh(MeshHandle mesh)
    {
        if (!mesh.valid) return;
        char[1024] error = 0;
        if (!mdVkReleaseStaticMesh(context, mesh.id, error.ptr,
            cast(uint) error.length))
            throw new Exception(message(error, "Unable to release Vulkan terrain mesh"));
    }

    override TextureHandle menuBlurTexture() const
    {
        return TextureHandle(mdVkBlurTexture(context));
    }

    override void resize(uint width, uint height)
    {
        mdVkResize(context, width, height);
    }

    override void setVsync(bool enabled)
    {
        mdVkSetVsync(context, enabled ? 1 : 0);
    }

    override void render(const FrameMesh frame)
    {
        if (nativeDraws.length < frame.draws.length)
        {
            size_t capacity = nativeDraws.length == 0 ? 256
                : nativeDraws.length * 2;
            if (capacity < frame.draws.length)
                capacity = frame.draws.length;
            nativeDraws.length = capacity;
        }
        foreach (index, draw; frame.draws)
        {
            nativeDraws[index].meshId = draw.meshId;
            nativeDraws[index].firstVertex = draw.firstVertex;
            nativeDraws[index].vertexCount = draw.vertexCount;
            nativeDraws[index].textureIndex = draw.textureIndex;
            nativeDraws[index].layer = cast(uint) draw.layer;
            nativeDraws[index].transform = draw.transform.m;
            nativeDraws[index].fog = draw.fog.constants();
        }
        const float[4] clearColor = [frame.clearColor.r, frame.clearColor.g,
            frame.clearColor.b, frame.clearColor.a];
        char[1024] error = 0;
        if (!mdVkRender(context, frame.vertices.ptr,
            cast(uint) frame.vertices.length, nativeDraws.ptr,
            cast(uint) frame.draws.length,
            clearColor.ptr, error.ptr, cast(uint) error.length))
            throw new Exception(message(error, "Vulkan frame failed"));
    }

private:
    static string message(ref char[1024] error, string fallback)
    {
        return error[0] ? fromStringz(error.ptr).idup : fallback;
    }
}
