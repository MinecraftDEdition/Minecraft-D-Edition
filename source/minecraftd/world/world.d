module minecraftd.world.world;

import core.stdc.math : cosf, fabsf, floorf, sinf;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : Vec3;
import minecraftd.world.block : BlockId, isFire, isFlammable, isOpaque, isSolid,
    isWater, isWaterSource, waterForLevel, waterHeight, waterLevel;
import minecraftd.world.chunk : Chunk, ChunkCoordinate, chunkCoordinate,
    localCoordinate;
import minecraftd.world.world_settings : WorldSettings, WorldType,
    DimensionId, loadWorldMetadata, saveWorldMetadata;

alias GenerationProgress = void delegate(int percent);

struct CollisionResult
{
    Vec3 movement;
    bool hitX;
    bool hitY;
    bool hitZ;
}

unittest
{
    // Transparent blocks still have full collision shapes. This specifically
    // guards the old isOpaque/isSolid mix-up that made glass intangible.
    auto collisionWorld=new World();
    scope(exit)destroy(collisionWorld);
    collisionWorld.setBlock(30,1,30,BlockId.glass);
    const beside=Aabb(29.2f,1.0f,30.2f,29.8f,2.8f,30.8f);
    const glassHit=collisionWorld.collide(beside,Vec3(1.5f,0,0));
    assert(glassHit.hitX);
    assert(glassHit.movement.x>0.1999f&&glassHit.movement.x<0.2001f);

    // Sweeping diagonally into a corner may slide along either face, but the
    // resulting box must never overlap the solid block or tunnel through it.
    const diagonal=Aabb(29.2f,1.0f,29.2f,29.8f,2.8f,29.8f);
    const cornerHit=collisionWorld.collide(diagonal,Vec3(0.6f,0,0.6f));
    assert(!diagonal.moved(cornerHit.movement).intersects(
        Aabb(30,1,30,31,2,31)));
    assert(cornerHit.hitX||cornerHit.hitZ);
}

unittest
{
    auto testWorld=new World();
    foreach(y;25..Chunk.height)foreach(z;28..33)foreach(x;28..33)
        testWorld.setBlock(x,y,z,BlockId.air);
    testWorld.setBlock(30,29,30,BlockId.waterSource);
    const changes=testWorld.tickWater();
    assert(changes.length>0);
    assert(testWorld.getBlock(30,28,30)==BlockId.waterFalling);
    assert(testWorld.getBlock(31,29,30)==BlockId.waterFlow1);
    assert(testWorld.waterFlowAt(Vec3(31.5f,29.2f,30.5f)).x>0.5f);
    assert(testWorld.isPointInWater(Vec3(30.5f,29.8f,30.5f)));
    assert(!testWorld.isPointInWater(Vec3(30.5f,29.95f,30.5f)));
    const ray=testWorld.rayCast(Vec3(30.5f,29.5f,28.0f),Vec3(0,0,1),4.0f);
    assert(!ray.hit); // selection rays pass through fluid blocks
    // Placement rays treat fluid exactly like air regardless of eye height.
    // A block placed from above replaces the shallow water cell immediately
    // above the solid support instead of being incorrectly perched on water.
    testWorld.setBlock(30,28,30,BlockId.stone);
    const surfacePlacement=testWorld.rayCastForPlacement(
        Vec3(30.5f,31.0f,30.5f),Vec3(0,-1,0),4.0f);
    assert(surfacePlacement.hit&&surfacePlacement.block==BlockId.stone);
    assert(surfacePlacement.placeY==29);
    testWorld.setBlock(30,29,31,BlockId.stone);
    const submergedPlacement=testWorld.rayCastForPlacement(
        Vec3(30.5f,29.4f,30.2f),Vec3(0,0,1),3.0f);
    assert(submergedPlacement.hit&&submergedPlacement.block==BlockId.stone);
    assert(submergedPlacement.placeZ==30); // replace the intervening fluid

    testWorld.setBlock(20,1,20,BlockId.netherrack);
    assert(testWorld.canPlaceFire(20,2,20));
    testWorld.setBlock(20,2,20,BlockId.fire);
    assert(testWorld.intersectsFire(Aabb(19.8f,2,19.8f,20.2f,3,20.2f)));
    const center=[Vec3(20.5f,2,20.5f)];
    testWorld.tickFireAround(center,1,30);
    assert(testWorld.getBlock(20,2,20)==BlockId.fire); // eternal support
}

unittest
{
    // Streaming is center-first and resident chunks can be explicitly evicted.
    auto streamingWorld=new World();
    scope(exit)destroy(streamingWorld);
    const before=streamingWorld.loadedChunkCoordinates().length;
    const generated=streamingWorld.ensureChunksAround(Vec3(160.5f,70,160.5f),
        3,2);
    assert(generated.length==2);
    assert(generated[0]==ChunkCoordinate(10,10));
    assert(streamingWorld.loadedChunkCoordinates().length==before+2);
    assert(streamingWorld.unloadChunk(10,10));
    assert(!streamingWorld.hasChunk(10,10));
    assert(streamingWorld.loadedChunkCoordinates().length==before+1);
}

struct BlockHit
{
    bool hit;
    int x;
    int y;
    int z;
    BlockId block;
    float distance;
    int placeX;
    int placeY;
    int placeZ;
}

struct WaterUpdate
{
    int x, y, z;
    BlockId oldBlock;
    BlockId newBlock;
}

private struct BlockPosition
{
    int x, y, z;
}

private struct WaterChunkCache
{
    uint revision;
    BlockPosition[] cells;
}

private struct FireChunkCache
{
    uint revision;
    BlockPosition[] cells;
}

final class World
{
    enum int overworldMinimumY = -64;
    enum int overworldMaximumY = 319;
    enum int netherMinimumY = 0;
    enum int netherMaximumY = 255;
    enum int overworldBorder = 29_999_984;
    enum int netherBorder = 3_749_998;
    enum int initialChunkRadius = 1;

    /// Kept as a compatibility view of chunk (0,0) for small mechanics tests.
    Chunk chunk;
    private Chunk[ChunkCoordinate] chunks;
    private uint[ChunkCoordinate] chunkRevisions;
    private bool[ChunkCoordinate] dirtyChunks;
    private WaterChunkCache[ChunkCoordinate] waterCache;
    private FireChunkCache[ChunkCoordinate] fireCache;
    uint revision;
    uint contentRevision;
    WorldSettings settings;
    string saveDirectory;
    DimensionId dimension = DimensionId.overworld;

    this()
    {
        foreach (chunkZ; 0 .. 2)
        foreach (chunkX; 0 .. 2)
            addChunk(new Chunk(chunkX, chunkZ));
        settings.spawn = Vec3(8.0f,1.0f,3.0f);
        foreach (z; 0 .. Chunk.depth * 2)
        foreach (x; 0 .. Chunk.width * 2)
        {
            setRawBlock(x, 0, z, BlockId.grass);
        }

        // Small shapes deliberately create visible AO corners and directional shading.
        foreach (x; 5 .. 9)
        foreach (z; 6 .. 10)
            setRawBlock(x, 1, z, BlockId.stone);
        setRawBlock(6, 2, 7, BlockId.stone);
        setRawBlock(7, 2, 7, BlockId.stone);
        setRawBlock(7, 2, 8, BlockId.dirt);
        setRawBlock(11, 1, 11, BlockId.grass);
        setRawBlock(11, 2, 11, BlockId.grass);
    }

