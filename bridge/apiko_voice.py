"""APIS-K0 phase 3: Apiko's voice (TTS + robot effect) and ears (microphone + speech recognition).

Used by apiko_bridge.py. Which services render the voice and recognise speech is the player's choice in the
in-game APIKO Settings window (apiko_providers.Settings); the voice itself is fixed per provider in providers.json.
- Voice: Piper or Kokoro (local, model files in models\\), or Cartesia / ElevenLabs / Groq Orpheus / OpenAI TTS.
  A cloud voice that fails (no credits, no connection) falls back to Piper so Apiko never goes mute; Orpheus only
  speaks English, other languages use Piper. Missing Piper voices are downloaded on first use.
- Ears: Groq or OpenAI Whisper API (fast; the clip is sent to them), or faster-whisper on the CPU, which is also
  the fallback when the API fails. The local Whisper model is downloaded to models\\whisper on first use.
Replies are rendered sentence by sentence and played by a background thread, so Apiko starts talking as soon as
the first sentence is ready. Audio plays on the PC's default output device, outside the game's audio engine,
panned and attenuated from the drone's position (simulated 3D).
"""

import hashlib
import io
import json
import queue
import random
import re
import threading
import time
import urllib.request
import wave
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel
from kokoro_onnx import Kokoro
from pedalboard import Bitcrush, Chorus, Distortion, HighpassFilter, LowpassFilter, Pedalboard, PitchShift

import apiko_dsp
import apiko_paths
from apiko_providers import ProviderError, missing, recommended_model, request, transcribe

MODELS = apiko_paths.MODELS_DIR
# Kokoro's model and voices, downloaded on first use (about 340 MB).
KOKORO_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"
KOKORO_FILES = ("kokoro-v1.0.onnx", "voices-v1.0.bin")
# Written lines (barks.json) are rendered once per voice and kept here (machine voice applied, glitches not).
SPEECH_CACHE = apiko_paths.DATA_DIR / "speech_cache"
MIC_RATE = 16000  # what Whisper expects
RATE = 24000  # every voice is resampled to this before effects and playback
# A phone line's band (the beacon's call), as in tools\make_beacon_audio.py.
PHONE_LINE = Pedalboard([HighpassFilter(cutoff_frequency_hz=450), LowpassFilter(cutoff_frequency_hz=3000)])
POSE_FILE = "audio_pose.txt"
MIN_SPEECH_SECONDS = 0.35
MIN_VOICED_SECONDS = 0.1  # less voiced sound than this: not sent to speech recognition (silence and noise give 0)
WHISPER_HALLUCINATION = re.compile(
    r"amara\.org|subt[ií]tulos (realizados|por)|thanks? (you )?for watching|gracias por ver|suscr[ií]bete|"
    r"subscribe to|like and subscribe", re.IGNORECASE)
# Ways Whisper writes "Apiko" despite the hint ("Debería comprármelo a pico."): fixed before the model reads them.
APIKO_MISHEARD = re.compile(r"\b(?:a[\s-]?pi[ck]o|ap[ií]c[oó]|ab[ií]k[oó]|ap[ií]k[oó]|happy ?ko|apiku)\b",
                            re.IGNORECASE)
LOCAL_ENGINES = ("piper", "kokoro")
DEFAULT_PITCH = 2.5  # semitones up for effects() when called on its own (the machine style sets the pitch)

# Glitch tokens the model writes into the text. They are not read aloud: each one becomes an audio glitch.
GLITCH_TOKEN = re.compile(r"(0x[0-9A-Fa-f]+|\bNULL\b|//+|\b[01]{4,}\b|[▓░▒█■□]+|<[^>]{0,20}>|\[[^\]]{0,20}\])")
SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")
MIN_SENTENCE_CHARS = 12  # shorter sentences are joined to the next one (each chunk opens a new audio stream)
# A sentence that is only an interjection ("Oh.", "Hmm...") opens the next one instead of closing the one before.
INTERJECTION = re.compile(r"^(oh+|ah+|eh|uh+|um+|hm+|mm+|huh|aha|ajá|ahá|vaya)[.!?…]*$", re.IGNORECASE)
# A long first sentence is cut at its first comma (or ; : —) so the first sound comes sooner.
FIRST_CHUNK_MAX = 50
FIRST_CHUNK_CUT = re.compile(r"(?<=[,;:—])\s+")


