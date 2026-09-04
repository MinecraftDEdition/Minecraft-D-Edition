module minecraftd.game.item.inventory;

import minecraftd.world.block : BlockId, catalogBlockDefinition,
    firstCatalogBlock, isCatalogBlock, lastCatalogBlock;

enum ItemId : ubyte
{
    none,
    grassBlock,
    dirt,
    stone,
    obsidian,
    netherrack,
    flintAndSteel,
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

enum ItemId firstCatalogItem = ItemId.coarseDirt;
enum ItemId lastCatalogItem = ItemId.pinkTerracotta;
enum ItemId lastBlockItem = lastCatalogItem;
static assert(cast(int)lastCatalogItem <= ubyte.max,
    "Item registry exceeds the current inventory/network ID width");

/// Java 1.19.3+ creative-inventory groups. An item may intentionally belong
/// to more than one group; the ordered catalog below remains the single source
/// of truth for Search Items and future experimental entries.
enum CreativeItemGroup : ubyte
{
    buildingBlocks,
    coloredBlocks,
    naturalBlocks,
    functionalBlocks,
    redstoneBlocks,
    toolsAndUtilities,
    combat,
    foodAndDrinks,
    ingredients,
    spawnEggs,
    operatorUtilities,
}

@property ItemId[] creativeCatalog()
{
    ItemId[] result = [
        ItemId.stone, ItemId.cobblestone,
        ItemId.oakPlanks, ItemId.sprucePlanks, ItemId.birchPlanks,
        ItemId.junglePlanks, ItemId.acaciaPlanks, ItemId.darkOakPlanks,
        ItemId.mangrovePlanks, ItemId.cherryPlanks, ItemId.bambooPlanks,
        ItemId.paleOakPlanks, ItemId.crimsonPlanks, ItemId.warpedPlanks,
        ItemId.bricks, ItemId.glass,
        ItemId.grassBlock, ItemId.dirt, ItemId.obsidian, ItemId.netherrack,
        ItemId.bedrock,
    ];
    foreach (raw; cast(int)firstCatalogItem .. cast(int)lastCatalogItem + 1)
        result ~= cast(ItemId)raw;
    result ~= ItemId.flintAndSteel;
    return result;
}

bool creativeItemInGroup(ItemId item, CreativeItemGroup group)
{
    const catalog = item >= firstCatalogItem && item <= lastCatalogItem;
    final switch (group)
    {
        case CreativeItemGroup.buildingBlocks:
            switch (item)
            {
                case ItemId.stone, ItemId.cobblestone, ItemId.oakPlanks,
                     ItemId.sprucePlanks, ItemId.birchPlanks,
                     ItemId.junglePlanks, ItemId.acaciaPlanks,
                     ItemId.darkOakPlanks, ItemId.mangrovePlanks,
                     ItemId.cherryPlanks, ItemId.bambooPlanks,
                     ItemId.paleOakPlanks, ItemId.crimsonPlanks,
                     ItemId.warpedPlanks, ItemId.bricks, ItemId.glass:
                    return true;
                default:
                    return catalog && !(item >= ItemId.whiteWool
                        && item <= ItemId.pinkTerracotta);
            }
        case CreativeItemGroup.coloredBlocks:
            return item >= ItemId.whiteWool && item <= ItemId.pinkTerracotta;
        case CreativeItemGroup.naturalBlocks:
            switch (item)
            {
                case ItemId.grassBlock, ItemId.dirt, ItemId.stone,
                     ItemId.obsidian, ItemId.netherrack, ItemId.bedrock:
                    return true;
                default:
                    return catalog && (item <= ItemId.dripstoneBlock
                        || (item >= ItemId.coalOre
                            && item <= ItemId.deepslateDiamondOre)
                        || (item >= ItemId.soulSoil
                            && item <= ItemId.ancientDebris)
                        || item == ItemId.endStone || item == ItemId.snowBlock
                        || (item >= ItemId.cinnabar
                            && item <= ItemId.chiseledSulfur));
            }
        case CreativeItemGroup.toolsAndUtilities:
            return item == ItemId.flintAndSteel;
        case CreativeItemGroup.functionalBlocks,
             CreativeItemGroup.redstoneBlocks,
             CreativeItemGroup.combat,
             CreativeItemGroup.foodAndDrinks,
             CreativeItemGroup.ingredients,
             CreativeItemGroup.spawnEggs,
             CreativeItemGroup.operatorUtilities:
            return false;
    }
}

ItemId[] creativeItems(CreativeItemGroup group)
{
    ItemId[] result;
    foreach (item; creativeCatalog)
        if (creativeItemInGroup(item, group)) result ~= item;
    return result;
}

struct ItemStack
{
    ItemId item;
    ubyte count;
    ubyte popTicks;

