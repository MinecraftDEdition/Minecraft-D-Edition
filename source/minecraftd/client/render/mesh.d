module minecraftd.client.render.mesh;

import minecraftd.common.math3d : Vec2, Vec3, Mat4;

struct Color
{
    float r = 1.0f;
    float g = 1.0f;
    float b = 1.0f;
    float a = 1.0f;

    Color shaded(float amount) const
    {
        return Color(r * amount, g * amount, b * amount, a);
    }
}

struct Vertex
{
    float[3] position;
    float[2] uv;
    float[4] color;

    this(Vec3 position, Vec2 uv, Color color)
    {
        this.position = [position.x, position.y, position.z];
        this.uv = [uv.x, uv.y];
        this.color = [color.r, color.g, color.b, color.a];
    }

    version (Windows) static auto inputLayout()
    {
        import directx.d3d12 : D3D12_INPUT_ELEMENT_DESC, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
        import directx.dxgiformat : DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT;
        D3D12_INPUT_ELEMENT_DESC[] layout = [
            {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 20, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        ];
        return layout;
    }
}

struct DrawCall
{
    uint firstVertex;
    uint vertexCount;
    uint textureIndex;
    Mat4 transform;
    DrawLayer layer;
    FogSettings fog;
}

/// Per-draw distance fog. World position is measured in the pixel shader so
/// the same setting works for terrain, entities, particles, and clouds.
struct FogSettings
{
    // Vanilla's clear Overworld fog is #c0d8ff, deliberately paler than the
    // plains sky (#78a7ff), so distant terrain dissolves into atmospheric haze.
    Color color = Color(192.0f / 255.0f, 216.0f / 255.0f, 1.0f, 1.0f);
    Vec3 cameraPosition;
    float enabled = 0.0f;
    float startDistance = 0.0f;
    float endDistance = 1.0f;

    static FogSettings disabled()
    {
        return FogSettings.init;
    }

    static FogSettings distance(Vec3 cameraPosition, float startDistance,
        float endDistance)
    {
        FogSettings result;
        result.cameraPosition = cameraPosition;
        result.enabled = 1.0f;
        result.startDistance = startDistance;
        result.endDistance = endDistance;
        return result;
    }

    static FogSettings blur(uint width, uint height, float radius)
    {
        FogSettings result;
        result.enabled = radius;
        result.startDistance = 1.0f / cast(float) (width == 0 ? 1 : width);
        result.endDistance = 1.0f / cast(float) (height == 0 ? 1 : height);
        return result;
    }

    float[12] constants() const
    {
        return [
            color.r, color.g, color.b, color.a,
            cameraPosition.x, cameraPosition.y, cameraPosition.z, enabled,
            startDistance, endDistance, 0.0f, 0.0f,
        ];
    }
}

enum DrawLayer : ubyte
{
    sky,
    world,
    translucent,
    entityShadow,
    viewModel,
    blurBackdrop,
    overlay,
    invertedOverlay,
    /// Alpha-blended geometry whose cube faces are visible only from outside.
    translucentCulled,
    /// Depth-writing geometry that intentionally has no back-face culling,
    /// such as camera-facing particles and skinned entity meshes.
    worldDoubleSided,
}

struct FrameMesh
{
    Vertex[] vertices;
    DrawCall[] draws;
    Color clearColor = Color(0.48f,0.70f,1.0f,1.0f);

    void clear(Color color = Color(0.48f,0.70f,1.0f,1.0f))
    {
        vertices.length = 0;
        draws.length = 0;
        clearColor = color;
    }

    void append(Vertex[] source, uint textureIndex, Mat4 transform,
        DrawLayer layer = DrawLayer.world,
        FogSettings fog = FogSettings.disabled())
    {
        if (source.length == 0)
            return;
        if (source.length % 3 != 0)
            throw new Exception("Mesh source is not a complete triangle list");
        const first = cast(uint) vertices.length;
        vertices ~= source;
        draws ~= DrawCall(first, cast(uint) source.length, textureIndex,
            transform, layer, fog);
    }
}

void appendQuad(
    ref Vertex[] vertices,
    Vec3 p0,
    Vec3 p1,
    Vec3 p2,
    Vec3 p3,
    Vec2 uv0,
    Vec2 uv1,
    Vec2 uv2,
    Vec2 uv3,
    Color c0,
    Color c1,
    Color c2,
    Color c3,
)
{
    // Split direction follows the brighter AO diagonal to reduce interpolation seams.
    if (c0.r + c2.r > c1.r + c3.r)
    {
        vertices ~= [Vertex(p0, uv0, c0), Vertex(p1, uv1, c1), Vertex(p3, uv3, c3)];
        vertices ~= [Vertex(p1, uv1, c1), Vertex(p2, uv2, c2), Vertex(p3, uv3, c3)];
    }
    else
    {
        vertices ~= [Vertex(p0, uv0, c0), Vertex(p1, uv1, c1), Vertex(p2, uv2, c2)];
        vertices ~= [Vertex(p0, uv0, c0), Vertex(p2, uv2, c2), Vertex(p3, uv3, c3)];
    }
}