    this(WorldSettings requested, string directory,
        GenerationProgress progress = null)
    {
        initialize(requested, directory, DimensionId.overworld, progress);
    }

    this(WorldSettings requested, string directory, DimensionId requestedDimension,
        GenerationProgress progress = null)
    {
        initialize(requested, directory, requestedDimension, progress);
    }

    ~this()
    {
        foreach (loaded; chunks) destroy(loaded);
        chunks.clear();
        chunk = null;
    }

private:
    void initialize(WorldSettings requested, string directory,
        DimensionId requestedDimension, GenerationProgress progress)
    {
        settings = requested;
        saveDirectory = directory;
        dimension = requestedDimension;
        const firstChunkPath = chunkPath(0, 0);
        if (exists(firstChunkPath))
        {
            if (progress !is null) progress(5);
            settings = loadWorldMetadata(directory);
            foreach (chunkZ; -initialChunkRadius .. initialChunkRadius + 1)
            foreach (chunkX; -initialChunkRadius .. initialChunkRadius + 1)
                loadOrGenerateChunk(chunkX, chunkZ);
            if (progress !is null) progress(100);
        }
        else
        {
            // The old monolithic blocks.dat is intentionally left untouched.
            // Its 64x32 layout cannot encode negative Y or chunk coordinates;
            // generating the new format beside it avoids corrupting that data.
            generateForDimension(progress);
            save();
        }
    }

    void generateForDimension(GenerationProgress progress)
    {
        if (dimension == DimensionId.nether)
            generateNether(progress);
        else
            generate(progress);
    }

public:

    void addWaterToLegacyTerrain()
    {
        // Legacy finite worlds are no longer mutated in place. New chunk
        // terrain always receives oceans and rivers during generation.
    }

    void save()
    {
        if (!saveDirectory.length || chunks.length == 0)
            return;
        saveWorldMetadata(saveDirectory, settings);
        mkdirRecurse(buildPath(saveDirectory, "chunks"));
        foreach (coordinate, loaded; chunks)
            write(chunkPath(coordinate.x, coordinate.z), loaded.snapshot());
        dirtyChunks.clear();
    }

    void saveDirtyChunks()
    {
        if(!saveDirectory.length||!dirtyChunks.length)return;
        saveWorldMetadata(saveDirectory,settings);
        mkdirRecurse(buildPath(saveDirectory,"chunks"));
        foreach(coordinate,dirty;dirtyChunks)
            if(auto loaded=coordinate in chunks)
                write(chunkPath(coordinate.x,coordinate.z),(*loaded).snapshot());
        dirtyChunks.clear();
    }

    void generate(GenerationProgress progress = null)
    {
        if (progress !is null) progress(0);
        clearChunks();
        int generated;
        const total = (initialChunkRadius * 2 + 1)
            * (initialChunkRadius * 2 + 1);
        foreach (chunkZ; -initialChunkRadius .. initialChunkRadius + 1)
        foreach (chunkX; -initialChunkRadius .. initialChunkRadius + 1)
        {
            ensureChunk(chunkX, chunkZ);
            if (progress !is null)
                progress(5 + ++generated * 85 / total);
        }
        settings.spawn = chooseSpawn();
        clearSpawn(settings.spawn);
        ++revision;
        if (progress !is null) progress(100);
    }

    void generateNether(GenerationProgress progress = null)
    {
        if (progress !is null) progress(0);
        clearChunks();
        int generated;
        const total = (initialChunkRadius * 2 + 1)
            * (initialChunkRadius * 2 + 1);
        foreach (chunkZ; -initialChunkRadius .. initialChunkRadius + 1)
        foreach (chunkX; -initialChunkRadius .. initialChunkRadius + 1)
        {
            ensureChunk(chunkX, chunkZ);
            if (progress !is null)
                progress(5 + ++generated * 85 / total);
        }
        settings.spawn = chooseNetherSpawn();
        ++revision;
        if (progress !is null) progress(100);
    }

    int minimumBuildY() const
    {
        return dimension == DimensionId.overworld
            ? overworldMinimumY : netherMinimumY;
    }

    int maximumBuildY() const
    {
        return dimension == DimensionId.overworld
            ? overworldMaximumY : netherMaximumY;
    }

    int voidDamageY() const { return minimumBuildY() - 64; }

    int horizontalBorder() const
    {
        return dimension == DimensionId.overworld
            ? overworldBorder : netherBorder;
    }

    bool withinHorizontalBorder(int x, int z) const
    {
        const limit = horizontalBorder();
        return x >= -limit && x <= limit && z >= -limit && z <= limit;
    }

    ChunkCoordinate[] loadedChunkCoordinates() const
    {
        ChunkCoordinate[] result;
        result.reserve(chunks.length);
        foreach (coordinate, loaded; chunks) result ~= coordinate;
        return result;
    }

    uint chunkRevision(int chunkX, int chunkZ) const
    {
        auto found = ChunkCoordinate(chunkX, chunkZ) in chunkRevisions;
        return found is null ? 0 : *found;
    }

    bool hasChunk(int chunkX, int chunkZ) const
    {
        return (ChunkCoordinate(chunkX, chunkZ) in chunks) !is null;
    }

    /// Builds or restores a chunk without publishing it into the live world.
    /// Integrated servers use this on terrain workers so expensive noise and
    /// disk reads never hold up the authoritative 20 Hz simulation loop.
    Chunk buildDetachedChunk(int chunkX,int chunkZ)
    {
        auto generated=new Chunk(chunkX,chunkZ);
        const path=chunkPath(chunkX,chunkZ);
        if(path.length&&exists(path)
            &&generated.restore(cast(const(ubyte)[])read(path)))
            return generated;
        if(dimension==DimensionId.nether)generateNetherChunk(generated);
        else generateOverworldChunk(generated);
        return generated;
    }

    /// Publishes a worker-built chunk on the world's owning thread. Returns
    /// false when another request installed the same coordinate first.
    bool installDetachedChunk(Chunk generated)
    {
        if(generated is null)return false;
        const coordinate=ChunkCoordinate(generated.chunkX,generated.chunkZ);
        if(coordinate in chunks)return false;
        addChunk(generated);
        ++revision;
        return true;
    }

    const(Chunk) chunkAt(int chunkX, int chunkZ) const
    {
        auto found = ChunkCoordinate(chunkX, chunkZ) in chunks;
        return found is null ? null : *found;
    }

    void clearChunks()
    {
        foreach (loaded; chunks) destroy(loaded);
        chunks.clear();
        chunkRevisions.clear();
        dirtyChunks.clear();
        waterCache.clear();
        fireCache.clear();
        chunk = null;
        ++revision;
    }

