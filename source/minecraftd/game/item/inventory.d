module minecraftd.game.item.inventory;

import minecraftd.world.block : BlockId;

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
}

struct ItemStack
{
    ItemId item;
    ubyte count;
    ubyte popTicks;

    bool empty() const { return item == ItemId.none || count == 0; }
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
        uint remaining = amount;
        foreach (ref stack; hotbar)
        {
            if (stack.item != item || stack.count >= maximumStack)
                continue;
            const room = maximumStack - stack.count;
            const moved = remaining < room ? remaining : room;
            stack.count += cast(ubyte) moved;
            stack.popTicks = 5;
            remaining -= moved;
            if (remaining == 0)
                return 0;
        }
        foreach (ref stack; storage)
        {
            if (stack.item != item || stack.count >= maximumStack)
                continue;
            const room = maximumStack - stack.count;
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
            const moved = remaining < maximumStack ? remaining : maximumStack;
            stack = ItemStack(item, cast(ubyte) moved, 5);
            remaining -= moved;
            if (remaining == 0)
                return 0;
        }
        foreach (ref stack; storage)
        {
            if (!stack.empty())
                continue;
            const moved = remaining < maximumStack ? remaining : maximumStack;
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
                target = ItemStack.init;
            }
            else if (target.empty())
            {
                target = carried;
                carried = ItemStack.init;
            }
            else if (target.item == carried.item
                && target.count < maximumStack)
            {
                const room = maximumStack - target.count;
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
            }
        }
        else if (carried.empty())
        {
            if (!target.empty())
            {
                const taken = cast(ubyte) ((target.count + 1) / 2);
                carried = ItemStack(target.item, taken, 5);
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
        else if (target.item == carried.item && target.count < maximumStack)
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
            if (carried.count >= maximumStack) break;
            auto stack = slot(slotIndex);
            if (stack.item != wanted || stack.empty()) continue;
            const room = maximumStack - carried.count;
            const moved = stack.count < room ? stack.count : room;
            carried.count += cast(ubyte) moved;
            stack.count -= cast(ubyte) moved;
            normalize(stack);
            setSlot(slotIndex, stack);
        }
        carried.popTicks = 5;
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
        else if (stack.count > maximumStack)
            stack.count = maximumStack;
    }

    void moveInto(ref ItemStack source, bool toHotbar)
    {
        void merge(ref ItemStack destination)
        {
            if (source.empty() || destination.item != source.item
                || destination.count >= maximumStack) return;
            const room = maximumStack - destination.count;
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
    final switch (item)
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
    }
}

string itemCategory(ItemId item)
{
    if (item == ItemId.none) return "";
    return item == ItemId.flintAndSteel ? "Tools & Utilities"
        : "Natural Blocks";
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
    final switch (block)
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
    }
}

BlockId placedBlock(ItemId item)
{
    final switch (item)
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
    }
}

/// Empty-hand loot for the prototype palette, derived from the imported
/// vanilla block loot tables. Stone requires the correct tool and drops none.
ItemId bareHandDrop(BlockId block)
{
    final switch (block)
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
}
