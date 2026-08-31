module minecraftd.world.block;

enum BlockId : ubyte
{
    air,
    grass,
    dirt,
    stone,
    obsidian,
    netherrack,
    netherPortalX,
    netherPortalZ,
    waterSource,
    waterFlow1,
    waterFlow2,
    waterFlow3,
    waterFlow4,
    waterFlow5,
    waterFlow6,
    waterFlow7,
    waterFalling,
    bricks,
    oakPlanks,
    sprucePlanks,
    birchPlanks,
    junglePlanks,
    acaciaPlanks,
    darkOakPlanks,
    mangrovePlanks,
    cherryPlanks,
    bambooPlanks,
    paleOakPlanks,
    crimsonPlanks,
    warpedPlanks,
    cobblestone,
    glass,
}

struct BlockSoundType
{
    string family;
    float volume;
    float pitch;
}

BlockSoundType soundType(BlockId block)
{
    // Vanilla assignments for the blocks currently implemented here.
    final switch (block)
    {
        case BlockId.air: return BlockSoundType("stone", 0.0f, 1.0f);
        case BlockId.grass: return BlockSoundType("grass", 1.0f, 1.0f);
        case BlockId.dirt: return BlockSoundType("gravel", 1.0f, 1.0f);
        case BlockId.stone: return BlockSoundType("stone", 1.0f, 1.0f);
        case BlockId.obsidian: return BlockSoundType("stone", 1.0f, 1.0f);
        case BlockId.netherrack: return BlockSoundType("netherrack", 1.0f, 1.0f);
        case BlockId.netherPortalX, BlockId.netherPortalZ:
            return BlockSoundType("stone", 0.0f, 1.0f);
        case BlockId.waterSource, BlockId.waterFlow1, BlockId.waterFlow2,
             BlockId.waterFlow3, BlockId.waterFlow4, BlockId.waterFlow5,
             BlockId.waterFlow6, BlockId.waterFlow7, BlockId.waterFalling:
            return BlockSoundType("stone", 0.0f, 1.0f);
        case BlockId.bricks, BlockId.cobblestone:
            return BlockSoundType("stone", 1.0f, 1.0f);
        case BlockId.oakPlanks, BlockId.sprucePlanks, BlockId.birchPlanks,
             BlockId.junglePlanks, BlockId.acaciaPlanks, BlockId.darkOakPlanks,
             BlockId.mangrovePlanks, BlockId.paleOakPlanks:
            return BlockSoundType("wood", 1.0f, 1.0f);
        case BlockId.cherryPlanks:
            return BlockSoundType("cherry_wood", 1.0f, 1.0f);
        case BlockId.bambooPlanks:
            return BlockSoundType("bamboo_wood", 1.0f, 1.0f);
        case BlockId.crimsonPlanks, BlockId.warpedPlanks:
            return BlockSoundType("nether_wood", 1.0f, 1.0f);
        case BlockId.glass:
            return BlockSoundType("glass", 1.0f, 1.0f);
    }
}

bool isOpaque(BlockId block)
{
    return block != BlockId.air && block != BlockId.netherPortalX
        && block != BlockId.netherPortalZ && block != BlockId.glass
        && !isWater(block);
}

bool isSolid(BlockId block)
{
    return isOpaque(block) || block == BlockId.glass;
}

bool isNetherPortal(BlockId block)
{
    return block == BlockId.netherPortalX || block == BlockId.netherPortalZ;
}

bool isWater(BlockId block)
{
    return block >= BlockId.waterSource && block <= BlockId.waterFalling;
}

bool isWaterSource(BlockId block)
{
    return block == BlockId.waterSource;
}

/// Java's flowing-water amount is 8 for a source/falling column and 7..1 for
/// legacy levels 1..7. Its own surface height is amount / 9.
float waterHeight(BlockId block)
{
    if (block == BlockId.waterSource || block == BlockId.waterFalling)
        return 8.0f / 9.0f;
    if (block >= BlockId.waterFlow1 && block <= BlockId.waterFlow7)
        return cast(float)(8 - (cast(int)block-cast(int)BlockId.waterSource)) / 9.0f;
    return 0.0f;
}

int waterLevel(BlockId block)
{
    if (block == BlockId.waterSource) return 0;
    if (block >= BlockId.waterFlow1 && block <= BlockId.waterFlow7)
        return cast(int)block-cast(int)BlockId.waterSource;
    return block == BlockId.waterFalling ? 8 : -1;
}

BlockId waterForLevel(int level, bool falling = false)
{
    if (falling) return BlockId.waterFalling;
    if (level <= 0) return BlockId.waterSource;
    if (level > 7) return BlockId.air;
    return cast(BlockId)(cast(int)BlockId.waterSource + level);
}