def download(url, path, log):
    """Path of a model file, downloaded first when missing (to a .part file, so a cut download is not kept)."""
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    log(f"downloading {path.name} (first use, only once)...")
    with urllib.request.urlopen(url, timeout=60) as response, open(part, "wb") as f:
        total = int(response.headers.get("Content-Length") or 0)
        done, shown = 0, 0
        while chunk := response.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            if total and done * 10 // total > shown:
                shown = done * 10 // total
                log(f"  {path.name}: {shown * 10}%")
    part.replace(path)
    return path


def split_sentences(text):
    """Sentences for the voice and the subtitles. A short one ("Useful.", "NULL.") stays with the sentence before:
    joined to the next one, the punchline showed in front of the following line. An interjection ("Oh.") goes with
    the next one wherever it is (it reacts to what follows), as does a short first one, having nothing before it."""
    chunks = []
    lead = ""  # interjections waiting for the sentence they open
    for piece in SENTENCE_END.split(text.strip()):
        if not piece:
            continue
        if INTERJECTION.match(piece):
            lead = f"{lead} {piece}".strip()
            continue
        if lead:
            piece, lead = f"{lead} {piece}", ""
        if chunks and (len(piece) < MIN_SENTENCE_CHARS or len(chunks[-1]) < MIN_SENTENCE_CHARS):
            chunks[-1] += " " + piece
        else:
            chunks.append(piece)
    if lead:  # an interjection at the very end: nothing after it to open
        if chunks:
            chunks[-1] += " " + lead
        else:
            chunks.append(lead)
    if len(chunks) > 1 and len(chunks[-1]) < MIN_SENTENCE_CHARS:
        last = chunks.pop()
        chunks[-1] += " " + last
    if chunks and len(chunks[0]) > FIRST_CHUNK_MAX:
        for cut in FIRST_CHUNK_CUT.finditer(chunks[0]):
            if cut.start() >= MIN_SENTENCE_CHARS and len(chunks[0]) - cut.end() >= MIN_SENTENCE_CHARS:
                chunks[0:1] = [chunks[0][:cut.start()], chunks[0][cut.end():]]
                break
    return chunks


def resample(samples, rate):
    samples = np.asarray(samples, dtype=np.float32)
    if rate == RATE or len(samples) == 0:
        return samples
    return np.interp(np.arange(0, len(samples), rate / RATE), np.arange(len(samples)), samples).astype(np.float32)


def voiced_seconds(audio):
    """How much of a microphone clip has a pitch (actual voice, not silence, breath or noise)."""
    f0, hop = apiko_dsp.pitch_track(np.asarray(audio, dtype=np.float64), MIC_RATE)
    return float(np.count_nonzero(f0 > 0)) * hop / MIC_RATE


def pcm16(raw):
    return np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0


