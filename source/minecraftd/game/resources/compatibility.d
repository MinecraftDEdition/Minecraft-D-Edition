module minecraftd.game.resources.compatibility;

import std.string : startsWith, endsWith, replace, split;
import std.algorithm : sort;

struct LegacySprite { string name,sheet; uint x,y,width,height; }
immutable LegacySprite[] legacySprites=[
    LegacySprite("hud/hotbar","widgets",0,0,182,22),
    LegacySprite("hud/hotbar_selection","widgets",0,22,24,22),
    LegacySprite("hud/crosshair","icons",0,0,15,15),
    LegacySprite("hud/heart/container","icons",16,0,9,9),
    LegacySprite("hud/heart/container_blinking","icons",25,0,9,9),
    LegacySprite("hud/heart/full","icons",52,0,9,9),
    LegacySprite("hud/heart/half","icons",61,0,9,9),
    LegacySprite("hud/heart/full_blinking","icons",70,0,9,9),
    LegacySprite("hud/heart/half_blinking","icons",79,0,9,9),
    LegacySprite("hud/food_empty","icons",16,27,9,9),
    LegacySprite("hud/food_full","icons",52,27,9,9),
    LegacySprite("hud/food_half","icons",61,27,9,9),
    LegacySprite("hud/air","icons",16,18,9,9),
    LegacySprite("hud/air_bursting","icons",25,18,9,9),
    LegacySprite("hud/experience_bar_background","icons",0,64,182,5),
    LegacySprite("hud/experience_bar_progress","icons",0,69,182,5)
];

// Virtual aliases only: archives and the installation assets remain unchanged.
string modernTextureName(string name,bool item)
{
    immutable pairs = "grass_top:grass_block_top grass_side:grass_block_side grass_side_overlay:grass_block_side_overlay grass_side_snowed:grass_block_snow tallgrass:short_grass grass:short_grass brick:bricks cobblestone_mossy:mossy_cobblestone dirt_podzol_top:podzol_top dirt_podzol_side:podzol_side grass_path_top:dirt_path_top grass_path_side:dirt_path_side planks_big_oak:dark_oak_planks hardened_clay:terracotta ice_packed:packed_ice magma:magma_block mob_spawner:spawner portal:nether_portal fire_layer_0:fire_0 fire_layer_1:fire_1 reeds:sugar_cane waterlily:lily_pad deadbush:dead_bush slime:slime_block end_bricks:end_stone_bricks endframe_top:end_portal_frame_top endframe_side:end_portal_frame_side endframe_eye:end_portal_frame_eye stonebrick:stone_bricks stonebrick_mossy:mossy_stone_bricks stonebrick_cracked:cracked_stone_bricks stonebrick_carved:chiseled_stone_bricks stone_andesite:andesite stone_andesite_smooth:polished_andesite stone_diorite:diorite stone_diorite_smooth:polished_diorite stone_granite:granite stone_granite_smooth:polished_granite furnace_front_off:furnace_front furnace_front_on:furnace_front_on comparator_off:comparator repeater_off:repeater farmland_dry:farmland farmland_wet:farmland_moist trapdoor:oak_trapdoor red_nether_brick:red_nether_bricks nether_brick:nether_bricks quartz_ore:nether_quartz_ore noteblock:note_block anvil_base:anvil anvil_top_damaged_0:anvil_top anvil_top_damaged_1:chipped_anvil_top anvil_top_damaged_2:damaged_anvil_top flower_rose:poppy flower_dandelion:dandelion flower_houstonia:azure_bluet flower_blue_orchid:blue_orchid flower_allium:allium flower_oxeye_daisy:oxeye_daisy flower_tulip_red:red_tulip flower_tulip_orange:orange_tulip flower_tulip_white:white_tulip flower_tulip_pink:pink_tulip";
    foreach(pair;pairs.split()) { const p=pair.split(":");if(name==p[0])return p[1]; }
    foreach(pair;"rail_normal:rail rail_normal_turned:rail_corner rail_golden:powered_rail rail_golden_powered:powered_rail_on rail_detector:detector_rail rail_detector_powered:detector_rail_on rail_activator:activator_rail rail_activator_powered:activator_rail_on redstone_dust_line0:redstone_dust_line0 redstone_torch_off:redstone_torch_off redstone_torch_on:redstone_torch torch_on:torch stone_slab_side:smooth_stone_slab_side stone_slab_top:smooth_stone sandstone_normal:sandstone sandstone_carved:chiseled_sandstone sandstone_smooth:cut_sandstone red_sandstone_normal:red_sandstone red_sandstone_carved:chiseled_red_sandstone red_sandstone_smooth:cut_red_sandstone prismarine_rough:prismarine prismarine_dark:dark_prismarine mushroom_block_skin_brown:brown_mushroom_block mushroom_block_skin_red:red_mushroom_block mushroom_brown:brown_mushroom mushroom_red:red_mushroom melon_stem_connected:attached_melon_stem melon_stem_disconnected:melon_stem pumpkin_stem_connected:attached_pumpkin_stem pumpkin_stem_disconnected:pumpkin_stem pumpkin_face_off:carved_pumpkin pumpkin_face_on:jack_o_lantern".split())
    {const p=pair.split(":");if(name==p[0])return p[1];}
    if(name.startsWith("door_")&&(name.endsWith("_lower")||name.endsWith("_upper")))
        return name[5..$-6].replace("wood","oak")~"_door_"~(name.endsWith("_lower")?"bottom":"top");
    if(item)
    {
        foreach(pair;"wood:wooden gold:golden".split())
        { const p=pair.split(":");if(name.startsWith(p[0]~"_"))return p[1]~name[p[0].length..$]; }
        foreach(pair;"apple_golden:golden_apple carrot_golden:golden_carrot beef_raw:beef beef_cooked:cooked_beef porkchop_raw:porkchop porkchop_cooked:cooked_porkchop chicken_raw:chicken chicken_cooked:cooked_chicken fish_raw:cod fish_cooked:cooked_cod fish_salmon_raw:salmon fish_salmon_cooked:cooked_salmon dye_powder_red:red_dye dye_powder_blue:lapis_lazuli dye_powder_white:bone_meal dye_powder_black:ink_sac door_wood:oak_door boat:oak_boat totem:totem_of_undying melon:melon_slice speckled_melon:glistering_melon_slice".split())
        {const p=pair.split(":");if(name==p[0])return p[1];}
    }
    foreach(pair;"concrete_powder_:concrete_powder hardened_clay_stained_:terracotta wool_colored_:wool glass_pane_top_:stained_glass_pane_top glass_:stained_glass concrete_:concrete glazed_terracotta_:glazed_terracotta".split())
    {
        const p=pair.split(":");
        if(name.startsWith(p[0]))return name[p[0].length..$].replace("silver","light_gray")~"_"~p[1];
    }
    foreach(pair;"planks_:planks leaves_:leaves sapling_:sapling log_:log".split())
    {
        const p=pair.split(":");
        if(name.startsWith(p[0]))
        {
            auto wood=name[p[0].length..$].replace("big_oak","dark_oak");
            if(wood.endsWith("_top"))return wood[0..$-4]~"_"~p[1]~"_top";
            return wood~"_"~p[1];
        }
    }
    return name;
}

