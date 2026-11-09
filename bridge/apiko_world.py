"""APIS-K0 phase 4: what Apiko perceives of the world, turned into as few tokens as possible.

- Diary: world events from the game ("action|kind|detail": V hacked or used a device, a camera spotted V, a turret
  turned hostile, an alarm went off, a device was destroyed, V breached a network). Kept for DIARY_SECONDS and
  aggregated ("V hacked 3 cameras"). Nothing here calls the model: the diary is only read when a turn happens.
- Devices: the game's "devices=" state line ("id,kind,category,meters,direction,flags" entries joined by ";").
  The model gets one summary line when security devices are around, and the full list (with ids, for V's orders in
  a later piece) only when V's words are about the surroundings.
- Enemies: the game's "enemies=" state line (see parse_enemies). Same idea: one summary line per place ("here" /
  "elsewhere") when enemies are around, the full cards only when V asks about them. V's kills go to the diary;
  warnings (warn_*) only trigger written lines and are never stored.
- Story (piece 4): the tracked quest comes as plain sensors ("quest=", "objective="); new objectives, quests
  started/completed/failed and text messages go to the diary. Hearing keeps the transcript of the last conversation
  V had and the latest TV/radio news, and knows when V is in a conversation (Apiko keeps quiet then).
"""

import json
import re
import threading
import time
import unicodedata
from pathlib import Path

DIARY_SECONDS = 600
DIARY_LINES = 6  # tokens: the 6 latest are enough context (2026-11-07)
SECURITY = 0
ONE_SHOT_ACTIONS = ("pinged", "breached", "alarm")
REPEAT_SECONDS = 10
SAID_SECONDS = 120
# Hearing: lines further apart than this start a new conversation; the last one is kept, up to SCENE_LINES lines,
# and shown for HEARD_SECONDS (the last SCENE_LINES_SHORT lines unless V asks about it).
SCENE_GAP_SECONDS = 60
SCENE_LINES = 12
SCENE_LINES_SHORT = 4
HEARD_SECONDS = 600
NEWS_LINES = 2
NEWS_CHARS = 160
# A conversation with fewer lines than this is not worth a remark when it ends.
SCENE_COMMENT_MIN_LINES = 3
# A conversation that never ended (a lost "scene|end") stops silencing Apiko after this long without lines.
SCENE_STUCK_SECONDS = 180
# An objective change this soon after a conversation means the conversation led to it.
LED_SECONDS = 45
# A settled conversation (earlier objective) can still be asked about for this long.
PAST_SECONDS = 1800
# Objective marker closer than this: V is at the objective.
AT_OBJECTIVE_METERS = 40
FOCUS_DESCRIPTION_CHARS = 200

# V's words about what was said: the full transcript of the last conversation.
ASKS_CONVERSATION = re.compile(
    r"\b(dijo|dicho|dice|decía|habl\w*|conversaci\w*|charla|llamad\w*|llam\w*|mensaje\w*|sms|opinas|crees|parece|"
    r"noticias?|tele|radio|said|says|told|talk\w*|conversation|call\w*|messages?|texts?|think|news|tv|radio)\b",
    re.IGNORECASE)
# V's words that ask for the detailed device list: questions about the surroundings and orders on devices.
ASKS_DEVICES = re.compile(
    r"\b(c[aá]maras?|torretas?|francotirador\w*|alarmas?|dispositivos?|aparatos?|hacke\w*|jacke\w*|hack\w*|"
    r"puertas?|verjas?|red|redes|punto de acceso|terminal\w*|ordenador\w*|m[aá]quinas?|altavo\w*|explosiv\w*|pantallas?|teles?|televis\w*|radios?|carteles?|sem[aá]foros?|"
    r"alrededor|cerca|aqu[ií]|ves|apaga\w*|enciende|distrae\w*|vigil\w*|seguridad|"
    r"cameras?|turrets?|snipers?|alarms?|devices?|doors?|gates?|network|access point|terminals?|computers?|"
    r"machines?|speakers?|explosives?|screens?|tvs?|radios?|billboards?|signs?|traffic lights?|around|nearby|see|turn off|switch off|distract\w*|security)\b",
    re.IGNORECASE)

# V's words that ask for the detailed enemy cards: questions about people around and threats, orders about them.
# Generic words (who, guy, see, near...) were dropped: a question about a conversation brought the enemies up.
ASKS_ENEMIES = re.compile(
    r"\b(enemig\w*|alguien|nadie|guardias?|bandas?|pandiller\w*|matones|someone|anyone|nobody|"
    r"netrunners?|francotirador\w*|jefes?|amenazas?|peligr\w*|hostil\w*|armad\w*|vigil\w*|combat\w*|pelea\w*|"
    r"enemy|enemies|guards?|gang\w*|thugs?|snipers?|boss|threats?|danger\w*|hostiles?|armed|fight\w*)\b",
    re.IGNORECASE)

