module minecraftd.server.integrated_game_server;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.math : atan2f, cosf, floorf, sinf;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;
import std.conv : to;
import std.datetime.systime : Clock;
import std.socket : AddressFamily, getAddress, InternetAddress, ProtocolType,
    Socket, SocketOption, SocketOptionLevel, SocketOSException,
    SocketShutdown, SocketType, TcpSocket;
import std.path : buildPath, dirName;

import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : DEG_TO_RAD, PI, Vec3, forwardFromYawPitch;
import minecraftd.game.item.inventory : ItemId, ItemStack, bareHandDrop,
    blockItem, placedBlock;
import minecraftd.game.entity.player : Player;
import minecraftd.network.chat_protocol : sanitizeChat;
import minecraftd.network.game_protocol : DroppedItemState, GamePacketType,
    CombatEventType, DamageCause, NetworkPlayerState, PacketReader, PacketWriter,
    PlayerActionType,
    PlayerInputCommand,
    chunkEncodingRaw, chunkEncodingRle, encodeChunkRuns,
    decodeFrameLength, decodeInput, framePacket, inputAttack, inputBack,
    inputCrouch, inputForward, inputJump, inputLeft, inputRight, inputSprint,
    gameProtocolVersion, maximumGamePacketBytes;
import minecraftd.server.host_commands : BanList, HostCommandKind,
    parseHostCommand;
import minecraftd.world.block : BlockId, bareHandDestroyProgress, isFire,
    isWater;
import minecraftd.world.chunk : Chunk, ChunkCoordinate, chunkCoordinate;
import minecraftd.world.world : GenerationProgress, World;
import minecraftd.world.nether_portal : PortalAxis, PortalRectangle,
    createTestPortal, createTestPortalFrame, igniteNetherPortal,
    intersectsPortal;
import minecraftd.world.world_settings : DimensionId, GameMode, WorldSettings;

private final class ServerPeer
{
    Socket socket;
    Mutex sendMutex;
    uint playerId;
    uint lastHeardTick;
    bool loggedIn;
    bool[ChunkCoordinate] sentChunks;
    DimensionId sentDimension = DimensionId.overworld;

    this(Socket socket)
    {
        this.socket = socket;
        sendMutex = new Mutex();
    }

    void send(const(ubyte)[] packet)
    {
        synchronized (sendMutex)
        {
            size_t sent;
            while (sent < packet.length)
            {
                const amount = socket.send(packet[sent .. $]);
                if (amount <= 0)
                    throw new SocketOSException("Game socket closed while sending");
                sent += amount;
            }
        }
    }

    void close()
    {
        if (socket is null)
            return;
        try socket.shutdown(SocketShutdown.BOTH);
        catch (SocketOSException) {}
        socket.close();
        socket = null;
    }
}

private struct InboundPacket
{
    ServerPeer peer;
    GamePacketType type;
    ubyte[] payload;
}

private final class ServerPlayer
{
    uint id;
    string name;
    string accountId;
    string skinVersion;
    string skinModel = "classic";
    bool host;
    LocalPlayer player;
    PlayerInputCommand input;
    PlayerInputCommand[] queuedInputs;
    uint acknowledgedInput;
    bool mining;
    int miningX;
    int miningY;
    int miningZ;
    BlockId miningBlock;
    float miningProgress = 0.0f;
    uint creativeBreakCooldown;
    uint damageEventId;
    DamageCause damageCause;
    GameMode respawnGameMode;
    string deathMessage;
    DimensionId dimension = DimensionId.overworld;
    ubyte viewDistance = 6;
    ubyte simulationDistance = 5;
    uint portalTicks;
    bool portalLatched;
    PortalRectangle overworldPortal;

    this(uint id, string name, Vec3 spawn, GameMode gameMode, bool hardcore)
    {
        this.id = id;
        this.name = name;
        player = new LocalPlayer();
        player.position = spawn;
        player.previousPosition = spawn;
        player.gameMode = gameMode;
        respawnGameMode = gameMode;
        player.hardcore = hardcore;
        player.flying = gameMode == GameMode.spectator;
        player.dimension = DimensionId.overworld;
        if (gameMode == GameMode.creative)
        {
            const starterItems = [
                ItemId.flintAndSteel, ItemId.bricks, ItemId.oakPlanks,
                ItemId.sprucePlanks, ItemId.birchPlanks, ItemId.junglePlanks,
                ItemId.acaciaPlanks, ItemId.darkOakPlanks,
                ItemId.mangrovePlanks, ItemId.cherryPlanks,
                ItemId.bambooPlanks, ItemId.paleOakPlanks,
                ItemId.crimsonPlanks, ItemId.warpedPlanks,
                ItemId.cobblestone, ItemId.glass,
            ];
            foreach (index, item; starterItems)
                player.inventory.storage[index] = ItemStack(item, 1);
        }
    }
}

/// Integrated authoritative game server. It owns an independent world and
/// advances movement, collision, survival, mining, items, and pickups at 20 TPS.
final class IntegratedGameServer
{
    enum ushort defaultPort = GameConnection.defaultPort;

    private TcpSocket listener;
    private Thread acceptThread;
    private Thread tickThread;
    private Thread[] workers;
    private ServerPeer[] peers;
    private Mutex peersMutex;
    private InboundPacket[] inbound;
    private Mutex inboundMutex;
    private shared bool running;
    private shared bool pauseRequested;
    private shared bool paused;

    private World world;
    private World netherWorld;
    private ServerPlayer[uint] players;
    private DroppedItemState[] droppedItems;
    private uint nextPlayerId = 1;
    private uint nextItemId = 1;
    private uint serverTick;
    private uint randomState = 0x9E3779B9u;
    private uint savedWorldRevision;
    private uint savedNetherRevision;
    private ushort listeningPort;
    private string sharedAddress;
    private BanList worldBans;
    private BanList universalBans;
    private string hostAccountId;
    private bool hostAssigned;

    this(ushort port = 0)
    {
        initialize(new World(), port);
    }

    this(WorldSettings settings, string directory,
        GenerationProgress progress = null, ushort port = 0)
    {
        initialize(new World(settings, directory, progress), port);
    }

private:
    void initialize(World ownedWorld, ushort port)
    {
        peersMutex = new Mutex();
        inboundMutex = new Mutex();
        world = ownedWorld;
        const worldBanPath = world.saveDirectory.length
            ? buildPath(world.saveDirectory, "bans.tsv") : "";
        const universalBanPath = world.saveDirectory.length
            ? buildPath(dirName(world.saveDirectory), "host-bans.tsv") : "";
        worldBans = new BanList(worldBanPath);
        universalBans = new BanList(universalBanPath);
        if (world.saveDirectory.length)
            netherWorld = new World(world.settings,
                buildPath(world.saveDirectory, "DIM-1"), DimensionId.nether);
        else
        {
            netherWorld = new World();
            netherWorld.settings = world.settings;
            netherWorld.dimension = DimensionId.nether;
            netherWorld.generateNether();
        }
        if (world.settings.effectiveGameMode() == GameMode.creative
            && !containsBlock(world, BlockId.obsidian))
        {
            const spawn = world.settings.spawn;
            createTestPortalFrame(world, cast(int)spawn.x + 3,
                cast(int)spawn.y, cast(int)spawn.z + 3, PortalAxis.x);
        }
        savedNetherRevision = netherWorld.contentRevision;
        savedWorldRevision = world.contentRevision;
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        // A port of zero lets Windows allocate a distinct endpoint per world,
        // allowing several hosted test worlds on one PC without collisions.
        // The wildcard bind makes the same authoritative server reachable by
        // LAN peers once the owner publishes its address from the pause menu.
        listener.bind(new InternetAddress("0.0.0.0", port));
        listeningPort = (cast(InternetAddress) listener.localAddress).port;
        listener.listen(32);
        atomicStore(running, true);
        acceptThread = new Thread({ acceptLoop(); });
        tickThread = new Thread({ tickLoop(); });
        acceptThread.start();
        tickThread.start();
    }

public:

    ushort port() const { return listeningPort; }

    string localAddress() const
    {
        return "127.0.0.1:" ~ portString();
    }

    string publish()
    {
        if (sharedAddress.length == 0)
            sharedAddress = discoverLanAddress() ~ ":" ~ portString();
        return sharedAddress;
    }

    void setPaused(bool value)
    {
        atomicStore(pauseRequested, value);
    }

    bool isPaused() const
    {
        return atomicLoad(paused);
    }

