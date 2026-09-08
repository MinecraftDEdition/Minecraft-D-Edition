module terrain_streaming_smoke;

import core.thread : Thread;
import core.time : msecs;
import std.socket : TcpSocket, Socket, InternetAddress;
import std.stdio : writeln;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.client.network.multiplayer_client : MultiplayerClient;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.client.chat.chat_state : ChatState;
import minecraftd.network.game_protocol : GamePacketType, PacketWriter,
    framePacket, gameProtocolVersion, chunkEncodingRaw;
import minecraftd.world.chunk : Chunk;
import minecraftd.world.world : World;
import minecraftd.world.block : BlockId;
import minecraftd.world.world_settings : DimensionId;
import minecraftd.common.math3d : Vec3;

void main()
{
    auto listener=new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1",0));
    listener.listen(2);
    scope(exit)listener.close();
    const port=(cast(InternetAddress)listener.localAddress).port;
    Socket[2] peers;
    MultiplayerClient[2] clients;
    World[2] worlds;
    LocalPlayer[2] players;
    ChatState[2] chats;
    scope(exit)foreach(i;0..2)
    {
        if(clients[i] !is null)destroy(clients[i]);
        if(peers[i] !is null)peers[i].close();
        if(worlds[i] !is null)destroy(worlds[i]);
        if(players[i] !is null)destroy(players[i]);
        if(chats[i] !is null)destroy(chats[i]);
    }
    foreach(i;0..2)
    {
        auto connection=new GameConnection("TerrainTest","127.0.0.1",port);
        peers[i]=listener.accept();
        worlds[i]=new World();
        players[i]=new LocalPlayer();
        chats[i]=new ChatState();
        clients[i]=new MultiplayerClient(connection,worlds[i],players[i]);
    }
    void broadcast(GamePacketType type,ubyte[] payload)
    {
        const packet=framePacket(type,payload);
        foreach(peer;peers)
        {
            size_t sent;
            while(sent<packet.length)
            {
                const amount=peer.send(packet[sent..$]);
                assert(amount>0);
                sent+=amount;
            }
        }
    }
    void awaitState(bool delegate() ready)
    {
        foreach(_;0..2000)
        {
            foreach(i;0..2)clients[i].poll(chats[i]);
            if(ready())return;
            Thread.sleep(2.msecs);
        }
        assert(0,"Timed out waiting for both terrain replicas");
    }
    PacketWriter login;
    login.putU16(gameProtocolVersion);login.putU32(1);login.putString("TerrainTest");
    login.putVec3(Vec3(0,72,0));login.putU8(cast(ubyte)DimensionId.overworld);
    broadcast(GamePacketType.loginAccepted,login.data);
    awaitState(()=>clients[0].loginComplete&&clients[1].loginComplete);

    auto chunk=new Chunk();
    scope(exit)destroy(chunk);
    chunk.set(0,70,0,BlockId.stone);
    const data=chunk.snapshot();
    // Pause application polling while the receive threads accumulate a burst.
    // The final edits and unloads must not overtake deferred chunk snapshots.
    foreach(x;0..40)
    {
        PacketWriter snapshot;
        snapshot.putI32(x);snapshot.putI32(0);snapshot.putU8(chunkEncodingRaw);
        snapshot.data~=data;
        broadcast(GamePacketType.chunkData,snapshot.data);
    }
    PacketWriter edit;
    edit.putI32(39*16);edit.putI32(70);edit.putI32(0);
    edit.putU8(cast(ubyte)BlockId.stone);edit.putU8(cast(ubyte)BlockId.oakPlanks);
    edit.putU32(1);
    broadcast(GamePacketType.blockChange,edit.data);
    foreach(x;0..39)
    {
        PacketWriter unload;
        unload.putI32(x);unload.putI32(0);
        broadcast(GamePacketType.chunkUnload,unload.data);
    }
    awaitState(() => worlds[0].loadedChunkCoordinates().length==1
        &&worlds[1].loadedChunkCoordinates().length==1
        &&worlds[0].getBlock(39*16,70,0)==BlockId.oakPlanks
        &&worlds[1].getBlock(39*16,70,0)==BlockId.oakPlanks);

    // A dimension change must discard old queued terrain. The new snapshot
    // uses identical coordinates but a different occupied height.
    PacketWriter travel;
    travel.putU8(cast(ubyte)DimensionId.nether);travel.putVec3(Vec3(0,22,0));
    broadcast(GamePacketType.dimensionChange,travel.data);
    chunk.set(0,70,0,BlockId.air);chunk.set(0,20,0,BlockId.netherrack);
    PacketWriter nether;
    nether.putI32(39);nether.putI32(0);nether.putU8(chunkEncodingRaw);
    nether.data~=chunk.snapshot();
    broadcast(GamePacketType.chunkData,nether.data);
    awaitState(()=>worlds[0].getBlock(39*16,20,0)==BlockId.netherrack
        &&worlds[1].getBlock(39*16,20,0)==BlockId.netherrack);
    foreach(world;worlds)
    {
        assert(world.dimension==DimensionId.nether);
        assert(world.getBlock(39*16,70,0)==BlockId.air);
        assert(world.loadedChunkCoordinates().length==1);
    }
    writeln("Two-client terrain burst, ordered edits/unloads, and dimension replacement passed");
}
