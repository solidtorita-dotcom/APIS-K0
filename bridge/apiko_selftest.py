"""Apiko.exe --selftest: checks the local voice engines without the game, for players and for packaged builds.

Piper says a line (played on the speakers), local Whisper transcribes it back, Kokoro says it too. Models missing
on disk are downloaded first, as in play. Returns the number of failed checks.
"""

import threading
import time
import traceback

import numpy as np

LINE = {"es": "Hola, V. Soy Apiko. Prueba de voz.", "en": "Hi, V. I'm Apiko. Voice test."}


def run(config, settings, log):
    import apiko_voice
    import sounddevice as sd

    failed = 0

    def check(name, step):
        nonlocal failed
        t = time.time()
        try:
            result = step()
            log(f"OK   {name} ({time.time() - t:.1f}s){': ' + result if result else ''}")
        except Exception as e:
            failed += 1
            log(f"FAIL {name}: {e!r}")
            log(traceback.format_exc().rstrip())

    lang = settings.catalog["languages"][0]
    text = LINE.get(lang, LINE["en"])
    voice = apiko_voice.Voice.__new__(apiko_voice.Voice)  # no player thread or warm-up: only the engines
    voice.config, voice.settings, voice.log = config, settings, log
    voice.lock, voice.piper_voices, voice.kokoro = threading.Lock(), {}, None
    said = {}

    def piper():
        said["audio"] = voice.local("piper", text, lang)
        return f"{len(said['audio']) / apiko_voice.RATE:.1f}s of speech"

    def play():
        audio = voice.machine(said["audio"], "piper")
        sd.play(audio * config.get("voice_volume", 0.8), apiko_voice.RATE, device=config.get("output_device"))
        sd.wait()
        return "you should have heard Apiko"

    def whisper():
        ears = apiko_voice.Ears.__new__(apiko_voice.Ears)
        ears.config, ears.settings, ears.log = config, settings, log
        ears.loading, ears.model, ears.model_name = threading.Lock(), None, None
        speech = said["audio"]
        count = int(len(speech) * apiko_voice.MIC_RATE / apiko_voice.RATE)
        audio = np.interp(np.linspace(0, len(speech) - 1, count), np.arange(len(speech)), speech)
        heard, heard_lang = ears.transcribe_local(audio.astype(np.float32))
        return f"{heard_lang}: {heard!r}"

    def kokoro():
        audio = voice.local("kokoro", text, lang)
        return f"{len(audio) / apiko_voice.RATE:.1f}s of speech"

    def microphone():
        devices = sd.query_devices()
        default_in = sd.default.device[0]
        return f"input: {devices[default_in]['name'] if default_in >= 0 else 'none'}"

    check("Piper voice", piper)
    if "audio" in said:
        check("speakers", play)
        check("local Whisper", whisper)
    check("Kokoro voice", kokoro)
    check("microphone", microphone)
    log("self-test passed" if not failed else f"self-test: {failed} check(s) failed")
    return failed
