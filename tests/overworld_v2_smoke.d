module overworld_v2_smoke;

import std.stdio : writeln;
import std.file : write, mkdirRecurse, exists, rmdirRecurse;
import std.format : format;
import std.math : abs, isFinite;
import std.algorithm : min, max;
import std.datetime.stopwatch : StopWatch, AutoStart;
import minecraftd.world.generation.overworld;
import minecraftd.world.generation.biomes;
import minecraftd.world.generation.noise;
import minecraftd.world.world_settings;
import minecraftd.world.block;
import minecraftd.world.chunk;
import minecraftd.game.item.inventory;
import minecraftd.game.item.workstations;

void main()
{
    mkdirRecurse("test-output/terrain");
    bool[Biome.max+1] seen;
    int low=319,high=-64,maxStep=0,wetStep=0;
    size_t wet,land;
    foreach(seed;[1L,42L,8675309L,-9123487123L,long.min])
    {
        WorldSettings settings;settings.seed=seed;
        ubyte[] pixels;
        foreach(z;0..256)foreach(x;0..256)
        {
            const wx=(x-128)*24,wz=(z-128)*24;
            const c=columnAt(wx,wz,settings);
            assert(c.height>=20&&c.height<260&&isFinite(c.temperature));
            assert(c==columnAt(wx,wz,settings));
            seen[c.biome]=true; low=min(low,c.height);high=max(high,c.height);
            if(c.water)++wet;else ++land;
            foreach(offset;[1,16])
            {
                const neighbor=columnAt(wx+offset,wz,settings);
                const step=abs(c.height-neighbor.height);
                if(offset==1)
                {
                    maxStep=max(maxStep,step);
                    if(c.water!=neighbor.water)wetStep=max(wetStep,step);
                    assert(step<=8,"A single column must not drop vertically to a river bed");
                }
                else assert(step<=64,format("Steep span seed=%s x=%s z=%s height=%s next=%s",seed,wx,wz,c.height,neighbor.height));
            }
            auto top=definition(c.biome).surface;
            ubyte[3] color=c.water?[40,95,160]:top==BlockId.sand?[216,201,140]:
                top==BlockId.snowBlock?[228,238,244]:top==BlockId.redSand?[186,97,55]:
                top==BlockId.stone||top==BlockId.gravel?[130,135,132]:
                top==BlockId.mycelium?[131,110,129]:[80,145,66];
            const shade=.65+min(1.0,max(0.0,(c.height-30)/160.0))*.65;
            foreach(ref channel;color)channel=cast(ubyte)min(255,cast(int)(channel*shade));
            pixels~=color[];
        }
        write(format("test-output/terrain/map-%s.ppm",seed),"P6\n256 256\n255\n"~cast(string)pixels);
        foreach(x;[-29_999_983,-17,-1,0,15,29_999_982])
        {
            const c=columnAt(x,-x,settings), next=columnAt(x+1,-x,settings);
            assert(c.height>=20&&c.height<260&&abs(c.height-next.height)<=8);
        }
    }
    size_t biomeCount;
    foreach(i,present;seen)if(present){++biomeCount;writeln(cast(Biome)i);}
    assert(biomeCount>=30 && high-low>100 && wet>1000 && land>1000);
    writeln("Columns: height ",low,"..",high,", maximum adjacent step ",maxStep,
        ", shoreline step ",wetStep,", biomes ",biomeCount,", water/land ",wet,"/",land);

    WorldSettings settings;settings.seed=42;
    auto watch=StopWatch(AutoStart.yes);
    size_t leaves,logs,caves;
    bool crossedEdge;
    // Locate a wooded climate once, then inspect real generated chunks.
    int forestX,forestZ;bool found;
    foreach(z;-32..33){foreach(x;-32..33)
    {
        const c=columnAt(x*32,z*32,settings);
        if(!c.water&&definition(c.biome).trees>=50)
        {forestX=chunkCoordinate(x*32);forestZ=chunkCoordinate(z*32);found=true;break;}
    }if(found)break;}
    assert(found);
    ubyte[][ChunkCoordinate] snapshots;
    foreach(z;forestZ-2..forestZ+3)foreach(x;forestX-2..forestX+3)
    {
        auto chunk=new Chunk(x,z);generateOverworld(chunk,settings);
        snapshots[ChunkCoordinate(x,z)]=chunk.snapshot();
        foreach(lz;0..16)foreach(lx;0..16)
        {
            assert(chunk.get(lx,-64,lz)==BlockId.bedrock);
            const c=columnAt(x*16+lx,z*16+lz,settings);
            foreach(y;-59..c.height-6)if(chunk.get(lx,y,lz)==BlockId.air)++caves;
            foreach(y;c.height+1..c.height+25)
            {
                const block=chunk.get(lx,y,lz);
                if(isLog(block))++logs;
                if(isLeaves(block)){++leaves;if(lx==0||lz==0)crossedEdge=true;}
            }
        }
        destroy(chunk);
    }
    foreach_reverse(z;forestZ-2..forestZ+3)foreach_reverse(x;forestX-2..forestX+3)
    {
        auto chunk=new Chunk(x,z);generateOverworld(chunk,settings);
        assert(chunk.snapshot()==snapshots[ChunkCoordinate(x,z)],"Generation order changed a tree or cave");
        destroy(chunk);
    }
    assert(logs>20&&leaves>100&&crossedEdge&&caves>100);
    writeln("50 chunks: ",watch.peek.total!"msecs"," ms; logs ",logs,", leaves ",leaves,", cave air ",caves);
    auto bare=new Chunk(forestX,forestZ);
    settings.generateTrees=false;settings.generateCaves=false;
    generateOverworld(bare,settings);
    foreach(value;bare.snapshot())assert(!isLeaves(cast(BlockId)value)&&!isLog(cast(BlockId)value));
    foreach(z;0..16)foreach(x;0..16)
    {
        const c=columnAt(forestX*16+x,forestZ*16+z,settings);
        foreach(y;-64..c.height+1)assert(bare.get(x,y,z)!=BlockId.air);
    }
    destroy(bare);
    settings.generateOceans=false;settings.generateRivers=false;
    foreach(z;-100..101)foreach(x;-100..101)
        assert(!columnAt(x*16,z*16,settings).water);
    foreach(raw;cast(int)ItemId.oakLog..cast(int)lastItem+1)
    {
        const item=cast(ItemId)raw;
        assert(blockItem(placedBlock(item))==item);
        assert(itemName(item).length&&itemIdentifier(item).length);
        assert(creativeItemInGroup(item,CreativeItemGroup.naturalBlocks));
    }
    assert(isSolid(BlockId.oakLeaves)&&!isOpaque(BlockId.oakLeaves));
    ItemStack[10] input;input[0]=ItemStack(ItemId.oakLog,1);
    assert(craftingResult(input)==ItemStack(ItemId.oakPlanks,4));
    const metadata="test-output/terrain/metadata";
    assert(!exists(metadata));mkdirRecurse(metadata);
    scope(exit)rmdirRecurse(metadata);
    write(metadata~"/level.dat","seed=42\n");
    assert(loadWorldMetadata(metadata).generatorVersion==1);
    saveWorldMetadata(metadata,settings);
    assert(loadWorldMetadata(metadata).generatorVersion==2);
    writeln("Overworld v2 regression checks passed");
}


