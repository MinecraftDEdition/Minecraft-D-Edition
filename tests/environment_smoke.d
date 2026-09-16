module environment_smoke;
import std.stdio : writeln;
import std.math : abs;
import minecraftd.world.world;
import minecraftd.world.chunk;
import minecraftd.world.block;
import minecraftd.common.math3d;
import minecraftd.common.aabb;
import minecraftd.client.player.local_player;
import minecraftd.client.render.world_lighting;
import minecraftd.client.render.block_renderer;
import minecraftd.client.render.sky_renderer;
import minecraftd.client.render.mesh;
import minecraftd.client.render.texture_manager;
import minecraftd.world.generation.trees;
import minecraftd.world.generation.overworld : columnAt;
import minecraftd.world.generation.biomes;
import minecraftd.world.world_settings;

void main()
{
    auto world=new World();scope(exit)destroy(world);world.clearChunks();
    foreach(z;-1..2)foreach(x;-1..3)world.installDetachedChunk(new Chunk(x,z));
    foreach(z;-16..32)foreach(x;-16..48)
    {world.setBlock(x,0,z,BlockId.stone);world.setBlock(x,8,z,BlockId.stone);}
    world.setBlock(20,8,8,BlockId.air);
    auto light=new WorldLighting(world);scope(exit)destroy(light);
    light.prepare(ChunkCoordinate(0,0));
    const left=light.skyLevelAt(15,7,8),border=light.skyLevelAt(16,7,8);
    light.prepare(ChunkCoordinate(1,0));
    assert(left>0&&abs(cast(int)border-left)<=1);
    assert(light.skyLevelAt(16,7,8)==border,"Shared samples must match across lighting caches");
    world.setBlock(15,1,8,BlockId.fire);
    auto blocks=new BlockRenderer(world);scope(exit)destroy(blocks);
    const fire=blocks.buildFireChunkRange(ChunkCoordinate(0,0),0,16);
    assert(fire.layer0.length+fire.layer1.length==48,"Fire must include four inner and four upright double-sided sheets");
    world.clearChunks();world.installDetachedChunk(new Chunk(0,0));
    const stopped=world.collide(Aabb(15.1f,1,8,15.7f,2.8f,8.6f),Vec3(4,0,0));
    assert(stopped.hitX&&abs(stopped.movement.x-.3f)<.0001f,"Unloaded chunks must block traversal");
    world.setBlock(8,1,8,BlockId.glass);
    const rounded=world.collide(Aabb(7.4f,1,8.1f,8.000001f,2.8f,8.7f),Vec3(.3f,0,0));
    assert(rounded.hitX&&rounded.movement.x<=0,"Tiny boundary penetration must not disable collision");
    float travel(BlockId floor)
    {
        world.clearChunks();
        foreach(z;0..4)world.installDetachedChunk(new Chunk(0,z));
        foreach(z;0..64)foreach(x;0..16)world.setBlock(x,0,z,floor);
        auto player=new LocalPlayer();scope(exit)destroy(player);
        player.position=player.previousPosition=Vec3(8,1,8);
        player.onGround=true;player.velocity=Vec3(0,0,4);
        foreach(_;0..20)player.simulateTick(world,0,0,false,false,false);
        return player.position.z-8;
    }
    const normal=travel(BlockId.stone),packed=travel(BlockId.packedIce),blue=travel(BlockId.blueIce);
    assert(packed>normal*3&&blue>packed,"Ice must preserve momentum, with blue ice slipperier");
    auto sky=new SkyRenderer(ImageData.init);
    const fog=Color(.75f,.85f,1,1),clear=Color(.48f,.7f,1,1);
    const horizon=sky.buildHorizon(Vec3(0,0,0),fog,clear);
    bool hasFog,hasClear;
    foreach(v;horizon){hasFog|=v.color[0]==fog.r;hasClear|=v.color[0]==clear.r;}
    assert(hasFog&&hasClear);destroy(sky);
    WorldSettings settings;settings.seed=42;
    int forestX,forestZ;bool found;
    foreach(z;-48..49){foreach(x;-48..49)
    {
        const c=columnAt(x*64,z*64,settings);
        if(!c.water&&definition(c.biome).tree==Tree.spruce)
        {forestX=x*4;forestZ=z*4;found=true;break;}
    }if(found)break;}
    assert(found);size_t spruceTrunks;
    foreach(z;forestZ-2..forestZ+3)foreach(x;forestX-2..forestX+3)
    {
        auto chunk=new Chunk(x,z);generateTrees(chunk,settings);
        foreach(lz;0..16)foreach(lx;0..16)
        {
            int run;
            foreach(y;-64..320)
            {
                if(chunk.get(lx,y,lz)==BlockId.spruceLog)++run;
                else if(run)
                {
                    assert(run>=6&&run<=11,"Spruce trunk exceeded controlled height");
                    assert(chunk.get(lx,y,lz)==BlockId.spruceLeaves,"Spruce needs a leafy tip");
                    ++spruceTrunks;run=0;
                }
            }
        }
        destroy(chunk);
    }
    assert(spruceTrunks>0);
    writeln("PASS: cross-chunk skylight, floor fire geometry, collision, ice coasting, horizon gradient");
    writeln("PASS: ",spruceTrunks," spruce trunks within height limits with leafy tips");
}
