module minecraftd.world.chunk;

import minecraftd.world.block : BlockId;

final class Chunk
{
    // A finite prototype region. 64x32x64 is large enough to make terrain
    // exploration meaningful while the networking layer still transfers one
    // complete authoritative block snapshot on login.
    enum int width = 64;
    enum int height = 32;
    enum int depth = 64;

    private BlockId[width * height * depth] blocks;

    BlockId get(int x, int y, int z) const
    {
        if (x < 0 || x >= width || y < 0 || y >= height || z < 0 || z >= depth)
            return BlockId.air;
        return blocks[(y * depth + z) * width + x];
    }

    void set(int x, int y, int z, BlockId block)
    {
        if (x < 0 || x >= width || y < 0 || y >= height || z < 0 || z >= depth)
            return;
        blocks[(y * depth + z) * width + x] = block;
    }

    ubyte[] snapshot() const
    {
        auto result = new ubyte[blocks.length];
        foreach (index, block; blocks)
            result[index] = cast(ubyte) block;
        return result;
    }

    bool restore(const(ubyte)[] data)
    {
        if (data.length != blocks.length)
            return false;
        foreach (index, value; data)
            blocks[index] = cast(BlockId) value;
        return true;
    }
}
