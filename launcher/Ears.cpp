#include "Ears.hpp"

#include "Dsp.hpp"
#include "Http.hpp"
#include "Log.hpp"
#include "Text.hpp"

#include <Windows.h>

#pragma warning(push, 0)
#include <miniaudio/miniaudio.h>
#include <whisper.h>
#pragma warning(pop)

#include <algorithm>
#include <cmath>
#include <thread>
#include <regex>
#include <set>

namespace apiko::ears
{
using Json = nlohmann::json;

namespace
{
constexpr double MinSpeechSeconds = 0.35;
// Less voiced sound than this: not sent to speech recognition (silence and noise give 0).
constexpr double MinVoicedSeconds = 0.1;

// Words of a text (text::Plain), as Python's re.findall(r"\w+", text.lower()): bytes past ASCII count as letters.
std::vector<std::string> PlainWords(const std::string& aText)
{
    std::vector<std::string> words;
    std::string word;
    for (char c : text::Plain(aText))
    {
        auto u = static_cast<unsigned char>(c);
        if (u >= 0x80 || std::isalnum(u) || c == '_')
            word += c;
        else if (!word.empty())
        {
            words.push_back(word);
            word.clear();
        }
    }
    if (!word.empty())
        words.push_back(word);
    return words;
}

std::string ToWav(const std::vector<float>& aAudio, int aRate)
{
    std::string wav;
    auto put32 = [&](std::uint32_t v) { wav.append(reinterpret_cast<const char*>(&v), 4); };
    auto put16 = [&](std::uint16_t v) { wav.append(reinterpret_cast<const char*>(&v), 2); };
    auto bytes = static_cast<std::uint32_t>(aAudio.size() * 2);
    wav += "RIFF";
    put32(36 + bytes);
    wav += "WAVEfmt ";
    put32(16);
    put16(1);
    put16(1);
    put32(static_cast<std::uint32_t>(aRate));
    put32(static_cast<std::uint32_t>(aRate * 2));
    put16(2);
    put16(16);
    wav += "data";
    put32(bytes);
    for (float v : aAudio)
        put16(static_cast<std::uint16_t>(static_cast<std::int16_t>(std::clamp(v, -1.0f, 1.0f) * 32767)));
    return wav;
}

// How much of a microphone clip has a pitch (actual voice, not silence, breath or noise).
double VoicedSeconds(const std::vector<float>& aAudio)
{
    int hop = 0;
    auto f0 = dsp::PitchTrack(std::vector<double>(aAudio.begin(), aAudio.end()), MicRate, hop);
    auto voiced = std::count_if(f0.begin(), f0.end(), [](double f) { return f > 0; });
    return static_cast<double>(voiced) * hop / MicRate;
}

std::string RandomBoundary()
{
    static const char hex[] = "0123456789abcdef";
    std::string boundary;
    auto seed = static_cast<unsigned>(GetTickCount64());
    for (int i = 0; i < 32; ++i)
    {
        seed = seed * 1103515245u + 12345u;
        boundary += hex[(seed >> 16) & 15];
    }
    return boundary;
}
} // namespace

// The default microphone, recording into a buffer while it is open.
class Microphone
{
public:
    ~Microphone()
    {
        if (open)
            ma_device_uninit(&device);
    }

    bool Open()
    {
        auto config = ma_device_config_init(ma_device_type_capture);
        config.capture.format = ma_format_f32;
        config.capture.channels = 1;
        config.sampleRate = MicRate;
        config.dataCallback = [](ma_device* aDevice, void*, const void* aInput, ma_uint32 aFrames) {
            auto* self = static_cast<Microphone*>(aDevice->pUserData);
            const auto* samples = static_cast<const float*>(aInput);
            std::lock_guard lock(self->mutex);
            self->audio.insert(self->audio.end(), samples, samples + aFrames);
        };
        config.pUserData = this;
        if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS)
            return false;
        open = true;
        return ma_device_start(&device) == MA_SUCCESS;
    }

    std::vector<float> Close()
    {
        if (open)
        {
            ma_device_uninit(&device);
            open = false;
        }
        std::lock_guard lock(mutex);
        return std::move(audio);
    }

private:
    ma_device device{};
    bool open = false;
    std::mutex mutex;
    std::vector<float> audio;
};

