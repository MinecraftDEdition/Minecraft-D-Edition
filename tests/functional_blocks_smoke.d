module functional_blocks_smoke;

import core.thread:Thread;
import core.time:msecs;
import std.file:tempDir,mkdirRecurse,rmdirRecurse;
import std.path:buildPath;
import std.uuid:randomUUID;
import std.stdio:writeln;
import minecraftd.client.network.game_connection:GameConnection;
import minecraftd.server.integrated_game_server:IntegratedGameServer;
import minecraftd.network.game_protocol;
import minecraftd.game.item.inventory;
import minecraftd.world.world_settings;

void main()
{
    const directory=buildPath(tempDir(),"mcde-functional-smoke-"~randomUUID().toString());
    mkdirRecurse(directory);
    scope(exit)rmdirRecurse(directory);
    WorldSettings settings;settings.gameMode=GameMode.creative;settings.worldType=WorldType.flat;
    auto server=new IntegratedGameServer(settings,directory);
    scope(exit)destroy(server);
    auto host=new GameConnection("Host","127.0.0.1",server.port);
    scope(exit)destroy(host);
    GameConnection guest;
    scope(exit)if(guest !is null)destroy(guest);
    NetworkPlayerState[string] states;
    string[] replies;
    void pump()
    {
        foreach(client;[host,guest])if(client !is null)
        foreach(packet;client.poll())
        {
            PacketReader reader=PacketReader(packet.payload);
            if(packet.type==GamePacketType.snapshot)
            {
                reader.readU32();reader.readU32();reader.readBool();
                const count=reader.readU16();
                foreach(i;0..count){auto state=reader.readPlayer();assert(reader.valid);states[state.name]=state;}
            }
            else if(packet.type==GamePacketType.chatBroadcast)
            {reader.readBool();replies~=reader.readString();}
        }
    }
    void until(scope bool delegate() condition,string description)
    {
        foreach(i;0..250){pump();if(condition())return;Thread.sleep(20.msecs);}
        assert(false,description);
    }
    void command(GameConnection client,string text)
    {PacketWriter writer;writer.putString(text);client.send(GamePacketType.chatSubmit,writer.data);}
    int count(string name,ItemId item)
    {
        auto state=name in states;if(state is null)return 0;
        int total;foreach(i;0..Inventory.slotCount)
        {const s=state.inventory.slot(i);if(s.item==item)total+=s.count;}
        return total;
    }
    until((){return ("Host" in states) !is null;},"Host login");
    guest=new GameConnection("Guest","127.0.0.1",server.port);
    until((){return ("Guest" in states) !is null;},"Guest login");
    command(host,"/give @s netherite_sword 2");
    until(()=>count("Host",ItemId.netheriteSword)==2,"Highest item ID/tool stacks roundtrip");
    foreach(i;0..Inventory.slotCount)
        if(states["Host"].inventory.slot(i).item==ItemId.netheriteSword)
            assert(states["Host"].inventory.slot(i).count==1);
    command(guest,"/give @s diamond 1");
    until((){foreach(r;replies)if(r=="You do not have permission to use host commands")return true;return false;},"Guest permission denial");
    assert(count("Guest",ItemId.diamond)==0);
    command(host,"/give @a bread 3");
    until(()=>count("Host",ItemId.bread)==3&&count("Guest",ItemId.bread)==3,"Give to all players");
    command(host,"/clear @a bread");
    until(()=>count("Host",ItemId.bread)==0&&count("Guest",ItemId.bread)==0,"Filtered clear");
    command(host,"/gamemode survival @s");
    until(()=>states["Host"].gameMode==GameMode.survival,"Game mode command");
    command(host,"/xp 15 @s");
    until(()=>states["Host"].experienceLevel==15,"Experience command");
    const x=states["Host"].position.x;
    command(host,"/tp @s ~2 ~ ~2");
    until(()=>states["Host"].position.x>x+1.5f,"Relative teleport");
    command(host,"/kill Guest");
    until(()=>states["Guest"].health<=0,"Kill command");
    writeln("PASS: two-client protocol, host permissions, item ID 255, legal tool stacks, give/clear/gamemode/xp/tp/kill");
}
