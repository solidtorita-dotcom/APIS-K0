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
| Bridge | `bridge/*.py` (Python), shipped as `Apiko.exe` | Speech recognition, the reply model, memory, lore, voice (TTS and effects), 3D audio |
| Launcher | `launcher/ApisK0Launcher.cpp` (RED4ext plugin) | Starts and stops the bridge with the game |

The game and the bridge talk through files in the CET mod folder (`to_bridge.jsonl`, `from_bridge.txt`).
Player data (settings with API keys, memory) lives in the player's game folder and `%LOCALAPPDATA%\Apiko`, never in
this repository.

## Building

Requirements (Windows):
- Python 3.14
- Visual Studio 2022 Build Tools with the C++ workload (for the launcher)
- [WolvenKit](https://github.com/WolvenKit/WolvenKit) CLI 8.x (for the archive)
- PowerShell 5.1 or later

Steps, from the repository root:

```bat
:: 1. Launcher (RED4ext plugin)
git clone --depth 1 https://github.com/WopsS/RED4ext.SDK.git launcher\deps\RED4ext.SDK
launcher\build.bat

:: 2. Bridge environment
python -m venv bridge\.venv
bridge\.venv\Scripts\python.exe -m pip install -r bridge\requirements.txt pyinstaller

:: 3. Build: bridge (PyInstaller), archive (WolvenKit) and the release zip in dist\
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Bridge -WolvenKit "C:\path\to\WolvenKit.CLI.exe"
```

`tools\build.ps1 -Install -Release -Game "C:\path\to\Cyberpunk 2077"` also installs the release into the game.
Without `-Release`, the development tools (`dev.lua`: debug hotkeys, debug log) are installed too; they are never in
the zip.

`tools/vanilla/*.ent.json` are vanilla game entities serialized with WolvenKit, used as the base for the mod's own
copies (van, bodies, case).

## License

GPL-3.0 (see `LICENSE`). Apiko's knowledge of Night City (`bridge/lore.json`) is based on the
[Cyberpunk Wiki](https://cyberpunk.fandom.com) (Fandom), licensed under CC BY-SA 3.0, rewritten as street knowledge.
Cyberpunk 2077 is a trademark of CD PROJEKT S.A.; this is an unofficial fan mod.
