"""APIS-K0 phase 4: Apiko's written lines (barks.json) for world events, spoken without asking the model.

A world event from the game (a camera spotted V, an alarm, a breach, an enemy detected V, a stealth kill, a
warning...) maps to a situation; the line is picked by
the instability tier and V's language, never repeating one until all of that situation, tier and language were
used. Reviewed text, zero tokens; the bridge decides when Apiko speaks (chance, shared pause, rare model turns).
"""

import json
import random
from pathlib import Path

BARKS_FILE = Path(__file__).resolve().parent / "barks.json"

# Diary action (from the game's world events) -> situation in barks.json.
SITUATIONS = {
    "spotted": "spotted",
    "hostile": "hostile",
    "alarm": "alarm",
    "breached": "breached",
    "pinged": "pinged",
    "destroyed": "destroyed",
    "hacked": "hacked",
}

# Enemy events (ApisK0Enemies.reds). Warnings are urgent: their own short pause, never the model.
WARNINGS = ("warn_netrunner", "warn_sniper", "warn_behind", "warn_elite",
            # V's wanted level rose (ApisK0People.reds): urgent like the others, but it goes to the diary too.
            "heat_up")
ENEMY_SITUATIONS = ("detected", "stealth_kill", "knockout")
# V entered a restricted or hostile security area: always a written line, never the model (user, 2026-11-07).
WRITTEN_ONLY = ("zone_restricted", "zone_dangerous",
                # A fight between others started close by (ApisK0Surroundings.reds).
                "fight_close")

# Everything that needs no talk with V and no concrete information is a written line (user, 2026-11-07); the
# model only improvises one now and then (the player's "improvise" setting). The game's chat events that became
# written lines, with their own chance (times "chatter"). low_health is urgent: it goes like a warning.
CHAT_SITUATIONS = {
    "combat_start": 0.5,
    "combat_end": 0.6,
    "nightfall": 0.4,
    "dawn": 0.4,
    "low_health": 0.8,
    # A new district (V gets there on foot or gets out of the car in it): almost always worth a line.
    "entered_district": 0.9,
}
URGENT_CHAT = ("low_health",)
# District lines: the most specific district with lines of its own wins (Dogtown and Kabuki before Pacifica and
# Watson); "district" is the generic fallback. Keys are the game's untranslated district names, lowercased.
DISTRICT_LINES = ("watson", "kabuki", "westbrook", "japantown", "citycenter", "heywood", "santodomingo", "pacifica",
                  "dogtown", "badlands")
# Long silence (no word from either side, no tension): a loose thought. Night and rain have their own lines.
IDLE_SITUATIONS = ("idle", "idle_night", "idle_rain")


def district_situation(keys, lines):
    """The district situation for the state's "district_keys" ("Kabuki,Watson"), most specific first."""
    for key in str(keys or "").split(","):
        name = "district_" + key.strip().lower()
        if key.strip().lower() in DISTRICT_LINES and name in lines:
            return name
    return "district" if "district" in lines else None


def situation_for(event):
    """The barks.json situation for a world event ("action|kind|detail"), or None (no line for it)."""
    action, _, rest = str(event).partition("|")
    kind = rest.partition("|")[0]
    detail = rest.partition("|")[2]
    if action in SITUATIONS:
        return SITUATIONS[action]
    if action in WARNINGS or action == "detected":
        return action
    # What V did (2026-11-07): a police officer killed (before the stealth check), a civilian killed, a boss down,
    # the police shaken off, a body hidden.
    if action == "killed" and kind == "NCPD":
        return "police_killed"
    if action == "civilian" and kind == "killed":
        return "civilian_killed"
    if action in ("boss_down", "heat_lost", "body_hidden", "sms"):
        return action
    # Missions: a cold judgment, never the quest's name.
    if action == "quest" and detail in ("completed", "failed"):
        return "quest_done" if detail == "completed" else "quest_failed"
    if action == "killed" and detail == "stealth":
        return "stealth_kill"
    if action == "knocked_out":
        return "knockout"
    if action == "heat":
        return "heat_up"
    if action == "fight":
        # Only a fight starting close by gets a line; one farther away only goes to the diary.
        return "fight_close" if detail == "close" else None
    if action == "zone":
        kind = rest.partition("|")[0]
        return "zone_" + kind if kind in ("restricted", "dangerous") else None
    return None


def tier(instability):
    if instability < 0.3:
        return "calm"
    return "cracked" if instability <= 0.6 else "unhinged"


class Barks:
    def __init__(self, log):
        self.log = log
        self.decks = {}  # (situation, tier, lang) -> lines not said yet, shuffled
        try:
            with open(BARKS_FILE, encoding="utf-8") as f:
                self.lines = {k: v for k, v in json.load(f).items() if not k.startswith("_")}
        except (OSError, ValueError) as e:
            log(f"barks.json not loaded, no written lines: {e!r}")
            self.lines = {}

    def has(self, situation):
        return situation in self.lines

    def pick(self, situation, instability, lang, fallback_lang):
        """A line for this situation, or None. Unknown languages use `fallback_lang` (the default one), else
        English."""
        level = tier(instability)
        by_lang = self.lines.get(situation, {}).get(level, {})
        if lang not in by_lang:
            for candidate in (fallback_lang, "en"):
                if candidate in by_lang:
                    lang = candidate
                    break
            else:
                lang = next(iter(by_lang), None)
        if not lang:
            return None, None
        key = (situation, level, lang)
        if not self.decks.get(key):
            deck = list(by_lang[lang])
            random.shuffle(deck)
            self.decks[key] = deck
        return self.decks[key].pop(), lang