    bool empty() const { return item == ItemId.none || count == 0; }
}

ubyte maximumStackSize(ItemId item)
{
    return item==ItemId.flintAndSteel?cast(ubyte)1:cast(ubyte)64;
}

struct Inventory
{
    enum int hotbarSize = 9;
    enum int storageSize = 27;
    enum int slotCount = hotbarSize + storageSize;
    enum ubyte maximumStack = 64;

    ItemStack[hotbarSize] hotbar;
    ItemStack[storageSize] storage;
    ItemStack carried;

    ItemStack slot(int index) const
    {
        if (index < 0 || index >= slotCount)
            return ItemStack.init;
        return index < storageSize ? storage[index]
            : hotbar[index - storageSize];
    }

    void setSlot(int index, ItemStack stack)
    {
        if (index < 0 || index >= slotCount)
            return;
        normalize(stack);
        if (index < storageSize)
            storage[index] = stack;
        else
            hotbar[index - storageSize] = stack;
    }

    /// Returns the amount that did not fit.
    ubyte add(ItemId item, ubyte amount)
    {
        if (item == ItemId.none || amount == 0)
            return 0;
        const limit=maximumStackSize(item);
        uint remaining = amount;
        foreach (ref stack; hotbar)
        {
            if (stack.item != item || stack.count >= limit)
                continue;
            const room = limit - stack.count;
            const moved = remaining < room ? remaining : room;
            stack.count += cast(ubyte) moved;
            stack.popTicks = 5;
            remaining -= moved;
            if (remaining == 0)
                return 0;
        }
        foreach (ref stack; storage)
        {
            if (stack.item != item || stack.count >= limit)
                continue;
            const room = limit - stack.count;
            const moved = remaining < room ? remaining : room;
            stack.count += cast(ubyte) moved;
            stack.popTicks = 5;
            remaining -= moved;
            if (remaining == 0)
                return 0;
        }
        foreach (ref stack; hotbar)
        {
            if (!stack.empty())
                continue;
            const moved = remaining < limit ? remaining : limit;
            stack = ItemStack(item, cast(ubyte) moved, 5);
            remaining -= moved;
            if (remaining == 0)
                return 0;
        }
        foreach (ref stack; storage)
        {
            if (!stack.empty())
                continue;
            const moved = remaining < limit ? remaining : limit;
            stack = ItemStack(item, cast(ubyte) moved, 5);
            remaining -= moved;
            if (remaining == 0)
                return 0;
        }
        return cast(ubyte) remaining;
    }

    bool removeOne(int slot)
    {
        if (slot < 0 || slot >= hotbarSize || hotbar[slot].empty())
            return false;
        auto stack = &hotbar[slot];
        --stack.count;
        stack.popTicks = 5;
        if (stack.count == 0)
            stack.item = ItemId.none;
        return true;
    }

