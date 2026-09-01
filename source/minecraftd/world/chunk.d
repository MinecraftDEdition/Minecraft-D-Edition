module minecraftd.world.chunk;

import minecraftd.world.block : BlockId;

/// Horizontal address of a Java-sized 16x16 chunk column.
struct ChunkCoordinate
{
    int x;
    int z;
}

final class Chunk
{
    enum int width = 16;
    enum int depth = 16;
    enum int minimumY = -64;
    enum int maximumY = 319;
    enum int height = maximumY - minimumY + 1;

    immutable int chunkX;
    immutable int chunkZ;
    private BlockId[width * height * depth] blocks;
    private uint[height] occupiedPerY;
    private int occupiedMinimumY=maximumY+1;
    private int occupiedMaximumY=minimumY-1;

    this(int chunkX = 0, int chunkZ = 0)
    {
        this.chunkX = chunkX;
        this.chunkZ = chunkZ;
    }

    BlockId get(int localX, int y, int localZ) const
    {
        if (localX < 0 || localX >= width || y < minimumY || y > maximumY
            || localZ < 0 || localZ >= depth)
            return BlockId.air;
        return blocks[((y - minimumY) * depth + localZ) * width + localX];
    }

    void set(int localX, int y, int localZ, BlockId block)
    {
        if (localX < 0 || localX >= width || y < minimumY || y > maximumY
            || localZ < 0 || localZ >= depth)
            return;
        const index=((y-minimumY)*depth+localZ)*width+localX;
        const previous=blocks[index];
        if(previous==block)return;
        blocks[index]=block;
        const layer=y-minimumY;
        if(previous!=BlockId.air)--occupiedPerY[layer];
        if(block!=BlockId.air)++occupiedPerY[layer];
        if(block!=BlockId.air)
        {
            if(y<occupiedMinimumY)occupiedMinimumY=y;
            if(y>occupiedMaximumY)occupiedMaximumY=y;
        }
        else if(previous!=BlockId.air
            &&occupiedPerY[layer]==0
            &&(y==occupiedMinimumY||y==occupiedMaximumY))
            recalculateOccupiedRange();
    }

    bool empty() const{return occupiedMaximumY<occupiedMinimumY;}
    int minimumOccupiedY() const{return occupiedMinimumY;}
    int maximumOccupiedY() const{return occupiedMaximumY;}

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
        occupiedPerY[]=0;
        foreach (index, value; data)
        {
            blocks[index] = cast(BlockId) value;
            if(blocks[index]!=BlockId.air)
                ++occupiedPerY[index/(width*depth)];
        }
        recalculateOccupiedRange();
        return true;
    }

private:
    void recalculateOccupiedRange()
    {
        occupiedMinimumY=maximumY+1;
        occupiedMaximumY=minimumY-1;
        foreach(y;minimumY..maximumY+1)
        {
            if(occupiedPerY[y-minimumY]==0)continue;
            if(y<occupiedMinimumY)occupiedMinimumY=y;
            if(y>occupiedMaximumY)occupiedMaximumY=y;
        }
    }
}

int chunkCoordinate(int blockCoordinate)
{
    int result = blockCoordinate / Chunk.width;
    if (blockCoordinate < 0 && blockCoordinate % Chunk.width != 0)
        --result;
    return result;
}

int localCoordinate(int blockCoordinate)
{
    int result = blockCoordinate % Chunk.width;
    if (result < 0) result += Chunk.width;
    return result;
}

unittest
{
    assert(chunkCoordinate(0) == 0 && chunkCoordinate(15) == 0);
    assert(chunkCoordinate(16) == 1 && chunkCoordinate(-1) == -1);
    assert(chunkCoordinate(-16) == -1 && chunkCoordinate(-17) == -2);
    assert(localCoordinate(-1) == 15 && localCoordinate(-16) == 0);
    auto chunk = new Chunk(-1, 2);
    scope(exit) destroy(chunk);
    chunk.set(15, -64, 0, BlockId.stone);
    chunk.set(0, 319, 15, BlockId.dirt);
    assert(chunk.get(15, -64, 0) == BlockId.stone);
    assert(chunk.get(0, 319, 15) == BlockId.dirt);
}