    ~this()
    {
        atomicStore(running, false);
        if (listener !is null)
        {
            try listener.shutdown(SocketShutdown.BOTH);
            catch (SocketOSException) {}
            listener.close();
            listener = null;
        }
        synchronized (peersMutex)
            foreach (peer; peers)
                peer.close();
        if (acceptThread !is null) acceptThread.join();
        if (tickThread !is null) tickThread.join();
        foreach (worker; workers) worker.join();
        foreach (player; players) destroy(player);
        world.save();
        netherWorld.save();
        destroy(netherWorld);
        destroy(world);
        destroy(worldBans);
        destroy(universalBans);
    }

private:
    void acceptLoop()
    {
        while (atomicLoad(running))
        {
            try
            {
                auto peer = new ServerPeer(listener.accept());
                synchronized (peersMutex)
                    peers ~= peer;
                startPeerWorker(peer);
            }
            catch (SocketOSException)
            {
                if (!atomicLoad(running)) break;
            }
        }
    }

    void startPeerWorker(ServerPeer acceptedPeer)
    {
        // Keep a distinct closure frame per accepted socket. Capturing the
        // accept-loop local directly can make multiple workers read one peer.
        auto worker = new Thread({ peerLoop(acceptedPeer); });
        workers ~= worker;
        worker.start();
    }

    void peerLoop(ServerPeer peer)
    {
        ubyte[4] header;
        while (atomicLoad(running) && peer.socket !is null)
        {
            try
            {
                if (!receiveExact(peer.socket, header[])) break;
                const length = decodeFrameLength(header[]);
                if (length < 1 || length > maximumGamePacketBytes) break;
                auto body = new ubyte[length];
                if (!receiveExact(peer.socket, body)) break;
                enqueue(InboundPacket(peer, cast(GamePacketType) body[0],
                    body[1 .. $].dup));
            }
            catch (SocketOSException) break;
        }
        enqueue(InboundPacket(peer, GamePacketType.disconnect, null));
    }

    void tickLoop()
    {
        while (atomicLoad(running))
        {
            const started = MonoTime.currTime;
            tick();
            const used = MonoTime.currTime - started;
            const remaining = 50.msecs - used;
            if (remaining > Duration.zero)
                Thread.sleep(remaining);
        }
    }

    void tick()
    {
        ++serverTick;
        processInbound();

        // The integrated world only freezes while its owner is genuinely the
        // sole player. A join immediately clears the effective pause without
        // requiring the host to close their menu first.
        const shouldPause = atomicLoad(pauseRequested) && players.length <= 1;
        atomicStore(paused, shouldPause);

        if (shouldPause)
        {
            // Networking remains alive while world time is frozen. Consume and
            // acknowledge input without applying it so prediction queues do not
            // grow and held movement cannot burst forward on resume.
            foreach (serverPlayer; players)
            {
                if (serverPlayer.queuedInputs.length != 0)
                {
                    serverPlayer.input = serverPlayer.queuedInputs[$ - 1];
                    serverPlayer.acknowledgedInput = serverPlayer.input.sequence;
                    serverPlayer.queuedInputs.length = 0;
                }
                serverPlayer.input.flags = 0;
                serverPlayer.input.usePressed = false;
                serverPlayer.input.attackPressed = false;
            }
            if (serverTick % 40 == 0)
                sendKeepAlives();
            broadcastSnapshots();
            return;
        }

        foreach (serverPlayer; players)
            if (serverPlayer.player.health <= 0.0f
                && serverPlayer.player.deathTime < 20)
                ++serverPlayer.player.deathTime;

        foreach (serverPlayer; players)
        {
            // Every predicted client tick must be simulated exactly once. The
            // previous newest-only slot discarded inputs whenever two packets
            // landed in one server tick, causing periodic backward corrections.
            auto queued = serverPlayer.queuedInputs;
            serverPlayer.queuedInputs = null;
            foreach (input; queued)
                simulateInput(serverPlayer, input);
        }

        foreach(serverPlayer;players)
            tickPlayerFire(serverPlayer);

        tickDroppedItems();
        if (serverTick % 5 == 0)
        {
            Vec3[] overworldCenters,netherCenters;
            int overworldSimulation=5,netherSimulation=5;
            foreach(serverPlayer;players)
            {
                if(serverPlayer.dimension==DimensionId.overworld)
                {
                    overworldCenters~=serverPlayer.player.position;
                    if(serverPlayer.simulationDistance>overworldSimulation)
                        overworldSimulation=serverPlayer.simulationDistance;
                }
                else
                {
                    netherCenters~=serverPlayer.player.position;
                    if(serverPlayer.simulationDistance>netherSimulation)
                        netherSimulation=serverPlayer.simulationDistance;
                }
            }
            foreach(change;world.tickWaterAround(overworldCenters,
                overworldSimulation))
                broadcastBlockChange(change.x,change.y,change.z,change.oldBlock,
                    change.newBlock,0,DimensionId.overworld);
            foreach(change;netherWorld.tickWaterAround(netherCenters,
                netherSimulation))
                broadcastBlockChange(change.x,change.y,change.z,change.oldBlock,
                    change.newBlock,0,DimensionId.nether);
            foreach(change;world.tickFireAround(overworldCenters,
                overworldSimulation,serverTick))
                broadcastBlockChange(change.x,change.y,change.z,change.oldBlock,
                    change.newBlock,0,DimensionId.overworld);
            foreach(change;netherWorld.tickFireAround(netherCenters,
                netherSimulation,serverTick))
                broadcastBlockChange(change.x,change.y,change.z,change.oldBlock,
                    change.newBlock,0,DimensionId.nether);
        }
        if (serverTick % 100 == 0
            && world.contentRevision != savedWorldRevision)
        {
            world.saveDirtyChunks();
            savedWorldRevision = world.contentRevision;
        }
        if (serverTick % 100 == 0
            && netherWorld.contentRevision != savedNetherRevision)
        {
            netherWorld.saveDirtyChunks();
            savedNetherRevision = netherWorld.contentRevision;
        }
        removeTimedOutPeers();
        if (serverTick % 40 == 0)
            sendKeepAlives();

        // Time-sensitive state always enters each ordered connection before
        // background terrain. Otherwise several large chunk packets can hold
        // movement and block changes behind them (TCP/EOS head-of-line delay).
        broadcastSnapshots();
        synchronized(peersMutex)
        foreach(peer;peers)
            if(peer.loggedIn&&peer.socket !is null)
                if(auto serverPlayer=peer.playerId in players)
                    syncPeerChunks(peer,*serverPlayer);
        trimInactiveChunks(world,DimensionId.overworld);
        trimInactiveChunks(netherWorld,DimensionId.nether);
    }

