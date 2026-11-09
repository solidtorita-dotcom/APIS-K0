// Apiko's conversation: port of the Bridge class of bridge\apiko_bridge.py, part by part (plan in DISENO.md).
// Phase 2a: V's typed words go to the reply model the player picked (with the fallback chain), Apiko answers as a
// subtitle; the settings window's Test checks the reply model.
// Phase 2b: memory per save (versions, snapshots, memory_out.txt for the game), consolidation of old history into
// the summary.
// Phase 2c: world perception (World.hpp), events and written lines (Barks.hpp), the find, the phone and home.
// Handle runs on the bridge's worker thread (it blocks on the model); Tick, CheckSettings and NoteGameMessage on the
// poll thread.
#pragma once

#include "Barks.hpp"
#include "Ears.hpp"
#include "GameFiles.hpp"
#include "Memory.hpp"
#include "Providers.hpp"
#include "Voice.hpp"
#include "World.hpp"

#include <nlohmann/json.hpp>

#include <atomic>
#include <chrono>
#include <deque>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <set>
#include <string>
#include <vector>

namespace apiko
{
class Brain
{
public:
    using Json = nlohmann::json;

    Brain(GameFiles& aFiles, const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir);

    // Loads config, catalog, settings, prompt and memory. Throws when something essential is missing.
    void Start();
    // A message for the worker (say, test, memory_load).
    void Handle(const Json& aMessage);
    // Settings changed in the game's settings window: reload (poll thread, about once a second).
    void CheckSettings();
    // Sends cues whose time has come (poll thread).
    void Tick();
    // Any message from the game: play time (plans expire with it) is the time between them, unless the gap means
    // the game was away (poll thread).
    void NoteGameMessage();
    // A "world" or "story" message, handled at once on the poll thread (diary, hearing). Returns a follow-up for the
    // worker when the game's event deserves one: "world_react" (maybe a written line) or a "scene_end" event.
    std::optional<Json> Perceive(const Json& aMessage);
    // Apiko stops talking at once (V pressed push-to-talk, the session ended). Any thread.
    void Hush();
    // Push-to-talk (poll thread): pressed, Apiko hushes and the microphone records; released, the clip goes to the
    // worker as a "voice" message (returned), or nothing when there was nothing recorded.
    void StartListening();
    std::optional<Json> StopListening(const Json& aMessage);

private:
    // A reply written later (cues, the beacon call's second subtitle).
    struct Pending
    {
        std::chrono::steady_clock::time_point due;
        std::string kind;
        std::string text;
        double duration = 0.0;
    };

    void Say(const Json& aMessage);
    // A "voice" message: speech recognition on the recorded clip, then V's words as a turn.
    void Hear(const Json& aMessage);
    // One model turn: V's words (aSaid) or an event (aSaid empty), with what Apiko perceives.
    void Turn(const std::string& aTurn, const std::string& aSaid, const Json& aState);
    // The perception lines of a turn (sensors, focus, devices, enemies, people, lore, diary, hearing...).
    std::string Perceived(const std::string& aTurn, const std::string& aSaid, const Json& aState);
    // A game event ("event" message): a written line, a model turn, or silence (chance, pauses, conversations).
    void Event(const Json& aMessage);
    // A world event the diary took as new ("world_react"): maybe a written line, rarely the model.
    void React(const Json& aMessage);
    // A chat event as a written line; false when the model should improvise it.
    bool EventLine(const std::string& aEvent, const Json& aState, double aChanceFactor);
    // Phase 2c-3: the find (beacon call, first contact, Kessler's shard), the phone, home, dev_say.
    void Scripted(const std::string& aEvent, std::int64_t aAge, const Json& aState, const Json& aMessage);
    // The first contact's sentences for these parts (first_contact.json), in V's language (else English).
    std::pair<std::vector<std::string>, std::string> FirstContactLines(const std::vector<std::string>& aParts) const;
    void BeaconCall();
    void FirstContactHead();
    void FirstContactRest(const std::set<std::string>& aFlags, const Json& aState);
    void FirstContactExtra(const std::string& aPart, const std::string& aWhat);
    void PhoneCall(bool aPresent, const Json& aState);
    // Says a line from barks.json (no tokens). False when there is none for it.
    bool SayWritten(const std::string& aSituation, const Json& aState);
    double ImproviseChance();
    // A number from config.json (defaults from config.example.json are merged in already).
    double Config(const char* aKey, double aDefault) const;
    // A random number in [0, 1).
    double Roll();
    void Test(const std::string& aWhat);
    void SetGameLanguage(const std::string& aCode);
    void WarnMissing();

