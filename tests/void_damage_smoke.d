module void_damage_smoke;

version(Windows):

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.random : uniform;

import minecraftd.client.chat.chat_state : ChatState;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.network.game_protocol : PlayerInputCommand;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.world.chunk : Chunk;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : GameMode, WorldSettings,
    saveWorldMetadata;

void main()
{
    const directory=buildPath(tempDir(),"minecraft-d-void-smoke-"
        ~to!string(uniform(1_000_000,9_999_999)));
    mkdirRecurse(buildPath(directory,"chunks"));
    scope(exit)rmdirRecurse(directory);
    WorldSettings settings;
    settings.name="Void Damage Smoke";
    settings.folder=settings.name;
    settings.gameMode=GameMode.survival;
    settings.spawn.x=0.5f;settings.spawn.y=-129.0f;settings.spawn.z=0.5f;
    saveWorldMetadata(directory,settings);
    auto empty=new Chunk();
    scope(exit)destroy(empty);
    write(buildPath(directory,"chunks","c.0.0.dat"),empty.snapshot());

    auto server=new IntegratedGameServer(settings,directory);
    scope(exit)destroy(server);
    auto connection=new GameConnection("VoidTester","127.0.0.1",server.port);
    auto clientWorld=new World();
    scope(exit)destroy(clientWorld);
    auto player=new LocalPlayer();
    scope(exit)destroy(player);
    auto client=new MultiplayerClient(connection,clientWorld,player);
    scope(exit)destroy(client);
    auto chat=new ChatState();
    scope(exit)destroy(chat);
    uint sequence;
    foreach(_;0..180)
    {
        client.poll(chat);
        if(client.loginComplete)
            client.sendPredictedInput(PlayerInputCommand(++sequence));
        if(player.health<=0.0f)break;
        Thread.sleep(25.msecs);
    }
    assert(player.health<=0.0f);
    assert(client.localDeathMessage=="VoidTester fell out of the world");
}
