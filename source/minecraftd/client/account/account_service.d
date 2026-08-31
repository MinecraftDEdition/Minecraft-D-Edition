module minecraftd.client.account.account_service;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, mkdirRecurse, read, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.string : toStringz;

import minecraftd.platform.clock : monotonicMilliseconds;
import minecraftd.platform.web : openExternalUrl, webRequest;

enum AccountStatus : ubyte
{
    guest,
    loading,
    waitingForBrowser,
    loggedIn,
    error,
}

struct AccountSnapshot
{
    AccountStatus status = AccountStatus.guest;
    string id;
    string email;
    string username;
    string skinPath;
    string skinModel = "classic";
    string message;
    long updatedAt;
    bool busy;

    bool loggedIn() const { return status == AccountStatus.loggedIn; }
}

private struct RemoteSkinFailure
{
    uint attempts;
    uint retryAt;
}

private uint remoteSkinRetryDelay(uint attempts)
{
    // Five seconds initially, doubling to a five-minute ceiling. A missing or
    // temporarily unavailable public skin must never be retried every frame.
    uint delay = 5_000;
    foreach (_; 1 .. attempts)
    {
        if (delay >= 300_000) return 300_000;
        delay *= 2;
    }
    return delay > 300_000 ? 300_000 : delay;
}

final class AccountService
{
    enum serviceOrigin = "https://account.minecraftdedition.com";

    private Mutex mutex;
    private AccountSnapshot current;
    private string token;
    private string tokenPath;
    private string cachedSkinPath;
    private string remoteSkinDirectory;
    private Thread worker;
    private Mutex remoteMutex;
    private string[string] remoteSkinPaths;
    private bool[string] remoteSkinPending;
    private RemoteSkinFailure[string] remoteSkinFailures;
    private Thread[] remoteWorkers;
    private shared bool stopping;
    private uint nextRefresh;

    this(string userData, string cache)
    {
        mutex = new Mutex();
        remoteMutex = new Mutex();
        tokenPath = buildPath(userData, "data", "account_session.token");
        cachedSkinPath = buildPath(cache, "account_skin.png");
        remoteSkinDirectory=buildPath(cache,"player_skins");
        mkdirRecurse(cache);
        mkdirRecurse(remoteSkinDirectory);
        if (exists(tokenPath))
        {
            try token = cast(string) read(tokenPath);
            catch (Exception) token = "";
        }
        if (token.length)
        {
            current.status = AccountStatus.loading;
            startOperation({ refreshProfile(true); });
        }
    }

    ~this()
    {
        stopping = true;
        if (worker !is null && worker.isRunning)
            worker.join();
        foreach(remoteWorker;remoteWorkers)
            if(remoteWorker !is null&&remoteWorker.isRunning)remoteWorker.join();
    }

    AccountSnapshot snapshot()
    {
        synchronized (mutex)
        {
            auto result = current;
            result.id = current.id.idup;
            result.email = current.email.idup;
            result.username = current.username.idup;
            result.skinPath = current.skinPath.idup;
            result.skinModel = current.skinModel.idup;
            result.message = current.message.idup;
            return result;
        }
    }

    void refreshWhenDue()
    {
        if (!token.length || monotonicMilliseconds() < nextRefresh) return;
        synchronized (mutex) if (current.busy) return;
        nextRefresh = monotonicMilliseconds() + 15_000;
        startOperation({ refreshProfile(false); });
    }

    void beginAuthentication(bool signup)
    {
        synchronized (mutex)
        {
            if (current.busy) return;
            current.status = AccountStatus.loading;
            current.message = signup
                ? "Opening the secure account sign-up page..."
                : "Opening the secure account login page...";
        }
        startOperation({ authenticate(signup); });
    }

    void changeUsername(string username)
    {
        const requested = username.idup;
        startOperation({
            try
            {
                const response = authorizedRequest("POST", "/api/profile",
                    "Content-Type: application/json\r\n",
                    cast(const(ubyte)[]) ("{\"username\":\"" ~ requested ~ "\"}"));
                if (response.status != 200)
                    throw new Exception(responseError(response.text));
                refreshProfile(false);
                setMessage("Username changed successfully.");
            }
            catch (Exception error) { setError(error.msg); }
        });
    }

