#include "GameFiles.hpp"

#include "Log.hpp"

#include <Windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <thread>

namespace apiko
{
namespace
{
constexpr const wchar_t* ToBridge = L"to_bridge.jsonl";
constexpr const wchar_t* FromBridge = L"from_bridge.txt";
constexpr const wchar_t* AliveFile = L"bridge_alive.txt";
constexpr const wchar_t* GameLiveFile = L"game_live.txt";
// Older than this, game_live.txt means no game (main menu, loading, closed or crashed).
constexpr std::int64_t GameLiveStaleSeconds = 5;
constexpr std::size_t RepliesKept = 20;

HANDLE OpenShared(const std::filesystem::path& aFile)
{
    return CreateFileW(aFile.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
}

bool ReadFrom(HANDLE aFile, std::uint64_t aOffset, std::uint64_t aSize, std::string& aOut)
{
    LARGE_INTEGER position{};
    position.QuadPart = static_cast<LONGLONG>(aOffset);
    if (!SetFilePointerEx(aFile, position, nullptr, FILE_BEGIN))
        return false;
    aOut.resize(static_cast<std::size_t>(aSize));
    DWORD read = 0;
    if (!ReadFile(aFile, aOut.data(), static_cast<DWORD>(aOut.size()), &read, nullptr))
        return false;
    aOut.resize(read);
    return true;
}

// Replies are one line each: tabs and line breaks inside the text would break the format.
std::string OneLine(std::string_view aText)
{
    std::string line(aText);
    std::replace_if(line.begin(), line.end(), [](char c) { return c == '\t' || c == '\n' || c == '\r'; }, ' ');
    return line;
}
} // namespace

std::int64_t UnixSeconds()
{
    return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

std::int64_t UnixMillis()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

bool ReadSharedFile(const std::filesystem::path& aFile, std::string& aOut)
{
    HANDLE file = OpenShared(aFile);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    LARGE_INTEGER size{};
    bool ok = GetFileSizeEx(file, &size) && ReadFrom(file, 0, static_cast<std::uint64_t>(size.QuadPart), aOut);
    CloseHandle(file);
    return ok;
}

bool WriteFileAtomic(const std::filesystem::path& aFile, std::string_view aContent)
{
    auto tmp = aFile;
    tmp.replace_extension(L".tmp");
    FILE* out = _wfopen(tmp.c_str(), L"wb");
    if (!out)
        return false;
    std::fwrite(aContent.data(), 1, aContent.size(), out);
    std::fclose(out);
    // The game may have the file open for a moment.
    for (int attempt = 0; attempt < 20; ++attempt)
    {
        if (MoveFileExW(tmp.c_str(), aFile.c_str(), MOVEFILE_REPLACE_EXISTING))
            return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return false;
}

GameFiles::GameFiles(std::filesystem::path aModDir)
    : modDir(std::move(aModDir))
    // Millisecond clock so ids keep growing across bridge restarts (the mod skips ids it has seen).
    , nextReplyId(UnixMillis())
{
}

std::vector<nlohmann::json> GameFiles::ReadNewMessages()
{
    std::vector<nlohmann::json> messages;
    HANDLE file = OpenShared(modDir / ToBridge);
    if (file == INVALID_HANDLE_VALUE)
        return messages;
    LARGE_INTEGER size{};
    std::string chunk;
    bool ok = GetFileSizeEx(file, &size);
    auto fileSize = ok ? static_cast<std::uint64_t>(size.QuadPart) : 0;
    if (ok && fileSize < offset) // truncated by the mod
        offset = 0;
    if (ok && fileSize > offset)
        ok = ReadFrom(file, offset, fileSize - offset, chunk);
    CloseHandle(file);
    if (!ok || chunk.empty())
        return messages;

    // Only complete lines; a line being written stays for the next poll.
    auto end = chunk.rfind('\n');
    if (end == std::string::npos)
        return messages;
    offset += end + 1;
    std::size_t start = 0;
    while (start <= end)
    {
        auto stop = chunk.find('\n', start);
        std::string_view line(chunk.data() + start, stop - start);
        start = stop + 1;
        if (!line.empty() && line.back() == '\r')
            line.remove_suffix(1);
        if (line.empty())
            continue;
        auto message = nlohmann::json::parse(line, nullptr, false);
        if (message.is_object())
            messages.push_back(std::move(message));
        else
            log::Write("bad line from the game: " + std::string(line.substr(0, 120)));
    }
    return messages;
}

void GameFiles::WriteReply(std::string_view aKind, std::string_view aText, double aDuration)
{
    std::lock_guard lock(writeMutex);
    nextReplyId = std::max(nextReplyId + 1, UnixMillis());
    char head[64];
    std::snprintf(head, sizeof(head), "%lld\t", static_cast<long long>(nextReplyId));
    char duration[32];
    std::snprintf(duration, sizeof(duration), "\t%.1f\t", aDuration);
    replies.push_back(head + std::string(aKind) + duration + OneLine(aText));
    while (replies.size() > RepliesKept)
        replies.pop_front();
    std::string content;
    for (const auto& reply : replies)
        content += reply + "\n";
    if (!WriteFileAtomic(modDir / FromBridge, content))
        log::Write("could not replace from_bridge.txt (file locked)");
}

void GameFiles::Heartbeat()
{
    auto path = modDir / AliveFile;
    FILE* out = _wfopen(path.c_str(), L"wb");
    if (!out)
        return;
    std::fprintf(out, "%lld", static_cast<long long>(UnixSeconds()));
    std::fclose(out);
}

void GameFiles::RemoveAlive()
{
    std::error_code error;
    std::filesystem::remove(modDir / AliveFile, error);
}

bool GameFiles::GameLive()
{
    for (int attempt = 0; attempt < 4; ++attempt)
    {
        std::string text;
        if (!ReadSharedFile(modDir / GameLiveFile, text))
        {
            std::error_code error;
            if (!std::filesystem::exists(modDir / GameLiveFile, error))
                return false;
        }
        else
        {
            try
            {
                if (text.find_first_not_of(" \t\r\n") != std::string::npos)
                    return UnixSeconds() - std::stoll(text) <= GameLiveStaleSeconds;
            }
            catch (const std::exception&)
            {
                // Half-written: read again below.
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return false;
}
} // namespace apiko
