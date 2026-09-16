module minecraftd.world.generation.biomes;

import minecraftd.world.block : BlockId;

// Released Java 26.2 surface Overworld catalog. Cave/Nether/End biomes are
// deliberately separate from this surface climate classifier.
enum Biome : ubyte
{
    plains, sunflowerPlains, snowyPlains, iceSpikes, desert,
    forest, flowerForest, birchForest, oldGrowthBirchForest, darkForest, paleGarden,
    taiga, snowyTaiga, oldGrowthPineTaiga, oldGrowthSpruceTaiga,
    savanna, savannaPlateau, windsweptSavanna,
    jungle, sparseJungle, bambooJungle, swamp, mangroveSwamp,
    badlands, erodedBadlands, woodedBadlands, meadow, cherryGrove, grove,
    snowySlopes, jaggedPeaks, frozenPeaks, stonyPeaks,
    windsweptHills, windsweptGravellyHills, windsweptForest,
    mushroomFields, beach, snowyBeach, stonyShore, river, frozenRiver,
    ocean, deepOcean, coldOcean, deepColdOcean, frozenOcean, deepFrozenOcean,
    lukewarmOcean, deepLukewarmOcean, warmOcean,
}

enum Tree : ubyte { none, oak, spruce, birch, jungle, acacia, darkOak, mangrove, cherry, paleOak }

struct BiomeDefinition
{
    BlockId surface=BlockId.grass;
    BlockId soil=BlockId.dirt;
    Tree tree=Tree.none;
    // Chance per 8x8 anchor cell, not per block. Keeps meshing/memory bounded.
    uint trees;
    bool tall;
}

BiomeDefinition definition(Biome biome) pure nothrow @safe @nogc
{
    alias B=BlockId;
    switch(biome)
    {
        case Biome.plains, Biome.sunflowerPlains: return BiomeDefinition(B.grass,B.dirt,Tree.oak,3);
        case Biome.forest, Biome.flowerForest: return BiomeDefinition(B.grass,B.dirt,Tree.oak,62);
        case Biome.birchForest: return BiomeDefinition(B.grass,B.dirt,Tree.birch,64);
        case Biome.oldGrowthBirchForest: return BiomeDefinition(B.grass,B.dirt,Tree.birch,65,true);
        case Biome.darkForest: return BiomeDefinition(B.grass,B.dirt,Tree.darkOak,88);
        case Biome.paleGarden: return BiomeDefinition(B.paleMossBlock,B.dirt,Tree.paleOak,85);
        case Biome.taiga: return BiomeDefinition(B.grass,B.dirt,Tree.spruce,62);
        case Biome.oldGrowthPineTaiga, Biome.oldGrowthSpruceTaiga:
            return BiomeDefinition(B.podzol,B.dirt,Tree.spruce,72,true);
        case Biome.snowyTaiga, Biome.grove:
            return BiomeDefinition(B.snowBlock,B.dirt,Tree.spruce,48);
        case Biome.snowyPlains, Biome.iceSpikes, Biome.snowySlopes,
             Biome.frozenPeaks, Biome.jaggedPeaks: return BiomeDefinition(B.snowBlock,B.dirt);
        case Biome.desert, Biome.beach: return BiomeDefinition(B.sand,B.sandstone);
        case Biome.snowyBeach: return BiomeDefinition(B.snowBlock,B.sand);
        case Biome.stonyShore, Biome.stonyPeaks, Biome.windsweptHills:
            return BiomeDefinition(B.stone,B.stone);
        case Biome.windsweptGravellyHills: return BiomeDefinition(B.gravel,B.stone);
        case Biome.windsweptForest: return BiomeDefinition(B.grass,B.stone,Tree.spruce,25);
        case Biome.savanna, Biome.savannaPlateau, Biome.windsweptSavanna:
            return BiomeDefinition(B.grass,B.dirt,Tree.acacia,18);
        case Biome.jungle, Biome.bambooJungle: return BiomeDefinition(B.grass,B.dirt,Tree.jungle,83,true);
        case Biome.sparseJungle: return BiomeDefinition(B.grass,B.dirt,Tree.jungle,26);
        case Biome.swamp: return BiomeDefinition(B.mud,B.dirt,Tree.oak,27);
        case Biome.mangroveSwamp: return BiomeDefinition(B.mud,B.clay,Tree.mangrove,55);
        case Biome.badlands, Biome.erodedBadlands: return BiomeDefinition(B.redSand,B.redSandstone);
        case Biome.woodedBadlands: return BiomeDefinition(B.coarseDirt,B.redSandstone,Tree.oak,18);
        case Biome.meadow: return BiomeDefinition(B.grass,B.dirt,Tree.oak,2);
        case Biome.cherryGrove: return BiomeDefinition(B.grass,B.dirt,Tree.cherry,58);
        case Biome.mushroomFields: return BiomeDefinition(B.mycelium,B.dirt);
        case Biome.warmOcean, Biome.lukewarmOcean, Biome.deepLukewarmOcean:
            return BiomeDefinition(B.sand,B.sandstone);
        default: return BiomeDefinition(B.gravel,B.stone);
    }
}

