module minecraftd.network.chat_protocol;

enum ChatPacketType : ubyte
{
    clientMessage = 1,
    serverBroadcast = 2,
}

enum uint maximumChatPacketBytes = 4096;

ubyte[] encodeChatPacket(ChatPacketType type, string text)
{
    const length = cast(uint) text.length + 1u;
    ubyte[] output = new ubyte[4 + length];
    output[0] = cast(ubyte) (length >> 24);
    output[1] = cast(ubyte) (length >> 16);
    output[2] = cast(ubyte) (length >> 8);
    output[3] = cast(ubyte) length;
    output[4] = cast(ubyte) type;
    foreach (index, value; cast(const(ubyte)[]) text)
        output[5 + index] = value;
    return output;
}

uint decodePacketLength(const(ubyte)[] header)
{
    if (header.length != 4)
        return 0;
    return (cast(uint) header[0] << 24)
        | (cast(uint) header[1] << 16)
        | (cast(uint) header[2] << 8)
        | cast(uint) header[3];
}

string sanitizeChat(string input)
{
    char[] output;
    output.reserve(256);
    bool pendingSpace;
    foreach (ubyte value; cast(const(ubyte)[]) input)
    {
        if (value == ' ' || value == '\t' || value == '\r' || value == '\n')
        {
            if (output.length != 0)
                pendingSpace = true;
            continue;
        }
        // The first renderer uses Java's ASCII bitmap provider. Reject control
        // and non-ASCII bytes at the authority boundary until Unihex lands.
        if (value < 32 || value > 126)
            continue;
        if (pendingSpace && output.length < 256)
            output ~= ' ';
        pendingSpace = false;
        if (output.length < 256)
            output ~= cast(char) value;
    }
    return output.idup;
}

unittest
{
    const packet = encodeChatPacket(ChatPacketType.clientMessage, "hello");
    assert(decodePacketLength(packet[0 .. 4]) == 6);
    assert(packet[4] == ChatPacketType.clientMessage);
    assert(sanitizeChat("  hello\t  world\r\n") == "hello world");
}
