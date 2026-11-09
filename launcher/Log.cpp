#include "Log.hpp"

#include <Windows.h>

#include <cstdio>
#include <mutex>

namespace apiko::log
{
namespace
{
std::mutex logMutex;
FILE* logFile = nullptr;
} // namespace

void Open(const std::filesystem::path& aFile, std::uintmax_t aMaxBytes)
{
    std::lock_guard lock(logMutex);
    if (logFile)
        return;
    std::error_code error;
    std::filesystem::create_directories(aFile.parent_path(), error);
    if (std::filesystem::file_size(aFile, error) > aMaxBytes && !error)
    {
        auto old = aFile;
        old.replace_extension(L".old.log");
        std::filesystem::rename(aFile, old, error);
    }
    // Shared for reading, so the log can be opened while the game runs.
    logFile = _wfsopen(aFile.c_str(), L"ab", _SH_DENYWR);
}

void Close()
{
    std::lock_guard lock(logMutex);
    if (logFile)
    {
        std::fclose(logFile);
        logFile = nullptr;
    }
}

void Write(std::string_view aText)
{
    SYSTEMTIME now;
    GetLocalTime(&now);
    char stamp[32];
    std::snprintf(stamp, sizeof(stamp), "%04u-%02u-%02u %02u:%02u:%02u ", now.wYear, now.wMonth, now.wDay, now.wHour,
                  now.wMinute, now.wSecond);
    std::lock_guard lock(logMutex);
    if (!logFile)
        return;
    std::fputs(stamp, logFile);
    std::fwrite(aText.data(), 1, aText.size(), logFile);
    std::fputc('\n', logFile);
    std::fflush(logFile);
}
} // namespace apiko::log
