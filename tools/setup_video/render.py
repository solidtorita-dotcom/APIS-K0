"""Renders the setup tutorial video (Nexus) from scenes.py and the narration from narrate.py (build\\setup_video).
The APIKO Settings window is drawn here, ImGui style, from the mod's providers.json and in the same order as
settings_window.lua: real texts, providers, models and notes. Output: art\\setup_video\\apiko_setup.mp4
(1920x1080, 30 fps).

Usage (system Python with Pillow, numpy and imageio-ffmpeg), from Apis-K0:
  python tools\\setup_video\\render.py                 the video
  python tools\\setup_video\\render.py --preview       stills in build\\setup_video\\preview (scene starts + actions)
"""
import json
import subprocess
import sys
import wave
from functools import lru_cache
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from scenes import SCENES  # noqa: E402

CATALOG = json.loads((ROOT / "src" / "bin" / "x64" / "plugins" / "cyber_engine_tweaks" / "mods" / "ApisK0" /
                      "providers.json").read_text(encoding="utf-8"))
ART = ROOT / "art" / "setup_video"
BUILD = ROOT / "build" / "setup_video"
VIDEO = ART / "apiko_setup.mp4"

W, H, FPS = 1920, 1080, 30
LEAD, TAIL, END_TAIL = 0.35, 0.55, 1.8  # silence before / after each line, and after the last one
FADE = 0.35

# Video look.
BG = (9, 12, 17)
GRID = (17, 27, 36)
YELLOW = (243, 230, 0)
CYAN = (0, 229, 255)
WHITE = (236, 240, 244)
GREY = (170, 182, 194)
FONT = "C:/Windows/Fonts/bahnschrift.ttf"
MONO = "C:/Windows/Fonts/consola.ttf"
PANEL_X, PANEL_W = 975, 860
SUB_Y = 1040

# The ImGui window (CET dark theme, as in the game's screenshots).
UI_FONT = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 25)
WIN = (95, 80, 865, 930)  # settings window x0, y0, x1, y1
MAIN = (95, 250, 865, 690)  # the APIKO chat window
TITLE_H, PAD, SCROLLBAR = 46, 18, 16
LINE, FRAME_H, HEADER_H, GAP, SPACING, ITEM_H = 34, 48, 46, 22, 10, 42
CX0, CY0 = WIN[0] + PAD, WIN[1] + TITLE_H + 10
CW = WIN[2] - WIN[0] - 2 * PAD - SCROLLBAR - 6
VIEW_H = WIN[3] - CY0 - 8
UI = {
    "win": (24, 27, 33, 246), "border": (62, 72, 88, 255), "title": (38, 66, 110, 255), "header": (37, 60, 97, 255),
    "frame": (31, 49, 77, 255), "frame_hover": (43, 68, 106, 255), "arrow": (46, 84, 138, 255),
    "popup": (19, 22, 27, 250), "sel": (37, 60, 97, 255), "hover": (54, 94, 152, 255),
    "text": (235, 235, 235, 255), "note": (179, 179, 179, 255), "warn": (242, 191, 89, 255),
    "disabled": (128, 128, 128, 255), "ok": (128, 232, 217, 255), "check": (52, 108, 190, 255),
    "grab": (66, 150, 250, 255), "button": (41, 74, 122, 255), "button_hover": (56, 98, 160, 255),
    "button_active": (70, 124, 200, 255), "track": (14, 16, 20, 255), "thumb": (66, 70, 78, 255),
    "sep": (62, 66, 74, 255),
}
SECTIONS = [("llm", "Reply model", "The AI that writes what Apiko says."),
            ("stt", "Speech recognition", "Turns your voice into text (push to talk)."),
            ("tts", "Voice", "Renders Apiko's voice. The voice itself is always Apiko's.")]

INITIAL = {"view": "none", "view_t": -10.0, "prev_view": "none", "open": None, "focus": None,
           "llm_provider": CATALOG["llm"]["default"], "llm_model": None, "llm_key": 0,
           "stt_provider": CATALOG["stt"]["default"], "stt_model": None, "stt_key": 0,
           "tts_provider": CATALOG["tts"]["default"], "tts_region": None, "tts_key": 0,
           "think": False, "improvise": 10, "fallback": True,
           "test_llm": None, "test_stt": None, "test_tts": None, "scroll": 0.0, "edit_t": -10.0}
EDITS = {"llm_provider", "llm_model", "stt_provider", "stt_model", "tts_provider", "tts_region", "llm_key", "stt_key",
         "tts_key", "improvise"}


