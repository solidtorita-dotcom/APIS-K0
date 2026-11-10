// The file protocol between the CET mod (init.lua) and the bridge, in the ApisK0 mod folder. Same files and formats
// as the Python bridge (bridge\apiko_bridge.py), so either one can serve the game:
//   to_bridge.jsonl    appended by the game: one JSON object per line (what V says, events, push-to-talk, tests...)
//   from_bridge.txt    rewritten by the bridge: the last replies as "id<TAB>kind<TAB>duration<TAB>text" lines
//                      ("face": the mood of the model reply's subtitle that follows, for the drone's screen;
//                      "react": the face at V's words, before the reply)
//   bridge_alive.txt   unix time, rewritten by the bridge every few seconds
//   game_live.txt      unix time, rewritten by the game every second while a save is loaded and played
#pragma once

#include <nlohmann/json.hpp>

#include <cstdint>
#include <deque>
#include <filesystem>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace apiko
{
class GameFiles
{
public:
    explicit GameFiles(std::filesystem::path aModDir);

    // Complete lines appended to to_bridge.jsonl since the last call, parsed. A line still being written stays for
    // the next call; a bad line is logged and skipped. The game truncates the file now and then: reading restarts.
    std::vector<nlohmann::json> ReadNewMessages();

    // Adds a reply to from_bridge.txt (the game shows each id once). Safe from any thread.
    void WriteReply(std::string_view aKind, std::string_view aText, double aDuration = 0.0);

    void Heartbeat();
    void RemoveAlive();

    // A save is loaded and being played: game_live.txt is fresh. A half-written read is retried.
    bool GameLive();

    const std::filesystem::path& ModDir() const { return modDir; }

private:
    std::filesystem::path modDir;
    std::uint64_t offset = 0;
    std::mutex writeMutex;
    std::deque<std::string> replies;
    std::int64_t nextReplyId;
};

// Unix time in seconds and milliseconds.
std::int64_t UnixSeconds();
std::int64_t UnixMillis();

// Reads a whole small file shared with another process (any sharing allowed). False when it cannot be opened.
bool ReadSharedFile(const std::filesystem::path& aFile, std::string& aOut);

// Writes a file through a temporary one and a replace, retrying while the reader has it open.
bool WriteFileAtomic(const std::filesystem::path& aFile, std::string_view aContent);
} // namespace apiko
