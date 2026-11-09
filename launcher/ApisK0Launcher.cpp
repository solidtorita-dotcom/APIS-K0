// ApisK0 Launcher: a RED4ext plugin that starts the Apiko bridge (Apiko.exe) when the game starts and stops it
// when the game closes, so players never have to open it themselves.
//
// The bridge ships inside the CET mod: <game>\bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0\bridge\Apiko.exe.
// It runs in its own console window, started minimized and without focus (the log stays one click away). It is put
// in a job object that kills it when the job's last handle closes: on unload, on a normal exit, and on a crash.
// A file named autostart.off next to Apiko.exe turns this off (for running the bridge by hand).
// Uses RED4ext only as a loader (no game types), so it does not depend on the game version.

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
#include <string>

namespace
{
HANDLE bridgeJob = nullptr;

std::filesystem::path BridgeDir()
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
    // The game exe is in <game>\bin\x64.
    return std::filesystem::path(exe).parent_path() / L"plugins" / L"cyber_engine_tweaks" / L"mods" / L"ApisK0" /
           L"bridge";
}

void StartBridge(RED4ext::v1::PluginHandle aHandle, const RED4ext::v1::Sdk* aSdk)
{
    auto dir = BridgeDir();
    auto exe = dir / L"Apiko.exe";
    std::error_code error;
    if (!std::filesystem::exists(exe, error))
    {
        aSdk->logger->WarnWF(aHandle, L"Apiko.exe not found at '%s': the bridge was not started.", exe.c_str());
        return;
    }
    if (std::filesystem::exists(dir / L"autostart.off", error))
    {
        aSdk->logger->Info(aHandle, "autostart.off found: the bridge was not started.");
        return;
    }

    bridgeJob = CreateJobObjectW(nullptr, nullptr);
    if (bridgeJob)
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(bridgeJob, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    }

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_SHOWMINNOACTIVE;
    PROCESS_INFORMATION process{};
    std::wstring commandLine = L"\"" + exe.wstring() + L"\"";
    // Suspended until it is in the job, so it cannot outlive the game even if the game dies right away.
    if (!CreateProcessW(exe.c_str(), commandLine.data(), nullptr, nullptr, FALSE,
                        CREATE_NEW_CONSOLE | CREATE_SUSPENDED, nullptr, dir.c_str(), &startup, &process))
    {
        aSdk->logger->ErrorF(aHandle, "Could not start Apiko.exe (Windows error %lu).", GetLastError());
        return;
    }
    if (!bridgeJob || !AssignProcessToJobObject(bridgeJob, process.hProcess))
    {
        aSdk->logger->WarnF(aHandle, "Apiko.exe is not tied to the game (error %lu): close it by hand after playing.",
                            GetLastError());
    }
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    aSdk->logger->InfoF(aHandle, "Apiko bridge started (pid %lu).", process.dwProcessId);
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
        if (bridgeJob)
        {
            CloseHandle(bridgeJob); // kills the bridge
            bridgeJob = nullptr;
        }
        break;
    }
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"ApisK0 Launcher";
    aInfo->author = L"Tora";
    aInfo->version = RED4EXT_V1_SEMVER(0, 1, 0);
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_INDEPENDENT;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