float hardness(BlockId block)
{
    final switch (block)
    {
        case BlockId.air: return -1.0f;
        case BlockId.grass: return 0.6f;
        case BlockId.dirt: return 0.5f;
        case BlockId.stone: return 1.5f;
        case BlockId.obsidian: return 50.0f;
        case BlockId.netherrack: return 0.4f;
        case BlockId.netherPortalX, BlockId.netherPortalZ: return -1.0f;
        case BlockId.waterSource, BlockId.waterFlow1, BlockId.waterFlow2,
             BlockId.waterFlow3, BlockId.waterFlow4, BlockId.waterFlow5,
             BlockId.waterFlow6, BlockId.waterFlow7, BlockId.waterFalling:
            return -1.0f;
        case BlockId.bricks, BlockId.oakPlanks, BlockId.sprucePlanks,
             BlockId.birchPlanks, BlockId.junglePlanks, BlockId.acaciaPlanks,
             BlockId.darkOakPlanks, BlockId.mangrovePlanks,
             BlockId.cherryPlanks, BlockId.bambooPlanks,
             BlockId.paleOakPlanks, BlockId.crimsonPlanks,
             BlockId.warpedPlanks, BlockId.cobblestone:
            return 2.0f;
        case BlockId.glass: return 0.3f;
    }
}

/// Vanilla BlockBehaviour.getDestroyProgress for an empty hand. Grass and
/// dirt are correctly harvestable by hand (divisor 30); stone is not
/// (divisor 100), though it may still be broken without producing a drop.
float bareHandDestroyProgress(BlockId block)
{
    const value = hardness(block);
    if (value < 0.0f)
        return 0.0f;
    const correctTool = block != BlockId.stone && block != BlockId.obsidian
        && block != BlockId.bricks && block != BlockId.cobblestone;
    return 1.0f / value / (correctTool ? 30.0f : 100.0f);
}

enum FallSurface : ubyte
{
    normal,
    hay,
    honey,
    bed,
    slime,
    stalagmite,
}

struct FallRule
{
    float multiplier;
    float addedDistance;
    bool bounces;
}

FallRule fallRule(FallSurface surface)
{
    final switch (surface)
    {
        case FallSurface.normal: return FallRule(1.0f, 0.0f, false);
        case FallSurface.hay, FallSurface.honey: return FallRule(0.2f, 0.0f, false);
        case FallSurface.bed: return FallRule(0.5f, 0.0f, true);
        case FallSurface.slime: return FallRule(0.0f, 0.0f, true);
        case FallSurface.stalagmite: return FallRule(2.0f, 2.0f, false);
    }
}

/// The current prototype palette contains only ordinary landing surfaces.
/// New registered blocks map to the rules above in this one dispatcher.
FallSurface fallSurface(BlockId block)
{
    final switch (block)
    {
        case BlockId.air, BlockId.grass, BlockId.dirt, BlockId.stone,
             BlockId.obsidian, BlockId.netherrack, BlockId.netherPortalX,
             BlockId.netherPortalZ, BlockId.waterSource, BlockId.waterFlow1,
             BlockId.waterFlow2, BlockId.waterFlow3, BlockId.waterFlow4,
             BlockId.waterFlow5, BlockId.waterFlow6, BlockId.waterFlow7,
             BlockId.waterFalling, BlockId.bricks, BlockId.oakPlanks,
             BlockId.sprucePlanks, BlockId.birchPlanks, BlockId.junglePlanks,
             BlockId.acaciaPlanks, BlockId.darkOakPlanks,
             BlockId.mangrovePlanks, BlockId.cherryPlanks,
             BlockId.bambooPlanks, BlockId.paleOakPlanks,
             BlockId.crimsonPlanks, BlockId.warpedPlanks,
             BlockId.cobblestone, BlockId.glass:
            return FallSurface.normal;
    }
}

float fallDamageMultiplier(BlockId block)
{
    return fallRule(fallSurface(block)).multiplier;
}

unittest
{
    import core.stdc.math : fabsf;
    assert(fabsf(bareHandDestroyProgress(BlockId.dirt) - 1.0f / 15.0f) < 0.00001f);
    assert(fabsf(bareHandDestroyProgress(BlockId.grass) - 1.0f / 18.0f) < 0.00001f);
    assert(fabsf(bareHandDestroyProgress(BlockId.stone) - 1.0f / 150.0f) < 0.00001f);
    assert(fallRule(FallSurface.hay).multiplier == 0.2f);
    assert(fallRule(FallSurface.bed).multiplier == 0.5f);
    assert(fallRule(FallSurface.slime).multiplier == 0.0f);
    assert(fallRule(FallSurface.stalagmite).addedDistance == 2.0f);
    assert(isWater(BlockId.waterFlow4));
    assert(waterLevel(BlockId.waterSource)==0);
    assert(waterLevel(BlockId.waterFlow7)==7);
    assert(fabsf(waterHeight(BlockId.waterSource)-8.0f/9.0f)<0.00001f);
    assert(fabsf(waterHeight(BlockId.waterFlow7)-1.0f/9.0f)<0.00001f);
    assert(isSolid(BlockId.glass) && !isOpaque(BlockId.glass));
    assert(hardness(BlockId.glass) == 0.3f);
    assert(hardness(BlockId.bricks) == 2.0f);
    assert(soundType(BlockId.cherryPlanks).family == "cherry_wood");
    assert(soundType(BlockId.bambooPlanks).family == "bamboo_wood");
    assert(soundType(BlockId.crimsonPlanks).family == "nether_wood");
    assert(soundType(BlockId.glass).family == "glass");
}
