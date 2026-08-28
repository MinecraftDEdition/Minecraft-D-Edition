module world_generation_smoke;

import std.file : exists, getcwd, rmdirRecurse;
import std.path : buildPath;
import std.stdio : writeln;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.common.math3d : Vec3;
import minecraftd.world.block : BlockId;
import minecraftd.world.chunk : Chunk;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : GameMode, WorldSettings;

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

    int minimum = Chunk.height, maximum, caveAir;
    foreach(x;0..Chunk.width) foreach(z;0..Chunk.depth)
    {
        int top = -1;
        foreach_reverse(y;0..Chunk.height)
            if(world.getBlock(x,y,z)!=BlockId.air){top=y;break;}
        if(top<minimum) minimum=top;
        if(top>maximum) maximum=top;
        foreach(y;2..top-3)
            if(world.getBlock(x,y,z)==BlockId.air) ++caveAir;
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
