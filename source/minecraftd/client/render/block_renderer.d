module minecraftd.client.render.block_renderer;

import minecraftd.client.render.mesh : Vertex, Color, appendQuad;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.client.render.world_lighting : WorldLighting;
import minecraftd.common.math3d : Vec2, Vec3;
import minecraftd.world.block : BlockId, isFire, isOpaque, isWater, waterHeight;
import minecraftd.world.chunk : Chunk, ChunkCoordinate;
import minecraftd.world.world : World;
import std.conv : to;

struct BlockTextureSet
{
    uint grassTop;
    uint grassSide;
    uint dirt;
    uint stone;
    uint obsidian;
    uint netherrack;
    uint bedrock;
    uint bricks;
    uint oakPlanks;
    uint sprucePlanks;
    uint birchPlanks;
    uint junglePlanks;
    uint acaciaPlanks;
    uint darkOakPlanks;
    uint mangrovePlanks;
    uint cherryPlanks;
    uint bambooPlanks;
    uint paleOakPlanks;
    uint crimsonPlanks;
    uint warpedPlanks;
    uint cobblestone;
    uint glass;
    uint waterStill;
    uint waterFlow;
    uint netherPortal;
    uint flintAndSteel;
}

/// Water is split by face role so the horizontal sheet has a deterministic
/// draw order.  In particular, it must not depend on associative-array
/// iteration order shared with the vertical flowing-water faces.
struct WaterGeometry
{
    Vertex[] surface;
    Vertex[] walls;
    Vertex[] underside;
}

struct FireGeometry
{
    Vertex[] layer0;
    Vertex[] layer1;
}

unittest
{
    auto testWorld=new World();
    scope(exit)destroy(testWorld);
    testWorld.setBlock(20,1,20,BlockId.waterSource);
    auto renderer=new BlockRenderer(testWorld);
    scope(exit)destroy(renderer);
    const geometry=renderer.buildWater();
    assert(geometry.surface.length==6);
    assert(geometry.walls.length==24);
    assert(geometry.underside.length==0); // hidden by the terrain below

    // The old regression test only counted all water vertices together, so a
    // mesh made entirely from walls could pass.  Verify that the top is a
    // non-degenerate, upward-wound triangle at the fluid height.
    const a=geometry.surface[0].position;
    const b=geometry.surface[1].position;
    const c=geometry.surface[2].position;
    const abx=b[0]-a[0], abz=b[2]-a[2];
    const acx=c[0]-a[0], acz=c[2]-a[2];
    assert(abz*acx-abx*acz>0.5f);
    assert(a[1]>1.0f);
    assert(b[1]>1.0f);
    assert(c[1]>1.0f);
}

unittest
{
    // Keep the first streamed 3x3 terrain neighborhood compact enough to
    // mesh incrementally without a visible loading hitch.
    auto generated=new World();
    scope(exit)destroy(generated);
    generated.settings.seed=8675309;
    generated.generate();
    auto renderer=new BlockRenderer(generated);
    scope(exit)destroy(renderer);
    size_t vertices;
    foreach(texture,geometry;renderer.build(BlockTextureSet.init))
        vertices+=geometry.length;
    const water=renderer.buildWater();
    vertices+=water.surface.length+water.walls.length+water.underside.length;
    assert(vertices<450_000);
}

unittest
{
    // Adjacent flat faces with identical texture and baked lighting collapse
    // into a repeating quad. The surrounding sides may retain individual AO,
    // but the 2x2 top must no longer cost four separate quads.
    auto flatWorld=new World();
    scope(exit)destroy(flatWorld);
    foreach(y;1..3)foreach(z;0..Chunk.depth)foreach(x;0..Chunk.width)
        flatWorld.setBlock(x,y,z,BlockId.air);
    foreach(z;2..4)foreach(x;12..14)
        flatWorld.setBlock(x,1,z,BlockId.stone);
    auto renderer=new BlockRenderer(flatWorld);
    scope(exit)destroy(renderer);
    BlockTextureSet textures;
    textures.stone=42;
    const geometry=renderer.buildChunkRange(textures,ChunkCoordinate(0,0),1,1);
    auto stone=42 in geometry;
    assert(stone !is null,"missing stone geometry");
    assert(stone.length<72,"stone vertices: "~to!string(stone.length));
    bool repeats;
    foreach(vertex;*stone)
        if(vertex.uv[0]>1.5f||vertex.uv[1]>1.5f)repeats=true;
    assert(repeats);
}

enum Face : int { down, up, north, south, west, east }

final class BlockRenderer
{
    private World world;
    private WorldLighting lighting;
    private bool smoothLighting = true;

    this(World world)
    {
        this.world = world;
        lighting = new WorldLighting(world);
    }

    ~this()
    {
        destroy(lighting);
    }

    void configure(bool smooth, float brightnessValue)
    {
        smoothLighting=smooth;
        lighting.configure(brightnessValue);
    }

    float lightAt(Vec3 position)
    {
        return lighting.brightnessAt(position);
    }

    Vertex[][uint] build(const BlockTextureSet textures)
    {
        lighting.refresh();
        Vertex[][uint] byTexture;
        foreach (coordinate; world.loadedChunkCoordinates())
        {
            auto part=buildChunk(textures,coordinate);
            foreach(texture,geometry;part)byTexture[texture]~=geometry;
        }
        return byTexture;
    }

    Vertex[][uint] buildChunk(const BlockTextureSet textures,
        ChunkCoordinate coordinate)
    {
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return null;
        return buildChunkRange(textures,coordinate,loaded.minimumOccupiedY(),
            loaded.maximumOccupiedY());
    }

