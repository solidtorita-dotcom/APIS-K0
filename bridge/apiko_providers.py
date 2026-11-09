"""APIS-K0: the services the player picked in the in-game APIKO Settings window (CET overlay).

providers.json (catalog, shipped in the CET mod folder) lists the providers for the reply model ("llm"), speech
recognition ("stt") and voice ("tts"), with their models, voices, recommendations and notes; the settings window
reads it too. settings.json (same folder) holds the player's choices and API keys: written by the settings
window, reloaded here when it changes, and created from config.json on first run (the setup before the menu).

settings.json:
  {"version": 1,
   "llm": {"provider": "openrouter", "models": {"openrouter": "anthropic/claude-haiku-5.5"}, "urls": {"ollama": "..."}},
   "stt": {"provider": "groq", "models": {"groq": "whisper-large-v3-turbo"}},
   "tts": {"provider": "piper"},
   "keys": {"openrouter": "sk-or-...", "groq": "gsk_..."}}
A model is remembered per provider; a missing one falls back to the catalog's recommended model. For the voice the
player only picks the provider: the voice itself (and the TTS model) is fixed in the catalog, so Apiko always
sounds like Apiko.
No third-party packages here: the bridge must run text-only without the voice packages.
"""

import http.client
import io
import json
import re
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

CATALOG_FILE = "providers.json"
SETTINGS_FILE = "settings.json"
USER_AGENT = "APIS-K0-bridge"
KINDS = ("llm", "stt", "tts")


