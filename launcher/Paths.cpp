#include "Paths.hpp"

#include "Text.hpp"

#include <Windows.h>

#include <string>

namespace apiko::paths
{
namespace
{
std::wstring Env(const wchar_t* aName)
{
    wchar_t buffer[MAX_PATH * 2];
    DWORD length = GetEnvironmentVariableW(aName, buffer, static_cast<DWORD>(std::size(buffer)));
    return length > 0 && length < std::size(buffer) ? std::wstring(buffer, length) : std::wstring();
}
} // namespace

std::filesystem::path UserDir()
{
    if (auto home = Env(L"APIKO_HOME"); !home.empty())
        return home;
    if (auto local = Env(L"LOCALAPPDATA"); !local.empty())
        return std::filesystem::path(local) / L"Apiko";
    auto profile = Env(L"USERPROFILE");
    return std::filesystem::path(profile.empty() ? L"." : profile) / L"Apiko";
}

std::filesystem::path DataDir()
{
    return UserDir() / L"data";
}

std::filesystem::path ModDir()
{
    std::wstring exe(MAX_PATH, L'\0');
    for (;;)
    {
        DWORD length = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
        if (length < exe.size())
        {
            exe.resize(length);
            break;
        }
        exe.resize(exe.size() * 2);
    }
    return std::filesystem::path(exe).parent_path() / L"plugins" / L"cyber_engine_tweaks" / L"mods" / L"ApisK0";
}

std::filesystem::path ShippedDir(const std::filesystem::path& aModDir)
{
    return aModDir / L"data";
}

nlohmann::json LoadConfig(const std::filesystem::path& aShippedDir)
{
    auto example = aShippedDir / L"config.example.json";
    auto file = UserDir() / L"config.json";
    std::error_code error;
    if (!std::filesystem::exists(file, error))
    {
        std::filesystem::create_directories(file.parent_path(), error);
        std::filesystem::copy_file(example, file, error);
    }
    nlohmann::json defaults = nlohmann::json::object();
    if (auto text = text::ReadFile(example))
        defaults = nlohmann::json::parse(*text, nullptr, false);
    nlohmann::json config = nlohmann::json::object();
    if (auto text = text::ReadFile(file))
        config = nlohmann::json::parse(*text, nullptr, false);
    if (!config.is_object())
        config = nlohmann::json::object();
    if (defaults.is_object())
        for (const auto& [key, value] : defaults.items())
            if (!config.contains(key))
                config[key] = value;
    return config;
}
} // namespace apiko::paths