    bool installChunk(int chunkX, int chunkZ, const(ubyte)[] data)
    {
        auto replacement = new Chunk(chunkX, chunkZ);
        if (!replacement.restore(data))
        {
            destroy(replacement);
            return false;
        }
        const coordinate = ChunkCoordinate(chunkX, chunkZ);
        if (auto old = coordinate in chunks) destroy(*old);
        chunks[coordinate] = replacement;
        if (chunkX == 0 && chunkZ == 0) chunk = replacement;
        markChunkAndNeighborsDirty(coordinate);
        ++revision;
        return true;
    }

    /// Removes one resident chunk. Servers persist it first; clients use the
    /// same operation for authoritative unload packets without touching disk.
    bool unloadChunk(int chunkX, int chunkZ, bool persist = false)
    {
        const coordinate = ChunkCoordinate(chunkX, chunkZ);
        auto loaded = coordinate in chunks;
        if (loaded is null) return false;
        if (persist && saveDirectory.length)
        {
            mkdirRecurse(buildPath(saveDirectory, "chunks"));
            write(chunkPath(chunkX, chunkZ), (*loaded).snapshot());
        }
        destroy(*loaded);
        chunks.remove(coordinate);
        chunkRevisions.remove(coordinate);
        dirtyChunks.remove(coordinate);
        waterCache.remove(coordinate);
        fireCache.remove(coordinate);
        if (chunkX == 0 && chunkZ == 0) chunk = null;
        markChunkAndNeighborsDirty(coordinate);
        ++revision;
        return true;
    }

    ChunkCoordinate[] ensureChunksAround(Vec3 position, int radius = 2,
        int maximumNewChunks = 2)
    {
        ChunkCoordinate[] generated;
        const centerX = chunkCoordinate(cast(int)floorf(position.x));
        const centerZ = chunkCoordinate(cast(int)floorf(position.z));
        // Center-out rings ensure terrain in front of the player becomes
        // available before distant corners instead of scanning one back edge.
        foreach (ring; 0 .. radius + 1)
        foreach (chunkZ; centerZ - ring .. centerZ + ring + 1)
        foreach (chunkX; centerX - ring .. centerX + ring + 1)
        {
            int dx=chunkX-centerX;if(dx<0)dx=-dx;
            int dz=chunkZ-centerZ;if(dz<0)dz=-dz;
            if((dx>dz?dx:dz)!=ring)continue;
            const blockX = chunkX * Chunk.width;
            const blockZ = chunkZ * Chunk.depth;
            if (!withinHorizontalBorder(blockX, blockZ)
                || !withinHorizontalBorder(blockX+Chunk.width-1,
                    blockZ+Chunk.depth-1)) continue;
            const coordinate = ChunkCoordinate(chunkX, chunkZ);
            if (coordinate in chunks) continue;
            ensureChunk(chunkX, chunkZ);
            generated ~= coordinate;
            if(maximumNewChunks>0&&generated.length>=maximumNewChunks)
                return generated;
        }
        return generated;
    }

    BlockId getBlock(int x, int y, int z) const
    {
        if (y < minimumBuildY() || y > maximumBuildY()
            || !withinHorizontalBorder(x,z)) return BlockId.air;
        auto loaded = ChunkCoordinate(chunkCoordinate(x),chunkCoordinate(z))
            in chunks;
        return loaded is null ? BlockId.air
            : (*loaded).get(localCoordinate(x),y,localCoordinate(z));
    }

    bool inBounds(int x, int y, int z) const
    {
        return y >= minimumBuildY() && y <= maximumBuildY()
            && withinHorizontalBorder(x,z);
    }

    void setBlock(int x, int y, int z, BlockId block)
    {
        if (!inBounds(x, y, z))
            return;
        const coordinate=ChunkCoordinate(chunkCoordinate(x),chunkCoordinate(z));
        auto loaded=coordinate in chunks;
        if(loaded is null)
        {
            ensureChunk(coordinate.x,coordinate.z);
            loaded=coordinate in chunks;
        }
        if ((*loaded).get(localCoordinate(x),y,localCoordinate(z)) == block)
            return;
        (*loaded).set(localCoordinate(x),y,localCoordinate(z),block);
        dirtyChunks[coordinate]=true;
        markBlockDirty(coordinate,localCoordinate(x),localCoordinate(z));
        ++contentRevision;
        ++revision;
    }

    /// Forces render/collision consumers to rebuild after a complete network
    /// snapshot, including when every received block equals the bootstrap map.
    void markDirty()
    {
        foreach (coordinate, loaded; chunks)
            chunkRevisions[coordinate] = chunkRevisions[coordinate] + 1;
        ++revision;
    }

    BlockHit rayCast(Vec3 origin, Vec3 direction, float maximumDistance = 5.0f) const
    {
        direction = direction.normalized();
        int x = cast(int) floorf(origin.x);
        int y = cast(int) floorf(origin.y);
        int z = cast(int) floorf(origin.z);
        const stepX = direction.x > 0 ? 1 : (direction.x < 0 ? -1 : 0);
        const stepY = direction.y > 0 ? 1 : (direction.y < 0 ? -1 : 0);
        const stepZ = direction.z > 0 ? 1 : (direction.z < 0 ? -1 : 0);
        enum float infinity = float.max;
        const deltaX = stepX == 0 ? infinity : fabsf(1.0f / direction.x);
        const deltaY = stepY == 0 ? infinity : fabsf(1.0f / direction.y);
        const deltaZ = stepZ == 0 ? infinity : fabsf(1.0f / direction.z);
        float nextX = stepX > 0 ? (x + 1.0f-origin.x) * deltaX
            : (stepX < 0 ? (origin.x-x) * deltaX : infinity);
        float nextY = stepY > 0 ? (y + 1.0f-origin.y) * deltaY
            : (stepY < 0 ? (origin.y-y) * deltaY : infinity);
        float nextZ = stepZ > 0 ? (z + 1.0f-origin.z) * deltaZ
            : (stepZ < 0 ? (origin.z-z) * deltaZ : infinity);
        float distance = 0.0f;
        int previousX = x;
        int previousY = y;
        int previousZ = z;

        foreach (_; 0 .. 256)
        {
            const block = getBlock(x, y, z);
            if (block != BlockId.air && !isWater(block))
                return BlockHit(true, x, y, z, block, distance,
                    previousX, previousY, previousZ);
            previousX = x;
            previousY = y;
            previousZ = z;
            if (nextX <= nextY && nextX <= nextZ)
            {
                distance = nextX; nextX += deltaX; x += stepX;
            }
            else if (nextY <= nextZ)
            {
                distance = nextY; nextY += deltaY; y += stepY;
            }
            else
            {
                distance = nextZ; nextZ += deltaZ; z += stepZ;
            }
            if (distance > maximumDistance)
                break;
        }
        return BlockHit.init;
    }

