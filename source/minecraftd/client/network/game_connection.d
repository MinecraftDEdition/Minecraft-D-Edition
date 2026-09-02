module minecraftd.client.network.game_connection;

import core.memory : GC;
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : ConvException, to;
import std.socket : InternetAddress, SocketOSException, SocketShutdown, TcpSocket;
import std.string : indexOf, startsWith, strip;

version (MCD_EOS)
    import minecraftd.client.network.eos_service : EosPacket, EosService;
import minecraftd.network.game_protocol : GamePacket, GamePacketType,
    PacketWriter, decodeFrameLength, framePacket, gameProtocolVersion,
    maximumGamePacketBytes;

struct ServerEndpoint
{
    string host;
    ushort port = GameConnection.defaultPort;
    string eosUserId;
    string eosSocketName;
    ushort localPort;
    bool eos;
    bool valid;
}

ServerEndpoint parseServerAddress(string input)
{
    auto value = strip(input);
    if (value.startsWith("mcd://eos/"))
    {
        value = value[10 .. $];
        const slash = value.indexOf('/');
        if (slash <= 0 || slash + 1 >= value.length)
            return ServerEndpoint.init;
        const userId = value[0 .. slash];
        auto socketAndPort = value[slash + 1 .. $];
        string socketName = socketAndPort;
        ushort localPort;
        const portSlash = socketAndPort.indexOf('/');
        if (portSlash != size_t.max)
        {
            if (portSlash == 0 || portSlash + 1 >= socketAndPort.length
                || socketAndPort[portSlash+1 .. $].indexOf('/') != size_t.max)
                return ServerEndpoint.init;
            socketName = socketAndPort[0 .. portSlash];
            try
            {
                const parsed=to!uint(socketAndPort[portSlash+1 .. $]);
                if(parsed==0||parsed>ushort.max)return ServerEndpoint.init;
                localPort=cast(ushort)parsed;
            }
            catch(ConvException)return ServerEndpoint.init;
        }
        if (!validProductUserId(userId) || !validSocketName(socketName))
            return ServerEndpoint.init;
        ServerEndpoint result;
        result.eosUserId = userId.idup;
        result.eosSocketName = socketName.idup;
        result.localPort = localPort;
        result.eos = true;
        result.valid = true;
        return result;
    }
    if (value.startsWith("mcd://"))
        value = value[6 .. $];
    if (value.length == 0)
        return ServerEndpoint.init;

    size_t colon = size_t.max;
    foreach_reverse (index, character; value)
    {
        if (character == ':')
        {
            colon = index;
            break;
        }
    }
    string host = value;
    ushort port = GameConnection.defaultPort;
    if (colon != size_t.max)
    {
        if (colon == 0 || colon + 1 >= value.length)
            return ServerEndpoint.init;
        host = value[0 .. colon];
        try
        {
            const parsed = to!uint(value[colon + 1 .. $]);
            if (parsed == 0 || parsed > ushort.max)
                return ServerEndpoint.init;
            port = cast(ushort) parsed;
        }
        catch (ConvException)
            return ServerEndpoint.init;
    }
    ServerEndpoint result;
    result.host = host.idup;
    result.port = port;
    result.valid = host.length != 0;
    return result;
}

private bool validProductUserId(string value)
{
    // EOS_PRODUCTUSERID_MAX_LENGTH is 32 in the bundled EOS SDK. Product
    // user IDs returned by EOS_ProductUserId_ToString use that 32-character
    // hexadecimal representation.
    if (value.length != 32) return false;
    foreach (character; value)
        if (!((character >= '0' && character <= '9')
            || (character >= 'a' && character <= 'f')
            || (character >= 'A' && character <= 'F')))
            return false;
    return true;
}

private bool validSocketName(string value)
{
    if (value.length < 1 || value.length > 32) return false;
    foreach (character; value)
        if (!((character >= 'A' && character <= 'Z')
            || (character >= 'a' && character <= 'z')
            || (character >= '0' && character <= '9')
            || character == '-' || character == '_' || character == ' '
            || character == '+' || character == '=' || character == '.'))
            return false;
    return true;
}

final class GameConnection
{
    enum ushort defaultPort = 25565;

    private TcpSocket socket;
    private Thread receiveThread;
    private Mutex inboxMutex;
    private Mutex sendMutex;
    private GamePacket[] inbox;
    private shared bool running;
    version (MCD_EOS)
    {
        private EosService eosService;
        private string eosRemoteUserId;
        private string eosSocketName;
        private ubyte[][2] eosStreams;
    }