# V's words asking what to do or about the job: the focus line then carries the quest details.
ASKS_PLAN = re.compile(
    r"\b(qu[eé] hac\w*|ahora qu[eé]|y ahora|siguiente|d[oó]nde|ad[oó]nde|misi[oó]n|encargo|objetivo|plan|trabajo|"
    r"c[oó]mo (entro|entramos|lo hago|lo hacemos|sigo|seguimos)|ayuda|"
    r"what now|what do (i|we)|what next|next|where|mission|job|gig|objective|plan|how do (i|we)|help)\b",
    re.IGNORECASE)

# Piece 6: V's words about bodies and vehicles.
ASKS_BODIES = re.compile(r"\b(cuerpos?|cad[aá]ver\w*|muertos?|escond\w*|rastro|bodies|body|corpses?|hide|hidden)\b",
                         re.IGNORECASE)
ASKS_VEHICLES = re.compile(r"\b(coches?|moto\w*|veh[ií]cul\w*|av|cars?|bikes?|vehicles?|ride)\b", re.IGNORECASE)

# V's words about food, drinks or shopping: the vendors near.
ASKS_SHOP = re.compile(
    r"\b(comer|comida|comemos|hambre|beber|bebida\w*|tienda\w*|vendedor\w*|venden|comprar|compro|compramos|"
    r"ripperdoc\w*|matasanos|armer\w*|ropa|puestos?|eat|eating|food|hungry|drinks?|buy|shop\w*|stores?|vendors?|"
    r"clothes|stalls?)\b",
    re.IGNORECASE)

# V's words about people that are not enemies: the crowd, the police, someone there.
ASKS_PEOPLE = re.compile(
    r"\b(gente|alguien|nadie|personas?|civil\w*|testigos?|polic[ií]\w*|poli|polis|ncpd|maxtac|multitud|"
    r"qui[eé]n(es)?|people|someone|anyone|nobody|civilians?|witness\w*|police|cops?|crowd|who)\b",
    re.IGNORECASE)

# Game names (gamedataAffiliation) that read badly as they come.
FACTIONS = {
    "TygerClaws": "Tyger Claws", "SixthStreet": "6th Street", "SixthStreetAndroid": "6th Street android",
    "VoodooBoys": "Voodoo Boys", "TheMox": "The Mox", "KangTao": "Kang Tao", "AfterlifeMercs": "Afterlife mercs",
    "MaelstromAndroid": "Maelstrom android", "ScavengersAndroid": "Scavengers android",
    "WraithsAndroid": "Wraiths android", "Wraiths_Former": "former Wraiths", "NCPrison": "NC prison",
    "TraumaTeam": "Trauma Team", "CityCouncil": "City Council", "UnaffiliatedCorpo": "corpo",
    "Unaffiliated": "unaffiliated", "Unknown": "unknown", "corpbud": "corpo", "OA": "Arasaka", "SSI": "SSI",
    "NUSA": "NUSA", "REDACTED": "unknown", "RecordingAgency": "recording agency", "SouthCalifornia": "SoCal",
}
AWARENESS = {"combat": "fighting", "searching": "searching", "fleeing": "fleeing",
             "suspicious": "getting suspicious of V", "calm": "unaware of V"}
NOTABLE_THREATS = ("elite", "boss", "maxtac")


def faction_name(name):
    return FACTIONS.get(name, name)


def weapon_name(item_type):
    """"Wea_AssaultRifle" -> "assault rifle"."""
    name = item_type[4:] if item_type.startswith("Wea_") else item_type
    return " ".join(w.lower() for w in re.findall(r"[A-Z][a-z]+|[A-Z]+(?![a-z])|\d+", name)) or name.lower()


def _enemy_label(kind):
    """Event kinds come as "<faction> <role>" or "<faction> <threat> <role>": humanize the faction."""
    faction, _, rest = kind.partition(" ")
    return (faction_name(faction) + (" " + rest if rest else "")).strip()


def _humanize(name):
    """Game action class names ("QuickHackDistraction", "ToggleON") as plain words ("distraction", "toggle on")."""
    for prefix in ("QuickHack", "Action"):
        if name.startswith(prefix) and len(name) > len(prefix):
            name = name[len(prefix):]
    words = re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+", name)
    return " ".join(w.lower() for w in words) or name.lower()


def _plural(kind):
    return kind + ("es" if kind.endswith(("x", "s")) else "s")


