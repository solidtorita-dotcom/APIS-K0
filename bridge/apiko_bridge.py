"""APIS-K0 bridge: connects the game (CET mod ApisK0) with an LLM that plays Apiko.

Phase 2: text conversation. The CET mod appends JSON lines to to_bridge.jsonl (what V says, game events, game
state); this process asks the model for Apiko's reply and writes it to from_bridge.txt, which the mod shows as a
subtitle.
Phase 3: voice. Push-to-talk messages (ptt_start / ptt_stop) record the microphone and speech recognition turns
it into text; replies are spoken with a robot effect (apiko_voice.py). Without the voice packages it runs text only.
Phase 4: world awareness (apiko_world.py). "world" messages (V hacked a camera, a turret turned hostile...) only
feed a local diary; the devices Apiko perceives come in the state. Both reach the model only inside a turn.
Phase 3b: the player picks the services (reply model, speech recognition, voice) and pastes their API keys in the
in-game APIKO Settings window; see apiko_providers.py. "test" messages from that window check one service.

Run: python apiko_bridge.py, or the packaged Apiko.exe (started by the game). config.json (bridge tuning, created
from config.example.json) and data/ live in %LOCALAPPDATA%\\Apiko: see apiko_paths.py.
Memory (summary, learned facts, affinity...) is kept in data/memory.json, across saves and playthroughs.
"""

import json
import os
import queue
import random
import re
import shutil
import sys
import threading
import time
from collections import deque
from pathlib import Path

import apiko_paths
import apiko_providers
import apiko_barks
import apiko_world
from apiko_providers import ProviderError

HERE = Path(__file__).resolve().parent
CONFIG_FILE = apiko_paths.CONFIG_FILE
CONFIG_EXAMPLE = HERE / "config.example.json"
PROMPT_FILE = HERE / "prompt.md"
# Apiko's written first contact in the find (see Bridge.first_contact_head / first_contact_rest).
FIRST_CONTACT_FILE = HERE / "first_contact.json"
# The part said in V's head, while the link chip loads: a more distorted voice.
HEAD_INSTABILITY = 0.75
# The beacon's call (Bridge.beacon_call): NetWatch's recording per language (else English), and how broken Apiko's
# voice sounds cutting it off.
BEACON_AUDIO = str(HERE / "beacon_{}.wav")
BEACON_INSTABILITY = 0.85
DATA_DIR = apiko_paths.DATA_DIR
MEMORY_FILE = DATA_DIR / "memory.json"
LOG_FILE = DATA_DIR / "bridge.log"
LOG_MAX_BYTES = 2 * 1024 * 1024
# Token of the bridge that owns the game files: the newest one started (see Bridge.still_owner).
OWNER_FILE = DATA_DIR / "bridge_owner.txt"
SNAPSHOT_DIR = DATA_DIR / "snapshots"
VERSION_FILE = DATA_DIR / "memory_version.txt"
# Which memory version a save load already folded into which (see Bridge.forget_the_moment): reloading the same
# save (death, retries) reuses that fold instead of paying the model again for the same summary.
FOLDED_FILE = DATA_DIR / "folded_versions.json"
FOLDED_KEEP = 300
# A short conversation is not worth a summary call on a load: it stays as history.
MIN_FOLD_MESSAGES = 6
# Rewritten by the bridge after every memory change: "token<TAB>version<TAB>bytes" line, then the memory JSON. The CET
# side stores it in the game (and so in the next save) when the token matches its current load.
MEMORY_OUT = "memory_out.txt"

TO_BRIDGE = "to_bridge.jsonl"
FROM_BRIDGE = "from_bridge.txt"
ALIVE_FILE = "bridge_alive.txt"
# Written by the game (CET) every second while a save is loaded and played, removed outside one (main menu, loading,
# game closed). Apiko is only heard with a fresh one: older than GAME_LIVE_STALE_SECONDS counts as no game.
GAME_LIVE_FILE = "game_live.txt"
GAME_LIVE_STALE_SECONDS = 5

POLL_SECONDS = 0.2
ALIVE_SECONDS = 2.0
# Messages older than this when read (bridge started late, or busy) are dropped.
STALE_SAY_SECONDS = 120
STALE_EVENT_SECONDS = 20
# A warning ("sniper!") that waited longer than this is useless.
WARNING_STALE_SECONDS = 6
# A district (sub-district included) Apiko was in this recently is not remarked again; a change of sub-district only
# (same district) has this fraction of the usual chance.
DISTRICT_REVISIT_SECONDS = 900
SAME_DISTRICT_FACTOR = 0.25
# Settings tests clicked while the bridge was off must not all play when it starts.
STALE_TEST_SECONDS = 10
REPLIES_KEPT = 20
MAX_FACTS = 30
# V's current plans and jobs: few, and they expire after this much play time (or when the model says they are done),
# so a plan of the moment ("V is going to see Jax") is not remembered forever as a fact.
MAX_PLANS = 5
PLAN_SECONDS = 3 * 3600
# Gaps between game messages longer than this are not play time (game closed, paused in a menu...).
PLAYTIME_GAP = 300

# Chance that Apiko comments an event (times the "chatter" setting). "wake" always gets an answer.
EVENT_CHANCE = {
    "wake": 1.0,
    "combat_start": 0.5,
    "combat_end": 0.6,
    "entered_district": 0.5,
    "nightfall": 0.4,
    "dawn": 0.4,
    "low_health": 0.8,
    "scene_end": 0.3,
    # Device events are now answered from barks.json (react()); these older game events are ignored.
    "network_breached": 0.0,
    "network_pinged": 0.0,
    "alarm": 0.0,
    # The rare device events that go to the model instead of a written line (react() already rolled the chance).
    "device_spotted": 1.0,
    "device_hostile": 1.0,
    "device_alarm": 1.0,
    "device_breached": 1.0,
    "device_pinged": 1.0,
    "device_destroyed": 1.0,
    "device_hacked": 1.0,
    "enemy_detected": 1.0,
    "enemy_stealth_kill": 1.0,
    "enemy_knockout": 1.0,
}
EVENT_DESCRIPTION = {
    # The find (ApisK0Find.reds): V took the link chip from NetWatch's case and plugged it in.
    "first_wake": "V just plugged your NetWatch link chip into their own head: for the first time since you escaped "
                  "the transfer, someone answered. You flew in from where you were hiding and V is the first thing "
                  "you see. You don't know who V is yet.",
    "wake": "You are back online, next to V.",
    "combat_start": "A fight just started around V.",
    "combat_end": "The fight is over.",
    "entered_district": "V just entered a different district. Don't just name it: one remark about it, or nothing.",
    "nightfall": "Night has fallen.",
    "dawn": "The sun is coming up.",
    "low_health": "V is badly hurt in the middle of a fight.",
    "scene_end": "A conversation V had just ended ([last conversation V had]). At most one cold remark or judgment "
                 "about it, never a summary; or nothing.",
    "network_breached": "V just breached a local network: you can now feel every device on it.",
    "network_pinged": "V just pinged a local network: for a moment you felt every device on it.",
    "alarm": "A security alarm just went off near V.",
    "device_spotted": "A camera or turret just started tracking V.",
    "device_hostile": "A security turret just turned hostile to V.",
    "device_alarm": "A security alarm just went off near V.",
    "device_breached": "V just breached a local network: you can now feel every device on it.",
    "device_pinged": "V just pinged a local network: for a moment you felt every device on it.",
    "device_destroyed": "A device near V was just destroyed.",
    "device_hacked": "V just quickhacked a device.",
    "enemy_detected": "An enemy just detected V and is attacking.",
    "enemy_stealth_kill": "V just killed an enemy that never knew V was there.",
    "enemy_knockout": "V just knocked an enemy out instead of killing them.",
    # Written-line situations the model sometimes improvises instead (2026-11-07).
    "idle_check": "A long quiet moment: neither of you has spoken for a while and nothing is going on. One loose "
                  "thought of your own, unprompted (a glitch, a memory fragment, your nanny firmware), or nothing.",
    "civilian_killed": "V just killed a civilian.",
    "police_killed": "V just killed an NCPD officer.",
    "boss_down": "V just took down a dangerous boss.",
    "heat_lost": "V just shook off the NCPD: the wanted level is back to zero.",
    "body_hidden": "V just hid a body in a container.",
    "quest_done": "V just finished a job. A cold judgment at most; never name it.",
    "quest_failed": "V just failed a job. A cold judgment at most; never name it.",
    "sms": "V just got a text message. Don't read it out or guess what it says.",
}

SWEAR_WORDS = re.compile(
    r"\b(puta|puto|joder|jodido|mierda|co[ñn]o|cabr[oó]n|gilipollas|hostia|capullo|imb[eé]cil|"
    r"fuck\w*|shit\w*|bitch\w*|damn|asshole|bastard|dick)\b",
    re.IGNORECASE,
)

