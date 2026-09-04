module minecraftd.client.render.world_lighting;

import minecraftd.common.math3d : Vec3, clamp;
import minecraftd.world.block : BlockId, isFire, isNetherPortal, isOpaque,
    isWater;
import minecraftd.world.chunk : Chunk, ChunkCoordinate, chunkCoordinate;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : DimensionId;

private final class LightChunk
{
    uint signature;
    DimensionId dimension;
    ChunkCoordinate coordinate;
    int originX, originY, originZ, height;
    ubyte[] sky;
    ubyte[] block;
    enum int border=1;
    enum int width=Chunk.width+border*2;
    enum int depth=Chunk.depth+border*2;

    bool inside(int x,int y,int z) const
    {
        return x>=originX&&x<originX+width&&y>=originY&&y<originY+height
            &&z>=originZ&&z<originZ+depth;
    }
    bool containsColumn(int x,int z) const
    {
        return x>=originX&&x<originX+width&&z>=originZ&&z<originZ+depth;
    }
    size_t indexOf(int x,int y,int z) const
    {
        return (cast(size_t)(y-originY)*depth+(z-originZ))*width+(x-originX);
    }
    int xOf(size_t i) const{return originX+cast(int)(i%width);}
    int zOf(size_t i) const{return originZ+cast(int)((i/width)%depth);}
    int yOf(size_t i) const{return originY+cast(int)(i/(width*depth));}
}

private struct LightEmitter
{
    int x,y,z;
    ubyte level;
}

private struct EmitterChunk
{
    uint revision;
    LightEmitter[] emitters;
}

/// Chunk-local Java-style light storage. Streamed chunks invalidate only
/// themselves and their edge neighbours instead of reallocating and filling
/// one ever-growing world rectangle.
final class WorldLighting
{
    private World world;
    private LightChunk[ChunkCoordinate] cached;
    private EmitterChunk[ChunkCoordinate] emitterCache;
    private LightChunk active;
    private float gamma=0.5f;

    this(World world){this.world=world;}
    ~this()
    {
        foreach(entry;cached)destroy(entry);
        cached.clear();
        emitterCache.clear();
    }
    void configure(float value){gamma=clamp(value,0.0f,1.0f);}

    void refresh()
    {
        if(active !is null&&active.signature!=revisionSignature(
            active.coordinate))active=null;
        ChunkCoordinate[] stale;
        foreach(coordinate,entry;cached)
            if(!world.hasChunk(coordinate.x,coordinate.z))stale~=coordinate;
        foreach(coordinate;stale)
        {
            if(active is cached[coordinate])active=null;
            destroy(cached[coordinate]);
            cached.remove(coordinate);
        }
        stale.length=0;
        foreach(coordinate,entry;emitterCache)
            if(!world.hasChunk(coordinate.x,coordinate.z))stale~=coordinate;
        foreach(coordinate;stale)emitterCache.remove(coordinate);
    }

    void prepare(ChunkCoordinate coordinate)
    {
        active=lightForCoordinate(coordinate);
    }

    ubyte skyLevelAt(int x,int y,int z)
    {
        auto light=lightFor(x,z);
        if(light is null)
            return world.dimension==DimensionId.overworld?15:0;
        if(!light.inside(x,y,z))return y>=light.originY+light.height
            &&world.dimension==DimensionId.overworld?15:0;
        return light.sky[light.indexOf(x,y,z)];
    }
    ubyte blockLevelAt(int x,int y,int z)
    {
        auto light=lightFor(x,z);
        if(light is null||!light.inside(x,y,z))return 0;
        return light.block[light.indexOf(x,y,z)];
    }
    float brightnessAt(int x,int y,int z)
    {
        auto light=lightFor(x,z);
        if(light is null)
            return world.dimension==DimensionId.overworld?1.0f:gammaCorrect(0.1f);
        if(!light.inside(x,y,z))return world.dimension==DimensionId.overworld
            &&y>=light.originY+light.height?1.0f:gammaCorrect(
                world.dimension==DimensionId.nether?0.1f:0.04f);
        const sky=light.sky[light.indexOf(x,y,z)];
        const block=light.block[light.indexOf(x,y,z)];
        const ambient=world.dimension==DimensionId.nether?0.1f:0.04f;
        return gammaCorrect(clamp(ambient+minecraftBrightness(sky)
            +minecraftBrightness(block),0.0f,1.0f));
    }
    float brightnessAt(Vec3 point)
    {
        import core.stdc.math:floorf;
        return brightnessAt(cast(int)floorf(point.x),cast(int)floorf(point.y),
            cast(int)floorf(point.z));
    }

private:
    LightChunk lightFor(int x,int z)
    {
        const coordinate=ChunkCoordinate(chunkCoordinate(x),chunkCoordinate(z));
        // prepare()/refresh() validates the active cache once per section.
        // Re-hashing nine neighboring chunks for every one of the millions of
        // vertex-light samples made smooth lighting needlessly CPU-bound.
        if(active !is null&&active.containsColumn(x,z))
            return active;
        return lightForCoordinate(coordinate);
    }

