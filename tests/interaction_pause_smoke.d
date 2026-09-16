module interaction_pause_smoke;
import core.thread : Thread;
import core.time : msecs;
import std.file : tempDir, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.stdio : writeln;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.network.game_protocol;
import minecraftd.world.world_settings : WorldSettings, WorldType, GameMode;
import minecraftd.game.item.inventory : ItemId;
import minecraftd.world.block : BlockId;
import minecraftd.common.math3d : Vec3;
void main()
{
    const root=buildPath(tempDir(),"mcde-interaction-"~randomUUID().toString());
    mkdirRecurse(root); scope(exit)rmdirRecurse(root);
    WorldSettings settings; settings.gameMode=GameMode.creative; settings.worldType=WorldType.flat;
    auto server=new IntegratedGameServer(settings,root); scope(exit)destroy(server);
    auto a=new GameConnection("Builder","127.0.0.1",server.port); scope(exit)destroy(a);
    GameConnection b; scope(exit)if(b !is null)destroy(b);
    uint id,ack; bool paused; NetworkPlayerState state; uint changes,observerChanges;
    void poll()
    {
        foreach(packet;a.poll())
        {
            auto r=PacketReader(packet.payload);
            if(packet.type==GamePacketType.loginAccepted){r.readU16();id=r.readU32();}
            if(packet.type==GamePacketType.snapshot)
            {
                r.readU32();ack=r.readU32();paused=r.readBool();
                foreach(_;0..r.readU16()){auto p=r.readPlayer();if(p.id==id)state=p;}
            }
            if(packet.type==GamePacketType.blockChange)++changes;
        }
        if(b !is null)foreach(packet;b.poll())
            if(packet.type==GamePacketType.blockChange)++observerChanges;
    }
    void waitFor(bool delegate() ready)
    {
        foreach(_;0..300){poll();if(ready())return;Thread.sleep(10.msecs);}
        assert(0,"Timed out waiting for authoritative response");
    }
    void click(ubyte buttons)
    {
        PacketWriter w;w.putU8(0);w.putU8(buttons);w.putF32(0);w.putF32(90);
        a.send(GamePacketType.interaction,w.data);
    }
    waitFor({return id!=0&&state.id==id;});
    const position=state.position;
    click(1); waitFor({return changes==1;});
    assert(ack==0 && state.position==position,"Click must not advance movement");
    PacketWriter inventory;inventory.putU8(cast(ubyte)PlayerActionType.creativeSetHotbar);
    inventory.putU16(cast(ushort)ItemId.oakLog);inventory.putU8(0);
    a.send(GamePacketType.playerAction,inventory.data);
    waitFor({return state.inventory.hotbar[0].item==ItemId.oakLog;});
    click(2);waitFor({return changes==2;});
    assert(ack==0,"Placement must not synthesize a movement tick");
    server.setPaused(true);
    auto input=PlayerInputCommand(1,inputForward,0,false,0,0);input.moveForward=1;
    a.sendFramed(encodeInput(input));
    waitFor({return paused&&ack==1;});
    assert(state.position.z>position.z,"Pre-pause prediction must be simulated, not discarded");
    const frozen=state.position;
    foreach(_;0..15){Thread.sleep(10.msecs);poll();assert(state.position==frozen);}
    click(1);foreach(_;0..15){Thread.sleep(10.msecs);poll();}
    assert(changes==2,"Singleplayer paused clicks must not edit terrain");
    server.setPaused(false);waitFor({return !paused;});
    assert(state.position==frozen,"Resume must not replay old held movement");
    b=new GameConnection("Observer","127.0.0.1",server.port);
    waitFor({return !server.canPause();});
    server.setPaused(true);
    click(1);waitFor({return changes==3&&observerChanges==1;});
    assert(!paused,"A host menu must not pause a shared world");
    uint sequence=2;
    foreach(buttons;[cast(ubyte)1,cast(ubyte)2])
    {
        // Let any previous meaningful interaction finish its animation.
        foreach(_;0..8)
        {
            auto idle=PlayerInputCommand(sequence++,0,0,false,0,-90);
            a.sendFramed(encodeInput(idle));Thread.sleep(50.msecs);poll();
        }
        PacketWriter emptyClick;emptyClick.putU8(0);emptyClick.putU8(buttons);
        emptyClick.putF32(0);emptyClick.putF32(-90);
        a.send(GamePacketType.interaction,emptyClick.data);
        bool swung;
        foreach(_;0..8)
        {
            auto idle=PlayerInputCommand(sequence++,0,0,false,0,-90);
            a.sendFramed(encodeInput(idle));Thread.sleep(50.msecs);poll();
            swung=swung||state.attackProgress>0;
        }
        assert(swung==(buttons==1),"Air attack must swing; empty use must not");
    }
    writeln("PASS: frame clicks, placement, pause input drain, stable resume, two-client edits");
}