    Vertex[][uint] buildChunkRange(const BlockTextureSet textures,
        ChunkCoordinate coordinate,int minimumY,int maximumY)
    {
        lighting.refresh();
        lighting.prepare(coordinate);
        Vertex[][uint] byTexture;
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return byTexture;
        if(minimumY<loaded.minimumOccupiedY())minimumY=loaded.minimumOccupiedY();
        if(maximumY>loaded.maximumOccupiedY())maximumY=loaded.maximumOccupiedY();
        foreach(faceValue;0..6)
        {
            const face=cast(Face)faceValue;
            final switch(face)
            {
                case Face.down,Face.up:
                    foreach(y;minimumY..maximumY+1)
                        buildGreedyPlane(byTexture,textures,coordinate,
                            face,y,Chunk.width,Chunk.depth,minimumY);
                    break;
                case Face.north,Face.south:
                    foreach(localZ;0..Chunk.depth)
                        buildGreedyPlane(byTexture,textures,coordinate,
                            face,localZ,Chunk.width,
                            maximumY-minimumY+1,minimumY);
                    break;
                case Face.west,Face.east:
                    foreach(localX;0..Chunk.width)
                        buildGreedyPlane(byTexture,textures,coordinate,
                            face,localX,Chunk.depth,
                            maximumY-minimumY+1,minimumY);
                    break;
            }
        }
        return byTexture;
    }

    Vertex[] buildPortals()
    {
        Vertex[] output;
        foreach (coordinate; world.loadedChunkCoordinates())
            output~=buildPortalsChunk(coordinate);
        return output;
    }

    Vertex[] buildPortalsChunk(ChunkCoordinate coordinate)
    {
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return null;
        return buildPortalsChunkRange(coordinate,loaded.minimumOccupiedY(),
            loaded.maximumOccupiedY());
    }

    Vertex[] buildPortalsChunkRange(ChunkCoordinate coordinate,int minimumY,
        int maximumY)
    {
        Vertex[] output;
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return output;
        if(minimumY<loaded.minimumOccupiedY())minimumY=loaded.minimumOccupiedY();
        if(maximumY>loaded.maximumOccupiedY())maximumY=loaded.maximumOccupiedY();
        foreach (y; minimumY .. maximumY+1)
        foreach (localZ; 0 .. Chunk.depth)
        foreach (localX; 0 .. Chunk.width)
        {
            const x=coordinate.x*Chunk.width+localX;
            const z=coordinate.z*Chunk.depth+localZ;
            const block = world.getBlock(x,y,z);
            if (block == BlockId.netherPortalX
                || block == BlockId.netherPortalZ)
                appendPortal(output,x,y,z,block==BlockId.netherPortalX);
        }
        return output;
    }

    WaterGeometry buildWater()
    {
        WaterGeometry result;
        foreach(coordinate;world.loadedChunkCoordinates())
        {
            const part=buildWaterChunk(coordinate);
            result.surface~=part.surface;
            result.walls~=part.walls;
            result.underside~=part.underside;
        }
        return result;
    }

    WaterGeometry buildWaterChunk(ChunkCoordinate coordinate)
    {
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return WaterGeometry.init;
        return buildWaterChunkRange(coordinate,loaded.minimumOccupiedY(),
            loaded.maximumOccupiedY());
    }