def to_wav(samples, rate):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes((np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


# ----------------------------------------------------------------------------------------------------------
# Cloud voices: (choice, text, lang, voice, speed, timeout) -> (samples float32, rate)


def json_headers(extra):
    return {"Content-Type": "application/json", **extra}


def tts_cartesia(choice, text, lang, voice, speed, timeout):
    body = {"model_id": choice["model"], "transcript": text, "voice": {"id": voice}, "language": lang,
            "output_format": {"container": "raw", "encoding": "pcm_s16le", "sample_rate": RATE},
            "generation_config": {"speed": max(0.6, min(1.5, speed))}}
    if choice["entry"].get("emotion"):
        body["generation_config"]["emotion"] = choice["entry"]["emotion"]  # "neutral": flatter delivery
    headers = json_headers({"Authorization": "Bearer " + choice["key"], "X-API-Key": choice["key"],
                            "Cartesia-Version": "2026-08-14"})
    return pcm16(request(choice["base_url"] + "/tts/bytes", json.dumps(body).encode(), headers, timeout)), RATE


def tts_elevenlabs(choice, text, lang, voice, speed, timeout):
    url = f"{choice['base_url']}/v1/text-to-speech/{voice}?output_format=pcm_{RATE}"
    headers = json_headers({"xi-api-key": choice["key"]})
    body = {"text": text, "model_id": choice["model"], "language_code": lang, "voice_settings": {"speed": speed}}
    try:
        raw = request(url, json.dumps(body).encode(), headers, timeout)
    except ProviderError as e:
        if e.status != 400:
            raise
        raw = request(url, json.dumps({"text": text, "model_id": choice["model"]}).encode(), headers, timeout)
    return pcm16(raw), RATE


def tts_groq(choice, text, lang, voice, speed, timeout):
    body = {"model": choice["model"], "input": text, "voice": voice, "response_format": "wav"}
    headers = json_headers({"Authorization": "Bearer " + choice["key"]})
    raw = request(choice["base_url"] + "/audio/speech", json.dumps(body).encode(), headers, timeout)
    try:
        with wave.open(io.BytesIO(raw)) as wav:
            rate, channels = wav.getframerate(), wav.getnchannels()
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError):
        rate, channels, frames = 24000, 1, raw[44:]  # streamed WAV with a placeholder header
    samples = pcm16(frames)
    if channels > 1:
        samples = samples[: len(samples) // channels * channels].reshape(-1, channels).mean(axis=1)
    return samples, rate


def tts_openai(choice, text, lang, voice, speed, timeout):
    body = {"model": choice["model"], "input": text, "voice": voice, "response_format": "pcm", "speed": speed}
    if choice["model"].startswith("gpt-4o"):
        body["instructions"] = "The light, curious, slightly synthetic voice of a small AI drone."
    headers = json_headers({"Authorization": "Bearer " + choice["key"]})
    return pcm16(request(choice["base_url"] + "/audio/speech", json.dumps(body).encode(), headers, timeout)), 24000


AZURE_LOCALES = {"es": "es-ES", "en": "en-US", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR",
                 "pl": "pl-PL", "ru": "ru-RU", "ja": "ja-JP", "zh": "zh-CN"}


def tts_azure(choice, text, lang, voice, speed, timeout):
    """Azure Speech REST: SSML in, raw 24 kHz PCM out. `base_url` is the resource's region ("westeurope") or a
    full endpoint URL."""
    region = choice["base_url"].strip().strip("/")
    url = region if "://" in region else f"https://{region}.tts.speech.microsoft.com"
    if not url.endswith("/cognitiveservices/v1"):
        url += "/cognitiveservices/v1"
    locale = voice.rsplit("-", 1)[0] if voice.count("-") >= 2 else lang
    rate = f"{(max(0.5, min(2.0, speed)) - 1.0) * 100:+.0f}%"
    body = f"<prosody rate='{rate}'>{xml_escape(text)}</prosody>"
    # A multilingual voice speaks V's language with its own timbre: say which, instead of letting it guess.
    if "Multilingual" in voice and not locale.lower().startswith(lang.lower()):
        body = f"<lang xml:lang='{AZURE_LOCALES.get(lang, lang)}'>{body}</lang>"
    ssml = f"<speak version='1.0' xml:lang='{locale}'><voice name='{voice}'>{body}</voice></speak>"
    headers = {"Ocp-Apim-Subscription-Key": choice["key"], "Content-Type": "application/ssml+xml",
               "X-Microsoft-OutputFormat": "raw-24khz-16bit-mono-pcm", "User-Agent": "APIS-K0"}
    return pcm16(request(url, ssml.encode("utf-8"), headers, timeout)), 24000


CLOUD_TTS = {"cartesia": tts_cartesia, "elevenlabs": tts_elevenlabs, "groq": tts_groq, "openai": tts_openai,
             "azure": tts_azure}


class Voice:
    """Text to speech with Apiko's voice: the chosen engine, pitched up, light robot effect that worsens with
    instability."""

    def __init__(self, config, settings, log):
        self.config = config
        self.settings = settings
        self.log = log
        self.lock = threading.Lock()
        self.piper_voices = {}
        self.kokoro = None
        self.last_failure = None
        self.rate = RATE
        self.pose = Pose(settings.mod_dir / POSE_FILE) if config.get("voice_3d", True) else None
        self.speaker = Speaker(RATE, self.pose.gains if self.pose else (lambda: (1.0, 1.0)),
                               config.get("output_device"))
        self.playlist = queue.Queue()
        self.generation = 0  # bumped by each new reply; queued chunks of older replies are skipped
        threading.Thread(target=self.player, daemon=True).start()
        self.settings_changed()

    def settings_changed(self):
        threading.Thread(target=self.warm_up, daemon=True).start()

    def warm_up(self):
        """Loads the local engine (the chosen one, or Piper as the cloud fallback) and runs it once: the first
        synthesis is slower, better before Apiko has to talk."""
        engine = self.settings.choice("tts")["id"]
        engine = engine if engine in LOCAL_ENGINES else "piper"
        for lang in self.settings.catalog["languages"]:
            try:
                self.local(engine, "Hola.", lang)
            except Exception as e:
                self.log(f"voice warm-up failed ({engine}, {lang}): {e!r}")

    def language(self, lang):
        languages = self.settings.catalog["languages"]
        return lang if lang in languages else languages[0]

    def synthesize(self, text, lang, strict=False):
        """One piece of plain text to (samples at RATE, engine that rendered it).
        strict: raise instead of falling back to Piper (tests)."""
        choice = self.settings.choice("tts")
        engine = choice["id"]
        only = choice["entry"].get("only_langs")
        if engine in LOCAL_ENGINES:
            return self.local(engine, text, lang), engine
        if only and lang not in only:
            return self.local("piper", text, lang), "piper"
        try:
            problem = missing(choice)
            if problem:
                raise ProviderError(problem)
            speed = self.speed(engine)
            samples, rate = CLOUD_TTS[engine](choice, text, lang, self.settings.voice(engine, lang), speed,
                                              self.config["tts_timeout_seconds"])
            self.last_failure = None
            return resample(samples, rate), engine
        except ProviderError as e:
            if strict:
                raise
            if str(e) != self.last_failure:
                self.last_failure = str(e)
                self.log(f"{choice['label']} voice failed, using Piper: {e}")
            return self.local("piper", text, lang), "piper"

    def style(self, engine):
        """Machine-voice settings for an engine: the catalog's tts.style with the provider's own overrides."""
        tts = self.settings.catalog["tts"]
        return {**(tts.get("style") or {}), **(tts["providers"].get(engine, {}).get("style") or {})}

    def machine(self, samples, engine):
        style = self.style(engine)
        return apiko_dsp.machine_voice(
            samples, RATE, keep=style.get("keep", 0.0), semitones=style.get("semitones", 1.5),
            steps=style.get("steps", True), remove_breaths=style.get("remove_breaths", True),
            level_amount=style.get("level", 0.8), octave_mix=style.get("octave_mix", 0.15))

    def speed(self, engine):
        """Speaking rate: the provider's own in the catalog (part of Apiko's voice), else config.json's."""
        return self.settings.catalog["tts"]["providers"].get(engine, {}).get("speed", self.config["voice_speed"])

    def local(self, engine, text, lang):
        voice = self.settings.voice(engine, lang)
        speed = self.speed(engine)
        with self.lock:
            if engine == "kokoro":
                if self.kokoro is None:
                    files = [download(KOKORO_URL + name, MODELS / name, self.log) for name in KOKORO_FILES]
                    self.kokoro = Kokoro(str(files[0]), str(files[1]))
                kokoro_lang = {"e": "es", "a": "en-us", "b": "en-gb"}.get(voice[:1], "en-us")
                samples, rate = self.kokoro.create(text, voice=voice, lang=kokoro_lang, speed=speed)
                return resample(samples, rate)
            name, _, speaker = voice.partition("#")
            piper_voice = self.piper_voice(name)
            from piper import SynthesisConfig
            settings = SynthesisConfig(speaker_id=int(speaker) if speaker else None, length_scale=1.0 / speed)
            chunks = list(piper_voice.synthesize(text, syn_config=settings))
            if not chunks:
                return np.zeros(0, dtype=np.float32)
            return resample(np.concatenate([c.audio_float_array for c in chunks]), chunks[0].sample_rate)

    def piper_voice(self, name):
        if name not in self.piper_voices:
            folder = MODELS / "piper"
            path = folder / f"{name}.onnx"
            if not path.exists():
                self.log(f"downloading Piper voice {name}...")
                from piper.download_voices import download_voice
                folder.mkdir(parents=True, exist_ok=True)
                download_voice(name, folder)
            from piper import PiperVoice
            self.piper_voices[name] = PiperVoice.load(str(path))
        return self.piper_voices[name]

    def cached_speech(self, text, lang, strict):
        """synthesize() + machine() for a text that will be said again (a written line): kept on disk per provider,
        voice, style and speed, so a cloud voice is paid once. A fallback to Piper is not kept."""
        engine = self.settings.choice("tts")["id"]
        try:
            voice = self.settings.voice(engine, lang)
        except KeyError:
            voice = ""
        key = json.dumps([engine, voice, self.style(engine), self.speed(engine), lang, text], sort_keys=True)
        path = SPEECH_CACHE / (hashlib.sha1(key.encode("utf-8")).hexdigest() + ".npy")
        try:
            return np.load(path)
        except (OSError, ValueError):
            pass
        samples, used = self.synthesize(text, lang, strict)
        speech = self.machine(samples, used)
        if used == engine:
            try:
                SPEECH_CACHE.mkdir(parents=True, exist_ok=True)
                np.save(path, speech.astype(np.float32))
            except OSError:
                pass
        return speech

    def render(self, text, lang, instability, strict=False, cache=False, phone=False):
        """Returns (samples float32 mono, sample rate). cache: the text is a written line (see cached_speech).
        phone: heard through a phone line (the beacon's call)."""
        lang = self.language(lang)
        parts = []
        for piece in GLITCH_TOKEN.split(text):
            if not piece or not piece.strip():
                continue
            if GLITCH_TOKEN.fullmatch(piece):
                parts.append(("glitch", None))
                continue
            if not re.search(r"\w", piece):
                continue
            if cache:
                parts.append(("speech", self.cached_speech(piece.strip(), lang, strict)))
                continue
            samples, engine = self.synthesize(piece.strip(), lang, strict)
            # Speech only: glitch sounds are added afterwards and must not be flattened or gated.
            parts.append(("speech", self.machine(samples, engine)))
        audio = self.assemble(parts, RATE, instability)
        audio = self.effects(audio, RATE, instability, 0.0)  # pitch already set by machine()
        if phone:
            audio = PHONE_LINE(audio[np.newaxis, :], RATE)[0]
            audio = (audio / (float(np.max(np.abs(audio))) or 1.0) * self.config["voice_volume"]).astype(np.float32)
        return audio, RATE

    def assemble(self, parts, rate, instability):
        out = []
        previous = None
        for kind, samples in parts:
            if kind == "speech":
                samples = self.random_glitches(samples, rate, instability)
                out.append(samples)
                previous = samples
            else:
                out.append(self.glitch_sound(previous, rate, instability))
        if not out:
            return np.zeros(int(rate * 0.2), dtype=np.float32)
        return np.concatenate(out).astype(np.float32)

    def glitch_sound(self, previous, rate, instability):
        choice = random.random()
        if previous is not None and len(previous) > rate // 10 and choice < 0.4:
            # Stutter: the end of the last sound, repeated.
            chunk = previous[-int(rate * random.uniform(0.05, 0.09)):]
            return np.concatenate([chunk] * random.randint(2, 4))
        if choice < 0.75:
            return self.static(rate, random.uniform(0.08, 0.2 + 0.15 * instability))
        return np.zeros(int(rate * random.uniform(0.06, 0.15)), dtype=np.float32)

    def static(self, rate, seconds):
        n = int(rate * seconds)
        noise = np.random.uniform(-1, 1, n).astype(np.float32)
        # Crude band limit (moving average) and a fade so it doesn't click.
        noise = np.convolve(noise, np.ones(4) / 4, mode="same")
        envelope = np.minimum(1.0, np.minimum(np.arange(n), np.arange(n)[::-1]) / (rate * 0.01))
        return (noise * envelope * 0.18).astype(np.float32)

    def random_glitches(self, samples, rate, instability):
        """Dropouts and stutters inside the speech; none below 0.35 instability."""
        if instability < 0.35 or len(samples) < rate // 2:
            return samples
        samples = samples.copy()
        events = np.random.poisson((instability - 0.3) * 1.2 * len(samples) / rate)
        for _ in range(events):
            start = random.randint(0, len(samples) - rate // 5)
            length = int(rate * random.uniform(0.04, 0.12))
            if random.random() < 0.5:
                samples[start:start + length] = 0.0
            else:
                chunk = samples[start:start + length].copy()
                samples = np.concatenate([samples[:start + length], chunk, chunk, samples[start + length:]])
        return samples

    def effects(self, audio, rate, instability, pitch=DEFAULT_PITCH):
        board = Pedalboard([
            PitchShift(semitones=pitch),
            HighpassFilter(cutoff_frequency_hz=220),
            LowpassFilter(cutoff_frequency_hz=7500 - 3000 * instability),
            Chorus(rate_hz=0.9, depth=0.15, centre_delay_ms=6.0, feedback=0.1, mix=0.25),
            Bitcrush(bit_depth=max(6.0, 14.0 - 8.0 * instability)),
            Distortion(drive_db=1.0 + 12.0 * instability),
        ])
        out = board(audio[np.newaxis, :], rate)[0]
        # Ring modulation: the classic metallic robot timbre, mixed in more as Apiko destabilises.
        t = np.arange(len(out)) / rate
        mix = 0.1 + 0.35 * instability
        out = out * (1 - mix) + out * np.sin(2 * np.pi * 55.0 * t) * mix
        peak = float(np.max(np.abs(out))) or 1.0
        return (out / peak * self.config["voice_volume"]).astype(np.float32)

    def new_reply(self):
        """Cuts what Apiko is saying (also used to interrupt it) and returns the id for the next reply's chunks."""
        self.generation += 1
        self.speaker.cut()
        return self.generation

    def queue_chunk(self, generation, audio, rate, on_start):
        """Plays after the chunks already queued; on_start runs when it starts sounding (shows its subtitle)."""
        self.playlist.put((generation, audio, rate, on_start))

    def player(self):
        while True:
            generation, audio, rate, on_start = self.playlist.get()
            if generation != self.generation:
                continue
            try:
                if rate != self.rate:
                    audio = np.interp(np.arange(0, len(audio), rate / self.rate), np.arange(len(audio)),
                                      audio).astype(np.float32)
                on_start()
                self.speaker.play(audio)
            except Exception as e:
                print(f"playback failed: {e!r}", flush=True)


class Pose:
    """Where the drone is relative to the camera (audio_pose.txt, written by the CET side), as smoothed
    left/right gains: quieter with distance, panned to the side it is on, a bit quieter behind V."""

    REF_DISTANCE = 2.0  # full volume up to this many metres
    MIN_GAIN = 0.3
    BEHIND_GAIN = 0.8
    PAN_AMOUNT = 0.8  # never fully in one ear
    SMOOTHING = 0.5  # share of the way to the new target per update

    def __init__(self, path):
        self.path = path
        self.current = np.array([1.0, 1.0])
        threading.Thread(target=self.follow, daemon=True).start()

    def gains(self):
        return self.current

    def target(self):
        try:
            text = self.path.read_text(encoding="utf-8").split()
            distance, pan, front = (float(v) for v in text)
        except (OSError, ValueError):  # missing file, "car", "none", half-written: centred
            return np.array([1.0, 1.0])
        gain = 1.0 if distance <= self.REF_DISTANCE else max(self.MIN_GAIN, (self.REF_DISTANCE / distance) ** 0.9)
        if front < -0.3:
            gain *= self.BEHIND_GAIN
        angle = (max(-1.0, min(1.0, pan)) * self.PAN_AMOUNT + 1.0) * np.pi / 4
        left, right = np.cos(angle), np.sin(angle)
        # Loudest channel at "gain": no clipping when panned hard.
        return np.array([left, right]) / max(left, right) * gain

    def follow(self):
        while True:
            self.current = self.current + (self.target() - self.current) * self.SMOOTHING
            time.sleep(0.1)


class Speaker:
    """Stereo output stream playing one chunk at a time; gains are applied per block, so the voice follows the
    drone while it talks. cut() silences it at once (interruption)."""

    def __init__(self, rate, gains, device):
        self.gains_source = gains
        self.gains = np.array([1.0, 1.0], dtype=np.float32)
        self.lock = threading.Lock()
        self.current = None
        self.position = 0
        self.finished = threading.Event()
        self.stream = sd.OutputStream(samplerate=rate, channels=2, dtype="float32", device=device,
                                      blocksize=512, callback=self.callback)
        self.stream.start()

    def callback(self, out, frames, time_info, status):
        target = np.asarray(self.gains_source(), dtype=np.float32)
        # Ramp from the last gains to the new ones over the block: no clicks when they change.
        ramp = np.linspace(0.0, 1.0, frames, dtype=np.float32)[:, None]
        gains = self.gains + (target - self.gains) * ramp
        self.gains = target
        out.fill(0.0)
        with self.lock:
            if self.current is None:
                return
            mono = self.current[self.position:self.position + frames]
            self.position += len(mono)
            if self.position >= len(self.current):
                self.current = None
                self.finished.set()
        out[:len(mono)] = mono[:, None] * gains[:len(mono)]

    def play(self, audio):
        """Blocks until the chunk has played or was cut."""
        with self.lock:
            self.finished.clear()
            self.current = audio
            self.position = 0
        self.finished.wait()

    def cut(self):
        with self.lock:
            self.current = None
            self.finished.set()


class Ears:
    """Push-to-talk recording and speech recognition: the chosen API, or faster-whisper on the CPU."""

    def __init__(self, config, settings, log):
        self.config = config
        self.settings = settings
        self.log = log
        self.model = None
        self.model_name = None
        self.loading = threading.Lock()
        self.stream = None
        self.chunks = []
        self.lock = threading.Lock()
        self.last_failure = None
        self.settings_changed()

    def settings_changed(self):
        # The local model is only loaded up front when it is the main recogniser; as a fallback, when needed.
        if self.settings.choice("stt")["id"] == "local":
            threading.Thread(target=self.load_model, daemon=True).start()

    def local_model_name(self):
        choice = self.settings.choice("stt")
        if choice["id"] == "local":
            return choice["model"]
        return recommended_model(self.settings.catalog["stt"]["providers"]["local"])

    def load_model(self):
        name = self.local_model_name()
        with self.loading:
            if self.model is not None and self.model_name == name:
                return
            t = time.time()
            self.model = WhisperModel(name, device="cpu", compute_type="int8", download_root=str(MODELS / "whisper"))
            self.model_name = name
            self.log(f"Whisper '{name}' ready ({time.time() - t:.1f}s)")

    def start(self):
        with self.lock:
            if self.stream is not None:
                return
            self.chunks = []
            self.stream = sd.InputStream(samplerate=MIC_RATE, channels=1, dtype="float32",
                                         device=self.config.get("input_device"), callback=self.on_audio)
            self.stream.start()

    def on_audio(self, data, frames, time_info, status):
        self.chunks.append(data[:, 0].copy())

    def stop(self):
        """Returns the recorded audio, or None if nothing was being recorded."""
        with self.lock:
            if self.stream is None:
                return None
            self.stream.stop()
            self.stream.close()
            self.stream = None
            if not self.chunks:
                return None
            return np.concatenate(self.chunks)

    def transcribe(self, audio, strict=False):
        """Returns (text, language) or (None, None). strict: raise instead of falling back to local (tests)."""
        if audio is None or len(audio) < MIC_RATE * MIN_SPEECH_SECONDS:
            return None, None
        voiced = voiced_seconds(audio)
        if voiced < MIN_VOICED_SECONDS:
            # Whisper "hears" something in silence (often the hint words): do not even ask.
            self.log(f"no speech in the clip ({voiced:.2f}s voiced), ignored")
            return None, None
        choice = self.settings.choice("stt")
        text, language = None, None
        if choice["id"] != "local":
            try:
                text, language = self.transcribe_remote(choice, audio)
                self.last_failure = None
            except ProviderError as e:
                if strict:
                    raise
                if str(e) != self.last_failure:
                    self.last_failure = str(e)
                    self.log(f"{choice['label']} speech recognition failed, using local Whisper: {e}")
                text, language = self.transcribe_local(audio)
        else:
            text, language = self.transcribe_local(audio)
        if text and self.hallucinated(text):
            self.log(f"ignored a typical Whisper hallucination: {text!r}")
            return None, None
        if text:
            fixed = APIKO_MISHEARD.sub("Apiko", text)
            if fixed != text:
                self.log(f"name fixed: {text!r} -> {fixed!r}")
                text = fixed
        return text, language

    def hallucinated(self, text):
        """Phrases Whisper invents for near-silent clips: only the hint words, or subtitle/video boilerplate."""
        words = set(re.findall(r"\w+", text.lower()))
        hint = set(re.findall(r"\w+", self.config["whisper_hint"].lower()))
        if words and words <= hint:
            return True
        return bool(WHISPER_HALLUCINATION.search(text))

    @staticmethod
    def silence():
        """One second of silence: enough to check that a speech recognition API answers (settings test)."""
        return np.zeros(MIC_RATE, dtype=np.float32)

    def transcribe_remote(self, choice, audio):
        allowed = self.settings.catalog["languages"]
        wav = to_wav(audio, MIC_RATE)
        hint, timeout = self.config["whisper_hint"], self.config["stt_timeout_seconds"]
        text, language = transcribe(choice, wav, None, hint, timeout)
        if text and language not in allowed:
            # Short clips are sometimes misdetected: try again in the main language.
            text, language = transcribe(choice, wav, allowed[0], hint, timeout)
        return (text or None), language

    def transcribe_local(self, audio):
        self.load_model()
        allowed = self.settings.catalog["languages"]
        hint = self.config["whisper_hint"]
        segments, info = self.model.transcribe(audio, beam_size=1, vad_filter=True, initial_prompt=hint)
        language = info.language
        if language not in allowed:
            # Short clips are often misdetected: take the most likely allowed language and try again.
            probs = dict(info.all_language_probs or [])
            language = max(allowed, key=lambda code: probs.get(code, 0.0))
            segments, info = self.model.transcribe(audio, beam_size=1, vad_filter=True, language=language,
                                                  initial_prompt=hint)
        text = " ".join(segment.text.strip() for segment in segments).strip()
        return (text or None), language
