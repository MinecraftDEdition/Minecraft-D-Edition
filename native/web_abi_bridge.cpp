#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <shellapi.h>
#include <commdlg.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
HANDLE instanceMutex = nullptr;

std::wstring widen(const char* value) {
    if (!value || !*value) return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        value, -1, nullptr, 0);
    if (count <= 0) return {};
    std::wstring result(static_cast<size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1,
        result.data(), count);
    result.pop_back();
    return result;
}

std::string narrow(const wchar_t* value) {
    if (!value || !*value) return {};
    const int count = WideCharToMultiByte(CP_UTF8, 0, value, -1,
        nullptr, 0, nullptr, nullptr);
    if (count <= 0) return {};
    std::string result(static_cast<size_t>(count), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), count,
        nullptr, nullptr);
    result.pop_back();
    return result;
}

void setError(char* output, unsigned int capacity, const char* message) {
    if (!output || capacity == 0) return;
    const char* source = message ? message : "Unknown web request failure";
    std::strncpy(output, source, capacity - 1);
    output[capacity - 1] = '\0';
}
}

extern "C" __declspec(dllexport) int mcdWebRequest(
    const char* methodUtf8, const char* urlUtf8, const char* headersUtf8,
    const unsigned char* body, unsigned int bodyLength, int* status,
    unsigned char** response, unsigned int* responseLength,
    char* error, unsigned int errorCapacity) {
    if (!methodUtf8 || !urlUtf8 || !status || !response || !responseLength) {
        setError(error, errorCapacity, "Invalid web request arguments");
        return 0;
    }
    *status = 0;
    *response = nullptr;
    *responseLength = 0;
    const auto method = widen(methodUtf8);
    const auto url = widen(urlUtf8);
    const auto headers = widen(headersUtf8 ? headersUtf8 : "");
    if (method.empty() || url.empty()) {
        setError(error, errorCapacity, "The request URL is not valid UTF-8");
        return 0;
    }

    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = static_cast<DWORD>(-1);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts)
        || parts.nScheme != INTERNET_SCHEME_HTTPS) {
        setError(error, errorCapacity, "Only HTTPS account URLs are allowed");
        return 0;
    }
    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    if (parts.dwExtraInfoLength)
        path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

    HINTERNET session = WinHttpOpen(L"Minecraft: D Edition/0.1",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        setError(error, errorCapacity, "Windows could not initialize HTTPS");
        return 0;
    }
    HINTERNET connection = WinHttpConnect(session, host.c_str(), parts.nPort, 0);
    HINTERNET request = connection ? WinHttpOpenRequest(connection,
        method.c_str(), path.c_str(), nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) : nullptr;
    bool ok = request != nullptr;
    if (ok) {
        WinHttpSetTimeouts(request, 10000, 10000, 15000, 15000);
        ok = WinHttpSendRequest(request,
            headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
            headers.empty() ? 0 : static_cast<DWORD>(headers.length()),
            bodyLength ? const_cast<unsigned char*>(body) : WINHTTP_NO_REQUEST_DATA,
            bodyLength, bodyLength, 0) != FALSE;
    }
    if (ok) ok = WinHttpReceiveResponse(request, nullptr) != FALSE;
    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    if (ok) ok = WinHttpQueryHeaders(request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusSize,
        WINHTTP_NO_HEADER_INDEX) != FALSE;

    std::vector<unsigned char> bytes;
    while (ok) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available)) { ok = false; break; }
        if (available == 0) break;
        const size_t start = bytes.size();
        bytes.resize(start + available);
        DWORD read = 0;
        if (!WinHttpReadData(request, bytes.data() + start, available, &read)) {
            ok = false;
            break;
        }
        bytes.resize(start + read);
    }
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    if (!ok) {
        setError(error, errorCapacity, "The secure account request failed");
        return 0;
    }
    if (!bytes.empty()) {
        auto* copy = static_cast<unsigned char*>(std::malloc(bytes.size()));
        if (!copy) {
            setError(error, errorCapacity, "The account response was too large");
            return 0;
        }
        std::memcpy(copy, bytes.data(), bytes.size());
        *response = copy;
        *responseLength = static_cast<unsigned int>(bytes.size());
    }
    *status = static_cast<int>(statusCode);
    return 1;
}

extern "C" __declspec(dllexport) void mcdWebFree(void* memory) {
    std::free(memory);
}

extern "C" __declspec(dllexport) int mcdOpenExternalUrl(const char* urlUtf8) {
    const auto url = widen(urlUtf8);
    if (url.empty()) return 0;
    const auto result = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr,
        L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    return result > 32 ? 1 : 0;
}

extern "C" __declspec(dllexport) unsigned int mcdChooseSkinPng(
    char* output, unsigned int capacity) {
    wchar_t path[32768] = {};
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.lpstrFilter = L"Minecraft skin (*.png)\0*.png\0PNG image (*.png)\0*.png\0";
    dialog.lpstrFile = path;
    dialog.nMaxFile = 32768;
    dialog.lpstrTitle = L"Choose a 64 x 64 Minecraft skin";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    dialog.lpstrDefExt = L"png";
    if (!GetOpenFileNameW(&dialog)) return 0;
    const auto utf8 = narrow(path);
    if (!output || capacity == 0 || utf8.size() + 1 > capacity) return 0;
    std::memcpy(output, utf8.data(), utf8.size());
    output[utf8.size()] = '\0';
    return static_cast<unsigned int>(utf8.size());
}

extern "C" __declspec(dllexport) int mcdAcquireSingleInstance(const char*) {
    instanceMutex = CreateMutexW(nullptr, TRUE,
        L"Local\\MinecraftDEdition.Game.SingleInstance");
    if (!instanceMutex) return 1;
    if (GetLastError() != ERROR_ALREADY_EXISTS) return 1;
    CloseHandle(instanceMutex);
    instanceMutex = nullptr;
    if (HWND existing = FindWindowW(L"MinecraftDEditionWindow", nullptr)) {
        if (IsIconic(existing)) ShowWindow(existing, SW_RESTORE);
        SetForegroundWindow(existing);
    }
    return 0;
}
