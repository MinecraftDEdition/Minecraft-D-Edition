module zombie_network_smoke;
import core.thread : Thread;
import core.time : msecs;
import std.file : tempDir,mkdirRecurse,rmdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.stdio : writeln;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.game.entity.zombie : ZombieState;
import minecraftd.game.item.inventory : ItemId;
import minecraftd.network.game_protocol;
import minecraftd.world.world_settings : WorldSettings,WorldType,GameMode;

void main()
{
    const root=buildPath(tempDir(),"mcde-zombie-network-"~randomUUID().toString());
    mkdirRecurse(root);scope(exit)rmdirRecurse(root);
    WorldSettings settings;settings.gameMode=GameMode.creative;settings.worldType=WorldType.flat;
    auto server=new IntegratedGameServer(settings,root);scope(exit)destroy(server);
    auto a=new GameConnection("ZombieTester","127.0.0.1",server.port());scope(exit)destroy(a);
    auto b=new GameConnection("ZombieObserver","127.0.0.1",server.port());scope(exit)destroy(b);
    uint[2] ids;ZombieState[][2] mobs;bool egg;
    void poll(GameConnection connection,size_t index)
    {
        foreach(packet;connection.poll())
        {
            auto r=PacketReader(packet.payload);
            if(packet.type==GamePacketType.loginAccepted){r.readU16();ids[index]=r.readU32();}
            else if(packet.type==GamePacketType.snapshot)
            {
                r.readU32();r.readU32();r.readBool();
                foreach(_;0..r.readU16())
                {
                    auto p=r.readPlayer();
                    if(index==0&&p.id==ids[0])egg=p.inventory.hotbar[0].item==ItemId.zombieSpawnEgg;
                }
                foreach(_;0..r.readU16())r.readDroppedItem();
                mobs[index]=null;
                foreach(_;0..r.readU16())mobs[index]~=r.readZombie();
                assert(r.valid&&r.cursor==r.data.length);
            }
        }
    }
    foreach(_;0..300)
    {
        poll(a,0);poll(b,1);if(ids[0]&&ids[1])break;
        Thread.sleep(20.msecs);
    }
    assert(ids[0]&&ids[1]);
    PacketWriter action;action.putU8(cast(ubyte)PlayerActionType.creativeSetHotbar);
    action.putU16(cast(ushort)ItemId.zombieSpawnEgg);action.putU8(0);
    a.send(GamePacketType.playerAction,action.data);
    foreach(_;0..100){poll(a,0);poll(b,1);if(egg)break;Thread.sleep(20.msecs);}
    assert(egg,"Creative egg must survive the 16-bit network round trip");
    auto input=PlayerInputCommand(1,0,0,true,0,90);
    auto bytes=encodeInput(input);a.send(GamePacketType.playerInput,bytes[5..$]);
    foreach(_;0..200)
    {
        poll(a,0);poll(b,1);if(mobs[0].length&&mobs[1].length)break;
        Thread.sleep(20.msecs);
    }
    assert(mobs[0].length==1&&mobs[1].length==1);
    assert(mobs[0][0].id==mobs[1][0].id&&mobs[0][0].position==mobs[1][0].position);
    writeln("Creative egg spawned one authoritative zombie visible to both clients");
}
