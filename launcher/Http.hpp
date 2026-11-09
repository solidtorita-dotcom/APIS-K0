// HTTPS requests with WinHTTP (part of Windows: no extra DLLs). Blocking: call from the bridge's worker threads,
// never from the game thread.
#pragma once

#include <filesystem>
#include <map>
#include <stdexcept>
#include <string>

namespace apiko::http
{
// A failed request: no connection, timeout, or an HTTP error status (then `status` is set and the message has the
// start of the response body).
class Error : public std::runtime_error
{
public:
    explicit Error(const std::string& aMessage, int aStatus = 0)
        : std::runtime_error(aMessage)
        , status(aStatus)
    {
    }
    int status;
};

// POST aBody to aUrl (GET when aBody is null); returns the response body of a 2xx answer, else throws Error.
std::string Request(const std::string& aUrl, const std::string* aBody, const std::map<std::string, std::string>& aHeaders,
                    double aTimeoutSeconds);

// GET aUrl into aFile (through aFile.part, so a cut download is never kept); throws Error. For big files: the body
// goes to disk as it arrives.
void Download(const std::string& aUrl, const std::filesystem::path& aFile, double aTimeoutSeconds);

// The text after "HTTP <status>: " for a short in-game notice.
std::string Snippet(const std::string& aText, std::size_t aMax = 300);
} // namespace apiko::http