    LightChunk lightForCoordinate(ChunkCoordinate coordinate)
    {
        if(!world.hasChunk(coordinate.x,coordinate.z))return null;
        const signature=revisionSignature(coordinate);
        if(auto found=coordinate in cached)
            if((*found).signature==signature&&(*found).dimension==world.dimension)
                return *found;
        auto replacement=build(coordinate,signature);
        if(auto old=coordinate in cached)
        {
            if(active is *old)active=null;
            destroy(*old);
        }
        cached[coordinate]=replacement;
        return replacement;
    }
    uint revisionSignature(ChunkCoordinate center) const
    {
        uint value=2166136261u;
        foreach(dz;-1..2)foreach(dx;-1..2)
        {
            value^=world.chunkRevision(center.x+dx,center.z+dz)
                +cast(uint)((dx+1)*31+(dz+1)*131);
            value*=16777619u;
        }
        return value;
    }
    LightChunk build(ChunkCoordinate coordinate,uint signature)
    {
        auto result=new LightChunk();
        result.signature=signature;result.dimension=world.dimension;
        result.coordinate=coordinate;
        result.originX=coordinate.x*Chunk.width-LightChunk.border;
        result.originZ=coordinate.z*Chunk.depth-LightChunk.border;
        int occupiedMin=world.maximumBuildY()+1;
        int occupiedMax=world.minimumBuildY()-1;
        foreach(dz;-1..2)foreach(dx;-1..2)
        {
            const loaded=world.chunkAt(coordinate.x+dx,coordinate.z+dz);
            if(loaded is null||loaded.empty)continue;
            if(loaded.minimumOccupiedY()<occupiedMin)
                occupiedMin=loaded.minimumOccupiedY();
            if(loaded.maximumOccupiedY()>occupiedMax)
                occupiedMax=loaded.maximumOccupiedY();
        }
        if(occupiedMax<occupiedMin)
        {occupiedMin=world.minimumBuildY();occupiedMax=occupiedMin;}
        result.originY=occupiedMin>world.minimumBuildY()
            ?occupiedMin-1:world.minimumBuildY();
        int lightMaximum=occupiedMax<world.maximumBuildY()
            ?occupiedMax+1:world.maximumBuildY();
        result.height=lightMaximum-result.originY+1;
        const count=cast(size_t)LightChunk.width*LightChunk.depth*result.height;
        result.sky.length=count;result.block.length=count;
        if(world.dimension==DimensionId.overworld)
        {
            size_t[] queue;
            foreach(z;result.originZ..result.originZ+LightChunk.depth)
            foreach(x;result.originX..result.originX+LightChunk.width)
            {
                ubyte level=15;
                for(int y=result.originY+result.height-1;y>=result.originY;--y)
                {
                    const cell=world.getBlock(x,y,z);
                    if(isOpaque(cell))break;
                    if(isWater(cell)&&level>0)--level;
                    const index=result.indexOf(x,y,z);
                    result.sky[index]=level;
                    if(level>1)queue~=index;
                }
            }
            spread(result,result.sky,queue);
        }
        buildBlockLight(result);
        return result;
    }

