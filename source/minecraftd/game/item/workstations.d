module minecraftd.game.item.workstations;

import minecraftd.game.item.inventory;
import minecraftd.world.block:BlockId,hardness,soundType,catalogBlockDefinition;
import std.string:splitLines,split;
import std.conv:to;
import std.file:exists,readText,write;
import std.path:buildPath;

struct Recipe { ItemId[9] input; ItemStack output; }
private Recipe[] recipes;
private bool initialized;
private void initializeRecipes()
{
    if(initialized)return;
    initialized=true;
    void add(ItemId[9] input,ItemId output,ubyte count=1)
    {recipes~=Recipe(input,ItemStack(output,count));}
    const N=ItemId.none, S=ItemId.stick;
    // Empty borders are removed by matches(), and shaped recipes may mirror.
    foreach(raw;cast(int)ItemId.oakPlanks..cast(int)ItemId.warpedPlanks+1)
    {
        const p=cast(ItemId)raw;
        add([p,p,N,p,p,N,N,N,N],ItemId.craftingTable);
        add([p,N,N,p,N,N,N,N,N],S,4);
    }
    const c=ItemId.cobblestone;
    add([c,c,c,c,N,c,c,c,c],ItemId.furnace);
    add([N,ItemId.book,N,ItemId.diamond,ItemId.obsidian,ItemId.diamond,
        ItemId.obsidian,ItemId.obsidian,ItemId.obsidian],ItemId.enchantingTable);
    add([ItemId.wheat,ItemId.wheat,ItemId.wheat,N,N,N,N,N,N],ItemId.bread);
    add([ItemId.ironIngot,N,N,N,ItemId.flint,N,N,N,N],ItemId.flintAndSteel);
    immutable ItemId[6] materials=[ItemId.oakPlanks,ItemId.cobblestone,
        ItemId.copperIngot,ItemId.ironIngot,ItemId.goldIngot,ItemId.diamond];
    foreach(tier,m;materials)
    {
        const start=cast(int)ItemId.woodenSword+cast(int)tier*5;
        add([m,N,N,m,N,N,S,N,N],cast(ItemId)start);
        add([m,m,N,m,S,N,N,S,N],cast(ItemId)(start+1));
        add([m,m,m,N,S,N,N,S,N],cast(ItemId)(start+2));
        add([m,N,N,S,N,N,S,N,N],cast(ItemId)(start+3));
        add([m,m,N,N,S,N,N,S,N],cast(ItemId)(start+4));
    }
}
private bool matches(const ItemStack[10] input,ItemId[9] recipe)
{
    int minX=3,minY=3,maxX=-1,maxY=-1,rMinX=3,rMinY=3,rMaxX=-1,rMaxY=-1;
    foreach(i;0..9)
    {
        if(!input[i].empty()){if(i%3<minX)minX=i%3;if(i/3<minY)minY=i/3;
            if(i%3>maxX)maxX=i%3;if(i/3>maxY)maxY=i/3;}
        if(recipe[i]!=ItemId.none){if(i%3<rMinX)rMinX=i%3;if(i/3<rMinY)rMinY=i/3;
            if(i%3>rMaxX)rMaxX=i%3;if(i/3>rMaxY)rMaxY=i/3;}
    }
    if(maxX<0||maxX-minX!=rMaxX-rMinX||maxY-minY!=rMaxY-rMinY)return false;
    foreach(mirror;0..2)
    {
        bool good=true;
        foreach(y;0..maxY-minY+1)foreach(x;0..maxX-minX+1)
        {
            ItemId actual=input[(minY+y)*3+minX+x].item;
            auto expected=recipe[(rMinY+y)*3+(mirror?rMaxX-x:rMinX+x)];
            if(expected==ItemId.oakPlanks&&actual>=ItemId.oakPlanks&&actual<=ItemId.warpedPlanks)
                actual=ItemId.oakPlanks;
            if(actual!=expected)good=false;
        }
        if(good)return true;
    }
    return false;
}
ItemStack craftingResult(const ItemStack[10] input)
{
    initializeRecipes();
    foreach(recipe;recipes)if(matches(input,recipe.input))return recipe.output;
    return ItemStack.init;
}
bool takeCraftingResult(ref Inventory inventory)
{
    const result=craftingResult(inventory.work);
    if(result.empty())return false;
    if(!inventory.carried.empty()&&(inventory.carried.item!=result.item
        ||inventory.carried.count+result.count>maximumStackSize(result.item)))return false;
    if(inventory.carried.empty())inventory.carried=result;
    else inventory.carried.count+=result.count;
    foreach(ref stack;inventory.work[0..9])
        if(!stack.empty()){if(--stack.count==0)stack=ItemStack.init;}
    inventory.work[9]=craftingResult(inventory.work);
    return true;
}
ItemId smeltingResult(ItemId input)
{
    switch(input)
    {
        case ItemId.rawIron,ItemId.ironOre,ItemId.deepslateIronOre:return ItemId.ironIngot;
        case ItemId.rawCopper,ItemId.copperOre,ItemId.deepslateCopperOre:return ItemId.copperIngot;
        case ItemId.rawGold,ItemId.goldOre,ItemId.deepslateGoldOre:return ItemId.goldIngot;
        case ItemId.sand,ItemId.redSand:return ItemId.glass;
        case ItemId.cobblestone:return ItemId.stone;
        case ItemId.beef:return ItemId.cookedBeef;
        case ItemId.porkchop:return ItemId.cookedPorkchop;
        case ItemId.chicken:return ItemId.cookedChicken;
        case ItemId.mutton:return ItemId.cookedMutton;
        case ItemId.rabbit:return ItemId.cookedRabbit;
        case ItemId.cod:return ItemId.cookedCod;
        default:return ItemId.none;
    }
}
ushort fuelTicks(ItemId item)
{
    if(item==ItemId.coal)return 1600;
    if(item==ItemId.coalBlock)return 16000;
    if(item==ItemId.stick)return 100;
    if(item>=ItemId.oakPlanks&&item<=ItemId.paleOakPlanks)return 300;
    return 0;
}