    void processInbound()
    {
        InboundPacket[] packets;
        synchronized (inboundMutex)
        {
            packets = inbound.dup;
            inbound.length = 0;
        }
        foreach (packet; packets)
        {
            packet.peer.lastHeardTick = serverTick;
            final switch (packet.type)
            {
                case GamePacketType.loginRequest:
                    acceptLogin(packet.peer, packet.payload);
                    break;
                case GamePacketType.playerInput:
                    if (auto serverPlayer = packet.peer.playerId in players)
                    {
                        bool valid;
                        const input = decodeInput(packet.payload, valid);
                        uint newestSequence = (*serverPlayer).input.sequence;
                        if ((*serverPlayer).queuedInputs.length != 0)
                            newestSequence = (*serverPlayer).queuedInputs[$ - 1].sequence;
                        if (valid && input.sequence > newestSequence
                            && (*serverPlayer).queuedInputs.length < 256)
                            (*serverPlayer).queuedInputs ~= input;
                    }
                    break;
                case GamePacketType.chatSubmit:
                    if (auto serverPlayer = packet.peer.playerId in players)
                    {
                        PacketReader reader = PacketReader(packet.payload);
                        const message = sanitizeChat(reader.readString());
                        if (reader.valid && message.length)
                        {
                            if (message[0] == '/')
                                handleHostCommand(packet.peer, *serverPlayer,
                                    message);
                            else
                                broadcastChat("<" ~ (*serverPlayer).name ~ "> "
                                    ~ message, false);
                        }
                    }
                    break;
                case GamePacketType.playerAction:
                    if (auto serverPlayer = packet.peer.playerId in players)
                    {
                        PacketReader reader = PacketReader(packet.payload);
                        const action = cast(PlayerActionType) reader.readU8();
                        const target = reader.readU8();
                        const auxiliary = reader.readU8();
                        if (reader.valid && (action == PlayerActionType.dropItem
                            || action == PlayerActionType.dropStack))
                        {
                            (*serverPlayer).player.selectedSlot = target < 9
                                ? target : 0;
                            dropSelectedItem(*serverPlayer,
                                action == PlayerActionType.dropStack);
                        }
                        else if (reader.valid && action == PlayerActionType.respawn)
                            respawnPlayer(*serverPlayer);
                        else if (reader.valid
                            && action == PlayerActionType.inventoryClick)
                            (*serverPlayer).player.inventory.click(target,
                                auxiliary != 0);
                        else if (reader.valid
                            && action == PlayerActionType.inventoryQuickMove)
                            (*serverPlayer).player.inventory.quickMove(target);
                        else if (reader.valid
                            && action == PlayerActionType.inventoryHotbarSwap)
                            (*serverPlayer).player.inventory.swapHotbar(target,
                                auxiliary);
                        else if (reader.valid
                            && action == PlayerActionType.inventoryDrop)
                            dropInventoryItem(*serverPlayer,target,
                                auxiliary != 0);
                        else if (reader.valid
                            && action == PlayerActionType.inventoryCollect)
                            (*serverPlayer).player.inventory.collectMatching(target);
                        else if (reader.valid
                            && action == PlayerActionType.inventoryClose)
                            closeInventory(*serverPlayer);
                        else if (reader.valid
                            && action == PlayerActionType.pickBlock)
                            pickSelectedBlock(*serverPlayer);
                    }
                    break;
                case GamePacketType.profileUpdate:
                    if(auto serverPlayer=packet.peer.playerId in players)
                    {
                        PacketReader reader=PacketReader(packet.payload);
                        const revision=sanitizeSkinVersion(reader.readString());
                        const model=reader.readString();
                        if(reader.valid)
                        {
                            (*serverPlayer).skinVersion=revision;
                            (*serverPlayer).skinModel=model=="slim"
                                ?"slim":"classic";
                        }
                    }
                    break;
                case GamePacketType.keepAliveReply:
                    break;
                case GamePacketType.chunkData:
                case GamePacketType.chunkUnload:
                    break;
                case GamePacketType.disconnect:
                    disconnectPeer(packet.peer);
                    break;
                case GamePacketType.loginAccepted,
                     GamePacketType.snapshot,
                     GamePacketType.blockChange,
                     GamePacketType.chatBroadcast,
                     GamePacketType.keepAlive,
                     GamePacketType.itemPickup,
                     GamePacketType.combatEvent,
                     GamePacketType.dimensionChange:
                    break;
            }
        }
    }

    void simulateInput(ServerPlayer serverPlayer, PlayerInputCommand input)
    {
        serverPlayer.input = input;
        serverPlayer.viewDistance=input.viewDistance<2?2:
            (input.viewDistance>12?12:input.viewDistance);
        serverPlayer.simulationDistance=input.simulationDistance<5?5:
            (input.simulationDistance>12?12:input.simulationDistance);
        auto player = serverPlayer.player;
        if (player.health <= 0.0f)
        {
            serverPlayer.acknowledgedInput = input.sequence;
            serverPlayer.input.flags = 0;
            serverPlayer.input.usePressed = false;
            serverPlayer.input.attackPressed = false;
            serverPlayer.mining = false;
            serverPlayer.miningProgress = 0.0f;
            return;
        }
        const healthBeforeMovement = player.health;
        player.yaw = input.yaw;
        player.pitch = input.pitch;
        player.selectedSlot = input.selectedSlot < 9 ? input.selectedSlot : 0;
        player.skinParts = input.skinParts;
        player.mainHandRight = input.mainHandRight;
        if (input.flightTogglePressed)
            player.toggleFlight();
        if (input.down(inputAttack) || input.attackPressed) player.attack();
        auto activeWorld = worldFor(serverPlayer.dimension);
        player.simulateTick(activeWorld, input.moveForward, input.moveStrafe,
            input.down(inputJump), input.down(inputCrouch),
            input.down(inputSprint), true);
        const border=cast(float)activeWorld.horizontalBorder();
        if(player.position.x < -border)player.position.x=-border;
        if(player.position.x > border)player.position.x=border;
        if(player.position.z < -border)player.position.z=-border;
        if(player.position.z > border)player.position.z=border;
        if (player.health < healthBeforeMovement)
        {
            const cause=player.drowningDamageDue?DamageCause.drown:DamageCause.fall;
            recordDamage(serverPlayer, cause);
            if (player.health <= 0.0f)
                handleDeath(serverPlayer, cause, "");
        }
        if(player.health>0.0f&&player.gameMode!=GameMode.spectator
            &&player.position.y<activeWorld.voidDamageY()
            &&serverTick%10==0)
        {
            player.health-=4.0f;
            if(player.health<0.0f)player.health=0.0f;
            recordDamage(serverPlayer,DamageCause.voidDamage);
            if(player.health<=0.0f)
                handleDeath(serverPlayer,DamageCause.voidDamage,"");
        }
        if (updatePortal(serverPlayer))
        {
            serverPlayer.acknowledgedInput = input.sequence;
            return;
        }
        serverPlayer.acknowledgedInput = input.sequence;
        const attackedPlayer = input.attackPressed
            && player.gameMode != GameMode.spectator
            && attackPlayer(serverPlayer);
        updateMining(serverPlayer, input.down(inputAttack) && !attackedPlayer,
            input.attackPressed && !attackedPlayer);
        if (input.usePressed && player.gameMode != GameMode.adventure
            && player.gameMode != GameMode.spectator)
            placeSelectedBlock(serverPlayer);
        serverPlayer.input.usePressed = false;
        serverPlayer.input.attackPressed = false;
    }

    void tickPlayerFire(ServerPlayer serverPlayer)
    {
        auto player=serverPlayer.player;
        if(player.health<=0.0f){player.fireTicks=0;return;}
        auto activeWorld=worldFor(serverPlayer.dimension);
        if(activeWorld.intersectsWater(player.boundingBox()))
        {
            player.fireTicks=0;
            return;
        }
        const inside=activeWorld.intersectsFire(player.boundingBox());
        if(inside&&player.fireTicks<160)player.fireTicks=160;
        else if(!inside&&player.fireTicks>0)--player.fireTicks;
        if(player.fireTicks<=0)return;
        const cadence=inside?10u:20u;
        if(serverTick%cadence!=0)return;
        const before=player.health;
        player.takeDamage(1.0f);
        if(player.health>=before)return;
        recordDamage(serverPlayer,DamageCause.fire);
        if(player.health<=0.0f)
            handleDeath(serverPlayer,DamageCause.fire,"");
    }

    void acceptLogin(ServerPeer peer, const(ubyte)[] payload)
    {
        if (peer.loggedIn)
            return;
        PacketReader reader = PacketReader(payload);
        const versionValue = reader.readU16();
        auto requested = sanitizeName(reader.readString());
        const accountId = reader.readString();
        const skinVersion = sanitizeSkinVersion(reader.readString());
        const skinModel = reader.readString();
        if (!reader.valid)
            return;
        if (versionValue != gameProtocolVersion)
        {
            PacketWriter rejected;
            rejected.putString("Incompatible Minecraft: D Edition protocol");
            sendTo(peer, framePacket(GamePacketType.disconnect, rejected.data));
            disconnectPeer(peer);
            return;
        }
        const recognizedHost = !hostAssigned
            || (hostAccountId.length && accountId == hostAccountId);
        const now = Clock.currTime.toUnixTime();
        if (!recognizedHost && accountId.length
            && (universalBans.contains(accountId, now)
                || worldBans.contains(accountId, now)))
        {
            disconnectWithReason(peer,
                "You are banned from this host's world");
            return;
        }
        if (!hostAssigned)
        {
            hostAssigned = true;
            hostAccountId = accountId.idup;
        }
        const id = nextPlayerId++;
        const name = uniqueName(requested.length ? requested : "Steve");
        const playersAlreadyPresent = players.length;
        auto spawn = world.settings.spawn;
        if (id > 1)
        {
            immutable float[3] offsets = [0.0f, 1.0f, -1.0f];
            spawn.x += offsets[(id-1)%3];
            spawn.z += offsets[((id-1)/3)%3];
        }
        auto serverPlayer = new ServerPlayer(id, name, spawn,
            world.settings.effectiveGameMode(), world.settings.hardcore);
        serverPlayer.accountId=accountId.idup;
        serverPlayer.host=recognizedHost;
        serverPlayer.skinVersion=skinVersion.idup;
        serverPlayer.skinModel=skinModel=="slim"?"slim":"classic";
        players[id] = serverPlayer;
        peer.playerId = id;
        peer.loggedIn = true;

        PacketWriter response;
        response.putU16(gameProtocolVersion);
        response.putU32(id); response.putString(name); response.putVec3(spawn);
        response.putU8(cast(ubyte) DimensionId.overworld);
        sendTo(peer, framePacket(GamePacketType.loginAccepted, response.data));
        peer.sentChunks.clear();
        peer.sentDimension=DimensionId.overworld;
        syncPeerChunks(peer,serverPlayer,9);
        // Opening an empty integrated world is not a multiplayer join event.
        // Once anybody is already present, broadcast to everyone (including
        // the newcomer), matching Java's visible self-join message on servers.
        if (playersAlreadyPresent != 0)
            broadcastChat(name ~ " joined the game", true);
    }

