// ApisK0 Launcher: a RED4ext plugin that runs the Apiko bridge inside the game (NativeBridge.cpp and friends): the
// reply model, memory, perception, voice and ears, with the same file protocol as the CET mod always used. It
// replaced the Python bridge (Apiko.exe) in 0.2.0: no separate program, no Python.
//
// A file named native.off in <game>\bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0\bridge\ keeps it from starting
// (development: running the Python bridge in bridge\ by hand instead; the last bridge started takes over anyway).
// Uses RED4ext only as a loader (no game types), so it does not depend on the game version.

#include "NativeBridge.hpp"
#include "Paths.hpp"

#include <RED4ext/Common.hpp>

#include <RED4ext/Api/ApiVersion.hpp>
#include <RED4ext/Api/v1/EMainReason.hpp>
#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/PluginInfo.hpp>
#include <RED4ext/Api/v1/Runtime.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>
#include <RED4ext/Api/v1/Version.hpp>

#include <Windows.h>

#include <filesystem>

namespace
{
void StartBridge(RED4ext::v1::PluginHandle aHandle, const RED4ext::v1::Sdk* aSdk)
{
    auto modDir = apiko::paths::ModDir();
    std::error_code error;
    if (std::filesystem::exists(modDir / L"bridge" / L"native.off", error))
    {
        aSdk->logger->Info(aHandle, "native.off found: the bridge was not started.");
        return;
    }
    apiko::native::Start(modDir, apiko::paths::DataDir());
    aSdk->logger->Info(aHandle, "Apiko bridge started (log: %LOCALAPPDATA%\\Apiko\\data\\native.log).");
}
} // namespace

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle, RED4ext::v1::EMainReason aReason,
                                        const RED4ext::v1::Sdk* aSdk)
{
    switch (aReason)
    {
    case RED4ext::v1::EMainReason::Load:
        StartBridge(aHandle, aSdk);
        break;
    case RED4ext::v1::EMainReason::Unload:
        apiko::native::Stop();
        break;
    }
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"ApisK0 Launcher";
    aInfo->author = L"Tora";
    aInfo->version = RED4EXT_V1_SEMVER(0, 3, 0);
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_INDEPENDENT;
    // Reported as SDK 0.5.0 (the SDK's own compatibility macro): older RED4ext releases, such as the ones for game
    // 2.31, do not know SDK 1.0.0. This plugin uses nothing beyond the logger.
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_1_0_0_COMPAT_0_5_0;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
