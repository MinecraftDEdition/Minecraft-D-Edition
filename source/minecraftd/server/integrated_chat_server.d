module minecraftd.server.integrated_chat_server;

version (Windows):

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel,
    SocketOSException, SocketShutdown, TcpSocket;

import minecraftd.network.chat_protocol : ChatPacketType,
    decodePacketLength, encodeChatPacket, maximumChatPacketBytes, sanitizeChat;

/// Small authoritative TCP relay. Clients submit unformatted text; only this
/// server assigns the sender name and emits displayable chat broadcasts.
final class IntegratedChatServer
{
    enum ushort defaultPort = 25566;

    private TcpSocket listener;
    private Thread acceptThread;
    private Thread[] workers;
    private Socket[] clients;
    private Mutex clientsMutex;
    private shared bool running;

    this(ushort port = defaultPort)
    {
        clientsMutex = new Mutex();
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        listener.bind(new InternetAddress("127.0.0.1", port));
        listener.listen(16);
        atomicStore(running, true);
        acceptThread = new Thread({ acceptLoop(); });
        acceptThread.start();
    }

    ~this()
    {
        atomicStore(running, false);
        if (listener !is null)
        {
            listener.shutdown(SocketShutdown.BOTH);
            listener.close();
        }
        if (acceptThread !is null)
            acceptThread.join();
        synchronized (clientsMutex)
        {
            foreach (client; clients)
            {
                client.shutdown(SocketShutdown.BOTH);
                client.close();
            }
            clients.length = 0;
        }
        foreach (worker; workers)
            worker.join();
    }

private:
    void acceptLoop()
    {
        while (atomicLoad(running))
        {
            try
            {
                auto client = listener.accept();
                synchronized (clientsMutex)
                    clients ~= client;
                auto worker = new Thread({ clientLoop(client); });
                workers ~= worker;
                worker.start();
            }
            catch (SocketOSException)
            {
                if (!atomicLoad(running))
                    break;
            }
        }
    }

    void clientLoop(Socket client)
    {
        ubyte[4] header;
        while (atomicLoad(running))
        {
            try
            {
                if (!receiveExact(client, header[]))
                    break;
                const length = decodePacketLength(header[]);
                if (length < 1 || length > maximumChatPacketBytes)
                    break;
                ubyte[] body = new ubyte[length];
                if (!receiveExact(client, body))
                    break;
                if (body[0] != ChatPacketType.clientMessage)
                    continue;
                const clean = sanitizeChat(cast(string) body[1 .. $]);
                if (clean.length == 0)
                    continue;
                broadcast("<Steve> " ~ clean);
            }
            catch (SocketOSException)
            {
                break;
            }
        }
        synchronized (clientsMutex)
        {
            foreach (index, candidate; clients)
            {
                if (candidate is client)
                {
                    clients[index] = clients[$ - 1];
                    clients.length--;
                    break;
                }
            }
        }
        client.close();
    }

    void broadcast(string message)
    {
        const packet = encodeChatPacket(ChatPacketType.serverBroadcast, message);
        synchronized (clientsMutex)
        {
            foreach (client; clients)
            {
                try sendAll(client, packet);
                catch (SocketOSException) {}
            }
        }
    }
}

private bool receiveExact(Socket socket, ubyte[] destination)
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

private void sendAll(Socket socket, const(ubyte)[] source)
{
    size_t sent;
    while (sent < source.length)
    {
        const amount = socket.send(source[sent .. $]);
        if (amount <= 0)
            throw new SocketOSException("Chat socket closed while sending");
        sent += amount;
    }
}