    /// Fluids are replaceable placement space, just like air. The ray always
    /// continues to the first solid support and reports the last traversed
    /// cell as the destination, independent of whether the eye began above or
    /// below the water surface.
    BlockHit rayCastForPlacement(Vec3 origin, Vec3 direction,
        float maximumDistance = 5.0f) const
    {
        direction = direction.normalized();
        int x=cast(int)floorf(origin.x), y=cast(int)floorf(origin.y),
            z=cast(int)floorf(origin.z);
        const stepX=direction.x>0?1:(direction.x<0?-1:0);
        const stepY=direction.y>0?1:(direction.y<0?-1:0);
        const stepZ=direction.z>0?1:(direction.z<0?-1:0);
        enum float infinity=float.max;
        const deltaX=stepX==0?infinity:fabsf(1.0f/direction.x);
        const deltaY=stepY==0?infinity:fabsf(1.0f/direction.y);
        const deltaZ=stepZ==0?infinity:fabsf(1.0f/direction.z);
        float nextX=stepX>0?(x+1.0f-origin.x)*deltaX:
            (stepX<0?(origin.x-x)*deltaX:infinity);
        float nextY=stepY>0?(y+1.0f-origin.y)*deltaY:
            (stepY<0?(origin.y-y)*deltaY:infinity);
        float nextZ=stepZ>0?(z+1.0f-origin.z)*deltaZ:
            (stepZ<0?(origin.z-z)*deltaZ:infinity);
        float distance;
        int previousX=x,previousY=y,previousZ=z;
        foreach(_;0..256)
        {
            const block=getBlock(x,y,z);
            if(block!=BlockId.air&&!isFire(block)&&!isWater(block))
                return BlockHit(true,x,y,z,block,distance,
                    previousX,previousY,previousZ);
            previousX=x;previousY=y;previousZ=z;
            if(nextX<=nextY&&nextX<=nextZ)
            {distance=nextX;nextX+=deltaX;x+=stepX;}
            else if(nextY<=nextZ)
            {distance=nextY;nextY+=deltaY;y+=stepY;}
            else
            {distance=nextZ;nextZ+=deltaZ;z+=stepZ;}
            if(distance>maximumDistance)break;
        }
        return BlockHit.init;
    }

    /// True when a point is below the local fluid surface. Water with water
    /// directly above is treated as a full-height column, matching FluidState.
    bool isPointInWater(Vec3 point) const
    {
        const x=cast(int)floorf(point.x);
        const y=cast(int)floorf(point.y);
        const z=cast(int)floorf(point.z);
        const block=getBlock(x,y,z);
        if(!isWater(block))return false;
        const height=isWater(getBlock(x,y+1,z))?1.0f:waterHeight(block);
        return point.y < y+height;
    }

    bool intersectsWater(Aabb bounds) const
    {
        const minX=cast(int)floorf(bounds.minX);
        const maxX=cast(int)floorf(bounds.maxX-0.0001f);
        const minY=cast(int)floorf(bounds.minY);
        const maxY=cast(int)floorf(bounds.maxY-0.0001f);
        const minZ=cast(int)floorf(bounds.minZ);
        const maxZ=cast(int)floorf(bounds.maxZ-0.0001f);
        foreach(y;minY..maxY+1)foreach(z;minZ..maxZ+1)foreach(x;minX..maxX+1)
        {
            const block=getBlock(x,y,z);
            if(!isWater(block))continue;
            const height=isWater(getBlock(x,y+1,z))?1.0f:waterHeight(block);
            if(bounds.minY<y+height && bounds.maxY>y)return true;
        }
        return false;
    }

    bool intersectsFire(Aabb bounds) const
    {
        const minX=cast(int)floorf(bounds.minX);
        const maxX=cast(int)floorf(bounds.maxX-0.0001f);
        const minY=cast(int)floorf(bounds.minY);
        const maxY=cast(int)floorf(bounds.maxY-0.0001f);
        const minZ=cast(int)floorf(bounds.minZ);
        const maxZ=cast(int)floorf(bounds.maxZ-0.0001f);
        foreach(y;minY..maxY+1)foreach(z;minZ..maxZ+1)
        foreach(x;minX..maxX+1)
            if(isFire(getBlock(x,y,z)))return true;
        return false;
    }

    bool canPlaceFire(int x,int y,int z) const
    {
        if(!inBounds(x,y,z))return false;
        const target=getBlock(x,y,z);
        if(target!=BlockId.air&&!isFire(target))return false;
        if(y>minimumBuildY()&&isSolid(getBlock(x,y-1,z)))return true;
        foreach(offset;[[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],
            [0,0,-1],[0,0,1]])
            if(isFlammable(getBlock(x+offset[0],y+offset[1],z+offset[2])))
                return true;
        return false;
    }

    /// FluidState.getFlow-style horizontal current. Higher legacy levels are
    /// shallower, so the vector points toward lower fluid surfaces and open
    /// drops. Callers apply Java's 0.014-block/tick fluid-push scale.
    Vec3 waterFlowAt(Vec3 point) const
    {
        const x=cast(int)floorf(point.x);
        const y=cast(int)floorf(point.y);
        const z=cast(int)floorf(point.z);
        const current=getBlock(x,y,z);
        if(!isWater(current))return Vec3.init;
        const own=isWater(getBlock(x,y+1,z))?1.0f:waterHeight(current);
        Vec3 flow;
        foreach(offset;[[-1,0],[1,0],[0,-1],[0,1]])
        {
            const nx=x+offset[0],nz=z+offset[1];
            const neighbor=getBlock(nx,y,nz);
            float difference;
            if(isWater(neighbor))
            {
                const other=isWater(getBlock(nx,y+1,nz))?1.0f
                    :waterHeight(neighbor);
                difference=own-other;
            }
            else if(!isOpaque(neighbor))
            {
                const below=getBlock(nx,y-1,nz);
                difference=isWater(below)?own-(waterHeight(below)-1.0f):own;
            }
            else continue;
            flow.x+=offset[0]*difference;
            flow.z+=offset[1]*difference;
        }
        if(current==BlockId.waterFalling)
            flow.y=-6.0f;
        return flow.lengthSquared()>0.000001f?flow.normalized():Vec3.init;
    }

    /// A compact deterministic form of WaterFluid's five-tick propagation:
    /// sources persist, water falls before spreading, horizontal levels lose
    /// one amount per block, and two neighboring sources regenerate a source.
    WaterUpdate[] tickWater()
    {
        return tickWaterChunks(loadedChunkCoordinates());
    }

