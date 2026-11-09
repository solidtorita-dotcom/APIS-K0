// Where the native bridge finds its files, as in bridge\apiko_paths.py:
//   the player's folder  %LOCALAPPDATA%\Apiko (APIKO_HOME overrides it): config.json, data\ (memory, logs), models\
//   the CET mod folder   <game>\bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0: the game files, settings.json
//   shipped data         <mod>\data: prompt.md, config.example.json... (inside Apiko.exe for the Python bridge)
#pragma once

#include <nlohmann/json.hpp>

#include <filesystem>

namespace apiko::paths
{
std::filesystem::path UserDir();
std::filesystem::path DataDir();
// The ApisK0 CET mod folder, from the game's exe (in <game>\bin\x64).
std::filesystem::path ModDir();
std::filesystem::path ShippedDir(const std::filesystem::path& aModDir);

// config.json (bridge tuning) with the defaults of config.example.json for missing keys. Created from the example
// when missing, as the Python bridge does.
nlohmann::json LoadConfig(const std::filesystem::path& aShippedDir);
} // namespace apiko::paths
