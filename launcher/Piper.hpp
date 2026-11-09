// Piper, Apiko's local voice: port of what piper1-gpl does for the Python bridge (bridge\apiko_voice.Voice.local).
// Text -> IPA phonemes per sentence with espeak-ng (linked in statically; its data in <mod>\data\espeak-ng-data) ->
// phoneme ids (the voice's .onnx.json) -> the VITS model with onnxruntime (onnxruntime.dll next to this plugin,
// loaded on first use through its C API, so a missing DLL only disables Piper).
// Voices live in %LOCALAPPDATA%\Apiko\models\piper (shared with the Python bridge) and are downloaded on first use.
// Synthesize is called from the worker thread only.
#pragma once

#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace apiko::piper
{
class Piper
{
public:
    // aRuntime: onnxruntime.dll; aEspeakData: the espeak-ng-data folder; aModels: where the voices are kept.
    Piper(std::filesystem::path aRuntime, std::filesystem::path aEspeakData, std::filesystem::path aModels);
    ~Piper();

    // Why Piper cannot run here (missing DLL or espeak data), or nothing. Cheap: checks files only.
    std::optional<std::string> Missing() const;

    // aVoice: "<name>" or "<name>#<speaker>" (e.g. "es_ES-sharvard-medium#1"). aSpeed > 1 speaks faster.
    // Samples at the voice's own rate (set in aRate). Throws std::runtime_error.
    std::vector<float> Synthesize(const std::string& aText, const std::string& aVoice, double aSpeed, int& aRate);

    // The phonemes espeak-ng gives for a text, one line per sentence (diagnostics: tests\piper_wav.cpp).
    std::string PhonemeText(const std::string& aText, const std::string& aEspeakVoice);

private:
    struct Model;
    struct Runtime;
    Model& Load(const std::string& aName);
    std::filesystem::path Download(const std::string& aName, const std::string& aSuffix);
    std::vector<std::vector<std::u32string>> Phonemize(const std::string& aText, const std::string& aEspeakVoice);

    std::filesystem::path runtimePath;
    std::filesystem::path espeakData;
    std::filesystem::path models;
    std::unique_ptr<Runtime> runtime;
    std::map<std::string, std::unique_ptr<Model>> loaded;
    bool espeakReady = false;
};
} // namespace apiko::piper