    void updateMining(ServerPlayer serverPlayer, bool held, bool pressed)
    {
        auto player = serverPlayer.player;
        auto activeWorld = worldFor(serverPlayer.dimension);
        if (serverPlayer.player.gameMode == GameMode.adventure
            || serverPlayer.player.gameMode == GameMode.spectator)
        {
            serverPlayer.mining = false;
            serverPlayer.miningProgress = 0.0f;
            return;
        }
        if (!held && !(player.gameMode == GameMode.creative && pressed))
        {
            serverPlayer.mining = false;
            serverPlayer.miningProgress = 0.0f;
            serverPlayer.creativeBreakCooldown = 0;
            return;
        }
        // Creative destroys immediately on a fresh click, but Java spaces
        // repeated held-button destruction by six ticks (0.3 seconds). It
        // never publishes mining progress, so no crack overlay is rendered.
        if (player.gameMode == GameMode.creative)
        {
            serverPlayer.mining = false;
            serverPlayer.miningProgress = 0.0f;
            if (serverPlayer.creativeBreakCooldown > 0)
                --serverPlayer.creativeBreakCooldown;
            if (!pressed && serverPlayer.creativeBreakCooldown > 0)
                return;
            const creativeHit = activeWorld.rayCast(player.eyePosition(1.0f),
                forwardFromYawPitch(player.yaw, player.pitch), 5.0f);
            if (!creativeHit.hit)
                return;
            player.attack(true);
            activeWorld.setBlock(creativeHit.x, creativeHit.y, creativeHit.z,
                BlockId.air);
            broadcastBlockChange(creativeHit.x, creativeHit.y, creativeHit.z,
                creativeHit.block, BlockId.air, serverPlayer.id,
                serverPlayer.dimension);
            serverPlayer.creativeBreakCooldown = 6;
            return;
        }

        const hit = activeWorld.rayCast(player.eyePosition(1.0f),
            forwardFromYawPitch(player.yaw, player.pitch), 5.0f);
        if (!hit.hit)
        {
            serverPlayer.mining = false;
            serverPlayer.miningProgress = 0.0f;
            return;
        }
        if (!serverPlayer.mining || serverPlayer.miningX != hit.x
            || serverPlayer.miningY != hit.y || serverPlayer.miningZ != hit.z
            || serverPlayer.miningBlock != hit.block)
        {
            serverPlayer.mining = true;
            serverPlayer.miningX = hit.x;
            serverPlayer.miningY = hit.y;
            serverPlayer.miningZ = hit.z;
            serverPlayer.miningBlock = hit.block;
            serverPlayer.miningProgress = 0.0f;
        }
        // The held mining action requests a swing every tick. attack(true)
        // observes the halfway guard shared with the predicting client.
        player.attack(true);
        float destroyProgress=bareHandDestroyProgress(hit.block);
        if(player.eyeInWater)destroyProgress*=0.2f;
        if(!player.onGround)destroyProgress*=0.2f;
        serverPlayer.miningProgress += destroyProgress;
        if (serverPlayer.miningProgress < 1.0f)
            return;

        activeWorld.setBlock(hit.x, hit.y, hit.z, BlockId.air);
        broadcastBlockChange(hit.x, hit.y, hit.z, hit.block, BlockId.air,
            serverPlayer.id, serverPlayer.dimension);
        const drop = bareHandDrop(hit.block);
        if (drop != ItemId.none)
            spawnDrop(drop, Vec3(hit.x + 0.5f, hit.y + 0.5f,
                hit.z + 0.5f), serverPlayer.dimension);
        serverPlayer.mining = false;
        serverPlayer.miningProgress = 0.0f;
    }

    void pickSelectedBlock(ServerPlayer serverPlayer)
    {
        auto player = serverPlayer.player;
        if (player.gameMode != GameMode.creative || player.health <= 0.0f)
            return;
        const hit = worldFor(serverPlayer.dimension).rayCast(
            player.eyePosition(1.0f),
            forwardFromYawPitch(player.yaw, player.pitch), 5.0f);
        if (!hit.hit)
            return;
        player.inventory.pickBlock(blockItem(hit.block), player.selectedSlot,
            true);
    }

    bool attackPlayer(ServerPlayer attacker)
    {
        if (attacker.player.gameMode == GameMode.spectator)
            return false;
        enum float attackRange = 3.0f;
        const origin = attacker.player.eyePosition(1.0f);
        const direction = forwardFromYawPitch(attacker.player.yaw,
            attacker.player.pitch);
        float closest = attackRange;
        ServerPlayer target;
        foreach (candidate; players)
        {
            if (candidate.id == attacker.id
                || candidate.dimension != attacker.dimension
                || candidate.player.health <= 0.0f
                || candidate.player.gameMode == GameMode.spectator)
                continue;
            float distance;
            if (rayIntersects(origin, direction, candidate.player.boundingBox(),
                attackRange, distance) && distance < closest)
            {
                closest = distance;
                target = candidate;
            }
        }
        if (target is null)
            return false;

        // A solid block closer than the entity wins the same pick ray.
        const block = worldFor(attacker.dimension).rayCast(origin, direction,
            attackRange);
        if (block.hit && block.distance + 0.0001f < closest)
            return false;
        // Java's hurt-resistance window prevents a held/click-spammed fist
        // from dealing full damage every 20 TPS server tick.
        if (target.player.hurtTime > 0)
            return true;

        const delta = target.player.position - attacker.player.position;
        auto horizontal = Vec3(delta.x, 0.0f, delta.z).normalized();
        if (horizontal.lengthSquared() < 0.000001f)
            horizontal = Vec3(sinf(attacker.player.yaw * PI / 180.0f),
                0.0f, cosf(attacker.player.yaw * PI / 180.0f));

        // LivingEntity's normal damage impulse is 0.4 blocks/tick. A sprint
        // attack adds 0.5, then slows and interrupts the attacker's sprint.
        const sprintHit = attacker.player.sprinting;
        const strength = sprintHit ? 0.9f : 0.4f;
        auto velocity = target.player.velocity;
        velocity.x = velocity.x * 0.5f + horizontal.x * strength * 20.0f;
        velocity.z = velocity.z * 0.5f + horizontal.z * strength * 20.0f;
        if (target.player.onGround)
        {
            const upward = velocity.y * 0.5f + strength * 20.0f;
            velocity.y = upward < 8.0f ? upward : 8.0f;
            target.player.onGround = false;
        }
        target.player.velocity = velocity;

        const worldAngle = atan2f(delta.z, delta.x) / (PI / 180.0f);
        // Java criticals require downward airborne travel, not merely holding
        // jump or attacking during the upward half of the arc.
        const critical = !attacker.player.onGround
            && attacker.player.velocity.y < 0.0f
            && attacker.player.fallDistance > 0.0f
            && !attacker.player.sprinting && !attacker.player.flying;
        const healthBeforeAttack = target.player.health;
        target.player.takeDamage(critical ? 1.5f : 1.0f,
            Player.wrapDegrees(worldAngle - target.player.yaw));
        if (target.player.health < healthBeforeAttack)
        {
            recordDamage(target, DamageCause.generic);
            if (target.player.health <= 0.0f)
                handleDeath(target, DamageCause.generic, attacker.name);
        }
        if (critical)
            broadcastCriticalHit(attacker.id, target.id, target.player.position,
                attacker.dimension);
        if (sprintHit)
        {
            attacker.player.velocity.x *= 0.6f;
            attacker.player.velocity.z *= 0.6f;
            attacker.player.sprinting = false;
            attacker.input.flags &= ~inputSprint;
        }
        return true;
    }