class ProviderError(RuntimeError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def request(url, body, headers, timeout):
    """POST body (GET when None); returns the response bytes or raises ProviderError (with the HTTP status)."""
    req = urllib.request.Request(url, data=body, headers={"User-Agent": USER_AGENT, **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise ProviderError(f"HTTP {e.code}: {detail}", e.code) from None
    except (OSError, http.client.HTTPException) as e:  # URLError, timeouts, dropped connections
        raise ProviderError(f"connection failed: {e!r}") from None


RETRY_AFTER = re.compile(r"try again in ([\d.]+)\s*(ms|s)", re.IGNORECASE)
MAX_RETRY_WAIT = 6.0


def request_with_retry(url, body, headers, timeout):
    """request(), retried once when the provider says to wait a few seconds (rate limit, HTTP 429)."""
    try:
        return request(url, body, headers, timeout)
    except ProviderError as e:
        match = RETRY_AFTER.search(str(e)) if e.status == 429 else None
        if not match:
            raise
        wait = float(match.group(1)) / (1000.0 if match.group(2).lower() == "ms" else 1.0)
        if wait > MAX_RETRY_WAIT:
            raise
        time.sleep(wait + 0.2)
        return request(url, body, headers, timeout)


def real_key(value):
    value = str(value or "").strip()
    return "" if not value or "PUT-YOUR" in value else value


def recommended_model(entry):
    models = entry.get("models") or []
    for model in models:
        if model.get("badge") == "Recommended":
            return model["id"]
    return models[0]["id"] if models else ""


def migrate(config):
    """settings.json from a config.json written before the in-game menu existed."""
    keys = {}
    llm = "openrouter"
    for provider, host in (("openrouter", "openrouter.ai"), ("groq", "api.groq.com"), ("openai", "api.openai.com")):
        if host in str(config.get("api_base", "")):
            llm = provider
    if real_key(config.get("api_key")):
        keys[llm] = real_key(config["api_key"])
    if real_key(config.get("groq_api_key")):
        keys["groq"] = real_key(config["groq_api_key"])
    settings = {
        "version": 1,
        "llm": {"provider": llm, "models": {}, "urls": {}},
        "stt": {"provider": "groq" if config.get("stt", "groq") == "groq" else "local", "models": {}},
        "tts": {"provider": config.get("tts_engine", "piper")},
        "keys": keys,
    }
    if config.get("model"):
        settings["llm"]["models"][llm] = config["model"]
    return settings


class Settings:
    def __init__(self, mod_dir, config, log):
        self.mod_dir = Path(mod_dir)
        self.log = log
        self.path = self.mod_dir / SETTINGS_FILE
        self.catalog_path = self.mod_dir / CATALOG_FILE
        self.stamp = None
        self.last_error = None
        if not self.catalog_path.exists():
            raise FileNotFoundError(f"{self.catalog_path} missing: install the mod (tools\\build.ps1 -Install)")
        if not self.path.exists():
            self.write(migrate(config))
            log("settings.json created from config.json (edit it in game: APIKO Settings)")
        self.reload()

    def write(self, data):
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        tmp.replace(self.path)

    def file_stamp(self):
        try:
            return self.path.stat().st_mtime_ns, self.catalog_path.stat().st_mtime_ns
        except OSError:
            return None

    def reload(self):
        stamp = self.file_stamp()
        with open(self.catalog_path, encoding="utf-8") as f:
            catalog = json.load(f)
        with open(self.path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("settings.json is not a JSON object")
        for kind in KINDS:
            if not isinstance(data.get(kind), dict):
                data[kind] = {}
        if not isinstance(data.get("keys"), dict):
            data["keys"] = {}
        self.catalog, self.data, self.stamp = catalog, data, stamp

    def check(self):
        """Reloads when either file changed; True if it did. A half-written file is retried on the next check."""
        stamp = self.file_stamp()
        if stamp is None or stamp == self.stamp:
            return False
        try:
            self.reload()
        except (OSError, ValueError) as e:
            if str(e) != self.last_error:
                self.last_error = str(e)
                self.log(f"settings.json not reloaded yet: {e}")
            return False
        self.last_error = None
        return True

    # --- what the player picked ---

    def choice(self, kind, provider=None):
        """Provider for llm / stt / tts resolved against the catalog."""
        section = self.catalog[kind]
        mine = self.data[kind]
        pid = provider or mine.get("provider")
        if pid not in section["providers"]:
            pid = section["default"]
        entry = section["providers"][pid]
        model = str((mine.get("models") or {}).get(pid) or "").strip() or recommended_model(entry)
        base_url = str((mine.get("urls") or {}).get(pid) or entry.get("base_url") or "").strip().rstrip("/")
        key_name = entry.get("key")
        preset = next((m for m in entry.get("models") or [] if m["id"] == model), {})
        return {
            "kind": kind, "id": pid, "label": entry["label"], "entry": entry, "model": model, "preset": preset,
            "base_url": base_url, "key_name": key_name,
            "key": real_key(self.data["keys"].get(key_name)) if key_name else "",
            # Reply models: the player may let them think before answering (slower, dearer; off by default).
            "think": kind == "llm" and self.data["llm"].get("think") is True,
        }

    def llm_chain(self):
        """Reply models to try in order: the player's choice, then (unless the player turned fallback off) the
        catalog's best-to-worst list, skipping repeats and models that cannot be used (no key, model or URL)."""
        first = self.choice("llm")
        chain = [first]
        if self.data["llm"].get("fallback", True) is False:
            return chain
        seen = {(first["id"], first["model"])}
        for item in self.catalog["llm"].get("fallback_order") or []:
            if item.get("provider") not in self.catalog["llm"]["providers"]:
                continue
            candidate = self.choice("llm", item["provider"])
            if item.get("model"):
                candidate = with_model(candidate, item["model"])
            if (candidate["id"], candidate["model"]) in seen or missing(candidate):
                continue
            seen.add((candidate["id"], candidate["model"]))
            chain.append(candidate)
        return chain

    def voice(self, provider, lang):
        """Apiko's voice is ours to pick, not the player's: one fixed voice per provider and language."""
        voices = self.catalog["tts"]["providers"][provider].get("voices") or {}
        return str(voices.get(lang) or voices.get(self.catalog["languages"][0]) or "").strip()

    def describe(self):
        llm, stt, tts = (self.choice(kind) for kind in KINDS)
        return f"model {llm['label']} ({llm['model'] or 'none'}{', thinks' if llm['think'] else ''}), speech {stt['label']}, voice {tts['label']}"


def with_model(choice, model):
    preset = next((m for m in choice["entry"].get("models") or [] if m["id"] == model), {})
    return {**choice, "model": model, "preset": preset}


def reason(error):
    """Short, readable cause of a failed call (for the in-game notice)."""
    status = getattr(error, "status", None)
    if status in (401, 403):
        return "invalid key"
    if status == 402:
        return "no credits"
    if status == 429:
        return "rate limit"
    if status and status >= 500:
        return "server error"
    return str(error)[:80]


def missing(choice):
    """Why this choice cannot be used yet, or None."""
    if choice["key_name"] and not choice["key"]:
        return f"No API key for {choice['label']}: add it in APIKO Settings (CET overlay)."
    if choice["kind"] == "llm" and not choice["model"]:
        return f"No model chosen for {choice['label']}: pick or type one in APIKO Settings."
    if choice["entry"].get("url_editable") and not choice["base_url"]:
        return f"No URL for {choice['label']}: set it in APIKO Settings."
    return None


# ----------------------------------------------------------------------------------------------------------
# Reply model: any OpenAI-compatible chat endpoint


def explicit_cache(choice):
    """Anthropic models through OpenRouter only cache with cache_control marks. OpenAI, Groq, DeepSeek, Gemini...
    cache repeated prefixes by themselves."""
    return choice["id"] == "openrouter" and str(choice["model"]).startswith("anthropic/")


def prepare_messages(messages, explicit):
    """Messages may carry "cache": True at the end of a prefix that repeats next turn. With `explicit`, that message
    gets a cache_control breakpoint; otherwise the mark is just dropped. Consecutive system messages are joined into
    one (some providers reject several), keeping their order so the fixed part stays first."""
    out = []
    for message in messages:
        content = message["content"]
        if explicit:
            content = [{"type": "text", "text": content}]
            if message.get("cache"):
                # 1 h instead of the default 5 min: Apiko talks in bursts with long silences, and with 5 min most
                # turns after a pause paid the whole prompt again. Writing costs 2x instead of 1.25x.
                content[0]["cache_control"] = {"type": "ephemeral", "ttl": "1h"}
        if message["role"] == "system" and out and out[-1]["role"] == "system":
            out[-1]["content"] = out[-1]["content"] + (content if explicit else "\n\n" + content)
            continue
        out.append({"role": message["role"], "content": content})
    return out


def chat(choice, messages, json_mode=True, max_tokens=400, timeout=30, think=True):
    """Returns (text, usage). Optional fields a provider rejects (HTTP 400) are dropped and the call retried.
    `think=False` keeps the catalog's lowest reasoning even when the player turned thinking on (background calls)."""
    problem = missing(choice)
    if problem:
        raise ProviderError(problem)
    entry = choice["entry"]
    tokens_field = entry.get("max_tokens_field", "max_tokens")
    body = {"model": choice["model"], "messages": prepare_messages(messages, explicit_cache(choice)),
            tokens_field: max_tokens}
    optional = {}
    if json_mode:
        optional["response_format"] = {"type": "json_object"}
    # The catalog's effort is the least each model allows ("none" where it can stop thinking altogether). Thinking
    # on = the model's own default (no field): on Haiku "low" already means no thinking at all (measured 2026-11-07).
    effort = choice["preset"].get("reasoning_effort")
    if think and choice.get("think"):
        effort = None
    if effort and entry.get("reasoning") == "openrouter":
        optional["reasoning"] = {"effort": effort}
    elif effort and entry.get("reasoning") == "openai":
        optional["reasoning_effort"] = effort
    headers = {"Content-Type": "application/json"}
    if choice["key"]:
        headers["Authorization"] = "Bearer " + choice["key"]
    if choice["id"] == "openrouter":
        headers["X-Title"] = "APIS-K0 (Cyberpunk 2077 mod)"
    url = choice["base_url"] + "/chat/completions"
    try:
        raw = request_with_retry(url, json.dumps({**body, **optional}).encode("utf-8"), headers, timeout)
    except ProviderError as e:
        if e.status != 400 or not (optional or explicit_cache(choice)):
            raise
        # Plain request: no optional fields and no cache marks.
        body["messages"] = prepare_messages(messages, False)
        raw = request_with_retry(url, json.dumps(body).encode("utf-8"), headers, timeout)
    try:
        result = json.loads(raw)
    except ValueError as e:
        raise ProviderError(f"bad response: {e}") from None
    if "error" in result:
        raise ProviderError(str(result["error"])[:300])
    try:
        return result["choices"][0]["message"].get("content") or "", result.get("usage") or {}
    except (KeyError, IndexError, TypeError, AttributeError):
        raise ProviderError(f"unexpected response: {str(result)[:300]}") from None


# ----------------------------------------------------------------------------------------------------------
# Speech recognition: OpenAI-compatible /audio/transcriptions (Groq, OpenAI)

LANGUAGE_NAMES = {"spanish": "es", "english": "en", "french": "fr", "german": "de", "italian": "it",
                  "portuguese": "pt", "polish": "pl", "russian": "ru", "japanese": "ja", "chinese": "zh"}


def transcribe(choice, wav_bytes, language, prompt, timeout=8):
    """Returns (text, two-letter language or '')."""
    problem = missing(choice)
    if problem:
        raise ProviderError(problem)
    fields = {"model": choice["model"], "response_format": "verbose_json", "temperature": "0", "prompt": prompt}
    if language:
        fields["language"] = language
    boundary = uuid.uuid4().hex
    body = io.BytesIO()
    for name, value in fields.items():
        body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="speech.wav"\r\n'
               "Content-Type: audio/wav\r\n\r\n".encode())
    body.write(wav_bytes)
    body.write(f"\r\n--{boundary}--\r\n".encode())
    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}", "Authorization": "Bearer " + choice["key"]}
    raw = request(choice["base_url"] + "/audio/transcriptions", body.getvalue(), headers, timeout)
    try:
        result = json.loads(raw)
    except ValueError as e:
        raise ProviderError(f"bad response: {e}") from None
    detected = str(result.get("language") or language or "").lower()
    return str(result.get("text") or "").strip(), LANGUAGE_NAMES.get(detected, detected)


def timed(function, *args, **kwargs):
    started = time.time()
    result = function(*args, **kwargs)
    return result, time.time() - started