    void buildBlockLight(LightChunk result)
    {
        // Block light reaches fifteen cells. The former one-cell-local flood
        // made every mesh calculate a different answer near chunk borders,
        // producing the conspicuous razor-edged bands around fire and portals.
        enum int reach=15;
        const minX=result.originX-(reach-1);
        const minZ=result.originZ-(reach-1);
        const maxX=result.originX+LightChunk.width+(reach-1);
        const maxZ=result.originZ+LightChunk.depth+(reach-1);
        int minY=result.originY-(reach-1);
        int maxY=result.originY+result.height+(reach-1);
        if(minY<world.minimumBuildY())minY=world.minimumBuildY();
        if(maxY>world.maximumBuildY()+1)maxY=world.maximumBuildY()+1;

        LightEmitter[] sources;
        foreach(chunkZ;chunkCoordinate(minZ)..chunkCoordinate(maxZ-1)+1)
        foreach(chunkX;chunkCoordinate(minX)..chunkCoordinate(maxX-1)+1)
            sources~=emittersFor(ChunkCoordinate(chunkX,chunkZ));
        if(!sources.length)return;

        const width=maxX-minX,depth=maxZ-minZ,height=maxY-minY;
        ubyte[] levels;
        levels.length=cast(size_t)width*depth*height;
        size_t[] queue;
        size_t indexOf(int x,int y,int z)
        {return (cast(size_t)(y-minY)*depth+(z-minZ))*width+(x-minX);}
        foreach(source;sources)
        {
            if(source.x<minX||source.x>=maxX||source.y<minY
                ||source.y>=maxY||source.z<minZ||source.z>=maxZ)continue;
            const index=indexOf(source.x,source.y,source.z);
            if(source.level<=levels[index])continue;
            levels[index]=source.level;
            queue~=index;
        }

        static immutable int[6] dx=[1,-1,0,0,0,0];
        static immutable int[6] dy=[0,0,1,-1,0,0];
        static immutable int[6] dz=[0,0,0,0,1,-1];
        size_t head;
        while(head<queue.length)
        {
            const currentIndex=queue[head++];
            const current=levels[currentIndex];
            if(current<=1)continue;
            const localX=cast(int)(currentIndex%width);
            const localZ=cast(int)((currentIndex/width)%depth);
            const localY=cast(int)(currentIndex/(width*depth));
            const x=minX+localX,y=minY+localY,z=minZ+localZ;
            foreach(side;0..6)
            {
                const nx=x+dx[side],ny=y+dy[side],nz=z+dz[side];
                if(nx<minX||nx>=maxX||ny<minY||ny>=maxY
                    ||nz<minZ||nz>=maxZ
                    ||isOpaque(world.getBlock(nx,ny,nz)))continue;
                const neighbor=indexOf(nx,ny,nz);
                const next=cast(ubyte)(current-1);
                if(next<=levels[neighbor])continue;
                levels[neighbor]=next;
                queue~=neighbor;
            }
        }
        foreach(y;result.originY..result.originY+result.height)
        foreach(z;result.originZ..result.originZ+LightChunk.depth)
        foreach(x;result.originX..result.originX+LightChunk.width)
            result.block[result.indexOf(x,y,z)]=levels[indexOf(x,y,z)];
    }

    const(LightEmitter)[] emittersFor(ChunkCoordinate coordinate)
    {
        const revision=world.chunkRevision(coordinate.x,coordinate.z);
        if(auto found=coordinate in emitterCache)
            if(found.revision==revision)return found.emitters;
        EmitterChunk replacement;
        replacement.revision=revision;
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        if(loaded !is null&&!loaded.empty)
        foreach(y;loaded.minimumOccupiedY()..loaded.maximumOccupiedY()+1)
        foreach(localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
        {
            const level=blockEmission(loaded.get(localX,y,localZ));
            if(level)replacement.emitters~=LightEmitter(
                coordinate.x*Chunk.width+localX,y,
                coordinate.z*Chunk.depth+localZ,level);
        }
        emitterCache[coordinate]=replacement;
        return emitterCache[coordinate].emitters;
    }
    void spread(LightChunk grid,ref ubyte[] levels,size_t[] queue)
    {
        static immutable int[6] dx=[1,-1,0,0,0,0];
        static immutable int[6] dy=[0,0,1,-1,0,0];
        static immutable int[6] dz=[0,0,0,0,1,-1];
        size_t head;
        while(head<queue.length)
        {
            const currentIndex=queue[head++];
            const current=levels[currentIndex];
            if(current<=1)continue;
            const x=grid.xOf(currentIndex),y=grid.yOf(currentIndex),
                z=grid.zOf(currentIndex);
            foreach(side;0..6)
            {
                const nx=x+dx[side],ny=y+dy[side],nz=z+dz[side];
                if(!grid.inside(nx,ny,nz)||isOpaque(world.getBlock(nx,ny,nz)))
                    continue;
                const next=cast(ubyte)(current-1);
                const neighbor=grid.indexOf(nx,ny,nz);
                if(next<=levels[neighbor])continue;
                levels[neighbor]=next;queue~=neighbor;
            }
        }
    }
    static ubyte blockEmission(BlockId cell)
    {
        return isFire(cell)?15:(isNetherPortal(cell)?11:0);
    }
    static float minecraftBrightness(ubyte level)
    {
        const normalized=cast(float)level/15.0f;
        return normalized<=0?0:normalized/(4.0f-3.0f*normalized);
    }
    float gammaCorrect(float value) const
    {
        const inverse=1.0f-value;
        const notGamma=1.0f-inverse*inverse*inverse*inverse;
        return value+(notGamma-value)*gamma;
    }
}

unittest
{
    auto world=new World();scope(exit)destroy(world);
    auto lighting=new WorldLighting(world);scope(exit)destroy(lighting);
    assert(lighting.skyLevelAt(20,20,20)==15);
    foreach(y;9..12)foreach(z;9..12)foreach(x;9..12)
        if(x==9||x==11||y==9||y==11||z==9||z==11)
            world.setBlock(x,y,z,BlockId.stone);
    assert(lighting.skyLevelAt(10,10,10)==0);
    world.setBlock(10,10,10,BlockId.netherPortalX);
    assert(lighting.blockLevelAt(10,10,10)==11);
}