    WaterGeometry buildWaterChunkRange(ChunkCoordinate coordinate,int minimumY,
        int maximumY)
    {
        WaterGeometry result;
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return result;
        if(minimumY<loaded.minimumOccupiedY())minimumY=loaded.minimumOccupiedY();
        if(maximumY>loaded.maximumOccupiedY())maximumY=loaded.maximumOccupiedY();
        foreach(y;minimumY..maximumY+1)
        foreach(localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
        {
            const x=coordinate.x*Chunk.width+localX;
            const z=coordinate.z*Chunk.depth+localZ;
            const block=world.getBlock(x,y,z);
            if(!isWater(block))continue;
            const fullAbove=isWater(world.getBlock(x,y+1,z));
            const h00=fullAbove?1.0f:waterCornerHeight(x,y,z);
            const h10=fullAbove?1.0f:waterCornerHeight(x+1,y,z);
            const h11=fullAbove?1.0f:waterCornerHeight(x+1,y,z+1);
            const h01=fullAbove?1.0f:waterCornerHeight(x,y,z+1);

            // Build the horizontal sheet explicitly.  Besides making a
            // missing surface impossible to hide behind valid wall geometry,
            // this lets the renderer draw every top after every wall.
            const above=world.getBlock(x,y+1,z);
            if(!isWater(above)&&!isOpaque(above))
                appendWaterFace(result.surface,x,y,z,Face.up,h00,h10,h11,h01);

            foreach(faceValue;0..6)
            {
                const face=cast(Face)faceValue;
                if(face==Face.up)continue;
                const normal=faceNormal(face);
                const neighbor=world.getBlock(x+cast(int)normal.x,
                    y+cast(int)normal.y,z+cast(int)normal.z);
                if(isWater(neighbor)||isOpaque(neighbor))continue;
                if(face==Face.down)
                    appendWaterFace(result.underside,x,y,z,face,h00,h10,h11,h01);
                else
                    appendWaterFace(result.walls,x,y,z,face,h00,h10,h11,h01);
            }
        }
        return result;
    }

    FireGeometry buildFireChunkRange(ChunkCoordinate coordinate,int minimumY,
        int maximumY)
    {
        FireGeometry result;
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null||loaded.empty)return result;
        if(minimumY<loaded.minimumOccupiedY())minimumY=loaded.minimumOccupiedY();
        if(maximumY>loaded.maximumOccupiedY())maximumY=loaded.maximumOccupiedY();
        foreach(y;minimumY..maximumY+1)
        foreach(localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
        {
            const x=coordinate.x*Chunk.width+localX;
            const z=coordinate.z*Chunk.depth+localZ;
            if(!isFire(world.getBlock(x,y,z)))continue;
            appendFire(result,x,y,z);
        }
        return result;
    }

    /// Standalone six-faced block model used by dropped items and GUI icons.
    Vertex[][uint] buildItem(BlockId block, const BlockTextureSet textures)
    {
        Vertex[][uint] byTexture;
        foreach (faceValue; 0 .. 6)
        {
            const face = cast(Face) faceValue;
            const texture = textureFor(block, face, textures);
            auto geometry = texture in byTexture;
            if (geometry is null)
            {
                byTexture[texture] = [];
                geometry = texture in byTexture;
            }
            const tint = block == BlockId.grass && face == Face.up
                ? Color(0.55f, 0.82f, 0.35f, 1.0f)
                : Color(1, 1, 1, 1);
            appendBlockFace(*geometry, 0, 0, 0, face, tint, false);
        }
        return byTexture;
    }

    /// Builds the thin, pixel-extruded model used by Java's item/generated
    /// parent. The face remains recognisably a 2-D sprite, while exposed alpha
    /// edges receive the one-pixel-deep sides visible when the item turns.
    Vertex[][uint] buildGeneratedItem(uint texture, const ImageData image)
    {
        Vertex[][uint] result;
        Vertex[] geometry;
        if (image.width == 0 || image.height == 0
            || image.rgba.length < image.width * image.height * 4)
            return result;

        enum float frontZ = 7.5f / 16.0f;
        enum float backZ = 8.5f / 16.0f;
        const front = Color(1,1,1,1);
        const side = Color(0.82f,0.82f,0.82f,1);
        appendQuad(geometry,Vec3(0,0,frontZ),Vec3(1,0,frontZ),
            Vec3(1,1,frontZ),Vec3(0,1,frontZ),
            Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
            front,front,front,front);
        appendQuad(geometry,Vec3(1,0,backZ),Vec3(0,0,backZ),
            Vec3(0,1,backZ),Vec3(1,1,backZ),
            Vec2(1,1),Vec2(0,1),Vec2(0,0),Vec2(1,0),
            front,front,front,front);

        bool opaque(int x,int y) const
        {
            if(x<0||y<0||x>=cast(int)image.width
                ||y>=cast(int)image.height)return false;
            return image.rgba[(cast(size_t)y*image.width+x)*4+3]>0;
        }
        foreach(y;0..cast(int)image.height)
        foreach(x;0..cast(int)image.width)
        {
            if(!opaque(x,y))continue;
            const x0=cast(float)x/image.width;
            const x1=cast(float)(x+1)/image.width;
            const y0=1.0f-cast(float)(y+1)/image.height;
            const y1=1.0f-cast(float)y/image.height;
            const uv=Vec2((cast(float)x+0.5f)/image.width,
                (cast(float)y+0.5f)/image.height);
            if(!opaque(x-1,y))
                appendQuad(geometry,Vec3(x0,y0,backZ),Vec3(x0,y0,frontZ),
                    Vec3(x0,y1,frontZ),Vec3(x0,y1,backZ),uv,uv,uv,uv,
                    side,side,side,side);
            if(!opaque(x+1,y))
                appendQuad(geometry,Vec3(x1,y0,frontZ),Vec3(x1,y0,backZ),
                    Vec3(x1,y1,backZ),Vec3(x1,y1,frontZ),uv,uv,uv,uv,
                    side,side,side,side);
            if(!opaque(x,y-1))
                appendQuad(geometry,Vec3(x0,y1,frontZ),Vec3(x1,y1,frontZ),
                    Vec3(x1,y1,backZ),Vec3(x0,y1,backZ),uv,uv,uv,uv,
                    side,side,side,side);
            if(!opaque(x,y+1))
                appendQuad(geometry,Vec3(x0,y0,backZ),Vec3(x1,y0,backZ),
                    Vec3(x1,y0,frontZ),Vec3(x0,y0,frontZ),uv,uv,uv,uv,
                    side,side,side,side);
        }
        result[texture] = geometry;
        return result;
    }

    /// Java renders the selected destroy stage over the target block's model.
    /// Expand each face by a tiny amount to prevent depth fighting with the
    /// base block while retaining normal world-depth occlusion.
    Vertex[] buildDamageOverlay(int x, int y, int z)
    {
        Vertex[] output;
        enum float epsilon = 0.002f;
        foreach (faceValue; 0 .. 6)
        {
            const face = cast(Face) faceValue;
            const before = output.length;
            appendBlockFace(output, x, y, z, face, Color(1, 1, 1, 1));
            const normal = faceNormal(face) * epsilon;
            foreach (ref vertex; output[before .. $])
            {
                vertex.position[0] += normal.x;
                vertex.position[1] += normal.y;
                vertex.position[2] += normal.z;
                vertex.color = [1.0f, 1.0f, 1.0f, 1.0f];
            }
        }
        return output;
    }

    /// A slightly expanded twelve-edge box matching Java's targeted block
    /// shape. Thin geometry is used instead of API line primitives so its
    /// width and joins remain stable on every DirectX 12 driver.
    Vertex[] buildOutline(int x,int y,int z)
    {
        Vertex[] output;
        enum float expand=0.002f;
        enum float halfWidth=0.003f;
        const lo=Vec3(x-expand,y-expand,z-expand);
        const hi=Vec3(x+1+expand,y+1+expand,z+1+expand);
        foreach(yEdge;[lo.y,hi.y])foreach(zEdge;[lo.z,hi.z])
            appendLineBox(output,Vec3(lo.x,yEdge,zEdge),Vec3(hi.x,yEdge,zEdge),
                halfWidth);
        foreach(xEdge;[lo.x,hi.x])foreach(zEdge;[lo.z,hi.z])
            appendLineBox(output,Vec3(xEdge,lo.y,zEdge),Vec3(xEdge,hi.y,zEdge),
                halfWidth);
        foreach(xEdge;[lo.x,hi.x])foreach(yEdge;[lo.y,hi.y])
            appendLineBox(output,Vec3(xEdge,yEdge,lo.z),Vec3(xEdge,yEdge,hi.z),
                halfWidth);
        return output;
    }

private:
    struct GreedyFaceCell
    {
        bool visible;
        bool flat;
        uint texture;
        Color[4] colors;
    }

    void buildGreedyPlane(ref Vertex[][uint] byTexture,
        const BlockTextureSet textures,ChunkCoordinate coordinate,Face face,
        int fixed,int uCount,int vCount,int minimumY)
    {
        GreedyFaceCell[] mask;
        mask.length=cast(size_t)uCount*vCount;
        const baseX=coordinate.x*Chunk.width;
        const baseZ=coordinate.z*Chunk.depth;
        foreach(v;0..vCount)foreach(u;0..uCount)
        {
            int x,y,z;
            final switch(face)
            {
                case Face.down,Face.up:
                    x=baseX+u;y=fixed;z=baseZ+v;break;
                case Face.north,Face.south:
                    x=baseX+u;y=minimumY+v;z=baseZ+fixed;break;
                case Face.west,Face.east:
                    x=baseX+fixed;y=minimumY+v;z=baseZ+u;break;
            }
            const block=world.getBlock(x,y,z);
            if(block==BlockId.air||isWater(block)||isFire(block)
                ||block==BlockId.netherPortalX||block==BlockId.netherPortalZ)
                continue;
            const normal=faceNormal(face);
            const neighbor=world.getBlock(x+cast(int)normal.x,
                y+cast(int)normal.y,z+cast(int)normal.z);
            if(isOpaque(neighbor)
                ||(block==BlockId.glass&&neighbor==BlockId.glass))continue;
            ref cell=mask[cast(size_t)v*uCount+u];
            cell.visible=true;
            cell.texture=textureFor(block,face,textures);
            const tint=block==BlockId.grass&&face==Face.up
                ?Color(0.55f,0.82f,0.35f,1):Color(1,1,1,1);
            blockFaceColors(cell.colors,x,y,z,face,tint,true);
            cell.flat=equalColor(cell.colors[0],cell.colors[1])
                &&equalColor(cell.colors[0],cell.colors[2])
                &&equalColor(cell.colors[0],cell.colors[3]);
        }

        foreach(v;0..vCount)for(int u=0;u<uCount;)
        {
            ref first=mask[cast(size_t)v*uCount+u];
            if(!first.visible){++u;continue;}
            int spanU=1,spanV=1;
            if(first.flat)
            {
                while(u+spanU<uCount&&mergeCompatible(first,
                    mask[cast(size_t)v*uCount+u+spanU]))++spanU;
                bool extending=true;
                while(v+spanV<vCount&&extending)
                {
                    foreach(offset;0..spanU)
                        if(!mergeCompatible(first,mask[
                            cast(size_t)(v+spanV)*uCount+u+offset]))
                        {extending=false;break;}
                    if(extending)++spanV;
                }
            }
            foreach(dv;0..spanV)foreach(du;0..spanU)
                mask[cast(size_t)(v+dv)*uCount+u+du].visible=false;
            auto geometry=first.texture in byTexture;
            if(geometry is null)
            {
                byTexture[first.texture]=[];
                geometry=first.texture in byTexture;
            }
            if(spanU==1&&spanV==1&&!first.flat)
            {
                int x,y,z;
                final switch(face)
                {
                    case Face.down,Face.up:
                        x=baseX+u;y=fixed;z=baseZ+v;break;
                    case Face.north,Face.south:
                        x=baseX+u;y=minimumY+v;z=baseZ+fixed;break;
                    case Face.west,Face.east:
                        x=baseX+fixed;y=minimumY+v;z=baseZ+u;break;
                }
                appendFaceWithColors(*geometry,x,y,z,face,first.colors);
            }
            else appendMergedFace(*geometry,coordinate,face,fixed,u,v,
                spanU,spanV,minimumY,first.colors[0]);
            u+=spanU;
        }
    }

    static bool equalColor(Color a,Color b)
    {
        return a.r==b.r&&a.g==b.g&&a.b==b.b&&a.a==b.a;
    }

    static bool mergeCompatible(const GreedyFaceCell a,
        const GreedyFaceCell b)
    {
        return b.visible&&b.flat&&a.texture==b.texture
            &&equalColor(a.colors[0],b.colors[0]);
    }

    void appendMergedFace(ref Vertex[] output,ChunkCoordinate coordinate,
        Face face,int fixed,int u,int v,int spanU,int spanV,int minimumY,
        Color color)
    {
        const baseX=coordinate.x*Chunk.width;
        const baseZ=coordinate.z*Chunk.depth;
        Vec3 a,b,c,d;
        float repeatU,repeatV;
        final switch(face)
        {
            case Face.up:
            {
                const x=baseX+u,z=baseZ+v,y=fixed+1;
                a=Vec3(x,y,z);b=Vec3(x,y,z+spanV);
                c=Vec3(x+spanU,y,z+spanV);d=Vec3(x+spanU,y,z);
                repeatU=spanV;repeatV=spanU;break;
            }
            case Face.down:
            {
                const x=baseX+u,z=baseZ+v,y=fixed;
                a=Vec3(x,y,z+spanV);b=Vec3(x,y,z);
                c=Vec3(x+spanU,y,z);d=Vec3(x+spanU,y,z+spanV);
                repeatU=spanV;repeatV=spanU;break;
            }
            case Face.north:
            {
                const x=baseX+u,y=minimumY+v,z=baseZ+fixed;
                a=Vec3(x+spanU,y,z);b=Vec3(x,y,z);
                c=Vec3(x,y+spanV,z);d=Vec3(x+spanU,y+spanV,z);
                repeatU=spanU;repeatV=spanV;break;
            }
            case Face.south:
            {
                const x=baseX+u,y=minimumY+v,z=baseZ+fixed+1;
                a=Vec3(x,y,z);b=Vec3(x+spanU,y,z);
                c=Vec3(x+spanU,y+spanV,z);d=Vec3(x,y+spanV,z);
                repeatU=spanU;repeatV=spanV;break;
            }
            case Face.west:
            {
                const x=baseX+fixed,y=minimumY+v,z=baseZ+u;
                a=Vec3(x,y,z);b=Vec3(x,y,z+spanU);
                c=Vec3(x,y+spanV,z+spanU);d=Vec3(x,y+spanV,z);
                repeatU=spanU;repeatV=spanV;break;
            }
            case Face.east:
            {
                const x=baseX+fixed+1,y=minimumY+v,z=baseZ+u;
                a=Vec3(x,y,z+spanU);b=Vec3(x,y,z);
                c=Vec3(x,y+spanV,z);d=Vec3(x,y+spanV,z+spanU);
                repeatU=spanU;repeatV=spanV;break;
            }
        }
        appendQuad(output,a,b,c,d,Vec2(0,repeatV),
            Vec2(repeatU,repeatV),Vec2(repeatU,0),Vec2(0,0),
            color,color,color,color);
    }

    static void appendFaceWithColors(ref Vertex[] output,int x,int y,int z,
        Face face,Color[4] colors)
    {
        const fx=cast(float)x,fy=cast(float)y,fz=cast(float)z;
        Vec3[4] points;
        final switch(face)
        {
            case Face.up:points=[Vec3(fx,fy+1,fz),Vec3(fx,fy+1,fz+1),
                Vec3(fx+1,fy+1,fz+1),Vec3(fx+1,fy+1,fz)];break;
            case Face.down:points=[Vec3(fx,fy,fz+1),Vec3(fx,fy,fz),
                Vec3(fx+1,fy,fz),Vec3(fx+1,fy,fz+1)];break;
            case Face.north:points=[Vec3(fx+1,fy,fz),Vec3(fx,fy,fz),
                Vec3(fx,fy+1,fz),Vec3(fx+1,fy+1,fz)];break;
            case Face.south:points=[Vec3(fx,fy,fz+1),Vec3(fx+1,fy,fz+1),
                Vec3(fx+1,fy+1,fz+1),Vec3(fx,fy+1,fz+1)];break;
            case Face.west:points=[Vec3(fx,fy,fz),Vec3(fx,fy,fz+1),
                Vec3(fx,fy+1,fz+1),Vec3(fx,fy+1,fz)];break;
            case Face.east:points=[Vec3(fx+1,fy,fz+1),Vec3(fx+1,fy,fz),
                Vec3(fx+1,fy+1,fz),Vec3(fx+1,fy+1,fz+1)];break;
        }
        appendQuad(output,points[0],points[1],points[2],points[3],
            Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
            colors[0],colors[1],colors[2],colors[3]);
    }

    static void appendLineBox(ref Vertex[] output,Vec3 a,Vec3 b,float radius)
    {
        auto minimum=Vec3(a.x<b.x?a.x:b.x,a.y<b.y?a.y:b.y,a.z<b.z?a.z:b.z);
        auto maximum=Vec3(a.x>b.x?a.x:b.x,a.y>b.y?a.y:b.y,a.z>b.z?a.z:b.z);
        if(maximum.x-minimum.x>radius)
        {minimum.y-=radius;maximum.y+=radius;minimum.z-=radius;maximum.z+=radius;}
        else if(maximum.y-minimum.y>radius)
        {minimum.x-=radius;maximum.x+=radius;minimum.z-=radius;maximum.z+=radius;}
        else
        {minimum.x-=radius;maximum.x+=radius;minimum.y-=radius;maximum.y+=radius;}
        const c=Color(0,0,0,0.72f);
        const uv=Vec2(0,0);
        void face(Vec3 p0,Vec3 p1,Vec3 p2,Vec3 p3)
        {appendQuad(output,p0,p1,p2,p3,uv,uv,uv,uv,c,c,c,c);}
        face(Vec3(minimum.x,minimum.y,minimum.z),Vec3(maximum.x,minimum.y,minimum.z),
            Vec3(maximum.x,maximum.y,minimum.z),Vec3(minimum.x,maximum.y,minimum.z));
        face(Vec3(maximum.x,minimum.y,maximum.z),Vec3(minimum.x,minimum.y,maximum.z),
            Vec3(minimum.x,maximum.y,maximum.z),Vec3(maximum.x,maximum.y,maximum.z));
        face(Vec3(minimum.x,minimum.y,maximum.z),Vec3(minimum.x,minimum.y,minimum.z),
            Vec3(minimum.x,maximum.y,minimum.z),Vec3(minimum.x,maximum.y,maximum.z));
        face(Vec3(maximum.x,minimum.y,minimum.z),Vec3(maximum.x,minimum.y,maximum.z),
            Vec3(maximum.x,maximum.y,maximum.z),Vec3(maximum.x,maximum.y,minimum.z));
        face(Vec3(minimum.x,maximum.y,minimum.z),Vec3(maximum.x,maximum.y,minimum.z),
            Vec3(maximum.x,maximum.y,maximum.z),Vec3(minimum.x,maximum.y,maximum.z));
        face(Vec3(minimum.x,minimum.y,maximum.z),Vec3(maximum.x,minimum.y,maximum.z),
            Vec3(maximum.x,minimum.y,minimum.z),Vec3(minimum.x,minimum.y,minimum.z));
    }

    uint textureFor(BlockId block, Face face, const BlockTextureSet textures) const
    {
        final switch (block)
        {
            case BlockId.air: return textures.stone;
            case BlockId.grass:
                if (face == Face.up) return textures.grassTop;
                if (face == Face.down) return textures.dirt;
                return textures.grassSide;
            case BlockId.dirt: return textures.dirt;
            case BlockId.stone: return textures.stone;
            case BlockId.obsidian: return textures.obsidian;
            case BlockId.netherrack: return textures.netherrack;
            case BlockId.bedrock: return textures.bedrock;
            case BlockId.bricks: return textures.bricks;
            case BlockId.oakPlanks: return textures.oakPlanks;
            case BlockId.sprucePlanks: return textures.sprucePlanks;
            case BlockId.birchPlanks: return textures.birchPlanks;
            case BlockId.junglePlanks: return textures.junglePlanks;
            case BlockId.acaciaPlanks: return textures.acaciaPlanks;
            case BlockId.darkOakPlanks: return textures.darkOakPlanks;
            case BlockId.mangrovePlanks: return textures.mangrovePlanks;
            case BlockId.cherryPlanks: return textures.cherryPlanks;
            case BlockId.bambooPlanks: return textures.bambooPlanks;
            case BlockId.paleOakPlanks: return textures.paleOakPlanks;
            case BlockId.crimsonPlanks: return textures.crimsonPlanks;
            case BlockId.warpedPlanks: return textures.warpedPlanks;
            case BlockId.cobblestone: return textures.cobblestone;
            case BlockId.glass: return textures.glass;
            case BlockId.netherPortalX, BlockId.netherPortalZ:
                return textures.netherPortal;
            case BlockId.waterSource, BlockId.waterFlow1, BlockId.waterFlow2,
                 BlockId.waterFlow3, BlockId.waterFlow4, BlockId.waterFlow5,
                 BlockId.waterFlow6, BlockId.waterFlow7, BlockId.waterFalling:
                return textures.waterStill;
            case BlockId.fire: return textures.stone;
        }
    }

    static void appendFire(ref FireGeometry result,int x,int y,int z)
    {
        const color=Color(1,1,1,1);
        const fx=cast(float)x,fy=cast(float)y,fz=cast(float)z;
        enum float floorLow=0.057f;
        enum float floorHigh=1.351f;
        enum float sideHigh=1.4f;

        void flame(ref Vertex[] output,Vec3 a,Vec3 b,Vec3 c,Vec3 d,
            bool mirror=false)
        {
            appendQuad(output,a,b,c,d,
                mirror?Vec2(1,1):Vec2(0,1),mirror?Vec2(0,1):Vec2(1,1),
                mirror?Vec2(0,0):Vec2(1,0),mirror?Vec2(1,0):Vec2(0,0),
                color,color,color,color);
        }

        // Faithfully reproduce Java's template_fire_floor shape: four
        // full-width sheets tilted 22.5 degrees around the block centre. The
        // previous pair of narrow diagonal cards resembled a campfire flame.
        flame(result.layer0,Vec3(fx,fy+floorLow,fz+0.738f),
            Vec3(fx+1,fy+floorLow,fz+0.738f),
            Vec3(fx+1,fy+floorHigh,fz+0.202f),
            Vec3(fx,fy+floorHigh,fz+0.202f));
        flame(result.layer1,Vec3(fx+1,fy+floorLow,fz+0.263f),
            Vec3(fx,fy+floorLow,fz+0.263f),
            Vec3(fx,fy+floorHigh,fz+0.798f),
            Vec3(fx+1,fy+floorHigh,fz+0.798f),true);
        flame(result.layer0,Vec3(fx+0.355f,fy+0.019f,fz+1),
            Vec3(fx+0.355f,fy+0.019f,fz),
            Vec3(fx+0.891f,fy+1.313f,fz),
            Vec3(fx+0.891f,fy+1.313f,fz+1),true);
        flame(result.layer1,Vec3(fx+0.645f,fy+0.019f,fz),
            Vec3(fx+0.645f,fy+0.019f,fz+1),
            Vec3(fx+0.109f,fy+1.313f,fz+1),
            Vec3(fx+0.109f,fy+1.313f,fz));

        // An unsupported floor fire also receives Java's four cardinal side
        // variants. Alternating fire_0/fire_1 keeps the authentic animation
        // variation without introducing a separate per-block model system.
        enum float edge=0.01f;
        flame(result.layer0,Vec3(fx,fy,fz+edge),Vec3(fx+1,fy,fz+edge),
            Vec3(fx+1,fy+sideHigh,fz+edge),Vec3(fx,fy+sideHigh,fz+edge));
        flame(result.layer1,Vec3(fx+1,fy,fz+1-edge),
            Vec3(fx,fy,fz+1-edge),Vec3(fx,fy+sideHigh,fz+1-edge),
            Vec3(fx+1,fy+sideHigh,fz+1-edge),true);
        flame(result.layer0,Vec3(fx+edge,fy,fz+1),Vec3(fx+edge,fy,fz),
            Vec3(fx+edge,fy+sideHigh,fz),Vec3(fx+edge,fy+sideHigh,fz+1),true);
        flame(result.layer1,Vec3(fx+1-edge,fy,fz),
            Vec3(fx+1-edge,fy,fz+1),Vec3(fx+1-edge,fy+sideHigh,fz+1),
            Vec3(fx+1-edge,fy+sideHigh,fz));
    }

    float waterCornerHeight(int cornerX,int y,int cornerZ) const
    {
        // D initializes an unassigned float to NaN.  Starting this accumulator
        // without an explicit zero made every exposed water-top Y coordinate
        // NaN, so the GPU discarded all horizontal triangles while the walls
        // (whose bottom vertices use integer Y) remained partially visible.
        float total=0.0f;
        int weight=0;
        foreach(dz;-1..1)foreach(dx;-1..1)
        {
            const x=cornerX+dx,z=cornerZ+dz;
            if(isWater(world.getBlock(x,y+1,z)))return 1.0f;
            const block=world.getBlock(x,y,z);
            if(!isWater(block))continue;
            const height=waterHeight(block);
            const contribution=height>=8.0f/9.0f?10:1;
            total+=height*contribution;
            weight+=contribution;
        }
        return weight?total/weight:0.0f;
    }

    void appendWaterFace(ref Vertex[] output,int x,int y,int z,Face face,
        float h00,float h10,float h11,float h01)
    {
        // The imported water sprite already carries Java's 180/255 alpha.
        // Multiplying another .72 vertex alpha made the final surface only
        // ~51% opaque and effectively erased it over bright terrain.
        const normal=faceNormal(face);
        const light=faceShade(face)*lighting.brightnessAt(
            x+cast(int)normal.x,y+cast(int)normal.y,z+cast(int)normal.z);
        const tint=Color(0.247f*light,0.463f*light,0.894f*light,1.0f);
        const bottom=cast(float)y;
        Vec3 a,b,c,d;
        final switch(face)
        {
            case Face.down: a=Vec3(x,y,z+1);b=Vec3(x+1,y,z+1);
                c=Vec3(x+1,y,z);d=Vec3(x,y,z);break;
            // Counter-clockwise from above: the geometric normal points up.
            // The translucent pipeline disables culling, so this same sheet
            // remains visible from underwater without a coplanar duplicate
            // that would blend twice.
            case Face.up: a=Vec3(x,y+h00,z);b=Vec3(x,y+h01,z+1);
                c=Vec3(x+1,y+h11,z+1);d=Vec3(x+1,y+h10,z);break;
            case Face.north:a=Vec3(x+1,bottom,z);b=Vec3(x,bottom,z);
                c=Vec3(x,y+h00,z);d=Vec3(x+1,y+h10,z);break;
            case Face.south:a=Vec3(x,bottom,z+1);b=Vec3(x+1,bottom,z+1);
                c=Vec3(x+1,y+h11,z+1);d=Vec3(x,y+h01,z+1);break;
            case Face.west:a=Vec3(x,bottom,z);b=Vec3(x,bottom,z+1);
                c=Vec3(x,y+h01,z+1);d=Vec3(x,y+h00,z);break;
            case Face.east:a=Vec3(x+1,bottom,z+1);b=Vec3(x+1,bottom,z);
                c=Vec3(x+1,y+h10,z);d=Vec3(x+1,y+h11,z+1);break;
        }
        appendQuad(output,a,b,c,d,Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
            tint,tint,tint,tint);
    }

    void appendPortal(ref Vertex[] output, int x, int y, int z, bool axisX)
    {
        const amount=lighting.brightnessAt(x,y,z);
        const color = Color(amount,amount,amount,0.78f);
        const inset = 6.0f / 16.0f;
        const farInset = 10.0f / 16.0f;
        if (axisX)
        {
            appendQuad(output, Vec3(x,y,z+inset), Vec3(x+1,y,z+inset),
                Vec3(x+1,y+1,z+inset), Vec3(x,y+1,z+inset),
                Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                color,color,color,color);
            appendQuad(output, Vec3(x+1,y,z+farInset), Vec3(x,y,z+farInset),
                Vec3(x,y+1,z+farInset), Vec3(x+1,y+1,z+farInset),
                Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                color,color,color,color);
        }
        else
        {
            appendQuad(output, Vec3(x+inset,y,z+1), Vec3(x+inset,y,z),
                Vec3(x+inset,y+1,z), Vec3(x+inset,y+1,z+1),
                Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                color,color,color,color);
            appendQuad(output, Vec3(x+farInset,y,z), Vec3(x+farInset,y,z+1),
                Vec3(x+farInset,y+1,z+1), Vec3(x+farInset,y+1,z),
                Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                color,color,color,color);
        }
    }

    Vec3 faceNormal(Face face) const
    {
        final switch (face)
        {
            case Face.down: return Vec3(0, -1, 0);
            case Face.up: return Vec3(0, 1, 0);
            case Face.north: return Vec3(0, 0, -1);
            case Face.south: return Vec3(0, 0, 1);
            case Face.west: return Vec3(-1, 0, 0);
            case Face.east: return Vec3(1, 0, 0);
        }
    }

    float faceShade(Face face) const
    {
        // Java Edition's CardinalLighting.DEFAULT values.
        float base;
        final switch (face)
        {
            case Face.down: base=0.5f;break;
            case Face.up: base=1.0f;break;
            case Face.north, Face.south: base=0.8f;break;
            case Face.west, Face.east: base=0.6f;break;
        }
        return base;
    }

    float vertexAo(int x, int y, int z, Face face, int uSign, int vSign) const
    {
        if(!smoothLighting)return 1.0f;
        const normal = faceNormal(face);
        Vec3 tangentU;
        Vec3 tangentV;
        final switch (face)
        {
            case Face.down, Face.up:
                tangentU = Vec3(1, 0, 0); tangentV = Vec3(0, 0, 1); break;
            case Face.north, Face.south:
                tangentU = Vec3(1, 0, 0); tangentV = Vec3(0, 1, 0); break;
            case Face.west, Face.east:
                tangentU = Vec3(0, 0, 1); tangentV = Vec3(0, 1, 0); break;
        }

        bool occupied(Vec3 offset)
        {
            return isOpaque(world.getBlock(
                x + cast(int) offset.x,
                y + cast(int) offset.y,
                z + cast(int) offset.z,
            ));
        }

        const sideU = occupied(normal + tangentU * cast(float) uSign);
        const sideV = occupied(normal + tangentV * cast(float) vSign);
        const corner = occupied(normal + tangentU * cast(float) uSign + tangentV * cast(float) vSign);
        const occlusion = sideU && sideV ? 3 : cast(int) sideU + cast(int) sideV + cast(int) corner;
        immutable float[4] ao = [1.0f, 0.8f, 0.6f, 0.5f];
        return ao[occlusion];
    }

    void appendBlockFace(ref Vertex[] output, int x, int y, int z, Face face,
        Color tint, bool sampleWorldLight = true)
    {
        const fx = cast(float) x;
        const fy = cast(float) y;
        const fz = cast(float) z;
        Vec3[4] points;

        final switch (face)
        {
            case Face.up:
                points = [Vec3(fx,fy+1,fz), Vec3(fx,fy+1,fz+1), Vec3(fx+1,fy+1,fz+1), Vec3(fx+1,fy+1,fz)];
                break;
            case Face.down:
                points = [Vec3(fx,fy,fz+1), Vec3(fx,fy,fz), Vec3(fx+1,fy,fz), Vec3(fx+1,fy,fz+1)];
                break;
            case Face.north:
                points = [Vec3(fx+1,fy,fz), Vec3(fx,fy,fz), Vec3(fx,fy+1,fz), Vec3(fx+1,fy+1,fz)];
                break;
            case Face.south:
                points = [Vec3(fx,fy,fz+1), Vec3(fx+1,fy,fz+1), Vec3(fx+1,fy+1,fz+1), Vec3(fx,fy+1,fz+1)];
                break;
            case Face.west:
                points = [Vec3(fx,fy,fz), Vec3(fx,fy,fz+1), Vec3(fx,fy+1,fz+1), Vec3(fx,fy+1,fz)];
                break;
            case Face.east:
                points = [Vec3(fx+1,fy,fz+1), Vec3(fx+1,fy,fz), Vec3(fx+1,fy+1,fz), Vec3(fx+1,fy+1,fz+1)];
                break;
        }

        Color[4] colors;
        blockFaceColors(colors,x,y,z,face,tint,sampleWorldLight);
        appendQuad(
            output,
            points[0], points[1], points[2], points[3],
            Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
            colors[0], colors[1], colors[2], colors[3],
        );
    }

    void blockFaceColors(ref Color[4] colors,int x,int y,int z,Face face,
        Color tint,bool sampleWorldLight)
    {
        int[4] uSigns;
        int[4] vSigns;
        final switch(face)
        {
            case Face.up:
                uSigns=[-1,-1,1,1];vSigns=[-1,1,1,-1];break;
            case Face.down:
                uSigns=[-1,-1,1,1];vSigns=[1,-1,-1,1];break;
            case Face.north:
                uSigns=[1,-1,-1,1];vSigns=[-1,-1,1,1];break;
            case Face.south,Face.west:
                uSigns=[-1,1,1,-1];vSigns=[-1,-1,1,1];break;
            case Face.east:
                uSigns=[1,-1,-1,1];vSigns=[-1,-1,1,1];break;
        }
        const normal=faceNormal(face);
        const worldLight=sampleWorldLight ? lighting.brightnessAt(
            x+cast(int)normal.x,y+cast(int)normal.y,z+cast(int)normal.z) : 1.0f;
        foreach (i; 0 .. 4)
        {
            const amount = faceShade(face) * worldLight
                * vertexAo(x, y, z, face, uSigns[i], vSigns[i]);
            colors[i] = Color(tint.r * amount, tint.g * amount, tint.b * amount, tint.a);
        }
    }
}