    /// Java-style Pick Block. Existing hotbar stacks are selected, existing
    /// storage stacks are swapped into the active hotbar slot, and Creative
    /// creates one item only when the item is not already present.
    bool pickBlock(ItemId item, ref int selectedSlot, bool creative)
    {
        if (item == ItemId.none)
            return false;
        if (selectedSlot < 0 || selectedSlot >= hotbarSize)
            selectedSlot = 0;
        foreach (index, stack; hotbar)
        {
            if (!stack.empty() && stack.item == item)
            {
                selectedSlot = cast(int) index;
                return true;
            }
        }
        foreach (index, stack; storage)
        {
            if (stack.empty() || stack.item != item)
                continue;
            const displaced = hotbar[selectedSlot];
            hotbar[selectedSlot] = stack;
            hotbar[selectedSlot].popTicks = 5;
            storage[index] = displaced;
            return true;
        }
        if (!creative)
            return false;
        hotbar[selectedSlot] = ItemStack(item, 1, 5);
        return true;
    }

    void tick()
    {
        foreach (ref stack; hotbar)
            if (stack.popTicks > 0)
                --stack.popTicks;
        foreach (ref stack; storage)
            if (stack.popTicks > 0)
                --stack.popTicks;
        // Cursor-held stacks do not use Java's slot-pop animation.
        carried.popTicks=0;
    }

    void click(int index, bool rightButton)
    {
        if (index < 0 || index >= slotCount)
            return;
        auto target = slot(index);
        if (!rightButton)
        {
            if (carried.empty())
            {
                carried = target;
                carried.popTicks=0;
                target = ItemStack.init;
            }
            else if (target.empty())
            {
                target = carried;
                carried = ItemStack.init;
            }
            else if (target.item == carried.item
                && target.count < maximumStackSize(target.item))
            {
                const room = maximumStackSize(target.item) - target.count;
                const moved = carried.count < room ? carried.count : room;
                target.count += cast(ubyte) moved;
                carried.count -= cast(ubyte) moved;
                if (carried.count == 0) carried = ItemStack.init;
            }
            else
            {
                const swap = target;
                target = carried;
                carried = swap;
                carried.popTicks=0;
            }
        }
        else if (carried.empty())
        {
            if (!target.empty())
            {
                const taken = cast(ubyte) ((target.count + 1) / 2);
                carried = ItemStack(target.item, taken, 0);
                target.count -= taken;
                normalize(target);
            }
        }
        else if (target.empty())
        {
            target = ItemStack(carried.item, 1, 5);
            --carried.count;
            normalize(carried);
        }
        else if (target.item == carried.item
            && target.count < maximumStackSize(target.item))
        {
            ++target.count;
            --carried.count;
            target.popTicks = 5;
            normalize(carried);
        }
        else
        {
            const swap = target;
            target = carried;
            carried = swap;
            carried.popTicks=0;
        }
        target.popTicks = target.empty() ? 0 : 5;
        setSlot(index, target);
    }

    void quickMove(int index)
    {
        auto source = slot(index);
        if (source.empty()) return;
        const toHotbar = index < storageSize;
        moveInto(source, toHotbar);
        setSlot(index, source);
    }

    void swapHotbar(int index, int hotbarSlot)
    {
        if (index < 0 || index >= slotCount || hotbarSlot < 0
            || hotbarSlot >= hotbarSize)
            return;
        const hotbarIndex = storageSize + hotbarSlot;
        const first = slot(index);
        const second = slot(hotbarIndex);
        setSlot(index, second);
        setSlot(hotbarIndex, first);
    }

    void collectMatching(int index)
    {
        auto target = slot(index);
        ItemId wanted = carried.empty() ? target.item : carried.item;
        if (wanted == ItemId.none) return;
        if (carried.empty())
        {
            carried = target;
            setSlot(index, ItemStack.init);
        }
        foreach (slotIndex; 0 .. slotCount)
        {
            const limit=maximumStackSize(wanted);
            if (carried.count >= limit) break;
            auto stack = slot(slotIndex);
            if (stack.item != wanted || stack.empty()) continue;
            const room = limit - carried.count;
            const moved = stack.count < room ? stack.count : room;
            carried.count += cast(ubyte) moved;
            stack.count -= cast(ubyte) moved;
            normalize(stack);
            setSlot(slotIndex, stack);
        }
        carried.popTicks = 0;
    }