// whisper.cpp with one model loaded at a time.
class LocalWhisper
{
public:
    explicit LocalWhisper(std::filesystem::path aModels)
        : models(std::move(aModels))
    {
        // whisper.cpp logs a lot to stderr: only errors, into our log.
        whisper_log_set(
            [](enum ggml_log_level aLevel, const char* aText, void*) {
                if (aLevel == GGML_LOG_LEVEL_ERROR && aText)
                    log::Write(std::string("whisper: ") + text::Trim(aText));
            },
            nullptr);
    }

    ~LocalWhisper()
    {
        if (context)
            whisper_free(context);
    }

    void Load(const std::string& aName)
    {
        if (context && aName == name)
            return;
        auto file = models / text::Widen("ggml-" + aName + ".bin");
        std::error_code error;
        if (!std::filesystem::exists(file, error))
        {
            log::Write("downloading Whisper model " + aName + " (first use, only once)...");
            http::Download("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-" + aName + ".bin", file, 120.0);
        }
        if (context)
            whisper_free(context);
        auto started = GetTickCount64();
        auto params = whisper_context_default_params();
        params.use_gpu = false; // the GPU is the game's (and the AMD driver hangs)
        context = whisper_init_from_file_with_params(text::PathString(file).c_str(), params);
        if (!context)
            throw std::runtime_error("Whisper model " + text::PathString(file) + " could not be loaded");
        name = aName;
        log::Write("Whisper '" + aName + "' ready (" + std::to_string((GetTickCount64() - started) / 1000.0).substr(0, 4) +
                   "s)");
    }

    std::pair<std::string, std::string> Transcribe(const std::vector<float>& aAudio, const std::vector<std::string>& aAllowed,
                                                   const std::string& aHint)
    {
        int threads = std::clamp(static_cast<int>(std::thread::hardware_concurrency()) / 2, 1, 4);
        // The language first, limited to the allowed ones: short clips are often misdetected.
        if (whisper_pcm_to_mel(context, aAudio.data(), static_cast<int>(aAudio.size()), threads) != 0)
            throw std::runtime_error("Whisper could not read the clip");
        std::vector<float> probs(whisper_lang_max_id() + 1, 0.0f);
        int best = whisper_lang_auto_detect(context, 0, threads, probs.data());
        std::string language = best >= 0 ? whisper_lang_str(best) : "";
        if (!aAllowed.empty() && std::find(aAllowed.begin(), aAllowed.end(), language) == aAllowed.end())
        {
            language = aAllowed[0];
            float top = -1.0f;
            for (const auto& lang : aAllowed)
            {
                int id = whisper_lang_id(lang.c_str());
                if (id >= 0 && probs[id] > top)
                {
                    top = probs[id];
                    language = lang;
                }
            }
        }
        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = threads;
        params.language = language.c_str();
        params.detect_language = false;
        params.initial_prompt = aHint.c_str();
        params.no_context = true;
        params.no_timestamps = true;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_special = false;
        params.print_timestamps = false;
        if (whisper_full(context, params, aAudio.data(), static_cast<int>(aAudio.size())) != 0)
            throw std::runtime_error("Whisper could not transcribe the clip");
        std::string said;
        for (int i = 0; i < whisper_full_n_segments(context); ++i)
            said += whisper_full_get_segment_text(context, i);
        return {text::Trim(said), language};
    }

private:
    std::filesystem::path models;
    whisper_context* context = nullptr;
    std::string name;
};

Ears::Ears(providers::Settings& aSettings, std::mutex& aSettingsMutex, const Json& aConfig,
           const std::filesystem::path& aModels)
    : settings(aSettings)
    , settingsMutex(aSettingsMutex)
    , config(aConfig)
    , local(std::make_unique<LocalWhisper>(aModels))
{
    if (config.contains("input_device") && !config["input_device"].is_null())
        log::Write("ears: config input_device is not used by the native bridge yet (default microphone)");
}

Ears::~Ears()
{
    std::lock_guard lock(mutex);
    if (microphone)
        microphone->Close();
}

bool Ears::Start()
{
    std::lock_guard lock(mutex);
    if (microphone)
        return true;
    microphone = std::make_unique<Microphone>();
    if (!microphone->Open())
    {
        microphone.reset();
        log::Write("ears: no microphone could be opened");
        return false;
    }
    return true;
}

