module minecraftd.server.player_saves;

import std.file : exists, read;
import std.path : buildPath;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.math : isFinite, abs;
import std.exception : enforce;
import minecraftd.network.game_protocol : NetworkPlayerState, PacketWriter, PacketReader;
import minecraftd.world.atomic_file : atomicWrite;
import minecraftd.world.world_settings : DimensionId, GameMode;
import minecraftd.game.item.inventory : ItemStack, lastItem, maximumStackSize;

string playerSavePath(string root,string identity)
{
    return buildPath(root,"playerdata",toHexString(sha256Of(identity))~".dat");
}

// Format 1 is independent of network snapshot layout. Keep this decoder when
// adding fields in later file versions; network changes must not invalidate saves.
void writePlayerSave(string root,string identity,const NetworkPlayerState state)
{
    if(!root.length)return;
    PacketWriter writer;writer.putString("MCDE_PLAYER_1");
    writer.putVec3(state.position);writer.putF32(state.yaw);writer.putF32(state.pitch);writer.putF32(state.bodyYaw);
    writer.putU8(cast(ubyte)state.dimension);writer.putU8(cast(ubyte)state.gameMode);
    writer.putBool(state.flying);writer.putF32(state.health);writer.putU8(state.food);
    writer.putF32(state.saturation);writer.putU32(state.score);writer.putU32(state.experienceLevel);
    writer.putF32(state.experienceProgress);writer.putU8(state.deathTime);writer.putString(state.deathMessage);
    writer.putU16(cast(ushort)state.airSupply);writer.putU16(state.fireTicks);writer.putU8(state.selectedSlot);
    void stack(ItemStack v)
    {writer.putU16(cast(ushort)v.item);writer.putU8(v.count);writer.putU8(v.popTicks);
     writer.putU16(v.damage);writer.putU8(v.enchantment);writer.putU8(v.enchantmentLevel);}
    foreach(v;state.inventory.hotbar)stack(v);
    foreach(v;state.inventory.storage)stack(v);
    stack(state.inventory.carried);writer.putU8(state.inventory.station);
    foreach(v;state.inventory.work)stack(v);
    writer.putI32(state.inventory.stationX);writer.putI32(state.inventory.stationY);writer.putI32(state.inventory.stationZ);
    writer.putU16(state.inventory.burnTicks);writer.putU16(state.inventory.cookTicks);
    atomicWrite(playerSavePath(root,identity),writer.data);
}

bool readPlayerSave(string root,string identity,out NetworkPlayerState state)
{
    if(!root.length)return false;
    const path=playerSavePath(root,identity);
    if(!exists(path))return false;
    const bytes=cast(const(ubyte)[])read(path);
    enforce(bytes.length<65536,"Player save is too large: "~path);
    auto reader=PacketReader(bytes);
    enforce(reader.readString()=="MCDE_PLAYER_1","Unsupported player save: "~path);
    NetworkPlayerState loaded;
    loaded.position=reader.readVec3();loaded.yaw=reader.readF32();loaded.pitch=reader.readF32();loaded.bodyYaw=reader.readF32();
    loaded.dimension=cast(DimensionId)reader.readU8();loaded.gameMode=cast(GameMode)reader.readU8();
    loaded.flying=reader.readBool();loaded.health=reader.readF32();loaded.food=reader.readU8();
    loaded.saturation=reader.readF32();loaded.score=reader.readU32();loaded.experienceLevel=reader.readU32();
    loaded.experienceProgress=reader.readF32();loaded.deathTime=reader.readU8();loaded.deathMessage=reader.readString();
    loaded.airSupply=cast(short)reader.readU16();loaded.fireTicks=reader.readU16();loaded.selectedSlot=reader.readU8();
    ItemStack stack()
    {
        import minecraftd.game.item.inventory : ItemId;
        return ItemStack(cast(ItemId)reader.readU16(),reader.readU8(),reader.readU8(),reader.readU16(),reader.readU8(),reader.readU8());
    }
    foreach(ref v;loaded.inventory.hotbar)v=stack();
    foreach(ref v;loaded.inventory.storage)v=stack();
    loaded.inventory.carried=stack();loaded.inventory.station=reader.readU8();
    foreach(ref v;loaded.inventory.work)v=stack();
    loaded.inventory.stationX=reader.readI32();loaded.inventory.stationY=reader.readI32();loaded.inventory.stationZ=reader.readI32();
    loaded.inventory.burnTicks=reader.readU16();loaded.inventory.cookTicks=reader.readU16();
    enforce(reader.valid&&reader.cursor==bytes.length,"Incomplete player save: "~path);
    enforce(isFinite(loaded.position.x)&&isFinite(loaded.position.y)&&isFinite(loaded.position.z)
        &&abs(loaded.position.x)<30_000_000&&abs(loaded.position.z)<30_000_000
        &&loaded.position.y>-4096&&loaded.position.y<4096
        &&isFinite(loaded.yaw)&&isFinite(loaded.pitch)&&abs(loaded.pitch)<=90
        &&loaded.selectedSlot<9&&loaded.dimension<=DimensionId.nether
        &&loaded.gameMode<=GameMode.spectator&&loaded.inventory.station<=3
        &&isFinite(loaded.health)&&isFinite(loaded.saturation)&&isFinite(loaded.bodyYaw)
        &&isFinite(loaded.experienceProgress),"Invalid player pose: "~path);
    foreach(entry;loaded.inventory.hotbar[]~loaded.inventory.storage[]
        ~loaded.inventory.work[]~[loaded.inventory.carried])
        enforce(entry.item<=lastItem&&entry.count<=maximumStackSize(entry.item),
            "Invalid inventory in player save: "~path);
    state=loaded;
    return true;
}
