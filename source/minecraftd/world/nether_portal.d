module minecraftd.world.nether_portal;

import minecraftd.common.aabb : Aabb;
import minecraftd.world.block : BlockId, isNetherPortal;
import minecraftd.world.world : World;

enum PortalAxis : ubyte { x, z }

struct PortalRectangle
{
    bool valid;
    PortalAxis axis;
    int minX;
    int minY;
    int minZ;
    int width;
    int height;
}

enum int minimumPortalWidth = 2;
enum int maximumPortalWidth = 21;
enum int minimumPortalHeight = 3;
enum int maximumPortalHeight = 21;

bool igniteNetherPortal(World world, int x, int y, int z,
    out PortalRectangle rectangle)
{
    if (world is null || !world.inBounds(x, y, z)
        || !validInterior(world.getBlock(x, y, z)))
        return false;
    rectangle = findFrame(world, x, y, z, PortalAxis.x);
    if (!rectangle.valid)
        rectangle = findFrame(world, x, y, z, PortalAxis.z);
    if (!rectangle.valid)
        return false;
    fillPortal(world, rectangle);
    return true;
}

PortalRectangle portalAt(World world, int x, int y, int z)
{
    const block = world.getBlock(x, y, z);
    if (!isNetherPortal(block))
        return PortalRectangle.init;
    return findExisting(world, x, y, z,
        block == BlockId.netherPortalX ? PortalAxis.x : PortalAxis.z);
}

bool intersectsPortal(World world, Aabb bounds, out PortalRectangle rectangle)
{
    import core.stdc.math : floorf;
    const minX = cast(int) floorf(bounds.minX);
    const minY = cast(int) floorf(bounds.minY);
    const minZ = cast(int) floorf(bounds.minZ);
    const maxX = cast(int) floorf(bounds.maxX - 0.0001f);
    const maxY = cast(int) floorf(bounds.maxY - 0.0001f);
    const maxZ = cast(int) floorf(bounds.maxZ - 0.0001f);
    foreach (y; minY .. maxY + 1)
    foreach (z; minZ .. maxZ + 1)
    foreach (x; minX .. maxX + 1)
    {
        if (!isNetherPortal(world.getBlock(x, y, z)))
            continue;
        rectangle = portalAt(world, x, y, z);
        return rectangle.valid;
    }
    return false;
}

PortalRectangle createTestPortal(World world, int minX, int minY, int minZ,
    PortalAxis axis)
{
    PortalRectangle rectangle = PortalRectangle(true, axis, minX, minY,
        minZ, 2, 3);
    createPortalFrame(world, rectangle);
    fillPortal(world, rectangle);
    return rectangle;
}

PortalRectangle createTestPortalFrame(World world, int minX, int minY,
    int minZ, PortalAxis axis)
{
    PortalRectangle rectangle = PortalRectangle(true, axis, minX, minY,
        minZ, 2, 3);
    createPortalFrame(world, rectangle);
    return rectangle;
}

private void createPortalFrame(World world, PortalRectangle rectangle)
{
    const dx = rectangle.axis == PortalAxis.x ? 1 : 0;
    const dz = rectangle.axis == PortalAxis.z ? 1 : 0;
    foreach (row; 0 .. rectangle.height)
    foreach (along; 0 .. rectangle.width)
        world.setBlock(rectangle.minX + along * dx,
            rectangle.minY + row, rectangle.minZ + along * dz, BlockId.air);
    foreach (along; -1 .. rectangle.width + 1)
    {
        world.setBlock(rectangle.minX + along * dx, rectangle.minY - 1,
            rectangle.minZ + along * dz, BlockId.obsidian);
        world.setBlock(rectangle.minX + along * dx,
            rectangle.minY + rectangle.height,
            rectangle.minZ + along * dz, BlockId.obsidian);
    }
    foreach (row; 0 .. rectangle.height)
    {
        world.setBlock(rectangle.minX - dx, rectangle.minY + row,
            rectangle.minZ - dz,
            BlockId.obsidian);
        world.setBlock(rectangle.minX + rectangle.width * dx,
            rectangle.minY + row,
            rectangle.minZ + rectangle.width * dz, BlockId.obsidian);
    }
}

private:
bool validInterior(BlockId block)
{
    return block == BlockId.air || isNetherPortal(block);
}

