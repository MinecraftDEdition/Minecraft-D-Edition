module client_join_smoke;

import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;

import minecraftd.client.chat.chat_state : ChatState;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.network.game_protocol : PlayerInputCommand, inputForward;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.world.block : BlockId;
import minecraftd.world.world : World;

void main()
{
    auto server = new IntegratedGameServer();
    scope (exit) destroy(server);
    server.setPaused(true);
    auto connection = new GameConnection("Steve", "127.0.0.1", server.port);
    auto world = new World();
    auto player = new LocalPlayer();
    auto client = new MultiplayerClient(connection, world, player);
    scope (exit) destroy(client);
    auto chat = new ChatState();
    scope (exit) destroy(chat);

    foreach (_; 0 .. 150)
    {
        client.poll(chat);
        if (client.loginComplete && client.serverPaused)
            break;
        Thread.sleep(20.msecs);
    }

    writeln("login=", client.loginComplete, " paused=", client.serverPaused,
        " spawn=", player.position.x, ",", player.position.y, ",",
        player.position.z, " ground=", world.getBlock(8, 0, 3),
        " revision=", world.revision);
    assert(client.loginComplete && client.serverPaused);
    assert(player.position.y == 1.0f);
    assert(world.getBlock(8, 0, 3) == BlockId.grass);
    assert(world.revision > 0);

    // Joining a host whose singleplayer pause menu is already open must
    // immediately resume the authoritative world for both clients.
    auto secondConnection = new GameConnection("Alex", "127.0.0.1", server.port);
    auto secondWorld = new World();
    scope (exit) destroy(secondWorld);
    auto secondPlayer = new LocalPlayer();
    scope (exit) destroy(secondPlayer);
    auto secondClient = new MultiplayerClient(secondConnection, secondWorld,
        secondPlayer);
    auto secondChat = new ChatState();
    scope (exit) destroy(secondChat);
    foreach (_; 0 .. 150)
    {
        client.poll(chat);
        secondClient.poll(secondChat);
        if (secondClient.loginComplete && !client.serverPaused
            && !secondClient.serverPaused)
            break;
        Thread.sleep(20.msecs);
    }
    assert(secondClient.loginComplete);
    assert(!client.serverPaused && !secondClient.serverPaused);

    foreach (sequence; 1 .. 5)
        secondClient.sendPredictedInput(PlayerInputCommand(sequence,
            inputForward, 0, false, 0.0f, 0.0f));
    bool guestMovedWhileHostMenuOpen;
    foreach (_; 0 .. 100)
    {
        client.poll(chat);
        secondClient.poll(secondChat);
        foreach (remote; client.remotePlayers())
            if (remote.networkId == secondClient.localPlayerId
                && remote.position.z > 3.2f)
                guestMovedWhileHostMenuOpen = true;
        if (guestMovedWhileHostMenuOpen) break;
        Thread.sleep(20.msecs);
    }
    assert(guestMovedWhileHostMenuOpen);

    // If the guest leaves while the host menu remains open, the now-solo
    // integrated world becomes pausable again.
    secondClient.requestDisconnect();
    destroy(secondClient);
    foreach (_; 0 .. 150)
    {
        client.poll(chat);
        if (client.serverPaused) break;
        Thread.sleep(20.msecs);
    }
    assert(client.serverPaused);
}
