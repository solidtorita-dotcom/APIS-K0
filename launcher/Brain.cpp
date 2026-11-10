#include "Brain.hpp"

#include "Log.hpp"
#include "Paths.hpp"
#include "Text.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <regex>
#include <set>

namespace apiko
{
namespace
{
using Json = nlohmann::json;

// Messages older than this when read (bridge busy or started late) are dropped.
constexpr std::int64_t StaleSaySeconds = 120;
constexpr std::int64_t StaleTestSeconds = 10;
// World events and heard lines older than this when read are dropped (a bridge started late).
constexpr std::int64_t StaleWorldSeconds = 30;
constexpr std::int64_t StaleEventSeconds = 20;
// A warning ("sniper!") that waited longer than this is useless.
constexpr std::int64_t WarningStaleSeconds = 6;
// A district (sub-district included) Apiko was in this recently is not remarked again; a change of sub-district only
// (same district) has this fraction of the usual chance.
constexpr double DistrictRevisitSeconds = 900;
constexpr double SameDistrictFactor = 0.25;
// The part of the first contact said in V's head, while the link chip loads: a more distorted voice.
constexpr double HeadInstability = 0.75;
// Apiko cutting off the beacon's call: its voice sounds very broken.
constexpr double BeaconInstability = 0.85;

// Chance that Apiko comments an event (times the "chatter" setting). "wake" always gets an answer. Chat events
// (combat, time of day, districts...) are written lines with their own chance (barks::ChatChance).
const std::map<std::string, double> EventChance = {
    {"wake", 1.0}, {"scene_end", 0.3},
    // Device events are answered from barks.json (React); these older game events are ignored.
    {"network_breached", 0.0}, {"network_pinged", 0.0}, {"alarm", 0.0},
    // The rare world events that go to the model instead of a written line (React already rolled the chance).
    {"device_spotted", 1.0}, {"device_hostile", 1.0}, {"device_alarm", 1.0}, {"device_breached", 1.0},
    {"device_pinged", 1.0}, {"device_destroyed", 1.0}, {"device_hacked", 1.0}, {"enemy_detected", 1.0},
    {"enemy_stealth_kill", 1.0}, {"enemy_knockout", 1.0}};

const std::map<std::string, std::string> EventDescription = {
    // The find (ApisK0Find.reds): V took the link chip from NetWatch's case and plugged it in.
    {"first_wake", "V just plugged your NetWatch link chip into their own head: for the first time since you escaped "
                   "the transfer, someone answered. You flew in from where you were hiding and V is the first thing "
                   "you see. You don't know who V is yet."},
    {"wake", "You are back online, next to V."},
    {"combat_start", "A fight just started around V."},
    {"combat_end", "The fight is over."},
    {"entered_district", "V just entered a different district. Don't just name it: one remark about it, or nothing."},
    {"nightfall", "Night has fallen."},
    {"dawn", "The sun is coming up."},
    {"low_health", "V is badly hurt in the middle of a fight."},
    {"scene_end", "A conversation V had just ended ([last conversation V had]). At most one cold remark or judgment "
                  "about it, never a summary; or nothing."},
    {"network_breached", "V just breached a local network: you can now feel every device on it."},
    {"network_pinged", "V just pinged a local network: for a moment you felt every device on it."},
    {"alarm", "A security alarm just went off near V."},
    {"device_spotted", "A camera or turret just started tracking V."},
    {"device_hostile", "A security turret just turned hostile to V."},
    {"device_alarm", "A security alarm just went off near V."},
    {"device_breached", "V just breached a local network: you can now feel every device on it."},
    {"device_pinged", "V just pinged a local network: for a moment you felt every device on it."},
    {"device_destroyed", "A device near V was just destroyed."},
    {"device_hacked", "V just quickhacked a device."},
    {"enemy_detected", "An enemy just detected V and is attacking."},
    {"enemy_stealth_kill", "V just killed an enemy that never knew V was there."},
    {"enemy_knockout", "V just knocked an enemy out instead of killing them."},
    // Written-line situations the model sometimes improvises instead.
    {"idle_check", "A long quiet moment: neither of you has spoken for a while and nothing is going on. One loose "
                   "thought of your own, unprompted (a glitch, a memory fragment, your nanny firmware), or nothing."},
    {"civilian_killed", "V just killed a civilian."},
    {"police_killed", "V just killed an NCPD officer."},
    {"boss_down", "V just took down a dangerous boss."},
    {"heat_lost", "V just shook off the NCPD: the wanted level is back to zero."},
    {"body_hidden", "V just hid a body in a container."},
    {"quest_done", "V just finished a job. A cold judgment at most; never name it."},
    {"quest_failed", "V just failed a job. A cold judgment at most; never name it."},
    {"sms", "V just got a text message. Don't read it out or guess what it says."}};

// Events of the find, the phone and home: written scripts (phase 2c-3).
bool ScriptedEvent(const std::string& aEvent)
{
    return aEvent == "beacon_call" || aEvent == "first_contact_head" || aEvent.rfind("first_wake:", 0) == 0 ||
           aEvent == "home_greet" || aEvent.rfind("phone_call:", 0) == 0 || aEvent == "dev_say" ||
           aEvent == "find_shard_late" || aEvent.rfind("antenna_", 0) == 0 || aEvent.rfind("ping_", 0) == 0;
}

// "Watson, Northside" -> "Northside" (Python's split(", ")[-1]).
std::string LastPart(const std::string& aPlace)
{
    auto at = aPlace.rfind(", ");
    return at == std::string::npos ? aPlace : aPlace.substr(at + 2);
}
constexpr std::size_t MaxFacts = 30;
constexpr std::size_t MaxPlansKept = 5;
// Gaps between game messages longer than this are not play time (game closed, paused in a menu...).
constexpr double PlaytimeGap = 300;
// A short conversation is not worth a summary call on a load: it stays as history.
constexpr std::size_t MinFoldMessages = 6;
// Save loads remembered as already folded (folded_versions.json).
constexpr std::size_t FoldedKeep = 300;
// Game time without talking after which Apiko is told how long it has been.
constexpr std::int64_t SilenceGameSeconds = 6 * 3600;

// Each mood is a face on the drone's screen (DISENO.md, "Caras por estado de ánimo"); no "scared": Apiko never shows fear.
// "neutral": a plain answer, the screen keeps the face it has (the reaction face, or the resting one).
const std::set<std::string> Moods = {"curious",  "happy",     "laughing", "bored",
                                     "angry",    "sad",       "confused", "surprised",
                                     "glitching", "neutral"};

// The reaction face (Brain::ReactFace): the faces it may put up, the call's limits, and how long the face stays
// when no reply replaces it (a silent reply, a slow model). The model answers one word.
const std::set<std::string> ReactionFaces = {"happy", "laughing", "bored", "angry", "sad", "confused", "surprised"};
constexpr int ReactionTokens = 20;
// The prompt's "Right now" line on Apiko's antenna (the game's "antenna" sensor): with it, the ping (the reply's
// "ping" field, which the game turns into the vanilla Ping quickhack on the nearest enemy).
const char* const AntennaOnRule =
    "- Your long-range antenna is back: you can ping (\"ping\": true) when V asks you to ping or scan, or when you need "
    "to know what is around (a hostile place and nothing known); it marks the enemies near V for both of you. The "
    "game tells you the result: never invent what the ping found.";
const char* const AntennaOffRule =
    "- Without your long-range antenna you cannot ping: if V asks you to, say you can't (never claim you did).";
// Brain::WornOut: how many of Apiko's last replies are checked for its worn-out topics.
constexpr std::size_t WornOutReplies = 6;
constexpr double ReactionTimeout = 4.0;
constexpr double ReactionSeconds = 8.0;
const char* const ReactionPrompt =
    "You are Apiko, a cold, sarcastic AI fragment trapped in a drone whose screen shows cartoon faces. You put a face "
    "up to mock V or to make your point obvious, never to show real feelings, and you are never scared. The user "
    "message is what V just said to you (maybe from speech recognition, in any language). Pick the face you put up "
    "at once, before you answer. Reply with exactly one word: happy, laughing, bored, angry, sad, confused, "
    "surprised, or none when nothing in V's words calls for a face (most lines).";

// Sensors whose changes are worth a [changed] line.
constexpr const char* NotableSensors[] = {"district", "weather", "in_combat", "v_in_vehicle"};
// Time and weather only when asked about (or on events, or when they change): if the model sees them, it mentions
// them.
const std::set<std::string> AmbientSensors = {"time", "weather"};
// Readings described apart (phase 2c) or only for the bridge, not the sensors line.
const std::set<std::string> HiddenSensors = {
    "devices",   "enemies",        "game_seconds",       "district_keys", "quests_done",    "quest",
    "objective", "objective_meters", "quest_type",       "objectives_done", "quest_description", "tension",
    "crowd",     "crowd_panic",    "witnesses",          "wanted_stars",  "police",         "named_here",
    "companions", "vendors_near",  "fight_nearby",       "bodies",        "notable_loot",   "vehicles",
    "antenna"};

std::string Str(const Json& aObject, const char* aKey)
{
    if (!aObject.is_object())
        return {};
    auto it = aObject.find(aKey);
    if (it == aObject.end() || it->is_null())
        return {};
    return it->is_string() ? it->get<std::string>() : it->dump();
}

std::int64_t Age(const Json& aMessage)
{
    auto it = aMessage.find("t");
    return it != aMessage.end() && it->is_number() ? UnixSeconds() - it->get<std::int64_t>() : 0;
}

std::size_t CharCount(const std::string& aText)
{
    return static_cast<std::size_t>(
        std::count_if(aText.begin(), aText.end(), [](char c) { return (static_cast<unsigned char>(c) & 0xC0) != 0x80; }));
}

// The model is asked for JSON; tolerate code fences or extra text around it, or plain text.
Json ParseReply(const std::string& aText)
{
    auto open = aText.find('{');
    auto close = aText.rfind('}');
    if (open != std::string::npos && close != std::string::npos && close > open)
    {
        auto data = Json::parse(aText.substr(open, close - open + 1), nullptr, false);
        if (data.is_object())
            return data;
    }
    // A reply cut short (out of tokens) is half a JSON object: keep what "say" had, up to its last full sentence,
    // instead of reading the braces out loud.
    static const std::regex sayStart(R"("say"\s*:\s*")");
    std::smatch match;
    if (std::regex_search(aText, match, sayStart))
    {
        std::string raw;
        for (std::size_t i = match.position(0) + match.length(0); i < aText.size() && aText[i] != '"'; ++i)
        {
            raw += aText[i];
            if (aText[i] == '\\' && i + 1 < aText.size())
                raw += aText[++i];
        }
        auto decoded = Json::parse("\"" + raw + "\"", nullptr, false);
        std::string said = decoded.is_string() ? decoded.get<std::string>() : raw;
        auto trimmed = text::Trim(said);
        std::size_t cut = std::string::npos;
        if (!trimmed.empty() && (trimmed.back() == '.' || trimmed.back() == '?' || trimmed.back() == '!'))
            return {{"say", trimmed}};
        for (const char* end : {". ", "? ", "! "})
        {
            auto at = said.rfind(end);
            if (at != std::string::npos && (cut == std::string::npos || at > cut))
                cut = at;
        }
        return {{"say", cut == std::string::npos ? std::string() : text::Trim(said.substr(0, cut + 1))}};
    }
    if (text::Trim(aText).rfind('{', 0) == 0)
        return {{"say", ""}};
    return {{"say", text::Trim(aText)}};
}

int ToInt(const Json& aValue, int aDefault = 0)
{
    try
    {
        if (aValue.is_number())
            return aValue.get<int>();
        if (aValue.is_string())
            return std::stoi(aValue.get<std::string>());
    }
    catch (const std::exception&)
    {
    }
    return aDefault;
}

// Sensor lines for one turn. Uneventful readings are left out (full health out of combat, not driving, not
// fighting; time and weather unless aAmbient): the less there is to read, the less the model recites it.
std::string DescribeState(const Json& aState, const Json& aPrevious, bool aAmbient)
{
    if (!aState.is_object() || aState.empty())
        return "[sensors] (no sensor data)";
    std::map<std::string, std::string> shown;
    for (const auto& [key, value] : aState.items())
    {
        auto text = value.is_string() ? value.get<std::string>() : value.dump();
        if (!text.empty() && !HiddenSensors.count(key) && (aAmbient || !AmbientSensors.count(key)))
            shown[key] = text;
    }
    double health = 100.0;
    try
    {
        if (shown.count("v_health_percent"))
            health = std::stod(shown["v_health_percent"]);
    }
    catch (const std::exception&)
    {
    }
    // 0 means the reading failed (V alive is never at 0 %).
    if (health <= 0 || (health >= 70 && shown["in_combat"] != "yes"))
        shown.erase("v_health_percent");
    for (const char* key : {"in_combat", "v_in_vehicle"})
        if (shown.count(key) && (shown[key] == "no" || shown[key].empty()))
            shown.erase(key);
    std::string line = "[sensors, background only] ";
    bool first = true;
    for (const auto& [key, value] : shown)
    {
        line += (first ? "" : "; ") + key + "=" + value;
        first = false;
    }
    if (aPrevious.is_object() && !aPrevious.empty())
    {
        std::string changes;
        for (const char* key : NotableSensors)
        {
            if (!aState.contains(key))
                continue;
            auto before = aPrevious.contains(key) ? Str(aPrevious, key) : "?";
            auto now = Str(aState, key);
            if (before != now)
                changes += (changes.empty() ? "" : "; ") + std::string(key) + ": " + before + " -> " + now;
        }
        if (!changes.empty())
            line += "\n[changed since last turn] " + changes;
    }
    return line;
}

// "[time since you last talked with V] ..." when a lot of game time has passed since the last turn.
std::string DescribeSilence(const Json& aState, const Json& aLast)
{
    std::int64_t now = 0, last = 0;
    try
    {
        now = std::stoll(Str(aState, "game_seconds").empty() ? "0" : Str(aState, "game_seconds"));
        last = aLast.is_number() ? aLast.get<std::int64_t>() : 0;
    }
    catch (const std::exception&)
    {
        return {};
    }
    auto gap = now - last;
    if (!last || gap < SilenceGameSeconds)
        return {};
    double hours = gap / 3600.0;
    auto span = hours < 48 ? "about " + std::to_string(std::lround(hours)) + " hours"
                           : "about " + std::to_string(std::lround(hours / 24)) + " days";
    return "[time since you last talked with V] " + span + " (game time)";
}

bool Matches(const std::regex& aPattern, const std::string& aText)
{
    return std::regex_search(aText, aPattern);
}

const std::regex& SwearWords()
{
    static const std::regex pattern(
        R"(\b(puta|puto|joder|jodido|mierda|co(ñ|n)o|cabr(o|ó)n|gilipollas|hostia|capullo|imb(e|é)cil|)"
        R"(fuck\w*|shit\w*|bitch\w*|damn|asshole|bastard|dick)\b)",
        std::regex::icase);
    return pattern;
}

// "remember" entries that are just a log of the conversation or of where V went, not lasting facts.
const std::regex& NotAFact()
{
    static const std::regex pattern(R"(^(V|Apiko) (asked|asks|entered|enters|went to|requested)\b)", std::regex::icase);
    return pattern;
}

const std::regex& AsksAmbient()
{
    static const std::regex pattern(
        R"(\b(hora|horas|tarde|noche|d(i|í)a|tiempo|clima|llueve|lluvia|llover|sol|fr(i|í)o|calor|d(o|ó)nde|estamos|)"
        R"(time|late|night|day|weather|rain|raining|sun|cold|hot|where)\b)",
        std::regex::icase);
    return pattern;
}

double SteadySeconds()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::string Fixed1(double aValue)
{
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.1f", aValue);
    return buffer;
}
} // namespace

Brain::Brain(GameFiles& aFiles, const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir)
    : files(aFiles)
    , modDir(aModDir)
    , dataDir(aDataDir)
    , settings(aModDir)
    , store(aDataDir)
{
}

void Brain::Start()
{
    auto shipped = modDir / L"data";
    config = paths::LoadConfig(shipped);
    auto prompt = text::ReadFile(shipped / L"prompt.md");
    if (!prompt)
        throw std::runtime_error("prompt.md missing in " + text::PathString(shipped) + ": install the mod");
    promptTemplate = *prompt;
    settings.Check(log::Write);
    auto language = text::Lower(config.value("default_language", std::string("English")));
    for (const auto& [name, code] : providers::LanguageNames())
        if (name == language)
            defaultLang = code;
    lastLang = defaultLang;
    memory.Load(dataDir / L"memory.json");
    lore.Load(shipped / L"lore.json");
    barks.Load(shipped / L"barks.json");
    if (auto script = text::ReadFile(shipped / L"first_contact.json"))
        firstContact = Json::parse(*script, nullptr, false);
    if (!firstContact.is_object())
    {
        log::Write("first contact script not loaded (first_contact.json)");
        firstContact = Json::object();
    }
    if (config.value("voice_enabled", true))
    {
        voice = std::make_unique<voice::Voice>(settings, settingsMutex, config, modDir, dataDir);
        if (!voice->Start())
            voice.reset();
        ears = std::make_unique<ears::Ears>(settings, settingsMutex, config, dataDir.parent_path() / L"models" / L"whisper-cpp");
    }
    else
        log::Write("voice disabled (voice_enabled false in config.json): subtitles only");
    lastVTalk = SteadySeconds();
    log::Write("brain ready: " + settings.Describe() + ". Affinity: " + std::to_string(memory.data.value("affinity", 0)) +
               ".");
    WarnMissing();
}

void Brain::CheckSettings()
{
    {
        std::lock_guard lock(settingsMutex);
        if (!settings.Check(log::Write))
            return;
    }
    log::Write("settings reloaded: " + settings.Describe());
    WarnMissing();
}

void Brain::WarnMissing()
{
    if (auto problem = providers::Missing(settings.Pick("llm")))
    {
        log::Write(*problem);
        files.WriteReply("status", *problem);
    }
}

void Brain::Tick()
{
    std::vector<Pending> due;
    {
        std::lock_guard lock(cueMutex);
        auto now = std::chrono::steady_clock::now();
        for (auto it = cues.begin(); it != cues.end();)
        {
            if (it->due <= now)
            {
                due.push_back(*it);
                it = cues.erase(it);
            }
            else
                ++it;
        }
    }
    for (const auto& reply : due)
        files.WriteReply(reply.kind, reply.text, reply.duration);
}

void Brain::ReplyAfter(double aSeconds, const std::string& aKind, const std::string& aText, double aDuration)
{
    std::lock_guard lock(cueMutex);
    cues.push_back({std::chrono::steady_clock::now() + std::chrono::milliseconds(static_cast<int>(aSeconds * 1000)),
                    aKind, aText, aDuration});
}

void Brain::CueAfter(const Spoken& aSpoken, const std::string& aCue, double aMinimum)
{
    // With voice: once the reply has sounded (a short silence queued after it). Without: after its subtitles' time.
    if (aSpoken.generation && voice)
    {
        voice->Queue(*aSpoken.generation, std::vector<float>(2400, 0.0f), [this, aCue] { files.WriteReply("cue", aCue); });
        return;
    }
    ReplyAfter(std::max(aMinimum, aSpoken.seconds), "cue", aCue);
}

void Brain::Hush()
{
    if (voice)
        voice->NewReply();
}

void Brain::StartListening()
{
    Hush(); // V talks over Apiko: it shuts up at once
    if (ears)
        ears->Start();
}

std::optional<Brain::Json> Brain::StopListening(const Json& aMessage)
{
    if (!ears)
        return std::nullopt;
    auto audio = ears->Stop();
    if (!audio)
        return std::nullopt;
    {
        std::lock_guard lock(clipsMutex);
        clips.push_back(std::move(*audio));
    }
    auto message = aMessage;
    message["type"] = "voice";
    return message;
}

void Brain::Hear(const Json& aMessage)
{
    std::vector<float> audio;
    {
        std::lock_guard lock(clipsMutex);
        if (clips.empty())
            return;
        audio = std::move(clips.front());
        clips.pop_front();
    }
    if (Age(aMessage) > StaleSaySeconds || !ears)
        return;
    auto started = std::chrono::steady_clock::now();
    std::optional<std::pair<std::string, std::string>> heard;
    try
    {
        heard = ears->Transcribe(audio);
    }
    catch (const std::exception& e)
    {
        log::Write(std::string("speech recognition failed: ") + e.what());
        files.WriteReply("status", text::Truncate(std::string("speech recognition failed: ") + e.what(), 300));
        return;
    }
    auto seconds = Fixed1(std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
    if (!heard)
    {
        files.WriteReply("status", "(no speech recognised)");
        return;
    }
    char audioSeconds[16];
    std::snprintf(audioSeconds, sizeof(audioSeconds), "%.1f", audio.size() / static_cast<double>(ears::MicRate));
    log::Write("heard (" + heard->second + ", " + audioSeconds + "s of audio, recognised in " + seconds +
               "s): " + heard->first);
    files.WriteReply("heard", text::CleanSay(heard->first));
    auto said = aMessage;
    said["type"] = "say";
    said["text"] = heard->first;
    Say(said);
}

void Brain::Handle(const Json& aMessage)
{
    FlushPlaytime();
    auto type = Str(aMessage, "type");
    if (type == "memory_load")
    {
        SetGameLanguage(Str(aMessage, "language"));
        LoadMemory(aMessage);
    }
    else if (type == "say")
    {
        Say(aMessage);
    }
    else if (type == "test")
    {
        if (Age(aMessage) <= StaleTestSeconds)
            Test(Str(aMessage, "what"));
    }
    else if (type == "voice")
        Hear(aMessage);
    else if (type == "warm_up")
    {
        if (voice)
            voice->WarmUp();
        if (ears)
            ears->WarmUp();
    }
    else if (type == "event")
        Event(aMessage);
    else if (type == "world_react")
        React(aMessage);
}

double Brain::Config(const char* aKey, double aDefault) const
{
    auto it = config.find(aKey);
    return it != config.end() && it->is_number() ? it->get<double>() : aDefault;
}

double Brain::Roll()
{
    return std::uniform_real_distribution<double>(0.0, 1.0)(random);
}

void Brain::Event(const Json& aMessage)
{
    auto event = Str(aMessage, "event");
    auto age = Age(aMessage);
    const auto& state = aMessage.contains("state") && aMessage["state"].is_object() ? aMessage["state"] : Json::object();
    auto now = SteadySeconds();
    if (ScriptedEvent(event))
    {
        Scripted(event, age, state, aMessage);
        return;
    }
    auto found = EventDescription.find(event);
    auto description = found == EventDescription.end() ? std::string() : found->second;
    // First wake in this save (the game says so): a fresh Apiko. The only place memory is ever reset.
    if (event == "first_wake")
    {
        log::Write("memory: first wake in this save, Apiko starts from scratch");
        memory.Replace(Memory::Fresh());
        diary.Clear();
        hearing.Clear();
        event = "wake";
    }
    // Districts: crossing back and forth between two sub-districts made Apiko name the place every time.
    double chanceFactor = 1.0;
    if (event == "entered_district")
    {
        auto place = Str(state, "district");
        auto previous = currentDistrict;
        currentDistrict = place;
        auto visited = visitedDistricts.find(place);
        bool recent = visited != visitedDistricts.end() && now - visited->second < DistrictRevisitSeconds;
        visitedDistricts[place] = now;
        if (recent)
            return;
        if (!previous.empty() && LastPart(previous) == LastPart(place))
            chanceFactor = SameDistrictFactor; // only the sub-district changed
    }
    // The first words wait for a bridge started a bit late.
    if (age > (event == "wake" ? StaleSaySeconds : StaleEventSeconds))
        return;
    // V is talking with someone: Apiko keeps quiet (it may remark on it when the conversation ends).
    if (event != "wake" && hearing.InScene())
        return;
    // Combat, health, time of day, districts and long silences are written lines; the model only gets them when it
    // improvises.
    if (barks::ChatChance(event) || event == "idle_check")
    {
        if (EventLine(event, state, chanceFactor))
            return;
        log::Write("event to the model (improvised): " + event);
    }
    else if (event != "wake" && aMessage.value("rolled", Json(false)) != true)
    {
        if (now - lastSpoken < Config("chatter_cooldown_seconds", 90))
            return;
        auto chance = EventChance.find(event);
        if (Roll() > (chance == EventChance.end() ? 0.3 : chance->second) * Config("chatter", 1.0) * chanceFactor)
            return;
    }
    Turn("[event: " + event + "] " + description, "", state);
}

void Brain::Scripted(const std::string& aEvent, std::int64_t aAge, const Json& aState, const Json& aMessage)
{
    // The find's first contact is written, not improvised: the part in V's head while the chip loads, then the rest
    // when the drone arrives ("first_wake:" + what V did, e.g. "first_wake:shard_read,ortega").
    if (aEvent == "beacon_call")
    {
        // V answered the beacon's call: NetWatch's recording, cut off by Apiko.
        if (aAge <= StaleSaySeconds)
            BeaconCall();
        else
            files.WriteReply("cue", "beacon_done");
    }
    else if (aEvent == "first_contact_head")
    {
        if (aAge <= StaleSaySeconds)
            FirstContactHead();
    }
    else if (aEvent.rfind("first_wake:", 0) == 0)
    {
        log::Write("memory: first wake in this save (the find), Apiko starts from scratch");
        memory.Replace(Memory::Fresh());
        diary.Clear();
        hearing.Clear();
        if (aAge <= StaleSaySeconds)
        {
            std::set<std::string> flags;
            auto list = aEvent.substr(std::string("first_wake:").size());
            for (std::size_t start = 0;;)
            {
                auto end = list.find(',', start);
                flags.insert(list.substr(start, end == std::string::npos ? std::string::npos : end - start));
                if (end == std::string::npos)
                    break;
                start = end + 1;
            }
            FirstContactRest(flags, aState);
        }
    }
    else if (aEvent == "home_greet")
    {
        // V came home, where Apiko stays when sent away: a written greeting.
        if (aAge <= StaleEventSeconds)
            SayWritten("home_greet", aState);
    }
    else if (aEvent.rfind("ping_", 0) == 0)
    {
        // Apiko's ping (ApisK0System.ApikoPing): done, nobody around, or too soon. A written line.
        if (aAge <= StaleEventSeconds)
            SayWritten(aEvent, aState);
    }
    else if (aEvent.rfind("antenna_", 0) == 0)
    {
        // The antenna mission (ApisK0Antenna.reds): its start, Apiko tracking its quest again, and at the site its
        // arrival, the server's memories, the body bags and the mounting. Written lines (barks.json, the event's name).
        // The mounting always answers: the game waits for its "antenna_done" cue (or a timeout).
        if (aAge <= StaleEventSeconds || aEvent == "antenna_mounted")
            AntennaLine(aEvent, aState);
    }
    else if (aEvent.rfind("phone_call:", 0) == 0)
    {
        // V called the APIKO contact ("phone_call:away" brings it back, "phone_call:present": it is right here).
        if (aAge <= StaleEventSeconds)
            PhoneCall(aEvent == "phone_call:present", aState);
    }
    else if (aEvent == "dev_say")
    {
        // Development (dev.lua): Apiko says a written text as it is, for recordings. Not kept in the history.
        auto said = text::Trim(Str(aMessage, "text"));
        if (!said.empty() && aAge <= StaleSaySeconds)
        {
            log::Write("dev: written line");
            auto lang = text::Lower(Str(aMessage, "lang")).substr(0, 2);
            Speak(said, lang.empty() ? lastLang : lang, Config("base_instability", 0.2), 0, true, true);
            lastSpoken = SteadySeconds();
        }
    }
    else if (aEvent == "find_shard_late")
    {
        // V took Kessler's warning shard after the first contact: a written line too.
        if (aAge <= StaleEventSeconds)
            FirstContactExtra("shard_late", "V took agent Kessler's shard (his warning report about you) from his "
                                            "body, after already plugging your chip in.");
    }
}

std::pair<std::vector<std::string>, std::string> Brain::FirstContactLines(const std::vector<std::string>& aParts) const
{
    // The first contact's sentences for these parts, in V's language (else English), and that language.
    auto lang = firstContact.contains(lastLang) ? lastLang : std::string("en");
    std::vector<std::string> lines;
    if (firstContact.contains(lang) && firstContact[lang].is_object())
        for (const auto& part : aParts)
        {
            auto it = firstContact[lang].find(part);
            if (it != firstContact[lang].end() && it->is_array())
                for (const auto& line : *it)
                    if (line.is_string())
                        lines.push_back(line.get<std::string>());
        }
    return {lines, lang};
}

namespace
{
std::string JoinLines(const std::vector<std::string>& aLines)
{
    std::string text;
    for (const auto& line : aLines)
        text += (text.empty() ? "" : " ") + line;
    return text;
}
} // namespace

void Brain::BeaconCall()
{
    // NetWatch's recorded recovery message, cut off by Apiko's written line, both subtitled (NETWATCH, then the
    // unknown speaker). The game hangs up on the "beacon_done" cue. Not in the history: the first wake starts
    // Apiko's memory from scratch anyway. Without voice (phase 3 brings the recording): subtitles timed by length.
    auto [netwatch, lang] = FirstContactLines({"beacon_netwatch"});
    auto recording = JoinLines(netwatch);
    auto line = JoinLines(FirstContactLines({"beacon_apiko"}).first);
    if (!files.GameLive())
    {
        files.WriteReply("cue", "beacon_done");
        return;
    }
    log::Write("find: beacon call");
    if (voice && !voice->Unavailable(voice->Language(lang)))
    {
        // NetWatch's recording (data\beacon_<lang>.wav, else English: the same voice for everyone), then Apiko cutting
        // it off over the same line, much more broken.
        int generation = voice->NewReply();
        auto audio = voice::LoadWav(modDir / L"data" / text::Widen("beacon_" + lang + ".wav"));
        if (!audio)
            audio = voice::LoadWav(modDir / L"data" / L"beacon_en.wav");
        if (audio)
        {
            float peak = 0.0f;
            for (float v : *audio)
                peak = std::max(peak, std::abs(v));
            float gain = static_cast<float>(Config("voice_volume", 0.8)) / (peak > 0 ? peak : 1.0f);
            for (auto& v : *audio)
                v *= gain;
            double seconds = static_cast<double>(audio->size()) / voice::Rate + 0.2;
            voice->Queue(generation, std::move(*audio), [this, recording, seconds] {
                if (!recording.empty())
                    files.WriteReply("sayn", recording, seconds);
            });
        }
        else
            log::Write("beacon recording missing (data\\beacon_*.wav): Apiko's line only");
        if (!line.empty())
            SpeakAloud(line, voice->Language(lang), BeaconInstability, SIZE_MAX, true, true, generation);
        CueAfter({generation, 0.0}, "beacon_done");
        lastSpoken = SteadySeconds();
        return;
    }
    double first = std::max(3.0, 1.5 + CharCount(recording) / 14.0);
    double second = std::max(2.0, 1.5 + CharCount(line) / 14.0);
    if (!recording.empty())
        files.WriteReply("sayn", recording, first);
    if (!line.empty())
        ReplyAfter(first, "sayu", line, second);
    ReplyAfter(first + second, "cue", "beacon_done");
    lastSpoken = SteadySeconds();
}

void Brain::FirstContactHead()
{
    // V plugged the link chip in: Apiko in V's head. The game keeps the screen glitching until the "head_done" cue.
    auto [lines, lang] = FirstContactLines({"head"});
    if (lines.empty())
    {
        files.WriteReply("cue", "head_done");
        return;
    }
    log::Write("first contact: in V's head");
    auto said = JoinLines(lines);
    // An unknown voice: Apiko has not given its name yet. More distorted: it speaks inside V's head.
    auto spoken = Speak(said, lang, HeadInstability, SIZE_MAX, true, true);
    CueAfter(spoken, "head_done", 3.0);
    lastSpoken = SteadySeconds();
}

void Brain::FirstContactRest(const std::set<std::string>& aFlags, const Json& aState)
{
    // The drone arrived behind V: the rest of the written first contact, by what V did at the site. It goes in the
    // history so that the model knows what Apiko already said.
    std::vector<std::string> parts{"arrival", aFlags.count("shard_read") ? "shard_read" : "shard_unread"};
    if (aFlags.count("ortega"))
        parts.push_back("ortega");
    parts.push_back("closing");
    auto [lines, lang] = FirstContactLines(parts);
    if (lines.empty())
        return;
    std::string names;
    for (const auto& part : parts)
        names += (names.empty() ? "" : ", ") + part;
    log::Write("first contact: " + names);
    // Subtitled by an unknown speaker up to the closing's first entry, where Apiko gives its name.
    auto beforeName = FirstContactLines(std::vector<std::string>(parts.begin(), parts.end() - 1)).first;
    auto closing = FirstContactLines({"closing"}).first;
    if (!closing.empty())
        beforeName.push_back(closing.front());
    Speak(JoinLines(lines), lang, Instability(aState), text::SplitSentences(JoinLines(beforeName)).size(), true, true);
    lastSpoken = SteadySeconds();
    auto head = FirstContactLines({"head"}).first;
    head.insert(head.end(), lines.begin(), lines.end());
    auto& history = memory.data["history"];
    history.push_back({{"role", "user"},
                       {"content", "[event: first_contact] V plugged your NetWatch link chip into their own head. You "
                                   "spoke in V's head while it loaded, then flew in behind V."}});
    history.push_back({{"role", "assistant"},
                       {"content", Json({{"say", JoinLines(head)}, {"mood", "cold"}})
                                       .dump(-1, ' ', false, Json::error_handler_t::replace)}});
    SaveMemory();
}

void Brain::FirstContactExtra(const std::string& aPart, const std::string& aWhat)
{
    // A written line of the find after the first contact (first_contact.json), in the history too.
    auto [lines, lang] = FirstContactLines({aPart});
    if (lines.empty())
        return;
    auto said = JoinLines(lines);
    log::Write("find: " + aPart);
    Speak(said, lang, Instability(lastState), 0, true, true);
    lastSpoken = SteadySeconds();
    auto& history = memory.data["history"];
    history.push_back({{"role", "user"}, {"content", "[event: " + aPart + "] " + aWhat}});
    history.push_back({{"role", "assistant"},
                       {"content", Json({{"say", said}, {"mood", "bored"}}).dump(-1, ' ', false, Json::error_handler_t::replace)}});
    SaveMemory();
}

void Brain::PhoneCall(bool aPresent, const Json& aState)
{
    // V called the APIKO contact and Apiko picked up: a written line (it comes back if it was away, or it is already
    // right here), in the history too; the game hangs up on the "call_done" cue.
    std::string situation = aPresent ? "phone_present" : "phone_arrive";
    double instability = Instability(aState);
    auto picked = barks.Pick(situation, instability, lastLang, defaultLang);
    if (!picked)
    {
        files.WriteReply("cue", "call_done");
        return;
    }
    const auto& line = picked->first;
    log::Write("< " + line + "  [written line: " + situation + ", " + barks::Tier(instability) + "]");
    auto spoken = Speak(line, picked->second, instability, 0, false, true);
    lastSpoken = SteadySeconds();
    CueAfter(spoken, "call_done");
    auto& history = memory.data["history"];
    history.push_back({{"role", "user"},
                       {"content", std::string("[event: phone_call] V called you on the phone") +
                                       (aPresent ? " while you were right next to V." : " to bring you back; you are coming.")}});
    history.push_back({{"role", "assistant"},
                       {"content", Json({{"say", line}, {"mood", "bored"}}).dump(-1, ' ', false, Json::error_handler_t::replace)}});
    SaveMemory();
}

void Brain::AntennaLine(const std::string& aSituation, const Json& aState)
{
    // The mounting's line ends with the "antenna_done" cue (the game ends the mounting then), even without a line.
    bool mounted = aSituation == "antenna_mounted";
    double instability = Instability(aState);
    auto picked = barks.Pick(aSituation, instability, lastLang, defaultLang);
    if (!picked)
    {
        if (mounted)
            files.WriteReply("cue", "antenna_done");
        return;
    }
    const auto& line = picked->first;
    log::Write("< " + line + "  [written line: " + aSituation + ", " + barks::Tier(instability) + "]");
    auto spoken = Speak(line, picked->second, instability, 0, true, true);
    lastSpoken = SteadySeconds();
    diary.NoteSaid(line);
    if (mounted)
        CueAfter(spoken, "antenna_done");
    // The start and the mounting go in the history, so the model knows what V and Apiko are after (or got).
    std::string event;
    if (aSituation == "antenna_start")
        event = "[event: antenna_echo] You picked up the echo of your own long-range antenna: NetWatch cut it out of your "
                "board in Pacifica and kept it as evidence, and it still broadcasts its inventory number. You told V you "
                "are going for it. You do not know yet where in Pacifica it is: never claim it is here. Bring it up only "
                "when V asks or it bears on what V asked, not in unrelated replies.";
    else if (mounted)
        event = "[event: antenna_mounted] V took your antenna back from NetWatch's agents in Pacifica (they were using it "
                "as bait to track you) and you mounted it: your long range is back, you hear the Net again.";
    if (event.empty())
        return;
    auto& history = memory.data["history"];
    history.push_back({{"role", "user"}, {"content", event}});
    history.push_back({{"role", "assistant"},
                       {"content", Json({{"say", line}, {"mood", mounted ? "happy" : "angry"}})
                                       .dump(-1, ' ', false, Json::error_handler_t::replace)}});
    SaveMemory();
}

void Brain::React(const Json& aMessage)
{
    // A device or enemy event: sometimes Apiko says a written line (barks.json, no tokens); rarely the model comments
    // it instead. Shares the pause with Apiko's other remarks. Warnings (an enemy netrunner hacking V, a sniper...)
    // are urgent: their own short pause and high chance, quickly stale, never the model.
    auto situation = barks::SituationFor(Str(aMessage, "event"));
    auto age = Age(aMessage);
    if (situation.empty() || hearing.InScene())
        return;
    auto now = SteadySeconds();
    double chatter = Config("chatter", 1.0);
    if (barks::IsWarning(situation))
    {
        if (age > WarningStaleSeconds || now - lastWarning < Config("warning_cooldown_seconds", 8))
            return;
        if (Roll() > Config("warning_chance", 0.9) * std::min(1.0, chatter))
            return;
        lastWarning = now;
    }
    else
    {
        if (age > StaleEventSeconds || now - lastSpoken < Config("bark_cooldown_seconds", 30))
            return;
        if (Roll() > Config("bark_chance", 0.4) * chatter)
            return;
        if (Roll() < ImproviseChance() && !barks::IsWrittenOnly(situation))
        {
            auto event = barks::IsEnemySituation(situation)    ? "enemy_" + situation
                         : barks::IsDeviceSituation(situation) ? "device_" + situation
                                                               : situation;
            log::Write("world event to the model (improvised): " + event);
            Event({{"type", "event"}, {"event", event}, {"t", UnixSeconds()}, {"rolled", true}, {"state", lastState}});
            return;
        }
    }
    SayWritten(situation, lastState);
}

double Brain::ImproviseChance()
{
    // How often the model improvises instead of a written line: the player's setting (APIKO Settings), else
    // config.json.
    Json value;
    {
        std::lock_guard lock(settingsMutex);
        value = settings.Value("llm", "improvise");
    }
    double chance = value.is_number() ? value.get<double>() : Config("bark_llm_chance", 0.1);
    return std::clamp(chance, 0.0, 1.0);
}

bool Brain::SayWritten(const std::string& aSituation, const Json& aState)
{
    double instability = Instability(aState);
    auto picked = barks.Pick(aSituation, instability, lastLang, defaultLang);
    if (!picked)
        return false;
    log::Write("< " + picked->first + "  [written line: " + aSituation + ", " + barks::Tier(instability) + "]");
    Speak(picked->first, picked->second, instability, 0, false, true);
    lastSpoken = SteadySeconds();
    diary.NoteSaid(picked->first);
    return true;
}

bool Brain::EventLine(const std::string& aEvent, const Json& aState, double aChanceFactor)
{
    // A chat event from the game (combat, health, time of day, district, a calm moment) as a written line. True when
    // it was handled here (a line, or silence); false when the model should improvise it.
    auto now = SteadySeconds();
    double chatter = Config("chatter", 1.0);
    std::string situation;
    if (aEvent == "idle_check")
    {
        // A long silence on both sides, nothing going on: maybe a loose thought (night and rain have their own).
        // Also while V drives: Apiko talks through the chip.
        double quiet = now - std::max(lastSpoken, lastVTalk);
        if (quiet < Config("idle_seconds", 300) || !Str(aState, "tension").empty() || Str(aState, "in_combat") == "yes")
            return true;
        if (Roll() > Config("idle_chance", 0.6) * chatter)
        {
            log::Write("idle: a long silence, but Apiko keeps quiet (chance)");
            return true;
        }
        std::vector<std::string> options{"idle"};
        auto time = Str(aState, "time");
        int hour = 12;
        try
        {
            auto head = time.substr(0, time.find(':'));
            if (!head.empty())
                hour = std::stoi(head);
        }
        catch (const std::exception&)
        {
        }
        if (hour >= 21 || hour < 5)
            options.push_back("idle_night");
        auto weather = Str(aState, "weather");
        if (weather.find("rain") != std::string::npos && weather.find("no rain") == std::string::npos)
            options.push_back("idle_rain");
        std::vector<std::string> usable;
        for (const auto& option : options)
            if (barks.Has(option))
                usable.push_back(option);
        if (usable.empty())
            usable.push_back("idle");
        situation = usable[std::uniform_int_distribution<std::size_t>(0, usable.size() - 1)(random)];
    }
    else if (aEvent == "entered_district")
    {
        situation = barks.DistrictSituation(Str(aState, "district_keys"));
        // Sub-districts of a place with the same lines: nothing new to say.
        auto previous = lastDistrictLine;
        lastDistrictLine = situation;
        if (situation.empty() || situation == previous)
        {
            log::Write(std::string("entered_district: quiet (") +
                       (situation.empty() ? "no lines" : "same place, other sub-district") + ")");
            return true;
        }
    }
    else
        situation = aEvent;
    if (barks::IsUrgentChat(aEvent))
    {
        if (now - lastWarning < Config("warning_cooldown_seconds", 8))
            return true;
        if (Roll() > barks::ChatChance(aEvent).value_or(1.0) * std::min(1.0, chatter))
            return true;
        lastWarning = now;
        SayWritten(situation, aState);
        return true;
    }
    if (aEvent != "idle_check")
    {
        if (now - lastSpoken < Config("bark_cooldown_seconds", 30))
        {
            log::Write(aEvent + ": quiet (Apiko spoke " + std::to_string(std::lround(now - lastSpoken)) + " s ago)");
            return true;
        }
        if (Roll() > barks::ChatChance(aEvent).value_or(1.0) * chatter * aChanceFactor)
        {
            log::Write(aEvent + ": quiet (chance)");
            return true;
        }
    }
    if (Roll() < ImproviseChance())
        return false;
    SayWritten(situation, aState);
    return true;
}

void Brain::SetGameLanguage(const std::string& aCode)
{
    // The game's text language (e.g. "en-us") is Apiko's default language; config default_language only covers the
    // time before the game reports it.
    auto lang = text::Lower(text::Trim(aCode)).substr(0, 2);
    if (lang.size() != 2 || !std::isalpha(static_cast<unsigned char>(lang[0])) ||
        !std::isalpha(static_cast<unsigned char>(lang[1])) || lang == defaultLang)
        return;
    if (lastLang == defaultLang)
        lastLang = lang;
    defaultLang = lang;
    log::Write("game language: " + aCode + " (Apiko's default language is now " + lang + ")");
}

std::pair<std::string, std::string> Brain::SystemPrompt()
{
    // prompt.md keeps what never changes above the @@DYNAMIC@@ line, so providers can cache it as a prefix.
    constexpr std::string_view marker = "@@DYNAMIC@@";
    auto split = promptTemplate.find(marker);
    std::string fixed = promptTemplate.substr(0, split);
    std::string changing = split == std::string::npos ? std::string() : promptTemplate.substr(split + marker.size());
    std::string defaultLanguage = config.value("default_language", std::string("English"));
    for (const auto& [name, code] : providers::LanguageNames())
        if (code == defaultLang)
            defaultLanguage = std::string(1, static_cast<char>(name[0] - 'a' + 'A')) + name.substr(1);
    return {text::Trim(text::Format(fixed, {{"default_language", defaultLanguage}})),
            text::Trim(text::Format(changing, {{"swearing_rule", memory.SwearingRule()},
                                               {"affinity", std::to_string(memory.data.value("affinity", 0))},
                                               {"affinity_stance", memory.AffinityStance()},
                                               {"worn_out", WornOut()},
                                               {"antenna_rule", Str(lastState, "antenna") == "yes" ? AntennaOnRule : AntennaOffRule},
                                               {"memory", memory.PromptBlock()}}))};
}

std::string Brain::WornOut()
{
    // Apiko brought up its 3.5% cap and NetWatch's past whenever it did not know something (tried in the game,
    // 2026-11-10). What its last replies already said is named, to be left out now.
    static const std::vector<std::pair<std::regex, std::string>> topics = {
        {std::regex(R"(3[.,]5|three point five|tres coma cinco)", std::regex::icase), "your 3.5% cap"},
        {std::regex(R"(netwatch|bryce|vance|nw-alpha|purg|quarantine|cuarentena)", std::regex::icase),
         "how NetWatch caught and locked you"},
    };
    const auto& history = memory.data["history"];
    if (!history.is_array())
        return {};
    std::vector<std::string> said;
    for (auto it = history.rbegin(); it != history.rend() && said.size() < WornOutReplies; ++it)
        if (it->is_object() && Str(*it, "role") == "assistant")
            said.push_back(Str(*it, "content"));
    std::string worn;
    for (const auto& [pattern, topic] : topics)
        for (const auto& line : said)
            if (std::regex_search(line, pattern))
            {
                worn += (worn.empty() ? "" : "; ") + topic;
                break;
            }
    return worn.empty() ? std::string()
                        : "- Worn out (in your last replies, V has heard it): " + worn +
                              ". Leave it out now, unless V asks about it.";
}

double Brain::Instability(const Json& aState)
{
    std::uniform_real_distribution<double> jitter(-0.1, 0.15);
    double value = config.value("base_instability", 0.2) + jitter(random);
    if (Str(aState, "in_combat") == "yes")
        value += 0.3;
    return std::round(std::clamp(value, 0.0, 1.0) * 100) / 100;
}

std::string Brain::Chat(const Json& aMessages, bool aJsonMode, int aMaxTokens, bool aFallback, bool aThink)
{
    std::vector<providers::Choice> chain;
    {
        std::lock_guard lock(settingsMutex);
        chain = aFallback ? settings.LlmChain() : std::vector<providers::Choice>{settings.Pick("llm")};
    }
    double timeout = config.value("request_timeout_seconds", 30.0);
    std::vector<std::pair<providers::Choice, std::string>> failures;
    std::set<std::string> dead; // providers whose account failed this turn: skip their other models
    for (const auto& choice : chain)
    {
        if (dead.count(choice.id))
            continue;
        try
        {
            auto result = providers::Chat(choice, aMessages, aJsonMode, aMaxTokens, timeout, aThink);
            lastUsage = result.usage;
            NoteFallback(chain[0], choice, failures);
            return result.text;
        }
        catch (const providers::Error& e)
        {
            failures.emplace_back(choice, providers::Reason(e));
            if (e.status == 401 || e.status == 402 || e.status == 403)
                dead.insert(choice.id);
        }
    }
    std::string reasons;
    for (const auto& [choice, reason] : failures)
        reasons += (reasons.empty() ? "" : "; ") + choice.label + " (" + choice.model + "): " + reason;
    throw providers::Error(reasons.empty() ? "no reply model available" : text::Truncate(reasons, 300));
}

void Brain::NoteFallback(const providers::Choice& aFirst, const providers::Choice& aUsed,
                         const std::vector<std::pair<providers::Choice, std::string>>& aFailures)
{
    if (aUsed.id == aFirst.id && aUsed.model == aFirst.model)
    {
        if (!fallbackActive.empty())
        {
            log::Write("back to " + aFirst.label + " (" + aFirst.model + ")");
            fallbackActive.clear();
        }
        return;
    }
    auto name = aUsed.label + " (" + aUsed.model + ")";
    if (name == fallbackActive)
        return;
    fallbackActive = name;
    auto cause = aFailures.empty() ? std::string("unavailable") : aFailures.front().second;
    auto message = aFirst.label + " (" + aFirst.model + ") failed: " + cause + ". Using " + name + ".";
    log::Write(message);
    files.WriteReply("status", message);
}

double Brain::SpeakSentences(const std::string& aText, std::size_t aUnknown)
{
    // Without voice: one subtitle per sentence, each shown for its reading time (as the voice will pace them).
    if (!files.GameLive())
    {
        log::Write("not said (no game session): " + text::Truncate(aText, 80));
        return 0.0;
    }
    auto sentences = text::SplitSentences(aText);
    double at = 0.0;
    for (std::size_t i = 0; i < sentences.size(); ++i)
    {
        double seconds = std::max(2.0, 1.0 + CharCount(sentences[i]) / 14.0);
        // Each new subtitle replaces the previous one; the last stays a bit longer.
        double duration = seconds + (i + 1 == sentences.size() ? 0.9 : 0.4);
        auto kind = i < aUnknown ? "sayu" : "say";
        if (i == 0)
            files.WriteReply(kind, sentences[i], duration);
        else
            ReplyAfter(at, kind, sentences[i], duration);
        at += seconds;
    }
    return at;
}

Brain::Spoken Brain::Speak(const std::string& aText, const std::string& aLang, double aInstability,
                           std::size_t aUnknown, bool aSentences, bool aCache)
{
    if (!files.GameLive())
    {
        log::Write("not said (no game session): " + text::Truncate(aText, 80));
        return {};
    }
    if (voice)
    {
        auto lang = voice->Language(aLang);
        auto problem = voice->Unavailable(lang);
        if (!problem)
            return SpeakAloud(aText, lang, aInstability, aUnknown, aCache);
        NoteVoiceFailure(*problem);
    }
    // Subtitles only: the written scripts sentence by sentence, the model's short replies as one subtitle.
    if (aSentences)
        return {std::nullopt, SpeakSentences(aText, aUnknown)};
    double duration = std::clamp(1.5 + CharCount(aText) / 14.0, 3.0, 14.0);
    if (!replyMood.empty())
        files.WriteReply("face", replyMood, duration);
    files.WriteReply(aUnknown ? "sayu" : "say", aText, duration);
    return {std::nullopt, 1.5 + CharCount(aText) / 14.0};
}

Brain::Spoken Brain::SpeakAloud(const std::string& aText, const std::string& aLang, double aInstability,
                                std::size_t aUnknown, bool aCache, bool aPhone, std::optional<int> aGeneration)
{
    // Voice and subtitles, sentence by sentence: each subtitle shows while its sentence sounds, and the first sounds
    // while the next ones are rendered. A sentence the voice cannot render: the rest goes out as a subtitle.
    auto sentences = text::SplitSentences(aText);
    int generation = aGeneration ? *aGeneration : voice->NewReply();
    // Each subtitle goes with its face, written when the sentence sounds (Brain::replyMood).
    auto subtitle = [this, mood = replyMood](const std::string& aKind, const std::string& aText, double aDuration)
    {
        if (!mood.empty())
            files.WriteReply("face", mood, aDuration);
        files.WriteReply(aKind, aText, aDuration);
    };
    double total = 0.0;
    auto started = std::chrono::steady_clock::now();
    for (std::size_t i = 0; i < sentences.size(); ++i)
    {
        std::string kind = i < aUnknown ? "sayu" : "say";
        std::vector<float> audio;
        try
        {
            audio = voice->Render(sentences[i], aLang, aInstability, aCache, aPhone);
            voiceFailure.clear();
        }
        catch (const std::exception& e)
        {
            NoteVoiceFailure(e.what());
            std::string rest;
            for (std::size_t j = i; j < sentences.size(); ++j)
                rest += (rest.empty() ? "" : " ") + sentences[j];
            double seconds = 1.5 + CharCount(rest) / 14.0;
            voice->Queue(generation, std::vector<float>(1, 0.0f),
                         [subtitle, kind, rest, seconds] { subtitle(kind, rest, seconds); });
            total += seconds;
            break;
        }
        if (i == 0)
            log::Write("voice: first sentence rendered in " +
                       Fixed1(std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count()) + "s");
        double seconds = static_cast<double>(audio.size()) / voice::Rate;
        // Each new subtitle replaces the previous one; the last stays a bit longer.
        double duration = seconds + (i + 1 == sentences.size() ? 0.9 : 0.4);
        voice->Queue(generation, std::move(audio),
                     [subtitle, kind, sentence = sentences[i], duration] { subtitle(kind, sentence, duration); });
        total += seconds;
    }
    return {generation, total};
}

void Brain::NoteVoiceFailure(const std::string& aWhy)
{
    // Once per cause: every sentence would repeat it.
    if (aWhy == voiceFailure)
        return;
    voiceFailure = aWhy;
    log::Write("voice unavailable, subtitles only: " + aWhy);
}

std::optional<Brain::Json> Brain::Perceive(const Json& aMessage)
{
    // A bridge started late reads the whole file: old world events and heard lines belong to an earlier moment
    // (replayed objectives made the quest brief look new and filled every turn).
    if (Age(aMessage) > StaleWorldSeconds)
        return std::nullopt;
    auto event = Str(aMessage, "event");
    if (Str(aMessage, "type") == "world")
    {
        // Local: the diary, and maybe a written line (on the worker, so speaking never blocks reading).
        if (event.rfind("objective|", 0) == 0)
        {
            hearing.OnObjective();
            objectiveChanged = SteadySeconds();
        }
        if (!diary.Add(event).empty() && !barks::SituationFor(event).empty())
        {
            auto react = aMessage;
            react["type"] = "world_react";
            return react;
        }
        return std::nullopt;
    }
    // "story": what Apiko hears. A conversation that ended may get one remark (an event, with its chance).
    auto lines = hearing.Handle(event);
    if (lines && *lines >= world::SceneCommentMinLines)
    {
        auto ended = aMessage;
        ended["type"] = "event";
        ended["event"] = "scene_end";
        return ended;
    }
    return std::nullopt;
}

void Brain::Say(const Json& aMessage)
{
    if (Age(aMessage) > StaleSaySeconds)
        return;
    auto said = text::Trim(Str(aMessage, "text"));
    if (said.empty())
        return;
    const auto& state = aMessage.contains("state") && aMessage["state"].is_object() ? aMessage["state"] : Json::object();
    auto& data = memory.data;
    data["swear_exposure"] = data.value("swear_exposure", 0) +
                             static_cast<int>(std::distance(std::sregex_iterator(said.begin(), said.end(), SwearWords()),
                                                            std::sregex_iterator()));
    lastVTalk = SteadySeconds();
    ReactFace(said);
    Turn("[V says] " + said, said, state);
}

void Brain::ReactFace(const std::string& aSaid)
{
    if (Config("reaction_faces", 1.0) <= 0.0 || !files.GameLive())
        return;
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("llm");
    }
    if (providers::Missing(choice))
        return;
    int turn = ++turnCount;
    Json messages = Json::array({{{"role", "system"}, {"content", ReactionPrompt}}, {{"role", "user"}, {"content", aSaid}}});
    reaction = std::async(std::launch::async, [this, choice, messages, turn]
    {
        auto started = std::chrono::steady_clock::now();
        try
        {
            auto result = providers::Chat(choice, messages, false, ReactionTokens, ReactionTimeout, false);
            std::string face;
            for (char c : text::Lower(result.text))
                if (c >= 'a' && c <= 'z')
                    face += c;
                else if (!face.empty())
                    break;
            auto seconds = Fixed1(std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
            if (!ReactionFaces.count(face))
            {
                log::Write("reaction face: none (" + text::Truncate(result.text, 40) + ") in " + seconds + "s");
                return;
            }
            if (repliedTurn.load() >= turn)
            {
                log::Write("reaction face: " + face + " too late (" + seconds + "s)");
                return;
            }
            files.WriteReply("react", face, ReactionSeconds);
            log::Write("reaction face: " + face + " in " + seconds + "s");
        }
        catch (const providers::Error& e)
        {
            log::Write(std::string("reaction face failed: ") + e.what());
        }
    });
}

std::string Brain::Perceived(const std::string& aTurn, const std::string& aSaid, const Json& aState)
{
    // Only V's own words: "[V says]" made "says" match the conversation words on every turn.
    bool isEvent = aSaid.empty();
    auto words = text::Plain(aSaid);
    std::vector<std::string> lines{DescribeState(aState, lastState, isEvent || Matches(AsksAmbient(), aSaid))};
    bool sceneEnd = aTurn.rfind("[event: scene_end]", 0) == 0;
    bool asksPlan = world::Asks(world::AsksPlan(), words);
    // What is current and what is settled, ranked here (Apiko repeated a conversation from an earlier objective and
    // compared enemies with an earlier turn). The quest details only when they help: V asks what to do, a
    // conversation just ended, or the first turn after the objective changed.
    auto now = SteadySeconds();
    bool questDetails = asksPlan || sceneEnd || objectiveChanged.load() > lastTurnAt;
    lastTurnAt = now;
    lines.push_back(world::DescribeFocus(aState, hearing.SceneNote(), !Str(aState, "enemies").empty(), questDetails));
    // Devices: a summary when security is around; the whole list when V talks about the surroundings.
    lines.push_back(world::DescribeDevices(Str(aState, "devices"), world::Asks(world::AsksDevices(), words)));
    // Enemies: only with tension (restricted area, weapon drawn, noticed...) or when V asks about people or threats
    // (then the full cards). Gangs standing around are no news.
    bool asksEnemies = world::Asks(world::AsksEnemies(), words);
    if (asksEnemies || !Str(aState, "tension").empty())
        lines.push_back(world::DescribeEnemies(Str(aState, "enemies"), asksEnemies));
    lines.push_back(world::DescribePeople(aState, world::Asks(world::AsksPeople(), words),
                                          world::Asks(world::AsksShop(), words)));
    lines.push_back(world::DescribeSurroundings(aState, words));
    // Public lore V's words touch (and the turn before, for follow-ups): never the game's plot.
    if (!words.empty())
    {
        lines.push_back(lore.Describe(words + " " + previousWords, aState));
        previousWords = words;
    }
    lines.push_back(diary.Describe());
    // What Apiko overheard: only when V asks about it or it just ended (all of it), or its end when V asks what to
    // do and it led to the current objective.
    lines.push_back(hearing.Describe(sceneEnd || world::Asks(world::AsksConversation(), words), asksPlan));
    lines.push_back(DescribeSilence(aState, memory.data["last_game_seconds"]));
    std::string perceived;
    for (const auto& line : lines)
        if (!line.empty())
            perceived += (perceived.empty() ? "" : "\n") + line;
    return perceived;
}

void Brain::Turn(const std::string& aTurn, const std::string& aSaid, const Json& aState)
{
    // aSaid: V's words; empty for an event turn.
    const auto& state = aState;
    bool isEvent = aSaid.empty();
    auto received = std::chrono::steady_clock::now();
    auto& data = memory.data;
    const auto& turn = aTurn;
    double instability = Instability(state);
    memory.ExpirePlans(log::Write);
    auto perceived = Perceived(aTurn, aSaid, state);
    {
        std::string indented;
        for (char c : perceived)
            indented += c == '\n' ? std::string("\n  ") : std::string(1, c);
        log::Write("  " + indented);
    }
    char instabilityText[16];
    std::snprintf(instabilityText, sizeof(instabilityText), "%.2f", instability);
    auto userContent = perceived + "\n[instability] " + instabilityText + "\n" + turn;
    if (!state.empty())
    {
        lastState = state;
        auto seconds = Str(state, "game_seconds");
        if (!seconds.empty())
            data["last_game_seconds"] = std::stoll(seconds);
    }

    // "cache" marks the end of a prefix that repeats on the next turn: the fixed prompt, and the history.
    auto [fixed, changing] = SystemPrompt();
    Json messages = Json::array({{{"role", "system"}, {"content", fixed}, {"cache", true}},
                                 {{"role", "system"}, {"content", changing}}});
    Json history = data["history"].is_array() ? data["history"] : Json::array();
    if (!history.empty())
        history.back()["cache"] = true;
    for (const auto& entry : history)
        messages.push_back(entry);
    messages.push_back({{"role", "user"}, {"content", userContent}});

    log::Write("> " + turn);
    std::string raw;
    auto started = std::chrono::steady_clock::now();
    try
    {
        // Room for the model's reasoning too: with 400, the JSON came out cut.
        raw = Chat(messages, true, 1000);
    }
    catch (const providers::Error& e)
    {
        repliedTurn = turnCount.load();
        log::Write(std::string("model error: ") + e.what());
        files.WriteReply("status", text::Truncate(std::string("model error: ") + e.what(), 300));
        return;
    }
    // The reply is here: a reaction face still on its way is too late.
    repliedTurn = turnCount.load();
    double modelSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();

    auto reply = ParseReply(raw);
    auto say = text::CleanSay(Str(reply, "say"));
    auto mood = text::Lower(Str(reply, "mood"));
    if (Moods.count(mood))
        data["last_mood"] = mood;
    int delta = std::clamp(ToInt(reply.value("affinity_delta", Json(0))), -3, 3);
    data["affinity"] = std::clamp(data.value("affinity", 0) + delta, -100, 100);
    auto fact = text::CleanSay(Str(reply, "remember"));
    if (!fact.empty() && Matches(NotAFact(), fact))
    {
        log::Write("remember ignored: " + fact);
        fact.clear();
    }
    auto& facts = data["facts"];
    if (!fact.empty() && std::find(facts.begin(), facts.end(), fact) == facts.end())
    {
        facts.push_back(fact);
        while (facts.size() > MaxFacts)
            facts.erase(facts.begin());
    }
    auto done = memory.DropPlan(ToInt(reply.value("plan_done", Json(0))));
    auto plan = text::CleanSay(Str(reply, "plan"));
    memory.AddPlan(plan);
    if (!done.empty())
        log::Write("plan done: " + done);
    if (!plan.empty())
        log::Write("plan: " + plan);

    // V sent Apiko away (only V's own words count, never an event): the game removes the drone once the parting line
    // has sounded (the "leave" cue).
    bool leave = !isEvent && reply.value("leave", Json(false)) == true;
    // V took Apiko along from the apartment (the game ignores it unless Apiko is staying there).
    bool follow = !isEvent && reply.value("follow", Json(false)) == true && !leave;
    log::Write("< " + (say.empty() ? std::string("(silence)") : say) + "  [mood " + mood + ", affinity " +
               std::to_string(data.value("affinity", 0)) + " (" + (delta >= 0 ? "+" : "") + std::to_string(delta) +
               ")" + (fact.empty() ? "" : ", remembers: " + fact) + (leave ? ", LEAVES" : "") +
               (follow ? ", FOLLOWS" : "") + "]");
    if (CharCount(say) > 220)
        log::Write("warning: reply of " + std::to_string(CharCount(say)) + " chars ignores the 200-char limit in prompt.md");
    if (follow)
        files.WriteReply("cue", "follow");
    // A ping (only with the antenna back): the game does it now, while Apiko speaks, and says how it went.
    if (reply.value("ping", Json(false)) == true && Str(lastState, "antenna") == "yes")
    {
        log::Write("ping asked by the model");
        files.WriteReply("cue", "ping");
    }
    Spoken spoken;
    if (!say.empty())
    {
        auto lang = text::Lower(Str(reply, "lang")).substr(0, 2);
        if (!lang.empty())
            lastLang = lang;
        replyMood = mood.empty() ? "neutral" : mood;
        spoken = Speak(say, lang.empty() ? lastLang : lang, instability);
        replyMood.clear();
        lastSpoken = SteadySeconds();
    }
    if (leave)
        CueAfter(spoken, "leave");

    auto usage = lastUsage;
    auto cached = usage.contains("prompt_tokens_details") && usage["prompt_tokens_details"].is_object()
                      ? Str(usage["prompt_tokens_details"], "cached_tokens")
                      : std::string();
    auto total = std::chrono::duration<double>(std::chrono::steady_clock::now() - received).count();
    log::Write("timing: model " + Fixed1(modelSeconds) + "s | total " + Fixed1(total) + "s | tokens in " +
               Str(usage, "prompt_tokens") + (cached.empty() ? "" : " (cached " + cached + ")") + " out " +
               Str(usage, "completion_tokens") + (usage.contains("cost") ? " | cost $" + Str(usage, "cost") : ""));

    // Events Apiko stays silent about are not kept in the history.
    if (isEvent && say.empty())
    {
        SaveMemory();
        return;
    }
    auto& kept = data["history"];
    if (!kept.is_array())
        kept = Json::array();
    kept.push_back({{"role", "user"}, {"content", turn}});
    Json saidJson = {{"say", say}, {"mood", mood}};
    if (leave)
        saidJson["leave"] = true;
    if (follow)
        saidJson["follow"] = true;
    kept.push_back({{"role", "assistant"}, {"content", saidJson.dump(-1, ' ', false, Json::error_handler_t::replace)}});
    CompactHistory();
    SaveMemory();
}

// --- memory per save ---

void Brain::NoteGameMessage()
{
    auto now = std::chrono::steady_clock::now();
    std::lock_guard lock(playtimeMutex);
    if (lastGameMessage)
    {
        double gap = std::chrono::duration<double>(now - *lastGameMessage).count();
        if (gap < PlaytimeGap)
            pendingPlaytime += gap;
    }
    lastGameMessage = now;
}

void Brain::FlushPlaytime()
{
    double seconds;
    {
        std::lock_guard lock(playtimeMutex);
        seconds = pendingPlaytime;
        pendingPlaytime = 0.0;
    }
    if (seconds > 0)
        memory.data["playtime"] = memory.data.value("playtime", 0.0) + seconds;
}

void Brain::SaveMemory()
{
    memory.Save(dataDir / L"memory.json");
    memoryVersion = store.Commit(memory.data);
    PublishMemory();
}

void Brain::PublishMemory()
{
    // "token<TAB>version<TAB>bytes" line, then the memory JSON. The CET side stores it in the game (and so in the
    // next save) when the token matches its current load.
    auto text = memory.data.dump(-1, ' ', false, Json::error_handler_t::replace);
    auto content = memoryToken + "\t" + std::to_string(memoryVersion) + "\t" + std::to_string(text.size()) + "\n" + text + "\n";
    if (!WriteFileAtomic(modDir / L"memory_out.txt", content))
        log::Write("could not replace memory_out.txt (file locked)");
}

void Brain::LoadMemory(const Json& aMessage)
{
    // A save was loaded (or the bridge came online during a game): bring back the memory of that save. Order: our
    // snapshot of the save's version, else the copy stored in the save. A save without a version: if Apiko was never
    // woken there, a fresh Apiko waits for its first wake; otherwise (a save from before this system) the current
    // memory.
    auto token = Str(aMessage, "token");
    int version = ToInt(aMessage.value("version", Json(0)));
    if (token == memoryToken && version == memoryVersion)
    {
        PublishMemory(); // repeated announcement (bridge restart): nothing changed
        return;
    }
    memoryToken = token;
    std::optional<Json> data;
    std::string source;
    if (version > 0)
    {
        data = store.Load(version);
        source = "snapshot";
        auto copy = Str(aMessage, "memory");
        if (!data && !copy.empty())
        {
            auto parsed = Json::parse(copy, nullptr, false);
            if (parsed.is_object())
            {
                data = parsed;
                source = "copy stored in the save";
                store.SaveAs(version, parsed);
            }
        }
        if (!data)
            log::Write("memory: version " + std::to_string(version) +
                       " of this save not found (no snapshot, no copy); keeping the current one");
    }
    else if (aMessage.value("unlocked", Json(false)) != true)
    {
        // Apiko not woken here: never reset on a load. The first wake ("first_wake" event) starts a fresh Apiko.
        log::Write("memory: save without a memory version and Apiko asleep; waiting for its first wake");
        diary.Clear();
        hearing.Clear();
        return;
    }
    else
        log::Write("memory: save from before memory versions; it adopts the current memory");
    diary.Clear();
    hearing.Clear();
    lastState = Json::object();

    if (data)
    {
        // This version was loaded and folded before (the same save reloaded): its fold, without the model.
        auto folded = FoldedVersions();
        auto key = std::to_string(version);
        std::optional<Json> foldedData;
        int foldedVersion = 0;
        if (folded.contains(key) && folded[key].is_number_integer())
        {
            foldedVersion = folded[key].get<int>();
            foldedData = store.Load(foldedVersion);
        }
        if (foldedData)
        {
            source = "fold of version " + key + " reused, no model call";
            version = foldedVersion;
            data = foldedData;
        }
        memory.Replace(*data);
        memory.Save(dataDir / L"memory.json");
        memoryVersion = version;
        PublishMemory();
        log::Write("memory: save loaded, version " + std::to_string(version) + " (" + source + "); affinity " +
                   std::to_string(memory.data.value("affinity", 0)) + ", " +
                   std::to_string(memory.data["facts"].size()) + " facts");
        if (foldedData)
        {
            ForgetTheMoment(false, false);
            return;
        }
        int loaded = version;
        if (ForgetTheMoment())
            RememberFold(loaded, memoryVersion);
        return;
    }
    ForgetTheMoment(false);
    SaveMemory();
}

bool Brain::ForgetTheMoment(bool aSave, bool aFold)
{
    // After a save load, what belonged to the moment goes: the recent conversation is folded into the long-term
    // summary (what was talked about stays; positions, closed doors... go). Facts, plans and affinity stay. A short
    // conversation stays as history: not worth a model call.
    objectiveChanged = 0.0;
    lastTurnAt = 0.0;
    currentDistrict.clear();
    visitedDistricts.clear();
    const auto& history = memory.data["history"];
    if (!aFold || !history.is_array() || history.size() < MinFoldMessages)
        return false;
    if (!CompactHistory(true))
        return false;
    log::Write("memory: recent conversation folded into the summary after the load");
    if (aSave)
        SaveMemory();
    return true;
}

Brain::Json Brain::FoldedVersions() const
{
    if (auto content = text::ReadFile(dataDir / L"folded_versions.json"))
    {
        auto parsed = Json::parse(*content, nullptr, false);
        if (parsed.is_object())
            return parsed;
    }
    return Json::object();
}

void Brain::RememberFold(int aLoaded, int aFolded)
{
    // In file order (oldest first), as the Python bridge keeps it: only the newest FoldedKeep entries stay.
    nlohmann::ordered_json mapping = nlohmann::ordered_json::object();
    if (auto content = text::ReadFile(dataDir / L"folded_versions.json"))
    {
        auto parsed = nlohmann::ordered_json::parse(*content, nullptr, false);
        if (parsed.is_object())
            mapping = parsed;
    }
    auto key = std::to_string(aLoaded);
    mapping.erase(key);
    mapping[key] = aFolded;
    while (mapping.size() > FoldedKeep)
        mapping.erase(mapping.begin());
    if (!WriteFileAtomic(dataDir / L"folded_versions.json", mapping.dump()))
        log::Write("could not write folded_versions.json");
}

bool Brain::CompactHistory(bool aFoldAll)
{
    auto& data = memory.data;
    auto& history = data["history"];
    auto limit = static_cast<std::size_t>(config.value("history_messages", 24));
    std::size_t cut;
    if (aFoldAll)
    {
        if (history.empty())
            return false;
        cut = history.size();
    }
    else
    {
        if (history.size() <= limit)
            return false;
        cut = history.size() - limit / 2;
    }
    cut -= cut % 2; // keep user/assistant pairs together
    std::string transcript;
    for (std::size_t i = 0; i < cut; ++i)
        transcript += (i ? "\n" : "") + std::string(history[i].value("role", "") == "assistant" ? "Apiko" : "V/event") +
                      ": " + history[i].value("content", std::string());
    std::string facts, plans;
    for (const auto& fact : data["facts"])
        if (fact.is_string())
            facts += (facts.empty() ? "- " : "\n- ") + fact.get<std::string>();
    for (const auto& plan : data["plans"])
        plans += (plans.empty() ? "- " : "\n- ") + plan.value("text", std::string());
    auto summary = data.value("summary", std::string());

    // Consolidation: the same call that folds the history into the summary also cleans the facts and plans.
    Json request = Json::array(
        {{{"role", "system"},
          {"content",
           "You maintain the long-term memory of Apiko, an AI companion drone, about V. Return ONLY a JSON object: "
           "{\"summary\": \"...\", \"facts\": [\"...\"], \"plans\": [\"...\"]}. summary: English, third person about "
           "V, at most 180 words; what matters for the relationship: what V told Apiko, what they did together, "
           "promises, insults, jokes, Apiko's memory fragments; never momentary readings (who stood where, enemy "
           "counts, closed doors, health, time). facts: lasting facts about V, people in V's life and what V and Apiko "
           "lived together; merge duplicates, drop trivial, obsolete or invented-sounding ones, at most " +
               std::to_string(MaxFacts) +
               ", English; keep each fact's wording and never split one fact into several; never V's questions, "
               "places visited, plans or sensor readings. plans: V's current goals and jobs still pending, at most " +
               std::to_string(MaxPlansKept) + "; drop finished or abandoned ones (a finished one may become a fact)."}},
         {{"role", "user"},
          {"content", "Previous summary:\n" + (summary.empty() ? std::string("(empty)") : summary) + "\n\nFacts:\n" +
                          (facts.empty() ? std::string("(none)") : facts) + "\n\nPlans:\n" +
                          (plans.empty() ? std::string("(none)") : plans) + "\n\nNew conversation to fold in:\n" +
                          transcript}}});
    Json reply;
    try
    {
        // Generous cap: a model that reasons first spends part of it thinking, and a cut reply has no summary.
        reply = ParseReply(Chat(request, true, 3000, true, false));
    }
    catch (const providers::Error& e)
    {
        log::Write(std::string("summary failed, keeping full history for now: ") + e.what());
        return false;
    }
    auto newSummary = text::Trim(Str(reply, "summary"));
    if (newSummary.empty())
    {
        log::Write("summary failed (no summary in the reply), keeping full history for now");
        return false;
    }
    data["summary"] = newSummary;
    history.erase(history.begin(), history.begin() + cut);
    if (reply.contains("facts") && reply["facts"].is_array())
    {
        Json cleaned = Json::array();
        for (const auto& fact : reply["facts"])
        {
            auto text = text::CleanSay(fact.is_string() ? fact.get<std::string>() : std::string());
            if (!text.empty() && cleaned.size() < MaxFacts)
                cleaned.push_back(text);
        }
        data["facts"] = cleaned;
    }
    if (reply.contains("plans") && reply["plans"].is_array())
    {
        double playtime = data.value("playtime", 0.0);
        Json cleaned = Json::array();
        for (const auto& plan : reply["plans"])
        {
            auto text = text::CleanSay(plan.is_string() ? plan.get<std::string>() : std::string());
            if (text.empty() || cleaned.size() >= MaxPlansKept)
                continue;
            double since = playtime;
            for (const auto& old : data["plans"])
                if (old.value("text", std::string()) == text)
                    since = old.value("since", playtime);
            cleaned.push_back({{"text", text}, {"since", since}});
        }
        data["plans"] = cleaned;
    }
    auto usage = lastUsage;
    log::Write("memory consolidated: summary, " + std::to_string(data["facts"].size()) + " facts, " +
               std::to_string(data["plans"].size()) + " plans; " + std::to_string(cut) + " messages folded, tokens in " +
               Str(usage, "prompt_tokens") + " out " + Str(usage, "completion_tokens") +
               (usage.contains("cost") ? ", $" + Str(usage, "cost") : ""));
    return true;
}

void Brain::Test(const std::string& aWhat)
{
    if (aWhat != "llm" && aWhat != "stt" && aWhat != "tts")
        return;
    CheckSettings(); // the window saves just before sending the test
    auto choice = settings.Pick(aWhat);
    auto name = choice.model.empty() ? choice.label : choice.label + " (" + choice.model + ")";
    auto started = std::chrono::steady_clock::now();
    try
    {
        if (aWhat == "llm")
            Chat(Json::array({{{"role", "user"}, {"content", "Reply with the single word OK."}}}), false, 50, false);
        else if (aWhat == "stt")
        {
            if (!ears)
                throw std::runtime_error("voice is off (voice_enabled false in config.json)");
            ears->Test();
        }
        else
        {
            if (!voice)
                throw std::runtime_error("voice is off (no audio output, or voice_enabled false in config.json)");
            auto lang = voice->Language(defaultLang);
            if (auto problem = voice->Unavailable(lang))
                throw std::runtime_error(*problem);
            std::string line = lang == "es" ? "Hola, soy Apiko. ¿Me oyes bien?" : "Hi, I'm Apiko. Can you hear me?";
            auto audio = voice->Render(line, lang, 0.2);
            double seconds = static_cast<double>(audio.size()) / voice::Rate + 0.6;
            voice->Queue(voice->NewReply(), std::move(audio),
                         [this, line, seconds] { files.WriteReply("say", line, seconds); });
        }
    }
    catch (const std::exception& e)
    {
        log::Write("test " + aWhat + ": " + name + " failed: " + e.what());
        files.WriteReply("test", text::Truncate(aWhat + "|error|" + name + ": " + e.what(), 300));
        return;
    }
    auto seconds = Fixed1(std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
    log::Write("test " + aWhat + ": " + name + " ok (" + seconds + "s)");
    files.WriteReply("test", aWhat + "|ok|" + name + ": OK (" + seconds + " s)");
}
} // namespace apiko
