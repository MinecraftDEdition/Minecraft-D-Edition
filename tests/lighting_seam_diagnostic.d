module lighting_seam_diagnostic;
import std.stdio:writeln;
import minecraftd.world.world:World;
import minecraftd.world.chunk:ChunkCoordinate;
import minecraftd.world.block:BlockId;
import minecraftd.client.render.world_lighting:WorldLighting;

// Diagnostic, not a passing correctness test for the lighting system.
// Run against the current renderer to reproduce the invalidation mismatch.
void main()
{
    auto world=new World();scope(exit)destroy(world);
    world.clearChunks();
    world.setBlock(12,200,8,BlockId.stone);
    world.setBlock(16,200,8,BlockId.stone);
    auto light=new WorldLighting(world);scope(exit)destroy(light);
    light.prepare(ChunkCoordinate(1,0));
    const beforeLight=light.blockLevelAt(16,201,8);
    const beforeMesh=world.chunkRevision(1,0);
    world.setBlock(12,201,8,BlockId.fire);
    light.refresh();light.prepare(ChunkCoordinate(1,0));
    const afterLight=light.blockLevelAt(16,201,8);
    const afterMesh=world.chunkRevision(1,0);
    writeln("Neighbor light: ",beforeLight," -> ",afterLight,
        "; neighbor mesh revision: ",beforeMesh," -> ",afterMesh);
    assert(beforeLight==0&&afterLight>0&&beforeMesh==afterMesh,
        "Reproduction changed: re-evaluate diagnosis before applying a fix.");
    writeln("CONFIRMED: neighbor light changed without invalidating its resident mesh.");
}
