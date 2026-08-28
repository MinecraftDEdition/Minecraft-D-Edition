cbuffer Transform : register(b0)
{
    float4 gRow0;
    float4 gRow1;
    float4 gRow2;
    float4 gRow3;
};

cbuffer Fog : register(b1)
{
    float4 gFogColor;
    float4 gFogCameraAndEnabled;
    float4 gFogDistances;
};

Texture2D gTexture : register(t0);
SamplerState gSampler : register(s0);

struct VertexInput
{
    float3 position : POSITION;
    float2 uv : TEXCOORD;
    float4 color : COLOR;
};

struct PixelInput
{
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD;
    float4 color : COLOR;
    float3 worldPosition : TEXCOORD1;
};

PixelInput VSMain(VertexInput input)
{
    PixelInput output;
    float4 vertexPosition = float4(input.position, 1.0f);
    output.position = float4(
        dot(vertexPosition, float4(gRow0.x, gRow1.x, gRow2.x, gRow3.x)),
        dot(vertexPosition, float4(gRow0.y, gRow1.y, gRow2.y, gRow3.y)),
        dot(vertexPosition, float4(gRow0.z, gRow1.z, gRow2.z, gRow3.z)),
        dot(vertexPosition, float4(gRow0.w, gRow1.w, gRow2.w, gRow3.w))
    );
    output.uv = input.uv;
    output.color = input.color;
    output.worldPosition = input.position;
    return output;
}

float4 PSMain(PixelInput input) : SV_TARGET
{
    float4 sampled = gTexture.Sample(gSampler, input.uv);
    clip(sampled.a - 0.02f);
    float4 color = sampled * input.color;
    float horizontalDistance = length(input.worldPosition.xz - gFogCameraAndEnabled.xz);
    float fogRange = max(gFogDistances.y - gFogDistances.x, 0.001f);
    float fogAmount = saturate((horizontalDistance - gFogDistances.x) / fogRange)
        * gFogCameraAndEnabled.w;
    color.rgb = lerp(color.rgb, gFogColor.rgb, fogAmount);
    return color;
}

// A real post-process blur for in-world menus.  The source texture is a copy
// of the completed scene, so this samples actual neighbouring framebuffer
// pixels rather than imitating blur with a translucent rectangle.
float4 PSBlur(PixelInput input) : SV_TARGET
{
    float2 texel = gFogDistances.xy;
    float radius = max(gFogCameraAndEnabled.w, 0.0f);
    float2 dx = float2(texel.x * radius, 0.0f);
    float2 dy = float2(0.0f, texel.y * radius);
    float4 color = gTexture.Sample(gSampler, input.uv) * 0.196326f;
    color += gTexture.Sample(gSampler, input.uv + dx * 1.384615f) * 0.136731f;
    color += gTexture.Sample(gSampler, input.uv - dx * 1.384615f) * 0.136731f;
    color += gTexture.Sample(gSampler, input.uv + dy * 1.384615f) * 0.136731f;
    color += gTexture.Sample(gSampler, input.uv - dy * 1.384615f) * 0.136731f;
    color += gTexture.Sample(gSampler, input.uv + dx * 3.230769f) * 0.064187f;
    color += gTexture.Sample(gSampler, input.uv - dx * 3.230769f) * 0.064187f;
    color += gTexture.Sample(gSampler, input.uv + dy * 3.230769f) * 0.064187f;
    color += gTexture.Sample(gSampler, input.uv - dy * 3.230769f) * 0.064187f;
    return color * input.color;
}
