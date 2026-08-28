module death_loop_smoke;

version (Windows):

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.random : uniform;
import std.stdio : writeln;

import minecraftd.client.chat.chat_state : ChatMessageKind, ChatState;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.network.game_protocol : PlayerInputCommand;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.world.block : BlockId;
import minecraftd.world.chunk : Chunk;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : GameMode, WorldSettings,
    saveWorldMetadata;

void main()
{
    runDeath(false);
    runDeath(true);
    writeln("survival respawn and Hardcore spectate death loops passed");
}

void runDeath(bool hardcore)
{
    const directory = buildPath(tempDir(), "minecraft-d-death-smoke-"
        ~ to!string(uniform(1_000_000,9_999_999)));
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);

    WorldSettings settings;
    settings.name = hardcore ? "Hardcore Death Smoke" : "Death Smoke";
    settings.folder = settings.name;
    settings.hardcore = hardcore;
    settings.gameMode = GameMode.survival;
    settings.spawn.x = 8.0f;
    settings.spawn.y = 25.0f;
    settings.spawn.z = 3.0f;
    saveWorldMetadata(directory,settings);
    auto chunk = new Chunk();
    scope (exit) destroy(chunk);
    foreach (z; 0 .. Chunk.depth)
    foreach (x; 0 .. Chunk.width)
        chunk.set(x,0,z,BlockId.grass);
    write(buildPath(directory,"blocks.dat"),chunk.snapshot());

    auto server = new IntegratedGameServer(settings,directory);
    scope (exit) destroy(server);
    auto connection = new GameConnection("Steve","127.0.0.1",server.port);
    auto clientWorld = new World();
    scope (exit) destroy(clientWorld);
    auto player = new LocalPlayer();
    scope (exit) destroy(player);
    auto client = new MultiplayerClient(connection,clientWorld,player);
    scope (exit) destroy(client);
    auto chat = new ChatState();
    scope (exit) destroy(chat);

    uint sequence;
    bool joinedMessage;
    bool deathMessage;
    foreach (_; 0 .. 200)
    {
        client.poll(chat);
        if (client.loginComplete)
            client.sendPredictedInput(PlayerInputCommand(++sequence));
        foreach (message; chat.messages)
        {
            if (message.text == "Steve joined the game"
                && message.kind == ChatMessageKind.system)
                joinedMessage = true;
            if (message.text == "Steve fell from a high place"
                && message.kind == ChatMessageKind.normal)
                deathMessage = true;
        }
        if (player.health <= 0.0f && player.deathTime >= 1
            && client.localDeathMessage == "Steve fell from a high place"
            && deathMessage)
            break;
        Thread.sleep(25.msecs);
    }
    assert(joinedMessage);
    assert(player.health <= 0.0f);
    assert(player.totalExperience == 0);
    assert(client.localDeathMessage == "Steve fell from a high place");
    assert(deathMessage);

    client.requestRespawn();
    foreach (_; 0 .. 100)
    {
        client.poll(chat);
        if (player.health > 0.0f
            && player.gameMode == (hardcore ? GameMode.spectator
                : GameMode.survival))
            break;
        Thread.sleep(20.msecs);
    }
    assert(player.health == 20.0f);
    assert(player.deathTime == 0);
    assert(player.gameMode == (hardcore ? GameMode.spectator
        : GameMode.survival));
    assert(player.flying == hardcore);
}