    static bool rayIntersects(Vec3 origin, Vec3 direction, Aabb bounds,
        float maximumDistance, out float distance)
    {
        float minimum = 0.0f;
        float maximum = maximumDistance;
        bool axis(float rayOrigin, float rayDirection, float low, float high)
        {
            if (rayDirection > -0.000001f && rayDirection < 0.000001f)
                return rayOrigin >= low && rayOrigin <= high;
            float first = (low - rayOrigin) / rayDirection;
            float second = (high - rayOrigin) / rayDirection;
            if (first > second)
            {
                const swap = first; first = second; second = swap;
            }
            if (first > minimum) minimum = first;
            if (second < maximum) maximum = second;
            return minimum <= maximum;
        }
        if (!axis(origin.x, direction.x, bounds.minX, bounds.maxX)
            || !axis(origin.y, direction.y, bounds.minY, bounds.maxY)
            || !axis(origin.z, direction.z, bounds.minZ, bounds.maxZ))
            return false;
        distance = minimum;
        return minimum >= 0.0f && minimum <= maximumDistance;
    }

    void placeSelectedBlock(ServerPlayer serverPlayer)
    {
        auto player = serverPlayer.player;
        if (player.gameMode == GameMode.adventure
            || player.gameMode == GameMode.spectator)
            return;
        const slot = player.selectedSlot;
        if (slot < 0 || slot >= player.inventory.hotbar.length)
            return;
        const stack = player.inventory.hotbar[slot];
        if (stack.empty())
            return;
        auto activeWorld = worldFor(serverPlayer.dimension);
        if (stack.item == ItemId.flintAndSteel)
        {
            const ignitionHit = activeWorld.rayCastForPlacement(
                player.eyePosition(1.0f),
                forwardFromYawPitch(player.yaw, player.pitch), 5.0f);
            PortalRectangle rectangle;
            if(!ignitionHit.hit)
                return;
            player.attack(true);
            if(igniteNetherPortal(activeWorld,ignitionHit.placeX,
                ignitionHit.placeY,ignitionHit.placeZ,rectangle))
                broadcastPortal(rectangle,serverPlayer.id,
                    serverPlayer.dimension);
            else if(activeWorld.canPlaceFire(ignitionHit.placeX,
                ignitionHit.placeY,ignitionHit.placeZ))
            {
                const old=activeWorld.getBlock(ignitionHit.placeX,
                    ignitionHit.placeY,ignitionHit.placeZ);
                activeWorld.setBlock(ignitionHit.placeX,ignitionHit.placeY,
                    ignitionHit.placeZ,BlockId.fire);
                broadcastBlockChange(ignitionHit.placeX,ignitionHit.placeY,
                    ignitionHit.placeZ,old,BlockId.fire,serverPlayer.id,
                    serverPlayer.dimension);
            }
            return;
        }
        const block = placedBlock(stack.item);
        if (block == BlockId.air)
            return;
        const hit = activeWorld.rayCastForPlacement(player.eyePosition(1.0f),
            forwardFromYawPitch(player.yaw, player.pitch), 5.0f);
        const replaced=hit.hit?activeWorld.getBlock(hit.placeX,hit.placeY,
            hit.placeZ):BlockId.air;
        if (!hit.hit || !activeWorld.inBounds(hit.placeX, hit.placeY, hit.placeZ)
            || (replaced!=BlockId.air&&!isWater(replaced)&&!isFire(replaced)))
            return;
        const placedBounds = Aabb(hit.placeX, hit.placeY, hit.placeZ,
            hit.placeX + 1.0f, hit.placeY + 1.0f, hit.placeZ + 1.0f);
        if (player.boundingBox().intersects(placedBounds))
            return;
        activeWorld.setBlock(hit.placeX, hit.placeY, hit.placeZ, block);
        if (player.gameMode != GameMode.creative)
            player.inventory.removeOne(slot);
        player.attack(true);
        broadcastBlockChange(hit.placeX, hit.placeY, hit.placeZ,
            replaced, block, serverPlayer.id, serverPlayer.dimension);
    }

    void dropSelectedItem(ServerPlayer serverPlayer, bool wholeStack = false)
    {
        auto player = serverPlayer.player;
        const slot = player.selectedSlot;
        if (slot < 0 || slot >= player.inventory.hotbar.length)
            return;
        const inventorySlot = player.inventory.storageSize + slot;
        const dropped = player.inventory.takeFromSlot(inventorySlot,wholeStack);
        if (dropped.empty())
            return;

        spawnThrownStack(serverPlayer,dropped);
        player.attack(true);
    }

    void dropInventoryItem(ServerPlayer serverPlayer, int slot, bool wholeStack)
    {
        auto player=serverPlayer.player;
        const dropped=slot==ubyte.max
            ? player.inventory.takeCarried(wholeStack)
            : player.inventory.takeFromSlot(slot,wholeStack);
        if(dropped.empty())return;
        spawnThrownStack(serverPlayer,dropped);
    }

    void closeInventory(ServerPlayer serverPlayer)
    {
        auto inventory=&serverPlayer.player.inventory;
        if(inventory.carried.empty())return;
        inventory.returnCarried();
        if(!inventory.carried.empty())
        {
            const dropped=inventory.takeCarried(true);
            spawnThrownStack(serverPlayer,dropped);
        }
    }

    void spawnThrownStack(ServerPlayer serverPlayer, ItemStack stack)
    {
        auto player = serverPlayer.player;

        // Player.drop(ItemStack, false, true): emit just below the eyes with a
        // 0.3-block/tick forward impulse, 0.1 upward bias, and small scatter.
        Vec3 velocity = forwardFromYawPitch(player.yaw, player.pitch) * 6.0f;
        velocity.y += 2.0f;
        const randomAngle = randomFloat() * PI * 2.0f;
        const randomMagnitude = randomFloat() * 0.4f;
        velocity.x += cosf(randomAngle) * randomMagnitude;
        velocity.y += (randomFloat() - randomFloat()) * 2.0f;
        velocity.z += sinf(randomAngle) * randomMagnitude;
        const origin = player.eyePosition(1.0f) + Vec3(0.0f, -0.3f, 0.0f);
        spawnDrop(stack.item, stack.count, origin, velocity, 40,
            serverPlayer.dimension);
    }

    void spawnDrop(ItemId item, Vec3 position,
        DimensionId dimension = DimensionId.overworld)
    {
        const velocity = Vec3((randomFloat() - 0.5f) * 2.0f,
            4.0f, (randomFloat() - 0.5f) * 2.0f);
        spawnDrop(item, 1, position, velocity, 10, dimension);
    }

    void spawnDrop(ItemId item, Vec3 position, Vec3 velocity, uint pickupDelay,
        DimensionId dimension = DimensionId.overworld)
    {
        spawnDrop(item,1,position,velocity,pickupDelay,dimension);
    }

    void spawnDrop(ItemId item, ubyte count, Vec3 position, Vec3 velocity,
        uint pickupDelay, DimensionId dimension = DimensionId.overworld)
    {
        if(item==ItemId.none||count==0)return;
        droppedItems ~= DroppedItemState(nextItemId++, item, count,
            position, velocity, 0, pickupDelay, dimension);
    }

    void tickDroppedItems()
    {
        DroppedItemState[] survivors;
        foreach (item; droppedItems)
        {
            ++item.age;
            if (item.pickupDelay > 0)
                --item.pickupDelay;
            const half = 0.125f;
            const bounds = Aabb(item.position.x-half, item.position.y-half,
                item.position.z-half, item.position.x+half, item.position.y+half,
                item.position.z+half);
            auto itemWorld=worldFor(item.dimension);
            const underwater=itemWorld.intersectsWater(bounds);
            if(underwater)
            {
                // ItemEntity.setUnderwaterMovement: .99 horizontal drag and
                // a .0005 block/tick buoyant nudge below .06 block/tick.
                item.velocity.x*=0.99f;
                item.velocity.z*=0.99f;
                if(item.velocity.y<1.2f)item.velocity.y+=0.01f;
                item.velocity+=itemWorld.waterFlowAt(item.position)*0.28f;
            }
            else item.velocity.y -= 0.8f;
            const collision = itemWorld.collide(bounds,
                item.velocity * 0.05f);
            item.position += collision.movement;
            if(!underwater)item.velocity.y*=0.98f;
            if (collision.hitY)
            {
                // Grass-like ground friction is block friction (.6) times
                // Java's regular .98 item drag. Settle the vertical component
                // at contact so network interpolation cannot magnify the tiny
                // sub-pixel rebound into the conspicuous repeated bounce the
                // old implementation produced.
                item.velocity.y=0;
                item.velocity.x*=0.588f;
                item.velocity.z*=0.588f;
            }
            else if(!underwater)
            {
                item.velocity.x*=0.98f;
                item.velocity.z*=0.98f;
            }
            if(collision.hitX)item.velocity.x=0;
            if(collision.hitZ)item.velocity.z=0;

            bool removed = item.age >= 6000;
            if (!removed && item.pickupDelay == 0)
            foreach (serverPlayer; players)
            {
                if (serverPlayer.dimension != item.dimension)
                    continue;
                const delta = serverPlayer.player.position - item.position;
                if (delta.lengthSquared() > 2.25f)
                    continue;
                const leftover = serverPlayer.player.inventory.add(item.item, item.count);
                if (leftover == item.count)
                    continue;
                sendPickup(serverPlayer.id, item.position, item.dimension);
                item.count = leftover;
                removed = leftover == 0;
                if (removed) break;
            }
            if (!removed)
                survivors ~= item;
        }
        droppedItems = survivors;
    }

