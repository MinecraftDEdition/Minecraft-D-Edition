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
    bedrock,
    fire,

    // Static full-cube registry. Keep this range contiguous: save files and
    // multiplayer packets currently store one byte per block.
    coarseDirt, rootedDirt, podzol, mycelium, mud, clay, sand, redSand, gravel,
    mossBlock, paleMossBlock, packedMud, mudBricks,
    granite, polishedGranite, diorite, polishedDiorite, andesite,
    polishedAndesite, deepslate, cobbledDeepslate, polishedDeepslate,
    deepslateBricks, crackedDeepslateBricks, deepslateTiles,
    crackedDeepslateTiles, chiseledDeepslate, calcite, tuff, polishedTuff,
    tuffBricks, chiseledTuff, chiseledTuffBricks, dripstoneBlock,
    sandstone, chiseledSandstone, cutSandstone, smoothSandstone,
    redSandstone, chiseledRedSandstone, cutRedSandstone, smoothRedSandstone,
    stoneBricks, crackedStoneBricks, mossyStoneBricks, chiseledStoneBricks,
    mossyCobblestone,
    coalOre, ironOre, copperOre, goldOre, redstoneOre, emeraldOre, lapisOre,
    diamondOre, deepslateCoalOre, deepslateIronOre, deepslateCopperOre,
    deepslateGoldOre, deepslateRedstoneOre, deepslateEmeraldOre,
    deepslateLapisOre, deepslateDiamondOre,
    coalBlock, ironBlock, rawIronBlock, copperBlock, rawCopperBlock,
    goldBlock, rawGoldBlock, emeraldBlock, lapisBlock, diamondBlock,
    netheriteBlock, amethystBlock,
    soulSoil, basalt, polishedBasalt, smoothBasalt, blackstone,
    polishedBlackstone, polishedBlackstoneBricks,
    crackedPolishedBlackstoneBricks, chiseledPolishedBlackstone,
    gildedBlackstone, netherBricks, crackedNetherBricks, chiseledNetherBricks,
    redNetherBricks, crimsonNylium, warpedNylium, netherWartBlock,
    warpedWartBlock, netherGoldOre, netherQuartzOre, ancientDebris,
    endStone, endStoneBricks, purpurBlock, quartzBlock, chiseledQuartzBlock,
    smoothQuartzBlock, quartzBricks, prismarineBricks,
    darkPrismarine, snowBlock, resinBlock, resinBricks,
    chiseledResinBricks, cinnabar, polishedCinnabar, cinnabarBricks,
    chiseledCinnabar, sulfur, polishedSulfur, sulfurBricks, chiseledSulfur,
    whiteWool, lightGrayWool, grayWool, blackWool, brownWool, redWool,
    orangeWool, yellowWool, limeWool, greenWool, cyanWool, lightBlueWool,
    blueWool, purpleWool, magentaWool, pinkWool,
    whiteConcrete, lightGrayConcrete, grayConcrete, blackConcrete,
    brownConcrete, redConcrete, orangeConcrete, yellowConcrete, limeConcrete,
    greenConcrete, cyanConcrete, lightBlueConcrete, blueConcrete,
    purpleConcrete, magentaConcrete, pinkConcrete,
    whiteTerracotta, lightGrayTerracotta, grayTerracotta, blackTerracotta,
    brownTerracotta, redTerracotta, orangeTerracotta, yellowTerracotta,
    limeTerracotta, greenTerracotta, cyanTerracotta, lightBlueTerracotta,
    blueTerracotta, purpleTerracotta, magentaTerracotta, pinkTerracotta,
}

enum BlockId firstCatalogBlock = BlockId.coarseDirt;
enum BlockId lastCatalogBlock = BlockId.pinkTerracotta;
static assert(cast(int)lastCatalogBlock <= ubyte.max,
    "Block registry exceeds the current save/network ID width");

struct CatalogBlockDefinition
{
    string name;
    string sideTexture;
    string topTexture;
    string bottomTexture;
    string soundFamily;
    float hardness;
    bool handHarvestable;
    bool flammable;
}

private pure CatalogBlockDefinition cube(string name, string texture,
    string sound, float hardness, bool handHarvestable = true,
    bool flammable = false)
{
    return CatalogBlockDefinition(name, texture, texture, texture, sound,
        hardness, handHarvestable, flammable);
}

private pure CatalogBlockDefinition sided(string name, string side,
    string top, string bottom, string sound, float hardness,
    bool handHarvestable = true, bool flammable = false)
{
    return CatalogBlockDefinition(name, side, top, bottom, sound, hardness,
        handHarvestable, flammable);
}