def _count(n, kind):
    if n == 1:
        return ("an " if kind[0] in "aeiou" else "a ") + kind
    return f"{n} {_plural(kind)}"


def _age(seconds):
    return "just now" if seconds < 60 else f"{int(seconds // 60)} min ago"


class Diary:
    def __init__(self, log):
        self.log = log
        self.lock = threading.Lock()
        self.entries = {}  # (action, kind, detail) -> [count, last time]
        # Apiko's last written line (barks.json) and when: only that one, and only for SAID_SECONDS, reaches the
        # model (so "what did you say?" works, for a few tokens).
        self.last_said = None

    def clear(self):
        """Another save was loaded: what happened in the last minutes belongs to another timeline."""
        with self.lock:
            self.entries.clear()
            self.last_said = None

    def note_said(self, line):
        with self.lock:
            self.last_said = (line, time.time())

    def add(self, event):
        """Records an event ("action|kind|detail"). Returns the action when it is new (not a repeat or ignored),
        so the bridge can react to it; None otherwise."""
        parts = (str(event).split("|") + ["", "", ""])[:3]
        action, kind, detail = (p.strip() for p in parts)
        # Routine uses (doors, vending machines...) say nothing about V, and doors are ignored altogether (user,
        # 2026-11-06): Apiko told V "you opened nine doors".
        if not action or action == "used" or kind == "door":
            return None
        # Warnings are for the moment only: a written line, never the diary.
        if action.startswith("warn_"):
            self.log(f"world: {action} {kind} {detail}".rstrip())
            return action
        if action in ("killed", "knocked_out", "detected", "boss_down"):
            # boss_down: the boss's own name, or its faction.
            kind = faction_name(kind) if action == "boss_down" else _enemy_label(kind)
        if action in ("hacked", "used") and detail:
            detail = _humanize(detail)
        elif action in ("breached", "pinged"):
            detail = ""  # number of devices exposed: only logged
        now = time.time()
        with self.lock:
            entry = self.entries.get((action, kind, detail))
            # One ping, breach or alarm can reach us many times at once (a save load re-applies the Ping status to
            # every pinged NPC): repeats within REPEAT_SECONDS are the same event.
            if entry and action in ONE_SHOT_ACTIONS and now - entry[1] < REPEAT_SECONDS:
                return None
            entry = self.entries.setdefault((action, kind, detail), [0, now])
            entry[0] += 1
            entry[1] = now
        if action != "said":
            self.log(f"world: {action} {kind} {detail}".rstrip())
        return action

    def describe(self):
        """One line with the latest events, newest first, or "" when nothing happened lately."""
        now = time.time()
        with self.lock:
            for key in [k for k, (_, last) in self.entries.items() if now - last > DIARY_SECONDS]:
                del self.entries[key]
            # Routine uses (doors, vending machines) never push out what matters.
            items = sorted(self.entries.items(), key=lambda item: (item[0][0] == "used", -item[1][1]))[:DIARY_LINES]
        lines = []
        for (action, kind, detail), (count, last) in items:
            what = _count(count, kind)
            if action == "hacked":
                text = f"V hacked {what}" + (f" ({detail})" if detail else "")
            elif action == "used":
                text = f"V used {what}" + (f" ({detail})" if detail else "")
            elif action == "spotted":
                text = f"{what} spotted V"
            elif action == "hostile":
                text = f"{what} turned hostile"
            elif action == "alarm":
                text = f"{what} went off"
            elif action == "destroyed":
                text = f"{what} destroyed"
            elif action == "breached":
                text = "V breached a local network" + (f" {count} times" if count > 1 else "")
            elif action == "pinged":
                text = "V pinged a local network" + (f" {count} times" if count > 1 else "")
            elif action in ("killed", "knocked_out"):
                who = f"a {kind} enemy" if count == 1 else f"{count} {kind} enemies"
                how = {"stealth": " unseen, in stealth", "quickhack": " with quickhacks", "melee": " in melee",
                       "explosive": " with explosives", "thrown": " with thrown weapons"}.get(detail, "")
                text = ("V killed " if action == "killed" else "V knocked out (non-lethal) ") + who + how
            elif action == "detected":
                text = f"{_count(count, kind)} detected V and attacked"
            elif action == "boss_down":
                text = f"V took down {kind}" + (" and killed them" if detail == "killed" else " without killing them")
            elif action == "objective":
                text = f"new objective" + (f' in "{kind}"' if kind else "") + f": {detail}"
            elif action == "quest":
                text = f'quest "{kind}" {detail}'
            elif action == "fight":
                text = f"a fight broke out {'close by' if detail == 'close' else 'nearby'}, not involving V ({kind.replace(' vs ', ' against ')})"
            elif action == "heat":
                text = f"NCPD wanted level rose to {kind} star" + ("" if kind == "1" else "s")
            elif action == "heat_lost":
                text = "V lost the NCPD (wanted level back to zero)"
            elif action == "body_hidden":
                text = "V hid a body" if count == 1 else f"V hid {count} bodies"
            elif action == "civilian":
                text = ("V killed " if kind == "killed" else "V hurt ") + ("a civilian" if count == 1 else f"{count} civilians")
            elif action == "zone":
                text = "V entered " + ("a hostile area (they shoot on sight)" if kind == "dangerous"
                                       else "a restricted area (trespassing)")
            elif action == "sms":
                text = f'{kind} texted V: "{detail[:120]}"'
            else:
                text = f"{action} {what}"
            lines.append(f"{text}, {_age(now - last)}")
        with self.lock:
            said = self.last_said
        if said and now - said[1] <= SAID_SECONDS:
            lines.append(f'you said "{said[0]}", {_age(now - said[1])}')
        if not lines:
            return ""
        return "[recent around V, last 10 min] " + "; ".join(lines)