std::optional<std::vector<float>> Ears::Stop()
{
    std::lock_guard lock(mutex);
    if (!microphone)
        return std::nullopt;
    auto audio = microphone->Close();
    microphone.reset();
    if (audio.empty())
        return std::nullopt;
    return audio;
}

std::pair<std::string, std::string> Ears::Remote(const providers::Choice& aChoice, const std::string& aWav,
                                                 const std::string& aLanguage)
{
    if (auto problem = providers::Missing(aChoice))
        throw providers::Error(*problem);
    std::vector<std::pair<std::string, std::string>> fields = {{"model", aChoice.model},
                                                               {"response_format", "verbose_json"},
                                                               {"temperature", "0"},
                                                               {"prompt", config.value("whisper_hint", std::string())}};
    if (!aLanguage.empty())
        fields.emplace_back("language", aLanguage);
    auto boundary = RandomBoundary();
    std::string body;
    for (const auto& [name, value] : fields)
        body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + value + "\r\n";
    body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n"
            "Content-Type: audio/wav\r\n\r\n";
    body += aWav;
    body += "\r\n--" + boundary + "--\r\n";
    std::map<std::string, std::string> headers = {{"Content-Type", "multipart/form-data; boundary=" + boundary},
                                                  {"Authorization", "Bearer " + aChoice.key}};
    auto raw = http::Request(aChoice.baseUrl + "/audio/transcriptions", &body, headers,
                             config.value("stt_timeout_seconds", 8.0));
    auto result = Json::parse(raw, nullptr, false);
    if (!result.is_object())
        throw providers::Error("bad response: " + http::Snippet(raw, 120));
    auto detected = text::Lower(result.value("language", aLanguage));
    for (const auto& [name, code] : providers::LanguageNames())
        if (name == detected)
            detected = code;
    return {text::Trim(result.value("text", std::string())), detected};
}

std::vector<std::string> Ears::Allowed() const
{
    auto catalog = settings.Catalog();
    std::vector<std::string> allowed;
    if (catalog["languages"].is_array())
        for (const auto& lang : catalog["languages"])
            if (lang.is_string())
                allowed.push_back(lang.get<std::string>());
    return allowed;
}

std::string Ears::LocalModel() const
{
    // The player's local model, or (as the cloud's fallback) the catalog's recommended one.
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("stt");
    }
    if (choice.id == "local" && !choice.model.empty())
        return choice.model;
    auto catalog = settings.Catalog();
    auto models = catalog["stt"]["providers"]["local"].value("models", Json::array());
    for (const auto& model : models)
        if (model.value("badge", std::string()) == "Recommended")
            return model.value("id", std::string("base"));
    return !models.empty() ? models[0].value("id", std::string("base")) : std::string("base");
}

std::pair<std::string, std::string> Ears::TranscribeLocal(const std::vector<float>& aAudio)
{
    local->Load(LocalModel());
    return local->Transcribe(aAudio, Allowed(), config.value("whisper_hint", std::string()));
}

std::pair<std::string, std::string> Ears::Recognize(const std::vector<float>& aAudio, bool aStrict)
{
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("stt");
    }
    if (choice.id == "local")
        return TranscribeLocal(aAudio);
    try
    {
        auto allowed = Allowed();
        auto wav = ToWav(aAudio, MicRate);
        auto [said, language] = Remote(choice, wav, "");
        if (!said.empty() && !allowed.empty() && std::find(allowed.begin(), allowed.end(), language) == allowed.end())
            // Short clips are sometimes misdetected: try again in the main language.
            std::tie(said, language) = Remote(choice, wav, allowed[0]);
        lastFailure.clear();
        return {said, language};
    }
    catch (const std::exception& e)
    {
        if (aStrict)
            throw;
        if (e.what() != lastFailure)
        {
            lastFailure = e.what();
            log::Write(choice.label + " speech recognition failed, using local Whisper: " + e.what());
        }
        return TranscribeLocal(aAudio);
    }
}

