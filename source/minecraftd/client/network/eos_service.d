module minecraftd.client.network.eos_service;

version (MCD_EOS)
{
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.file : exists, mkdirRecurse, readText;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.socket : InternetAddress, SocketOSException, SocketShutdown, TcpSocket;
import std.string : fromStringz, toStringz;
import minecraftd.platform.paths : platformPaths;

private extern(C) nothrow
{
    void* mcd_eos_create(const(char)* productId, const(char)* sandboxId,
        const(char)* deploymentId, const(char)* clientId,
        const(char)* clientSecret, const(char)* cacheDirectory,
        const(char)* displayName, char* errorBuffer, uint errorCapacity);
    void mcd_eos_destroy(void* context);
    void mcd_eos_tick(void* context);
    int mcd_eos_status(void* context);
    int mcd_eos_copy_error(void* context, char* output, uint capacity);
    int mcd_eos_copy_local_user_id(void* context, char* output, uint capacity);
    int mcd_eos_configure_socket(void* context, const(char)* socketName,
        int hosting, int forceRelays);
    int mcd_eos_send(void* context, const(char)* remoteUserId,
        const(char)* socketName, ubyte channel, const(void)* data, uint length);
    int mcd_eos_receive(void* context, char* remoteOutput,
        uint remoteCapacity, char* socketOutput, uint socketCapacity,
        ubyte* channelOutput, void* dataOutput, uint dataCapacity,
        uint* lengthOutput);
    int mcd_eos_poll_closed(void* context, char* remoteOutput,
        uint remoteCapacity);
    void mcd_eos_close_peer(void* context, const(char)* remoteUserId,
        const(char)* socketName) @nogc;
    int mcd_eos_random_socket_name(char* output, uint capacity);
}

enum EosStatus : int
{
    initializing,
    ready,
    failed,
}

struct EosPacket
{
    string remoteUserId;
    string socketName;
    ubyte channel;
    ubyte[] data;
}

/// Owns the one EOS platform instance used by the game. All EOS SDK work is
/// deliberately pumped on the render/main thread; worker threads only handle
/// the loopback TCP side of hosted peers.
final class EosService
{
    enum uint maximumPacketBytes = 1170;
    enum uint streamChunkBytes = 1100;

    private void* context;
    private string startupError;
    private bool forceRelaysEnabled;

    this(string displayName = "Steve")
    {
        try
        {
            const paths = platformPaths();
            const localConfigPath = buildPath(paths.userData, "data",
                "eos.local.json");
            const clientConfigPath = buildPath(paths.resources, "data",
                "eos.client.json");
            const configPath = exists(localConfigPath)
                ? localConfigPath : clientConfigPath;
            if (!exists(configPath))
            {
                startupError = "EOS is not configured (data/eos.local.json and "
                    ~ "data/eos.client.json are missing)";
                return;
            }
            const root = parseJSON(readText(configPath));
            if (root.type != JSONType.object)
                throw new Exception("the root must be a JSON object");
            const productId = requiredString(root, "productId");
            const sandboxId = requiredString(root, "sandboxId");
            const deploymentId = requiredString(root, "deploymentId");
            const clientId = requiredString(root, "clientId");
            const clientSecret = requiredString(root, "clientSecret");
            auto forceRelaysValue = "forceRelays" in root.object;
            if (forceRelaysValue !is null)
            {
                if (forceRelaysValue.type != JSONType.true_
                    && forceRelaysValue.type != JSONType.false_)
                    throw new Exception("'forceRelays' must be true or false");
                forceRelaysEnabled = forceRelaysValue.boolean;
            }
            const cacheDirectory = buildPath(paths.cache, "eos");
            mkdirRecurse(cacheDirectory);
            char[512] nativeError = 0;
            context = mcd_eos_create(toStringz(productId), toStringz(sandboxId),
                toStringz(deploymentId), toStringz(clientId),
                toStringz(clientSecret), toStringz(cacheDirectory),
                toStringz(displayName), nativeError.ptr,
                cast(uint) nativeError.length);
            if (context is null)
                startupError = "EOS SDK could not be created";
            else if (nativeError[0] != 0)
                startupError = fromStringz(nativeError.ptr).idup;
        }
        catch (Exception error)
            startupError = "Invalid EOS configuration: " ~ error.msg;
    }

    ~this()
    {
        if (context !is null)
        {
            mcd_eos_destroy(context);
            context = null;
        }
    }

    void tick()
    {
        if (context !is null)
            mcd_eos_tick(context);
    }

    EosStatus status()
    {
        if (context is null)
            return EosStatus.failed;
        return cast(EosStatus) mcd_eos_status(context);
    }

    bool ready() { return status == EosStatus.ready; }

    string error()
    {
        if (startupError.length)
            return startupError;
        if (context is null)
            return "EOS is unavailable";
        char[512] buffer = 0;
        mcd_eos_copy_error(context, buffer.ptr, cast(uint) buffer.length);
        return buffer[0] ? fromStringz(buffer.ptr).idup : "";
    }

    string localUserId()
    {
        if (!ready) return "";
        char[96] buffer = 0;
        return mcd_eos_copy_local_user_id(context, buffer.ptr,
            cast(uint) buffer.length)
            ? fromStringz(buffer.ptr).idup : "";
    }

    bool configureSocket(string socketName, bool hosting)
    {
        return ready && mcd_eos_configure_socket(context,
            toStringz(socketName), hosting ? 1 : 0,
            forceRelaysEnabled ? 1 : 0) != 0;
    }

    bool send(string remoteUserId, string socketName, ubyte channel,
        const(ubyte)[] data)
    {
        return ready && data.length > 0 && data.length <= maximumPacketBytes
            && mcd_eos_send(context, toStringz(remoteUserId),
                toStringz(socketName), channel, data.ptr,
                cast(uint) data.length) != 0;
    }

    bool receive(out EosPacket packet)
    {
        packet = EosPacket.init;
        if (!ready) return false;
        char[96] remote = 0;
        char[40] socket = 0;
        ubyte channel;
        ubyte[maximumPacketBytes] data;
        uint length;
        const result = mcd_eos_receive(context, remote.ptr,
            cast(uint) remote.length, socket.ptr, cast(uint) socket.length,
            &channel, data.ptr, cast(uint) data.length, &length);
        if (result != 1)
            return false;
        packet.remoteUserId = fromStringz(remote.ptr).idup;
        packet.socketName = fromStringz(socket.ptr).idup;
        packet.channel = channel;
        packet.data = data[0 .. length].dup;
        return true;
    }

    string pollClosedPeer()
    {
        if (!ready) return "";
        char[96] remote = 0;
        return mcd_eos_poll_closed(context, remote.ptr,
            cast(uint) remote.length) == 1
            ? fromStringz(remote.ptr).idup : "";
    }

    void closePeer(string remoteUserId, string socketName) @nogc nothrow
    {
        if (context is null || remoteUserId.length == 0
            || socketName.length == 0)
            return;
        char[96] remote = 0;
        char[40] socket = 0;
        if (!copyCString(remoteUserId, remote[])
            || !copyCString(socketName, socket[]))
            return;
        mcd_eos_close_peer(context, remote.ptr, socket.ptr);
    }

    static string createSocketName()
    {
        char[33] buffer = 0;
        return mcd_eos_random_socket_name(buffer.ptr,
            cast(uint) buffer.length)
            ? fromStringz(buffer.ptr).idup : "";
    }

private:
    static bool copyCString(const(char)[] value, char[] output) @nogc nothrow
    {
        if (value.length == 0 || value.length >= output.length)
            return false;
        output[0 .. value.length] = value[];
        output[value.length] = '\0';
        return true;
    }

    static string requiredString(const ref JSONValue root, string key)
    {
        auto value = key in root.object;
        if (value is null || value.type != JSONType.string
            || value.str.length == 0)
            throw new Exception("missing non-empty string '" ~ key ~ "'");
        return value.str.idup;
    }
}

private final class HostPeer
{
    string remoteUserId;
    TcpSocket socket;
    Thread receiveThread;
    Mutex outgoingMutex;
    ubyte[][] outgoing;
    shared bool running;

    this(string remoteUserId, ushort localPort)
    {
        this.remoteUserId = remoteUserId;
        outgoingMutex = new Mutex();
        socket = new TcpSocket(new InternetAddress("127.0.0.1", localPort));
        atomicStore(running, true);
        receiveThread = new Thread({ receiveLoop(); });
        receiveThread.start();
    }

    void write(const(ubyte)[] data)
    {
        if (!atomicLoad(running)) return;
        try
        {
            size_t sent;
            while (sent < data.length)
            {
                const amount = socket.send(data[sent .. $]);
                if (amount <= 0) { atomicStore(running, false); return; }
                sent += amount;
            }
        }
        catch (SocketOSException)
            atomicStore(running, false);
    }

    ubyte[][] takeOutgoing()
    {
        synchronized (outgoingMutex)
        {
            auto result = outgoing;
            outgoing = null;
            return result;
        }
    }

    void close()
    {
        atomicStore(running, false);
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

    ~this() { close(); }

private:
    void receiveLoop()
    {
        ubyte[EosService.streamChunkBytes] buffer;
        while (atomicLoad(running))
        {
            try
            {
                const amount = socket.receive(buffer[]);
                if (amount <= 0) break;
                synchronized (outgoingMutex)
                    outgoing ~= buffer[0 .. amount].dup;
            }
            catch (SocketOSException)
                break;
        }
        atomicStore(running, false);
    }
}

/// Translates each remote EOS peer into its own loopback TCP connection. This
/// lets the existing IntegratedGameServer stay authoritative without exposing
/// a router port to the Internet.
final class EosHostBridge
{
    private EosService eos;
    private ushort localPort;
    private HostPeer[string] peers;
    immutable string socketName;
    immutable string invitation;

    this(EosService eos, ushort localPort)
    {
        if (eos is null || !eos.ready)
            throw new Exception(eos is null ? "EOS is unavailable" : eos.error);
        this.eos = eos;
        this.localPort = localPort;
        socketName = EosService.createSocketName();
        if (socketName.length == 0
            || !eos.configureSocket(socketName, true))
            throw new Exception("EOS could not open the hosted P2P socket");
        const id = eos.localUserId();
        if (id.length == 0)
            throw new Exception("EOS did not provide a local product user ID");
        // The loopback port is ignored by remote machines, but lets a second
        // client sharing this PC and EOS identity connect to the host directly.
        invitation = "mcd://eos/" ~ id ~ "/" ~ socketName ~ "/"
            ~ to!string(localPort);
    }

    ~this()
    {
        foreach (remote, peer; peers)
        {
            eos.closePeer(remote, socketName);
            destroy(peer);
        }
        peers.clear();
    }

    void pump()
    {
        EosPacket packet;
        while (eos.receive(packet))
        {
            if (packet.socketName != socketName || packet.channel != 0)
                continue;
            auto found = packet.remoteUserId in peers;
            if (found is null)
            {
                try
                {
                    peers[packet.remoteUserId] = new HostPeer(
                        packet.remoteUserId, localPort);
                    found = packet.remoteUserId in peers;
                }
                catch (SocketOSException)
                {
                    eos.closePeer(packet.remoteUserId, socketName);
                    continue;
                }
            }
            (*found).write(packet.data);
        }

        string[] remove;
        foreach (remote, peer; peers)
        {
            foreach (chunk; peer.takeOutgoing())
                if (!eos.send(remote, socketName, 0, chunk))
                    atomicStore(peer.running, false);
            if (!atomicLoad(peer.running))
                remove ~= remote;
        }
        string closed;
        while ((closed = eos.pollClosedPeer()).length)
            if (closed in peers) remove ~= closed;
        foreach (remote; remove)
        {
            auto found = remote in peers;
            if (found is null) continue;
            eos.closePeer(remote, socketName);
            destroy(*found);
            peers.remove(remote);
        }
    }
}
}
else
{
    enum EosStatus : int
    {
        initializing,
        ready,
        failed,
    }

    struct EosPacket
    {
        string remoteUserId;
        string socketName;
        ubyte channel;
        ubyte[] data;
    }

    final class EosService
    {
        this(string displayName = "Steve") {}
        void tick() {}
        EosStatus status() { return EosStatus.failed; }
        bool ready() { return false; }
        string error() { return "EOS is not included in this test build"; }
        string localUserId() { return ""; }
    }

    final class EosHostBridge
    {
        string invitation;
        this(EosService eos, ushort localPort)
        {
            throw new Exception("EOS is not included in this test build");
        }
        void pump() {}
    }
}
