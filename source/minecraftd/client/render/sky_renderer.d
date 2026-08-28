module minecraftd.client.render.sky_renderer;

import core.stdc.math : floorf;
import minecraftd.client.render.mesh : Vertex, Color, appendQuad;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.common.math3d : Vec2, Vec3, cross;

final class SkyRenderer
{
    private ImageData cloudMask;

    this(ImageData cloudMask)
    {
        this.cloudMask = cloudMask;
    }

    Vertex[] buildSun(Vec3 cameraPosition)
    {
        Vertex[] output;
        // Minecraft's quad spans -30..30 at a radius of 100. Keep this first
        // fixed daytime sky in the western (-X) half of the Overworld.
        const center = cameraPosition + Vec3(-70.71068f, 70.71068f, 0.0f);
        const direction = (cameraPosition - center).normalized();
        const right = cross(Vec3(0,1,0), direction).normalized() * 30.0f;
        const up = cross(direction, right.normalized()) * 30.0f;
        const white = Color(1,1,1,1);
        appendQuad(output,
            center-right-up, center+right-up, center+right+up, center-right+up,
            Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0), white,white,white,white);
        return output;
    }

    Vertex[] buildClouds(Vec3 cameraPosition, float elapsedSeconds,
        bool fancy = true)
    {
        Vertex[] output;
        if (cloudMask.width == 0 || cloudMask.height == 0)
            return output;

        enum float cellSize = 12.0f;
        const float thickness = fancy ? 4.0f : 0.0f;
        enum float cloudHeight = 192.0f;
        enum int radius = 32;
        const scroll = elapsedSeconds * 0.6f; // Java: 0.03 blocks/tick at 20 Hz.
        const cloudX = cameraPosition.x + scroll;
        const cloudZ = cameraPosition.z + 3.96f;
        const centerX = cast(int) floorf(cloudX / cellSize);
        const centerZ = cast(int) floorf(cloudZ / cellSize);
        enum int diameter = radius * 2 + 1;
        bool[diameter][diameter] occupied;
        bool[diameter][diameter] merged;

        foreach (localZ; 0 .. diameter)
        foreach (localX; 0 .. diameter)
        {
            const relativeX = localX - radius;
            const relativeZ = localZ - radius;
            occupied[localZ][localX] = formationVisible(
                wrap(centerX + relativeX, cast(int) cloudMask.width),
                wrap(centerZ + relativeZ, cast(int) cloudMask.height));
        }

        const top = Color(1.0f, 1.0f, 1.0f, 0.8f);
        const bottom = Color(0.7f, 0.7f, 0.7f, 0.8f);
        const northSouth = Color(0.9f, 0.9f, 0.9f, 0.8f);
        const eastWest = Color(0.8f, 0.8f, 0.8f, 0.8f);

        // Greedily merge adjacent opaque mask cells into broad coplanar top
        // and bottom faces. The old one-quad-per-texel mesh exposed its grid
        // as long translucent strips; shared cloud masses now read as a single
        // silhouette while retaining vanilla's pixel-shaped outline.
        foreach (localZ; 0 .. diameter)
        foreach (localX; 0 .. diameter)
        {
            if (!occupied[localZ][localX] || merged[localZ][localX])
                continue;
            int runWidth = 1;
            while (localX + runWidth < diameter
                && occupied[localZ][localX + runWidth]
                && !merged[localZ][localX + runWidth])
                ++runWidth;
            int runHeight = 1;
            bool canGrow = true;
            while (localZ + runHeight < diameter && canGrow)
            {
                foreach (offsetX; 0 .. runWidth)
                    if (!occupied[localZ + runHeight][localX + offsetX]
                        || merged[localZ + runHeight][localX + offsetX])
                    {
                        canGrow = false;
                        break;
                    }
                if (canGrow) ++runHeight;
            }
            foreach (offsetZ; 0 .. runHeight)
            foreach (offsetX; 0 .. runWidth)
                merged[localZ + offsetZ][localX + offsetX] = true;

            const relativeX = localX - radius;
            const relativeZ = localZ - radius;
            const x0 = cast(float) (centerX + relativeX) * cellSize - scroll;
            const x1 = x0 + cast(float) runWidth * cellSize;
            const z0 = cast(float) (centerZ + relativeZ) * cellSize - 3.96f;
            const z1 = z0 + cast(float) runHeight * cellSize;
            const textureX = wrap(centerX + relativeX,
                cast(int) cloudMask.width);
            const textureZ = wrap(centerZ + relativeZ,
                cast(int) cloudMask.height);
            int sampleX;
            int sampleZ;
            visibleSample(textureX, textureZ, sampleX, sampleZ);
            const uv = Vec2(
                (cast(float) sampleX + 0.5f) / cloudMask.width,
                (cast(float) sampleZ + 0.5f) / cloudMask.height);
            appendQuad(output, Vec3(x0,cloudHeight+thickness,z0),
                Vec3(x0,cloudHeight+thickness,z1),
                Vec3(x1,cloudHeight+thickness,z1),
                Vec3(x1,cloudHeight+thickness,z0), uv,uv,uv,uv,
                top,top,top,top);
            if(fancy)
                appendQuad(output, Vec3(x1,cloudHeight,z0),
                    Vec3(x1,cloudHeight,z1), Vec3(x0,cloudHeight,z1),
                    Vec3(x0,cloudHeight,z0), uv,uv,uv,uv,
                    bottom,bottom,bottom,bottom);
        }

        if(fancy) foreach (relativeZ; -radius .. radius + 1)
        foreach (relativeX; -radius .. radius + 1)
        {
            const textureX = wrap(centerX + relativeX, cast(int) cloudMask.width);
            const textureZ = wrap(centerZ + relativeZ, cast(int) cloudMask.height);
            if (!formationVisible(textureX, textureZ))
                continue;

            const x0 = cast(float) (centerX + relativeX) * cellSize - scroll;
            const x1 = x0 + cellSize;
            const z0 = cast(float) (centerZ + relativeZ) * cellSize - 3.96f;
            const z1 = z0 + cellSize;
            const y0 = cloudHeight;
            int sampleX;
            int sampleZ;
            visibleSample(textureX, textureZ, sampleX, sampleZ);
            const uv = Vec2(
                (cast(float) sampleX + 0.5f) / cloudMask.width,
                (cast(float) sampleZ + 0.5f) / cloudMask.height,
            );
            if (!formationVisible(textureX, textureZ - 1))
                appendQuad(output, Vec3(x1,y0,z0), Vec3(x0,y0,z0),
                    Vec3(x0,y0+thickness,z0), Vec3(x1,y0+thickness,z0), uv,uv,uv,uv,
                    northSouth,northSouth,northSouth,northSouth);
            if (!formationVisible(textureX, textureZ + 1))
                appendQuad(output, Vec3(x0,y0,z1), Vec3(x1,y0,z1),
                    Vec3(x1,y0+thickness,z1), Vec3(x0,y0+thickness,z1), uv,uv,uv,uv,
                    northSouth,northSouth,northSouth,northSouth);
            if (!formationVisible(textureX - 1, textureZ))
                appendQuad(output, Vec3(x0,y0,z0), Vec3(x0,y0,z1),
                    Vec3(x0,y0+thickness,z1), Vec3(x0,y0+thickness,z0), uv,uv,uv,uv,
                    eastWest,eastWest,eastWest,eastWest);
            if (!formationVisible(textureX + 1, textureZ))
                appendQuad(output, Vec3(x1,y0,z1), Vec3(x1,y0,z0),
                    Vec3(x1,y0+thickness,z0), Vec3(x1,y0+thickness,z1), uv,uv,uv,uv,
                    eastWest,eastWest,eastWest,eastWest);
        }
        return output;
    }

