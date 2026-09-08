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
    size_t selectionAnchor;
    int screenTicks;
    ChatMessage[] messages;

    private size_t draftCursor;
    private size_t draftSelectionAnchor;

string[] suggestions;
    int suggestionIndex;
    string[] playerNames;
    private string suggestionInput;
    private size_t completionStart;
    void refreshSuggestions()
    {
        import std.string:split,startsWith;
        import minecraftd.game.item.inventory:creativeCatalog,itemIdentifier;
        const prefix=input[0..cursor];
        if(prefix==suggestionInput)return;
        suggestionInput=prefix;suggestions=null;suggestionIndex=0;
        if(!prefix.startsWith("/"))return;
        completionStart=cursor;
        while(completionStart>0&&input[completionStart-1]!=' ')--completionStart;
        const token=input[completionStart..cursor];
        const parts=prefix.split();
        const index=parts.length-(token.length?1:0);
        string[] candidates;
        if(index==0)candidates=["/give","/kill","/clear","/tp","/teleport","/gamemode","/xp","/help","/ban","/kick","/unban"];
        else if(parts.length&&((parts[0]=="/give"&&index==2)||(parts[0]=="/clear"&&index==2)))
        {foreach(item;creativeCatalog)candidates~=itemIdentifier(item);}
        else if(parts.length&&parts[0]=="/gamemode"&&index==1)
            candidates=["survival","creative","adventure","spectator"];
        else if(index==1||(parts.length&&parts[0]=="/gamemode"&&index==2))
            candidates=["@s","@a"]~playerNames;
        foreach(candidate;candidates)
            if(candidate.startsWith(token)&&candidate!=token)suggestions~=candidate;
    }
    void cycleSuggestion(int direction)
    {
        refreshSuggestions();
        if(!suggestions.length)return;
        suggestionIndex=(suggestionIndex+direction+cast(int)suggestions.length)%cast(int)suggestions.length;
    }
    bool acceptSuggestion()
    {
        refreshSuggestions();
        if(!suggestions.length)return false;
        const value=suggestions[suggestionIndex];
        input=input[0..completionStart]~value~" "~input[cursor..$];
        cursor=selectionAnchor=completionStart+value.length+1;
        suggestions=null;suggestionInput="";
        return true;
    }

    void open()
    {
        suggestionInput="";suggestions=null;
        active = true;
        input = draft;
        cursor = draftCursor <= input.length ? draftCursor : input.length;
        selectionAnchor = draftSelectionAnchor <= input.length
            ? draftSelectionAnchor : cursor;
        screenTicks = 0;
    }

    void close(bool saveDraft = false)
    {
        suggestionInput="";suggestions=null;
        active = false;
        if (saveDraft)
        {
            draft = input;
            draftCursor = cursor;
            draftSelectionAnchor = selectionAnchor;
        }
        else
        {
            draft = "";
            draftCursor = draftSelectionAnchor = 0;
        }
        input = "";
        cursor = selectionAnchor = 0;
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
            if (value < 32 || value > 126
                || (!hasSelection && input.length >= maximumInputLength))
                continue;
            eraseSelection();
            input = input[0 .. cursor] ~ cast(char) value ~ input[cursor .. $];
            ++cursor;
            selectionAnchor = cursor;
        }
    }

    void paste(string value)
    {
        import std.utf : toUTF16;
        insertCharacters(toUTF16(value));
    }

    bool hasSelection() const
    {
        return cursor != selectionAnchor;
    }

    size_t selectionStart() const
    {
        return cursor < selectionAnchor ? cursor : selectionAnchor;
    }

    size_t selectionEnd() const
    {
        return cursor > selectionAnchor ? cursor : selectionAnchor;
    }

    string selectedText() const
    {
        return hasSelection ? input[selectionStart .. selectionEnd] : "";
    }

    void selectAll()
    {
        selectionAnchor = 0;
        cursor = input.length;
        screenTicks = 0;
    }

    void setCursor(size_t position, bool selecting = false)
    {
        const next = position <= input.length ? position : input.length;
        if (!selecting)
            selectionAnchor = next;
        cursor = next;
        screenTicks = 0;
    }

    void backspace()
    {
        if (eraseSelection())
            return;
        if (cursor == 0)
            return;
        input = input[0 .. cursor - 1] ~ input[cursor .. $];
        --cursor;
        selectionAnchor = cursor;
    }

    void deleteForward()
    {
        if (eraseSelection())
            return;
        if (cursor >= input.length)
            return;
        input = input[0 .. cursor] ~ input[cursor + 1 .. $];
        selectionAnchor = cursor;
    }

    void moveCursor(int amount, bool selecting = false)
    {
        if (!selecting && hasSelection)
        {
            setCursor(amount < 0 ? selectionStart : selectionEnd);
            return;
        }
        size_t next = cursor;
        if (amount < 0 && next > 0)
            --next;
        else if (amount > 0 && next < input.length)
            ++next;
        setCursor(next, selecting);
    }

    void moveToStart(bool selecting = false)
    {
        setCursor(0, selecting);
    }

    void moveToEnd(bool selecting = false)
    {
        setCursor(input.length, selecting);
    }

    void cutSelection()
    {
        eraseSelection();
    }

    void submit(Network)(Network network)
    {
        if (input.length != 0)
            network.sendChat(input);
        close(false);
    }

private:
    bool eraseSelection()
    {
        if (!hasSelection)
            return false;
        const first = selectionStart;
        const after = selectionEnd;
        input = input[0 .. first] ~ input[after .. $];
        cursor = selectionAnchor = first;
        screenTicks = 0;
        return true;
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

    chat.selectAll();
    assert(chat.selectedText == "helo");
    chat.insertCharacters("world"w);
    assert(chat.input == "world" && chat.cursor == 5 && !chat.hasSelection);

    chat.moveCursor(-1, true);
    chat.moveCursor(-1, true);
    assert(chat.selectedText == "ld");
    chat.deleteForward();
    assert(chat.input == "wor");

    chat.close(true);
    chat.open();
    assert(chat.input == "wor" && chat.cursor == 3);
}
