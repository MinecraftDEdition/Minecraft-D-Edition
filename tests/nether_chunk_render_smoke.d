module nether_chunk_render_smoke;

import core.time : MonoTime;
import std.stdio : writeln;

import minecraftd.client.render.block_renderer : BlockRenderer, BlockTextureSet;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : DimensionId;

void main()
{
    auto world=new World();
    scope(exit)destroy(world);
    world.dimension=DimensionId.nether;
    world.generateNether();
    auto renderer=new BlockRenderer(world);
    scope(exit)destroy(renderer);

    BlockTextureSet textures;
    textures.netherrack=101;
    textures.bedrock=102;
    size_t vertices;
    long maximumSectionMicroseconds;
    foreach(coordinate;world.loadedChunkCoordinates())
    {
        const loaded=world.chunkAt(coordinate.x,coordinate.z);
        assert(loaded !is null&&!loaded.empty);
        assert(loaded.minimumOccupiedY()==0);
        assert(loaded.maximumOccupiedY()==127);
        typeof(renderer.buildChunk(textures,coordinate)) mesh;
        for(int y=loaded.minimumOccupiedY();y<=loaded.maximumOccupiedY();y+=16)
        {
            const started=MonoTime.currTime;
            const part=renderer.buildChunkRange(textures,coordinate,y,y+15);
            renderer.buildPortalsChunkRange(coordinate,y,y+15);
            renderer.buildWaterChunkRange(coordinate,y,y+15);
            const micros=(MonoTime.currTime-started).total!"usecs";
            if(micros>maximumSectionMicroseconds)
                maximumSectionMicroseconds=micros;
            foreach(texture,geometry;part)mesh[texture]~=geometry;
        }
        auto netherrack=101 in mesh;
        auto bedrock=102 in mesh;
        assert(netherrack !is null&&netherrack.length>0);
        assert(bedrock !is null&&bedrock.length>0);
        foreach(texture,geometry;mesh)vertices+=geometry.length;
    }
    writeln("Nether chunk render smoke passed: ",vertices,
        " vertices across 9 chunks; slowest streamed section ",
        maximumSectionMicroseconds/1000.0," ms");
}