    std::pair<std::string, std::string> SystemPrompt();
    double Instability(const Json& aState);
    // The reply model's answer, trying the fallback chain; throws providers::Error when none answers.
    std::string Chat(const Json& aMessages, bool aJsonMode, int aMaxTokens, bool aFallback = true, bool aThink = true);
    void NoteFallback(const providers::Choice& aFirst, const providers::Choice& aUsed,
                      const std::vector<std::pair<providers::Choice, std::string>>& aFailures);
    // Subtitles (voice comes in phase 3). Nothing is said outside a game session.
    // What Speak started: the voice reply (to queue a cue after it), or, without voice, its subtitles' seconds.
    struct Spoken
    {
        std::optional<int> generation;
        double seconds = 0.0;
    };
    // Apiko says aText: with voice when it can, else subtitles. aUnknown: how many sentences are subtitled by an
    // unknown speaker ("sayu": the find, before Apiko gives its name). aSentences: without voice, one subtitle per
    // sentence (the written scripts) instead of one for all. Nothing is said outside a game session.
    // aCache: a written line (its voice is rendered once and kept, see voice::Voice::Render).
    Spoken Speak(const std::string& aText, const std::string& aLang, double aInstability, std::size_t aUnknown = 0,
                 bool aSentences = false, bool aCache = false);
    // aPhone: through a phone line. aGeneration: after what that reply already queued, instead of cutting it.
    Spoken SpeakAloud(const std::string& aText, const std::string& aLang, double aInstability, std::size_t aUnknown,
                      bool aCache = false, bool aPhone = false, std::optional<int> aGeneration = std::nullopt);
    void NoteVoiceFailure(const std::string& aWhy);
    // The written scripts, one subtitle per sentence (the first aUnknown by an unknown speaker). Returns the seconds
    // until the last one has been read.
    double SpeakSentences(const std::string& aText, std::size_t aUnknown);
    // Tells the game aCue once what Speak started has been heard or read (at least aMinimum seconds).
    void CueAfter(const Spoken& aSpoken, const std::string& aCue, double aMinimum = 1.5);
    void ReplyAfter(double aSeconds, const std::string& aKind, const std::string& aText, double aDuration = 0.0);

    // Memory per save.
    void FlushPlaytime();
    // memory.json, a new version snapshot, and the copy for the game (it goes into the next save).
    void SaveMemory();
    void PublishMemory();
    void LoadMemory(const Json& aMessage);
    bool ForgetTheMoment(bool aSave = true, bool aFold = true);
    Json FoldedVersions() const;
    void RememberFold(int aLoaded, int aFolded);
    // Folds the older half of a long history (all of it with aFoldAll) into the summary, cleaning facts and plans in
    // the same call. True when it folded.
    bool CompactHistory(bool aFoldAll = false);

    GameFiles& files;
    std::filesystem::path modDir;
    std::filesystem::path dataDir;
    Json config;
    providers::Settings settings;
    std::mutex settingsMutex;
    Memory memory;
    MemoryStore store;
    // Load token from the CET side (one per save load) and the memory version in use.
    std::string memoryToken;
    int memoryVersion = 0;
    std::mutex playtimeMutex;
    double pendingPlaytime = 0.0;
    std::optional<std::chrono::steady_clock::time_point> lastGameMessage;
    std::string promptTemplate;
    std::string defaultLang = "en";
    std::string lastLang = "en";
    Json lastState = Json::object();
    Json lastUsage = Json::object();
    std::string fallbackActive;
    std::mt19937 random{std::random_device{}()};
    std::mutex cueMutex;
    std::vector<Pending> cues;

    // Phase 2c: what Apiko perceives.
    world::Diary diary;
    world::Hearing hearing;
    world::Lore lore;
    // V's words of the turn before (text::Plain): a follow-up question keeps its lore.
    std::string previousWords;
    // When the tracked objective last changed (poll thread) and when the last turn was built (steady seconds).
    std::atomic<double> objectiveChanged{0.0};
    double lastTurnAt = 0.0;

    // Phase 2c-2: written lines and when Apiko speaks (worker thread; steady seconds).
    barks::Barks barks;
    double lastSpoken = 0.0;
    double lastWarning = 0.0;
    double lastVTalk = 0.0; // V's last words (long silences get a loose thought)
    std::string lastDistrictLine; // district situation of the last district V entered
    std::string currentDistrict;
    std::map<std::string, double> visitedDistricts; // district -> last time Apiko was told V entered it

    // Phase 2c-3: the find's written first contact (first_contact.json: language -> part -> sentences).
    Json firstContact = Json::object();

    // Phase 3: the voice (none when there is no output device or voice_enabled is false: subtitles only).
    std::unique_ptr<voice::Voice> voice;
    std::string voiceFailure; // last cause logged (worker thread)

    // Phase 4: the microphone and speech recognition (with the voice: none when voice_enabled is false).
    std::unique_ptr<ears::Ears> ears;
    std::mutex clipsMutex;
    std::deque<std::vector<float>> clips; // recorded on the poll thread, heard on the worker, in order
};
} // namespace apiko
