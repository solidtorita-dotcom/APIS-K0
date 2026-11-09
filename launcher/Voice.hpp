// Apiko's voice: port of Voice, Pose and Speaker in bridge\apiko_voice.py.
// The cloud voice the player picked (Azure, Cartesia, Groq Orpheus, OpenAI) renders each sentence; the machine voice
// and effects (Dsp.hpp) make it Apiko's; a player thread plays the sentences in order on the PC's default output
// (miniaudio), each sentence's subtitle shown when it starts. A new reply (or V pressing push-to-talk, or the session
// ending) cuts what is playing and drops what is queued.
// Position is simulated: audio_pose.txt (written by the CET side) gives the drone's distance and side, turned into
// smoothed left/right gains. Written lines are rendered once and kept in data\speech_cache, the same files and keys
// as the Python bridge, so a cloud voice is paid once.
// Local voices (Piper) come in phase 5: until then a choice the native bridge cannot render, or a failed call, leaves
// Apiko with subtitles only.
#pragma once

#include "Dsp.hpp"
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
    // The cloud voice, resampled to Rate: plain speech, before the machine voice.
    std::vector<float> Synthesize(const std::string& aText, const std::string& aLang);
    // Synthesize + the machine voice for a written line: kept on disk per provider, voice, style and speed.
    std::vector<float> CachedSpeech(const std::string& aText, const std::string& aLang);
    nlohmann::json StyleJson() const;
    dsp::Style MachineStyle() const;
    double Speed(const std::string& aEngine) const;
    std::string VoiceName(const std::string& aEngine, const std::string& aLang) const;

    providers::Settings& settings;
    std::mutex& settingsMutex;
    nlohmann::json config;
    std::filesystem::path modDir;
    std::filesystem::path cacheDir;
    std::unique_ptr<Pose> pose;
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