class Hearing:
    """What Apiko hears through the game's subtitles: the last conversation V had (lines of scenes and calls V takes
    part in) and the latest TV/radio news. Also whether V is in a conversation right now."""

    def __init__(self, log):
        self.log = log
        self.lock = threading.Lock()
        self.scene = []  # (speaker, text, time) of the last conversation
        # "current"; "led" (the objective changed right after it: it led to the current objective); "past" (the
        # objective changed later: settled, shown only when V asks about it).
        self.scene_status = "current"
        self.news = []  # (speaker, text, time), newest last
        self.in_scene_since = None

    def clear(self):
        with self.lock:
            self.scene = []
            self.scene_status = "current"
            self.news = []
            self.in_scene_since = None

    def on_objective(self):
        """The tracked objective changed. A conversation going on or just ended led to it; an older one (or one that
        already led to the previous objective) is now history."""
        with self.lock:
            if not self.scene:
                return
            recent = self.in_scene_since is not None or time.time() - self.scene[-1][2] <= LED_SECONDS
            status = "led" if recent and self.scene_status == "current" else "past"
            if status != self.scene_status:
                self.scene_status = status
                self.log(f"last conversation is now '{status}' (objective changed)")

    def scene_note(self):
        """For the focus line: how the last conversation relates to the current objective, or ""."""
        with self.lock:
            if not self.scene or time.time() - self.scene[-1][2] > HEARD_SECONDS:
                return ""
            who = sorted({s for s, _, _ in self.scene if s and s != "V"})
            with_whom = f" with {', '.join(who)}" if who else ""
            if self.scene_status == "led":
                return f"the last conversation{with_whom} led to the current objective"
            if self.scene_status == "past":
                return f"the conversation{with_whom} belongs to an earlier objective: settled, don't bring it up"
            return ""

    def handle(self, event):
        """A "story" message from the game. Returns the number of lines of a conversation that just ended, else None."""
        parts = str(event).split("|", 3)
        now = time.time()
        if parts[0] == "heard" and len(parts) == 4:
            kind, speaker, text = parts[1], parts[2].strip(), parts[3].strip()
            if not text:
                return None
            with self.lock:
                if kind == "conv":
                    # The game sometimes shows the same line twice a few seconds apart.
                    if self.scene and self.scene[-1][:2] == (speaker, text) and now - self.scene[-1][2] < REPEAT_SECONDS:
                        return None
                    if self.scene and (now - self.scene[-1][2] > SCENE_GAP_SECONDS or self.scene_status == "past"):
                        self.scene = []
                    if not self.scene:
                        self.scene_status = "current"
                    self.scene.append((speaker, text, now))
                    del self.scene[:-SCENE_LINES]
                elif kind == "news":
                    # Commercials ("ad_mrstud", "ad_foreign_body"...) are noise, not news.
                    if speaker.lower().startswith("ad_"):
                        return None
                    if len(text) > NEWS_CHARS:
                        text = text[:NEWS_CHARS].rsplit(" ", 1)[0] + "..."
                    if not any(t == text for _, t, _ in self.news):
                        self.news.append((speaker, text, now))
                        del self.news[:-NEWS_LINES]
            self.log(f"heard ({kind}) {speaker or '?'}: {text}")
        elif parts[0] == "scene" and len(parts) > 1:
            if parts[1] == "start":
                with self.lock:
                    self.in_scene_since = now
                self.log("conversation started: Apiko keeps quiet")
            elif parts[1] == "end":
                with self.lock:
                    self.in_scene_since = None
                try:
                    lines = int(parts[2]) if len(parts) > 2 else 0
                except ValueError:
                    lines = 0
                self.log(f"conversation ended ({lines} lines)")
                return lines
        return None

    def in_scene(self):
        with self.lock:
            if self.in_scene_since is None:
                return False
            last = max([self.in_scene_since] + [t for _, _, t in self.scene[-1:]])
            return time.time() - last < SCENE_STUCK_SECONDS

    def describe(self, full, plan=False):
        """The last conversation and the latest news (`full`: V asks about them, or the conversation just ended), or
        the end of a conversation that led to the current objective (`plan`: V asks what to do); else ""."""
        now = time.time()
        with self.lock:
            scene = list(self.scene)
            status = self.scene_status
            news = [n for n in self.news if now - n[2] <= HEARD_SECONDS]
        lines = []
        # Tokens (2026-11-07): the transcript only when V asks about it or it just ended (`full`), or its last lines
        # when V asks what to do and it led to the current objective (`plan`). A settled one only when asked.
        wanted = full or (plan and status == "led")
        if scene and wanted and now - scene[-1][2] <= (PAST_SECONDS if status == "past" else HEARD_SECONDS):
            shown = scene if full else scene[-SCENE_LINES_SHORT:]
            cut = "" if len(shown) == len(scene) else f", last {len(shown)} of {len(scene)} lines"
            transcript = " / ".join(f"{s or '?'}: {t}" for s, t, _ in shown)
            label = {"led": "; it led to the current objective",
                     "past": "; from an earlier objective, settled"}.get(status, "")
            lines.append(f"[last conversation V had, {_age(now - scene[-1][2])}{cut}{label}; overheard] "
                         + transcript)
        if news and full:
            lines.append("[heard on TV/radio lately] " + " / ".join(f"{s or 'news'}: {t}" for s, t, _ in news))
        return "\n".join(lines)


