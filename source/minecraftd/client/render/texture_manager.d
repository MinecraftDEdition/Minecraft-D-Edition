module minecraftd.client.render.texture_manager;

version (Windows)
{
    import core.sys.windows.com : CoCreateInstance, CLSCTX_INPROC_SERVER;
    import core.sys.windows.windows : GENERIC_READ, FAILED;
    import directx.wincodec;
    import std.utf : toUTF16z;
}
else version (OSX)
{
    import core.stdc.stdlib : free;
    import core.stdc.string : memcpy;
    import std.string : fromStringz, toStringz;

    private extern(C) nothrow
    {
        int mcdImageLoadPng(const(char)* path, ubyte** pixels, uint* width,
            uint* height, char* error, uint errorCapacity);
        void mcdImageFree(void* pixels);
    }
}

struct ImageData
{
    uint width;
    uint height;
    ubyte[] rgba;
}

/// Builds tightly packed, alpha-aware mip levels after the original image.
/// `additionalLevels` follows the video setting: zero keeps level 0 only,
/// while four permits the complete 16 -> 8 -> 4 -> 2 -> 1 block chain.
ImageData[] buildMipChain(const ImageData source,uint additionalLevels)
{
    ImageData[] result;
    result~=ImageData(source.width,source.height,source.rgba.dup);
    foreach(unused;0..additionalLevels)
    {
        const previous=result[$-1];
        if(previous.width==1&&previous.height==1)break;
        ImageData next;
        next.width=previous.width>1?previous.width/2:1;
        next.height=previous.height>1?previous.height/2:1;
        next.rgba.length=cast(size_t)next.width*next.height*4;
        foreach(y;0..next.height)foreach(x;0..next.width)
        {
            uint alphaTotal,redPremultiplied,greenPremultiplied,
                bluePremultiplied,samples;
            foreach(sampleY;0..2)foreach(sampleX;0..2)
            {
                const sourceX=x*2+sampleX<previous.width
                    ?x*2+sampleX:previous.width-1;
                const sourceY=y*2+sampleY<previous.height
                    ?y*2+sampleY:previous.height-1;
                const sourceOffset=(cast(size_t)sourceY*previous.width
                    +sourceX)*4;
                const alpha=previous.rgba[sourceOffset+3];
                alphaTotal+=alpha;
                redPremultiplied+=previous.rgba[sourceOffset]*alpha;
                greenPremultiplied+=previous.rgba[sourceOffset+1]*alpha;
                bluePremultiplied+=previous.rgba[sourceOffset+2]*alpha;
                ++samples;
            }
            const destination=(cast(size_t)y*next.width+x)*4;
            if(alphaTotal)
            {
                next.rgba[destination]=cast(ubyte)(redPremultiplied/alphaTotal);
                next.rgba[destination+1]=cast(ubyte)(greenPremultiplied/alphaTotal);
                next.rgba[destination+2]=cast(ubyte)(bluePremultiplied/alphaTotal);
            }
            next.rgba[destination+3]=cast(ubyte)(alphaTotal/samples);
        }
        result~=next;
    }
    return result;
}

final class TextureManager
{
    version (Windows) private IWICImagingFactory factory;

    this()
    {
        version (Windows)
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
    }

    ~this()
    {
        version (Windows)
        {
        if (factory !is null)
            factory.Release();
        }
    }

    ImageData loadPng(string path)
    {
        version (Windows) return loadPngWindows(path);
        else version (OSX) return loadPngPortable(path);
    }

    version (Windows) private ImageData loadPngWindows(string path)
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

    version (OSX) private ImageData loadPngPortable(string path)
    {
        ubyte* decoded;
        ImageData image;
        char[1024] error = 0;
        if (!mcdImageLoadPng(path.toStringz(), &decoded, &image.width,
                &image.height, error.ptr, cast(uint) error.length))
            throw new Exception(error[0] ? fromStringz(error.ptr).idup
                : "Unable to decode PNG: " ~ path);
        scope (exit) mcdImageFree(decoded);
        image.rgba.length = cast(size_t) image.width * image.height * 4;
        if (image.rgba.length)
            memcpy(image.rgba.ptr, decoded, image.rgba.length);
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

unittest
{
    ImageData image;
    image.width=image.height=4;
    image.rgba.length=4*4*4;
    foreach(offset;0..image.rgba.length/4)
        image.rgba[offset*4..offset*4+4]=[cast(ubyte)200,100,50,255];
    const levels=buildMipChain(image,4);
    assert(levels.length==3);
    assert(levels[1].width==2&&levels[1].height==2);
    assert(levels[2].width==1&&levels[2].height==1);
    assert(levels[2].rgba==[cast(ubyte)200,100,50,255]);
}
