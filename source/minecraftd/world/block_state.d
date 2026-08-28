module minecraftd.world.block_state;

import minecraftd.world.block : BlockId;

struct BlockState
{
    BlockId id;

    bool isAir() const { return id == BlockId.air; }
}