def describe_people(state, asked, asks_shop=False):
    """"[people around V]": named characters here, companions, police and the wanted level, panic and witnesses, and
    how busy the place is. Only when something there matters or V asks about people; vendors near when V asks
    about people, food or shopping. "" otherwise."""
    items = []
    if state.get("vendors_near") and (asked or asks_shop):
        items.append("vendors near: " + state["vendors_near"].replace(" / ", ", "))
    elif asks_shop:
        items.append("no vendor within 40 m (there may be some farther away)")
    if state.get("named_here"):
        items.append("here: " + state["named_here"].replace(" / ", ", "))
    if state.get("companions"):
        items.append("following V: " + state["companions"].replace(" / ", ", "))
    if state.get("wanted_stars"):
        items.append(f"NCPD wanted level {state['wanted_stars']} of 5 stars")
    # Police around is ordinary background: it matters only with a wanted level or witnesses, or when V asks.
    if state.get("police") and (asked or state.get("wanted_stars") or state.get("witnesses")):
        items.append("police Apiko perceives: " + state["police"])
    if state.get("witnesses"):
        items.append(f"{state['witnesses']} civilians saw V (they call NCPD)")
    if state.get("crowd_panic"):
        items.append(f"{state['crowd_panic']} civilians panicking")
    if not items and not asked:
        return ""
    crowd = {"crowded": "a crowd around", "a few people": "a few people around", "empty": "nobody else around"}.get(
        state.get("crowd", ""), "")
    if crowd:
        items.append(crowd)
    return "[people around V] " + "; ".join(items) if items else ""


LORE_FILE = Path(__file__).resolve().parent / "lore.json"
LORE_MAX = 3  # entries per turn (tokens)


def _plain(text):
    """Lowercase without accents, for matching V's words against lore keys."""
    return "".join(c for c in unicodedata.normalize("NFD", str(text).lower()) if unicodedata.category(c) != "Mn")


