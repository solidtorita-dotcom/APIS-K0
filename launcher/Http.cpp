#include "Http.hpp"

#include "Text.hpp"

#include <Windows.h>
#include <winhttp.h>

#include <fstream>
#include <functional>
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

namespace
{
// The request; the body of a 2xx answer goes to aSink in pieces when given, else it is returned.
std::string Perform(const std::string& aUrl, const std::string* aBody, const std::map<std::string, std::string>& aHeaders,
                    double aTimeoutSeconds, const std::function<void(const char*, std::size_t)>* aSink)
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

    bool ok = status >= 200 && status < 300;
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
        if (ok && aSink)
        {
            (*aSink)(response.data(), response.size());
            response.clear();
        }
    }
    if (!ok)
        throw Error("HTTP " + std::to_string(status) + ": " + Snippet(response), static_cast<int>(status));
    return response;
}
} // namespace

std::string Request(const std::string& aUrl, const std::string* aBody, const std::map<std::string, std::string>& aHeaders,
                    double aTimeoutSeconds)
{
    return Perform(aUrl, aBody, aHeaders, aTimeoutSeconds, nullptr);
}

void Download(const std::string& aUrl, const std::filesystem::path& aFile, double aTimeoutSeconds)
{
    auto part = aFile;
    part += L".part";
    std::error_code error;
    std::filesystem::create_directories(aFile.parent_path(), error);
    {
        std::ofstream out(part, std::ios::binary);
        if (!out)
            throw Error("cannot write " + text::PathString(part));
        std::function<void(const char*, std::size_t)> sink = [&](const char* aData, std::size_t aSize) {
            if (!out.write(aData, static_cast<std::streamsize>(aSize)))
                throw Error("cannot write " + text::PathString(part));
        };
        Perform(aUrl, nullptr, {{"User-Agent", "APIS-K0"}}, aTimeoutSeconds, &sink);
    }
    std::filesystem::rename(part, aFile, error);
    if (error)
        throw Error("cannot write " + text::PathString(aFile));
}
} // namespace apiko::http
