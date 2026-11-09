#include "Http.hpp"

#include "Text.hpp"

#include <Windows.h>
#include <winhttp.h>

#include <memory>

#pragma comment(lib, "winhttp.lib")

namespace apiko::http
{
namespace
{
constexpr const wchar_t* UserAgent = L"APIS-K0-bridge";

struct HandleCloser
{
    void operator()(HINTERNET aHandle) const { WinHttpCloseHandle(aHandle); }
};
using Handle = std::unique_ptr<void, HandleCloser>;

// One session for the whole game: it keeps connections alive between requests to the same host.
HINTERNET Session()
{
    static Handle session(WinHttpOpen(UserAgent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                                      WINHTTP_NO_PROXY_BYPASS, 0));
    return session.get();
}

std::string LastError(const char* aWhat)
{
    return std::string("connection failed (") + aWhat + ", Windows error " + std::to_string(GetLastError()) + ")";
}
} // namespace

std::string Snippet(const std::string& aText, std::size_t aMax)
{
    return text::Truncate(aText, aMax);
}

std::string Request(const std::string& aUrl, const std::string* aBody, const std::map<std::string, std::string>& aHeaders,
                    double aTimeoutSeconds)
{
    if (!Session())
        throw Error(LastError("WinHttpOpen"));
    std::wstring url = text::Widen(aUrl);
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts))
        throw Error("bad URL: " + aUrl);
    std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    if (parts.lpszExtraInfo)
        path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

    Handle connection(WinHttpConnect(Session(), host.c_str(), parts.nPort, 0));
    if (!connection)
        throw Error(LastError("connect"));
    DWORD flags = parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
    Handle request(WinHttpOpenRequest(connection.get(), aBody ? L"POST" : L"GET", path.c_str(), nullptr,
                                      WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags));
    if (!request)
        throw Error(LastError("open request"));
    int timeout = static_cast<int>(aTimeoutSeconds * 1000);
    WinHttpSetTimeouts(request.get(), timeout, timeout, timeout, timeout);
    DWORD decompression = WINHTTP_DECOMPRESSION_FLAG_ALL;
    WinHttpSetOption(request.get(), WINHTTP_OPTION_DECOMPRESSION, &decompression, sizeof(decompression));

    std::wstring headers;
    for (const auto& [name, value] : aHeaders)
        headers += text::Widen(name) + L": " + text::Widen(value) + L"\r\n";
    const void* body = aBody ? aBody->data() : WINHTTP_NO_REQUEST_DATA;
    DWORD length = aBody ? static_cast<DWORD>(aBody->size()) : 0;
    if (!WinHttpSendRequest(request.get(), headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
                            static_cast<DWORD>(-1L), const_cast<void*>(body), length, length, 0))
        throw Error(LastError("send"));
    if (!WinHttpReceiveResponse(request.get(), nullptr))
        throw Error(LastError("receive"));

    DWORD status = 0;
    DWORD size = sizeof(status);
    WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                        &status, &size, WINHTTP_NO_HEADER_INDEX);

    std::string response;
    for (;;)
    {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request.get(), &available))
            throw Error(LastError("read"));
        if (available == 0)
            break;
        auto start = response.size();
        response.resize(start + available);
        DWORD read = 0;
        if (!WinHttpReadData(request.get(), response.data() + start, available, &read))
            throw Error(LastError("read"));
        response.resize(start + read);
    }
    if (status < 200 || status >= 300)
        throw Error("HTTP " + std::to_string(status) + ": " + Snippet(response), static_cast<int>(status));
    return response;
}
} // namespace apiko::http