    void changeSkin(string path)
    {
        const selected = path.idup;
        startOperation({
            try
            {
                const bytes = cast(ubyte[]) read(selected);
                if (!isModernSkin(bytes))
                    throw new Exception("That's not a skin, silly!");
                string model;
                synchronized (mutex) model = current.skinModel.idup;
                const response = authorizedRequest("PUT", "/api/skin",
                    "Content-Type: image/png\r\nX-MCDE-Skin-Model: "
                        ~ (model == "slim" ? "slim" : "classic") ~ "\r\n",
                    bytes);
                if (response.status != 200)
                    throw new Exception(responseError(response.text));
                const result=parseJSON(response.text);
                const updated=longField(result,"updatedAt");
                const returnedModel=stringField(result,"skinModel");
                installCachedSkin(bytes);
                synchronized(mutex)
                {
                    current.status=AccountStatus.loggedIn;
                    current.skinPath=cachedSkinPath.idup;
                    current.skinModel=returnedModel=="slim"?"slim":"classic";
                    // A changed revision forces both renderers to upload the
                    // newly installed pixels on their next frame.
                    current.updatedAt=updated>0?updated
                        :current.updatedAt+1;
                    current.message="Skin changed successfully.";
                }
                nextRefresh=monotonicMilliseconds()+15_000;
            }
            catch (Exception error) { setError(error.msg); }
        });
    }

    void signOut()
    {
        startOperation({
            try if (token.length)
                authorizedRequest("POST", "/api/desktop/logout");
            catch (Exception) {}
            clearSession();
        });
    }

    string passwordUrl()
    {
        synchronized (mutex)
            return serviceOrigin ~ "/?player=" ~ current.id ~ "#security";
    }

    string ensureRemoteSkin(string accountId,string revision)
    {
        if(!safeIdentifier(accountId)||!safeRevision(revision))return "";
        const key=(accountId~"-"~revision).idup;
        synchronized(remoteMutex)
        {
            reapRemoteWorkers();
            if(auto found=key in remoteSkinPaths)return (*found).idup;
            if(key in remoteSkinPending)return "";
            const now=monotonicMilliseconds();
            if(auto failure=key in remoteSkinFailures)
                if(now<failure.retryAt)return "";
            // Two transfers are enough for a multiplayer join burst. Further
            // requests remain queued implicitly and are reconsidered next frame.
            if(remoteWorkers.length>=2)return "";
            const destination=buildPath(remoteSkinDirectory,key~".png");
            if(exists(destination))
            {
                remoteSkinPaths[key]=destination;
                remoteSkinFailures.remove(key);
                return destination;
            }
            remoteSkinPending[key]=true;
            const id=accountId.idup;
            auto remoteWorker=new Thread({
                string completed;
                try
                {
                    const response=webRequest("GET",serviceOrigin~"/skins/"
                        ~id~".png?v="~revision);
                    if(response.status==200&&isModernSkin(response.body))
                    {write(destination,response.body);completed=destination;}
                }
                catch(Throwable){}
                synchronized(remoteMutex)
                {
                    remoteSkinPending.remove(key);
                    if(completed.length)
                    {
                        remoteSkinPaths[key]=completed;
                        remoteSkinFailures.remove(key);
                    }
                    else
                    {
                        auto previous=key in remoteSkinFailures;
                        const attempts=previous is null?1:previous.attempts+1;
                        remoteSkinFailures[key]=RemoteSkinFailure(attempts,
                            monotonicMilliseconds()+remoteSkinRetryDelay(attempts));
                    }
                }
            });
            remoteWorkers~=remoteWorker;
            remoteWorker.start();
        }
        return "";
    }

private:
    void reapRemoteWorkers()
    {
        size_t index;
        while(index<remoteWorkers.length)
        {
            auto remoteWorker=remoteWorkers[index];
            if(remoteWorker !is null&&remoteWorker.isRunning)
            {
                ++index;
                continue;
            }
            if(remoteWorker !is null)remoteWorker.join();
            remoteWorkers[index]=remoteWorkers[$-1];
            remoteWorkers.length--;
        }
    }