    void handleDeath(ServerPlayer serverPlayer, DamageCause cause,
        string attackerName)
    {
        auto player = serverPlayer.player;
        if (serverPlayer.deathMessage.length)
            return;
        player.velocity = Vec3.init;
        player.sprinting = false;
        player.attacking = false;
        player.deathTime = 0;
        serverPlayer.mining = false;
        serverPlayer.miningProgress = 0.0f;
        serverPlayer.input.flags = 0;
        serverPlayer.input.usePressed = false;
        serverPlayer.input.attackPressed = false;

        final switch (cause)
        {
            case DamageCause.fall:
                serverPlayer.deathMessage = fallDeathMessage(serverPlayer.name,
                    player.lastLandedFallDistance);
                break;
            case DamageCause.drown:
                serverPlayer.deathMessage = serverPlayer.name ~ " drowned";
                break;
            case DamageCause.voidDamage:
                serverPlayer.deathMessage = serverPlayer.name
                    ~ " fell out of the world";
                break;
            case DamageCause.fire:
                serverPlayer.deathMessage = serverPlayer.name
                    ~ " went up in flames";
                break;
            case DamageCause.generic:
                serverPlayer.deathMessage = attackerName.length
                    ? serverPlayer.name ~ " was slain by " ~ attackerName
                    : serverPlayer.name ~ " died";
                break;
            case DamageCause.none:
                serverPlayer.deathMessage = serverPlayer.name ~ " died";
                break;
        }
        broadcastChat(serverPlayer.deathMessage, false);
    }

    bool updatePortal(ServerPlayer serverPlayer)
    {
        auto player = serverPlayer.player;
        PortalRectangle rectangle;
        const inside = intersectsPortal(worldFor(serverPlayer.dimension),
            player.boundingBox(), rectangle);
        if (!inside)
        {
            serverPlayer.portalLatched = false;
            serverPlayer.portalTicks = 0;
            player.portalProgress -= 0.05f;
            if (player.portalProgress < 0.0f) player.portalProgress = 0.0f;
            return false;
        }
        if (serverPlayer.portalLatched)
        {
            player.portalProgress = 1.0f;
            return false;
        }

        ++serverPlayer.portalTicks;
        // Java players wait 80 ticks in ordinary modes; Creative and
        // Spectator use the one-tick portal delay. Keeping progress at one on
        // arrival preserves the visible distortion until the player steps out.
        const delay = player.gameMode == GameMode.creative
                || player.gameMode == GameMode.spectator ? 1u : 80u;
        player.portalProgress = cast(float) serverPlayer.portalTicks / delay;
        if (player.portalProgress > 1.0f) player.portalProgress = 1.0f;
        if (serverPlayer.portalTicks < delay)
            return false;

        if (serverPlayer.dimension == DimensionId.overworld)
            serverPlayer.overworldPortal = rectangle;
        transferDimension(serverPlayer, rectangle);
        return true;
    }

    void transferDimension(ServerPlayer serverPlayer,
        PortalRectangle sourcePortal)
    {
        PortalRectangle destination;
        if (serverPlayer.dimension == DimensionId.overworld)
        {
            auto spawn = netherWorld.settings.spawn;
            destination = createTestPortal(netherWorld,
                cast(int) spawn.x - 1, cast(int) spawn.y,
                cast(int) spawn.z, sourcePortal.axis);
            serverPlayer.dimension = DimensionId.nether;
        }
        else
        {
            destination = serverPlayer.overworldPortal;
            if (!destination.valid)
            {
                auto spawn = world.settings.spawn;
                destination = createTestPortal(world,
                    cast(int) spawn.x - 1, cast(int) spawn.y,
                    cast(int) spawn.z, PortalAxis.x);
            }
            serverPlayer.dimension = DimensionId.overworld;
        }

        const dx = destination.axis == PortalAxis.x ? 1.0f : 0.0f;
        const dz = destination.axis == PortalAxis.z ? 1.0f : 0.0f;
        const position = Vec3(
            destination.minX + dx * (destination.width * 0.5f) +
                (destination.axis == PortalAxis.z ? 0.5f : 0.0f),
            destination.minY,
            destination.minZ + dz * (destination.width * 0.5f) +
                (destination.axis == PortalAxis.x ? 0.5f : 0.0f));
        auto player = serverPlayer.player;
        player.dimension = serverPlayer.dimension;
        player.position = position;
        player.previousPosition = position;
        player.velocity = Vec3.init;
        player.visualCorrection = Vec3.init;
        player.previousVisualCorrection = Vec3.init;
        player.portalProgress = 1.0f;
        serverPlayer.portalTicks = 0;
        serverPlayer.portalLatched = true;
        serverPlayer.mining = false;
        serverPlayer.miningProgress = 0.0f;
        serverPlayer.queuedInputs.length = 0;
        sendDimensionSnapshot(serverPlayer);
    }

    void respawnPlayer(ServerPlayer serverPlayer)
    {
        if (serverPlayer.player.health > 0.0f)
            return;
        const mode = serverPlayer.player.hardcore
            ? GameMode.spectator : serverPlayer.respawnGameMode;
        serverPlayer.dimension = DimensionId.overworld;
        serverPlayer.player.dimension = DimensionId.overworld;
        serverPlayer.player.portalProgress = 0.0f;
        serverPlayer.portalLatched = false;
        serverPlayer.player.respawnAt(world.settings.spawn, mode);
        serverPlayer.deathMessage = "";
        serverPlayer.damageCause = DamageCause.none;
        serverPlayer.mining = false;
        serverPlayer.miningProgress = 0.0f;
        serverPlayer.queuedInputs.length = 0;
        sendDimensionSnapshot(serverPlayer);
    }

    NetworkPlayerState networkState(ServerPlayer serverPlayer) const
    {
        const player = serverPlayer.player;
        NetworkPlayerState state;
        state.id = serverPlayer.id; state.name = serverPlayer.name;
        state.accountId=serverPlayer.accountId;
        state.skinVersion=serverPlayer.skinVersion;
        state.skinModel=serverPlayer.skinModel;
        state.position = player.position; state.velocity = player.velocity;
        state.yaw = player.yaw; state.pitch = player.pitch;
        state.bodyYaw = player.bodyYaw;
        state.walkPosition = player.walkAnimationPosition;
        state.walkSpeed = player.walkAnimationSpeed;
        state.attackProgress = player.attackProgress;
        state.crouching = player.crouching; state.sprinting = player.sprinting;
        state.onGround = player.onGround; state.health = player.health;
        state.food = cast(ubyte) player.foodLevel;
        state.saturation = player.saturationLevel;
        state.experienceLevel = cast(uint) player.experienceLevel;
        state.experienceProgress = player.experienceProgress;
        state.score = cast(uint) (player.totalExperience < 0
            ? 0 : player.totalExperience);
        state.deathTime = cast(ubyte) player.deathTime;
        state.deathMessage = serverPlayer.deathMessage;
        state.selectedSlot = cast(ubyte) player.selectedSlot;
        state.inventory = player.inventory;
        state.mining = serverPlayer.mining;
        state.miningX = serverPlayer.miningX;
        state.miningY = serverPlayer.miningY;
        state.miningZ = serverPlayer.miningZ;
        state.miningProgress = serverPlayer.miningProgress;
        state.hurtTime = cast(ubyte) player.hurtTime;
        state.hurtDirection = player.hurtDirection;
        state.damageEventId = serverPlayer.damageEventId;
        state.damageCause = serverPlayer.damageCause;
        state.gameMode = player.gameMode;
        state.hardcore = player.hardcore;
        state.flying = player.flying;
        state.skinParts = player.skinParts;
        state.mainHandRight = player.mainHandRight;
        state.dimension = serverPlayer.dimension;
        state.portalProgress = player.portalProgress;
        state.airSupply=cast(short)player.airSupply;
        state.inWater=player.inWater;
        state.eyeInWater=player.eyeInWater;
        state.swimming=player.swimming;
        state.fireTicks=cast(ushort)(player.fireTicks<0?0:player.fireTicks);
        return state;
    }