// This table is deliberately ordered exactly like the contiguous enum range.
// It is the shared source of names, textures, sound material, hardness and
// harvesting rules for rendering, inventory, particles and gameplay.
immutable CatalogBlockDefinition[] catalogBlockDefinitions = [
    cube("Coarse Dirt", "coarse_dirt", "gravel", .5f),
    cube("Rooted Dirt", "rooted_dirt", "rooted_dirt", .5f),
    sided("Podzol", "podzol_side", "podzol_top", "dirt", "gravel", .5f),
    sided("Mycelium", "mycelium_side", "mycelium_top", "dirt", "grass", .6f),
    cube("Mud", "mud", "mud", .5f), cube("Clay", "clay", "gravel", .6f),
    cube("Sand", "sand", "sand", .5f), cube("Red Sand", "red_sand", "sand", .5f),
    cube("Gravel", "gravel", "gravel", .6f),
    cube("Moss Block", "moss_block", "moss", .1f),
    cube("Pale Moss Block", "pale_moss_block", "moss", .1f),
    cube("Packed Mud", "packed_mud", "packed_mud", 1f),
    cube("Mud Bricks", "mud_bricks", "mud_bricks", 1.5f),
    cube("Granite", "granite", "stone", 1.5f, false),
    cube("Polished Granite", "polished_granite", "stone", 1.5f, false),
    cube("Diorite", "diorite", "stone", 1.5f, false),
    cube("Polished Diorite", "polished_diorite", "stone", 1.5f, false),
    cube("Andesite", "andesite", "stone", 1.5f, false),
    cube("Polished Andesite", "polished_andesite", "stone", 1.5f, false),
    sided("Deepslate", "deepslate", "deepslate_top", "deepslate_top", "deepslate", 3f, false),
    cube("Cobbled Deepslate", "cobbled_deepslate", "deepslate", 3.5f, false),
    cube("Polished Deepslate", "polished_deepslate", "deepslate", 3.5f, false),
    cube("Deepslate Bricks", "deepslate_bricks", "deepslate", 3.5f, false),
    cube("Cracked Deepslate Bricks", "cracked_deepslate_bricks", "deepslate", 3.5f, false),
    cube("Deepslate Tiles", "deepslate_tiles", "deepslate", 3.5f, false),
    cube("Cracked Deepslate Tiles", "cracked_deepslate_tiles", "deepslate", 3.5f, false),
    cube("Chiseled Deepslate", "chiseled_deepslate", "deepslate", 3.5f, false),
    cube("Calcite", "calcite", "calcite", .75f, false),
    cube("Tuff", "tuff", "tuff", 1.5f, false),
    cube("Polished Tuff", "polished_tuff", "tuff", 1.5f, false),
    cube("Tuff Bricks", "tuff_bricks", "tuff", 1.5f, false),
    sided("Chiseled Tuff", "chiseled_tuff", "chiseled_tuff_top", "chiseled_tuff_top", "tuff", 1.5f, false),
    sided("Chiseled Tuff Bricks", "chiseled_tuff_bricks", "chiseled_tuff_bricks_top", "chiseled_tuff_bricks_top", "tuff", 1.5f, false),
    cube("Dripstone Block", "dripstone_block", "dripstone", 1.5f, false),
    sided("Sandstone", "sandstone", "sandstone_top", "sandstone_bottom", "stone", .8f, false),
    cube("Chiseled Sandstone", "chiseled_sandstone", "stone", .8f, false),
    cube("Cut Sandstone", "cut_sandstone", "stone", .8f, false),
    sided("Smooth Sandstone", "sandstone_top", "sandstone_top", "sandstone_top", "stone", 2f, false),
    sided("Red Sandstone", "red_sandstone", "red_sandstone_top", "red_sandstone_bottom", "stone", .8f, false),
    cube("Chiseled Red Sandstone", "chiseled_red_sandstone", "stone", .8f, false),
    cube("Cut Red Sandstone", "cut_red_sandstone", "stone", .8f, false),
    sided("Smooth Red Sandstone", "red_sandstone_top", "red_sandstone_top", "red_sandstone_top", "stone", 2f, false),
    cube("Stone Bricks", "stone_bricks", "stone", 1.5f, false),
    cube("Cracked Stone Bricks", "cracked_stone_bricks", "stone", 1.5f, false),
    cube("Mossy Stone Bricks", "mossy_stone_bricks", "stone", 1.5f, false),
    cube("Chiseled Stone Bricks", "chiseled_stone_bricks", "stone", 1.5f, false),
    cube("Mossy Cobblestone", "mossy_cobblestone", "stone", 2f, false),
    cube("Coal Ore", "coal_ore", "stone", 3f, false),
    cube("Iron Ore", "iron_ore", "stone", 3f, false),
    cube("Copper Ore", "copper_ore", "stone", 3f, false),
    cube("Gold Ore", "gold_ore", "stone", 3f, false),
    cube("Redstone Ore", "redstone_ore", "stone", 3f, false),
    cube("Emerald Ore", "emerald_ore", "stone", 3f, false),
    cube("Lapis Lazuli Ore", "lapis_ore", "stone", 3f, false),
    cube("Diamond Ore", "diamond_ore", "stone", 3f, false),
    cube("Deepslate Coal Ore", "deepslate_coal_ore", "deepslate", 4.5f, false),
    cube("Deepslate Iron Ore", "deepslate_iron_ore", "deepslate", 4.5f, false),
    cube("Deepslate Copper Ore", "deepslate_copper_ore", "deepslate", 4.5f, false),
    cube("Deepslate Gold Ore", "deepslate_gold_ore", "deepslate", 4.5f, false),
    cube("Deepslate Redstone Ore", "deepslate_redstone_ore", "deepslate", 4.5f, false),
    cube("Deepslate Emerald Ore", "deepslate_emerald_ore", "deepslate", 4.5f, false),
    cube("Deepslate Lapis Lazuli Ore", "deepslate_lapis_ore", "deepslate", 4.5f, false),
    cube("Deepslate Diamond Ore", "deepslate_diamond_ore", "deepslate", 4.5f, false),
    cube("Block of Coal", "coal_block", "stone", 5f, false),
    cube("Block of Iron", "iron_block", "stone", 5f, false),
    cube("Block of Raw Iron", "raw_iron_block", "stone", 5f, false),
    cube("Block of Copper", "copper_block", "copper", 3f, false),
    cube("Block of Raw Copper", "raw_copper_block", "stone", 5f, false),
    cube("Block of Gold", "gold_block", "stone", 3f, false),
    cube("Block of Raw Gold", "raw_gold_block", "stone", 5f, false),
    cube("Block of Emerald", "emerald_block", "stone", 5f, false),
    cube("Lapis Lazuli Block", "lapis_block", "stone", 3f, false),
    cube("Block of Diamond", "diamond_block", "stone", 5f, false),
    cube("Block of Netherite", "netherite_block", "netherite", 50f, false),
    cube("Block of Amethyst", "amethyst_block", "amethyst", 1.5f, false),
    cube("Soul Soil", "soul_soil", "soul_soil", .5f),
    sided("Basalt", "basalt_side", "basalt_top", "basalt_top", "basalt", 1.25f, false),
    sided("Polished Basalt", "polished_basalt_side", "polished_basalt_top", "polished_basalt_top", "basalt", 1.25f, false),
    cube("Smooth Basalt", "smooth_basalt", "basalt", 1.25f, false),
    sided("Blackstone", "blackstone", "blackstone_top", "blackstone_top", "stone", 1.5f, false),
    cube("Polished Blackstone", "polished_blackstone", "stone", 2f, false),
    cube("Polished Blackstone Bricks", "polished_blackstone_bricks", "stone", 1.5f, false),
    cube("Cracked Polished Blackstone Bricks", "cracked_polished_blackstone_bricks", "stone", 1.5f, false),
    cube("Chiseled Polished Blackstone", "chiseled_polished_blackstone", "stone", 1.5f, false),
    cube("Gilded Blackstone", "gilded_blackstone", "stone", 1.5f, false),
    cube("Nether Bricks", "nether_bricks", "nether_bricks", 2f, false),
    cube("Cracked Nether Bricks", "cracked_nether_bricks", "nether_bricks", 2f, false),
    cube("Chiseled Nether Bricks", "chiseled_nether_bricks", "nether_bricks", 2f, false),
    cube("Red Nether Bricks", "red_nether_bricks", "nether_bricks", 2f, false),
    sided("Crimson Nylium", "crimson_nylium_side", "crimson_nylium", "netherrack", "nylium", .4f),
    sided("Warped Nylium", "warped_nylium_side", "warped_nylium", "netherrack", "nylium", .4f),
    cube("Nether Wart Block", "nether_wart_block", "netherwart", 1f),
    cube("Warped Wart Block", "warped_wart_block", "netherwart", 1f),
    cube("Nether Gold Ore", "nether_gold_ore", "nether_ore", 3f, false),
    cube("Nether Quartz Ore", "nether_quartz_ore", "nether_ore", 3f, false),
    sided("Ancient Debris", "ancient_debris_side", "ancient_debris_top", "ancient_debris_top", "netherite", 30f, false),
    cube("End Stone", "end_stone", "stone", 3f, false),
    cube("End Stone Bricks", "end_stone_bricks", "stone", 3f, false),
    cube("Purpur Block", "purpur_block", "stone", 1.5f, false),
    sided("Block of Quartz", "quartz_block_side", "quartz_block_top", "quartz_block_bottom", "stone", .8f, false),
    sided("Chiseled Quartz Block", "chiseled_quartz_block", "chiseled_quartz_block_top", "chiseled_quartz_block_top", "stone", .8f, false),
    cube("Smooth Quartz Block", "quartz_block_bottom", "stone", 2f, false),
    cube("Quartz Bricks", "quartz_bricks", "stone", .8f, false),
    cube("Prismarine Bricks", "prismarine_bricks", "stone", 1.5f, false),
    cube("Dark Prismarine", "dark_prismarine", "stone", 1.5f, false),
    cube("Snow Block", "snow", "snow", .2f),
    cube("Block of Resin", "resin_block", "resin", .5f),
    cube("Resin Bricks", "resin_bricks", "resin_bricks", 1.5f, false),
    cube("Chiseled Resin Bricks", "chiseled_resin_bricks", "resin_bricks", 1.5f, false),
    cube("Cinnabar", "cinnabar", "cinnabar", 1.5f, false),
    cube("Polished Cinnabar", "polished_cinnabar", "cinnabar", 1.5f, false),
    cube("Cinnabar Bricks", "cinnabar_bricks", "cinnabar", 1.5f, false),
    cube("Chiseled Cinnabar", "chiseled_cinnabar", "cinnabar", 1.5f, false),
    cube("Sulfur", "sulfur", "sulfur", .5f),
    cube("Polished Sulfur", "polished_sulfur", "sulfur", .5f),
    cube("Sulfur Bricks", "sulfur_bricks", "sulfur", .5f),
    cube("Chiseled Sulfur", "chiseled_sulfur", "sulfur", .5f),

    cube("White Wool", "white_wool", "cloth", .8f, true, true),
    cube("Light Gray Wool", "light_gray_wool", "cloth", .8f, true, true),
    cube("Gray Wool", "gray_wool", "cloth", .8f, true, true),
    cube("Black Wool", "black_wool", "cloth", .8f, true, true),
    cube("Brown Wool", "brown_wool", "cloth", .8f, true, true),
    cube("Red Wool", "red_wool", "cloth", .8f, true, true),
    cube("Orange Wool", "orange_wool", "cloth", .8f, true, true),
    cube("Yellow Wool", "yellow_wool", "cloth", .8f, true, true),
    cube("Lime Wool", "lime_wool", "cloth", .8f, true, true),
    cube("Green Wool", "green_wool", "cloth", .8f, true, true),
    cube("Cyan Wool", "cyan_wool", "cloth", .8f, true, true),
    cube("Light Blue Wool", "light_blue_wool", "cloth", .8f, true, true),
    cube("Blue Wool", "blue_wool", "cloth", .8f, true, true),
    cube("Purple Wool", "purple_wool", "cloth", .8f, true, true),
    cube("Magenta Wool", "magenta_wool", "cloth", .8f, true, true),
    cube("Pink Wool", "pink_wool", "cloth", .8f, true, true),
    cube("White Concrete", "white_concrete", "stone", 1.8f, false),
    cube("Light Gray Concrete", "light_gray_concrete", "stone", 1.8f, false),
    cube("Gray Concrete", "gray_concrete", "stone", 1.8f, false),
    cube("Black Concrete", "black_concrete", "stone", 1.8f, false),
    cube("Brown Concrete", "brown_concrete", "stone", 1.8f, false),
    cube("Red Concrete", "red_concrete", "stone", 1.8f, false),
    cube("Orange Concrete", "orange_concrete", "stone", 1.8f, false),
    cube("Yellow Concrete", "yellow_concrete", "stone", 1.8f, false),
    cube("Lime Concrete", "lime_concrete", "stone", 1.8f, false),
    cube("Green Concrete", "green_concrete", "stone", 1.8f, false),
    cube("Cyan Concrete", "cyan_concrete", "stone", 1.8f, false),
    cube("Light Blue Concrete", "light_blue_concrete", "stone", 1.8f, false),
    cube("Blue Concrete", "blue_concrete", "stone", 1.8f, false),
    cube("Purple Concrete", "purple_concrete", "stone", 1.8f, false),
    cube("Magenta Concrete", "magenta_concrete", "stone", 1.8f, false),
    cube("Pink Concrete", "pink_concrete", "stone", 1.8f, false),
    cube("White Terracotta", "white_terracotta", "stone", 1.25f, false),
    cube("Light Gray Terracotta", "light_gray_terracotta", "stone", 1.25f, false),
    cube("Gray Terracotta", "gray_terracotta", "stone", 1.25f, false),
    cube("Black Terracotta", "black_terracotta", "stone", 1.25f, false),
    cube("Brown Terracotta", "brown_terracotta", "stone", 1.25f, false),
    cube("Red Terracotta", "red_terracotta", "stone", 1.25f, false),
    cube("Orange Terracotta", "orange_terracotta", "stone", 1.25f, false),
    cube("Yellow Terracotta", "yellow_terracotta", "stone", 1.25f, false),
    cube("Lime Terracotta", "lime_terracotta", "stone", 1.25f, false),
    cube("Green Terracotta", "green_terracotta", "stone", 1.25f, false),
    cube("Cyan Terracotta", "cyan_terracotta", "stone", 1.25f, false),
    cube("Light Blue Terracotta", "light_blue_terracotta", "stone", 1.25f, false),
    cube("Blue Terracotta", "blue_terracotta", "stone", 1.25f, false),
    cube("Purple Terracotta", "purple_terracotta", "stone", 1.25f, false),
    cube("Magenta Terracotta", "magenta_terracotta", "stone", 1.25f, false),
    cube("Pink Terracotta", "pink_terracotta", "stone", 1.25f, false),
];