    void startOperation(void delegate() operation)
    {
        synchronized (mutex)
        {
            if (current.busy) return;
            current.busy = true;
        }
        worker = new Thread({
            scope (exit) synchronized (mutex) current.busy = false;
            operation();
        });
        worker.start();
    }

    void authenticate(bool signup)
    {
        try
        {
            const mode = signup ? "signup" : "login";
            const start = webRequest("POST", serviceOrigin ~ "/api/desktop/start",
                "Content-Type: application/json\r\n",
                cast(const(ubyte)[]) ("{\"mode\":\"" ~ mode ~ "\"}"));
            if (start.status != 200)
                throw new Exception(responseError(start.text));
            const document = parseJSON(start.text);
            const requestId = stringField(document, "requestId");
            const pollSecret = stringField(document, "pollSecret");
            const authorizeUrl = stringField(document, "authorizeUrl");
            if (!requestId.length || !pollSecret.length || !authorizeUrl.length)
                throw new Exception("The account service returned an incomplete login request.");
            if (!openExternalUrl(authorizeUrl))
                throw new Exception("Your default browser could not be opened.");
            synchronized (mutex)
            {
                current.status = AccountStatus.waitingForBrowser;
                current.message = "Finish signing in securely in your browser.";
            }
            foreach (_; 0 .. 300)
            {
                if (stopping) return;
                const payload = "{\"requestId\":\"" ~ requestId
                    ~ "\",\"pollSecret\":\"" ~ pollSecret ~ "\"}";
                const poll = webRequest("POST", serviceOrigin ~ "/api/desktop/poll",
                    "Content-Type: application/json\r\n",
                    cast(const(ubyte)[]) payload);
                if (poll.status == 200)
                {
                    const result = parseJSON(poll.text);
                    token = stringField(result, "token");
                    if (!token.length)
                        throw new Exception("The account service did not return a session.");
                    persistToken();
                    refreshProfile(true);
                    setMessage(signup ? "Account created successfully."
                        : "Logged in successfully.");
                    return;
                }
                if (poll.status != 202)
                    throw new Exception(responseError(poll.text));
                Thread.sleep(1_000.msecs);
            }
            throw new Exception("The account login timed out. Please try again.");
        }
        catch (Exception error) { setError(error.msg); }
    }

    void refreshProfile(bool clearInvalidSession)
    {
        try
        {
            const response = authorizedRequest("GET", "/api/me");
            if (response.status == 401)
            {
                clearSession();
                return;
            }
            if (response.status != 200)
                throw new Exception(responseError(response.text));
            const document = parseJSON(response.text);
            const account = document["account"];
            const id = stringField(account, "id");
            const username = nullableStringField(account, "username");
            const email = stringField(account, "email");
            const model = stringField(account, "skinModel");
            const skinUrl = nullableStringField(account, "skinUrl");
            const updated = longField(account, "updatedAt");
            string localSkin = exists(cachedSkinPath) ? cachedSkinPath : "";
            bool skinReady=!skinUrl.length;
            if (skinUrl.length)
            {
                bool needsDownload;
                synchronized (mutex)
                    needsDownload = current.updatedAt != updated
                        || !exists(cachedSkinPath);
                if (needsDownload)
                {
                    const skin = webRequest("GET", absoluteUrl(skinUrl));
                    if (skin.status == 200 && isModernSkin(skin.body))
                    {
                        installCachedSkin(skin.body);
                        localSkin = cachedSkinPath;
                        skinReady=true;
                    }
                }
                else
                {
                    localSkin = cachedSkinPath;
                    skinReady=true;
                }
            }
            synchronized (mutex)
            {
                current.status = AccountStatus.loggedIn;
                current.id = id.idup;
                current.username = username.idup;
                current.email = email.idup;
                current.skinModel = model == "slim" ? "slim" : "classic";
                current.skinPath = localSkin.idup;
                // Do not accept a new skin revision until its pixels are
                // present. This keeps periodic refreshes retrying transient
                // download failures instead of permanently using stale skin.
                if(skinReady)current.updatedAt = updated;
            }
            nextRefresh = monotonicMilliseconds() + 15_000;
        }
        catch (Exception error) { setError(error.msg); }
    }

