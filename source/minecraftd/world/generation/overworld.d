module minecraftd.world.generation.overworld;

import std.math : abs, floor;
import std.algorithm : min, max;
import minecraftd.world.block : BlockId;
import minecraftd.world.chunk : Chunk;
import minecraftd.world.world_settings : WorldSettings;
import minecraftd.world.generation.noise;
import minecraftd.world.generation.biomes;

enum seaLevel=63;
struct TerrainColumn
{
    int height;
    Biome biome;
    bool water;
    double temperature;
}

TerrainColumn columnAt(int x,int z,const WorldSettings settings) pure nothrow @safe @nogc
{
    const seed=settings.seed;
    const wx=x+fbm(x*.0011,z*.0011,seed+301,2)*95;
    const wz=z+fbm(x*.0011,z*.0011,seed+719,2)*95;
    const continent=fbm(wx*.0007,wz*.0007,seed+17);
    const erosion=fbm(wx*.0017,wz*.0017,seed+7919,3);
    const temperature=fbm(x*.00085,z*.00085,seed+341,3);
    const humidity=fbm(x*.001,z*.001,seed-991,3);
    const variation=fbm(wx*.0023,wz*.0023,seed+487,3);
    const river=abs(fbm(wx*.0018,wz*.0018,seed-887,2));
    const inland=smooth(-.04,.38,continent);
    const ridge=1-abs(fbm(wx*.003,wz*.003,seed+49081,3));
    const mountain=smooth(-.08,.48,-erosion)*inland;
    const valley=settings.generateRivers?smooth(.025,.40,river):1;
    double height=settings.generateOceans?lerp(29,70,smooth(-.48,.04,continent)):70;
    height+=inland*9+fbm(wx*.006,wz*.006,seed-401,3)*(3+inland*9);
    height+=mountain*ridge*ridge*ridge*145*valley;
    height+=fbm(x*.026,z*.026,seed+619,2)*(1+mountain*3);
    if(settings.generateRivers)
    {
        // Wide shoulders ease into a shallow bed. Never clamp a mountain to
        // sea level: the maximum excavation here is 24 blocks over a valley.
        const channel=1-smooth(.014,.14,river);
        height=lerp(height,min(height,max(59.0,height-24)),channel);
    }
    bool ocean=settings.generateOceans&&continent<.035;
    // Rare broad islands, using the same continuous shoreline interpolation.
    const island=smooth(.62,.86,noise2(x*.002,z*.002,seed+1789))
        *(1-smooth(-.30,-.12,continent));
    if(settings.generateOceans)height=lerp(height,73,island);
    const wet=height<seaLevel&&(ocean||settings.generateRivers);
    auto biome=selectBiome(temperature,humidity,variation,erosion,height,
        ocean&&wet,wet&&!ocean);
    if(island>.8&&height>seaLevel)biome=Biome.mushroomFields;
    return TerrainColumn(cast(int)floor(height),biome,wet,temperature);
}

// Signed cavity density on a world-aligned 4-block grid. Interpolation makes
// generation far cheaper than evaluating several octaves for every voxel.
private float cavity(int x,int y,int z,long seed) pure nothrow @safe @nogc
{
    const a=noise3(x*.035,y*.043,z*.035,seed+104729);
    const b=noise3(x*.041+37,y*.037,z*.041-19,seed-31337);
    const chamber=noise3(x*.021,y*.029,z*.021,seed+8273);
    const tubes=min(.095-abs(a),.095-abs(b));
    // Local chamber field interrupts tubes; there is no periodic sine path.
    return cast(float)max(chamber-.49,min(tubes,chamber+.12));
}

void generateOverworld(Chunk target,const WorldSettings settings)
{
    alias B=BlockId;
    const ox=target.chunkX*16, oz=target.chunkZ*16;
    TerrainColumn[256] columns;
    int highest=-64;
    foreach(z;0..16)foreach(x;0..16)
    {
        columns[z*16+x]=columnAt(ox+x,oz+z,settings);
        highest=max(highest,columns[z*16+x].height);
    }
    enum gridY=97;
    float[5*5*gridY] caves;
    const levels=min(gridY,(highest+64)/4+2);
    if(settings.generateCaves)
        foreach(y;0..levels)foreach(z;0..5)foreach(x;0..5)
            caves[(y*5+z)*5+x]=cavity(ox+x*4,y*4-64,oz+z*4,settings.seed);
    float caveAt(int x,int y,int z)
    {
        const gx=x/4, gy=(y+64)/4, gz=z/4;
        const fx=(x%4)*.25, fy=((y+64)%4)*.25, fz=(z%4)*.25;
        double[2] layer;
        foreach(dy;0..2)
        {
            const i=((gy+dy)*5+gz)*5+gx;
            layer[dy]=lerp(lerp(caves[i],caves[i+1],fx),
                lerp(caves[i+5],caves[i+6],fx),fz);
        }
        return cast(float)lerp(layer[0],layer[1],fy);
    }
    foreach(z;0..16)foreach(x;0..16)
    {
        const wx=ox+x,wz=oz+z;
        const c=columns[z*16+x];
        const surface=definition(c.biome);
        const badlands=c.biome==Biome.badlands||c.biome==Biome.erodedBadlands||c.biome==Biome.woodedBadlands;
        const entrance=!c.water&&c.height>72
            &&fbm(wx*.014,wz*.014,settings.seed+21031,2)>.48;
        foreach(y;-64..c.height+1)
        {
            B block=y<0?B.deepslate:B.stone;
            if(y>=c.height-3)block=y==c.height?surface.surface:surface.soil;
            if(badlands&&y>c.height-24&&y<c.height-3)
            {
                immutable B[8] bands=[B.orangeTerracotta,B.orangeTerracotta,B.yellowTerracotta,
                    B.redTerracotta,B.orangeTerracotta,B.whiteTerracotta,B.brownTerracotta,B.orangeTerracotta];
                block=bands[cast(uint)(y+64)/3%8];
            }
            if(settings.generateCaves&&y>-59
                &&(y<c.height-6||(entrance&&y>seaLevel+6))
                &&(!c.water||y<seaLevel-8)&&caveAt(x,y,z)>0)
                block=B.air;
            if(y==-64||(y<-60&&hash(wx,y,wz,settings.seed+31)%5>=cast(uint)(y+64)))
                block=B.bedrock;
            target.set(x,y,z,block);
        }
        if(c.water)
            foreach(y;c.height+1..seaLevel+1)
                target.set(x,y,z,y==seaLevel&&c.temperature<-.32?B.packedIce:B.waterSource);
    }
    if(settings.generateTrees)
    {
        import minecraftd.world.generation.trees : generateTrees;
        generateTrees(target,settings);
    }
}
