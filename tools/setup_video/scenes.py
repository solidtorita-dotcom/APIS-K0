"""The setup tutorial video (Nexus): its scenes, in order. Shared by narrate.py (Apiko's voice) and render.py (frames).

The settings window is drawn by render.py from providers.json, like settings_window.lua draws it, so it shows the
real texts, providers and models. Each scene:
- `say`: Apiko's narration (also the subtitle, unless `sub` is given).
- `card`: a centered title card instead of the window. Otherwise `step`, `title`, `detail` go in the side panel.
- `hl`: widgets highlighted with a frame (ids below).
- `do`: what happens on screen, in seconds from the scene's start:
    ("view", t, "main" | "settings" | "none")    which window shows (fades)
    ("move", t0, t1, target)                      the cursor glides to a widget id, or ("item", combo id, index)
    ("click", t)                                  a click (sound and ripple; the effect is the next actions)
    ("open", t, combo id) / ("close", t)          a dropdown opens / closes
    ("pick", t, state key, value)                 a dropdown choice (sets the value, closes the dropdown)
    ("focus", t, input id or None)                text caret in an input
    ("type", t0, t1, state key, characters)       a key being pasted / typed (shown as asterisks)
    ("slide", t0, t1, state key, from, to)        the slider dragged
    ("scroll", t0, t1, widget id, pixels)         the window scrolls so that widget sits that far from its top
    ("test", t, kind, result, delay)              Test pressed: "testing...", then the result after `delay`
Widget ids: warn, hdr_<kind>, prov_<kind>, model_<kind>, region_tts, key_<kind>, keyurl_<kind>, think, improvise,
fallback, test_<kind>, saved, and main_settings (the APIKO window's Settings button). <kind>: llm, stt, tts.
"""

