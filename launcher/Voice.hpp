// Apiko's voice: port of Voice, Pose and Speaker in bridge\apiko_voice.py.
// The cloud voice the player picked (Azure, Cartesia, Groq Orpheus, OpenAI) renders each sentence; the machine voice
// and effects (Dsp.hpp) make it Apiko's; a player thread plays the sentences in order on the PC's default output
// (miniaudio), each sentence's subtitle shown when it starts. A new reply (or V pressing push-to-talk, or the session
// ending) cuts what is playing and drops what is queued.
// Position is simulated: audio_pose.txt (written by the CET side) gives the drone's distance and side, turned into
// smoothed left/right gains. Written lines are rendered once and kept in data\speech_cache, the same files and keys
// as the Python bridge, so a cloud voice is paid once.
// Piper (Piper.hpp) is the local voice, and the fallback when a cloud voice fails or lacks V's language, so Apiko
// never goes mute while Piper can run. Kokoro is not in the native bridge.
#pragma once

#include "Dsp.hpp"
#include "Piper.hpp"
#include "Providers.hpp"

#include <nlohmann/json.hpp>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace apiko::voice
{
// Every voice is resampled to this before effects and playback.
constexpr int Rate = 24000;

class Speaker;
class Pose;

// A 16-bit PCM WAV as mono samples at Rate, or nothing when it is missing or unreadable.
std::optional<std::vector<float>> LoadWav(const std::filesystem::path& aFile);

class Voice
{
public:
    Voice(providers::Settings& aSettings, std::mutex& aSettingsMutex, const nlohmann::json& aConfig,
          const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir);
    ~Voice();

    // Opens the output device and starts the player thread. False (logged) when there is no device.
    bool Start();
    void Stop();

    // A language the voices have (the catalog's), else its first.
    std::string Language(const std::string& aLang) const;
    // Why the player's voice cannot speak this language now (local engine, language it lacks, no key), or nothing.
    std::optional<std::string> Unavailable(const std::string& aLang) const;
    // One piece of text to Apiko's voice: samples at Rate. Glitch tokens ("0x3F", "NULL"...) are never read aloud.
    // aCache: a written line, said again some day (see CachedSpeech). aPhone: heard through a phone line.
    // Throws http::Error or std::runtime_error.
    std::vector<float> Render(const std::string& aText, const std::string& aLang, double aInstability,
                              bool aCache = false, bool aPhone = false);

    // Loads Piper and runs it once per language (worker thread, at start): the first synthesis is slower.
    void WarmUp();

    // Cuts what Apiko is saying and drops what is queued; returns the id for the next reply's chunks.
    int NewReply();
    // Plays after the chunks already queued for that reply; aOnStart runs when it starts sounding (its subtitle).
    void Queue(int aGeneration, std::vector<float> aAudio, std::function<void()> aOnStart);

private:
    struct Chunk
    {
        int generation;
        std::vector<float> audio;
        std::function<void()> onStart;
    };
    void Play();
    // The player's voice (or Piper in its place), resampled to Rate: plain speech, before the machine voice.
    // aEngine: the engine that rendered it.
    std::vector<float> Synthesize(const std::string& aText, const std::string& aLang, std::string& aEngine);
    std::vector<float> Local(const std::string& aText, const std::string& aLang);
    std::vector<float> SynthesizeCloud(const providers::Choice& aChoice, const std::string& aText, const std::string& aLang);
    // Why the cloud voice cannot speak aLang (it lacks the language, no key), or nothing.
    std::optional<std::string> CloudProblem(const providers::Choice& aChoice, const std::string& aLang) const;
    // Synthesize + the machine voice for a written line: kept on disk per provider, voice, style and speed.
    std::vector<float> CachedSpeech(const std::string& aText, const std::string& aLang);
    nlohmann::json StyleJson(const std::string& aEngine) const;
    dsp::Style MachineStyle(const std::string& aEngine) const;
    providers::Choice Choice() const;
    double Speed(const std::string& aEngine) const;
    std::string VoiceName(const std::string& aEngine, const std::string& aLang) const;

    providers::Settings& settings;
    std::mutex& settingsMutex;
    nlohmann::json config;
    std::filesystem::path modDir;
    std::filesystem::path cacheDir;
    std::unique_ptr<Pose> pose;
    std::unique_ptr<piper::Piper> piper;
    std::string lastFailure; // last cloud failure logged (worker thread)
    std::unique_ptr<Speaker> speaker;
    std::thread player;
    std::mutex queueMutex;
    std::condition_variable queueReady;
    std::deque<Chunk> playlist;
    bool stopping = false;
    std::atomic<int> generation{0};
    std::mt19937 random{std::random_device{}()}; // glitches (Render runs on the worker thread only)
};
} // namespace apiko::voice