bool isCatalogBlock(BlockId block)
{
    return block >= firstCatalogBlock && block <= lastCatalogBlock;
}

CatalogBlockDefinition catalogBlockDefinition(BlockId block)
{
    if (!isCatalogBlock(block)) return CatalogBlockDefinition.init;
    return catalogBlockDefinitions[cast(size_t)(cast(int)block
        - cast(int)firstCatalogBlock)];
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
    switch (block)
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
        case BlockId.bedrock:
            return BlockSoundType("stone", 1.0f, 1.0f);
        case BlockId.fire:
            return BlockSoundType("stone", 0.0f, 1.0f);
        default:
            const definition = catalogBlockDefinition(block);
            return BlockSoundType(definition.soundFamily, 1.0f, 1.0f);
    }
}

bool isOpaque(BlockId block)
{
    return isCatalogBlock(block) || (block != BlockId.air && block != BlockId.netherPortalX
        && block != BlockId.netherPortalZ && block != BlockId.glass
        && !isWater(block) && block != BlockId.fire);
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

bool isFire(BlockId block)
{
    return block == BlockId.fire;
}

/// Java's ordinary wooden planks burn; crimson and warped planks deliberately
/// do not. Keeping this in the block registry prevents the fire simulator and
/// renderer from growing separate, contradictory material tables.
bool isFlammable(BlockId block)
{
    if (isCatalogBlock(block)) return catalogBlockDefinition(block).flammable;
    return block == BlockId.oakPlanks || block == BlockId.sprucePlanks
        || block == BlockId.birchPlanks || block == BlockId.junglePlanks
        || block == BlockId.acaciaPlanks || block == BlockId.darkOakPlanks
        || block == BlockId.mangrovePlanks || block == BlockId.cherryPlanks
        || block == BlockId.bambooPlanks || block == BlockId.paleOakPlanks;
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
    switch (block)
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
        case BlockId.bedrock: return -1.0f;
        case BlockId.fire: return -1.0f;
        default: return catalogBlockDefinition(block).hardness;
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
    const correctTool = isCatalogBlock(block)
        ? catalogBlockDefinition(block).handHarvestable
        : block != BlockId.stone && block != BlockId.obsidian
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
    switch (block)
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
        case BlockId.bedrock: return FallSurface.normal;
        case BlockId.fire: return FallSurface.normal;
        default: return FallSurface.normal;
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
    assert(isSolid(BlockId.bedrock) && hardness(BlockId.bedrock) < 0.0f);
    assert(!isSolid(BlockId.fire) && isFlammable(BlockId.oakPlanks));
    assert(!isFlammable(BlockId.crimsonPlanks));
    assert(catalogBlockDefinitions.length == cast(size_t)(cast(int)lastCatalogBlock
        - cast(int)firstCatalogBlock + 1));
    assert(catalogBlockDefinition(BlockId.deepslate).sideTexture == "deepslate");
    assert(soundType(BlockId.whiteWool).family == "cloth");
    assert(isFlammable(BlockId.whiteWool));
}
