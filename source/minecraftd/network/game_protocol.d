module minecraftd.network.game_protocol;

import core.stdc.string : memcpy;
import minecraftd.common.math3d : Vec3;
import minecraftd.game.item.inventory : Inventory, ItemId, ItemStack;
import minecraftd.world.world_settings : DimensionId, GameMode;

enum GamePacketType : ubyte
{
    loginRequest = 1,
    loginAccepted,
    playerInput,
    snapshot,
    blockChange,
    chatSubmit,
    chatBroadcast,
    disconnect,
    keepAlive,
    keepAliveReply,
    itemPickup,
    playerAction,
    combatEvent,
    dimensionChange,
}

enum uint maximumGamePacketBytes = 1024 * 1024;
enum ushort gameProtocolVersion = 13;

enum DamageCause : ubyte
{
    none,
    generic,
    fall,
    drown,
}

enum CombatEventType : ubyte
{
    criticalHit = 1,
}

enum PlayerActionType : ubyte
{
    dropItem = 1,
    dropStack,
    respawn,
    inventoryClick,
    inventoryQuickMove,
    inventoryHotbarSwap,
    inventoryDrop,
    inventoryCollect,
    inventoryClose,
    pickBlock,
}

enum ubyte inputForward = 1 << 0;
enum ubyte inputBack = 1 << 1;
enum ubyte inputLeft = 1 << 2;
enum ubyte inputRight = 1 << 3;
enum ubyte inputJump = 1 << 4;
enum ubyte inputCrouch = 1 << 5;
enum ubyte inputSprint = 1 << 6;
enum ubyte inputAttack = 1 << 7;

struct PlayerInputCommand
{
    uint sequence = 0;
    ubyte flags = 0;
    ubyte selectedSlot = 0;
    bool usePressed = false;
    float yaw = 0.0f;
    float pitch = 0.0f;
    bool attackPressed = false;
    bool flightTogglePressed = false;
    ubyte skinParts = 0x3F;
    bool mainHandRight = true;

    bool down(ubyte flag) const { return (flags & flag) != 0; }
}

struct NetworkPlayerState
{
    uint id;
    string name;
    Vec3 position;
    Vec3 velocity;
    float yaw;
    float pitch;
    float bodyYaw;
    float walkPosition;
    float walkSpeed;
    float attackProgress;
    bool crouching;
    bool sprinting;
    bool onGround;
    float health;
    ubyte food;
    float saturation;
    uint experienceLevel;
    float experienceProgress;
    uint score;
    ubyte deathTime;
    string deathMessage;
    ubyte selectedSlot;
    Inventory inventory;
    bool mining;
    int miningX;
    int miningY;
    int miningZ;
    float miningProgress;
    ubyte hurtTime;
    float hurtDirection;
    uint damageEventId;
    DamageCause damageCause;
    GameMode gameMode;
    bool hardcore;
    bool flying;
    ubyte skinParts = 0x3F;
    bool mainHandRight = true;
    DimensionId dimension;
    float portalProgress;
    short airSupply = 300;
    bool inWater;
    bool eyeInWater;
    bool swimming;
}

struct DroppedItemState
{
    uint id;
    ItemId item;
    ubyte count;
    Vec3 position;
    Vec3 velocity;
    uint age;
    uint pickupDelay;
    DimensionId dimension;
}

struct GamePacket
{
    GamePacketType type;
    ubyte[] payload;
}

struct PacketWriter
{
    ubyte[] data;