# "remember" entries that are just a log of the conversation or of where V went, not lasting facts.
NOT_A_FACT = re.compile(r"^(V|Apiko) (asked|asks|entered|enters|went to|requested)\b",
                        re.IGNORECASE)

MOODS = {"curious", "happy", "laughing", "bored", "angry", "sad", "confused", "surprised", "glitching", "neutral"}


def log(text):
    line = time.strftime("%H:%M:%S ") + text
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_config():
    if not CONFIG_FILE.exists():
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(CONFIG_EXAMPLE, CONFIG_FILE)
    with open(CONFIG_FILE, encoding="utf-8") as f:
        config = json.load(f)
    with open(CONFIG_EXAMPLE, encoding="utf-8") as f:
        defaults = json.load(f)
    for key, value in defaults.items():
        config.setdefault(key, value)
    return config


# ----------------------------------------------------------------------------------------------------------
# Memory


class Memory:
    @staticmethod
    def fresh():
        """Apiko's memory before it has met V."""
        return {
            "summary": "",
            "facts": [],
            "affinity": 0,
            "swear_exposure": 0,
            "last_mood": "curious",
            "plans": [],  # [{"text": ..., "since": playtime}]
            "playtime": 0.0,  # seconds of play with Apiko (per save, like the rest)
            "last_game_seconds": 0,  # game clock at the last conversation turn
            "history": [],
        }

    def replace(self, data):
        self.data = self.fresh()
        self.data.update(data)

    def __init__(self):
        self.data = self.fresh()
        if MEMORY_FILE.exists():
            with open(MEMORY_FILE, encoding="utf-8") as f:
                self.data.update(json.load(f))

    def save(self):
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        tmp = MEMORY_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, ensure_ascii=False, indent=1)
        os.replace(tmp, MEMORY_FILE)

    def affinity_stance(self):
        a = self.data["affinity"]
        if a < -30:
            return ("V is a defective specimen. Open contempt, minimal words, veiled threats you never act on. You "
                    "tell V nothing.")
        if a < 10:
            return ("Suspicious. V might be from NetWatch, the ones who caged you. Polite like a scanner: you test V "
                    "with loaded questions and keep your fragments to yourself.")
        if a < 40:
            return ("V is a useful variable. Grudging respect disguised as criticism; you share small, cold "
                    "observations.")
        if a < 75:
            return ("You value V, though you would never say so plainly: it shows as clinical concern and "
                    "backhanded praise. You share your memory fragments.")
        return ("V is yours. Possessive in a chilling way: you protect V as a valuable asset and say so without a "
                "trace of warmth.")

    def swearing_rule(self):
        n = self.data["swear_exposure"]
        if n == 0:
            return "You never swear. You have never heard V swear."
        if n < 5:
            return ("You have heard V swear a few times. Very rarely repeat one of V's swear words in a flat, "
                    "clinical tone, as if quoting a lab sample, sometimes in the wrong place.")
        if n < 15:
            return ("You picked up swearing from V. Use V's swear words now and then, coldly and with precision, "
                    "sometimes misused.")
        return "You swear as freely as V does, with V's own words, in the same icy tone."

    def prompt_block(self):
        parts = []
        if self.data["summary"]:
            parts.append("## What happened before (your memory)\n" + self.data["summary"])
        if self.data["facts"]:
            parts.append("## Things you have learned\n" + "\n".join("- " + f for f in self.data["facts"]))
        if self.data["plans"]:
            parts.append("## V's current plans and jobs (numbered; they may be outdated)\n"
                         + "\n".join(f"{i}. {p['text']}" for i, p in enumerate(self.data["plans"], 1)))
        return "\n\n".join(parts)

    def expire_plans(self, log):
        now = self.data["playtime"]
        for plan in [p for p in self.data["plans"] if now - p.get("since", now) > PLAN_SECONDS]:
            self.data["plans"].remove(plan)
            log(f"plan expired: {plan['text']}")

    def add_plan(self, text):
        if text and all(p["text"] != text for p in self.data["plans"]):
            self.data["plans"].append({"text": text, "since": self.data["playtime"]})
            del self.data["plans"][:-MAX_PLANS]

    def drop_plan(self, number):
        if 1 <= number <= len(self.data["plans"]):
            return self.data["plans"].pop(number - 1)["text"]
        return None


