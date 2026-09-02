module minecraftd.client.render.graphics_device;

import minecraftd.client.render.mesh : FrameMesh, MeshHandle, Vertex;
import minecraftd.client.render.texture_manager : ImageData;

enum GraphicsApi : ubyte
{
    directX12,
    vulkan,
}

struct TextureHandle
{
    uint descriptorIndex;
}

abstract class GraphicsDevice
{
    abstract TextureHandle uploadTexture(const ImageData image);
    abstract MeshHandle uploadStaticMesh(const Vertex[] vertices);
    abstract void releaseStaticMesh(MeshHandle mesh);
    abstract TextureHandle menuBlurTexture() const;
    abstract void resize(uint width, uint height);
    abstract void render(const FrameMesh frame);
    abstract void setVsync(bool enabled);
}