Biome selectBiome(double temperature,double humidity,double variation,
    double erosion,double height,bool ocean,bool river) pure nothrow @safe @nogc
{
    if(ocean)
    {
        const deep=height<42;
        if(temperature<-.38)return deep?Biome.deepFrozenOcean:Biome.frozenOcean;
        if(temperature<-.13)return deep?Biome.deepColdOcean:Biome.coldOcean;
        if(temperature>.42)return deep?Biome.deepLukewarmOcean:Biome.warmOcean;
        if(temperature>.16)return deep?Biome.deepLukewarmOcean:Biome.lukewarmOcean;
        return deep?Biome.deepOcean:Biome.ocean;
    }
    if(river)return temperature<-.32?Biome.frozenRiver:Biome.river;
    if(height>154)
        return temperature>.24?Biome.stonyPeaks:variation>.12?Biome.jaggedPeaks:Biome.frozenPeaks;
    if(height>122 && temperature<.18)return humidity>0?Biome.grove:Biome.snowySlopes;
    if(height<66)
    {
        if(temperature<-.3)return Biome.snowyBeach;
        if(erosion<-.25)return Biome.stonyShore;
        if(humidity>.23 && temperature>-.15)return temperature>.22?Biome.mangroveSwamp:Biome.swamp;
        return Biome.beach;
    }
    if(temperature<-.3)
        return humidity>.03?Biome.snowyTaiga:variation>.4?Biome.iceSpikes:Biome.snowyPlains;
    if(temperature>.3)
    {
        if(humidity<-.22)
        {
            if(variation>.12)return variation>.4?Biome.erodedBadlands:Biome.badlands;
            return Biome.desert;
        }
        if(humidity<.06)
            return height>115?Biome.windsweptSavanna:height>91?Biome.savannaPlateau:Biome.savanna;
        if(humidity>.32)return Biome.bambooJungle;
        return humidity>.15?Biome.jungle:Biome.sparseJungle;
    }
    if(temperature>.17 && humidity<-.2 && variation>.3)return Biome.woodedBadlands;
    if(height>112)
        return humidity>.15?Biome.windsweptForest:variation>.15?Biome.windsweptGravellyHills:Biome.windsweptHills;
    if(height>92 && temperature>-.12)
        return humidity>.15?Biome.cherryGrove:Biome.meadow;
    if(temperature<-.1)
        return humidity>.2?(variation>0?Biome.oldGrowthSpruceTaiga:Biome.oldGrowthPineTaiga):Biome.taiga;
    if(humidity>.33)return variation>.25?Biome.paleGarden:Biome.darkForest;
    if(humidity>.08)
    {
        if(variation<-.25)return Biome.oldGrowthBirchForest;
        if(variation<-.02)return Biome.birchForest;
        return variation>.3?Biome.flowerForest:Biome.forest;
    }
    return variation>.25?Biome.sunflowerPlains:Biome.plains;
}
