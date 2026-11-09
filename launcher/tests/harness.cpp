// Runs the native bridge outside the game, against a copy of the mod folder, for quick checks before a game test.
// Usage: harness <mod folder copy> <data folder> <seconds> [file of message JSON lines]
// It plays the game's side: keeps game_live.txt fresh, appends the messages to to_bridge.jsonl (with "t" set), then
// prints from_bridge.txt after the given seconds.
#include "../GameFiles.hpp"
#include "../NativeBridge.hpp"
#include "../Text.hpp"

#include <Windows.h>

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <thread>

int wmain(int argc, wchar_t** argv)
{
    if (argc < 4)
    {
        std::wcerr << L"usage: harness <mod dir> <data dir> <seconds> [message JSON...]\n";
        return 2;
    }
    SetConsoleOutputCP(CP_UTF8);
    std::filesystem::path modDir = argv[1];
    std::filesystem::path dataDir = argv[2];
    int seconds = _wtoi(argv[3]);
    auto live = [&] {
        std::ofstream(modDir / L"game_live.txt") << apiko::UnixSeconds();
    };
    live();
    apiko::native::Start(modDir, dataDir);
    std::this_thread::sleep_for(std::chrono::seconds(2));
    // Messages from a file of JSON lines (shells mangle quotes in arguments).
    if (argc > 4)
    {
        std::ifstream in(argv[4]);
        std::string line;
        while (std::getline(in, line))
        {
            // "sleep <seconds>" lines space the messages out (the bridge reads them in batches).
            if (line.rfind("sleep ", 0) == 0)
            {
                for (int s = std::stoi(line.substr(6)); s > 0; --s)
                {
                    live();
                    std::this_thread::sleep_for(std::chrono::seconds(1));
                }
                continue;
            }
            auto message = nlohmann::json::parse(line, nullptr, false);
            if (!message.is_object())
            {
                std::cerr << "bad message line: " << line << "\n";
                continue;
            }
            message["t"] = apiko::UnixSeconds();
            std::ofstream(modDir / L"to_bridge.jsonl", std::ios::app) << message.dump() << "\n";
        }
    }
    for (int i = 0; i < seconds; ++i)
    {
        live();
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    apiko::native::Stop();
    if (auto replies = apiko::text::ReadFile(modDir / L"from_bridge.txt"))
        std::cout << "--- from_bridge.txt\n" << *replies;
    return 0;
}