def font(size, variation="Regular"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(variation)
    return f


def wrap(text, f, width):
    lines = []
    for paragraph in text.split("\n"):
        line = ""
        for word in paragraph.split(" "):
            test = f"{line} {word}".strip()
            if f.getlength(test) <= width or not line:
                line = test
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


@lru_cache(maxsize=None)
def ui_wrap(text):
    return tuple(wrap(text, UI_FONT, CW))


def ease(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def badge(label, b):
    return f"{label} ({b})" if b else label


# --- the settings window: layout ---------------------------------------------------------------------------------

def recommended(entry):
    models = entry.get("models") or []
    for m in models:
        if m.get("badge") == "Recommended":
            return m["id"]
    return models[0]["id"] if models else ""


def layout(st):
    """Widgets of the settings window for this state, top to bottom, with their y in content pixels."""
    items = []

    def add(kind, h, wid=None, **data):
        items.append(dict(kind=kind, h=h, id=wid, **data))

    def text(t, color, wid=None):
        if t:
            lines = ui_wrap(t)
            add("text", LINE * len(lines), wid, lines=lines, color=color)

    text("Pick who powers Apiko and paste your own API keys. Changes apply on their own in a second.", "note")
    text("Keys are saved as plain text in this mod's folder (settings.json). Never share that file.", "warn", "warn")
    for kind, title, hint in SECTIONS:
        add("spacing", 4)
        add("header", HEADER_H, f"hdr_{kind}", title=title)
        text(hint, "note")
        section = CATALOG[kind]
        pid = st[f"{kind}_provider"]
        entry = section["providers"][pid]
        options = [p for p in section["order"] if p in section["providers"]]
        add("combo", FRAME_H, f"prov_{kind}", value=badge(entry["label"], entry.get("badge")),
            options=[badge(section["providers"][p]["label"], section["providers"][p].get("badge")) for p in options],
            selected=options.index(pid))
        text(entry.get("note"), "note")
        models = entry.get("models") or []
        if kind != "tts" and (models or entry.get("url_editable")):
            model = st.get(f"{kind}_model") or recommended(entry)
            preset = next((m for m in models if m["id"] == model), None)
            add("gap", GAP)
            text("Model", "text")
            add("combo", FRAME_H, f"model_{kind}", value=badge(model, preset and preset.get("badge")),
                options=[badge(m["id"], m.get("badge")) for m in models] + ["Custom model..."],
                selected=models.index(preset) if preset else len(models))
            text(preset and preset.get("note"), "note")
        if entry.get("url_editable") and entry.get("regions"):
            regions = entry["regions"]
            rid = st.get("tts_region") or entry.get("base_url")
            current = next((i for i, r in enumerate(regions) if r["id"] == rid), 0)
            add("gap", GAP)
            text(entry.get("url_label", "Region"), "text")
            add("combo", FRAME_H, f"region_{kind}", value=regions[current]["label"],
                options=[r["label"] for r in regions] + ["Other..."], selected=current)
            text(entry.get("url_note"), "note")
        if entry.get("key"):
            add("gap", GAP)
            text(f"API key ({entry['label']})", "text")
            add("input", FRAME_H, f"key_{kind}", stars=st[f"{kind}_key"], password=True)
            if entry.get("key_url"):
                text("Get a key (select and Ctrl+C):", "disabled")
                add("input", FRAME_H, f"keyurl_{kind}", value=entry["key_url"])
        if kind == "llm":
            add("gap", GAP)
            add("check", FRAME_H, "think", label="Think before answering", checked=st["think"])
            text("Follows Apiko's rules a bit better, but answers about 2 s later and costs about twice as much. "
                 "Recommended: off." if entry.get("reasoning") else
                 "This provider's models do not think: no effect here.", "note")
            add("gap", GAP)
            add("slider", FRAME_H, "improvise", label="Improvised remarks", value=st["improvise"])
            text("Apiko reacts to events (combat, alarms, districts...) with written lines: instant and free. This is "
                 "how often the model makes one up instead (fresher, but it costs tokens and comes a bit later). "
                 "0% = only when you talk to it.", "note")
            add("gap", GAP)
            add("check", FRAME_H, "fallback", label="If it fails, use the next best model you have a key for",
                checked=st["fallback"])
            text("Order (best first): Claude Haiku, GPT-5.4 mini, Gemini 3.5 Flash, ... Groq, Ollama, free models. "
                 "Only models whose provider has a key here are used.", "note")
        add("gap", GAP)
        add("button", FRAME_H, f"test_{kind}", label="Test", status=st.get(f"test_{kind}"))
    add("spacing", 4)
    add("sep", 2)
    add("text", LINE, "saved", lines=("Saving..." if st.get("saving") else "Saved.",), color="disabled")
    y = 4
    for it in items:
        it["y"] = y
        y += it["h"] + SPACING
    return items, {it["id"]: it for it in items if it["id"]}, y


def item_rect(it):
    """The widget's own rectangle, in content pixels."""
    x0, y0, y1 = 0, it["y"], it["y"] + it["h"]
    if it["kind"] == "check":
        x1 = FRAME_H - 8 + 14 + UI_FONT.getlength(it["label"])
    elif it["kind"] == "slider":
        x1 = 310 + 14 + UI_FONT.getlength(it["label"])
    elif it["kind"] == "button":
        x1 = UI_FONT.getlength(it["label"]) + 32
    elif it["kind"] == "text":
        x1 = max(UI_FONT.getlength(line) for line in it["lines"])
    else:
        x1 = CW
    return x0, y0, x1, y1


def to_screen(rect, scroll):
    x0, y0, x1, y1 = rect
    return CX0 + x0, CY0 + y0 - scroll, CX0 + x1, CY0 + y1 - scroll


def popup_rects(combo_rect, n):
    """Screen rects of a dropdown's list (up to 8 visible) and of its items."""
    x0, _, x1, y1 = combo_rect
    visible = min(n, 8)
    top = y1 + 2
    items = [(x0, top + 6 + i * ITEM_H, x1, top + 6 + (i + 1) * ITEM_H) for i in range(visible)]
    return (x0, top, x1, top + 12 + visible * ITEM_H), items


# --- the settings window: drawing --------------------------------------------------------------------------------

def tri_down(d, cx, cy, size, color):
    d.polygon([(cx - size, cy - size * 0.6), (cx + size, cy - size * 0.6), (cx, cy + size * 0.7)], fill=color)


def inside(p, r):
    return p is not None and r[0] <= p[0] <= r[2] and r[1] <= p[1] <= r[3]


def draw_frame_text(d, rect, txt, color, clip_w=None):
    x0, y0, x1, y1 = rect
    if clip_w is not None:
        while txt and UI_FONT.getlength(txt) > clip_w:
            txt = txt[:-1]
    d.text((x0 + 12, (y0 + y1) / 2), txt, font=UI_FONT, fill=UI[color], anchor="lm")


def draw_content(st, items, t, cursor, pressed):
    """The scrolled content of the settings window as an RGBA image (CW x VIEW_H); the cursor in screen pixels."""
    img = Image.new("RGBA", (CW + 4, VIEW_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    scroll = st["scroll"]
    for it in items:
        top = it["y"] - scroll
        if top > VIEW_H or top + it["h"] < 0:
            continue
        r = (0, top, CW, top + it["h"])
        screen = to_screen(item_rect(it), scroll)
        hover = inside(cursor, screen) and st["open"] is None
        k = it["kind"]
        if k == "text":
            for i, line in enumerate(it["lines"]):
                d.text((0, top + i * LINE + 3), line, font=UI_FONT, fill=UI[it["color"]])
        elif k == "header":
            d.rounded_rectangle(r, 4, fill=UI["header"])
            tri_down(d, 22, top + it["h"] / 2, 9, UI["text"])
            d.text((44, top + it["h"] / 2), it["title"], font=UI_FONT, fill=UI["text"], anchor="lm")
        elif k == "combo":
            open_ = st["open"] == it["id"]
            d.rounded_rectangle(r, 4, fill=UI["frame_hover"] if hover or open_ else UI["frame"])
            d.rounded_rectangle((CW - FRAME_H, top, CW, top + it["h"]), 4,
                                fill=UI["button_hover"] if hover or open_ else UI["arrow"])
            tri_down(d, CW - FRAME_H / 2, top + it["h"] / 2, 9, UI["text"])
            draw_frame_text(d, r, it["value"], "text", CW - FRAME_H - 24)
        elif k == "input":
            d.rounded_rectangle(r, 4, fill=UI["frame_hover"] if hover else UI["frame"])
            if it.get("password"):
                if it["stars"]:
                    draw_frame_text(d, r, "*" * it["stars"], "text", CW - 24)
                elif st["focus"] != it["id"]:
                    draw_frame_text(d, r, "paste your key here", "disabled")
                if st["focus"] == it["id"] and int(t * 2.5) % 2 == 0:
                    x = 12 + min(UI_FONT.getlength("*" * it["stars"]), CW - 24) + 2
                    d.line([(x, top + 10), (x, top + it["h"] - 10)], fill=UI["text"], width=2)
            else:
                draw_frame_text(d, r, it["value"], "text", CW - 24)
        elif k == "check":
            box = FRAME_H - 8
            b = (0, top + 4, box, top + 4 + box)
            d.rounded_rectangle(b, 4, fill=UI["check"] if it["checked"] else
                                (UI["frame_hover"] if hover else UI["frame"]))
            if it["checked"]:
                d.line([(9, top + 4 + box * 0.52), (box * 0.42, top + 4 + box * 0.76), (box - 8, top + 4 + box * 0.26)],
                       fill=UI["text"], width=4, joint="curve")
            d.text((box + 14, top + it["h"] / 2), it["label"], font=UI_FONT, fill=UI["text"], anchor="lm")
        elif k == "slider":
            fr = (0, top, 310, top + it["h"])
            d.rounded_rectangle(fr, 4, fill=UI["frame_hover"] if hover else UI["frame"])
            gx = 6 + (310 - 12 - 22) * it["value"] / 50
            d.rounded_rectangle((gx, top + 6, gx + 22, top + it["h"] - 6), 4, fill=UI["grab"])
            d.text((155, top + it["h"] / 2), f"{round(it['value'])}%", font=UI_FONT, fill=UI["text"], anchor="mm")
            d.text((324, top + it["h"] / 2), it["label"], font=UI_FONT, fill=UI["text"], anchor="lm")
        elif k == "button":
            bw = UI_FONT.getlength(it["label"]) + 32
            color = "button_active" if pressed == it["id"] else ("button_hover" if hover else "button")
            d.rounded_rectangle((0, top, bw, top + it["h"]), 4, fill=UI[color])
            d.text((bw / 2, top + it["h"] / 2), it["label"], font=UI_FONT, fill=UI["text"], anchor="mm")
            status = it["status"]
            if status == "pending":
                d.text((bw + 14, top + it["h"] / 2), "testing...", font=UI_FONT, fill=UI["disabled"], anchor="lm")
            elif status:
                d.text((bw + 14, top + it["h"] / 2), status, font=UI_FONT, fill=UI["ok"], anchor="lm")
        elif k == "sep":
            d.line([(0, top + 1), (CW, top + 1)], fill=UI["sep"], width=2)
    return img


def draw_window_frame(d, rect, title):
    x0, y0, x1, y1 = rect
    d.rounded_rectangle(rect, 8, fill=UI["win"], outline=UI["border"], width=2)
    d.rounded_rectangle((x0 + 1, y0 + 1, x1 - 1, y0 + TITLE_H), 8, fill=UI["title"])
    d.rectangle((x0 + 1, y0 + TITLE_H - 10, x1 - 1, y0 + TITLE_H), fill=UI["title"])
    tri_down(d, x0 + 26, y0 + TITLE_H / 2, 10, UI["text"])
    d.text(((x0 + x1) / 2, y0 + TITLE_H / 2), title, font=UI_FONT, fill=UI["text"], anchor="mm")


def draw_settings(st, t, cursor, pressed):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    draw_window_frame(d, WIN, "APIKO Settings")
    items, by_id, total = layout(st)
    layer.alpha_composite(draw_content(st, items, t, cursor, pressed), (CX0, CY0))
    # Scrollbar.
    sx0 = WIN[2] - SCROLLBAR - 6
    d.rectangle((sx0, CY0, sx0 + SCROLLBAR, CY0 + VIEW_H), fill=UI["track"])
    if total > VIEW_H:
        h = max(40, VIEW_H * VIEW_H / total)
        y = CY0 + (VIEW_H - h) * st["scroll"] / (total - VIEW_H)
        d.rounded_rectangle((sx0 + 3, y, sx0 + SCROLLBAR - 3, y + h), 6, fill=UI["thumb"])
    # Open dropdown, over everything.
    if st["open"] in by_id:
        it = by_id[st["open"]]
        combo = to_screen(item_rect(it), st["scroll"])
        box, rows = popup_rects(combo, len(it["options"]))
        d.rounded_rectangle(box, 4, fill=UI["popup"], outline=UI["border"], width=1)
        for i, row in enumerate(rows):
            if i == it["selected"]:
                d.rectangle(row, fill=UI["sel"])
            if inside(cursor, row):
                d.rectangle(row, fill=UI["hover"])
            d.text((row[0] + 12, (row[1] + row[3]) / 2), it["options"][i], font=UI_FONT, fill=UI["text"], anchor="lm")
        if len(it["options"]) > len(rows):
            frac = len(rows) / len(it["options"])
            d.rounded_rectangle((box[2] - 12, box[1] + 6, box[2] - 4, box[1] + 6 + (box[3] - box[1] - 12) * frac), 4,
                                fill=UI["thumb"])
    return layer, by_id


MAIN_BUTTON = (MAIN[0] + PAD, MAIN[1] + TITLE_H + 14, MAIN[0] + PAD + UI_FONT.getlength("Settings") + 32,
               MAIN[1] + TITLE_H + 14 + FRAME_H)


def draw_main(cursor, pressed):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    draw_window_frame(d, MAIN, "APIKO")
    b = MAIN_BUTTON
    color = "button_active" if pressed == "main_settings" else ("button_hover" if inside(cursor, b) else "button")
    d.rounded_rectangle(b, 4, fill=UI[color])
    d.text(((b[0] + b[2]) / 2, (b[1] + b[3]) / 2), "Settings", font=UI_FONT, fill=UI["text"], anchor="mm")
    y = b[3] + 14
    d.text((b[0], y), "Bridge online", font=UI_FONT, fill=UI["ok"])
    y += LINE + 10
    d.line([(b[0], y), (MAIN[2] - PAD, y)], fill=UI["sep"], width=2)
    y += 14
    d.text((b[0], y), "APIKO:", font=UI_FONT, fill=UI["ok"])
    d.text((b[0] + UI_FONT.getlength("APIKO: "), y), "Configure me. I am waiting.", font=UI_FONT, fill=UI["text"])
    iy = MAIN[3] - PAD - FRAME_H
    send_w = UI_FONT.getlength("Send") + 32
    d.rounded_rectangle((b[0], iy, MAIN[2] - PAD - send_w - 10, iy + FRAME_H), 4, fill=UI["frame"])
    d.rounded_rectangle((MAIN[2] - PAD - send_w, iy, MAIN[2] - PAD, iy + FRAME_H), 4, fill=UI["button"])
    d.text((MAIN[2] - PAD - send_w / 2, iy + FRAME_H / 2), "Send", font=UI_FONT, fill=UI["text"], anchor="mm")
    return layer


# --- timeline: scenes, state, cursor -----------------------------------------------------------------------------

def scene_times():
    info = json.loads((BUILD / "durations.json").read_text(encoding="utf-8"))
    spans, t = [], 0.0
    for i, seconds in enumerate(info["seconds"]):
        tail = END_TAIL if i == len(SCENES) - 1 else TAIL
        last_action = max([a[2] if a[0] in ("move", "type", "slide", "scroll") else
                           a[1] + (a[4] if a[0] == "test" else 0) for a in SCENES[i].get("do", [])] or [0])
        length = max(LEAD + seconds + tail, last_action + 0.9)
        spans.append((t, t + length))
        t += length
    return spans, t


class Timeline:
    def __init__(self):
        self.spans, self.total = scene_times()
        self.events = []
        for i, scene in enumerate(SCENES):
            start = self.spans[i][0]
            for a in scene.get("do", []):
                kind = a[0]
                if kind in ("move", "type", "slide", "scroll"):
                    self.events.append((start + a[1], kind, (start + a[1], start + a[2]) + tuple(a[3:])))
                elif kind == "test":
                    _, t0, what, result, delay = a
                    self.events.append((start + t0, "set", (f"test_{what}", "pending")))
                    self.events.append((start + t0 + delay, "set", (f"test_{what}", result)))
                    self.events.append((start + t0, "press", (f"test_{what}",)))
                elif kind == "click":
                    self.events.append((start + a[1], "click", ()))
                elif kind == "open":
                    self.events.append((start + a[1], "set", ("open", a[2])))
                elif kind == "close":
                    self.events.append((start + a[1], "set", ("open", None)))
                elif kind == "pick":
                    self.events.append((start + a[1], "set", (a[2], a[3])))
                    self.events.append((start + a[1], "set", ("open", None)))
                elif kind == "focus":
                    self.events.append((start + a[1], "set", ("focus", a[2])))
                elif kind == "view":
                    self.events.append((start + a[1], "view", (a[2],)))
        self.events.sort(key=lambda e: e[0])
        self.clicks = [e[0] for e in self.events if e[1] == "click"]
        # Scroll targets and cursor path, resolved in order (they depend on the layout at that time).
        self.scroll_to = {}
        for n, (t, kind, args) in enumerate(self.events):
            if kind == "scroll":
                t0, t1, wid, anchor = args
                st = self.state(t1, upto=n)
                _, by_id, total = layout(st)
                self.scroll_to[n] = min(max(0.0, by_id[wid]["y"] - anchor), max(0.0, total - VIEW_H))
        self.path = []
        pos = (1500.0, 1150.0)
        for n, (t, kind, args) in enumerate(self.events):
            if kind == "move":
                t0, t1, target = args
                end = self.target(target, self.state(t1))
                self.path.append((t0, t1, pos, end))
                pos = end

    def state(self, t, upto=None):
        st = dict(INITIAL)
        for n, (et, kind, args) in enumerate(self.events):
            if et > t or (upto is not None and n >= upto):
                break
            if kind == "set":
                key, value = args
                st[key] = value
                if key in EDITS:
                    st["edit_t"] = et
            elif kind == "view":
                st["prev_view"], st["view"], st["view_t"] = st["view"], args[0], et
            elif kind == "type":
                t0, t1, key, chars = args
                st[key] = round(chars * min(1.0, (t - t0) / (t1 - t0)))
                st["edit_t"] = min(t, t1)
            elif kind == "slide":
                t0, t1, key, a, b = args
                st[key] = a + (b - a) * ease((t - t0) / (t1 - t0))
                st["edit_t"] = min(t, t1)
            elif kind == "scroll" and n in getattr(self, "scroll_to", {}):
                t0, t1 = args[0], args[1]
                start = st["scroll"]
                st["scroll"] = start + (self.scroll_to[n] - start) * ease((t - t0) / (t1 - t0))
        st["saving"] = t - st["edit_t"] < 0.8
        return st

    def target(self, target, st):
        if target == "main_settings":
            b = MAIN_BUTTON
            return (b[0] + (b[2] - b[0]) * 0.55, (b[1] + b[3]) / 2)
        _, by_id, _ = layout(st)
        if isinstance(target, tuple):
            _, combo, index = target
            it = by_id[combo]
            _, rows = popup_rects(to_screen(item_rect(it), st["scroll"]), len(it["options"]))
            r = rows[index]
            return (r[0] + min(220, (r[2] - r[0]) * 0.4), (r[1] + r[3]) / 2)
        it = by_id[target]
        x0, y0, x1, y1 = to_screen(item_rect(it), st["scroll"])
        if it["kind"] == "slider":
            return (CX0 + 6 + (310 - 34) * it["value"] / 50 + 11, (y0 + y1) / 2)
        if it["kind"] == "check":
            return (x0 + (FRAME_H - 8) / 2, (y0 + y1) / 2)
        if it["kind"] == "text":
            return (x1 + 26, (y0 + y1) / 2)
        return (x0 + min(240, (x1 - x0) * 0.45), (y0 + y1) / 2)

    def cursor(self, t, st):
        pos = (1500.0, 1150.0)
        for t0, t1, p0, p1 in self.path:
            if t < t0:
                break
            k = ease((t - t0) / (t1 - t0))
            pos = (p0[0] + (p1[0] - p0[0]) * k, p0[1] + (p1[1] - p0[1]) * k)
        # Dragging the slider: the cursor follows the grab.
        for et, kind, args in self.events:
            if kind == "slide" and args[0] <= t <= args[1] + 0.05:
                pos = (CX0 + 6 + (310 - 34) * st["improvise"] / 50 + 11, pos[1])
        return pos

    def scene(self, t):
        return max(i for i, (s, _) in enumerate(self.spans) if s <= t or i == 0)


# --- video layers ------------------------------------------------------------------------------------------------

def background():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    for x in range(0, W, 48):
        d.line([(x, 0), (x, H)], fill=GRID)
    for y in range(0, H, 48):
        d.line([(0, y), (W, y)], fill=GRID)
    yy, xx = np.mgrid[0:H, 0:W]
    r = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2)
    shade = np.clip(1.15 - 0.55 * r, 0.35, 1.0)[..., None]
    img = Image.fromarray((np.asarray(img) * shade).astype(np.uint8))
    d = ImageDraw.Draw(img)
    d.text((W - 40, 34), "APIKO  //  SETUP GUIDE  //  v0.1.0 alpha", font=font(22), fill=(90, 102, 114), anchor="ra")
    return img


def panel(scene):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    if scene.get("card"):
        big = font(130 if scene is SCENES[0] else 104, "Bold")
        y = H // 2 - 110
        d.text((W // 2, y), scene["title"], font=big, fill=YELLOW, anchor="mm")
        d.line([(W // 2 - 260, y + 92), (W // 2 + 260, y + 92)], fill=CYAN, width=3)
        d.text((W // 2, y + 160), scene.get("detail", ""), font=font(46), fill=WHITE, anchor="mm")
        return layer
    x, y = PANEL_X, 230
    d.rectangle([x - 34, y + 6, x - 26, y + 340], fill=YELLOW)
    d.text((x, y), scene.get("step", ""), font=font(32, "SemiBold"), fill=CYAN)
    y += 66
    title = font(66, "Bold")
    for line in wrap(scene["title"], title, PANEL_W):
        d.text((x, y), line, font=title, fill=WHITE)
        y += 80
    y += 24
    detail, mono = font(38), ImageFont.truetype(MONO, 36)
    for line in wrap(scene.get("detail", ""), detail, PANEL_W):
        is_url = "/" in line and " " not in line.strip()
        d.text((x, y), line, font=mono if is_url else detail, fill=YELLOW if is_url else GREY)
        y += 54
    return layer


def subtitle(scene):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f, name = font(34), font(34, "Bold")
    lines = wrap(scene.get("sub", scene["say"]), f, 1500)
    top = SUB_Y - 46 * len(lines)
    width = max(f.getlength(line) for line in lines) + name.getlength("APIKO:  ")
    d.rounded_rectangle([W // 2 - width / 2 - 24, top - 12, W // 2 + width / 2 + 24, SUB_Y + 4], 8,
                        fill=(0, 0, 0, 190))
    left = W // 2 - width / 2
    d.text((left, top), "APIKO:", font=name, fill=CYAN)
    for i, line in enumerate(lines):
        d.text((left + name.getlength("APIKO:  "), top + 46 * i), line, font=f, fill=WHITE)
    return layer


def faded(layer, alpha):
    if alpha >= 1:
        return layer
    out = layer.copy()
    out.putalpha(layer.getchannel("A").point(lambda v: int(v * max(0.0, alpha))))
    return out


def draw_boxes(canvas, boxes, appear, t):
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    pulse = 0.5 + 0.5 * np.sin(t * 2 * np.pi / 1.4)
    a = ease(appear)
    grow = (1 - a) * 18
    for x0, y0, x1, y1 in boxes:
        x0, y0, x1, y1 = x0 - 7 - grow, y0 - 6 - grow, x1 + 7 + grow, y1 + 6 + grow
        for spread, alpha in ((10, 40), (6, 70), (3, 110)):
            d.rounded_rectangle([x0 - spread, y0 - spread, x1 + spread, y1 + spread], 6,
                                outline=YELLOW + (int(alpha * a * (0.6 + 0.4 * pulse)),), width=2)
        d.rounded_rectangle([x0, y0, x1, y1], 5, outline=YELLOW + (int(255 * a),), width=3)
    canvas.alpha_composite(overlay)


CURSOR = [(0, 0), (0, 25), (6, 19), (10.5, 29), (14.5, 27.2), (10, 17.6), (18, 17.6)]


def draw_cursor(canvas, pos, t, clicks):
    d = ImageDraw.Draw(canvas)
    for c in clicks:
        k = (t - c) / 0.4
        if 0 <= k <= 1:
            r = 8 + 30 * ease(k)
            d.ellipse((pos[0] - r, pos[1] - r, pos[0] + r, pos[1] + r), outline=CYAN + (int(255 * (1 - k)),), width=3)
    press = any(0 <= t - c <= 0.12 for c in clicks)
    s = 1.35 * (0.88 if press else 1.0)
    pts = [(pos[0] + x * s, pos[1] + y * s) for x, y in CURSOR]
    d.polygon(pts, fill=(255, 255, 255, 255), outline=(0, 0, 0, 255), width=2)


def glitch(img, amount, rng):
    if amount <= 0:
        return img
    a = np.asarray(img).copy()
    for _ in range(int(14 * amount)):
        y = rng.integers(0, H - 40)
        h = rng.integers(4, 40)
        a[y:y + h] = np.roll(a[y:y + h], int(rng.integers(-60, 60) * amount), axis=1)
    return Image.fromarray(a)


class Renderer:
    def __init__(self):
        self.tl = Timeline()
        self.bg = background()
        self.panels = [panel(s) for s in SCENES]
        self.subs = [subtitle(s) for s in SCENES]
        self.rng = np.random.default_rng(7)

    def frame(self, t):
        tl = self.tl
        i = tl.scene(t)
        start, _ = tl.spans[i]
        local = t - start
        scene = SCENES[i]
        st = tl.state(t)
        cursor = tl.cursor(t, st)
        pressed = None
        for et, kind, args in tl.events:
            if kind == "press" and 0 <= t - et <= 0.2:
                pressed = args[0]
        if st["view"] == "main" and any(0 <= t - c <= 0.2 for c in tl.clicks):
            pressed = "main_settings"
        canvas = self.bg.copy().convert("RGBA")
        k = ease((t - st["view_t"]) / 0.35)
        show = {"main": 0.0, "settings": 0.0}
        if st["view"] in show:
            show[st["view"]] = k
        if st["prev_view"] in show and st["prev_view"] != st["view"]:
            show[st["prev_view"]] = max(show[st["prev_view"]], 1 - k)
        by_id = {}
        if show["main"] > 0:
            canvas.alpha_composite(faded(draw_main(cursor, pressed), show["main"]))
        if show["settings"] > 0:
            layer, by_id = draw_settings(st, t, cursor, pressed)
            canvas.alpha_composite(faded(layer, show["settings"]))
        # Highlights.
        boxes = []
        for wid in scene.get("hl", []):
            if wid == "main_settings" and show["main"] > 0.5:
                boxes.append(MAIN_BUTTON)
            elif wid in by_id and show["settings"] > 0.5:
                r = to_screen(item_rect(by_id[wid]), st["scroll"])
                if r[1] >= CY0 - 4 and r[3] <= CY0 + VIEW_H + 4:
                    boxes.append(r)
        if boxes:
            draw_boxes(canvas, boxes, local / 0.4, t)
        alpha = ease(local / FADE)
        canvas.alpha_composite(faded(self.panels[i], alpha), (0, 0) if scene.get("card") else (int((1 - alpha) * 30), 0))
        if local >= LEAD * 0.6:
            canvas.alpha_composite(self.subs[i])
        if show["main"] > 0 or show["settings"] > 0:
            draw_cursor(canvas, cursor, t, tl.clicks)
        out = canvas.convert("RGB")
        if scene.get("card") and local < 0.45:
            out = glitch(out, 1 - local / 0.45, self.rng)
        black = min(1.0, t / 0.6, (tl.total - t) / 1.0)
        if black < 1:
            out = Image.blend(Image.new("RGB", (W, H), (0, 0, 0)), out, max(0.0, black))
        return out


def audio_track(tl):
    rate = 48000
    total = tl.total
    track = np.zeros(int(total * rate) + rate, dtype=np.float32)
    tick_t = np.arange(int(rate * 0.045)) / rate
    tick = (np.sin(2 * np.pi * 2100 * tick_t) * np.exp(-tick_t * 110) * 0.16).astype(np.float32)
    for i, (start, _) in enumerate(tl.spans):
        with wave.open(str(BUILD / f"scene_{i:02d}.wav"), "rb") as w:
            src_rate = w.getframerate()
            x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32767
        x = np.interp(np.arange(int(len(x) * rate / src_rate)) * src_rate / rate, np.arange(len(x)), x)
        at = int((start + LEAD) * rate)
        track[at:at + len(x)] += x * 0.95
    for c in tl.clicks:
        at = int(c * rate)
        track[at:at + len(tick)] += tick
    # Soft key taps while a key is pasted.
    for et, kind, args in tl.events:
        if kind == "type":
            for tt in np.arange(args[0], args[1], 0.09):
                at = int(tt * rate)
                track[at:at + len(tick)] += tick * 0.35
    track = np.clip(track[:int(total * rate)], -1, 1)
    path = BUILD / "narration.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((track * 32767).astype(np.int16).tobytes())
    return path


def main():
    r = Renderer()
    if "--preview" in sys.argv:
        out = BUILD / "preview"
        out.mkdir(parents=True, exist_ok=True)
        for f in out.glob("*.png"):
            f.unlink()
        for i, (start, end) in enumerate(r.tl.spans):
            for k, frac in enumerate((0.45, 0.75)):
                r.frame(start + (end - start) * frac).save(out / f"scene_{i:02d}_{k}.png")
        print(f"previews: {out}  (total {r.tl.total:.1f} s)")
        return
    audio = audio_track(r.tl)
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
           "-r", str(FPS), "-i", "-", "-i", str(audio), "-c:v", "libx264", "-preset", "slow", "-crf", "18",
           "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", str(VIDEO)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    frames = int(r.tl.total * FPS)
    for n in range(frames):
        proc.stdin.write(r.frame(n / FPS).tobytes())
        if n % (FPS * 10) == 0:
            print(f"{n / FPS:5.1f} / {r.tl.total:.1f} s", flush=True)
    proc.stdin.close()
    if proc.wait():
        raise SystemExit("ffmpeg failed")
    print(f"video: {VIDEO} ({r.tl.total:.1f} s)")


if __name__ == "__main__":
    main()
