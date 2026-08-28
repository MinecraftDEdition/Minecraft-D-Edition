module input_queue_smoke;

import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;

import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.network.game_protocol : GamePacketType, PacketReader,
    PlayerInputCommand, encodeInput, inputForward;
import minecraftd.server.integrated_game_server : IntegratedGameServer;

void main()
{
    auto server = new IntegratedGameServer();
    scope (exit) destroy(server);
    auto connection = new GameConnection("Steve", "127.0.0.1", server.port);
    scope (exit) destroy(connection);

    bool loggedIn;
    foreach (_; 0 .. 100)
    {
        foreach (packet; connection.poll())
            if (packet.type == GamePacketType.loginAccepted)
                loggedIn = true;
        if (loggedIn) break;
        Thread.sleep(20.msecs);
    }
    assert(loggedIn);

    // Deliver ten predicted ticks as one TCP burst. The server must simulate
    // every sequence exactly once rather than retaining only sequence ten.
    foreach (sequence; 1 .. 11)
        connection.sendFramed(encodeInput(PlayerInputCommand(sequence,
            inputForward, 0, false, 0.0f, 0.0f)));

    uint acknowledged;
    float authoritativeZ = 3.0f;
    foreach (_; 0 .. 100)
    {
        foreach (packet; connection.poll())
        if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32();
            acknowledged = reader.readU32();
            reader.readBool();
            const count = reader.readU16();
            foreach (_player; 0 .. count)
            {
                const state = reader.readPlayer();
                if (state.name == "Steve")
                    authoritativeZ = state.position.z;
            }
        }
        if (acknowledged >= 10) break;
        Thread.sleep(20.msecs);
    }
    writeln("burst ack=", acknowledged, " authoritative z=", authoritativeZ);
    assert(acknowledged == 10);
    assert(authoritativeZ > 4.7f);
}