    WaterUpdate[] tickWaterAround(const(Vec3)[] centers,int radius)
    {
        bool[ChunkCoordinate] selected;
        foreach(center;centers)
        {
            const centerX=chunkCoordinate(cast(int)floorf(center.x));
            const centerZ=chunkCoordinate(cast(int)floorf(center.z));
            foreach(z;centerZ-radius..centerZ+radius+1)
            foreach(x;centerX-radius..centerX+radius+1)
                if(hasChunk(x,z))selected[ChunkCoordinate(x,z)]=true;
        }
        ChunkCoordinate[] coordinates;
        foreach(coordinate,present;selected)coordinates~=coordinate;
        return tickWaterChunks(coordinates);
    }

private:
    WaterUpdate[] tickWaterChunks(const(ChunkCoordinate)[] coordinates)
    {
        WaterUpdate[] changes;
        if(dimension==DimensionId.nether)return changes;
        bool[ChunkCoordinate] selected;
        bool[BlockPosition] candidates;
        foreach(coordinate;coordinates)selected[coordinate]=true;
        foreach(coordinate;coordinates)
        foreach(cell;waterCellsFor(coordinate))
        {
            candidates[cell]=true;
            candidates[BlockPosition(cell.x,cell.y-1,cell.z)]=true;
            candidates[BlockPosition(cell.x-1,cell.y,cell.z)]=true;
            candidates[BlockPosition(cell.x+1,cell.y,cell.z)]=true;
            candidates[BlockPosition(cell.x,cell.y,cell.z-1)]=true;
            candidates[BlockPosition(cell.x,cell.y,cell.z+1)]=true;
        }
        foreach(position,present;candidates)
        {
            const x=position.x,y=position.y,z=position.z;
            if(y<minimumBuildY()||y>64
                ||ChunkCoordinate(chunkCoordinate(x),chunkCoordinate(z))
                    !in selected)continue;
            const current=getBlock(x,y,z);
            if(current!=BlockId.air && !isWater(current)&&!isFire(current))continue;
            BlockId next=BlockId.air;
            if(isWaterSource(current))next=BlockId.waterSource;
            else if(y<maximumBuildY() && isWater(getBlock(x,y+1,z)))
                next=BlockId.waterFalling;
            else
            {
                int sources;
                int best=99;
                foreach(offset;[[-1,0],[1,0],[0,-1],[0,1]])
                {
                    const neighbor=getBlock(x+offset[0],y,z+offset[1]);
                    if(isWaterSource(neighbor))++sources;
                    int level=waterLevel(neighbor);
                    // The foot of a falling column spreads horizontally as a
                    // fresh level-one flow after it reaches solid terrain.
                    if(neighbor==BlockId.waterFalling
                        &&isSolid(getBlock(x+offset[0],y-1,z+offset[1])))
                        level=0;
                    if(level>=0 && level<8 && level<best)best=level;
                }
                if(sources>=2 && y>minimumBuildY()
                    && isOpaque(getBlock(x,y-1,z)))
                    next=BlockId.waterSource;
                else if(best<7)next=waterForLevel(best+1);
            }
            // A water cell with no remaining feed drains away one level per
            // scheduled tick rather than disappearing abruptly.
            if(next==BlockId.air && isWater(current))
            {
                const oldLevel=waterLevel(current);
                if(oldLevel>=0 && oldLevel<7)next=waterForLevel(oldLevel+1);
                // Orphaned falling columns used to be immortal because level
                // eight missed the draining branch. Remove the disconnected
                // tail in one scheduled fluid step.
                else if(current==BlockId.waterFalling)next=BlockId.air;
            }
            if(next!=current)changes~=WaterUpdate(x,y,z,current,next);
        }
        foreach(change;changes)setBlock(change.x,change.y,change.z,change.newBlock);
        return changes;
    }