SCENES = [
    {"card": True, "title": "APIKO SETUP", "detail": "Three keys. About ten minutes.",
     "say": "Setup. Three keys, about ten minutes. Even you can manage that."},

    {"step": "START", "title": "Open the settings", "detail": "CET overlay  >  APIKO window  >  Settings",
     "say": "Open the Cyber Engine Tweaks overlay. In my window, press Settings.",
     "hl": ["main_settings"],
     "do": [("view", 0.0, "main"), ("move", 0.6, 1.6, "main_settings"), ("click", 3.4), ("view", 3.5, "settings")]},

    {"step": "BEFORE YOU START", "title": "Your keys stay on your PC",
     "detail": "They are saved in the mod's settings.json.\nNever share that file.",
     "say": "Your keys are saved in a file in the mod folder. Never share it. Not even with me.",
     "hl": ["warn"], "do": [("move", 0.3, 1.1, "warn")]},

    {"step": "1 / 3  REPLY MODEL", "title": "Pick OpenRouter", "detail": "The AI that writes what Apiko says.",
     "say": "First, my brain. Under Reply model, pick OpenRouter.",
     "hl": ["prov_llm"],
     "do": [("move", 0.2, 0.9, "prov_llm"), ("click", 1.1), ("open", 1.1, "prov_llm"),
            ("move", 1.5, 2.3, ("item", "prov_llm", 0)), ("click", 2.9), ("pick", 2.9, "llm_provider", "openrouter")]},

    {"step": "1 / 3  REPLY MODEL", "title": "Keep the recommended model",
     "detail": "Claude Haiku: fast, cheap and the best at playing Apiko.",
     "say": "Keep the recommended model. It plays me best. Obviously.",
     "hl": ["model_llm"],
     "do": [("move", 0.1, 0.7, "model_llm"), ("click", 0.9), ("open", 0.9, "model_llm"),
            ("move", 1.3, 2.0, ("item", "model_llm", 2)), ("move", 2.3, 2.9, ("item", "model_llm", 0)),
            ("click", 3.4), ("pick", 3.4, "llm_model", "anthropic/claude-haiku-5.5")]},

    {"step": "1 / 3  REPLY MODEL", "title": "Get a key and paste it", "detail": "openrouter.ai/settings/keys",
     "say": "Create a key at openrouter dot A I, and paste it here.",
     "sub": "Create a key at openrouter.ai, and paste it here.",
     "hl": ["keyurl_llm", "key_llm"],
     "do": [("scroll", 0.0, 0.8, "key_llm", 260), ("move", 0.5, 1.2, "keyurl_llm"),
            ("move", 1.7, 2.2, "key_llm"), ("click", 2.3), ("focus", 2.3, "key_llm"),
            ("type", 2.6, 3.4, "llm_key", 73), ("focus", 3.9, None)]},

    {"step": "1 / 3  REPLY MODEL", "title": "Want it free?",
     "detail": "Google Gemini has a free tier.\nKey: aistudio.google.com/apikey",
     "say": "Want it completely free? Google Gemini has a free tier. I will try not to judge.",
     "hl": ["prov_llm"],
     "do": [("scroll", 0.0, 0.7, "prov_llm", 150), ("move", 0.4, 1.0, "prov_llm"), ("click", 1.2),
            ("open", 1.2, "prov_llm"), ("move", 1.6, 2.2, ("item", "prov_llm", 1)),
            ("move", 4.2, 4.6, ("item", "prov_llm", 0)), ("click", 4.9), ("pick", 4.9, "llm_provider", "openrouter")]},

    {"step": "1 / 3  REPLY MODEL", "title": "Think before answering: off", "detail": "Slower and about twice the cost.",
     "say": "Leave Think before answering off. I am fast enough already.",
     "hl": ["think"],
     "do": [("scroll", 0.0, 0.9, "think", 120), ("move", 0.6, 1.3, "think")]},

    {"step": "1 / 3  REPLY MODEL", "title": "Improvised remarks",
     "detail": "How often Apiko makes up its own comments.\n10% is a good start.",
     "say": "Improvised remarks: how often I make up my own comments. Ten percent. Any more and you will never hear "
            "the end of it.",
     "hl": ["improvise"],
     "do": [("move", 0.2, 0.8, "improvise"), ("slide", 1.1, 2.0, "improvise", 10, 35),
            ("slide", 3.6, 4.4, "improvise", 35, 10)]},

    {"step": "1 / 3  REPLY MODEL", "title": "Keep the fallback on",
     "detail": "If a model fails, the next one you have a key for takes over.",
     "say": "Keep this on. If one model fails, I switch to the next one you have a key for.",
     "hl": ["fallback"], "do": [("move", 0.2, 0.9, "fallback")]},

    {"step": "1 / 3  REPLY MODEL", "title": "Press Test", "detail": "OK means the key works.",
     "say": "Press Test. If it says OK, my brain is online. Such as it is.",
     "hl": ["test_llm"],
     "do": [("scroll", 0.0, 0.6, "test_llm", 420), ("move", 0.4, 1.0, "test_llm"), ("click", 1.2),
            ("test", 1.2, "llm", "OpenRouter (anthropic/claude-haiku-5.5): OK (1.1 s)", 1.1)]},

    {"step": "2 / 3  SPEECH RECOGNITION", "title": "Pick Groq",
     "detail": "Free. Only needed to talk by voice:\nyou can also type.",
     "say": "Next, my ears. Under Speech recognition, pick Groq. It is free.",
     "hl": ["prov_stt"],
     "do": [("scroll", 0.0, 0.9, "hdr_stt", 90), ("move", 0.7, 1.3, "prov_stt"), ("click", 1.5),
            ("open", 1.5, "prov_stt"), ("move", 1.9, 2.5, ("item", "prov_stt", 0)), ("click", 3.0),
            ("pick", 3.0, "stt_provider", "groq")]},

    {"step": "2 / 3  SPEECH RECOGNITION", "title": "Paste the key, press Test", "detail": "console.groq.com/keys",
     "say": "Create a key at console dot groq dot com, paste it, and press Test.",
     "sub": "Create a key at console.groq.com, paste it, and press Test.",
     "hl": ["keyurl_stt", "key_stt", "test_stt"],
     "do": [("scroll", 0.0, 0.6, "key_stt", 300), ("move", 0.4, 0.9, "keyurl_stt"), ("move", 1.2, 1.6, "key_stt"),
            ("click", 1.7), ("focus", 1.7, "key_stt"), ("type", 1.9, 2.6, "stt_key", 56), ("focus", 2.8, None),
            ("move", 2.8, 3.3, "test_stt"), ("click", 3.5), ("test", 3.5, "stt", "Groq (whisper-large-v3-turbo): OK (0.6 s)", 0.7)]},

    {"step": "3 / 3  VOICE", "title": "Pick Azure", "detail": "Free plan: 500,000 characters a month.\nIt never charges you.",
     "say": "Finally, my voice. Pick Azure. The free plan never charges you.",
     "hl": ["prov_tts"],
     "do": [("scroll", 0.0, 0.8, "hdr_tts", 90), ("move", 0.6, 1.2, "prov_tts"), ("click", 1.4),
            ("open", 1.4, "prov_tts"), ("move", 1.8, 2.4, ("item", "prov_tts", 0)), ("click", 2.9),
            ("pick", 2.9, "tts_provider", "azure")]},

    {"step": "3 / 3  VOICE", "title": "Create a free Speech resource",
     "detail": "Azure portal  >  Speech service\nPricing tier: Free F0.\nThen pick the same region here.\n"
               "(Microsoft asks for a card to verify you.)",
     "say": "On the Azure portal, create a Speech resource with the free F zero tier. Then choose the same region here.",
     "sub": "On the Azure portal, create a Speech resource with the free F0 tier. Then choose the same region here.",
     "hl": ["keyurl_tts", "region_tts"],
     "do": [("scroll", 0.0, 0.8, "region_tts", 120), ("move", 0.5, 1.1, "keyurl_tts"), ("move", 3.0, 3.5, "region_tts"),
            ("click", 3.7), ("open", 3.7, "region_tts"), ("move", 4.1, 4.9, ("item", "region_tts", 2)),
            ("click", 5.5), ("pick", 5.5, "tts_region", "westeurope")]},

    {"step": "3 / 3  VOICE", "title": "Paste KEY 1, press Test",
     "detail": "From the Keys and Endpoint page\nof your Speech resource.",
     "say": "Copy key one from Keys and Endpoint, paste it, and press Test. If you hear me, it worked. "
            "Unfortunately for you.",
     "sub": "Copy KEY 1 from Keys and Endpoint, paste it, and press Test. If you hear me, it worked. "
            "Unfortunately for you.",
     "hl": ["key_tts", "test_tts"],
     "do": [("scroll", 0.0, 0.6, "key_tts", 380), ("move", 0.4, 1.0, "key_tts"), ("click", 1.1),
            ("focus", 1.1, "key_tts"), ("type", 1.3, 2.1, "tts_key", 84), ("focus", 2.4, None),
            ("move", 2.4, 2.9, "test_tts"), ("click", 3.1), ("test", 3.1, "tts", "Azure: OK (0.9 s)", 0.9)]},

    {"step": "3 / 3  VOICE", "title": "Saved on its own", "detail": "Changes apply in a second. No save button.",
     "say": "Changes are saved on their own. No button. You are welcome.",
     "hl": ["saved"], "do": [("scroll", 0.0, 0.7, "saved", 700), ("move", 0.5, 1.1, "saved")]},

    {"card": True, "title": "Done", "detail": "Hold push-to-talk and talk to Apiko.",
     "say": "Done. Hold push-to-talk and speak. I will be listening. I always am.",
     "do": [("view", 0.0, "none")]},
]