    void putU8(ubyte value) { data ~= value; }
    void putBool(bool value) { putU8(value ? 1 : 0); }
    void putU16(ushort value)
    {
        data ~= cast(ubyte) (value >> 8);
        data ~= cast(ubyte) value;
    }
    void putU32(uint value)
    {
        data ~= cast(ubyte) (value >> 24);
        data ~= cast(ubyte) (value >> 16);
        data ~= cast(ubyte) (value >> 8);
        data ~= cast(ubyte) value;
    }
    void putI32(int value) { putU32(cast(uint) value); }
    void putF32(float value)
    {
        uint bits;
        memcpy(&bits, &value, bits.sizeof);
        putU32(bits);
    }
    void putVec3(Vec3 value)
    {
        putF32(value.x); putF32(value.y); putF32(value.z);
    }
    void putString(string value)
    {
        const length = value.length > ushort.max ? ushort.max : value.length;
        putU16(cast(ushort) length);
        data ~= cast(const(ubyte)[]) value[0 .. length];
    }
    void putInventory(const Inventory inventory)
    {
        foreach (stack; inventory.hotbar)
        {
            putU8(cast(ubyte) stack.item);
            putU8(stack.count);
            putU8(stack.popTicks);
        }
        foreach (stack; inventory.storage)
        {
            putU8(cast(ubyte) stack.item);
            putU8(stack.count);
            putU8(stack.popTicks);
        }
        putU8(cast(ubyte) inventory.carried.item);
        putU8(inventory.carried.count);
        putU8(inventory.carried.popTicks);
    }
    void putPlayer(const NetworkPlayerState player)
    {
        putU32(player.id); putString(player.name);
        putVec3(player.position); putVec3(player.velocity);
        putF32(player.yaw); putF32(player.pitch); putF32(player.bodyYaw);
        putF32(player.walkPosition); putF32(player.walkSpeed);
        putF32(player.attackProgress);
        putBool(player.crouching); putBool(player.sprinting); putBool(player.onGround);
        putF32(player.health); putU8(player.food); putF32(player.saturation);
        putU32(player.experienceLevel); putF32(player.experienceProgress);
        putU32(player.score); putU8(player.deathTime);
        putString(player.deathMessage);
        putU8(player.selectedSlot); putInventory(player.inventory);
        putBool(player.mining);
        putI32(player.miningX); putI32(player.miningY); putI32(player.miningZ);
        putF32(player.miningProgress);
        putU8(player.hurtTime); putF32(player.hurtDirection);
        putU32(player.damageEventId); putU8(cast(ubyte) player.damageCause);
        putU8(cast(ubyte) player.gameMode); putBool(player.hardcore);
        putBool(player.flying);
        putU8(player.skinParts); putBool(player.mainHandRight);
        putU8(cast(ubyte) player.dimension); putF32(player.portalProgress);
        putU16(cast(ushort)player.airSupply);
        putBool(player.inWater); putBool(player.eyeInWater); putBool(player.swimming);
    }
    void putDroppedItem(const DroppedItemState item)
    {
        putU32(item.id); putU8(cast(ubyte) item.item); putU8(item.count);
        putVec3(item.position); putVec3(item.velocity); putU32(item.age);
        putU32(item.pickupDelay);
        putU8(cast(ubyte) item.dimension);
    }
}

struct PacketReader
{
    const(ubyte)[] data;
    size_t cursor;
    bool valid = true;

    private bool require(size_t amount)
    {
        if (!valid || cursor + amount > data.length)
        {
            valid = false;
            return false;
        }
        return true;
    }
    ubyte readU8()
    {
        if (!require(1)) return 0;
        return data[cursor++];
    }
    bool readBool() { return readU8() != 0; }
    ushort readU16()
    {
        if (!require(2)) return 0;
        const value = cast(ushort) ((cast(ushort) data[cursor] << 8)
            | cast(ushort) data[cursor + 1]);
        cursor += 2;
        return value;
    }
    uint readU32()
    {
        if (!require(4)) return 0;
        const value = (cast(uint) data[cursor] << 24)
            | (cast(uint) data[cursor + 1] << 16)
            | (cast(uint) data[cursor + 2] << 8)
            | cast(uint) data[cursor + 3];
        cursor += 4;
        return value;
    }
    int readI32() { return cast(int) readU32(); }
    float readF32()
    {
        const bits = readU32();
        float value;
        memcpy(&value, &bits, value.sizeof);
        return value;
    }
    Vec3 readVec3() { return Vec3(readF32(), readF32(), readF32()); }
    string readString()
    {
        const length = readU16();
        if (!require(length)) return "";
        const result = cast(string) data[cursor .. cursor + length].idup;
        cursor += length;
        return result;
    }
    Inventory readInventory()
    {
        Inventory result;
        foreach (ref stack; result.hotbar)
            stack = ItemStack(cast(ItemId) readU8(), readU8(), readU8());
        foreach (ref stack; result.storage)
            stack = ItemStack(cast(ItemId) readU8(), readU8(), readU8());
        result.carried = ItemStack(cast(ItemId) readU8(), readU8(), readU8());
        return result;
    }
    NetworkPlayerState readPlayer()
    {
        NetworkPlayerState result;
        result.id = readU32(); result.name = readString();
        result.position = readVec3(); result.velocity = readVec3();
        result.yaw = readF32(); result.pitch = readF32(); result.bodyYaw = readF32();
        result.walkPosition = readF32(); result.walkSpeed = readF32();
        result.attackProgress = readF32();
        result.crouching = readBool(); result.sprinting = readBool();
        result.onGround = readBool(); result.health = readF32();
        result.food = readU8(); result.saturation = readF32();
        result.experienceLevel = readU32();
        result.experienceProgress = readF32();
        result.score = readU32(); result.deathTime = readU8();
        result.deathMessage = readString();
        result.selectedSlot = readU8(); result.inventory = readInventory();
        result.mining = readBool();
        result.miningX = readI32(); result.miningY = readI32();
        result.miningZ = readI32(); result.miningProgress = readF32();
        result.hurtTime = readU8(); result.hurtDirection = readF32();
        result.damageEventId = readU32();
        result.damageCause = cast(DamageCause) readU8();
        result.gameMode = cast(GameMode) readU8();
        result.hardcore = readBool(); result.flying = readBool();
        result.skinParts = readU8(); result.mainHandRight = readBool();
        result.dimension = cast(DimensionId) readU8();
        result.portalProgress = readF32();
        result.airSupply = cast(short)readU16();
        result.inWater = readBool(); result.eyeInWater = readBool();
        result.swimming = readBool();
        return result;
    }
    DroppedItemState readDroppedItem()
    {
        DroppedItemState result;
        result.id = readU32(); result.item = cast(ItemId) readU8();
        result.count = readU8(); result.position = readVec3();
        result.velocity = readVec3(); result.age = readU32();
        result.pickupDelay = readU32();
        result.dimension = cast(DimensionId) readU8();
        return result;
    }
}