    auto authorizedRequest(string method, string path, string headers = "",
        const(ubyte)[] body = null)
    {
        if (!token.length) throw new Exception("Sign in to continue.");
        return webRequest(method, absoluteUrl(path),
            "Authorization: Bearer " ~ token ~ "\r\n" ~ headers, body);
    }

    string absoluteUrl(string path) const
    {
        return path.length && path[0] == '/' ? serviceOrigin ~ path : path;
    }

    void persistToken()
    {
        write(tokenPath ~ ".new", token);
        if (exists(tokenPath)) remove(tokenPath);
        rename(tokenPath ~ ".new", tokenPath);
        version (Posix)
        {
            import core.sys.posix.sys.stat : chmod;
            chmod(tokenPath.toStringz(), 0x180); // 0600
        }
    }

    void installCachedSkin(const(ubyte)[] bytes)
    {
        const temporary=cachedSkinPath~".new";
        write(temporary,bytes);
        if(exists(cachedSkinPath))remove(cachedSkinPath);
        rename(temporary,cachedSkinPath);
    }

    void clearSession()
    {
        token = "";
        try if (exists(tokenPath)) remove(tokenPath);
        catch (Exception) {}
        synchronized (mutex) current = AccountSnapshot.init;
    }

    void setMessage(string value)
    {
        synchronized (mutex) current.message = value.idup;
    }

    void setError(string value)
    {
        synchronized (mutex)
        {
            current.status = token.length ? AccountStatus.loggedIn
                : AccountStatus.error;
            current.message = value.idup;
        }
    }

    static bool isModernSkin(const(ubyte)[] bytes)
    {
        static immutable ubyte[8] signature = [137,80,78,71,13,10,26,10];
        if (bytes.length < 24 || bytes[0 .. 8] != signature[]) return false;
        uint width, height;
        foreach (index; 0 .. 4)
        {
            width = (width << 8) | bytes[16 + index];
            height = (height << 8) | bytes[20 + index];
        }
        return width == 64 && height == 64;
    }

    static bool safeIdentifier(string value)
    {
        if(!value.length||value.length>64)return false;
        foreach(character;value)
            if(!((character>='a'&&character<='z')
                ||(character>='A'&&character<='Z')
                ||(character>='0'&&character<='9')||character=='-'
                ||character=='_'))return false;
        return true;
    }

    static bool safeRevision(string value)
    {
        if(!value.length||value.length>20)return false;
        foreach(character;value)if(character<'0'||character>'9')return false;
        return true;
    }

    static string responseError(string body)
    {
        try
        {
            const document = parseJSON(body);
            const value = stringField(document, "error");
            if (value.length) return value;
        }
        catch (Exception) {}
        return "The account service could not complete that request.";
    }

    static string stringField(JSONValue value, string key)
    {
        if (value.type != JSONType.object || key !in value.object) return "";
        const field = value.object[key];
        return field.type == JSONType.string ? field.str.idup : "";
    }

    static string nullableStringField(JSONValue value, string key)
    {
        return stringField(value, key);
    }

    static long longField(JSONValue value, string key)
    {
        if (value.type != JSONType.object || key !in value.object) return 0;
        const field = value.object[key];
        return field.type == JSONType.integer ? field.integer : 0;
    }
}

unittest
{
    assert(remoteSkinRetryDelay(1)==5_000);
    assert(remoteSkinRetryDelay(2)==10_000);
    assert(remoteSkinRetryDelay(7)==300_000);
    assert(remoteSkinRetryDelay(100)==300_000);
}
