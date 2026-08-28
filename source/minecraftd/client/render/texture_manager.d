module minecraftd.client.render.texture_manager;

version (Windows):

import core.sys.windows.com : CoCreateInstance, CLSCTX_INPROC_SERVER;
import core.sys.windows.windows : GENERIC_READ, SUCCEEDED, FAILED;
import directx.wincodec;
import std.utf : toUTF16z;

struct ImageData
{
    uint width;
    uint height;
    ubyte[] rgba;
}

final class TextureManager
{
    private IWICImagingFactory factory;

    this()
    {
        const result = CoCreateInstance(
            &CLSID_WICImagingFactory,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_IWICImagingFactory,
            cast(void**) &factory,
        );
        if (FAILED(result) || factory is null)
            throw new Exception("Unable to create the Windows Imaging Component factory");
    }

    ~this()
    {
        if (factory !is null)
            factory.Release();
    }

    ImageData loadPng(string path)
    {
        IWICBitmapDecoder decoder;
        IWICBitmapFrameDecode frame;
        IWICFormatConverter converter;
        scope (exit)
        {
            if (converter !is null) converter.Release();
            if (frame !is null) frame.Release();
            if (decoder !is null) decoder.Release();
        }

        if (FAILED(factory.CreateDecoderFromFilename(
            path.toUTF16z(),
            null,
            GENERIC_READ,
            WICDecodeMetadataCacheOnLoad,
            &decoder,
        )))
            throw new Exception("Unable to decode PNG: " ~ path);
        if (FAILED(decoder.GetFrame(0, &frame)))
            throw new Exception("Unable to read PNG frame: " ~ path);
        if (FAILED(factory.CreateFormatConverter(&converter)))
            throw new Exception("Unable to create PNG format converter");
        if (FAILED(converter.Initialize(
            frame,
            &GUID_WICPixelFormat32bppRGBA,
            WICBitmapDitherTypeNone,
            null,
            0.0,
            WICBitmapPaletteTypeCustom,
        )))
            throw new Exception("Unable to convert PNG to RGBA8: " ~ path);

        ImageData image;
        if (FAILED(converter.GetSize(&image.width, &image.height)))
            throw new Exception("Unable to query PNG dimensions: " ~ path);
        const stride = image.width * 4;
        image.rgba.length = stride * image.height;
        if (FAILED(converter.CopyPixels(null, stride, cast(uint) image.rgba.length, image.rgba.ptr)))
            throw new Exception("Unable to copy PNG pixels: " ~ path);
        return image;
    }

    /// Java's celestial texture is authored as an opaque additive sprite.
    /// Our regular alpha-blended pass needs its black luminance moved into
    /// transparency or the texture's black square becomes visible.
    ImageData loadAdditivePngAsAlpha(string path)
    {
        auto image = loadPng(path);
        for (size_t offset = 0; offset < image.rgba.length; offset += 4)
        {
            const red = image.rgba[offset];
            const green = image.rgba[offset + 1];
            const blue = image.rgba[offset + 2];
            const intensity = red > green
                ? (red > blue ? red : blue)
                : (green > blue ? green : blue);
            if (intensity == 0)
            {
                image.rgba[offset .. offset + 4] = 0;
                continue;
            }
            image.rgba[offset] = cast(ubyte) ((cast(uint) red * 255u) / intensity);
            image.rgba[offset + 1] = cast(ubyte) ((cast(uint) green * 255u) / intensity);
            image.rgba[offset + 2] = cast(ubyte) ((cast(uint) blue * 255u) / intensity);
            image.rgba[offset + 3] = intensity;
        }
        return image;
    }
}