    void recordDamage(ServerPlayer player, DamageCause cause)
    {
        ++player.damageEventId;
        player.damageCause = cause;
    }

    void broadcastCriticalHit(uint attackerId, uint targetId, Vec3 position,
        DimensionId dimension)
    {
        PacketWriter writer;
        writer.putU8(cast(ubyte) CombatEventType.criticalHit);
        writer.putU32(attackerId); writer.putU32(targetId);
        writer.putVec3(position);
        broadcastToDimension(framePacket(GamePacketType.combatEvent,
            writer.data), dimension);
    }

    void broadcastSnapshots()
    {
        synchronized (peersMutex)
        foreach (peer; peers)
        {
            if (!peer.loggedIn || peer.socket is null) continue;
            auto own = peer.playerId in players;
            if (own is null) continue;
            PacketWriter writer;
            writer.putU32(serverTick);
            writer.putU32((*own).acknowledgedInput);
            writer.putBool(atomicLoad(paused));
            const viewerIsSpectator = (*own).player.gameMode == GameMode.spectator;
            ushort visibleCount;
            foreach (serverPlayer; players)
                if (serverPlayer.dimension == (*own).dimension
                    && (serverPlayer.player.gameMode != GameMode.spectator
                    || viewerIsSpectator)) ++visibleCount;
            writer.putU16(visibleCount);
            foreach (serverPlayer; players)
                if (serverPlayer.dimension == (*own).dimension
                    && (serverPlayer.player.gameMode != GameMode.spectator
                    || viewerIsSpectator))
                    writer.putPlayer(networkState(serverPlayer));
            ushort visibleItems;
            foreach (item; droppedItems)
                if (item.dimension == (*own).dimension) ++visibleItems;
            writer.putU16(visibleItems);
            foreach (item; droppedItems)
                if (item.dimension == (*own).dimension)
                    writer.putDroppedItem(item);
            try peer.send(framePacket(GamePacketType.snapshot, writer.data));
            catch (SocketOSException) {}
        }
    }

    void broadcastBlockChange(int x, int y, int z, BlockId oldBlock,
        BlockId newBlock, uint actorPlayerId, DimensionId dimension)
    {
        PacketWriter writer;
        writer.putI32(x); writer.putI32(y); writer.putI32(z);
        writer.putU8(cast(ubyte) oldBlock); writer.putU8(cast(ubyte) newBlock);
        writer.putU32(actorPlayerId);
        broadcastToDimension(framePacket(GamePacketType.blockChange,
            writer.data), dimension);
    }

    void broadcastPortal(PortalRectangle rectangle, uint actorPlayerId,
        DimensionId dimension)
    {
        const dx = rectangle.axis == PortalAxis.x ? 1 : 0;
        const dz = rectangle.axis == PortalAxis.z ? 1 : 0;
        const portalBlock = rectangle.axis == PortalAxis.x
            ? BlockId.netherPortalX : BlockId.netherPortalZ;
        foreach (row; 0 .. rectangle.height)
        foreach (along; 0 .. rectangle.width)
            broadcastBlockChange(rectangle.minX + along * dx,
                rectangle.minY + row, rectangle.minZ + along * dz,
                BlockId.air, portalBlock, actorPlayerId, dimension);
    }

    void broadcastChat(string message, bool system)
    {
        PacketWriter writer;
        writer.putBool(system);
        writer.putString(message);
        broadcast(framePacket(GamePacketType.chatBroadcast, writer.data));
    }

    void handleHostCommand(ServerPeer senderPeer, ServerPlayer sender,
        string message)
    {
        if (!sender.host)
        {
            sendSystemMessage(senderPeer,
                "You do not have permission to use host commands");
            return;
        }

        const command = parseHostCommand(message);
        if (command.kind == HostCommandKind.invalid)
        {
            sendSystemMessage(senderPeer, command.error);
            return;
        }
        if (command.kind == HostCommandKind.none)
            return;
        if (command.accountId == sender.accountId
            || (hostAccountId.length && command.accountId == hostAccountId))
        {
            sendSystemMessage(senderPeer,
                "The host cannot target their own account");
            return;
        }

        if (command.kind == HostCommandKind.kick)
        {
            auto target = findPeerByAccount(command.accountId);
            if (target is null)
            {
                sendSystemMessage(senderPeer,
                    "No connected player has that account ID");
                return;
            }
            disconnectWithReason(target, "Kicked by the world host");
            sendSystemMessage(senderPeer, "Kicked " ~ command.accountId);
            return;
        }

        if (command.kind == HostCommandKind.unban)
        {
            const removed = worldBans.unban(command.accountId)
                | universalBans.unban(command.accountId);
            sendSystemMessage(senderPeer, removed
                ? "Unbanned " ~ command.accountId
                : "That account was not banned");
            return;
        }

        const now = Clock.currTime.toUnixTime();
        long expiresAt;
        if (command.durationSeconds > 0)
            expiresAt = command.durationSeconds > long.max - now
                ? long.max : now + command.durationSeconds;
        auto bans = command.universal ? universalBans : worldBans;
        bans.ban(command.accountId, expiresAt);
        auto target = findPeerByAccount(command.accountId);
        if (target !is null)
            disconnectWithReason(target, expiresAt == 0
                ? "Permanently banned by the world host"
                : "Temporarily banned by the world host");
        sendSystemMessage(senderPeer, "Banned " ~ command.accountId
            ~ (command.universal ? " from all of your worlds" : " from this world")
            ~ (expiresAt == 0 ? " permanently" : " for "
                ~ to!string(command.durationSeconds) ~ " seconds"));
    }

    void sendSystemMessage(ServerPeer peer, string message)
    {
        PacketWriter writer;
        writer.putBool(true);
        writer.putString(message);
        sendTo(peer, framePacket(GamePacketType.chatBroadcast, writer.data));
    }

    ServerPeer findPeerByAccount(string accountId)
    {
        synchronized (peersMutex)
        foreach (peer; peers)
        {
            if (!peer.loggedIn || peer.socket is null) continue;
            auto candidate = peer.playerId in players;
            if (candidate !is null && (*candidate).accountId == accountId)
                return peer;
        }
        return null;
    }

    void disconnectWithReason(ServerPeer peer, string reason)
    {
        PacketWriter writer;
        writer.putString(reason);
        try peer.send(framePacket(GamePacketType.disconnect, writer.data));
        catch (SocketOSException) {}
        disconnectPeer(peer);
    }

    void sendPickup(uint playerId, Vec3 position, DimensionId dimension)
    {
        PacketWriter writer;
        writer.putU32(playerId); writer.putVec3(position);
        broadcastToDimension(framePacket(GamePacketType.itemPickup,
            writer.data), dimension);
    }

    World worldFor(DimensionId dimension)
    {
        return dimension == DimensionId.nether ? netherWorld : world;
    }

    static bool containsBlock(World candidate, BlockId wanted)
    {
        foreach (coordinate;candidate.loadedChunkCoordinates())
        foreach (y;candidate.minimumBuildY()..candidate.maximumBuildY()+1)
        foreach (localZ;0..Chunk.depth)foreach(localX;0..Chunk.width)
            if (candidate.getBlock(coordinate.x*Chunk.width+localX,y,
                coordinate.z*Chunk.depth+localZ) == wanted) return true;
        return false;
    }

    void sendDimensionSnapshot(ServerPlayer serverPlayer)
    {
        auto activeWorld = worldFor(serverPlayer.dimension);
        PacketWriter writer;
        writer.putU8(cast(ubyte) serverPlayer.dimension);
        writer.putVec3(serverPlayer.player.position);
        synchronized (peersMutex)
        foreach (peer; peers)
            if (peer.loggedIn && peer.playerId == serverPlayer.id
                && peer.socket !is null)
            {
                try peer.send(framePacket(GamePacketType.dimensionChange,
                    writer.data));
                catch (SocketOSException) {}
                peer.sentChunks.clear();
                peer.sentDimension=serverPlayer.dimension;
                syncPeerChunks(peer,serverPlayer,9);
                break;
            }
    }

    void sendChunkData(ServerPeer peer, World source,
        ChunkCoordinate coordinate)
    {
        const loaded=source.chunkAt(coordinate.x,coordinate.z);
        if(loaded is null)return;
        const snapshot=loaded.snapshot();
        const compressed=encodeChunkRuns(snapshot);
        PacketWriter writer;
        writer.putI32(coordinate.x);writer.putI32(coordinate.z);
        if(compressed.length<snapshot.length)
        {
            writer.putU8(chunkEncodingRle);
            writer.data~=compressed;
        }
        else
        {
            writer.putU8(chunkEncodingRaw);
            writer.data~=snapshot;
        }
        sendTo(peer,framePacket(GamePacketType.chunkData,writer.data));
    }

