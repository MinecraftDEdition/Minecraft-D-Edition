module minecraftd.platform.windows.dx12.shader;

import directx.d3dcompiler;
import minecraftd.platform.windows.dx12.command_context : requireSuccess;

struct ShaderPair
{
    ID3DBlob vertex;
    ID3DBlob pixel;
    ID3DBlob blurPixel;

    void release()
    {
        if (vertex !is null) { vertex.Release(); vertex = null; }
        if (pixel !is null) { pixel.Release(); pixel = null; }
        if (blurPixel !is null) { blurPixel.Release(); blurPixel = null; }
    }
}

ShaderPair compileWorldShaders()
{
    enum source = import("world.hlsl");
    debug const uint flags = D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION;
    else const uint flags = D3DCOMPILE_OPTIMIZATION_LEVEL3;

    ShaderPair result;
    ID3DBlob errors;
    scope (exit) if (errors !is null) errors.Release();
    requireSuccess(D3DCompile(
        source.ptr,
        source.length,
        "world.hlsl",
        null,
        null,
        "VSMain",
        vs_5_0,
        flags,
        0,
        &result.vertex,
        &errors,
    ), "Compile vertex shader");
    requireSuccess(D3DCompile(
        source.ptr,
        source.length,
        "world.hlsl",
        null,
        null,
        "PSMain",
        ps_5_0,
        flags,
        0,
        &result.pixel,
        &errors,
    ), "Compile pixel shader");
    requireSuccess(D3DCompile(
        source.ptr,
        source.length,
        "world.hlsl",
        null,
        null,
        "PSBlur",
        ps_5_0,
        flags,
        0,
        &result.blurPixel,
        &errors,
    ), "Compile menu blur pixel shader");
    return result;
}
