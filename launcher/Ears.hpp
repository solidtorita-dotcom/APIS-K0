// Apiko's ears: port of Ears in bridge\apiko_voice.py. Push-to-talk records the default microphone (miniaudio,
// 16 kHz mono, opened only while the key is held); speech recognition is the cloud service the player picked
// (Groq or OpenAI Whisper). Local Whisper comes in phase 5: until then that choice gets a notice.
// Start/Stop run on the bridge's poll thread (they must be quick); Transcribe on the worker (it blocks on the call).
#pragma once

#include "Providers.hpp"

#include <nlohmann/json.hpp>

#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace apiko::ears
{
// What Whisper expects.
constexpr int MicRate = 16000;

class Microphone;

class Ears
{
public:
    Ears(providers::Settings& aSettings, std::mutex& aSettingsMutex, const nlohmann::json& aConfig);
    ~Ears();

    // Starts recording (a press of push-to-talk). False (logged) when there is no microphone.
    bool Start();
    // Stops recording; the audio, or nothing when nothing was being recorded.
    std::optional<std::vector<float>> Stop();

    // The words in a clip and their two-letter language, or nothing (too short, no voice in it, nothing understood,
    // a typical Whisper hallucination). Throws providers::Error when the service fails.
    std::optional<std::pair<std::string, std::string>> Transcribe(const std::vector<float>& aAudio);
    // One call with a second of silence: the settings window's Test. Throws on failure.
    void Test();

private:
    std::pair<std::string, std::string> Remote(const providers::Choice& aChoice, const std::string& aWav,
                                               const std::string& aLanguage);
    std::pair<std::string, std::string> TranscribeRemote(const std::vector<float>& aAudio);
    bool Hallucinated(const std::string& aText) const;

    providers::Settings& settings;
    std::mutex& settingsMutex;
    nlohmann::json config;
    std::mutex mutex;
    std::unique_ptr<Microphone> microphone;
};

// "a pico", "Apíkó", "happy ko"... -> "Apiko": ways Whisper writes the name despite the hint.
std::string FixName(const std::string& aText);
} // namespace apiko::ears