    /// Infinite Creative catalog source. A primary click takes one item and
    /// repeated primary clicks grow a matching cursor stack. A primary click
    /// on a different catalog item clears the cursor; a secondary click always
    /// takes that item's full legal stack.
    void creativeCatalogClick(ItemId item,bool fullStack)
    {
        if(item==ItemId.none)
        {
            carried=ItemStack.init;
            return;
        }
        const limit=maximumStackSize(item);
        if(fullStack)
            carried=ItemStack(item,limit,0);
        else if(carried.empty())
            carried=ItemStack(item,1,0);
        else if(carried.item==item)
        {
            if(carried.count<limit)++carried.count;
            carried.popTicks=0;
        }
        else carried=ItemStack.init;
    }

    ItemStack takeFromSlot(int index, bool wholeStack)
    {
        auto stack = slot(index);
        if (stack.empty()) return ItemStack.init;
        const amount = wholeStack ? stack.count : cast(ubyte) 1;
        ItemStack result = ItemStack(stack.item, amount, 0);
        stack.count -= amount;
        normalize(stack);
        setSlot(index, stack);
        return result;
    }

    ItemStack takeCarried(bool wholeStack)
    {
        if (carried.empty()) return ItemStack.init;
        const amount = wholeStack ? carried.count : cast(ubyte) 1;
        ItemStack result = ItemStack(carried.item, amount, 0);
        carried.count -= amount;
        normalize(carried);
        return result;
    }

    ubyte returnCarried()
    {
        if (carried.empty()) return 0;
        const leftover = add(carried.item, carried.count);
        carried.count = leftover;
        normalize(carried);
        return leftover;
    }

private:
    static void normalize(ref ItemStack stack)
    {
        if (stack.item == ItemId.none || stack.count == 0)
            stack = ItemStack.init;
        else if (stack.count > maximumStackSize(stack.item))
            stack.count = maximumStackSize(stack.item);
    }

