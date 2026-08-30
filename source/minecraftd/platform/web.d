module minecraftd.platform.web;

import core.stdc.string : memcpy;
import std.string : fromStringz, toStringz;

struct WebResponse
{
    int status;
    ubyte[] body;

    string text() const { return cast(string) body.idup; }
}

private extern(C) nothrow
{
    int mcdWebRequest(const(char)* method, const(char)* url,
        const(char)* headers, const(ubyte)* body, uint bodyLength,
        int* status, ubyte** response, uint* responseLength,
        char* error, uint errorCapacity);
    void mcdWebFree(void* memory);
    int mcdOpenExternalUrl(const(char)* url);
    uint mcdChooseSkinPng(char* output, uint capacity);
    int mcdAcquireSingleInstance(const(char)* lockPath);
}

WebResponse webRequest(string method, string url, string headers = "",
    const(ubyte)[] body = null)
{
    int status;
    ubyte* received;
    uint receivedLength;
    char[1024] error = 0;
    const success = mcdWebRequest(method.toStringz(), url.toStringz(),
        headers.toStringz(), body.length ? body.ptr : null,
        cast(uint) body.length, &status, &received, &receivedLength,
        error.ptr, cast(uint) error.length);
    if (!success)
        throw new Exception(error[0] ? fromStringz(error.ptr).idup
            : "The secure account request failed");
    scope (exit) if (received !is null) mcdWebFree(received);
    WebResponse result;
    result.status = status;
    result.body.length = receivedLength;
    if (receivedLength) memcpy(result.body.ptr, received, receivedLength);
    return result;
}

bool openExternalUrl(string url)
{
    return mcdOpenExternalUrl(url.toStringz()) != 0;
}

string chooseSkinPng()
{
    char[32 * 1024] path = 0;
    const length = mcdChooseSkinPng(path.ptr, cast(uint) path.length);
    return length ? path[0 .. length].idup : "";
}

bool acquireSingleInstance(string lockPath)
{
    return mcdAcquireSingleInstance(lockPath.toStringz()) != 0;
}