void addCompatibilityAliases(ref string[string] files)
{
    const originals=files.dup;
    void aliasFile(string target,string source)
    {
        if(target.endsWith(".png.mcmeta")&&target[0..$-7] in originals)return;
        if(target !in files)files[target]=originals[source];
    }
    // Sorting makes collisions between malformed legacy names deterministic.
    auto keys=originals.keys;keys.sort();
    foreach(key;keys)
    {
        foreach(folder;["blocks","items","block","item"])
        {
            const prefix="minecraft/textures/"~folder~"/";
            if(!key.startsWith(prefix))continue;
            const suffix=key.endsWith(".png.mcmeta")?".png.mcmeta":key.endsWith(".png")?".png":"";
            if(!suffix.length)continue;
            const name=key[prefix.length..$-suffix.length];
            const item=folder=="items"||folder=="item";
            aliasFile("minecraft/textures/"~(item?"item/":"block/")~modernTextureName(name,item)~suffix,key);
        }
    }
    foreach(name;["minecraft.png","edition.png"])
    {
        const key="minecraft/textures/gui/title/"~name;
        if(key in originals)aliasFile("minecraft_d/textures/gui/title/"~name,key);
    }
    const widgets="minecraft/textures/gui/widgets.png";
    if(widgets in originals)foreach(name;["button","button_highlighted","button_disabled"])
        aliasFile("minecraft/textures/gui/sprites/widget/"~name~".png",widgets);
    const background="minecraft/textures/gui/options_background.png";
    if(background in originals)aliasFile("minecraft/textures/gui/menu_background.png",background);
    foreach(sprite;legacySprites)
    {
        const sheet="minecraft/textures/gui/"~sprite.sheet~".png";
        if(sheet in originals)aliasFile("minecraft/textures/gui/sprites/"~sprite.name~".png",sheet);
    }
    foreach(pair;["textures/entity/steve.png:textures/entity/player/wide/steve.png",
        "textures/environment/sun.png:textures/environment/celestial/sun.png"])
    {
        const p=pair.split(":");const source="minecraft/"~p[0];
        if(source in originals)aliasFile("minecraft/"~p[1],source);
    }
}
