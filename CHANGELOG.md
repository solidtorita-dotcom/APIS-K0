# Changelog

## 0.3.1
- Fix: Apiko's drone could turn hostile during some quests, for example a modded Lucy romance quest. Quests can change which groups are friendly to each other, and the drone was only friendly through its group. Now the drone and V are kept friendly to each other directly, so no quest can turn the drone against you.

## 0.3.0
- Faces: hand-drawn faces on the drone's screen. Apiko puts one up the moment you speak, another for its answer, then goes back to its resting face.
- New mission, "Echo": leave the Badlands with Apiko and it picks up something NetWatch took from it. It insists on getting it back.
- Ping: once Echo is done, Apiko pings when you ask, when it decides it needs to, or when you walk into a hostile area blind. It marks the enemies around you. One per minute.
- Enemies: Apiko now knows exactly the enemies the game marks for you (seen, tagged or pinged). No more talking about enemies you never saw.
- Ambient talk: Apiko hears what people say around you and can tell you about it when you ask. It no longer makes up conversations it did not hear.
- Less repetition: Apiko stops bringing up its limiter and its past every time it does not know something.
- Built with the latest RED4ext SDK: should work with game version 2.31 (untested).

## 0.2.0
- No more Apiko.exe: everything runs inside the game in the RED4ext plugin. No separate window, nothing for antivirus programs to flag, a much smaller download.
- Local options rebuilt into the plugin: Piper voice and Whisper speech recognition on your PC. Both also step in when a cloud service fails, so Apiko is never left mute or deaf.
- A camera or turret that spots you now gets an urgent warning.
- Apiko comments on events a bit more often (shorter pause between remarks).
- The Kokoro voice is gone (Piper replaces it).

## 0.1.0
- First alpha release.