PortalRectangle findFrame(World world, int x, int y, int z, PortalAxis axis)
{
    const dx = axis == PortalAxis.x ? 1 : 0;
    const dz = axis == PortalAxis.z ? 1 : 0;
    int bottomY = y;
    while (bottomY > world.minimumBuildY()
        && validInterior(world.getBlock(x, bottomY - 1, z))
        && y - bottomY < maximumPortalHeight)
        --bottomY;

    int minX = x;
    int minZ = z;
    int negative;
    while (negative < maximumPortalWidth
        && validInterior(world.getBlock(minX - dx, bottomY, minZ - dz)))
    {
        minX -= dx;
        minZ -= dz;
        ++negative;
    }
    if (world.getBlock(minX - dx, bottomY, minZ - dz) != BlockId.obsidian)
        return PortalRectangle.init;

    int width;
    while (width <= maximumPortalWidth
        && validInterior(world.getBlock(minX + width * dx, bottomY,
            minZ + width * dz)))
        ++width;
    if (width < minimumPortalWidth || width > maximumPortalWidth
        || world.getBlock(minX + width * dx, bottomY,
            minZ + width * dz) != BlockId.obsidian)
        return PortalRectangle.init;

    foreach (along; 0 .. width)
        if (world.getBlock(minX + along * dx, bottomY - 1,
            minZ + along * dz) != BlockId.obsidian)
            return PortalRectangle.init;

    int height;
    for (; height <= maximumPortalHeight; ++height)
    {
        bool top = true;
        foreach (along; 0 .. width)
        {
            const block = world.getBlock(minX + along * dx,
                bottomY + height, minZ + along * dz);
            if (block != BlockId.obsidian)
            {
                top = false;
                if (!validInterior(block)) return PortalRectangle.init;
            }
        }
        if (top)
            break;
        if (world.getBlock(minX - dx, bottomY + height, minZ - dz)
                != BlockId.obsidian
            || world.getBlock(minX + width * dx, bottomY + height,
                minZ + width * dz) != BlockId.obsidian)
            return PortalRectangle.init;
    }
    if (height < minimumPortalHeight || height > maximumPortalHeight)
        return PortalRectangle.init;
    return PortalRectangle(true, axis, minX, bottomY, minZ, width, height);
}

PortalRectangle findExisting(World world, int x, int y, int z, PortalAxis axis)
{
    const portalBlock = axis == PortalAxis.x
        ? BlockId.netherPortalX : BlockId.netherPortalZ;
    const dx = axis == PortalAxis.x ? 1 : 0;
    const dz = axis == PortalAxis.z ? 1 : 0;
    int minY = y;
    while (minY > world.minimumBuildY()
        && world.getBlock(x, minY - 1, z) == portalBlock)
        --minY;
    int minX = x, minZ = z;
    while (world.getBlock(minX - dx, minY, minZ - dz) == portalBlock)
    {
        minX -= dx; minZ -= dz;
    }
    int width;
    while (world.getBlock(minX + width * dx, minY,
        minZ + width * dz) == portalBlock) ++width;
    int height;
    while (world.getBlock(minX, minY + height, minZ) == portalBlock) ++height;
    return PortalRectangle(width >= minimumPortalWidth
        && height >= minimumPortalHeight, axis, minX, minY, minZ,
        width, height);
}

void fillPortal(World world, PortalRectangle rectangle)
{
    const dx = rectangle.axis == PortalAxis.x ? 1 : 0;
    const dz = rectangle.axis == PortalAxis.z ? 1 : 0;
    const block = rectangle.axis == PortalAxis.x
        ? BlockId.netherPortalX : BlockId.netherPortalZ;
    foreach (row; 0 .. rectangle.height)
    foreach (along; 0 .. rectangle.width)
        world.setBlock(rectangle.minX + along * dx,
            rectangle.minY + row, rectangle.minZ + along * dz, block);
}

unittest
{
    auto world = new World();
    scope (exit) destroy(world);
    // Clear a small area and construct the cornerless Java minimum frame.
    foreach (x; 18 .. 24) foreach (y; 1 .. 8)
        world.setBlock(x, y, 20, BlockId.air);
    foreach (x; 20 .. 22)
    {
        world.setBlock(x, 1, 20, BlockId.obsidian);
        world.setBlock(x, 5, 20, BlockId.obsidian);
    }
    foreach (y; 2 .. 5)
    {
        world.setBlock(19, y, 20, BlockId.obsidian);
        world.setBlock(22, y, 20, BlockId.obsidian);
    }
    PortalRectangle portal;
    assert(igniteNetherPortal(world, 20, 2, 20, portal));
    assert(portal.width == 2 && portal.height == 3);
    assert(world.getBlock(20, 2, 20) == BlockId.netherPortalX);
    assert(world.isUnobstructed(
        Aabb(20.1f,2.0f,19.9f,20.9f,3.8f,20.1f)));

    auto maximumWorld = new World();
    scope (exit) destroy(maximumWorld);
    foreach (x; 3 .. 28) foreach (y; 1 .. 25)
        maximumWorld.setBlock(x,y,30,BlockId.air);
    foreach (x; 5 .. 26)
    {
        maximumWorld.setBlock(x,1,30,BlockId.obsidian);
        maximumWorld.setBlock(x,23,30,BlockId.obsidian);
    }
    foreach (y; 2 .. 23)
    {
        maximumWorld.setBlock(4,y,30,BlockId.obsidian);
        maximumWorld.setBlock(26,y,30,BlockId.obsidian);
    }
    assert(igniteNetherPortal(maximumWorld,5,2,30,portal));
    assert(portal.width==maximumPortalWidth
        &&portal.height==maximumPortalHeight);
}