    void sendChunkUnload(ServerPeer peer,ChunkCoordinate coordinate)
    {
        PacketWriter writer;
        writer.putI32(coordinate.x);writer.putI32(coordinate.z);
        sendTo(peer,framePacket(GamePacketType.chunkUnload,writer.data));
    }

    void syncPeerChunks(ServerPeer peer,ServerPlayer serverPlayer,
        int maximumSends=1)
    {
        auto source=worldFor(serverPlayer.dimension);
        if(peer.sentDimension!=serverPlayer.dimension)
        {
            peer.sentChunks.clear();
            peer.sentDimension=serverPlayer.dimension;
        }
        const radius=cast(int)serverPlayer.viewDistance;
        source.ensureChunksAround(serverPlayer.player.position,radius,2);
        const centerX=chunkCoordinate(cast(int)floorf(
            serverPlayer.player.position.x));
        const centerZ=chunkCoordinate(cast(int)floorf(
            serverPlayer.player.position.z));

        ChunkCoordinate[] unloads;
        foreach(coordinate,present;peer.sentChunks)
        {
            int dx=coordinate.x-centerX;if(dx<0)dx=-dx;
            int dz=coordinate.z-centerZ;if(dz<0)dz=-dz;
            if(dx>radius+1||dz>radius+1)unloads~=coordinate;
        }
        foreach(coordinate;unloads)
        {
            sendChunkUnload(peer,coordinate);
            peer.sentChunks.remove(coordinate);
        }

        foreach(sendIndex;0..maximumSends)
        {
            bool found;
            ChunkCoordinate best;
            int bestDistance=int.max;
            foreach(coordinate;source.loadedChunkCoordinates())
            {
                if(coordinate in peer.sentChunks)continue;
                int dx=coordinate.x-centerX;if(dx<0)dx=-dx;
                int dz=coordinate.z-centerZ;if(dz<0)dz=-dz;
                if(dx>radius||dz>radius)continue;
                const distance=dx*dx+dz*dz;
                if(!found||distance<bestDistance)
                {found=true;best=coordinate;bestDistance=distance;}
            }
            if(!found)break;
            sendChunkData(peer,source,best);
            peer.sentChunks[best]=true;
        }
    }

    void trimInactiveChunks(World source,DimensionId dimension)
    {
        bool hasViewer;
        foreach(serverPlayer;players)
            if(serverPlayer.dimension==dimension){hasViewer=true;break;}
        if(!hasViewer)return;
        int removed;
        foreach(coordinate;source.loadedChunkCoordinates())
        {
            bool keep;
            foreach(serverPlayer;players)
            {
                if(serverPlayer.dimension!=dimension)continue;
                const centerX=chunkCoordinate(cast(int)floorf(
                    serverPlayer.player.position.x));
                const centerZ=chunkCoordinate(cast(int)floorf(
                    serverPlayer.player.position.z));
                const radius=cast(int)serverPlayer.viewDistance+2;
                int dx=coordinate.x-centerX;if(dx<0)dx=-dx;
                int dz=coordinate.z-centerZ;if(dz<0)dz=-dz;
                if(dx<=radius&&dz<=radius){keep=true;break;}
            }
            if(keep)continue;
            source.unloadChunk(coordinate.x,coordinate.z,true);
            if(++removed>=2)break;
        }
    }

    void broadcastToDimension(const(ubyte)[] packet, DimensionId dimension)
    {
        synchronized (peersMutex)
        foreach (peer; peers)
        {
            if (!peer.loggedIn || peer.socket is null) continue;
            auto player = peer.playerId in players;
            if (player is null || (*player).dimension != dimension) continue;
            try peer.send(packet);
            catch (SocketOSException) {}
        }
    }

    void sendKeepAlives()
    {
        PacketWriter writer;
        writer.putU32(serverTick);
        broadcast(framePacket(GamePacketType.keepAlive, writer.data));
    }

    void broadcast(const(ubyte)[] packet)
    {
        synchronized (peersMutex)
        foreach (peer; peers)
            if (peer.loggedIn && peer.socket !is null)
                try peer.send(packet);
                catch (SocketOSException) {}
    }

    void sendTo(ServerPeer peer, const(ubyte)[] packet)
    {
        try peer.send(packet);
        catch (SocketOSException) disconnectPeer(peer);
    }

    void removeTimedOutPeers()
    {
        ServerPeer[] expired;
        synchronized (peersMutex)
            foreach (peer; peers)
                if (peer.loggedIn && serverTick - peer.lastHeardTick > 200)
                    expired ~= peer;
        foreach (peer; expired)
            disconnectPeer(peer);
    }

    void disconnectPeer(ServerPeer peer)
    {
        string departedName;
        if (peer.playerId in players)
        {
            departedName = players[peer.playerId].name;
            destroy(players[peer.playerId]);
            players.remove(peer.playerId);
        }
        peer.loggedIn = false;
        peer.close();
        synchronized (peersMutex)
        {
            foreach (index, candidate; peers)
            if (candidate is peer)
            {
                peers[index] = peers[$ - 1];
                peers.length--;
                break;
            }
        }
        if (departedName.length && atomicLoad(running))
            broadcastChat(departedName ~ " left the game", true);
    }

    void enqueue(InboundPacket packet)
    {
        synchronized (inboundMutex)
            inbound ~= packet;
    }

    string sanitizeName(string input)
    {
        char[] result;
        foreach (ubyte value; cast(const(ubyte)[]) input)
        {
            const allowed = value >= 'a' && value <= 'z'
                || value >= 'A' && value <= 'Z'
                || value >= '0' && value <= '9' || value == '_';
            if (allowed && result.length < 16)
                result ~= cast(char) value;
        }
        return result.idup;
    }

    string sanitizeSkinVersion(string input)
    {
        if(input.length>20)return "";
        foreach(character;input)
            if(character<'0'||character>'9')return "";
        return input.idup;
    }

    string uniqueName(string base)
    {
        import std.conv : to;
        string candidate = base;
        int suffix = 2;
        bool taken(string value)
        {
            foreach (serverPlayer; players)
                if (serverPlayer.name == value) return true;
            return false;
        }
        while (taken(candidate))
            candidate = base ~ to!string(suffix++);
        return candidate;
    }

    float randomFloat()
    {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return cast(float) (randomState & 0x00FFFFFFu) / 16777216.0f;
    }

    string portString() const
    {
        import std.conv : to;
        return to!string(listeningPort);
    }

    string discoverLanAddress() const
    {
        // Ask Windows which local interface owns the default IPv4 route. A UDP
        // connect does not send a packet, but gives a much more dependable LAN
        // address than hostname lookup on PCs whose hostname resolves only to
        // loopback.
        try
        {
            auto probe = new Socket(AddressFamily.INET, SocketType.DGRAM,
                ProtocolType.UDP);
            scope (exit) probe.close();
            probe.connect(new InternetAddress("8.8.8.8", 53));
            auto internet = cast(InternetAddress) probe.localAddress();
            if (internet !is null)
            {
                const candidate = internet.toAddrString();
                if (candidate.length && candidate != "127.0.0.1"
                    && candidate != "0.0.0.0")
                    return candidate;
            }
        }
        catch (Exception) {}
        try
        {
            foreach (address; getAddress(Socket.hostName, listeningPort))
            {
                auto internet = cast(InternetAddress) address;
                if (internet is null)
                    continue;
                const candidate = internet.toAddrString();
                if (candidate.length && candidate != "127.0.0.1"
                    && candidate != "0.0.0.0")
                    return candidate;
            }
        }
        catch (Exception) {}
        return "127.0.0.1";
    }
}

private bool receiveExact(Socket socket, ubyte[] destination)
{
    size_t received;
    while (received < destination.length)
    {
        const amount = socket.receive(destination[received .. $]);
        if (amount <= 0) return false;
        received += amount;
    }
    return true;
}

private string fallDeathMessage(string playerName, float fallDistance)
{
    return playerName ~ (fallDistance > 5.0f
        ? " fell from a high place"
        : " hit the ground too hard");
}

unittest
{
    assert(fallDeathMessage("Steve",5.01f)
        == "Steve fell from a high place");
    assert(fallDeathMessage("Steve",5.0f)
        == "Steve hit the ground too hard");
}