/// Shared client prediction/server validation. Output slots are never ordinary
/// inventory slots: extracting output must also consume the recipe ingredients.
bool clickWorkstation(ref Inventory inv,int target,bool right)
{
    if(!inv.station)return false;
    if(target>=Inventory.slotCount)
    {
        const index=target-Inventory.slotCount;
        const limit=inv.station==1?10:(inv.station==2?3:2);
        if(index>=limit)return false;
        if(inv.station==1&&index==9)return takeCraftingResult(inv);
        if(inv.station==2&&index==2)
        {
            const output=inv.work[2];
            if(output.empty())return false;
            const amount=right?1:output.count;
            if(!inv.carried.empty()&&(inv.carried.item!=output.item
                ||inv.carried.count+amount>maximumStackSize(output.item)))return false;
            if(inv.carried.empty())inv.carried=ItemStack(output.item,cast(ubyte)amount);
            else inv.carried.count+=cast(ubyte)amount;
            inv.work[2].count-=cast(ubyte)amount;
            if(!inv.work[2].count)inv.work[2]=ItemStack.init;
            return true;
        }
        if(!inv.carried.empty())
        {
            if(inv.station==2&&index==0&&smeltingResult(inv.carried.item)==ItemId.none)return false;
            if(inv.station==2&&index==1&&!fuelTicks(inv.carried.item))return false;
            if(inv.station==3&&index==0&&!durability(inv.carried.item))return false;
            if(inv.station==3&&index==1&&inv.carried.item!=ItemId.lapisLazuli)return false;
        }
    }
    if(target<0)return false;
    const beforeInput=inv.work[0].item;
    inv.click(target,right);
    if(inv.station==1)inv.work[9]=craftingResult(inv.work);
    if(inv.station==2&&beforeInput!=inv.work[0].item)inv.cookTicks=0;
    return true;
}
void tickFurnace(ref Inventory furnace)
{
    if(furnace.burnTicks)--furnace.burnTicks;
    const result=smeltingResult(furnace.work[0].item);
    const possible=!furnace.work[0].empty()&&result!=ItemId.none
        &&(furnace.work[2].empty()||(furnace.work[2].item==result
            &&furnace.work[2].count<maximumStackSize(result)));
    if(possible&&!furnace.burnTicks&&!furnace.work[1].empty())
    {
        const fuel=fuelTicks(furnace.work[1].item);
        if(fuel){furnace.burnTicks=fuel;
            if(--furnace.work[1].count==0)furnace.work[1]=ItemStack.init;}
    }
    if(possible&&furnace.burnTicks)
    {
        if(++furnace.cookTicks>=200)
        {
            furnace.cookTicks=0;
            if(--furnace.work[0].count==0)furnace.work[0]=ItemStack.init;
            if(furnace.work[2].empty())furnace.work[2]=ItemStack(result,1);
            else ++furnace.work[2].count;
        }
    }
    else furnace.cookTicks=0;
}
float miningProgress(BlockId block,ItemStack tool)
{
    const h=hardness(block);
    if(h<0)return 0;
    if(h==0)return 1;
    const kind=toolKind(tool.item),tier=toolTier(tool.item);
    const family=soundType(block).family;
    const pick=family=="stone"||family=="deepslate"||family=="tuff"||family=="metal"
        ||family=="nether_bricks"||family=="netherrack"||family=="basalt";
    const effective=(kind==2&&pick)||(kind==1&&(family=="wood"||family=="nether_wood"))
        ||(kind==3&&(family=="gravel"||family=="sand"||family=="grass"||family=="snow"));
    immutable float[7] speeds=[2,4,5,6,12,8,9];
    float speed=effective?speeds[tier]:1;
    if(effective&&tool.enchantment==1)speed+=tool.enchantmentLevel*tool.enchantmentLevel+1;
    const harvest=harvestDrop(block,tool.item)!=ItemId.none;
    return speed/h/(harvest?30:100);
}
ItemId harvestDrop(BlockId block,ItemId tool)
{
    const basic=bareHandDrop(block);
    if(basic!=ItemId.none)return basic;
    if(toolKind(tool)!=2)return ItemId.none;
    const tier=toolTier(tool);
    const rank=tier==4?0:(tier>=5?3:(tier==3?2:(tier>0?1:0)));
    const required=(block==BlockId.obsidian||block==BlockId.ancientDebris)?3:
        ((block==BlockId.diamondOre||block==BlockId.deepslateDiamondOre
          ||block==BlockId.goldOre||block==BlockId.deepslateGoldOre
          ||block==BlockId.redstoneOre||block==BlockId.deepslateRedstoneOre
          ||block==BlockId.emeraldOre||block==BlockId.deepslateEmeraldOre)?2:
          ((block==BlockId.ironOre||block==BlockId.deepslateIronOre
            ||block==BlockId.copperOre||block==BlockId.deepslateCopperOre)?1:0));
    if(rank<required)return ItemId.none;
    switch(block)
    {
        case BlockId.bedrock,BlockId.glass,BlockId.enchantingTable:return block==BlockId.enchantingTable?ItemId.enchantingTable:ItemId.none;
        case BlockId.stone:return ItemId.cobblestone;
        case BlockId.coalOre,BlockId.deepslateCoalOre:return ItemId.coal;
        case BlockId.ironOre,BlockId.deepslateIronOre:return ItemId.rawIron;
        case BlockId.copperOre,BlockId.deepslateCopperOre:return ItemId.rawCopper;
        case BlockId.goldOre,BlockId.deepslateGoldOre:return ItemId.rawGold;
        case BlockId.diamondOre,BlockId.deepslateDiamondOre:return ItemId.diamond;
        case BlockId.lapisOre,BlockId.deepslateLapisOre:return ItemId.lapisLazuli;
        default:return blockItem(block);
    }
}

unittest
{
    Inventory inv;inv.station=1;
    inv.work[0]=inv.work[1]=inv.work[3]=inv.work[4]=ItemStack(ItemId.oakPlanks,2);
    assert(craftingResult(inv.work).item==ItemId.craftingTable);
    assert(takeCraftingResult(inv)&&inv.carried.item==ItemId.craftingTable&&inv.work[0].count==1);
    inv=Inventory.init;inv.work[0]=ItemStack(ItemId.beef,2);inv.work[1]=ItemStack(ItemId.coal,1);
    foreach(i;0..199)tickFurnace(inv);
    assert(inv.work[2].empty());tickFurnace(inv);
    assert(inv.work[2].item==ItemId.cookedBeef&&inv.work[0].count==1);
    assert(harvestDrop(BlockId.diamondOre,ItemId.woodenPickaxe)==ItemId.none);
    assert(harvestDrop(BlockId.diamondOre,ItemId.ironPickaxe)==ItemId.diamond);
}
