module minecraftd.client.chat.chat_state;

enum ChatMessageKind : ubyte
{
    normal,
    system,
}

struct ChatMessage
{
    string text;
    int age;
    ChatMessageKind kind;
}

final class ChatState
{
    enum size_t maximumInputLength = 256;
    enum size_t maximumHistory = 100;

    bool active;
    string input;
    string draft;
    size_t cursor;
    int screenTicks;
    ChatMessage[] messages;

    void open()
    {
        active = true;
        input = draft;
        cursor = 0;
        screenTicks = 0;
    }

    void close(bool saveDraft = false)
    {
        active = false;
        draft = saveDraft ? input : "";
        input = "";
        cursor = 0;
    }

    void tick()
    {
        ++screenTicks;
        foreach (ref message; messages)
            ++message.age;
    }

    void addMessage(string text, ChatMessageKind kind = ChatMessageKind.normal)
    {
        messages ~= ChatMessage(text, 0, kind);
        if (messages.length > maximumHistory)
            messages = messages[$ - maximumHistory .. $].dup;
    }

    void insertCharacters(const(wchar)[] characters)
    {
        foreach (value; characters)
        {
            if (value == 8)
            {
                backspace();
                continue;
            }
            if (value < 32 || value > 126 || input.length >= maximumInputLength)
                continue;
            input = input[0 .. cursor] ~ cast(char) value ~ input[cursor .. $];
            ++cursor;
        }
    }

    void backspace()
    {
        if (cursor == 0)
            return;
        input = input[0 .. cursor - 1] ~ input[cursor .. $];
        --cursor;
    }

    void deleteForward()
    {
        if (cursor >= input.length)
            return;
        input = input[0 .. cursor] ~ input[cursor + 1 .. $];
    }

    void moveCursor(int amount)
    {
        if (amount < 0 && cursor > 0)
            --cursor;
        else if (amount > 0 && cursor < input.length)
            ++cursor;
    }

    void submit(Network)(Network network)
    {
        if (input.length != 0)
            network.sendChat(input);
        close(false);
    }
}

unittest
{
    auto chat = new ChatState();
    chat.open();
    chat.insertCharacters("hello"w);
    chat.moveCursor(-1);
    chat.backspace();
    assert(chat.input == "helo");
}
