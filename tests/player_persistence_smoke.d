module player_persistence_smoke;

import core.thread : Thread;
import core.time : msecs;
import std.file : tempDir,mkdirRecurse,rmdirRecurse,exists,write;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.stdio : writeln;
import minecraftd.server.integrated_game_server;
import minecraftd.server.player_saves;
import minecraftd.client.network.game_connection;
import minecraftd.network.game_protocol;
import minecraftd.world.world_settings;
import minecraftd.game.item.inventory;
import minecraftd.common.math3d;
import minecraftd.client.network.multiplayer_client;
import minecraftd.client.player.local_player;
import minecraftd.client.chat.chat_state;
import minecraftd.world.world;

void main()
{
    const root=buildPath(tempDir(),"mcde-save-"~randomUUID().toString());
    mkdirRecurse(root);scope(exit)rmdirRecurse(root);
    WorldSettings settings;settings.worldType=WorldType.flat;settings.gameMode=GameMode.creative;
    auto server=new IntegratedGameServer(settings,root);
    GameConnection connection;uint id;NetworkPlayerState state,loginState;
    bool saveDone,saveBusy,saveFinished;
    void connect()
    {connection=new GameConnection("Owner","127.0.0.1",server.port);id=0;}
    void poll()
    {
        foreach(packet;connection.poll())
        {
            auto r=PacketReader(packet.payload);
            if(packet.type==GamePacketType.loginAccepted)
            {r.readU16();id=r.readU32();r.readString();r.readVec3();r.readU8();loginState=r.readPlayer();assert(r.valid);}
            if(packet.type==GamePacketType.snapshot)
            {r.readU32();r.readU32();r.readBool();foreach(_;0..r.readU16()){auto p=r.readPlayer();if(p.id==id)state=p;}}
            if(packet.type==GamePacketType.saveComplete){saveDone=r.readBool();assert(saveDone&&r.valid);}
            if(packet.type==GamePacketType.saveStatus)
            {r.readU32();const busy=r.readBool();assert(!r.readBool());if(busy)saveBusy=true;else saveFinished=true;}
        }
    }
    void waitFor(bool delegate() ready)
    {foreach(_;0..1000){poll();if(ready())return;Thread.sleep(10.msecs);}assert(0,"Timed out waiting for save/recovery");}
    connect();waitFor({return id!=0&&state.id==id;});
    PacketWriter tp;tp.putString("/tp 12.25 -59 -23.75");connection.send(GamePacketType.chatSubmit,tp.data);
    waitFor({return state.position==Vec3(12.25f,-59,-23.75f);});
    PacketWriter inv;inv.putU8(cast(ubyte)PlayerActionType.creativeSetHotbar);
    inv.putU16(cast(ushort)ItemId.diamondSword);inv.putU8(4);
    connection.send(GamePacketType.playerAction,inv.data);
    waitFor({return state.inventory.hotbar[4].item==ItemId.diamondSword;});
    server.setPaused(true);server.requestSave();
    waitFor({return saveBusy&&saveFinished;});
    NetworkPlayerState saved;
    assert(readPlayerSave(root,"host",saved));
    assert(saved.position==state.position&&saved.inventory.hotbar[4].item==ItemId.diamondSword);
    PacketWriter quit;quit.putF32(73.25f);quit.putF32(-18.5f);
    connection.send(GamePacketType.saveAndQuit,quit.data);waitFor({return saveDone;});
    assert(readPlayerSave(root,"host",saved)&&saved.yaw==73.25f&&saved.pitch==-18.5f);
    destroy(connection);connection=null;destroy(server);
    server=new IntegratedGameServer(settings,root);
    connect();waitFor({return id!=0&&state.id==id;});
    assert(loginState.position==saved.position&&loginState.yaw==saved.yaw&&loginState.pitch==saved.pitch);
    assert(loginState.inventory.hotbar[4]==saved.inventory.hotbar[4]);
    // Shutdown without a graceful client logout still saves remaining players.
    destroy(server);destroy(connection);
    assert(readPlayerSave(root,"host",saved)&&saved.inventory.hotbar[4].item==ItemId.diamondSword);
    server=new IntegratedGameServer(settings,root);
    auto clientWorld=new World();auto localPlayer=new LocalPlayer();auto chat=new ChatState();
    auto client=new MultiplayerClient(new GameConnection("Owner","127.0.0.1",server.port),clientWorld,localPlayer);
    foreach(_;0..1000){client.poll(chat);if(client.loginComplete)break;Thread.sleep(10.msecs);}
    assert(client.loginComplete&&localPlayer.position==saved.position);
    assert(localPlayer.yaw==saved.yaw&&localPlayer.pitch==saved.pitch);
    assert(localPlayer.inventory.hotbar[4]==saved.inventory.hotbar[4]);
    localPlayer.yaw=-17.75f;localPlayer.pitch=23.5f;
    client.requestDisconnect();assert(!client.disconnectReason.length);
    assert(readPlayerSave(root,"host",saved)&&saved.yaw==-17.75f&&saved.pitch==23.5f);
    destroy(client);destroy(server);destroy(clientWorld);destroy(localPlayer);destroy(chat);

    // Storage, cursor and crafting slots and item metadata are all durable.
    saved.inventory.storage[3]=ItemStack(ItemId.oakLog,37);
    saved.inventory.carried=ItemStack(ItemId.diamondPickaxe,1,0,127,1,3);
    saved.inventory.station=1;saved.inventory.work[0]=ItemStack(ItemId.birchLog,7);
    saved.dimension=DimensionId.nether;saved.selectedSlot=4;
    writePlayerSave(root,"account:guest",saved);
    NetworkPlayerState restored;assert(readPlayerSave(root,"account:guest",restored));
    assert(restored.inventory==saved.inventory&&restored.dimension==DimensionId.nether&&restored.selectedSlot==4);
    assert(readPlayerSave(root,"host",restored)&&restored.inventory.storage[3].empty(),"Player identities must remain separate");
    assert(!exists(playerSavePath(root,"host")~".tmp"));
    // An interrupted replacement must leave the last committed player intact.
    write(playerSavePath(root,"host")~".tmp","partial write");
    NetworkPlayerState previous=restored;
    assert(readPlayerSave(root,"host",restored)&&restored.position==previous.position
        &&restored.inventory==previous.inventory&&restored.yaw==previous.yaw);
    writePlayerSave(root,"host",restored);
    assert(!exists(playerSavePath(root,"host")~".tmp"));
    writeln("PASS: paused autosave, final view, exact position, inventory, reconnect and server shutdown persistence");
}