    this(string playerName = "Steve", string host = "127.0.0.1",
        ushort port = defaultPort,string accountId="",string skinVersion="",
        string skinModel="classic")
    {
        inboxMutex = new Mutex();
        sendMutex = new Mutex();
        socket = new TcpSocket(new InternetAddress(host, port));
        scope (failure) socket.close();
        atomicStore(running, true);
        receiveThread = new Thread({ receiveLoop(); });
        receiveThread.start();

        PacketWriter login;
        login.putU16(gameProtocolVersion);
        login.putString(playerName);
        login.putString(accountId);login.putString(skinVersion);
        login.putString(skinModel);
        sendFramed(framePacket(GamePacketType.loginRequest, login.data));
    }

    version (MCD_EOS) this(EosService service, string playerName,
        ServerEndpoint endpoint,string accountId="",string skinVersion="",
        string skinModel="classic")
    {
        if (service is null || !service.ready || !endpoint.valid || !endpoint.eos)
            throw new Exception("EOS connection is not ready");
        inboxMutex = new Mutex();
        sendMutex = new Mutex();
        eosService = service;
        eosRemoteUserId = endpoint.eosUserId;
        eosSocketName = endpoint.eosSocketName;
        if (!eosService.configureSocket(eosSocketName, false))
            throw new Exception("EOS could not open the remote P2P socket");
        atomicStore(running, true);

        PacketWriter login;
        login.putU16(gameProtocolVersion);
        login.putString(playerName);
        login.putString(accountId);login.putString(skinVersion);
        login.putString(skinModel);
        sendFramed(framePacket(GamePacketType.loginRequest, login.data));
    }

    ~this()
    {
        // A GC-invoked finalizer may not allocate. In particular, converting
        // EOS IDs with toStringz here used to throw InvalidMemoryOperationError
        // on macOS if a freshly-created connection crossed a compiler liveness
        // gap while the multiplayer menu was rendering.
        if (GC.inFinalizer)
        {
            const wasRunning = atomicLoad(running);
            atomicStore(running, false);
            version (MCD_EOS) if (eosService !is null)
            {
                if (wasRunning)
                    eosService.closePeer(eosRemoteUserId, eosSocketName);
                eosService = null;
                eosRemoteUserId = null;
                eosSocketName = null;
                foreach(ref stream;eosStreams)stream=null;
            }
            return;
        }
        close();
    }

    bool connected() const
    {
        return atomicLoad(running);
    }

    void close()
    {
        version (MCD_EOS)
        {
            if (!atomicLoad(running) && socket is null && eosService is null)
                return;
        }
        else
        {
            if (!atomicLoad(running) && socket is null)
                return;
        }
        const wasRunning = atomicLoad(running);
        atomicStore(running, false);
        version (MCD_EOS) if (eosService !is null)
        {
            // If EOS already reported the link closed, a replacement may have
            // re-opened this same host/socket before this stale object is
            // destroyed. Do not close that new connection during reconnect.
            if (wasRunning)
                eosService.closePeer(eosRemoteUserId, eosSocketName);
            eosService = null;
            foreach(ref stream;eosStreams)stream.length=0;
        }
        if (socket !is null)
        {
            try socket.shutdown(SocketShutdown.BOTH);
            catch (SocketOSException) {}
            socket.close();
            socket = null;
        }
        if (receiveThread !is null)
        {
            receiveThread.join();
            receiveThread = null;
        }
    }

    void send(GamePacketType type, const(ubyte)[] payload = null)
    {
        sendFramed(framePacket(type, payload));
    }

    void sendFramed(const(ubyte)[] packet)
    {
        if (!atomicLoad(running))
            return;
        version (MCD_EOS) if (eosService !is null)
        {
            size_t offset;
            while (offset < packet.length)
            {
                const count = (packet.length - offset) < EosService.streamChunkBytes
                    ? packet.length - offset : EosService.streamChunkBytes;
                if (!eosService.send(eosRemoteUserId, eosSocketName, 0,
                    packet[offset .. offset + count]))
                {
                    atomicStore(running, false);
                    return;
                }
                offset += count;
            }
            return;
        }
        if (socket is null) return;
        synchronized (sendMutex)
        {
            try
            {
                size_t sent;
                while (sent < packet.length)
                {
                    const amount = socket.send(packet[sent .. $]);
                    if (amount <= 0)
                    {
                        atomicStore(running, false);
                        return;
                    }
                    sent += amount;
                }
            }
            catch (SocketOSException)
                atomicStore(running, false);
        }
    }

