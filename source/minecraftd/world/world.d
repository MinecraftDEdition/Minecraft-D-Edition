module minecraftd.world.world;

import core.stdc.math : cosf, fabsf, floorf, sinf;
import std.file : exists, read, write;
import std.path : buildPath;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : Vec3;
import minecraftd.world.block : BlockId, isOpaque, isWater, isWaterSource,
    waterForLevel, waterHeight, waterLevel;
import minecraftd.world.chunk : Chunk;
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

final class World
{
    Chunk chunk;
    uint revision;
    WorldSettings settings;
    string saveDirectory;
    DimensionId dimension = DimensionId.overworld;

    this()
    {
        chunk = new Chunk();
        settings.spawn = Vec3(8.0f,1.0f,3.0f);
        foreach (z; 0 .. Chunk.depth)
        foreach (x; 0 .. Chunk.width)
        {
            chunk.set(x, 0, z, BlockId.grass);
        }

        // Small shapes deliberately create visible AO corners and directional shading.
        foreach (x; 5 .. 9)
        foreach (z; 6 .. 10)
            chunk.set(x, 1, z, BlockId.stone);
        chunk.set(6, 2, 7, BlockId.stone);
        chunk.set(7, 2, 7, BlockId.stone);
        chunk.set(7, 2, 8, BlockId.dirt);
        chunk.set(11, 1, 11, BlockId.grass);
        chunk.set(11, 2, 11, BlockId.grass);
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

private:
    void initialize(WorldSettings requested, string directory,
        DimensionId requestedDimension, GenerationProgress progress)
    {
        chunk = new Chunk();
        settings = requested;
        saveDirectory = directory;
        dimension = requestedDimension;
        const blockPath = buildPath(directory, "blocks.dat");
        if (exists(blockPath))
        {
            if (progress !is null) progress(5);
            const bytes = cast(const(ubyte)[]) read(blockPath);
            if (!chunk.restore(bytes))
                generateForDimension(progress);
            else
            {
                settings = loadWorldMetadata(directory);
                if(requestedDimension==DimensionId.overworld
                    && settings.worldType==WorldType.normal)
                    addWaterToLegacyTerrain();
                if (progress !is null) progress(100);
            }
        }
        else
        {
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
        bool found;
        foreach(y;0..Chunk.height)foreach(z;0..Chunk.depth)foreach(x;0..Chunk.width)
            if(isWater(chunk.get(x,y,z))){found=true;break;}
        if(found)return;
        foreach(z;0..Chunk.depth)foreach(x;0..Chunk.width)
        {
            int surface=-1;
            foreach(y;0..11)if(isOpaque(chunk.get(x,y,z)))surface=y;
            if(surface>=0&&surface<10)
            {
                if(chunk.get(x,surface,z)==BlockId.grass)
                    chunk.set(x,surface,z,BlockId.dirt);
                foreach(y;surface+1..11)
                    if(chunk.get(x,y,z)==BlockId.air)
                        chunk.set(x,y,z,BlockId.waterSource);
            }
        }
        ++revision;
    }

    void save()
    {
        if (!saveDirectory.length || chunk is null)
            return;
        saveWorldMetadata(saveDirectory, settings);
        write(buildPath(saveDirectory, "blocks.dat"), chunk.snapshot());
    }

    void generate(GenerationProgress progress = null)
    {
        if (progress !is null) progress(0);
        foreach (x; 0 .. Chunk.width)
        {
            foreach (z; 0 .. Chunk.depth)
            {
                int surface;
                const phase = cast(float)(settings.seed & 1023) * 0.0061359f;
                if (settings.worldType == WorldType.flat)
                    surface = 5;
                else
                {
                    const broad = fractal2(x * 0.055f, z * 0.055f,
                        settings.seed, 4);
                    const detail = fractal2(x * 0.13f, z * 0.13f,
                        settings.seed + 7919, 3);
                    const rolling = sinf(x * 0.13f + phase) * 3.0f
                        + cosf(z * 0.11f - phase) * 3.0f;
                    surface = 12 + cast(int) (broad * 6.0f
                        + detail * 2.0f + rolling);
                    if (surface < 5) surface = 5;
                    if (surface > Chunk.height - 5) surface = Chunk.height - 5;
                }
                foreach (y; 0 .. surface + 1)
                {
                    BlockId block = y == surface ? BlockId.grass
                        : (y >= surface - 3 ? BlockId.dirt : BlockId.stone);
                    if (settings.worldType == WorldType.normal && y >= 2
                        && y <= surface - 4)
                    {
                        const cheese = fractal3(x * 0.105f, y * 0.15f,
                            z * 0.105f, settings.seed + 104729, 3);
                        const tunnel = fractal3(x * 0.055f, y * 0.09f,
                            z * 0.055f, settings.seed - 31337, 2);
                        const winding = sinf(x * 0.29f + y * 0.17f + phase)
                            + cosf(z * 0.31f - y * 0.13f - phase);
                        if (cheese > 0.58f
                            || (cheese > 0.50f && tunnel > 0.45f)
                            || winding > 1.86f)
                            block = BlockId.air;
                    }
                    chunk.set(x, y, z, block);
                }
                // Java's oceans occupy terrain below sea level. Keeping the
                // finite prototype's sea at y=10 creates shorelines, pools,
                // and underwater caves without submerging its usual spawn.
                if (settings.worldType == WorldType.normal && surface < 10)
                {
                    chunk.set(x, surface, z, BlockId.dirt);
                    foreach (y; surface + 1 .. 11)
                        chunk.set(x, y, z, BlockId.waterSource);
                }
            }
            if (progress !is null)
                progress(5 + cast(int) ((x + 1) * 85 / Chunk.width));
        }
        settings.spawn = chooseSpawn();
        clearSpawn(settings.spawn);
        ++revision;
        if (progress !is null) progress(100);
    }

    /// A compact Nether-wastes prototype: a netherrack floor and ceiling,
    /// broad noise-shaped caverns, and a deliberately traversable central
    /// shelf for the first destination portal. It remains a genuinely separate
    /// block volume and save file even though this early build omits biomes,
    /// lava seas, structures, and the 8:1 coordinate transform.
    void generateNether(GenerationProgress progress = null)
    {
        if (progress !is null) progress(0);
        foreach (x; 0 .. Chunk.width)
        {
            foreach (z; 0 .. Chunk.depth)
            {
                const floorNoise = fractal2(x * 0.07f, z * 0.07f,
                    settings.seed - 113, 4);
                const roofNoise = fractal2(x * 0.06f, z * 0.06f,
                    settings.seed + 7331, 3);
                int floorHeight = 7 + cast(int) (floorNoise * 3.0f);
                int roofStart = 24 + cast(int) (roofNoise * 2.0f);
                if (floorHeight < 4) floorHeight = 4;
                if (floorHeight > 11) floorHeight = 11;
                if (roofStart < 20) roofStart = 20;
                if (roofStart > 27) roofStart = 27;
                foreach (y; 0 .. Chunk.height)
                {
                    BlockId block = y <= floorHeight || y >= roofStart
                        ? BlockId.netherrack : BlockId.air;
                    if (block == BlockId.netherrack && y > 1
                        && y < Chunk.height - 2)
                    {
                        const cave = fractal3(x * 0.09f, y * 0.12f,
                            z * 0.09f, settings.seed + 99173, 3);
                        if (cave > 0.66f && y > floorHeight - 2
                            && y < roofStart + 2)
                            block = BlockId.air;
                    }
                    chunk.set(x, y, z, block);
                }
            }
            if (progress !is null)
                progress(5 + cast(int) ((x + 1) * 85 / Chunk.width));
        }

        const centerX = Chunk.width / 2;
        const centerZ = Chunk.depth / 2;
        const floorY = 9;
        foreach (z; centerZ - 5 .. centerZ + 6)
        foreach (x; centerX - 5 .. centerX + 6)
        {
            foreach (y; floorY .. floorY + 7)
                chunk.set(x, y, z, y == floorY ? BlockId.netherrack
                    : BlockId.air);
        }
        settings.spawn = Vec3(centerX + 0.5f, floorY + 1.0f,
            centerZ + 0.5f);
        ++revision;
        if (progress !is null) progress(100);
    }

    BlockId getBlock(int x, int y, int z) const
    {
        return chunk.get(x, y, z);
    }

    bool inBounds(int x, int y, int z) const
    {
        return x >= 0 && x < Chunk.width && y >= 0 && y < Chunk.height
            && z >= 0 && z < Chunk.depth;
    }

    void setBlock(int x, int y, int z, BlockId block)
    {
        if (!inBounds(x, y, z))
            return;
        if (chunk.get(x, y, z) == block)
            return;
        chunk.set(x, y, z, block);
        ++revision;
    }

    /// Forces render/collision consumers to rebuild after a complete network
    /// snapshot, including when every received block equals the bootstrap map.
    void markDirty()
    {
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
        WaterUpdate[] changes;
        foreach(y;0..Chunk.height)foreach(z;0..Chunk.depth)foreach(x;0..Chunk.width)
        {
            const current=getBlock(x,y,z);
            if(current!=BlockId.air && !isWater(current))continue;
            BlockId next=BlockId.air;
            if(isWaterSource(current))next=BlockId.waterSource;
            else if(y+1<Chunk.height && isWater(getBlock(x,y+1,z)))
                next=BlockId.waterFalling;
            else
            {
                int sources;
                int best=99;
                foreach(offset;[[-1,0],[1,0],[0,-1],[0,1]])
                {
                    const neighbor=getBlock(x+offset[0],y,z+offset[1]);
                    if(isWaterSource(neighbor))++sources;
                    const level=waterLevel(neighbor);
                    if(level>=0 && level<8 && level<best)best=level;
                }
                if(sources>=2 && y>0 && isOpaque(getBlock(x,y-1,z)))
                    next=BlockId.waterSource;
                else if(best<7)next=waterForLevel(best+1);
            }
            // A water cell with no remaining feed drains away one level per
            // scheduled tick rather than disappearing abruptly.
            if(next==BlockId.air && isWater(current))
            {
                const oldLevel=waterLevel(current);
                if(oldLevel>=0 && oldLevel<7)next=waterForLevel(oldLevel+1);
            }
            if(next!=current)changes~=WaterUpdate(x,y,z,current,next);
        }
        foreach(change;changes)setBlock(change.x,change.y,change.z,change.newBlock);
        return changes;
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
    Vec3 chooseSpawn() const
    {
        const centerX = Chunk.width / 2;
        const centerZ = Chunk.depth / 2;
        int bestX = centerX;
        int bestZ = centerZ;
        int bestY = surfaceAt(centerX, centerZ);
        int bestScore = int.max;
        foreach (radius; 0 .. Chunk.width / 2)
        foreach (z; centerZ - radius .. centerZ + radius + 1)
        foreach (x; centerX - radius .. centerX + radius + 1)
        {
            if (x < 2 || z < 2 || x >= Chunk.width - 2 || z >= Chunk.depth - 2)
                continue;
            const y = surfaceAt(x, z);
            if (y < 1 || y >= Chunk.height - 3)
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
        foreach_reverse (y; 0 .. Chunk.height)
            if (chunk.get(x, y, z) != BlockId.air)
                return y;
        return -1;
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
                chunk.set(x + dx, fillY, z + dz, BlockId.dirt);
            chunk.set(x + dx, y - 1, z + dz, BlockId.grass);
            chunk.set(x + dx, y, z + dz, BlockId.air);
            chunk.set(x + dx, y + 1, z + dz, BlockId.air);
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
        foreach (y; 0 .. Chunk.height)
        foreach (z; 0 .. Chunk.depth)
        foreach (x; 0 .. Chunk.width)
        {
            if (!isOpaque(chunk.get(x, y, z)))
                continue;
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
        if (minX < 0) minX = 0; if (minY < 0) minY = 0; if (minZ < 0) minZ = 0;
        if (maxX >= Chunk.width) maxX = Chunk.width - 1;
        if (maxY >= Chunk.height) maxY = Chunk.height - 1;
        if (maxZ >= Chunk.depth) maxZ = Chunk.depth - 1;
        foreach (y; minY .. maxY + 1)
        foreach (z; minZ .. maxZ + 1)
        foreach (x; minX .. maxX + 1)
        {
            if (!isOpaque(chunk.get(x,y,z))) continue;
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
