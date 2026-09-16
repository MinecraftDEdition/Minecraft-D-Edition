module foliage_smoke;
import std.stdio : writeln;
import minecraftd.world.world;
import minecraftd.world.chunk;
import minecraftd.world.block;
import minecraftd.client.render.block_renderer;
import minecraftd.client.render.world_lighting;

void main()
{
    auto world=new World();scope(exit)destroy(world);
    world.clearChunks();world.installDetachedChunk(new Chunk(0,0));
    world.setBlock(8,8,8,BlockId.oakLeaves);
    foreach(d;[[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],[0,0,-1],[0,0,1]])
        world.setBlock(8+d[0],8+d[1],8+d[2],BlockId.birchLeaves);
    auto renderer=new BlockRenderer(world);scope(exit)destroy(renderer);
    BlockTextureSet textures;
    textures.catalogSide[BlockId.oakLeaves]=100;
    textures.catalogTop[BlockId.oakLeaves]=100;
    textures.catalogBottom[BlockId.oakLeaves]=100;
    textures.catalogSide[BlockId.birchLeaves]=101;
    textures.catalogTop[BlockId.birchLeaves]=101;
    textures.catalogBottom[BlockId.birchLeaves]=101;
    const mesh=renderer.buildChunk(textures,ChunkCoordinate(0,0));
    assert(mesh[100].length==36,"A leaf surrounded by leaves must retain all six faces");
    foreach(d;[[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],[0,0,-1],[0,0,1]])
        world.setBlock(8+d[0],8+d[1],8+d[2],BlockId.stone);
    assert(renderer.buildChunk(textures,ChunkCoordinate(0,0))[100].length==36);
    world.clearChunks();
    foreach(z;0..2)foreach(x;0..2)world.installDetachedChunk(new Chunk(x,z));
    foreach(z;0..32)foreach(x;0..32)world.setBlock(x,0,z,BlockId.grass);
    foreach(z;4..28)foreach(x;4..28)world.setBlock(x,6,z,BlockId.oakLeaves);
    auto light=new WorldLighting(world);scope(exit)destroy(light);
    const shaded=light.skyLevelAt(16,1,16),open=light.skyLevelAt(1,1,1);
    assert(shaded<open&&open==15,"A leaf canopy must shade the ground");
    writeln("PASS: six faces against leaves/stone; canopy skylight ",shaded," vs open ",open);
}
