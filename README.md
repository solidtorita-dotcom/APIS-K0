# Apiko - AI Drone Companion

A Cyberpunk 2077 mod: a rogue AI fragment in a small Zetatech Bombus drone that follows V, perceives the game world,
remembers what you live together and talks back with its own voice, powered by the AI providers the player chooses.

Nexus Mods page: https://www.nexusmods.com/cyberpunk2077/mods/ (link pending)

## How it works

| Part | Where | What it does |
|---|---|---|
| Game scripts | `src/r6/scripts/ApisK0/*.reds` (redscript) | Spawns the drone, follows V, perceives the world (combat, police, devices, enemies, people, quests), the find quest |
| Tweaks | `src/r6/tweaks/ApisK0/*.yaml` (TweakXL) | The drone's record, the find quest's records |
| CET mod | `src/bin/x64/plugins/cyber_engine_tweaks/mods/ApisK0/` (Lua) | Push-to-talk, chat window, settings window, the file link with the bridge |
| World | `tools/make_world.py` → `ApisK0.archive` (ArchiveXL) | The find site: the case, the van, the bodies, journal entries |
| Bridge | `launcher/*.cpp` (RED4ext plugin, C++) | Runs inside the game: speech recognition, the reply model, memory, perception, lore, written lines, voice (TTS, machine-voice effects, simulated 3D audio), local options (Piper, whisper.cpp, Ollama) |
| Data | `bridge/prompt.md`, `barks.json`, `lore.json`, `first_contact.json`, `beacon_*.wav` | Apiko's prompt, written lines, public lore, the find's script, the beacon's recording |
| Python bridge | `bridge/*.py` | The 0.1.0 bridge (shipped then as `Apiko.exe`), kept as a reference and development tool; not in the release |

The game and the bridge talk through files in the CET mod folder (`to_bridge.jsonl`, `from_bridge.txt`).
Player data (settings with API keys, memory) lives in the player's game folder and `%LOCALAPPDATA%\Apiko`, never in
this repository.

## Building

Requirements (Windows):
- Visual Studio 2022 (or later) Build Tools with the C++ workload and its CMake and Ninja (for the plugin)
- Git and curl
- Python 3.14 (only for `tools/make_world.py`, which writes the archive's JSON)
- [WolvenKit](https://github.com/WolvenKit/WolvenKit) CLI 8.x (for the archive)
- PowerShell 5.1 or later

Steps, from the repository root:

```bat
:: 1. Third-party sources into launcher\deps (not in this repository)
git clone --depth 1 https://github.com/WopsS/RED4ext.SDK.git launcher\deps\RED4ext.SDK
mkdir launcher\deps\nlohmann launcher\deps\miniaudio
curl -L -o launcher\deps\nlohmann\json.hpp https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp
curl -L -o launcher\deps\miniaudio\miniaudio.h https://raw.githubusercontent.com/mackron/miniaudio/0.11.21/miniaudio.h
git clone https://github.com/espeak-ng/espeak-ng.git launcher\deps\espeak-ng
git -C launcher\deps\espeak-ng checkout 6b96deb
git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git launcher\deps\whisper.cpp
:: onnxruntime: extract https://github.com/microsoft/onnxruntime/releases/download/v1.20.1/onnxruntime-win-x64-1.20.1.zip
:: and rename its folder to launcher\deps\onnxruntime

:: 2. espeak-ng (with its data) and whisper.cpp as static libraries, then the plugin
launcher\build_deps.bat
launcher\build.bat

:: 3. Python environment for make_world.py
python -m venv bridge\.venv
bridge\.venv\Scripts\python.exe -m pip install -r bridge\requirements.txt

:: 4. Archive (WolvenKit) and the release zip in dist\
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -WolvenKit "C:\path\to\WolvenKit.CLI.exe"
```

Test programs (the bridge outside the game, the voice effects, speech recognition, Piper): `launcher\tests\`,
built with `launcher\tests\build_harness.bat`.

`tools\build.ps1 -Install -Release -Game "C:\path\to\Cyberpunk 2077"` also installs the release into the game.
Without `-Release`, the development tools (`dev.lua`: debug hotkeys, debug log) are installed too; they are never in
the zip.

`tools/vanilla/*.ent.json` are vanilla game entities serialized with WolvenKit, used as the base for the mod's own
copies (van, bodies, case).

## License

GPL-3.0 (see `LICENSE`). Apiko's knowledge of Night City (`bridge/lore.json`) is based on the
[Cyberpunk Wiki](https://cyberpunk.fandom.com) (Fandom), licensed under CC BY-SA 3.0, rewritten as street knowledge.
Cyberpunk 2077 is a trademark of CD PROJEKT S.A.; this is an unofficial fan mod.