class Lore:
    """Night City's public Net as Apiko finds it (lore.json): never the game's plot. Only the entries whose keys V
    mentions reach the model, and only those Night City already knows in this save (quest gates)."""

    def __init__(self, log):
        self.log = log
        try:
            data = json.loads(LORE_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log(f"lore.json not loaded, Apiko knows no public lore: {e!r}")
            data = {}
        self.gates = {name: set(ids) for name, ids in (data.get("gates") or {}).items()}
        self.entries = []
        for entry in data.get("entries") or []:
            pattern = "|".join(re.escape(_plain(k)) for k in entry.get("keys") or [])
            if pattern:
                self.entries.append(dict(entry, match=re.compile(rf"(?<!\w)({pattern})(?!\w)")))
        self.last_done = None

    def done_gates(self, state):
        done = set(str(state.get("quests_done", "")).split(","))
        gates = {name for name, ids in self.gates.items() if ids & done}
        if gates != self.last_done:
            self.last_done = gates
            self.log(f"lore: story gates passed in this save: {', '.join(sorted(gates)) or 'none'}")
        return gates

    def describe(self, words, state):
        """"[found on the Net]" with the entries V's words touch (most recent words first), or ""."""
        text = _plain(words)
        if not text.strip():
            return ""
        gates = self.done_gates(state)
        found = []
        for entry in self.entries:
            if entry.get("after") and entry["after"] not in gates:
                continue
            if entry.get("until") and entry["until"] in gates:
                continue
            hit = entry["match"].search(text)
            if hit:
                found.append((hit.start(), entry))
        found.sort(key=lambda item: item[0])
        lines = [entry["text"] for _, entry in found[:LORE_MAX]]
        if not lines:
            return ""
        self.log(f"lore: {', '.join(entry['id'] for _, entry in found[:LORE_MAX])}")
        return "[found on the Net: public info, use it as your own knowledge] " + " | ".join(lines)


def describe_surroundings(state, turn):
    """"[around V]" (piece 6): other people's fights and notable loot always; bodies V left with tension or when
    asked; vehicles (V's own only when asked). "" when nothing qualifies. `turn` is V's
    words ("" for events)."""
    items = []
    if state.get("fight_nearby"):
        sides, _, rest = state["fight_nearby"].partition(", ")
        sides = " against ".join(faction_name(f) for f in sides.split(" vs "))
        items.append(f"fight not involving V: {sides}" + (f", {rest}" if rest else ""))
    if state.get("notable_loot"):
        items.append("notable loot in view: " + state["notable_loot"])
    if state.get("bodies") and (state.get("tension") or ASKS_BODIES.search(turn)):
        items.append("bodies: " + state["bodies"])
    if state.get("vehicles"):
        asked = bool(ASKS_VEHICLES.search(turn))
        vehicles = [v for v in state["vehicles"].split(", ") if asked or v != "V's own vehicle"]
        if vehicles:
            items.append("vehicles near: " + ", ".join(vehicles))
    return "[around V] " + "; ".join(items) if items else ""


def describe_focus(state, scene_note, enemies_around, detailed=True):
    """"[what matters now]": the bridge's own ranking of what is current, for the model to choose what to say (never
    to recite): tension first, then the tracked objective (where V is relative to it; what the job is and what is
    done only when `detailed`: V asks what to do, the objective just changed or a conversation ended), then what
    is settled or irrelevant."""
    items = []
    tension = state.get("tension", "")
    if "combat" in tension:
        items.append("combat: V's survival comes first")
    elif tension:
        items.append(f"tension: {tension}")
    objective = state.get("objective", "")
    try:
        meters = int(state.get("objective_meters", ""))
    except ValueError:
        meters = None
    at_objective = meters is not None and meters <= AT_OBJECTIVE_METERS
    # The objective only when it helps: V asks what to do, it just changed, a conversation ended, or V is at it.
    # Always there, the model kept pushing V towards it ("your objective is 1.5 km away", 2026-11-07).
    if objective and (detailed or at_objective):
        quest = state.get("quest", "")
        kind = state.get("quest_type", "job")
        line = f'objective "{objective}"' + (f' ({kind} "{quest}")' if quest else "")
        if meters is not None:
            line += ("; V is there now" if meters <= AT_OBJECTIVE_METERS
                     else f"; its marker is {meters} m away" if meters < 1000 else f"; its marker is {meters / 1000:.1f} km away")
        items.append(line)
        done = state.get("objectives_done", "") if detailed else ""
        if done:
            items.append(f"steps already completed (finished, never suggest them): {done}")
        description = state.get("quest_description", "") if detailed else ""
        if description:
            # Journal texts come with literal "\n" and fixer chatter: one line, short.
            description = re.sub(r"\s+", " ", description.replace("\\n", " ")).strip()
            if len(description) > FOCUS_DESCRIPTION_CHARS:
                description = description[:FOCUS_DESCRIPTION_CHARS].rsplit(" ", 1)[0] + "..."
            items.append(f"background of the job (context only; the current objective is what counts now): {description}")
    elif not objective and detailed:
        items.append("no tracked objective")
    if scene_note:
        items.append(scene_note)
    if enemies_around and not tension:
        items.append("enemies nearby are no threat right now: not worth mentioning")
    if not items:
        return ""
    return ("[what matters now; to choose what to say, never recite it; earlier turns' readings are stale] "
            + "; ".join(items))


def parse_devices(line):
    devices = []
    for entry in str(line or "").split(";"):
        fields = entry.split(",")
        if len(fields) < 6:
            continue
        try:
            category, meters = int(fields[2]), int(fields[3])
        except ValueError:
            continue
        devices.append({"id": fields[0], "kind": fields[1], "category": category, "meters": meters,
                        "direction": fields[4], "flags": fields[5].split()})
    return devices


def _security_groups(devices):
    """Security devices by kind, with counts of each state and where they are (above/below)."""
    groups = {}
    for d in devices:
        if d["category"] != SECURITY:
            continue
        group = groups.setdefault(d["kind"], {"n": 0, "watching-V": 0, "hostile": 0, "ringing": 0, "off": 0,
                                              "levels": set()})
        group["n"] += 1
        for flag in d["flags"]:
            if flag in group:
                group[flag] += 1
        group["levels"].update(w for w in d["direction"].split() if w in ("above", "below"))
    return groups


def _describe_groups(groups, with_levels):
    parts = []
    for kind, group in groups.items():
        # Every state is spelled out, the "no" too: with "2 cameras" alone the model said they were watching V.
        notes = []
        if with_levels and group["levels"]:
            notes.append(" and ".join(sorted(group["levels"])))
        if kind in ("camera", "turret", "sniper nest"):
            notes.append(f"{group['watching-V']} watching V" if group["n"] > 1
                         else ("watching V" if group["watching-V"] else "not watching V"))
        if kind in ("turret", "sniper nest"):
            notes.append(f"{group['hostile']} hostile" if group["n"] > 1
                         else ("hostile" if group["hostile"] else "not hostile"))
        if kind == "alarm":
            notes.append("ringing" if group["ringing"] else "silent")
        if group["off"]:
            notes.append(f"{group['off']} off" if group["n"] > 1 else "off")
        parts.append(_count(group["n"], kind) + (f" ({', '.join(notes)})" if notes else ""))
    return "; ".join(parts)


def describe_devices(line, detailed):
    """What the model reads about devices: "here" (in V's space: a clear line from V or the drone) is kept apart
    from what Apiko only knows through the network or saw before (behind walls, another floor). Without that, the
    cameras of a basement came out as if they were in the room. A summary of security, or the full list when
    `detailed`."""
    devices = parse_devices(line)
    if not devices:
        return ""
    breached = any("breached" in d["flags"] for d in devices)
    pinged = any("pinged" in d["flags"] for d in devices)
    if detailed:
        items = []
        for d in devices:
            place = "here" if "here" in d["flags"] else "elsewhere"
            flags = [f for f in d["flags"] if f not in ("on", "here")]  # "on" is the normal case
            items.append(f"{d['id']} {d['kind']} {d['meters']}m {d['direction']}, {place}"
                         + (f" ({', '.join(flags)})" if flags else ""))
        return ("[devices you perceive; here = in V's space, elsewhere = behind walls or on another floor; ids are "
                "internal, never say them] " + "; ".join(items))
    here = _security_groups([d for d in devices if "here" in d["flags"]])
    away = _security_groups([d for d in devices if "here" not in d["flags"]])
    if not here and not away and not breached and not pinged:
        return ""
    lines = ["[security here, in V's space] " + (_describe_groups(here, False) or "none")]
    if away:
        lines.append("[security elsewhere on the network, not in V's space] " + _describe_groups(away, True))
    if breached:
        lines.append("[network] V has breached the local network")
    elif pinged:
        lines.append("[network] V's ping revealed the local network")
    return "\n".join(lines)


ENEMY_FIELDS = ("id", "faction", "role", "threat", "power", "meters", "direction", "awareness", "health", "flags",
                "weapon", "cyberware", "name")


def parse_enemies(line):
    """The game's "enemies=" line: "id,faction,role,threat,power,meters,direction,awareness,health,flags,weapon,
    cyberware,name" entries joined by ";" (flags space-separated, cyberware joined by "+")."""
    enemies = []
    for entry in str(line or "").split(";"):
        fields = entry.split(",")
        if len(fields) < len(ENEMY_FIELDS):
            continue
        e = dict(zip(ENEMY_FIELDS, fields))
        try:
            e["meters"], e["health"] = int(e["meters"]), int(e["health"])
        except ValueError:
            continue
        e["faction"] = faction_name(e["faction"])
        e["flags"] = e["flags"].split()
        e["weapon"] = weapon_name(e["weapon"]) if e["weapon"] else ""
        e["cyberware"] = [c for c in e["cyberware"].split("+") if c]
        e["name"] = e["name"].strip()
        enemies.append(e)
    return enemies


def _awareness(e):
    if e["awareness"] == "combat" and "targeting-V" in e["flags"]:
        return "fighting V"
    text = AWARENESS.get(e["awareness"], e["awareness"])
    if "hostile" not in e["flags"] and e["awareness"] in ("calm", "suspicious"):
        text += ", not hostile yet"
    return text


def _describe_faction(faction, group):
    """"3 Maelstrom (2 gunners, 1 netrunner; 2 fighting V, 1 unaware of V; 1 elite)": every count spelled out, so
    the model does not invent states (with "2 cameras" alone it said they were watching V)."""
    roles, states, notes = {}, {}, []
    for e in group:
        roles[e["role"]] = roles.get(e["role"], 0) + 1
        state = _awareness(e)
        states[state] = states.get(state, 0) + 1
    threats = {}
    for e in group:
        if e["threat"] in NOTABLE_THREATS:
            threats[e["threat"]] = threats.get(e["threat"], 0) + 1
    notes.append(", ".join(f"{n} {r}" + ("s" if n > 1 else "") for r, n in sorted(roles.items(), key=lambda x: -x[1])))
    notes.append(", ".join(f"{n} {s}" for s, n in sorted(states.items(), key=lambda x: -x[1])))
    if threats:
        notes.append(", ".join(f"{n} {t}" for t, n in threats.items()))
    hacking = sum("hacking-V" in e["flags"] for e in group)
    if hacking:
        notes.append(f"{hacking} hacking V right now")
    named = [f"{e['name']} ({e['threat']})" if e["threat"] in NOTABLE_THREATS else e["name"] for e in group if e["name"]]
    if named:
        notes.append("named: " + ", ".join(named))
    levels = sorted({w for e in group for w in e["direction"].split() if w in ("above", "below")})
    if levels:
        notes.append(" and ".join(levels))
    return f"{len(group)} {faction} ({'; '.join(notes)})"


def _describe_place(enemies):
    by_faction = {}
    for e in enemies:
        by_faction.setdefault(e["faction"], []).append(e)
    return "; ".join(_describe_faction(f, g) for f, g in by_faction.items())


def _last_seen(e):
    """Seconds since a remembered enemy (lost from sight, not tracked) was last seen; None for a live one."""
    for flag in e["flags"]:
        if flag.startswith("last-seen-") and flag.endswith("s"):
            try:
                return int(flag[len("last-seen-"):-1])
            except ValueError:
                return 0
    return None


def describe_enemies(line, detailed):
    """What the model reads about enemies: a summary per place ("here" = in V's space, a clear line from V or the
    drone; "elsewhere" = tracked through a tag, a ping or a hacked camera; "lost sight" = seen before, only its last
    known card), or the full cards when `detailed`. "" when Apiko knows of none."""
    enemies = parse_enemies(line)
    if not enemies:
        return ""
    if detailed:
        items = []
        for e in enemies:
            ago = _last_seen(e)
            if ago is not None:
                place = (f"{e['meters']}m {e['direction']} when last seen {ago}s ago, out of sight since; "
                         "may have moved, the rest is as it was then")
            else:
                place = f"{e['meters']}m {e['direction']}, {'here' if 'here' in e['flags'] else 'elsewhere'}"
            card = [f"{e['id']} {e['faction']} {e['role']}" + (f" \"{e['name']}\"" if e["name"] else ""),
                    f"{e['threat']} rank, {e['power']} for V", place, _awareness(e), f"{e['health']}% health"]
            if e["weapon"]:
                card.append(e["weapon"])
            if e["cyberware"]:
                card.append("cyberware: " + ", ".join(e["cyberware"]))
            if "hacking-V" in e["flags"]:
                card.append("hacking V right now")
            how = [w for w in ("tagged", "pinged", "camera") if w in e["flags"]]
            if how and "here" not in e["flags"]:
                card.append("known via " + "/".join(how))
            items.append(", ".join(card))
        return ("[enemies you perceive; here = in V's space, elsewhere = behind walls but tracked by tag, ping or "
                "camera; last seen = you lost sight of it and only know where it was; ids are internal, never say "
                "them] " + "; ".join(items))
    here = [e for e in enemies if "here" in e["flags"]]
    lost = [e for e in enemies if "here" not in e["flags"] and _last_seen(e) is not None]
    away = [e for e in enemies if "here" not in e["flags"] and _last_seen(e) is None]
    lines = []
    if here:
        lines.append("[threats here, in V's space] " + _describe_place(here))
    if away:
        lines.append("[threats elsewhere, not in V's space, tracked by tag, ping or camera] " + _describe_place(away))
    if lost:
        newest = min(_last_seen(e) for e in lost)
        lines.append(f"[threats you saw and lost sight of (latest {newest}s ago); only where they were then, they may "
                     "have moved] " + _describe_place(lost))
    return "\n".join(lines)