    const(BlockPosition)[] waterCellsFor(ChunkCoordinate coordinate)
    {
        const currentRevision=chunkRevision(coordinate.x,coordinate.z);
        if(auto found=coordinate in waterCache)
            if(found.revision==currentRevision)return found.cells;
        WaterChunkCache replacement;
        replacement.revision=currentRevision;
        const loaded=chunkAt(coordinate.x,coordinate.z);
        if(loaded !is null&&!loaded.empty)
        {
            int maximum=loaded.maximumOccupiedY();
            if(maximum>64)maximum=64;
            foreach(y;loaded.minimumOccupiedY()..maximum+1)
            foreach(localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
                if(isWater(loaded.get(localX,y,localZ)))
                    replacement.cells~=BlockPosition(
                        coordinate.x*Chunk.width+localX,y,
                        coordinate.z*Chunk.depth+localZ);
        }
        waterCache[coordinate]=replacement;
        return waterCache[coordinate].cells;
    }

public:
    /// Scheduled fire updates use the same authoritative block-change stream
    /// as water. Netherrack supports eternal fire, ordinary planks burn and
    /// spread, and unsupported fire expires instead of becoming a permanent
    /// cosmetic billboard.
    WaterUpdate[] tickFireAround(const(Vec3)[] centers,int radius,uint tick)
    {
        WaterUpdate[] changes;
        if(tick%30!=0)return changes;
        bool[ChunkCoordinate] selected;
        foreach(center;centers)
        {
            const centerX=chunkCoordinate(cast(int)floorf(center.x));
            const centerZ=chunkCoordinate(cast(int)floorf(center.z));
            foreach(z;centerZ-radius..centerZ+radius+1)
            foreach(x;centerX-radius..centerX+radius+1)
                if(hasChunk(x,z))selected[ChunkCoordinate(x,z)]=true;
        }
        bool[BlockPosition] queued;
        void queue(int x,int y,int z,BlockId next)
        {
            const position=BlockPosition(x,y,z);
            if(position in queued)return;
            const old=getBlock(x,y,z);
            if(old==next)return;
            queued[position]=true;
            changes~=WaterUpdate(x,y,z,old,next);
        }
        foreach(coordinate,present;selected)
        {
            foreach(position;fireCellsFor(coordinate))
            {
                const x=position.x,y=position.y,z=position.z;
                bool wet;
                foreach(offset;[[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],
                    [0,0,-1],[0,0,1]])
                    if(isWater(getBlock(x+offset[0],y+offset[1],z+offset[2])))
                        wet=true;
                const below=getBlock(x,y-1,z);
                bool adjacentFuel;
                foreach(offset;[[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],
                    [0,0,-1],[0,0,1]])
                    if(isFlammable(getBlock(x+offset[0],y+offset[1],z+offset[2])))
                        adjacentFuel=true;
                if(wet||(!isSolid(below)&&!adjacentFuel))
                {queue(x,y,z,BlockId.air);continue;}
                const random=hash(x,y,z,cast(long)settings.seed+tick);
                if(below!=BlockId.netherrack&&!isFlammable(below)
                    &&!adjacentFuel&&(random&3)==0)
                    queue(x,y,z,BlockId.air);
                foreach(index,offset;[[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],
                    [0,0,-1],[0,0,1]])
                {
                    const nx=x+offset[0],ny=y+offset[1],nz=z+offset[2];
                    if(isFlammable(getBlock(nx,ny,nz))
                        &&((random>>(index*3))&7)<2)
                        queue(nx,ny,nz,BlockId.fire);
                    const above=getBlock(nx,ny+1,nz);
                    if(isFlammable(getBlock(nx,ny,nz))
                        &&above==BlockId.air&&((random>>(index*4))&15)==0)
                        queue(nx,ny+1,nz,BlockId.fire);
                }
            }
        }
        foreach(change;changes)setBlock(change.x,change.y,change.z,change.newBlock);
        return changes;
    }

    const(BlockPosition)[] fireCellsFor(ChunkCoordinate coordinate)
    {
        const currentRevision=chunkRevision(coordinate.x,coordinate.z);
        if(auto found=coordinate in fireCache)
            if(found.revision==currentRevision)return found.cells;
        FireChunkCache replacement;
        replacement.revision=currentRevision;
        const loaded=chunkAt(coordinate.x,coordinate.z);
        if(loaded !is null&&!loaded.empty)
        foreach(y;loaded.minimumOccupiedY()..loaded.maximumOccupiedY()+1)
        foreach(localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
            if(isFire(loaded.get(localX,y,localZ)))
                replacement.cells~=BlockPosition(
                    coordinate.x*Chunk.width+localX,y,
                    coordinate.z*Chunk.depth+localZ);
        fireCache[coordinate]=replacement;
        return fireCache[coordinate].cells;
    }

    bool isUnobstructed(Aabb bounds) const
    {
        return foreachSolidBlock(bounds, (Aabb blockBounds) {
            if (bounds.intersects(blockBounds))
                return false;
            return true;
        });
    }

    CollisionResult collide(Aabb bounds, Vec3 requested) const
    {
        Vec3 movement = requested;

        movement.y = clipY(bounds, movement.y);
        bounds = bounds.moved(Vec3(0, movement.y, 0));

        // Java resolves the smaller horizontal component first. This makes
        // diagonal movement slide consistently along walls and block corners.
        const xFirst = fabsf(movement.x) < fabsf(movement.z);
        if (xFirst)
        {
            movement.x = clipX(bounds, movement.x);
            bounds = bounds.moved(Vec3(movement.x, 0, 0));
        }

        movement.z = clipZ(bounds, movement.z);
        bounds = bounds.moved(Vec3(0, 0, movement.z));

        if (!xFirst)
            movement.x = clipX(bounds, movement.x);

        enum float epsilon = 0.000001f;
        return CollisionResult(
            movement,
            fabsf(movement.x - requested.x) > epsilon,
            fabsf(movement.y - requested.y) > epsilon,
            fabsf(movement.z - requested.z) > epsilon,
        );
    }

    /// Clips a third-person camera segment against solid blocks. Expanding
    /// each cube by the camera radius prevents near-plane wall intersections.
    Vec3 clipCamera(Vec3 start, Vec3 desired, float cameraRadius = 0.1f) const
    {
        const delta = desired - start;
        float closest = 1.0f;
        const search = Aabb(
            start.x < desired.x ? start.x : desired.x,
            start.y < desired.y ? start.y : desired.y,
            start.z < desired.z ? start.z : desired.z,
            start.x > desired.x ? start.x : desired.x,
            start.y > desired.y ? start.y : desired.y,
            start.z > desired.z ? start.z : desired.z);
        foreachSolidBlock(search, (Aabb block) {
            block = Aabb(
                block.minX-cameraRadius, block.minY-cameraRadius, block.minZ-cameraRadius,
                block.maxX+cameraRadius, block.maxY+cameraRadius, block.maxZ+cameraRadius,
            );
            float hit;
            if (segmentHit(start, delta, block, hit) && hit < closest)
                closest = hit;
            return true;
        });
        return start + delta * closest;
    }

private:
    string chunkPath(int chunkX, int chunkZ) const
    {
        return saveDirectory.length ? buildPath(saveDirectory, "chunks",
            "c." ~ to!string(chunkX) ~ "." ~ to!string(chunkZ) ~ ".dat") : "";
    }

    void addChunk(Chunk loaded)
    {
        const coordinate = ChunkCoordinate(loaded.chunkX, loaded.chunkZ);
        chunks[coordinate] = loaded;
        markChunkAndNeighborsDirty(coordinate);
        if (loaded.chunkX == 0 && loaded.chunkZ == 0) chunk = loaded;
    }

    void markChunkAndNeighborsDirty(ChunkCoordinate center)
    {
        foreach (dz; -1 .. 2)
        foreach (dx; -1 .. 2)
        {
            const coordinate = ChunkCoordinate(center.x + dx, center.z + dz);
            if (coordinate in chunks)
            {
                if(auto found=coordinate in chunkRevisions)++*found;
                else chunkRevisions[coordinate]=1;
            }
        }
    }

    void markBlockDirty(ChunkCoordinate center,int localX,int localZ)
    {
        void bump(ChunkCoordinate coordinate)
        {
            if(coordinate !in chunks)return;
            if(auto found=coordinate in chunkRevisions)++*found;
            else chunkRevisions[coordinate]=1;
        }
        bump(center);
        const west=localX==0,east=localX==Chunk.width-1;
        const north=localZ==0,south=localZ==Chunk.depth-1;
        if(west)bump(ChunkCoordinate(center.x-1,center.z));
        if(east)bump(ChunkCoordinate(center.x+1,center.z));
        if(north)bump(ChunkCoordinate(center.x,center.z-1));
        if(south)bump(ChunkCoordinate(center.x,center.z+1));
        if(west&&north)bump(ChunkCoordinate(center.x-1,center.z-1));
        if(west&&south)bump(ChunkCoordinate(center.x-1,center.z+1));
        if(east&&north)bump(ChunkCoordinate(center.x+1,center.z-1));
        if(east&&south)bump(ChunkCoordinate(center.x+1,center.z+1));
    }

    void setRawBlock(int x, int y, int z, BlockId block)
    {
        auto loaded = ChunkCoordinate(chunkCoordinate(x),chunkCoordinate(z))
            in chunks;
        if (loaded !is null)
            (*loaded).set(localCoordinate(x),y,localCoordinate(z),block);
    }

    void loadOrGenerateChunk(int chunkX, int chunkZ)
    {
        const path = chunkPath(chunkX, chunkZ);
        auto loaded = new Chunk(chunkX, chunkZ);
        if (path.length && exists(path)
            && loaded.restore(cast(const(ubyte)[])read(path)))
            addChunk(loaded);
        else
        {
            destroy(loaded);
            ensureChunk(chunkX, chunkZ);
        }
    }

    void ensureChunk(int chunkX, int chunkZ)
    {
        const coordinate = ChunkCoordinate(chunkX, chunkZ);
        if (coordinate in chunks) return;
        auto generated=buildDetachedChunk(chunkX,chunkZ);
        addChunk(generated);
        ++revision;
    }

    void generateOverworldChunk(Chunk target)
    {
        enum int seaLevel = 63;
        const phase = cast(float)(settings.seed & 1023) * 0.0061359f;
        foreach (localZ; 0 .. Chunk.depth)
        foreach (localX; 0 .. Chunk.width)
        {
            const x=target.chunkX*Chunk.width+localX;
            const z=target.chunkZ*Chunk.depth+localZ;
            int surface;
            if(settings.worldType==WorldType.flat)
                surface=-60;
            else
            {
                const continent=fractal2(x*0.0035f,z*0.0035f,
                    settings.seed+17,5);
                const hills=fractal2(x*0.012f,z*0.012f,
                    settings.seed+7919,4);
                const detail=fractal2(x*0.045f,z*0.045f,
                    settings.seed-401,3);
                const ridges=1.0f-fabsf(fractal2(x*0.008f,z*0.008f,
                    settings.seed+49081,4));
                surface=64+cast(int)(continent*38.0f+hills*17.0f
                    +detail*5.0f+(ridges*ridges-0.45f)*18.0f);
                const river=fabsf(fractal2(x*0.0065f,z*0.0065f,
                    settings.seed-887,4));
                if(settings.generateRivers&&river<0.055f)
                {
                    const amount=(0.055f-river)/0.055f;
                    const riverBed=seaLevel-4-cast(int)(amount*3.0f);
                    if(surface>riverBed)surface=riverBed;
                }
                if(settings.generateOceans&&continent<-0.22f)
                    surface=52+cast(int)((continent+1.0f)*8.0f+detail*2.0f);
                if(surface<-55)surface=-55;
                if(surface>250)surface=250;
            }

            foreach(y;overworldMinimumY..surface+1)
            {
                BlockId block;
                const bedrockLayer=y-overworldMinimumY;
                if(bedrockLayer==0
                    ||(bedrockLayer<5
                        &&cast(int)(hash(x,y,z,settings.seed+31)%5)
                            >=bedrockLayer))
                    block=BlockId.bedrock;
                else
                    block=y==surface?BlockId.grass
                        :(y>=surface-3?BlockId.dirt:BlockId.stone);
                if(settings.worldType==WorldType.normal&&settings.generateCaves
                    &&block==BlockId.stone&&y>overworldMinimumY+5
                    &&y<surface-4)
                {
                    const cheese=fractal3(x*0.035f,y*0.055f,z*0.035f,
                        settings.seed+104729,3);
                    const tunnels=fractal3(x*0.085f,y*0.075f,z*0.085f,
                        settings.seed-31337,2);
                    const winding=sinf(x*0.095f+y*0.071f+phase)
                        +cosf(z*0.091f-y*0.063f-phase);
                    if(cheese>0.56f||(cheese>0.44f&&tunnels>0.52f)
                        ||winding>1.91f)
                        block=BlockId.air;
                }
                target.set(localX,y,localZ,block);
            }
            if(settings.worldType==WorldType.normal&&surface<seaLevel
                &&(settings.generateOceans||settings.generateRivers))
            {
                if(target.get(localX,surface,localZ)==BlockId.grass)
                    target.set(localX,surface,localZ,BlockId.dirt);
                foreach(y;surface+1..seaLevel+1)
                    target.set(localX,y,localZ,BlockId.waterSource);
            }
        }
    }

    void generateNetherChunk(Chunk target)
    {
        foreach(localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
        {
            const x=target.chunkX*Chunk.width+localX;
            const z=target.chunkZ*Chunk.depth+localZ;
            foreach(y;0..128)
            {
                const floorLayer=y;
                const roofLayer=127-y;
                bool bedrock=floorLayer==0||roofLayer==0;
                if(!bedrock&&floorLayer<5)
                    bedrock=cast(int)(hash(x,y,z,settings.seed-19)%5)>=floorLayer;
                if(!bedrock&&roofLayer<5)
                    bedrock=cast(int)(hash(x,y,z,settings.seed+23)%5)>=roofLayer;
                if(bedrock)
                {
                    target.set(localX,y,localZ,BlockId.bedrock);
                    continue;
                }
                const broad=fractal3(x*0.018f,y*0.026f,z*0.018f,
                    settings.seed+99173,4);
                const detail=fractal3(x*0.055f,y*0.065f,z*0.055f,
                    settings.seed-7331,3);
                const edge=cast(float)fabsf(cast(float)y-64.0f)/64.0f;
                const density=broad*0.72f+detail*0.28f+edge*0.82f-0.38f;
                target.set(localX,y,localZ,density>0.0f
                    ?BlockId.netherrack:BlockId.air);
            }
        }
    }

    Vec3 chooseNetherSpawn() const
    {
        foreach(radius;0..32)foreach(z;-radius..radius+1)
        foreach(x;-radius..radius+1)
        {
            foreach(y;32..96)
                if(getBlock(x,y-1,z)==BlockId.netherrack
                    &&getBlock(x,y,z)==BlockId.air
                    &&getBlock(x,y+1,z)==BlockId.air)
                    return Vec3(x+0.5f,y,z+0.5f);
        }
        return Vec3(0.5f,64.0f,0.5f);
    }

    Vec3 chooseSpawn() const
    {
        const centerX = 0;
        const centerZ = 0;
        int bestX = centerX;
        int bestZ = centerZ;
        int bestY = surfaceAt(centerX, centerZ);
        int bestScore = int.max;
        foreach (radius; 0 .. (initialChunkRadius + 1) * Chunk.width)
        foreach (z; centerZ - radius .. centerZ + radius + 1)
        foreach (x; centerX - radius .. centerX + radius + 1)
        {
            const y = surfaceAt(x, z);
            if (y < 62 || y >= overworldMaximumY - 2
                || getBlock(x,y,z) != BlockId.grass)
                continue;
            int slope;
            foreach (dz; -1 .. 2)
            foreach (dx; -1 .. 2)
            {
                int difference = surfaceAt(x + dx, z + dz) - y;
                if (difference < 0) difference = -difference;
                if (difference > slope) slope = difference;
            }
            const distance = (x-centerX)*(x-centerX) + (z-centerZ)*(z-centerZ);
            const score = slope * 10000 + distance;
            if (score < bestScore)
            {
                bestScore = score; bestX = x; bestZ = z; bestY = y;
                if (slope == 0 && radius > 2)
                    return Vec3(bestX + 0.5f, bestY + 1.0f, bestZ + 0.5f);
            }
        }
        return Vec3(bestX + 0.5f, bestY + 1.0f, bestZ + 0.5f);
    }

    int surfaceAt(int x, int z) const
    {
        foreach_reverse (y; minimumBuildY() .. maximumBuildY()+1)
            if (isSolid(getBlock(x, y, z)))
                return y;
        return minimumBuildY()-1;
    }

    void clearSpawn(Vec3 spawn)
    {
        const x = cast(int) floorf(spawn.x);
        const y = cast(int) floorf(spawn.y);
        const z = cast(int) floorf(spawn.z);
        foreach (dz; -1 .. 2)
        foreach (dx; -1 .. 2)
        {
            const top = surfaceAt(x + dx, z + dz);
            foreach (fillY; top + 1 .. y)
                setRawBlock(x + dx, fillY, z + dz, BlockId.dirt);
            setRawBlock(x + dx, y - 1, z + dz, BlockId.grass);
            setRawBlock(x + dx, y, z + dz, BlockId.air);
            setRawBlock(x + dx, y + 1, z + dz, BlockId.air);
        }
    }

    static float fade(float value)
    {
        return value * value * (3.0f - 2.0f * value);
    }

    static float mix(float a, float b, float amount)
    {
        return a + (b - a) * amount;
    }

    static uint hash(int x, int y, int z, long seed)
    {
        ulong value = cast(ulong) seed ^ (cast(ulong) cast(uint) x * 0x9E3779B1u)
            ^ (cast(ulong) cast(uint) y * 0x85EBCA77u)
            ^ (cast(ulong) cast(uint) z * 0xC2B2AE3Du);
        value ^= value >> 30; value *= 0xBF58476D1CE4E5B9UL;
        value ^= value >> 27; value *= 0x94D049BB133111EBUL;
        value ^= value >> 31;
        return cast(uint) value;
    }

    static float randomValue(int x, int y, int z, long seed)
    {
        return cast(float) (hash(x, y, z, seed) & 0x00FFFFFFu)
            / 8388607.5f - 1.0f;
    }

    static float noise2(float x, float z, long seed)
    {
        const ix = cast(int) floorf(x), iz = cast(int) floorf(z);
        const fx = fade(x - ix), fz = fade(z - iz);
        return mix(mix(randomValue(ix,0,iz,seed), randomValue(ix+1,0,iz,seed), fx),
            mix(randomValue(ix,0,iz+1,seed), randomValue(ix+1,0,iz+1,seed), fx), fz);
    }

    static float noise3(float x, float y, float z, long seed)
    {
        const ix = cast(int) floorf(x), iy = cast(int) floorf(y),
            iz = cast(int) floorf(z);
        const fx = fade(x-ix), fy = fade(y-iy), fz = fade(z-iz);
        float layer(int dy)
        {
            return mix(mix(randomValue(ix,iy+dy,iz,seed),
                    randomValue(ix+1,iy+dy,iz,seed), fx),
                mix(randomValue(ix,iy+dy,iz+1,seed),
                    randomValue(ix+1,iy+dy,iz+1,seed), fx), fz);
        }
        return mix(layer(0), layer(1), fy);
    }

    static float fractal2(float x, float z, long seed, int octaves)
    {
        float sum = 0.0f, amplitude = 1.0f, total = 0.0f;
        foreach (octave; 0 .. octaves)
        {
            sum += noise2(x, z, seed + octave * 1013) * amplitude;
            total += amplitude; amplitude *= 0.5f; x *= 2.0f; z *= 2.0f;
        }
        return sum / total;
    }

    static float fractal3(float x, float y, float z, long seed, int octaves)
    {
        float sum = 0.0f, amplitude = 1.0f, total = 0.0f;
        foreach (octave; 0 .. octaves)
        {
            sum += noise3(x, y, z, seed + octave * 1619) * amplitude;
            total += amplitude; amplitude *= 0.5f;
            x *= 2.0f; y *= 2.0f; z *= 2.0f;
        }
        return sum / total;
    }

    bool segmentHit(Vec3 start, Vec3 delta, Aabb block, out float hit) const
    {
        float minimum = 0.0f;
        float maximum = 1.0f;
        bool clipAxis(float origin, float direction, float low, float high)
        {
            if (fabsf(direction) < 0.000001f)
                return origin >= low && origin <= high;
            float first = (low-origin) / direction;
            float second = (high-origin) / direction;
            if (first > second)
            {
                const temporary = first;
                first = second;
                second = temporary;
            }
            if (first > minimum) minimum = first;
            if (second < maximum) maximum = second;
            return minimum <= maximum;
        }

        if (!clipAxis(start.x, delta.x, block.minX, block.maxX)
            || !clipAxis(start.y, delta.y, block.minY, block.maxY)
            || !clipAxis(start.z, delta.z, block.minZ, block.maxZ))
            return false;
        hit = minimum;
        return minimum >= 0.0f && minimum <= 1.0f;
    }

    bool foreachSolidBlock(scope bool delegate(Aabb) visitor) const
    {
        foreach (coordinate, loaded; chunks)
        foreach (y; minimumBuildY() .. maximumBuildY()+1)
        foreach (localZ; 0 .. Chunk.depth)
        foreach (localX; 0 .. Chunk.width)
        {
            if (!isSolid(loaded.get(localX,y,localZ)))
                continue;
            const x=coordinate.x*Chunk.width+localX;
            const z=coordinate.z*Chunk.depth+localZ;
            if (!visitor(Aabb(x, y, z, x + 1.0f, y + 1.0f, z + 1.0f)))
                return false;
        }
        return true;
    }

    bool foreachSolidBlock(Aabb area, scope bool delegate(Aabb) visitor) const
    {
        int minX = cast(int) floorf(area.minX) - 1;
        int minY = cast(int) floorf(area.minY) - 1;
        int minZ = cast(int) floorf(area.minZ) - 1;
        int maxX = cast(int) floorf(area.maxX) + 1;
        int maxY = cast(int) floorf(area.maxY) + 1;
        int maxZ = cast(int) floorf(area.maxZ) + 1;
        if (minY < minimumBuildY()) minY = minimumBuildY();
        if (maxY > maximumBuildY()) maxY = maximumBuildY();
        foreach (y; minY .. maxY + 1)
        foreach (z; minZ .. maxZ + 1)
        foreach (x; minX .. maxX + 1)
        {
            if (!isSolid(getBlock(x,y,z))) continue;
            if (!visitor(Aabb(x,y,z,x+1.0f,y+1.0f,z+1.0f))) return false;
        }
        return true;
    }

    float clipX(Aabb bounds, float amount) const
    {
        auto search = bounds;
        if (amount > 0) search.maxX += amount; else search.minX += amount;
        foreachSolidBlock(search, (Aabb block) {
            if (bounds.maxY <= block.minY || bounds.minY >= block.maxY
                || bounds.maxZ <= block.minZ || bounds.minZ >= block.maxZ)
                return true;
            if (amount > 0 && bounds.maxX <= block.minX
                && bounds.maxX + amount > block.minX)
                amount = block.minX - bounds.maxX;
            else if (amount < 0 && bounds.minX >= block.maxX
                && bounds.minX + amount < block.maxX)
                amount = block.maxX - bounds.minX;
            return true;
        });
        return amount;
    }

    float clipY(Aabb bounds, float amount) const
    {
        auto search = bounds;
        if (amount > 0) search.maxY += amount; else search.minY += amount;
        foreachSolidBlock(search, (Aabb block) {
            if (bounds.maxX <= block.minX || bounds.minX >= block.maxX
                || bounds.maxZ <= block.minZ || bounds.minZ >= block.maxZ)
                return true;
            if (amount > 0 && bounds.maxY <= block.minY
                && bounds.maxY + amount > block.minY)
                amount = block.minY - bounds.maxY;
            else if (amount < 0 && bounds.minY >= block.maxY
                && bounds.minY + amount < block.maxY)
                amount = block.maxY - bounds.minY;
            return true;
        });
        return amount;
    }

    float clipZ(Aabb bounds, float amount) const
    {
        auto search = bounds;
        if (amount > 0) search.maxZ += amount; else search.minZ += amount;
        foreachSolidBlock(search, (Aabb block) {
            if (bounds.maxX <= block.minX || bounds.minX >= block.maxX
                || bounds.maxY <= block.minY || bounds.minY >= block.maxY)
                return true;
            if (amount > 0 && bounds.maxZ <= block.minZ
                && bounds.maxZ + amount > block.minZ)
                amount = block.minZ - bounds.maxZ;
            else if (amount < 0 && bounds.minZ >= block.maxZ
                && bounds.minZ + amount < block.maxZ)
                amount = block.maxZ - bounds.minZ;
            return true;
        });
        return amount;
    }
}