std::optional<std::pair<std::string, std::string>> Ears::Transcribe(const std::vector<float>& aAudio)
{
    if (aAudio.size() < static_cast<std::size_t>(MicRate * MinSpeechSeconds))
        return std::nullopt;
    double voiced = VoicedSeconds(aAudio);
    if (voiced < MinVoicedSeconds)
    {
        // Whisper "hears" something in silence (often the hint words): do not even ask.
        char seconds[16];
        std::snprintf(seconds, sizeof(seconds), "%.2f", voiced);
        log::Write(std::string("no speech in the clip (") + seconds + "s voiced), ignored");
        return std::nullopt;
    }
    auto [said, language] = Recognize(aAudio);
    if (said.empty())
        return std::nullopt;
    if (Hallucinated(said))
    {
        log::Write("ignored a typical Whisper hallucination: " + said);
        return std::nullopt;
    }
    auto fixed = FixName(said);
    if (fixed != said)
    {
        log::Write("name fixed: " + said + " -> " + fixed);
        said = fixed;
    }
    return std::make_pair(said, language);
}

void Ears::Test()
{
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("stt");
    }
    if (choice.id == "local")
        local->Load(LocalModel());
    else
        Recognize(std::vector<float>(MicRate, 0.0f), true);
}

void Ears::WarmUp()
{
    // The local model is only loaded up front when it is the player's choice; as a fallback, when needed.
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("stt");
    }
    if (choice.id != "local")
        return;
    try
    {
        local->Load(LocalModel());
    }
    catch (const std::exception& e)
    {
        log::Write(std::string("Whisper warm-up failed: ") + e.what());
    }
}

bool Ears::Hallucinated(const std::string& aText) const
{
    // Phrases Whisper invents for near-silent clips: only the hint words, or subtitle/video boilerplate.
    auto words = PlainWords(aText);
    auto hintWords = PlainWords(config.value("whisper_hint", std::string()));
    std::set<std::string> hint(hintWords.begin(), hintWords.end());
    if (!words.empty() && std::all_of(words.begin(), words.end(), [&](const std::string& w) { return hint.count(w) > 0; }))
        return true;
    static const std::regex boilerplate(
        R"(amara\.org|subtitulos (realizados|por)|thanks? (you )?for watching|gracias por ver|suscribete|subscribe to|)"
        R"(like and subscribe)");
    return std::regex_search(text::Plain(aText), boilerplate);
}

std::string FixName(const std::string& aText)
{
    // Word spans of the text (bytes past ASCII count as letters), compared without case or accents.
    struct Span
    {
        std::size_t start, end;
        std::string plain;
    };
    std::vector<Span> spans;
    for (std::size_t i = 0; i < aText.size();)
    {
        auto u = static_cast<unsigned char>(aText[i]);
        if (u >= 0x80 || std::isalnum(u) || aText[i] == '_')
        {
            auto j = i;
            while (j < aText.size() && (static_cast<unsigned char>(aText[j]) >= 0x80 ||
                                        std::isalnum(static_cast<unsigned char>(aText[j])) || aText[j] == '_'))
                ++j;
            spans.push_back({i, j, text::Plain(aText.substr(i, j - i))});
            i = j;
        }
        else
            ++i;
    }
    static const std::set<std::string> single = {"apico", "apiko", "abiko", "apiku", "happyko"};
    std::string out;
    std::size_t copied = 0;
    for (std::size_t k = 0; k < spans.size(); ++k)
    {
        auto first = spans[k].start;
        std::size_t end = 0;
        if (single.count(spans[k].plain))
            end = spans[k].end;
        else if (k + 1 < spans.size())
        {
            // "a pico", "a-piko", "happy ko": two words with one space (or a hyphen for "a") between them.
            auto gap = aText.substr(spans[k].end, spans[k + 1].start - spans[k].end);
            const auto& next = spans[k + 1].plain;
            bool aPico = spans[k].plain == "a" && (next == "pico" || next == "piko") &&
                         (gap == " " || gap == "-" || gap == "\t");
            bool happyKo = spans[k].plain == "happy" && next == "ko" && gap == " ";
            if (aPico || happyKo)
                end = spans[++k].end;
        }
        if (!end)
            continue;
        out += aText.substr(copied, first - copied) + "Apiko";
        copied = end;
    }
    return out + aText.substr(copied);
}
} // namespace apiko::ears
