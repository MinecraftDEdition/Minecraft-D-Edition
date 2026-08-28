module minecraftd.client.chat.chat_client;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.socket : InternetAddress, SocketOSException, SocketShutdown, TcpSocket;

import minecraftd.network.chat_protocol : ChatPacketType,
    decodePacketLength, encodeChatPacket, maximumChatPacketBytes;

final class ChatClient
{
    private TcpSocket socket;
    private Thread receiveThread;
    private Mutex inboxMutex;
    private Mutex sendMutex;
    private string[] inbox;
    private shared bool running;

    this(string host = "127.0.0.1", ushort port = 25566)
    {
        inboxMutex = new Mutex();
        sendMutex = new Mutex();
        socket = new TcpSocket(new InternetAddress(host, port));
        scope (failure) socket.close();
        atomicStore(running, true);
        receiveThread = new Thread({ receiveLoop(); });
        receiveThread.start();
    }

    ~this()
    {
        atomicStore(running, false);
        if (socket !is null)
        {
            socket.shutdown(SocketShutdown.BOTH);
            socket.close();
        }
        if (receiveThread !is null)
            receiveThread.join();
    }

    void sendChat(string message)
    {
        const packet = encodeChatPacket(ChatPacketType.clientMessage, message);
        synchronized (sendMutex)
        {
            size_t sent;
            while (sent < packet.length)
            {
                const amount = socket.send(packet[sent .. $]);
                if (amount <= 0)
                    return;
                sent += amount;
            }
        }
    }

    string[] pollMessages()
    {
        synchronized (inboxMutex)
        {
            auto result = inbox.dup;
            inbox.length = 0;
            return result;
        }
    }

private:
    void receiveLoop()
    {
        ubyte[4] header;
        while (atomicLoad(running))
        {
            try
            {
                if (!receiveExact(header[]))
                    break;
                const length = decodePacketLength(header[]);
                if (length < 1 || length > maximumChatPacketBytes)
                    break;
                ubyte[] body = new ubyte[length];
                if (!receiveExact(body))
                    break;
                if (body[0] == ChatPacketType.serverBroadcast)
                {
                    const message = cast(string) body[1 .. $].idup;
                    synchronized (inboxMutex)
                        inbox ~= message;
                }
            }
            catch (SocketOSException)
            {
                break;
            }
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