private:
    int wrap(int value, int dimension) const
    {
        const remainder = value % dimension;
        return remainder < 0 ? remainder + dimension : remainder;
    }

    bool visible(int x, int z) const
    {
        x = wrap(x, cast(int) cloudMask.width);
        z = wrap(z, cast(int) cloudMask.height);
        return cloudMask.rgba[(cast(size_t) z * cloudMask.width + x) * 4 + 3] >= 10;
    }

    bool formationVisible(int x, int z) const
    {
        // Modern Java consumes the 256x256 alpha mask directly. The previous
        // neighborhood filter joined nearby texels and manufactured the long,
        // disconnected slab formations visible in D Edition screenshots.
        return visible(x,z);
    }

    void visibleSample(int x, int z, out int sampleX, out int sampleZ) const
    {
        if (visible(x, z))
        {
            sampleX = wrap(x, cast(int) cloudMask.width);
            sampleZ = wrap(z, cast(int) cloudMask.height);
            return;
        }
        foreach (offsetZ; -1 .. 2)
        foreach (offsetX; -1 .. 2)
            if (visible(x + offsetX, z + offsetZ))
            {
                sampleX = wrap(x + offsetX, cast(int) cloudMask.width);
                sampleZ = wrap(z + offsetZ, cast(int) cloudMask.height);
                return;
            }
        sampleX = wrap(x, cast(int) cloudMask.width);
        sampleZ = wrap(z, cast(int) cloudMask.height);
    }
}

unittest
{
    ImageData mask;
    mask.width = mask.height = 8;
    mask.rgba.length = 8 * 8 * 4;
    foreach (x; 2 .. 5)
        mask.rgba[(4 * 8 + x) * 4 + 3] = 255;
    mask.rgba[3] = 255; // isolated mask noise
    auto renderer = new SkyRenderer(mask);
    scope (exit) destroy(renderer);
    assert(!renderer.visible(3, 3));
    assert(!renderer.formationVisible(3, 3));
    assert(renderer.formationVisible(0, 0)); // the source mask is authoritative
}
