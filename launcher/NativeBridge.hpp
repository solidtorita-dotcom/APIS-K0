// The native bridge: Apiko's bridge inside the game process, replacing Apiko.exe (plugin plan in DISENO.md).
// Phase 1 (skeleton): the file protocol of the Python bridge (GameFiles), on its own thread so the game thread never
// waits. It reads what the game sends and answers with placeholders: V's words are echoed, settings tests report
// "not implemented yet". Turned on by a file named native.on in the mod's bridge folder (then Apiko.exe is not
// started).
#pragma once

#include <filesystem>

namespace apiko::native
{
// Starts the bridge thread. aModDir: the ApisK0 CET mod folder. aDataDir: %LOCALAPPDATA%\Apiko\data.
void Start(const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir);
// Stops the thread and waits for it.
void Stop();
} // namespace apiko::native