ubyte[] framePacket(GamePacketType type, const(ubyte)[] payload)
{
    const length = cast(uint) payload.length + 1;
    PacketWriter output;
    output.putU32(length);
    output.putU8(cast(ubyte) type);
    output.data ~= payload;
    return output.data;
}

uint decodeFrameLength(const(ubyte)[] header)
{
    PacketReader reader = PacketReader(header);
    return reader.readU32();
}

ubyte[] encodeInput(PlayerInputCommand input)
{
    PacketWriter writer;
    writer.putU32(input.sequence); writer.putU8(input.flags);
    writer.putU8(input.selectedSlot); writer.putBool(input.usePressed);
    writer.putF32(input.yaw); writer.putF32(input.pitch);
    writer.putBool(input.attackPressed);
    writer.putBool(input.flightTogglePressed);
    writer.putU8(input.skinParts); writer.putBool(input.mainHandRight);
    return framePacket(GamePacketType.playerInput, writer.data);
}

PlayerInputCommand decodeInput(const(ubyte)[] payload, out bool valid)
{
    PacketReader reader = PacketReader(payload);
    PlayerInputCommand result;
    result.sequence = reader.readU32(); result.flags = reader.readU8();
    result.selectedSlot = reader.readU8(); result.usePressed = reader.readBool();
    result.yaw = reader.readF32(); result.pitch = reader.readF32();
    result.attackPressed = reader.readBool();
    result.flightTogglePressed = reader.readBool();
    result.skinParts = reader.readU8(); result.mainHandRight = reader.readBool();
    valid = reader.valid;
    return result;
}

unittest
{
    auto input = PlayerInputCommand(42, inputForward | inputJump,
        3, true, 90.0f, -12.0f, true);
    input.skinParts = 0x15;
    input.mainHandRight = false;
    auto encoded = encodeInput(input);
    assert(decodeFrameLength(encoded[0 .. 4]) == encoded.length - 4);
    bool valid;
    const decoded = decodeInput(encoded[5 .. $], valid);
    assert(valid && decoded.sequence == 42 && decoded.usePressed
        && decoded.attackPressed);
    assert(decoded.down(inputForward) && decoded.down(inputJump));
    assert(decoded.skinParts == 0x15 && !decoded.mainHandRight);

    NetworkPlayerState player;
    player.id = 7;
    player.name = "Steve";
    player.score = 42;
    player.deathTime = 20;
    player.deathMessage = "Steve fell from a high place";
    player.skinParts = 0x2A;
    player.mainHandRight = false;
    player.dimension = DimensionId.nether;
    player.portalProgress = 0.75f;
    player.inventory.storage[4] = ItemStack(ItemId.stone,37,2);
    player.inventory.carried = ItemStack(ItemId.dirt,12,0);
    PacketWriter stateWriter;
    stateWriter.putPlayer(player);
    PacketReader stateReader = PacketReader(stateWriter.data);
    const restored = stateReader.readPlayer();
    assert(stateReader.valid && restored.id == 7 && restored.score == 42);
    assert(restored.deathTime == 20
        && restored.deathMessage == "Steve fell from a high place");
    assert(restored.skinParts == 0x2A && !restored.mainHandRight);
    assert(restored.dimension == DimensionId.nether
        && restored.portalProgress == 0.75f);
    assert(restored.inventory.storage[4].item==ItemId.stone
        && restored.inventory.storage[4].count==37);
    assert(restored.inventory.carried.item==ItemId.dirt
        && restored.inventory.carried.count==12);
}
