// Native bridge log: %LOCALAPPDATA%\Apiko\data\native.log (UTF-8, one timestamped line per entry), next to the
// Python bridge's bridge.log. Safe to call from any thread.
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

namespace apiko::log
{
// Opens (appends to) the log file. Past maxBytes the old log is kept as native.old.log and a new one starts.
void Open(const std::filesystem::path& aFile, std::uintmax_t aMaxBytes = 2 * 1024 * 1024);
void Close();
void Write(std::string_view aText);
} // namespace apiko::log