    GamePacket[] poll()
    {
        version (MCD_EOS) if (eosService !is null && atomicLoad(running))
            pollEos();
        synchronized (inboxMutex)
        {
            auto result = inbox.dup;
            inbox.length = 0;
            return result;
        }
    }

private:
    version (MCD_EOS)
    {
    void pollEos()
    {
        EosPacket packet;
        while (eosService.receive(packet))
        {
            if (packet.remoteUserId != eosRemoteUserId
                || packet.socketName != eosSocketName || packet.channel > 1)
                continue;
            GamePacket[] decoded;
            if (!appendAndDecodeFrames(eosStreams[packet.channel], decoded,
                packet.data))
            {
                atomicStore(running, false);
                return;
            }
            synchronized (inboxMutex)
                inbox ~= decoded;
        }
        string closed;
        while ((closed = eosService.pollClosedPeer()).length)
            if (closed == eosRemoteUserId)
                atomicStore(running, false);
    }
    }

    void receiveLoop()
    {
        ubyte[4] header;
        while (atomicLoad(running))
        {
            try
            {
                if (!receiveExact(header[]))
                    break;
                const length = decodeFrameLength(header[]);
                if (length < 1 || length > maximumGamePacketBytes)
                    break;
                auto body = new ubyte[length];
                if (!receiveExact(body))
                    break;
                const type = cast(GamePacketType) body[0];
                auto payload = body[1 .. $].dup;
                synchronized (inboxMutex)
                    inbox ~= GamePacket(type, payload);
            }
            catch (SocketOSException)
                break;
        }
        atomicStore(running, false);
    }

    bool receiveExact(ubyte[] destination)
    {
        size_t received;
        while (received < destination.length)
        {
            const amount = socket.receive(destination[received .. $]);
            if (amount <= 0)
                return false;
            received += amount;
        }
        return true;
    }
}

private bool appendAndDecodeFrames(ref ubyte[] stream,
    ref GamePacket[] decoded, const(ubyte)[] incoming)
{
    stream ~= incoming;
    while (stream.length >= 4)
    {
        const length = decodeFrameLength(stream[0 .. 4]);
        if (length < 1 || length > maximumGamePacketBytes)
        {
            stream.length = 0;
            return false;
        }
        if (stream.length < 4 + length)
            return true;
        const type = cast(GamePacketType) stream[4];
        decoded ~= GamePacket(type, stream[5 .. 4 + length].dup);
        stream = stream[4 + length .. $];
    }
    return true;
}

unittest
{
    auto endpoint = parseServerAddress("mcd://192.168.1.4:30123");
    assert(endpoint.valid && endpoint.host == "192.168.1.4"
        && endpoint.port == 30123);
    endpoint = parseServerAddress("localhost");
    assert(endpoint.valid && endpoint.port == GameConnection.defaultPort);
    assert(!parseServerAddress("host:nope").valid);
    endpoint = parseServerAddress("mcd://eos/"
        ~ "0123456789abcdef0123456789abcdef"
        ~ "/AbCdEf0123456789-_______");
    assert(endpoint.valid && endpoint.eos
        && endpoint.eosSocketName == "AbCdEf0123456789-_______");
    assert(!parseServerAddress("mcd://eos/not-a-user/socket").valid);
    endpoint=parseServerAddress("mcd://eos/"
        ~"0123456789abcdef0123456789abcdef"
        ~"/MCD-LOCAL/25565");
    assert(endpoint.valid&&endpoint.eos&&endpoint.localPort==25565
        &&endpoint.eosSocketName=="MCD-LOCAL");
    assert(!parseServerAddress("mcd://eos/"
        ~ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        ~ "/MCD-LOCAL/25565").valid);

    auto payload = new ubyte[5000];
    foreach (index, ref value; payload) value = cast(ubyte) index;
    const framed = framePacket(GamePacketType.chatSubmit, payload);
    ubyte[] stream;
    GamePacket[] decoded;
    assert(appendAndDecodeFrames(stream, decoded, framed[0 .. 3]));
    assert(decoded.length == 0);
    foreach (offset; 3 .. framed.length)
        assert(appendAndDecodeFrames(stream, decoded, framed[offset .. offset + 1]));
    assert(decoded.length == 1 && decoded[0].type == GamePacketType.chatSubmit);
    assert(decoded[0].payload == payload && stream.length == 0);
}