    void moveInto(ref ItemStack source, bool toHotbar)
    {
        void merge(ref ItemStack destination)
        {
            const limit=maximumStackSize(source.item);
            if (source.empty() || destination.item != source.item
                || destination.count >= limit) return;
            const room = limit - destination.count;
            const moved = source.count < room ? source.count : room;
            destination.count += cast(ubyte) moved;
            source.count -= cast(ubyte) moved;
            destination.popTicks = 5;
            normalize(source);
        }
        void fill(ref ItemStack destination)
        {
            if (source.empty() || !destination.empty()) return;
            destination = source;
            destination.popTicks = 5;
            source = ItemStack.init;
        }
        if (toHotbar)
        {
            foreach (ref destination; hotbar) merge(destination);
            foreach (ref destination; hotbar) fill(destination);
        }
        else
        {
            foreach (ref destination; storage) merge(destination);
            foreach (ref destination; storage) fill(destination);
        }
    }
}

string itemName(ItemId item)
{
    switch (item)
    {
        case ItemId.none: return "";
        case ItemId.grassBlock: return "Grass Block";
        case ItemId.dirt: return "Dirt";
        case ItemId.stone: return "Stone";
        case ItemId.obsidian: return "Obsidian";
        case ItemId.netherrack: return "Netherrack";
        case ItemId.flintAndSteel: return "Flint and Steel";
        case ItemId.bricks: return "Bricks";
        case ItemId.oakPlanks: return "Oak Planks";
        case ItemId.sprucePlanks: return "Spruce Planks";
        case ItemId.birchPlanks: return "Birch Planks";
        case ItemId.junglePlanks: return "Jungle Planks";
        case ItemId.acaciaPlanks: return "Acacia Planks";
        case ItemId.darkOakPlanks: return "Dark Oak Planks";
        case ItemId.mangrovePlanks: return "Mangrove Planks";
        case ItemId.cherryPlanks: return "Cherry Planks";
        case ItemId.bambooPlanks: return "Bamboo Planks";
        case ItemId.paleOakPlanks: return "Pale Oak Planks";
        case ItemId.crimsonPlanks: return "Crimson Planks";
        case ItemId.warpedPlanks: return "Warped Planks";
        case ItemId.cobblestone: return "Cobblestone";
        case ItemId.glass: return "Glass";
        case ItemId.bedrock: return "Bedrock";
        default: return catalogBlockDefinition(placedBlock(item)).name;
    }
}

string itemCategory(ItemId item)
{
    if (item == ItemId.none) return "";
    if (creativeItemInGroup(item,CreativeItemGroup.toolsAndUtilities))
        return "Tools & Utilities";
    if (creativeItemInGroup(item,CreativeItemGroup.buildingBlocks))
        return "Building Blocks";
    if (creativeItemInGroup(item,CreativeItemGroup.naturalBlocks))
        return "Natural Blocks";
    return "";
}

bool sameHeldStack(const ItemStack left, const ItemStack right)
{
    return (left.empty() && right.empty())
        // Java's hand reequip/highlight comparison ignores stack count; adding
        // another copy of the same item must not replay the name or dip the hand.
        || (!left.empty() && !right.empty() && left.item == right.item);
}

ItemId blockItem(BlockId block)
{
    switch (block)
    {
        case BlockId.air: return ItemId.none;
        case BlockId.fire: return ItemId.none;
        case BlockId.grass: return ItemId.grassBlock;
        case BlockId.dirt: return ItemId.dirt;
        case BlockId.stone: return ItemId.stone;
        case BlockId.obsidian: return ItemId.obsidian;
        case BlockId.netherrack: return ItemId.netherrack;
        case BlockId.bricks: return ItemId.bricks;
        case BlockId.oakPlanks: return ItemId.oakPlanks;
        case BlockId.sprucePlanks: return ItemId.sprucePlanks;
        case BlockId.birchPlanks: return ItemId.birchPlanks;
        case BlockId.junglePlanks: return ItemId.junglePlanks;
        case BlockId.acaciaPlanks: return ItemId.acaciaPlanks;
        case BlockId.darkOakPlanks: return ItemId.darkOakPlanks;
        case BlockId.mangrovePlanks: return ItemId.mangrovePlanks;
        case BlockId.cherryPlanks: return ItemId.cherryPlanks;
        case BlockId.bambooPlanks: return ItemId.bambooPlanks;
        case BlockId.paleOakPlanks: return ItemId.paleOakPlanks;
        case BlockId.crimsonPlanks: return ItemId.crimsonPlanks;
        case BlockId.warpedPlanks: return ItemId.warpedPlanks;
        case BlockId.cobblestone: return ItemId.cobblestone;
        case BlockId.glass: return ItemId.glass;
        case BlockId.bedrock: return ItemId.bedrock;
        case BlockId.netherPortalX, BlockId.netherPortalZ: return ItemId.none;
        case BlockId.waterSource, BlockId.waterFlow1, BlockId.waterFlow2,
             BlockId.waterFlow3, BlockId.waterFlow4, BlockId.waterFlow5,
             BlockId.waterFlow6, BlockId.waterFlow7, BlockId.waterFalling:
            return ItemId.none;
        default:
            if (!isCatalogBlock(block)) return ItemId.none;
            return cast(ItemId)(cast(int)firstCatalogItem
                + cast(int)block - cast(int)firstCatalogBlock);
    }
}

BlockId placedBlock(ItemId item)
{
    switch (item)
    {
        case ItemId.none: return BlockId.air;
        case ItemId.grassBlock: return BlockId.grass;
        case ItemId.dirt: return BlockId.dirt;
        case ItemId.stone: return BlockId.stone;
        case ItemId.obsidian: return BlockId.obsidian;
        case ItemId.netherrack: return BlockId.netherrack;
        case ItemId.flintAndSteel: return BlockId.air;
        case ItemId.bricks: return BlockId.bricks;
        case ItemId.oakPlanks: return BlockId.oakPlanks;
        case ItemId.sprucePlanks: return BlockId.sprucePlanks;
        case ItemId.birchPlanks: return BlockId.birchPlanks;
        case ItemId.junglePlanks: return BlockId.junglePlanks;
        case ItemId.acaciaPlanks: return BlockId.acaciaPlanks;
        case ItemId.darkOakPlanks: return BlockId.darkOakPlanks;
        case ItemId.mangrovePlanks: return BlockId.mangrovePlanks;
        case ItemId.cherryPlanks: return BlockId.cherryPlanks;
        case ItemId.bambooPlanks: return BlockId.bambooPlanks;
        case ItemId.paleOakPlanks: return BlockId.paleOakPlanks;
        case ItemId.crimsonPlanks: return BlockId.crimsonPlanks;
        case ItemId.warpedPlanks: return BlockId.warpedPlanks;
        case ItemId.cobblestone: return BlockId.cobblestone;
        case ItemId.glass: return BlockId.glass;
        case ItemId.bedrock: return BlockId.bedrock;
        default:
            if (item < firstCatalogItem || item > lastCatalogItem)
                return BlockId.air;
            return cast(BlockId)(cast(int)firstCatalogBlock
                + cast(int)item - cast(int)firstCatalogItem);
    }
}

/// Empty-hand loot for the prototype palette, derived from the imported
/// vanilla block loot tables. Stone requires the correct tool and drops none.
ItemId bareHandDrop(BlockId block)
{
    switch (block)
    {
        case BlockId.grass, BlockId.dirt: return ItemId.dirt;
        case BlockId.netherrack: return ItemId.netherrack;
        case BlockId.oakPlanks: return ItemId.oakPlanks;
        case BlockId.sprucePlanks: return ItemId.sprucePlanks;
        case BlockId.birchPlanks: return ItemId.birchPlanks;
        case BlockId.junglePlanks: return ItemId.junglePlanks;
        case BlockId.acaciaPlanks: return ItemId.acaciaPlanks;
        case BlockId.darkOakPlanks: return ItemId.darkOakPlanks;
        case BlockId.mangrovePlanks: return ItemId.mangrovePlanks;
        case BlockId.cherryPlanks: return ItemId.cherryPlanks;
        case BlockId.bambooPlanks: return ItemId.bambooPlanks;
        case BlockId.paleOakPlanks: return ItemId.paleOakPlanks;
        case BlockId.crimsonPlanks: return ItemId.crimsonPlanks;
        case BlockId.warpedPlanks: return ItemId.warpedPlanks;
        case BlockId.air, BlockId.stone, BlockId.obsidian,
             BlockId.bricks, BlockId.cobblestone, BlockId.glass,
             BlockId.netherPortalX, BlockId.netherPortalZ,
             BlockId.bedrock, BlockId.fire: return ItemId.none;
        case BlockId.waterSource, BlockId.waterFlow1, BlockId.waterFlow2,
             BlockId.waterFlow3, BlockId.waterFlow4, BlockId.waterFlow5,
             BlockId.waterFlow6, BlockId.waterFlow7, BlockId.waterFalling:
            return ItemId.none;
        default:
            if (!isCatalogBlock(block)) return ItemId.none;
            return catalogBlockDefinition(block).handHarvestable
                ? blockItem(block) : ItemId.none;
    }
}

unittest
{
    Inventory inventory;
    assert(inventory.add(ItemId.dirt, 64) == 0);
    assert(inventory.hotbar[0].count == 64);
    assert(inventory.add(ItemId.dirt, 2) == 0);
    assert(inventory.hotbar[1].count == 2);
    assert(inventory.removeOne(0));
    assert(inventory.hotbar[0].count == 63);
    Inventory expanded;
    foreach (ref stack; expanded.hotbar) stack = ItemStack(ItemId.stone,64);
    assert(expanded.add(ItemId.dirt,64)==0);
    assert(expanded.storage[0].item==ItemId.dirt
        && expanded.storage[0].count==64);
    expanded.click(0,false);
    assert(expanded.carried.item==ItemId.dirt&&expanded.storage[0].empty());
    expanded.click(1,true);
    assert(expanded.storage[1].item==ItemId.dirt
        && expanded.storage[1].count==1&&expanded.carried.count==63);
    expanded.hotbar[0]=ItemStack.init;
    expanded.quickMove(1);
    assert(expanded.storage[1].empty()&&expanded.hotbar[0].count==1);
    assert(bareHandDrop(BlockId.stone) == ItemId.none);
    assert(bareHandDrop(BlockId.grass) == ItemId.dirt);
    assert(sameHeldStack(ItemStack.init, ItemStack.init));
    assert(sameHeldStack(ItemStack(ItemId.dirt, 4, 0),
        ItemStack(ItemId.dirt, 4, 5)));
    assert(sameHeldStack(ItemStack(ItemId.dirt, 4, 0),
        ItemStack(ItemId.dirt, 5, 0)));
    assert(!sameHeldStack(ItemStack(ItemId.dirt, 4, 0),
        ItemStack(ItemId.stone, 4, 0)));
    Inventory creative;
    int selected = 2;
    assert(creative.pickBlock(ItemId.stone, selected, true));
    assert(selected == 2 && creative.hotbar[2].item == ItemId.stone
        && creative.hotbar[2].count == 1);
    creative.hotbar[5] = ItemStack(ItemId.dirt, 17);
    assert(creative.pickBlock(ItemId.dirt, selected, true) && selected == 5);
    creative.storage[3] = ItemStack(ItemId.grassBlock, 9);
    selected = 1;
    assert(creative.pickBlock(ItemId.grassBlock, selected, true));
    assert(creative.hotbar[1].item == ItemId.grassBlock
        && creative.hotbar[1].count == 9 && creative.storage[3].empty());
    assert(blockItem(BlockId.glass) == ItemId.glass);
    assert(blockItem(BlockId.bedrock) == ItemId.bedrock);
    assert(placedBlock(ItemId.bedrock) == BlockId.bedrock);
    assert(placedBlock(ItemId.warpedPlanks) == BlockId.warpedPlanks);
    assert(bareHandDrop(BlockId.oakPlanks) == ItemId.oakPlanks);
    assert(bareHandDrop(BlockId.glass) == ItemId.none);
    assert(blockItem(BlockId.cinnabar) == ItemId.cinnabar);
    assert(placedBlock(ItemId.pinkTerracotta) == BlockId.pinkTerracotta);
    assert(itemName(ItemId.deepslateDiamondOre) == "Deepslate Diamond Ore");
    assert(creativeItemInGroup(ItemId.blueWool,
        CreativeItemGroup.coloredBlocks));

    Inventory tools;
    assert(maximumStackSize(ItemId.flintAndSteel)==1);
    assert(tools.add(ItemId.flintAndSteel,2)==0);
    assert(tools.hotbar[0].item==ItemId.flintAndSteel
        &&tools.hotbar[0].count==1);
    assert(tools.hotbar[1].item==ItemId.flintAndSteel
        &&tools.hotbar[1].count==1);

    Inventory catalog;
    catalog.creativeCatalogClick(ItemId.dirt,false);
    assert(catalog.carried==ItemStack(ItemId.dirt,1,0));
    catalog.creativeCatalogClick(ItemId.dirt,false);
    assert(catalog.carried==ItemStack(ItemId.dirt,2,0));
    catalog.creativeCatalogClick(ItemId.stone,false);
    assert(catalog.carried.empty());
    catalog.creativeCatalogClick(ItemId.stone,true);
    assert(catalog.carried==ItemStack(ItemId.stone,64,0));
    catalog.creativeCatalogClick(ItemId.flintAndSteel,true);
    assert(catalog.carried==ItemStack(ItemId.flintAndSteel,1,0));
    catalog.creativeCatalogClick(ItemId.none,false);
    assert(catalog.carried.empty());
}