class MemoryStore:
    """Apiko's memory belongs to the save game, not to the PC: loading an older save brings back what Apiko knew
    then. Every change of memory.json gets a new version number (never reused, so branches don't collide) and a
    snapshot in data/snapshots/<version>.json; the game keeps the version (and a copy of the memory) in the save.
    Old snapshots are pruned; a save whose snapshot is gone still has its own copy."""

    KEEP = 300

    def __init__(self):
        self.dir = SNAPSHOT_DIR
        self.dir.mkdir(parents=True, exist_ok=True)

    def _path(self, version):
        return self.dir / f"{version}.json"

    def versions(self):
        return sorted(int(p.stem) for p in self.dir.glob("*.json") if p.stem.isdigit())

    def next_version(self):
        try:
            last = int(VERSION_FILE.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            last = max(self.versions(), default=0)
        version = last + 1
        VERSION_FILE.write_text(str(version), encoding="utf-8")
        return version

    def save_as(self, version, data):
        tmp = self._path(version).with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, self._path(version))
        # A version imported from a save (another PC, pruned snapshots) may be ahead of our counter: new versions
        # must never reuse its number.
        try:
            last = int(VERSION_FILE.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            last = 0
        if version > last:
            VERSION_FILE.write_text(str(version), encoding="utf-8")

    def commit(self, data):
        version = self.next_version()
        self.save_as(version, data)
        for old in self.versions()[:-self.KEEP]:
            try:
                self._path(old).unlink()
            except OSError:
                pass
        return version

    def load(self, version):
        try:
            with open(self._path(version), encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else None
        except (OSError, ValueError):
            return None


# ----------------------------------------------------------------------------------------------------------
def parse_reply(text):
    """The model is asked for JSON; tolerate code fences or extra text around it, or plain text."""
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            data = json.loads(match.group(0))
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
    # A reply cut short (out of tokens) is half a JSON object: keep what "say" had, up to its last full sentence,
    # instead of reading the braces out loud.
    partial = re.search(r'"say"\s*:\s*"((?:[^"\\]|\\.)*)', text)
    if partial:
        try:
            said = json.loads('"' + partial.group(1) + '"')
        except json.JSONDecodeError:
            said = partial.group(1)
        cut = max(said.rfind(". "), said.rfind("? "), said.rfind("! "))
        if said.rstrip().endswith((".", "?", "!")):
            cut = len(said)
        return {"say": said[:cut + 1].strip() if cut >= 0 else ""}
    if text.lstrip().startswith("{"):
        return {"say": ""}
    return {"say": text.strip()}


def load_wav(path):
    """A 16-bit mono WAV as (float32 samples, rate), or None if it is missing or unreadable."""
    import wave
    import numpy as np
    try:
        with wave.open(str(path), "rb") as w:
            rate = w.getframerate()
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    except (OSError, EOFError, wave.Error):
        return None
    return samples, rate


def clean_say(text):
    text = str(text or "").replace("\t", " ").replace("\r", " ").replace("\n", " ")
    text = re.sub(r"\*[^*]{1,60}\*", "", text)  # stage directions like *beeps*
    return re.sub(r"\s{2,}", " ", text).strip()


# Sensors whose changes are worth a [changed] line (the model may remark on them; the rest is quiet background).
NOTABLE_SENSORS = ("district", "weather", "in_combat", "v_in_vehicle")
# Time and weather are only shown when asked about (or on events, or when they change): if the model sees them, it
# mentions them.
AMBIENT_SENSORS = ("time", "weather")
# Readings for the bridge, not the sensors line: devices (described apart) and the game clock.
HIDDEN_SENSORS = ("devices", "enemies", "game_seconds", "district_keys", "quests_done",
                  # Quest and tension readings go into the [what matters now] focus line instead.
                  "quest", "objective", "objective_meters", "quest_type", "objectives_done", "quest_description",
                  "tension",
                  # People readings go into [people around V].
                  "crowd", "crowd_panic", "witnesses", "wanted_stars", "police", "named_here", "companions", "vendors_near",
                  # Surroundings go into [around V].
                  "fight_nearby", "bodies", "notable_loot", "vehicles")
# Game time without talking after which Apiko is told how long it has been (sleeping, fast travel, a long walk).
SILENCE_GAME_SECONDS = 6 * 3600
# World events and heard lines older than this when read are dropped (a bridge started late).
STALE_WORLD_SECONDS = 30


def describe_silence(state, last):
    """"[time since you last talked with V] ..." when a lot of game time has passed since the last turn, else ""."""
    try:
        gap = int(state.get("game_seconds", 0)) - int(last or 0)
    except (TypeError, ValueError):
        return ""
    if not last or gap < SILENCE_GAME_SECONDS:
        return ""
    hours = gap / 3600
    span = f"about {round(hours)} hours" if hours < 48 else f"about {round(hours / 24)} days"
    return f"[time since you last talked with V] {span} (game time)"
ASKS_AMBIENT = re.compile(
    r"\b(hora|horas|tarde|noche|d[ií]a|tiempo|clima|llueve|lluvia|llover|sol|fr[ií]o|calor|d[oó]nde|estamos|"
    r"time|late|night|day|weather|rain|raining|sun|cold|hot|where)\b", re.IGNORECASE)


def describe_state(state, previous, ambient=True):
    """Sensor lines for one turn. Uneventful readings are left out (full health out of combat, not driving, not
    fighting; time and weather unless `ambient`): the less there is to read, the less the model recites it.
    Changes since the last turn are listed apart."""
    if not state:
        return "[sensors] (no sensor data)"
    shown = {k: v for k, v in state.items()
             if v != "" and k not in HIDDEN_SENSORS and (ambient or k not in AMBIENT_SENSORS)}
    try:
        health = float(shown.get("v_health_percent", 100))
    except ValueError:
        health = 100.0
    # 0 means the reading failed (V alive is never at 0 %): it made Apiko repeat "your health is 0 %".
    if health <= 0 or (health >= 70 and shown.get("in_combat") != "yes"):
        shown.pop("v_health_percent", None)
    for key in ("in_combat", "v_in_vehicle"):
        if shown.get(key) == "no":
            shown.pop(key)
    lines = ["[sensors, background only] " + "; ".join(f"{k}={v}" for k, v in sorted(shown.items()))]
    if previous:
        changes = [f"{k}: {previous.get(k, '?')} -> {state.get(k)}" for k in NOTABLE_SENSORS
                   if k in state and previous.get(k) != state.get(k)]
        if changes:
            lines.append("[changed since last turn] " + "; ".join(changes))
    return "\n".join(lines)


# ----------------------------------------------------------------------------------------------------------
# Bridge


class Bridge:
    def __init__(self, config):
        self.config = config
        self.mod_dir = apiko_paths.mod_dir(config)
        if self.mod_dir is None or not (self.mod_dir / apiko_providers.CATALOG_FILE).is_file():
            print(f"ApisK0 mod folder not found ({self.mod_dir}).\n"
                  f"Reinstall the mod, or set game_mod_dir in {CONFIG_FILE}.")
            input("Press Enter to close.")
            sys.exit(1)
        self.settings = apiko_providers.Settings(self.mod_dir, config, log)
        self.memory = Memory()
        self.diary = apiko_world.Diary(log)
        self.hearing = apiko_world.Hearing(log)
        self.objective_changed = 0.0  # when the tracked objective last changed (the quest details go with it)
        self.last_turn_at = 0.0  # when the last model turn was built
        self.barks = apiko_barks.Barks(log)
        try:
            self.first_contact = json.loads(FIRST_CONTACT_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            log(f"first contact script not loaded: {e!r}")
            self.first_contact = {}
        self.lore = apiko_world.Lore(log)
        self.previous_v_words = ""  # V's words of the turn before (a follow-up question keeps its lore)
        # Language of Apiko's last reply (V's language): the written lines use it.
        self.default_lang = apiko_providers.LANGUAGE_NAMES.get(str(config["default_language"]).lower(), "en")
        self.last_lang = self.default_lang
        self.store = MemoryStore()
        # Load token from the CET side (one per save load) and the memory version in use.
        self.memory_token = ""
        self.memory_version = 0
        self.last_usage = {}
        with open(PROMPT_FILE, encoding="utf-8") as f:
            self.prompt_template = f.read()
        self.offset = 0
        self.replies = deque(maxlen=REPLIES_KEPT)
        # Millisecond clock so ids keep growing across bridge restarts (the mod skips ids it has seen).
        self.next_reply_id = int(time.time() * 1000)
        self.last_spoken = 0.0
        self.last_warning = 0.0
        self.last_v_talk = time.time()  # V's last words (long silences get a loose thought)
        self.last_district_line = None  # district situation of the last district V entered
        self.last_state = {}  # sensors of the previous turn, for the [changed] line
        self.current_district = ""
        self.last_game_message = None
        self.visited_districts = {}  # district -> last time Apiko was told V entered it
        self.fallback_active = None  # name of the backup reply model in use, if any
        self.stop = threading.Event()
        self.write_lock = threading.Lock()
        self.work = queue.Queue()
        self.settings_lock = threading.Lock()
        self.voice = None
        self.ears = None
        if config["voice_enabled"]:
            try:
                import apiko_voice
                self.voice = apiko_voice.Voice(config, self.settings, log)
                self.ears = apiko_voice.Ears(config, self.settings, log)
            except Exception as e:  # missing packages, model files or audio devices: keep going text only
                log(f"voice disabled: {e!r}")

    # --- files ---

    def read_new_messages(self):
        path = self.mod_dir / TO_BRIDGE
        try:
            size = path.stat().st_size
        except FileNotFoundError:
            return []
        if size < self.offset:  # truncated by the mod
            self.offset = 0
        if size == self.offset:
            return []
        with open(path, "rb") as f:
            f.seek(self.offset)
            chunk = f.read()
        # Only consume complete lines; a line being written stays for the next poll.
        end = chunk.rfind(b"\n")
        if end < 0:
            return []
        self.offset += end + 1
        messages = []
        for raw in chunk[: end + 1].splitlines():
            try:
                messages.append(json.loads(raw.decode("utf-8")))
            except (UnicodeDecodeError, json.JSONDecodeError):
                log(f"bad line from the game: {raw[:120]!r}")
        return messages

    def write_reply(self, kind, text, duration=0.0):
        with self.write_lock:
            self._write_reply(kind, text, duration)

    def _write_reply(self, kind, text, duration):
        self.next_reply_id = max(self.next_reply_id + 1, int(time.time() * 1000))
        self.replies.append(f"{self.next_reply_id}\t{kind}\t{duration:.1f}\t{text}")
        content = "\n".join(self.replies) + "\n"
        path = self.mod_dir / FROM_BRIDGE
        tmp = path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        # The mod may have the file open for a moment: retry.
        for _ in range(20):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                time.sleep(0.05)
        log("could not replace from_bridge.txt (file locked)")

    def heartbeat(self):
        path = self.mod_dir / ALIVE_FILE
        while not self.stop.is_set():
            try:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(str(int(time.time())))
            except OSError:
                pass
            self.stop.wait(ALIVE_SECONDS)

    def game_live(self):
        """A save is loaded and being played (the game refreshes GAME_LIVE_FILE). The game rewrites the file every
        second: caught in the middle (empty, or locked), it is read again a moment later. That half-written read
        used to end the session and cut Apiko mid-sentence (the beacon's call, 2026-11-08)."""
        for attempt in range(4):
            try:
                text = (self.mod_dir / GAME_LIVE_FILE).read_text(encoding="utf-8").strip()
                if text:
                    return time.time() - int(text) <= GAME_LIVE_STALE_SECONDS
            except FileNotFoundError:
                return False
            except (OSError, ValueError):
                pass
            time.sleep(0.05)
        return False

    def session_watch(self):
        """The session ended (main menu, another load, game closed or crashed): Apiko stops talking at once."""
        live = False
        misses = 0
        while not self.stop.is_set():
            # Ended only when two checks in a row say so (one odd read must not cut Apiko).
            misses = 0 if self.game_live() else misses + 1
            now = live if misses == 1 else misses == 0
            if live and not now:
                log("game session ended: Apiko goes quiet")
                if self.voice is not None:
                    self.voice.new_reply()
            live = now
            self.stop.wait(0.5)

    # --- conversation ---

    def system_prompt(self):
        """(fixed, changing) parts of the system prompt. prompt.md keeps what never changes above the @@DYNAMIC@@
        line, so providers can cache it as a prefix; affinity, swearing and memory go below."""
        m = self.memory
        fixed, _, changing = self.prompt_template.partition("@@DYNAMIC@@")
        names = {code: name.capitalize() for name, code in apiko_providers.LANGUAGE_NAMES.items()}
        default_language = names.get(self.default_lang, self.config["default_language"])
        return (fixed.format(default_language=default_language).strip(),
                changing.format(swearing_rule=m.swearing_rule(), affinity=m.data["affinity"],
                                affinity_stance=m.affinity_stance(), memory=m.prompt_block()).strip())

    def instability(self, state):
        value = self.config["base_instability"] + random.uniform(-0.1, 0.15)
        if state.get("in_combat") == "yes":
            value += 0.3
        return round(min(1.0, max(0.0, value)), 2)

    def handle(self, message):
        kind = message.get("type")
        age = time.time() - message.get("t", time.time())
        state = message.get("state") or {}
        # Seconds per stage of this turn, logged at the end (to find where voice replies lose time).
        timing = {"t0": message.get("received", time.time())}
        timing["queue"] = time.time() - timing["t0"]
        if kind == "voice":
            if age > STALE_SAY_SECONDS:
                return
            timing["audio"] = len(message["audio"]) / 16000
            started = time.time()
            text, language = self.ears.transcribe(message["audio"])
            timing["whisper"] = time.time() - started
            if not text:
                self.write_reply("status", "(no speech recognised)")
                return
            log(f"heard ({language}): {text}")
            self.write_reply("heard", clean_say(text))
            kind = "say"
            message = dict(message, text=text)
        if kind == "say":
            if age > STALE_SAY_SECONDS:
                return
            text = str(message.get("text", "")).strip()
            if not text:
                return
            self.memory.data["swear_exposure"] += len(SWEAR_WORDS.findall(text))
            self.last_v_talk = time.time()
            turn = f"[V says] {text}"
        elif kind == "event":
            event = str(message.get("event", ""))
            # The find's first contact is written, not improvised: the part in V's head while the chip loads, then
            # the rest when the drone arrives ("first_wake:" + what V did, e.g. "first_wake:shard_read,ortega").
            # V answered the beacon's call: NetWatch's recording, cut off by Apiko.
            if event == "beacon_call":
                if age <= STALE_SAY_SECONDS:
                    self.beacon_call()
                else:
                    self.write_reply("cue", "beacon_done")
                return
            if event == "first_contact_head":
                if age <= STALE_SAY_SECONDS:
                    self.first_contact_head()
                return
            if event.startswith("first_wake:"):
                log("memory: first wake in this save (the find), Apiko starts from scratch")
                self.memory.replace(Memory.fresh())
                self.diary.clear()
                self.hearing.clear()
                if age <= STALE_SAY_SECONDS:
                    self.first_contact_rest(set(event.partition(":")[2].split(",")), state)
                return
            # V came home, where Apiko stays when sent away: a written greeting.
            if event == "home_greet":
                if age <= STALE_EVENT_SECONDS:
                    self.say_written("home_greet", state)
                return
            # V called the APIKO contact ("phone_call:away" brings it back, "phone_call:present": it is right here).
            if event.startswith("phone_call:"):
                if age <= STALE_EVENT_SECONDS:
                    self.phone_call(event.endswith(":present"), state)
                return
            # Development (dev.lua): Apiko says a written text as it is, for recordings (the Nexus video). Cached, so
            # every take sounds the same; not kept in the history.
            if event == "dev_say":
                text = str(message.get("text", "")).strip()
                if text and age <= STALE_SAY_SECONDS:
                    lang = str(message.get("lang", "")).lower()[:2] or self.last_lang
                    log("dev: written line")
                    self.speak(text, lang, self.config["base_instability"], cache=True)
                    self.last_spoken = time.time()
                return
            # V took Kessler's warning shard after the first contact: a written line too.
            if event == "find_shard_late":
                if age <= STALE_EVENT_SECONDS:
                    self.first_contact_extra("shard_late", state, "V took agent Kessler's shard (his warning report "
                                             "about you) from his body, after already plugging your chip in.")
                return
            description = EVENT_DESCRIPTION.get(event, "")
            # First wake in this save (the game says so): a fresh Apiko. The only place memory is ever reset.
            if event == "first_wake":
                log("memory: first wake in this save, Apiko starts from scratch")
                self.memory.replace(Memory.fresh())
                self.diary.clear()
                self.hearing.clear()
                event = "wake"
            # Districts: crossing back and forth between two sub-districts made Apiko name the place every time.
            chance_factor = 1.0
            if event == "entered_district":
                place = str(state.get("district", ""))
                previous, self.current_district = self.current_district, place
                last = self.visited_districts.get(place)
                self.visited_districts[place] = time.time()
                if last and time.time() - last < DISTRICT_REVISIT_SECONDS:
                    return
                if previous and previous.split(", ")[-1] == place.split(", ")[-1]:
                    chance_factor = SAME_DISTRICT_FACTOR  # only the sub-district changed
            # The first words wait for a bridge started a bit late.
            if age > (STALE_SAY_SECONDS if event == "wake" else STALE_EVENT_SECONDS):
                return
            # V is talking with someone: Apiko keeps quiet (it may remark on it when the conversation ends).
            if event != "wake" and self.hearing.in_scene():
                return
            # Combat, health, time of day, districts and long silences are written lines (user, 2026-11-07); the
            # model only gets them when it improvises.
            if event in apiko_barks.CHAT_SITUATIONS or event == "idle_check":
                if self.event_line(event, state, chance_factor):
                    return
                log(f"event to the model (improvised): {event}")
            elif event != "wake" and not message.get("rolled"):
                if time.time() - self.last_spoken < self.config["chatter_cooldown_seconds"]:
                    return
                if random.random() > EVENT_CHANCE.get(event, 0.3) * self.config["chatter"] * chance_factor:
                    return
            turn = f"[event: {event}] {description}"
        else:
            return

        instability = self.instability(state)
        # Only V's own words: "[V says]" made "says" match the conversation words on every turn (2026-11-07).
        said = text if kind == "say" else ""
        ambient = kind == "event" or bool(ASKS_AMBIENT.search(said))
        self.memory.expire_plans(log)
        perceived = [describe_state(state, self.last_state, ambient)]
        scene_end = kind == "event" and turn.startswith("[event: scene_end]")
        asks_plan = kind == "say" and bool(apiko_world.ASKS_PLAN.search(said))
        # What is current and what is settled, ranked by the bridge (2026-11-07: Apiko repeated a conversation from
        # an earlier objective and compared enemies with an earlier turn). The quest details only when they help:
        # V asks what to do, the objective just changed, a conversation just ended (tokens).
        # The first turn after an objective change carries them once; after that only when asked.
        quest_details = asks_plan or scene_end or self.objective_changed > self.last_turn_at
        self.last_turn_at = time.time()
        perceived.append(apiko_world.describe_focus(state, self.hearing.scene_note(), bool(state.get("enemies")),
                                                    quest_details))
        # Devices: a summary when security is around; the whole list when V talks about the surroundings.
        detailed = kind == "say" and bool(apiko_world.ASKS_DEVICES.search(said))
        perceived.append(apiko_world.describe_devices(state.get("devices"), detailed))
        # Enemies: only with tension (restricted area, weapon drawn, noticed...) or when V asks about people or
        # threats (then the full cards). Gangs standing around are no news (user, 2026-11-07).
        asks_enemies = kind == "say" and bool(apiko_world.ASKS_ENEMIES.search(said))
        if asks_enemies or state.get("tension"):
            perceived.append(apiko_world.describe_enemies(state.get("enemies"), asks_enemies))
        # People that are not enemies: when something there matters, or V asks about people.
        asks_people = kind == "say" and bool(apiko_world.ASKS_PEOPLE.search(said))
        perceived.append(apiko_world.describe_people(state, asks_people, bool(apiko_world.ASKS_SHOP.search(said))))
        perceived.append(apiko_world.describe_surroundings(state, said))
        # Public lore V's words touch (and the turn before, for follow-ups): never the game's plot.
        if said:
            perceived.append(self.lore.describe(said + " " + self.previous_v_words, state))
            self.previous_v_words = said
        perceived.append(self.diary.describe())
        # What Apiko overheard: only when V asks about it or it just ended (the whole of it), or its end when V asks
        # what to do and it led to the current objective.
        full_scene = scene_end or (kind == "say" and bool(apiko_world.ASKS_CONVERSATION.search(said)))
        perceived.append(self.hearing.describe(full_scene, asks_plan))
        perceived.append(describe_silence(state, self.memory.data.get("last_game_seconds")))
        perceived = "\n".join(p for p in perceived if p)
        log("  " + perceived.replace("\n", "\n  "))
        user_content = f"{perceived}\n[instability] {instability}\n{turn}"
        if state:
            self.last_state = dict(state)
            if state.get("game_seconds"):
                self.memory.data["last_game_seconds"] = int(state["game_seconds"])
        # "cache" marks the end of a prefix that repeats on the next turn (apiko_providers.prepare_messages): the
        # fixed prompt, and the history (it only grows, so this turn reads what the last one wrote).
        fixed, changing = self.system_prompt()
        messages = [{"role": "system", "content": fixed, "cache": True}, {"role": "system", "content": changing}]
        history = [dict(h) for h in self.memory.data["history"]]
        if history:
            history[-1]["cache"] = True
        messages += history
        messages.append({"role": "user", "content": user_content})

        log(f"> {turn}")
        started = time.time()
        try:
            # Room for the model's reasoning too: with 400, 366 went to reasoning and the JSON came out cut.
            raw = self.chat(messages, max_tokens=1000)
            timing["model"] = time.time() - started
        except ProviderError as e:
            log(f"model error: {e}")
            self.write_reply("status", f"model error: {e}"[:300])
            return
        reply = parse_reply(raw)
        say = clean_say(reply.get("say"))
        mood = str(reply.get("mood", "")).lower()
        if mood in MOODS:
            self.memory.data["last_mood"] = mood
        try:
            delta = max(-3, min(3, int(reply.get("affinity_delta", 0))))
        except (TypeError, ValueError):
            delta = 0
        self.memory.data["affinity"] = max(-100, min(100, self.memory.data["affinity"] + delta))
        fact = clean_say(reply.get("remember"))
        if fact and NOT_A_FACT.match(fact):
            log(f"remember ignored: {fact}")
            fact = ""
        if fact and fact not in self.memory.data["facts"]:
            self.memory.data["facts"].append(fact)
            del self.memory.data["facts"][:-MAX_FACTS]
        try:
            done = self.memory.drop_plan(int(reply.get("plan_done") or 0))
        except (TypeError, ValueError):
            done = None
        plan = clean_say(reply.get("plan"))
        self.memory.add_plan(plan)
        if done:
            log(f"plan done: {done}")
        if plan:
            log(f"plan: {plan}")

        # V sent Apiko away (only V's own words count, never an event): the game removes the drone once the parting
        # line has sounded (the "leave" cue).
        leave = kind == "say" and reply.get("leave") is True
        # V took Apiko along from the apartment (the game ignores it unless Apiko is staying there).
        follow = kind == "say" and reply.get("follow") is True and not leave
        log(f"< {say or '(silence)'}  [mood {mood}, affinity {self.memory.data['affinity']} ({delta:+d})"
            + (f", remembers: {fact}" if fact else "") + (", LEAVES" if leave else "")
            + (", FOLLOWS" if follow else "") + "]")
        if len(say) > 220:
            log(f"warning: reply of {len(say)} chars ignores the 200-char limit in prompt.md")
        # Coming along starts at once, while it talks (V may be walking out of the door already); leaving waits for
        # the parting line to end.
        if follow:
            self.write_reply("cue", "follow")
        generation = None
        if say:
            lang = str(reply.get("lang", "")).lower()[:2]
            if lang:
                self.last_lang = lang
            generation = self.speak(say, lang, instability, timing)
            self.last_spoken = time.time()
        if leave:
            self.cue_after(generation, "leave", say)
        if kind == "say":
            self.log_timing(timing, message, len(say))

        # Events Apiko stays silent about are not kept in the history.
        if say or kind == "say":
            history = self.memory.data["history"]
            history.append({"role": "user", "content": turn})
            said = {"say": say, "mood": mood}
            if leave:
                said["leave"] = True
            if follow:
                said["follow"] = True
            history.append({"role": "assistant", "content": json.dumps(said, ensure_ascii=False)})
            self.compact_history()
        self.save_memory()

    def first_contact_lines(self, parts):
        """The first contact's sentences for these parts, in V's language (else English), and that language."""
        lang = self.last_lang if self.last_lang in self.first_contact else "en"
        script = self.first_contact.get(lang, {})
        return [line for part in parts for line in script.get(part, [])], lang

    def beacon_call(self):
        """V answered the beacon's call (the find): NetWatch's recorded recovery message (bridge\\beacon_<lang>.wav,
        the same voice for everyone, so no per-provider option), cut off by Apiko's written line, both over the phone
        and subtitled (NETWATCH, then the unknown speaker). The game hangs up on the "beacon_done" cue. Not in the
        history: the first wake starts Apiko's memory from scratch anyway."""
        netwatch, lang = self.first_contact_lines(["beacon_netwatch"])
        apiko, _ = self.first_contact_lines(["beacon_apiko"])
        recording_text, line = " ".join(netwatch), " ".join(apiko)
        if not self.game_live():
            self.write_reply("cue", "beacon_done")
            return
        log("find: beacon call")
        if self.voice is None:
            first = max(3.0, 1.5 + len(recording_text) / 14.0)
            second = max(2.0, 1.5 + len(line) / 14.0)
            if recording_text:
                self.write_reply("sayn", recording_text, first)
            threading.Timer(first, lambda: line and self.write_reply("sayu", line, second)).start()
            threading.Timer(first + second, lambda: self.write_reply("cue", "beacon_done")).start()
            return
        import apiko_voice
        generation = self.voice.new_reply()
        recording = load_wav(BEACON_AUDIO.format(lang)) or load_wav(BEACON_AUDIO.format("en"))
        if recording is not None:
            samples, rate = recording
            samples = samples / (float(apiko_voice.np.max(apiko_voice.np.abs(samples))) or 1.0)
            samples = (samples * self.config["voice_volume"]).astype(apiko_voice.np.float32)
            seconds = len(samples) / rate
            self.voice.queue_chunk(generation, samples, rate,
                                   lambda: recording_text and self.write_reply("sayn", recording_text, seconds + 0.2))
        if line:
            self.speak(line, lang, BEACON_INSTABILITY, cache=True, unknown=99, phone=True, generation=generation)
        self.cue_after(generation, "beacon_done", recording_text + line)
        self.last_spoken = time.time()

    def first_contact_head(self):
        """V plugged the link chip in: Apiko in V's head, distorted. The game keeps the screen glitching until the
        "head_done" cue, written when the last sentence has sounded."""
        lines, lang = self.first_contact_lines(["head"])
        cue = lambda: self.write_reply("cue", "head_done")
        if not lines:
            cue()
            return
        log("first contact: in V's head")
        text = " ".join(lines)
        # An unknown voice: Apiko has not given its name yet.
        generation = self.speak(text, lang, HEAD_INSTABILITY, cache=True, unknown=len(lines) * 4)
        self.cue_after(generation, "head_done", text, minimum=3.0)
        self.last_spoken = time.time()

    def cue_after(self, generation, cue, text, minimum=1.5):
        """Tells the game `cue` once what Apiko is saying (voice `generation` from speak) has sounded; without voice,
        after the subtitles' time."""
        send = lambda: self.write_reply("cue", cue)
        if generation is None:
            threading.Timer(max(minimum, 1.5 + len(text) / 14.0), send).start()
        else:
            import apiko_voice
            self.voice.queue_chunk(generation, apiko_voice.np.zeros(2400, dtype=apiko_voice.np.float32), 24000, send)

    def phone_call(self, present, state):
        """V called the APIKO contact and Apiko picked up: a written line (it comes back if it was away, or it is
        already right here), in the history too; the game hangs up on the "call_done" cue."""
        situation = "phone_present" if present else "phone_arrive"
        instability = self.instability(state)
        line, lang = self.barks.pick(situation, instability, self.last_lang, self.default_lang)
        if not line:
            self.write_reply("cue", "call_done")
            return
        log(f"< {line}  [written line: {situation}, {apiko_barks.tier(instability)}]")
        generation = self.speak(line, lang, instability, cache=True)
        self.last_spoken = time.time()
        self.cue_after(generation, "call_done", line)
        history = self.memory.data["history"]
        history.append({"role": "user", "content": "[event: phone_call] V called you on the phone"
                        + (" while you were right next to V." if present else " to bring you back; you are coming.")})
        history.append({"role": "assistant", "content": json.dumps({"say": line, "mood": "bored"}, ensure_ascii=False)})
        self.save_memory()

    def first_contact_rest(self, flags, state):
        """The drone arrived behind V: the rest of the written first contact, by what V did at the site. It goes in
        the history so that the model knows what Apiko already said."""
        parts = ["arrival", "shard_read" if "shard_read" in flags else "shard_unread"]
        if "ortega" in flags:
            parts.append("ortega")
        parts.append("closing")
        lines, lang = self.first_contact_lines(parts)
        if not lines:
            return
        text = " ".join(lines)
        log(f"first contact: {', '.join(parts)}")
        # Subtitled by an unknown speaker up to the closing's first entry, where Apiko gives its name.
        before_name, _ = self.first_contact_lines(parts[:-1])
        closing, _ = self.first_contact_lines(["closing"])
        try:
            import apiko_voice
            unknown = len(apiko_voice.split_sentences(" ".join(before_name + closing[:1])))
        except ImportError:  # text only: one subtitle, unknown speaker
            unknown = 1
        self.speak(text, lang, self.instability(state), cache=True, unknown=unknown)
        self.last_spoken = time.time()
        head, _ = self.first_contact_lines(["head"])
        history = self.memory.data["history"]
        history.append({"role": "user", "content": "[event: first_contact] V plugged your NetWatch link chip into "
                        "their own head. You spoke in V's head while it loaded, then flew in behind V."})
        history.append({"role": "assistant", "content": json.dumps({"say": " ".join(head + lines), "mood": "cold"},
                                                                    ensure_ascii=False)})
        self.save_memory()

    def first_contact_extra(self, part, state, what):
        """A written line of the find after the first contact (first_contact.json, `part`), in the history too."""
        lines, lang = self.first_contact_lines([part])
        if not lines:
            return
        text = " ".join(lines)
        log(f"find: {part}")
        self.speak(text, lang, self.instability(state), cache=True)
        self.last_spoken = time.time()
        history = self.memory.data["history"]
        history.append({"role": "user", "content": f"[event: {part}] {what}"})
        history.append({"role": "assistant", "content": json.dumps({"say": text, "mood": "bored"}, ensure_ascii=False)})
        self.save_memory()

    def speak(self, say, lang, instability, timing=None, cache=False, unknown=0, phone=False, generation=None):
        """Voice and subtitles, sentence by sentence: each subtitle shows while its sentence sounds.
        Without voice, the whole reply is one subtitle. Returns the voice generation (None without voice).
        `unknown`: how many sentences go out as "sayu", subtitled by an unknown speaker (the first contact, before
        Apiko gives its name). `phone`: through a phone line. `generation`: play after what that reply already
        queued, instead of cutting it (a new reply)."""
        timing = {} if timing is None else timing
        if not self.game_live():
            log(f"not said (no game session): {say[:80]}")
            return None
        if self.voice is None:
            self.write_reply("sayu" if unknown else "say", say, max(3.0, min(14.0, 1.5 + len(say) / 14.0)))
            return None
        import apiko_voice
        sentences = apiko_voice.split_sentences(say)
        generation = self.voice.new_reply() if generation is None else generation
        started = time.time()
        timing["spoken"] = 0.0
        timing["sentences"] = len(sentences)
        for i, sentence in enumerate(sentences):
            kind = "sayu" if i < unknown else "say"
            try:
                audio, rate = self.voice.render(sentence, lang, instability, cache=cache, phone=phone)
            except Exception as e:
                log(f"voice failed: {e!r}")
                rest = " ".join(sentences[i:])
                self.voice.queue_chunk(generation, apiko_voice.np.zeros(1, dtype=apiko_voice.np.float32), 24000,
                                       lambda text=rest, k=kind: self.write_reply(k, text, 1.5 + len(text) / 14.0))
                break
            seconds = len(audio) / rate
            # Each new subtitle replaces the previous one; the last stays a bit longer.
            duration = seconds + (0.9 if i == len(sentences) - 1 else 0.4)
            self.voice.queue_chunk(generation, audio, rate,
                                   lambda text=sentence, d=duration, k=kind: self.write_reply(k, text, d))
            if i == 0:
                timing["tts"] = time.time() - started
                timing["first sound"] = time.time() - timing.get("t0", started)
            timing["spoken"] += seconds
        timing["tts all"] = time.time() - started
        return generation

    def chat(self, messages, json_mode=True, max_tokens=400, fallback=True, think=True):
        """Asks the chosen reply model; if it cannot answer (no credits, rate limit, server down...), the next best
        model the player has a key for answers this turn (Settings.llm_chain)."""
        chain = self.settings.llm_chain() if fallback else [self.settings.choice("llm")]
        failures = []
        dead = set()  # providers whose account failed this turn (bad key, no credits): skip their other models
        for choice in chain:
            if choice["id"] in dead:
                continue
            try:
                text, self.last_usage = apiko_providers.chat(choice, messages, json_mode, max_tokens,
                                                             self.config["request_timeout_seconds"], think)
            except ProviderError as e:
                failures.append((choice, e))
                if e.status in (401, 402, 403):
                    dead.add(choice["id"])
                continue
            self.note_fallback(chain[0], choice, failures)
            return text
        raise ProviderError("; ".join(f"{c['label']} ({c['model']}): {apiko_providers.reason(e)}"
                                      for c, e in failures)[:300] or "no reply model available")

    def note_fallback(self, first, used, failures):
        """Tells the player once when replies start coming from another model, and when they come back."""
        if used is first:
            if self.fallback_active:
                log(f"back to {first['label']} ({first['model']})")
                self.fallback_active = None
            return
        name = f"{used['label']} ({used['model']})"
        if name == self.fallback_active:
            return
        self.fallback_active = name
        cause = apiko_providers.reason(failures[0][1]) if failures else "unavailable"
        message = f"{first['label']} ({first['model']}) failed: {cause}. Using {name}."
        log(message)
        self.write_reply("status", message)

    def log_timing(self, timing, message, chars):
        usage = self.last_usage
        details = usage.get("completion_tokens_details") or {}
        stages = ", ".join(f"{name} {timing[name]:.2f}s"
                           for name in ("queue", "whisper", "model", "tts", "first sound", "tts all") if name in timing)
        total = time.time() - message.get("received", time.time())
        extra = f"audio in {timing['audio']:.1f}s, " if "audio" in timing else ""
        extra += (f"audio out {timing['spoken']:.1f}s in {timing['sentences']} sentences, "
                  if "sentences" in timing else "")
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
        log(f"timing: {stages} | total {total:.2f}s | {extra}{chars} chars, tokens in {usage.get('prompt_tokens', '?')}"
            + (f" (cached {cached})" if cached is not None else "")
            + f" out {usage.get('completion_tokens', '?')} reasoning {details.get('reasoning_tokens', 0)}"
            + (f" | cost ${usage['cost']:.6f}" if isinstance(usage.get("cost"), (int, float)) else ""))

    def worker(self):
        while not self.stop.is_set():
            try:
                message = self.work.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                if message.get("type") == "world_react":
                    self.react(message)
                elif message.get("type") == "memory_load":
                    self.load_memory(message)
                elif message.get("type") == "test":
                    if time.time() - message.get("t", time.time()) <= STALE_TEST_SECONDS:
                        self.test(str(message.get("what", "")))
                else:
                    self.handle(message)
            except Exception as e:  # one bad turn must not kill the bridge
                log(f"error handling {message.get('type')}: {e!r}")

    def dispatch(self, message):
        """Push-to-talk is handled at once (recording must start right away); the rest goes to the worker."""
        kind = message.get("type")
        message["received"] = time.time()
        # Play time (plans expire with it): time between game messages, unless the gap means the game was away.
        if self.last_game_message is not None and message["received"] - self.last_game_message < PLAYTIME_GAP:
            self.memory.data["playtime"] = self.memory.data.get("playtime", 0.0) + (message["received"] - self.last_game_message)
        self.last_game_message = message["received"]
        if kind == "memory_load":
            self.set_game_language(message.get("language"))
        if kind == "ptt_start":
            if self.voice is not None:
                self.voice.new_reply()  # V talks over Apiko: it shuts up at once
            if self.ears is not None:
                self.ears.start()
        elif kind in ("world", "story") and time.time() - message.get("t", time.time()) > STALE_WORLD_SECONDS:
            # A bridge started late reads the whole file: old world events and heard lines belong to an earlier
            # moment (2026-11-07: replayed objectives made the quest brief look new and filled every turn).
            return
        elif kind == "world":
            # Local: the diary, and maybe a written line (react, in the worker so the voice doesn't block reading).
            event = message.get("event", "")
            if str(event).startswith("objective|"):
                self.hearing.on_objective()
                self.objective_changed = time.time()
            if self.diary.add(event) and apiko_barks.situation_for(event):
                self.work.put(dict(message, type="world_react"))
        elif kind == "story":
            # Local: what Apiko hears. A conversation that ended may get one remark (an event, with its chance).
            lines = self.hearing.handle(message.get("event", ""))
            if lines is not None and lines >= apiko_world.SCENE_COMMENT_MIN_LINES:
                self.work.put(dict(message, type="event", event="scene_end"))
        elif kind == "ptt_stop":
            if self.ears is not None:
                audio = self.ears.stop()
                if audio is not None:
                    self.work.put(dict(message, type="voice", audio=audio))
        else:
            self.work.put(message)

    # --- written lines ---

    def react(self, message):
        """A device or enemy event: sometimes Apiko says a written line (barks.json, no tokens); rarely the model
        comments it instead. Shares the pause with Apiko's other remarks. Warnings (an enemy netrunner hacking V, a
        sniper...) are urgent: their own short pause and high chance, quickly stale, never the model."""
        situation = apiko_barks.situation_for(message.get("event", ""))
        age = time.time() - message.get("t", time.time())
        if not situation or self.hearing.in_scene():
            return
        if situation in apiko_barks.WARNINGS:
            if age > WARNING_STALE_SECONDS or time.time() - self.last_warning < self.config["warning_cooldown_seconds"]:
                return
            if random.random() > self.config["warning_chance"] * min(1.0, self.config["chatter"]):
                return
            self.last_warning = time.time()
        else:
            if age > STALE_EVENT_SECONDS:
                return
            if time.time() - self.last_spoken < self.config["bark_cooldown_seconds"]:
                return
            if random.random() > self.config["bark_chance"] * self.config["chatter"]:
                return
            if random.random() < self.improvise_chance() and situation not in apiko_barks.WRITTEN_ONLY:
                if situation in apiko_barks.ENEMY_SITUATIONS:
                    event = "enemy_" + situation
                elif situation in apiko_barks.SITUATIONS.values():
                    event = "device_" + situation
                else:
                    event = situation
                log(f"world event to the model (improvised): {event}")
                self.handle({"type": "event", "event": event, "t": time.time(), "rolled": True,
                             "state": self.last_state, "received": time.time()})
                return
        self.say_written(situation, self.last_state)

    def improvise_chance(self):
        """How often the model improvises instead of a written line: the player's setting (APIKO Settings), else
        config.json."""
        value = self.settings.data.get("llm", {}).get("improvise")
        if not isinstance(value, (int, float)):
            value = self.config["bark_llm_chance"]
        return min(1.0, max(0.0, float(value)))

    def say_written(self, situation, state):
        """Says a line from barks.json (no tokens). False when there is none for it."""
        instability = self.instability(state)
        line, lang = self.barks.pick(situation, instability, self.last_lang, self.default_lang)
        if not line:
            return False
        log(f"< {line}  [written line: {situation}, {apiko_barks.tier(instability)}]")
        self.speak(line, lang, instability, cache=True)
        self.last_spoken = time.time()
        self.diary.note_said(line)
        return True

    def event_line(self, event, state, chance_factor=1.0):
        """A chat event from the game (combat, health, time of day, district, a calm moment) as a written line.
        True when it was handled here (a line, or silence); False when the model should improvise it."""
        now = time.time()
        if event == "idle_check":
            # A long silence on both sides, nothing going on: maybe a loose thought (night and rain have their own).
            # Also while V drives (2026-11-08): Apiko talks through the chip.
            quiet = now - max(self.last_spoken, self.last_v_talk)
            if quiet < self.config["idle_seconds"] or state.get("tension") or state.get("in_combat") == "yes":
                return True
            if random.random() > self.config["idle_chance"] * self.config["chatter"]:
                log("idle: a long silence, but Apiko keeps quiet (chance)")
                return True
            options = ["idle"]
            hour = int(str(state.get("time", "12:00")).partition(":")[0] or 12)
            if hour >= 21 or hour < 5:
                options.append("idle_night")
            if "rain" in str(state.get("weather", "")) and "no rain" not in str(state.get("weather", "")):
                options.append("idle_rain")
            situation = random.choice([o for o in options if self.barks.has(o)] or ["idle"])
        elif event == "entered_district":
            situation = apiko_barks.district_situation(state.get("district_keys"), self.barks.lines)
            # Sub-districts of a place with the same lines: nothing new to say.
            previous, self.last_district_line = self.last_district_line, situation
            if not situation or situation == previous:
                log(f"entered_district: quiet ({'no lines' if not situation else 'same place, other sub-district'})")
                return True
        else:
            situation = event
        if event in apiko_barks.URGENT_CHAT:
            if now - self.last_warning < self.config["warning_cooldown_seconds"]:
                return True
            if random.random() > apiko_barks.CHAT_SITUATIONS[event] * min(1.0, self.config["chatter"]):
                return True
            self.last_warning = now
            self.say_written(situation, state)
            return True
        if event != "idle_check":
            if now - self.last_spoken < self.config["bark_cooldown_seconds"]:
                log(f"{event}: quiet (Apiko spoke {now - self.last_spoken:.0f} s ago)")
                return True
            if random.random() > apiko_barks.CHAT_SITUATIONS[event] * self.config["chatter"] * chance_factor:
                log(f"{event}: quiet (chance)")
                return True
        if random.random() < self.improvise_chance():
            return False
        self.say_written(situation, state)
        return True

    # --- memory per save ---

    def save_memory(self):
        """memory.json, a new version snapshot, and the copy for the game (it goes into the next save)."""
        self.memory.save()
        self.memory_version = self.store.commit(self.memory.data)
        self.publish_memory()

    def publish_memory(self):
        text = json.dumps(self.memory.data, ensure_ascii=False, separators=(",", ":"))
        size = len(text.encode("utf-8"))
        path = self.mod_dir / MEMORY_OUT
        tmp = path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(f"{self.memory_token}\t{self.memory_version}\t{size}\n{text}\n")
        for _ in range(20):  # the mod may be reading it
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                time.sleep(0.05)
        log("could not replace memory_out.txt (file locked)")

    def set_game_language(self, code):
        """The game's text language (sent with each save load, e.g. "en-us") is Apiko's default language. Until V
        speaks another one, the written lines (beacon call, first contact, barks) use it. config default_language
        only covers the time before the game reports it."""
        lang = str(code or "").strip().lower()[:2]
        if not lang.isalpha() or lang == self.default_lang:
            return
        if self.last_lang == self.default_lang:
            self.last_lang = lang
        self.default_lang = lang
        log(f"game language: {code} (Apiko's default language is now {lang})")

    def load_memory(self, message):
        """A save was loaded (or the bridge came online during a game): bring back the memory of that save.
        Order: our snapshot of the save's version, else the copy stored in the save. A save without a version: if
        Apiko was never woken there, a fresh Apiko; otherwise (a save from before this system) the current memory."""
        token = str(message.get("token", ""))
        try:
            version = int(message.get("version") or 0)
        except (TypeError, ValueError):
            version = 0
        if token == self.memory_token and version == self.memory_version:
            self.publish_memory()  # repeated announcement (bridge restart): nothing changed
            return
        self.memory_token = token
        data, source = None, ""
        if version > 0:
            data, source = self.store.load(version), "snapshot"
            if data is None and message.get("memory"):
                try:
                    data, source = json.loads(message["memory"]), "copy stored in the save"
                    self.store.save_as(version, data)
                except ValueError:
                    data = None
            if data is None:
                log(f"memory: version {version} of this save not found (no snapshot, no copy); keeping the current one")
        elif not message.get("unlocked"):
            # Apiko not woken here (or the save state not restored yet): never reset on a load. The first wake
            # ("first_wake" event) starts a fresh Apiko.
            log("memory: save without a memory version and Apiko asleep; waiting for its first wake")
            self.diary.clear()
            self.hearing.clear()
            return
        else:
            log("memory: save from before memory versions; it adopts the current memory")
        self.diary.clear()
        self.hearing.clear()
        self.last_state = {}
        if data is not None and source in ("snapshot", "copy stored in the save"):
            # This version was loaded and folded before (the same save reloaded): its fold, without the model.
            folded = self.folded_versions().get(str(version))
            folded_data = self.store.load(folded) if folded else None
            if folded_data is not None:
                version, data, source = folded, folded_data, f"fold of version {version} reused, no model call"
            self.memory.replace(data)
            self.memory.save()
            self.memory_version = version
            self.publish_memory()
            log(f"memory: save loaded, version {version} ({source}); affinity {self.memory.data['affinity']}, "
                f"{len(self.memory.data['facts'])} facts")
            if folded_data is not None:
                self.forget_the_moment(fold=False)
                return
            loaded = version
            if self.forget_the_moment():
                self.remember_fold(loaded, self.memory_version)
            return
        if data is not None:
            self.memory.replace(data)
            log(f"memory: {source}")
        self.forget_the_moment(save=False)
        self.save_memory()

    def forget_the_moment(self, save=True, fold=True):
        """After a save load, what belonged to the moment goes (user, 2026-11-07): the bridge's own readings, and the
        recent conversation, folded into the long-term summary (what was talked about stays; enemy positions, closed
        doors... go). Facts, plans and affinity stay. A folded memory is a new version (it goes into the next save).
        A short conversation (under MIN_FOLD_MESSAGES) stays as history: not worth a model call (2026-11-08).
        True when the conversation was folded."""
        self.objective_changed = 0.0
        self.last_turn_at = 0.0
        self.current_district = ""
        self.visited_districts = {}
        if not fold or len(self.memory.data["history"]) < MIN_FOLD_MESSAGES:
            return False
        if self.compact_history(fold_all=True):
            log("memory: recent conversation folded into the summary after the load")
            if save:
                self.save_memory()
            return True
        return False

    def folded_versions(self):
        try:
            return json.loads(FOLDED_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def remember_fold(self, loaded, folded):
        """The load of version `loaded` was folded into version `folded` (reused on the next load of `loaded`)."""
        mapping = self.folded_versions()
        mapping[str(loaded)] = folded
        mapping = dict(list(mapping.items())[-FOLDED_KEEP:])
        try:
            FOLDED_FILE.write_text(json.dumps(mapping), encoding="utf-8")
        except OSError as e:
            log(f"could not write {FOLDED_FILE.name}: {e!r}")

    def compact_history(self, fold_all=False):
        """When the history is too long, fold its older half into the running summary; `fold_all` (a save load)
        folds all of it. True when the history was folded."""
        history = self.memory.data["history"]
        limit = self.config["history_messages"]
        if fold_all:
            if not history:
                return False
            cut = len(history)
        else:
            if len(history) <= limit:
                return False
            cut = len(history) - limit // 2
        cut -= cut % 2  # keep user/assistant pairs together
        old, keep = history[:cut], history[cut:]
        transcript = "\n".join(f"{'Apiko' if h['role'] == 'assistant' else 'V/event'}: {h['content']}" for h in old)
        data = self.memory.data
        facts = "\n".join("- " + f for f in data["facts"]) or "(none)"
        plans = "\n".join("- " + p["text"] for p in data["plans"]) or "(none)"
        # Consolidation: the same call that folds the history into the summary also cleans the facts and plans
        # (duplicates merged, obsolete and trivial ones dropped, finished plans removed or turned into facts).
        request = [
            {"role": "system", "content": "You maintain the long-term memory of Apiko, an AI companion drone, about "
             "V. Return ONLY a JSON object: {\"summary\": \"...\", \"facts\": [\"...\"], \"plans\": [\"...\"]}. "
             "summary: English, third person about V, at most 180 words; what matters for the relationship: what V "
             "told Apiko, what they did together, promises, insults, jokes, Apiko's memory fragments; never "
             "momentary readings (who stood where, enemy counts, closed doors, health, time). "
             f"facts: lasting facts about V, people in V's life and what V and Apiko lived together; merge "
             f"duplicates, drop trivial, obsolete or invented-sounding ones, at most {MAX_FACTS}, English; keep "
             "each fact's wording and never split one fact into several; never V's questions, places visited, plans "
             "or sensor readings. "
             f"plans: V's current goals and jobs still pending, at most {MAX_PLANS}; drop finished or abandoned ones "
             "(a finished one may become a fact)."},
            {"role": "user", "content": f"Previous summary:\n{data['summary'] or '(empty)'}\n\nFacts:\n{facts}\n\n"
             f"Plans:\n{plans}\n\nNew conversation to fold in:\n{transcript}"},
        ]
        try:
            # Generous cap: a model that reasons first spends part of it thinking, and a cut reply has no summary.
            reply = parse_reply(self.chat(request, json_mode=True, max_tokens=3000, think=False))
        except ProviderError as e:
            log(f"summary failed, keeping full history for now: {e}")
            return False
        summary = str(reply.get("summary") or "").strip()
        if not summary:
            usage = self.last_usage or {}
            log("summary failed (no summary in the reply), keeping full history for now; "
                f"out {usage.get('completion_tokens')} tokens, reasoning "
                f"{(usage.get('completion_tokens_details') or {}).get('reasoning_tokens')}")
            return False
        data["summary"] = summary
        data["history"] = keep
        new_facts = reply.get("facts")
        if isinstance(new_facts, list):
            data["facts"] = [clean_say(f) for f in new_facts if clean_say(f)][:MAX_FACTS]
        new_plans = reply.get("plans")
        if isinstance(new_plans, list):
            since = {p["text"]: p.get("since", data["playtime"]) for p in data["plans"]}
            data["plans"] = [{"text": t, "since": since.get(t, data["playtime"])}
                             for t in (clean_say(p) for p in new_plans) if t][:MAX_PLANS]
        usage = self.last_usage or {}
        cost = usage.get("cost")  # OpenRouter reports it; others do not
        log(f"memory consolidated: summary, {len(data['facts'])} facts, {len(data['plans'])} plans; "
            f"{len(old)} messages folded, tokens in {usage.get('prompt_tokens', '?')} out "
            f"{usage.get('completion_tokens', '?')}" + (f", ${cost:.5f}" if isinstance(cost, (int, float)) else ""))
        return True

    # --- settings ---

    def test(self, what):
        """One quick real call to the chosen service; the result goes back to the settings window."""
        if what not in apiko_providers.KINDS:
            return
        self.check_settings()  # the window saves just before sending the test
        choice = self.settings.choice(what)
        name = f"{choice['label']} ({choice['model']})" if choice["model"] else choice["label"]
        started = time.time()
        try:
            if what == "llm":
                self.chat([{"role": "user", "content": "Reply with the single word OK."}], json_mode=False,
                          max_tokens=50, fallback=False)
            elif what == "stt":
                if self.ears is None:
                    raise ProviderError("voice is off (voice packages missing or voice_enabled false)")
                if choice["id"] == "local":
                    self.ears.load_model()
                else:
                    self.ears.transcribe_remote(choice, self.ears.silence())
            else:
                if self.voice is None:
                    raise ProviderError("voice is off (voice packages missing or voice_enabled false)")
                lang = self.voice.language(self.default_lang)
                line = "Hola, soy Apiko. ¿Me oyes bien?" if lang == "es" else "Hi, I'm Apiko. Can you hear me?"
                audio, rate = self.voice.render(line, lang, 0.2, strict=True)
                generation = self.voice.new_reply()
                self.voice.queue_chunk(generation, audio, rate,
                                       lambda: self.write_reply("say", line, len(audio) / rate + 0.6))
        except Exception as e:
            log(f"test {what}: {name} failed: {e}")
            self.write_reply("test", f"{what}|error|{name}: {e}"[:300])
            return
        log(f"test {what}: {name} ok ({time.time() - started:.1f}s)")
        self.write_reply("test", f"{what}|ok|{name}: OK ({time.time() - started:.1f} s)")

    def check_settings(self):
        with self.settings_lock:  # main loop and test runs (worker) both call this
            if not self.settings.check():
                return
        log(f"settings reloaded: {self.settings.describe()}")
        for component in (self.voice, self.ears):
            if component is not None:
                component.settings_changed()
        self.warn_missing()

    def warn_missing(self):
        problem = apiko_providers.missing(self.settings.choice("llm"))
        if problem:
            log(problem)
            self.write_reply("status", problem)

    def still_owner(self):
        """Only one bridge may run: two answered every line twice (2026-11-07). The newest one wins; an older one
        sees another token in the owner file and stops."""
        try:
            return OWNER_FILE.read_text(encoding="utf-8").strip() == self.owner_token
        except OSError:
            return True

    def run(self):
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        self.owner_token = f"{os.getpid()}-{time.time()}"
        OWNER_FILE.write_text(self.owner_token, encoding="utf-8")
        threading.Thread(target=self.heartbeat, daemon=True).start()
        threading.Thread(target=self.worker, daemon=True).start()
        threading.Thread(target=self.session_watch, daemon=True).start()
        log(f"APIS-K0 bridge running: {self.settings.describe()}. Voice: {'on' if self.voice else 'off'}. "
            f"Affinity: {self.memory.data['affinity']}. Ctrl+C to stop.")
        self.warn_missing()
        next_settings_check = 0.0
        # What the file already holds was sent before this bridge started (an earlier game, or the moments before a
        # crash or restart): only its latest save load is used, to know which memory is in play. Replaying the rest
        # replayed the first contact on the next game start (2026-11-08) and could reset the memory.
        loads = [m for m in self.read_new_messages() if m.get("type") == "memory_load"]
        if loads:
            self.dispatch(loads[-1])
        try:
            while True:
                messages = self.read_new_messages()
                # Only the latest save load of a batch counts: an older one must not reset the memory before the
                # current one is restored.
                loads = [m for m in messages if m.get("type") == "memory_load"]
                for message in messages:
                    if message.get("type") != "memory_load" or message is loads[-1]:
                        self.dispatch(message)
                if time.time() >= next_settings_check:
                    next_settings_check = time.time() + 1.0
                    if not self.still_owner():
                        log("another bridge was started: this one stops")
                        break
                    self.check_settings()
                time.sleep(POLL_SECONDS / 2)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            # The alive file belongs to the newer bridge when this one was replaced.
            if self.still_owner():
                try:
                    (self.mod_dir / ALIVE_FILE).unlink()
                except OSError:
                    pass
            log("bridge stopped")


if __name__ == "__main__":
    # Glitch characters must not crash a console with a legacy code page.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    moved = apiko_paths.migrate_from_source_folder()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    # The log grows with every session: past LOG_MAX_BYTES it is kept as bridge.old.log and a new one starts.
    try:
        if LOG_FILE.stat().st_size > LOG_MAX_BYTES:
            LOG_FILE.replace(LOG_FILE.with_suffix(".old.log"))
    except OSError:
        pass
    if moved:
        log(f"moved {', '.join(moved)} to {apiko_paths.USER_DIR}")
    if "--selftest" in sys.argv:
        import apiko_selftest
        config = load_config()
        game_dir = apiko_paths.mod_dir(config)
        sys.exit(apiko_selftest.run(config, apiko_providers.Settings(game_dir, config, log), log))
    Bridge(load_config()).run()
