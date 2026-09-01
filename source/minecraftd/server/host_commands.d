module minecraftd.server.host_commands;

import std.algorithm : sort;
import std.conv : ConvException, to;
import std.file : exists, readText, write;
import std.string : split, splitLines, strip;

enum HostCommandKind : ubyte
{
    none,
    ban,
    kick,
    unban,
    invalid,
}

struct HostCommand
{
    HostCommandKind kind;
    string accountId;
    bool universal;
    long durationSeconds;
    string error;
}

HostCommand parseHostCommand(string input)
{
    const parts=strip(input).split();
    if(!parts.length||!parts[0].length||parts[0][0]!='/')
        return HostCommand.init;
    const name=parts[0];
    if(name=="/kick"||name=="/unban")
    {
        if(parts.length!=2||!validAccountId(parts[1]))
            return invalid("Usage: "~name~" <account id>");
        HostCommand result;
        result.kind=name=="/kick"?HostCommandKind.kick:HostCommandKind.unban;
        result.accountId=parts[1].idup;
        return result;
    }
    if(name!="/ban")return invalid("Unknown command: "~name);
    if(parts.length<2||parts.length>7||!validAccountId(parts[1]))
        return invalid("Usage: /ban <account id> [universal] [seconds] "
            ~"[minutes] [hours] [days]");

    HostCommand result;
    result.kind=HostCommandKind.ban;
    result.accountId=parts[1].idup;
    size_t durationStart=2;
    if(parts.length>2)
    {
        if(parts[2]=="true"||parts[2]=="false")
        {
            result.universal=parts[2]=="true";
            durationStart=3;
        }
        // The scope is optional. If the next value is numeric, interpret it
        // as seconds so `/ban <id> 30` remains a useful shorthand.
    }
    if(parts.length-durationStart>4)
        return invalid("Usage: /ban <account id> [universal] [seconds] "
            ~"[minutes] [hours] [days]");
    immutable long[4] multipliers=[1,60,3600,86_400];
    foreach(index;durationStart..parts.length)
    {
        ulong value;
        try value=to!ulong(parts[index]);
        catch(ConvException)
            return invalid("Ban durations must be non-negative whole numbers");
        const multiplier=multipliers[index-durationStart];
        if(value>cast(ulong)(long.max-result.durationSeconds)
            /cast(ulong)multiplier)
            return invalid("The requested ban duration is too large");
        result.durationSeconds+=cast(long)value*multiplier;
    }
    return result;
}

private HostCommand invalid(string message)
{
    HostCommand result;
    result.kind=HostCommandKind.invalid;
    result.error=message;
    return result;
}

private bool validAccountId(string value)
{
    if(!value.length||value.length>128)return false;
    foreach(character;value)
        if(character<=0x20||character==0x7F)return false;
    return true;
}

struct BanRecord
{
    long expiresAt; // Unix time; zero is permanent.
}

final class BanList
{
    private string path;
    private BanRecord[string] records;

    this(string path)
    {
        this.path=path;
        load();
    }

    void ban(string accountId,long expiresAt)
    {
        records[accountId.idup]=BanRecord(expiresAt);
        save();
    }

    bool unban(string accountId)
    {
        const removed=records.remove(accountId);
        if(removed)save();
        return removed;
    }

    bool contains(string accountId,long now)
    {
        auto record=accountId in records;
        if(record is null)return false;
        if(record.expiresAt!=0&&record.expiresAt<=now)
        {
            records.remove(accountId);
            save();
            return false;
        }
        return true;
    }

    long expiry(string accountId) const
    {
        auto record=accountId in records;
        return record is null?-1:record.expiresAt;
    }

private:
    void load()
    {
        if(!path.length||!exists(path))return;
        try foreach(line;readText(path).splitLines())
        {
            const columns=line.split("\t");
            if(columns.length!=2||!validAccountId(columns[0]))continue;
            try records[columns[0].idup]=BanRecord(to!long(columns[1]));
            catch(ConvException){}
        }
        catch(Exception){}
    }

    void save()
    {
        if(!path.length)return;
        auto ids=records.keys;
        sort(ids);
        string output;
        foreach(id;ids)
            output~=id~"\t"~to!string(records[id].expiresAt)~"\n";
        try write(path,output);
        catch(Exception){}
    }
}

unittest
{
    auto command=parseHostCommand("/ban auth0|abc true 5 2 1 1");
    assert(command.kind==HostCommandKind.ban&&command.universal);
    assert(command.durationSeconds==5+2*60+3600+86_400);
    command=parseHostCommand("/ban auth0|abc");
    assert(command.kind==HostCommandKind.ban&&command.durationSeconds==0);
    command=parseHostCommand("/ban auth0|abc 30");
    assert(command.kind==HostCommandKind.ban&&!command.universal
        &&command.durationSeconds==30);
    assert(parseHostCommand("/kick auth0|abc").kind==HostCommandKind.kick);
    assert(parseHostCommand("/unban auth0|abc").kind==HostCommandKind.unban);
    assert(parseHostCommand("/ban auth0|abc maybe").kind
        ==HostCommandKind.invalid);

    auto bans=new BanList("");
    scope(exit)destroy(bans);
    bans.ban("auth0|temporary",200);
    assert(bans.contains("auth0|temporary",199));
    assert(!bans.contains("auth0|temporary",200));
    bans.ban("auth0|permanent",0);
    assert(bans.contains("auth0|permanent",long.max));
}
