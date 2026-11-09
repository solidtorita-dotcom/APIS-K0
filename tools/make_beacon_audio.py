"""Renders NetWatch's recorded recovery message for the beacon's call (the find) into bridge\\beacon_<lang>.wav.

The beacon's voice is not Apiko's and is the same for every player, so it ships as audio in the mod instead of a
per-provider voice option. Voice picked by the user by ear on 2026-11-08: Azure en-US-BrianMultilingualNeural (sample
"E"), as a flat machine voice through a phone line, cut off mid-word at the end (Apiko takes the line over).
Needs the player's Azure key in the installed mod's settings.json. The texts are also in bridge\\first_contact.json
("beacon_netwatch", the subtitles): keep both the same.

Usage (bridge venv): .venv\\Scripts\\python.exe ..\\tools\\make_beacon_audio.py   (from Apis-K0\\bridge)
"""
import json
import sys
import wave
from pathlib import Path

import numpy as np

BRIDGE = Path(__file__).resolve().parent.parent / "bridge"
sys.path.insert(0, str(BRIDGE))
import apiko_dsp  # noqa: E402
from apiko_voice import resample, tts_azure  # noqa: E402
from pedalboard import Bitcrush, Distortion, HighpassFilter, LowpassFilter, Pedalboard  # noqa: E402

RATE = 24000
SETTINGS = Path(r"C:\Steam\steamapps\common\Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0\settings.json")
VOICE = "en-US-BrianMultilingualNeural"

# Said sentence by sentence (a pause between them); the last one is cut short by CUT seconds of its end.
LINES = {
    "es": ["Baliza de recuperación.", "Activo comprometido.", "Escolta: sin respuesta.",
           "Transmitiendo coordenadas a la unidad más cercana."],
    "en": ["Recovery beacon.", "Asset compromised.", "Escort: no response.",
           "Transmitting coordinates to the nearest unit."],
}
CUT = {"es": 0.30, "en": 0.22}

PHONE = Pedalboard([HighpassFilter(450), LowpassFilter(3000), Distortion(drive_db=6), Bitcrush(bit_depth=9)])


def speech_end(x):
    window = RATE // 100
    env = np.convolve(np.abs(x), np.ones(window) / window, mode="same")
    loud = np.nonzero(env > 0.02 * env.max())[0]
    return loud[-1] if len(loud) else len(x)


def render(choice, lang):
    out = []
    for i, line in enumerate(LINES[lang]):
        raw, rate = tts_azure(choice, line, lang, VOICE, 1.0, 20)
        x = resample(raw, rate).astype(np.float64)
        end = speech_end(x)
        last = i == len(LINES[lang]) - 1
        x = x[: end - int(RATE * CUT[lang])] if last else x[: end + int(RATE * 0.05)]
        out.append(apiko_dsp.machine_voice(x, RATE, keep=0.0, semitones=0.0, octave_mix=0.0))
        if not last:
            out.append(np.zeros(int(RATE * 0.25)))
    x = np.concatenate(out).astype(np.float32)
    x = PHONE(x[np.newaxis, :], RATE)[0]
    # Line hiss under the voice, and the line dropping at the end (a burst of static, then nothing).
    x = x + np.random.uniform(-1, 1, len(x)).astype(np.float32) * 0.01
    burst = np.random.uniform(-1, 1, int(RATE * 0.12)).astype(np.float32) * 0.25
    x = np.concatenate([x, burst, np.zeros(int(RATE * 0.3), dtype=np.float32)])
    return x / max(1e-6, float(np.abs(x).max()))


def save(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


def main():
    settings = json.loads(SETTINGS.read_text(encoding="utf-8"))
    choice = {"base_url": settings["tts"]["urls"]["azure"], "key": settings["keys"]["azure"]}
    for lang in LINES:
        x = render(choice, lang)
        path = BRIDGE / f"beacon_{lang}.wav"
        save(path, x)
        print(f"{path.name}: {len(x) / RATE:.1f} s")


if __name__ == "__main__":
    main()
