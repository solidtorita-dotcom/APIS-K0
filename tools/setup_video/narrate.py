"""Renders Apiko's narration for the setup video: one WAV per scene in build\\setup_video, with Apiko's real voice
pipeline (the voice chosen in the installed mod's settings.json, its machine style and effects; cached like the
written lines in game). Needs a cloud voice with its key in settings.json (strict: no Piper fallback).

Usage (bridge venv, from Apis-K0):  bridge\\.venv\\Scripts\\python.exe tools\\setup_video\\narrate.py
"""
import json
import sys
import threading
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "bridge"))
sys.path.insert(0, str(HERE))
import apiko_providers  # noqa: E402
import apiko_voice  # noqa: E402
from scenes import SCENES  # noqa: E402

MOD_DIR = Path(r"C:\Steam\steamapps\common\Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0")
OUT = ROOT / "build" / "setup_video"
INSTABILITY = 0.2  # config.example.json base_instability: calm, no glitches


def voice():
    """apiko_voice.Voice without its speaker and player (nothing is played here)."""
    config = json.loads((ROOT / "bridge" / "config.example.json").read_text(encoding="utf-8"))
    v = apiko_voice.Voice.__new__(apiko_voice.Voice)
    v.config, v.log = config, print
    v.settings = apiko_providers.Settings(MOD_DIR, config, print)
    v.lock = threading.Lock()
    v.piper_voices, v.kokoro, v.last_failure, v.rate = {}, None, None, apiko_voice.RATE
    return v


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    v = voice()
    print(f"voice: {v.settings.choice('tts')['label']}")
    durations = []
    for i, scene in enumerate(SCENES):
        audio, rate = v.render(scene["say"], "en", INSTABILITY, strict=True, cache=True)
        with wave.open(str(OUT / f"scene_{i:02d}.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
        durations.append(len(audio) / rate)
        print(f"scene {i:02d}: {durations[-1]:.1f} s")
    (OUT / "durations.json").write_text(json.dumps({"rate": apiko_voice.RATE, "seconds": durations}), encoding="utf-8")
    print(f"total narration: {sum(durations):.1f} s")


if __name__ == "__main__":
    main()
