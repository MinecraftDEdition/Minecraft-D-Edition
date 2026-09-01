module world_generation_smoke;

import std.file : exists, getcwd, rmdirRecurse;
import std.path : buildPath;
import std.stdio : writeln;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.common.math3d : Vec3;
import minecraftd.world.block : BlockId;
import minecraftd.world.chunk : Chunk;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : DimensionId, GameMode, WorldSettings;

void main()
{
    const directory = buildPath(getcwd(),"tests","generated_world_test");
    if (exists(directory)) rmdirRecurse(directory);
    scope(exit) if (exists(directory)) rmdirRecurse(directory);

    WorldSettings settings;
    settings.name = "Generation Test";
    settings.folder = "generated_world_test";
    settings.seed = 8675309;
    int lastProgress = -1;
    auto world = new World(settings,directory,(int percent) {
        assert(percent >= lastProgress && percent >= 0 && percent <= 100);
        lastProgress = percent;
    });
    assert(lastProgress == 100);
    const spawn = world.settings.spawn;
    const sx = cast(int)spawn.x, sy = cast(int)spawn.y, sz = cast(int)spawn.z;
    assert(world.getBlock(sx,sy-1,sz) == BlockId.grass);
    assert(world.getBlock(sx,sy,sz) == BlockId.air);
    assert(world.getBlock(sx,sy+1,sz) == BlockId.air);

    int minimum = int.max, maximum = int.min, caveAir;
    foreach(coordinate;world.loadedChunkCoordinates())
    foreach(localX;0..Chunk.width) foreach(localZ;0..Chunk.depth)
    {
        const x=coordinate.x*Chunk.width+localX;
        const z=coordinate.z*Chunk.depth+localZ;
        int top = world.minimumBuildY()-1;
        foreach_reverse(y;world.minimumBuildY()..world.maximumBuildY()+1)
            if(world.getBlock(x,y,z)==BlockId.grass){top=y;break;}
        if(top<world.minimumBuildY())continue;
        if(top<minimum) minimum=top;
        if(top>maximum) maximum=top;
        foreach(y;world.minimumBuildY()+5..top-3)
            if(world.getBlock(x,y,z)==BlockId.air) ++caveAir;
        assert(world.getBlock(x,world.minimumBuildY(),z)==BlockId.bedrock);
    }
    assert(maximum-minimum >= 4);
    assert(caveAir > 0);
    world.save();
    const original = world.chunk.snapshot();
    destroy(world);

    auto loaded = new World(settings,directory);
    scope(exit) destroy(loaded);
    assert(loaded.chunk.snapshot() == original);
    assert(loaded.settings.spawn.x == spawn.x
        && loaded.settings.spawn.y == spawn.y
        && loaded.settings.spawn.z == spawn.z);
    assert(loaded.minimumBuildY()==-64&&loaded.maximumBuildY()==319
        &&loaded.voidDamageY()==-128
        &&loaded.horizontalBorder()==29_999_984);

    const netherDirectory=buildPath(directory,"nether-test");
    auto nether=new World(settings,netherDirectory,DimensionId.nether);
    scope(exit)destroy(nether);
    assert(nether.minimumBuildY()==0&&nether.maximumBuildY()==255
        &&nether.voidDamageY()==-64&&nether.horizontalBorder()==3_749_998);
    foreach(coordinate;nether.loadedChunkCoordinates())
    foreach(localX;0..Chunk.width)foreach(localZ;0..Chunk.depth)
    {
        const x=coordinate.x*Chunk.width+localX;
        const z=coordinate.z*Chunk.depth+localZ;
        assert(nether.getBlock(x,0,z)==BlockId.bedrock);
        assert(nether.getBlock(x,127,z)==BlockId.bedrock);
        assert(nether.getBlock(x,128,z)==BlockId.air);
    }

    auto spectator = new LocalPlayer();
    scope(exit) destroy(spectator);
    spectator.gameMode = GameMode.spectator;
    spectator.flying = true;
    spectator.position = Vec3(sx+.5f,sy,sz+.5f);
    foreach(_;0..20)
        spectator.simulateTick(loaded,true,false,false,false,false,false,false);
    assert(spectator.position.z > sz+2.0f);
    writeln("world generation tests passed: height range ",minimum,"..",
        maximum,", cave air ",caveAir,", spawn ",spawn);
}
