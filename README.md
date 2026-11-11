# Apiko - AI Drone Companion

A Cyberpunk 2077 mod: a rogue AI fragment in a small Zetatech Bombus drone that follows V, perceives the game world,
remembers what you live together and talks back with its own voice, powered by the AI providers the player chooses.

Nexus Mods page: https://www.nexusmods.com/cyberpunk2077/mods/37881

## How it works

| Part | Where | What it does |
|---|---|---|
| Game scripts | `src/r6/scripts/ApisK0/*.reds` (redscript) | Spawns the drone, follows V, perceives the world (combat, police, devices, the enemies the game marks, people, quests), the find quest, the "Echo" quest and Apiko's ping, the faces on the drone's screen |
| Tweaks | `src/r6/tweaks/ApisK0/*.yaml` (TweakXL) | The drone's record, the quests' items and scan records |
| CET mod | `src/bin/x64/plugins/cyber_engine_tweaks/mods/ApisK0/` (Lua) | Push-to-talk, chat window, settings window, the file link with the bridge |
| World | `tools/make_world.py` → `ApisK0.archive` (ArchiveXL) | The find site (case, van, bodies), the Echo site's props, journal entries, the drone's own entity with its screen and faces |
| Faces | `caras/*.png` | Apiko's faces (128×128), imported as textures by `tools/build.ps1` |
| Bridge | `launcher/*.cpp` (RED4ext plugin, C++) | Runs inside the game: speech recognition, the reply model, memory, perception, lore, written lines, voice (TTS, machine-voice effects, simulated 3D audio), local options (Piper, whisper.cpp, Ollama) |
| Data | `bridge/prompt.md`, `barks.json`, `lore.json`, `first_contact.json`, `beacon_*.wav` | Apiko's prompt, written lines, public lore, the find's script, the beacon's recording |
| Python bridge | `bridge/*.py` | The 0.1.0 bridge (shipped then as `Apiko.exe`), kept as a reference and development tool; not in the release |

The game and the bridge talk through files in the CET mod folder (`to_bridge.jsonl`, `from_bridge.txt`).
Player data (settings with API keys, memory) lives in the player's game folder and `%LOCALAPPDATA%\Apiko`, never in
this repository.

## License

GPL-3.0 (see `LICENSE`). Apiko's knowledge of Night City (`bridge/lore.json`) is based on the
[Cyberpunk Wiki](https://cyberpunk.fandom.com) (Fandom), licensed under CC BY-SA 3.0, rewritten as street knowledge.
Cyberpunk 2077 is a trademark of CD PROJEKT S.A.; this is an unofficial fan mod.
