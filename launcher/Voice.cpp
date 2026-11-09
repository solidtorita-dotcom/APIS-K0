#include "Voice.hpp"

#include "Http.hpp"
#include "Log.hpp"
#include "Text.hpp"

#include <Windows.h>
#include <bcrypt.h>

#pragma warning(push, 0)
#include <miniaudio/miniaudio.h>
#pragma warning(pop)

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <numbers>
#include <regex>
#include <sstream>

#pragma comment(lib, "bcrypt.lib")

namespace apiko::voice
{
using Json = nlohmann::json;

// --- position ---

// Where the drone is relative to the camera (audio_pose.txt: "distance pan front", written by the CET side), as
// smoothed left/right gains: quieter with distance, panned to the side it is on, a bit quieter behind V.
class Pose
{
public:
    explicit Pose(std::filesystem::path aFile)
        : file(std::move(aFile))
        , thread([this] { Follow(); })
    {
    }

    ~Pose()
    {
        {
            std::lock_guard lock(mutex);
            stopping = true;
        }
        wake.notify_all();
        thread.join();
    }

    std::array<float, 2> Gains()
    {
        std::lock_guard lock(mutex);
        return current;
    }

private:
    static constexpr double RefDistance = 2.0; // full volume up to this many metres
    static constexpr double MinGain = 0.3;
    static constexpr double BehindGain = 0.8;
    static constexpr double PanAmount = 0.8;  // never fully in one ear
    static constexpr double Smoothing = 0.5;  // share of the way to the new target per update

    std::array<double, 2> Target()
    {
        // A missing file, "car", "none" or a half-written one: centred.
        std::ifstream in(file);
        double distance = 0, pan = 0, front = 0;
        if (!(in >> distance >> pan >> front))
            return {1.0, 1.0};
        double gain = distance <= RefDistance ? 1.0 : std::max(MinGain, std::pow(RefDistance / distance, 0.9));
        if (front < -0.3)
            gain *= BehindGain;
        double angle = (std::clamp(pan, -1.0, 1.0) * PanAmount + 1.0) * std::numbers::pi / 4;
        double left = std::cos(angle), right = std::sin(angle);
        // Loudest channel at "gain": no clipping when panned hard.
        double top = std::max(left, right);
        return {left / top * gain, right / top * gain};
    }

    void Follow()
    {
        std::array<double, 2> smooth{1.0, 1.0};
        std::unique_lock lock(mutex);
        while (!stopping)
        {
            lock.unlock();
            auto target = Target();
            for (int c = 0; c < 2; ++c)
                smooth[c] += (target[c] - smooth[c]) * Smoothing;
            lock.lock();
            current = {static_cast<float>(smooth[0]), static_cast<float>(smooth[1])};
            wake.wait_for(lock, std::chrono::milliseconds(100), [this] { return stopping; });
        }
    }

    std::filesystem::path file;
    std::mutex mutex;
    std::condition_variable wake;
    bool stopping = false;
    std::array<float, 2> current{1.0f, 1.0f};
    std::thread thread;
};

// --- output ---

// Stereo output stream playing one chunk at a time; the gains are applied per block, so the voice follows the drone
// while it talks. Play blocks until the chunk has played or was cut.
class Speaker
{
public:
    explicit Speaker(Pose* aPose)
        : pose(aPose)
    {
    }

    ~Speaker()
    {
        if (open)
            ma_device_uninit(&device);
    }

    bool Open()
    {
        auto config = ma_device_config_init(ma_device_type_playback);
        config.playback.format = ma_format_f32;
        config.playback.channels = 2;
        config.sampleRate = Rate;
        config.periodSizeInFrames = 512;
        config.dataCallback = [](ma_device* aDevice, void* aOut, const void*, ma_uint32 aFrames) {
            static_cast<Speaker*>(aDevice->pUserData)->Fill(static_cast<float*>(aOut), aFrames);
        };
        config.pUserData = this;
        if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS)
            return false;
        open = true;
        if (ma_device_start(&device) != MA_SUCCESS)
            return false;
        log::Write(std::string("voice output: ") + device.playback.name);
        return true;
    }

    void Play(const std::vector<float>& aAudio)
    {
        std::unique_lock lock(mutex);
        current = &aAudio;
        position = 0;
        finished.wait(lock, [this] { return current == nullptr; });
    }

    void Cut()
    {
        {
            std::lock_guard lock(mutex);
            current = nullptr;
        }
        finished.notify_all();
    }

private:
    void Fill(float* aOut, ma_uint32 aFrames)
    {
        std::fill(aOut, aOut + aFrames * 2, 0.0f);
        // Ramp from the last gains to the new ones over the block: no clicks when they change.
        auto target = pose ? pose->Gains() : std::array<float, 2>{1.0f, 1.0f};
        auto start = gains;
        gains = target;
        bool done = false;
        {
            std::lock_guard lock(mutex);
            if (!current)
                return;
            auto count = std::min<std::size_t>(aFrames, current->size() - position);
            for (std::size_t i = 0; i < count; ++i)
            {
                float ramp = aFrames > 1 ? static_cast<float>(i) / (aFrames - 1) : 1.0f;
                float sample = (*current)[position + i];
                aOut[i * 2] = sample * (start[0] + (target[0] - start[0]) * ramp);
                aOut[i * 2 + 1] = sample * (start[1] + (target[1] - start[1]) * ramp);
            }
            position += count;
            if (position >= current->size())
            {
                current = nullptr;
                done = true;
            }
        }
        if (done)
            finished.notify_all();
    }

    Pose* pose;
    std::array<float, 2> gains{1.0f, 1.0f};
    ma_device device{};
    bool open = false;
    std::mutex mutex;
    std::condition_variable finished;
    const std::vector<float>* current = nullptr;
    std::size_t position = 0;
};

namespace
{
// Glitch tokens the model writes into the text: never read aloud, each becomes a glitch sound.
const std::regex& GlitchToken()
{
    static const std::regex pattern(
        "(0x[0-9A-Fa-f]+|\\bNULL\\b|//+|\\b[01]{4,}\\b|(?:\xE2\x96\x93|\xE2\x96\x91|\xE2\x96\x92|\xE2\x96\x88|"
        "\xE2\x96\xA0|\xE2\x96\xA1)+|<[^>]{0,20}>|\\[[^\\]]{0,20}\\])");
    return pattern;
}

bool HasWord(const std::string& aText)
{
    return std::any_of(aText.begin(), aText.end(), [](char c) {
        auto u = static_cast<unsigned char>(c);
        return u >= 0x80 || std::isalnum(u);
    });
}

std::vector<float> Pcm16(const std::string& aRaw, std::size_t aOffset = 0)
{
    std::vector<float> samples((aRaw.size() - std::min(aOffset, aRaw.size())) / 2);
    for (std::size_t i = 0; i < samples.size(); ++i)
    {
        auto lo = static_cast<unsigned char>(aRaw[aOffset + i * 2]);
        auto hi = static_cast<unsigned char>(aRaw[aOffset + i * 2 + 1]);
        samples[i] = static_cast<std::int16_t>(lo | (hi << 8)) / 32768.0f;
    }
    return samples;
}

std::vector<float> Resample(std::vector<float> aSamples, int aRate)
{
    if (aRate == Rate || aSamples.empty() || aRate <= 0)
        return aSamples;
    double step = static_cast<double>(aRate) / Rate;
    std::vector<float> out(static_cast<std::size_t>(std::ceil(aSamples.size() / step)));
    for (std::size_t i = 0; i < out.size(); ++i)
    {
        double at = i * step;
        auto j = static_cast<std::size_t>(at);
        double frac = at - j;
        float a = aSamples[std::min(j, aSamples.size() - 1)];
        float b = aSamples[std::min(j + 1, aSamples.size() - 1)];
        out[i] = static_cast<float>(a + (b - a) * frac);
    }
    return out;
}

// A WAV file's 16-bit samples, its rate and channel count. A streamed WAV may have a placeholder header: then 24 kHz
// mono after 44 bytes.
std::vector<float> ParseWav(const std::string& aRaw, int& aRate)
{
    int rate = 24000, channels = 1;
    std::size_t data = 44;
    if (aRaw.size() > 12 && aRaw.compare(0, 4, "RIFF") == 0)
    {
        for (std::size_t at = 12; at + 8 <= aRaw.size();)
        {
            std::uint32_t size = 0;
            std::memcpy(&size, aRaw.data() + at + 4, 4);
            if (aRaw.compare(at, 4, "fmt ") == 0 && at + 16 <= aRaw.size())
            {
                std::uint16_t count = 0;
                std::uint32_t frequency = 0;
                std::memcpy(&count, aRaw.data() + at + 10, 2);
                std::memcpy(&frequency, aRaw.data() + at + 12, 4);
                channels = std::max<int>(1, count);
                rate = static_cast<int>(frequency);
            }
            if (aRaw.compare(at, 4, "data") == 0)
            {
                data = at + 8;
                break;
            }
            at += 8 + size + (size & 1);
        }
    }
    auto samples = Pcm16(aRaw, data);
    if (channels > 1)
    {
        std::vector<float> mono(samples.size() / channels);
        for (std::size_t i = 0; i < mono.size(); ++i)
        {
            float sum = 0;
            for (int c = 0; c < channels; ++c)
                sum += samples[i * channels + c];
            mono[i] = sum / channels;
        }
        samples = std::move(mono);
    }
    aRate = rate;
    return samples;
}

std::string XmlEscape(const std::string& aText)
{
    std::string out;
    for (char c : aText)
    {
        switch (c)
        {
        case '&': out += "&amp;"; break;
        case '<': out += "&lt;"; break;
        case '>': out += "&gt;"; break;
        default: out += c;
        }
    }
    return out;
}

// --- speech cache: the Python bridge's keys and files ---

// Python's json.dumps(value, sort_keys=True): ", " and ": " separators, non-ASCII as \uXXXX (UTF-16 units).
std::string PyJson(const Json& aValue)
{
    if (aValue.is_string())
    {
        auto wide = text::Widen(aValue.get<std::string>());
        std::string out = "\"";
        for (wchar_t w : wide)
        {
            auto c = static_cast<unsigned>(w);
            if (c == '"')
                out += "\\\"";
            else if (c == '\\')
                out += "\\\\";
            else if (c == '\n')
                out += "\\n";
            else if (c == '\r')
                out += "\\r";
            else if (c == '\t')
                out += "\\t";
            else if (c == '\b')
                out += "\\b";
            else if (c == '\f')
                out += "\\f";
            else if (c < 0x20 || c > 0x7E)
            {
                // Python escapes control characters and everything past ASCII; 0x7F stays as it is.
                if (c == 0x7F)
                {
                    out += static_cast<char>(c);
                    continue;
                }
                char escaped[8];
                std::snprintf(escaped, sizeof(escaped), "\\u%04x", c);
                out += escaped;
            }
            else
                out += static_cast<char>(c);
        }
        return out + "\"";
    }
    if (aValue.is_array())
    {
        std::string out = "[";
        for (std::size_t i = 0; i < aValue.size(); ++i)
            out += (i ? ", " : "") + PyJson(aValue[i]);
        return out + "]";
    }
    if (aValue.is_object())
    {
        std::string out = "{";
        bool first = true;
        for (const auto& [key, value] : aValue.items()) // nlohmann::json keeps keys sorted
        {
            out += (first ? "" : ", ") + PyJson(Json(key)) + ": " + PyJson(value);
            first = false;
        }
        return out + "}";
    }
    return aValue.dump(); // numbers (floats keep their ".0", like Python), true, false, null
}

std::string Sha1Hex(const std::string& aData)
{
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    std::array<unsigned char, 20> digest{};
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA1_ALGORITHM, nullptr, 0) == 0)
    {
        BCryptHash(algorithm, nullptr, 0, reinterpret_cast<PUCHAR>(const_cast<char*>(aData.data())),
                   static_cast<ULONG>(aData.size()), digest.data(), static_cast<ULONG>(digest.size()));
        BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    std::string hex;
    for (auto byte : digest)
    {
        char two[3];
        std::snprintf(two, sizeof(two), "%02x", byte);
        hex += two;
    }
    return hex;
}

// A 1-D float32 .npy file (np.save of the Python bridge), or nothing.
std::optional<std::vector<float>> LoadNpy(const std::filesystem::path& aFile)
{
    auto raw = text::ReadFile(aFile);
    if (!raw || raw->size() < 12 || raw->compare(0, 6, "\x93NUMPY") != 0)
        return std::nullopt;
    std::size_t headerLength = 0, start = 0;
    if ((*raw)[6] == 1)
    {
        headerLength = static_cast<unsigned char>((*raw)[8]) | (static_cast<unsigned char>((*raw)[9]) << 8);
        start = 10;
    }
    else
    {
        std::uint32_t length = 0;
        std::memcpy(&length, raw->data() + 8, 4);
        headerLength = length;
        start = 12;
    }
    if (start + headerLength > raw->size())
        return std::nullopt;
    auto header = raw->substr(start, headerLength);
    if (header.find("'<f4'") == std::string::npos || header.find("'fortran_order': False") == std::string::npos)
        return std::nullopt;
    auto data = start + headerLength;
    std::vector<float> samples((raw->size() - data) / 4);
    std::memcpy(samples.data(), raw->data() + data, samples.size() * 4);
    return samples;
}

bool SaveNpy(const std::filesystem::path& aFile, const std::vector<float>& aSamples)
{
    std::string header = "{'descr': '<f4', 'fortran_order': False, 'shape': (" + std::to_string(aSamples.size()) + ",), }";
    // Magic (6) + version (2) + length (2) + header, padded with spaces to 64 bytes and ending in a newline.
    while ((10 + header.size() + 1) % 64)
        header += ' ';
    header += '\n';
    std::string content = std::string("\x93NUMPY\x01\x00", 8);
    content += static_cast<char>(header.size() & 0xFF);
    content += static_cast<char>((header.size() >> 8) & 0xFF);
    content += header;
    content.append(reinterpret_cast<const char*>(aSamples.data()), aSamples.size() * 4);
    auto temp = aFile;
    temp += L".tmp";
    {
        std::ofstream out(temp, std::ios::binary);
        if (!out.write(content.data(), static_cast<std::streamsize>(content.size())))
            return false;
    }
    std::error_code error;
    std::filesystem::rename(temp, aFile, error);
    return !error;
}

// --- cloud voices ---

struct Samples
{
    std::vector<float> audio;
    int rate;
};

using Headers = std::map<std::string, std::string>;

Samples Azure(const providers::Choice& aChoice, const std::string& aText, const std::string& aLang,
              const std::string& aVoice, double aSpeed, double aTimeout)
{
    // Azure Speech REST: SSML in, raw 24 kHz PCM out. The base URL is the resource's region ("westeurope") or a full
    // endpoint URL.
    auto region = text::Trim(aChoice.baseUrl);
    while (!region.empty() && region.back() == '/')
        region.pop_back();
    auto url = region.find("://") != std::string::npos ? region : "https://" + region + ".tts.speech.microsoft.com";
    if (url.size() < 21 || url.compare(url.size() - 21, 21, "/cognitiveservices/v1") != 0)
        url += "/cognitiveservices/v1";
    auto locale = std::count(aVoice.begin(), aVoice.end(), '-') >= 2 ? aVoice.substr(0, aVoice.rfind('-')) : aLang;
    char rate[16];
    std::snprintf(rate, sizeof(rate), "%+.0f%%", (std::clamp(aSpeed, 0.5, 2.0) - 1.0) * 100);
    auto body = std::string("<prosody rate='") + rate + "'>" + XmlEscape(aText) + "</prosody>";
    // A multilingual voice speaks V's language with its own timbre: say which, instead of letting it guess.
    static const std::map<std::string, std::string> locales = {{"es", "es-ES"}, {"en", "en-US"}, {"fr", "fr-FR"},
                                                               {"de", "de-DE"}, {"it", "it-IT"}, {"pt", "pt-BR"},
                                                               {"pl", "pl-PL"}, {"ru", "ru-RU"}, {"ja", "ja-JP"},
                                                               {"zh", "zh-CN"}};
    if (aVoice.find("Multilingual") != std::string::npos && text::Lower(locale).rfind(text::Lower(aLang), 0) != 0)
    {
        auto it = locales.find(aLang);
        body = "<lang xml:lang='" + (it == locales.end() ? aLang : it->second) + "'>" + body + "</lang>";
    }
    auto ssml = "<speak version='1.0' xml:lang='" + locale + "'><voice name='" + aVoice + "'>" + body + "</voice></speak>";
    Headers headers = {{"Ocp-Apim-Subscription-Key", aChoice.key},
                       {"Content-Type", "application/ssml+xml"},
                       {"X-Microsoft-OutputFormat", "raw-24khz-16bit-mono-pcm"},
                       {"User-Agent", "APIS-K0"}};
    return {Pcm16(http::Request(url, &ssml, headers, aTimeout)), 24000};
}

Samples Cartesia(const providers::Choice& aChoice, const std::string& aText, const std::string& aLang,
                 const std::string& aVoice, double aSpeed, double aTimeout)
{
    Json body = {{"model_id", aChoice.model},
                 {"transcript", aText},
                 {"voice", {{"id", aVoice}}},
                 {"language", aLang},
                 {"output_format", {{"container", "raw"}, {"encoding", "pcm_s16le"}, {"sample_rate", Rate}}},
                 {"generation_config", {{"speed", std::clamp(aSpeed, 0.6, 1.5)}}}};
    if (aChoice.entry.contains("emotion") && aChoice.entry["emotion"].is_string())
        body["generation_config"]["emotion"] = aChoice.entry["emotion"]; // "neutral": flatter delivery
    auto payload = body.dump(-1, ' ', false, Json::error_handler_t::replace);
    Headers headers = {{"Content-Type", "application/json"},
                       {"Authorization", "Bearer " + aChoice.key},
                       {"X-API-Key", aChoice.key},
                       {"Cartesia-Version", "2026-08-14"}};
    return {Pcm16(http::Request(aChoice.baseUrl + "/tts/bytes", &payload, headers, aTimeout)), Rate};
}

Samples Groq(const providers::Choice& aChoice, const std::string& aText, const std::string&, const std::string& aVoice,
             double, double aTimeout)
{
    Json body = {{"model", aChoice.model}, {"input", aText}, {"voice", aVoice}, {"response_format", "wav"}};
    auto payload = body.dump(-1, ' ', false, Json::error_handler_t::replace);
    Headers headers = {{"Content-Type", "application/json"}, {"Authorization", "Bearer " + aChoice.key}};
    int rate = 0;
    auto samples = ParseWav(http::Request(aChoice.baseUrl + "/audio/speech", &payload, headers, aTimeout), rate);
    return {std::move(samples), rate};
}

Samples OpenAi(const providers::Choice& aChoice, const std::string& aText, const std::string&, const std::string& aVoice,
               double aSpeed, double aTimeout)
{
    Json body = {{"model", aChoice.model}, {"input", aText}, {"voice", aVoice}, {"response_format", "pcm"}, {"speed", aSpeed}};
    if (aChoice.model.rfind("gpt-4o", 0) == 0)
        body["instructions"] = "The light, curious, slightly synthetic voice of a small AI drone.";
    auto payload = body.dump(-1, ' ', false, Json::error_handler_t::replace);
    Headers headers = {{"Content-Type", "application/json"}, {"Authorization", "Bearer " + aChoice.key}};
    return {Pcm16(http::Request(aChoice.baseUrl + "/audio/speech", &payload, headers, aTimeout)), 24000};
}
} // namespace

std::optional<std::vector<float>> LoadWav(const std::filesystem::path& aFile)
{
    auto raw = text::ReadFile(aFile);
    if (!raw || raw->size() <= 44 || raw->compare(0, 4, "RIFF") != 0)
        return std::nullopt;
    int rate = 0;
    auto samples = ParseWav(*raw, rate);
    if (samples.empty())
        return std::nullopt;
    return Resample(std::move(samples), rate);
}

Voice::Voice(providers::Settings& aSettings, std::mutex& aSettingsMutex, const Json& aConfig,
             const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir)
    : settings(aSettings)
    , settingsMutex(aSettingsMutex)
    , config(aConfig)
    , modDir(aModDir)
    , cacheDir(aDataDir / L"speech_cache")
{
}

Voice::~Voice()
{
    Stop();
}

bool Voice::Start()
{
    if (config.value("voice_3d", true))
        pose = std::make_unique<Pose>(modDir / L"audio_pose.txt");
    speaker = std::make_unique<Speaker>(pose.get());
    if (!speaker->Open())
    {
        log::Write("voice disabled: no audio output device");
        speaker.reset();
        pose.reset();
        return false;
    }
    if (config.contains("output_device") && !config["output_device"].is_null())
        log::Write("voice: config output_device is not used by the native bridge yet (default device)");
    player = std::thread([this] { Play(); });
    return true;
}

void Voice::Stop()
{
    {
        std::lock_guard lock(queueMutex);
        stopping = true;
        playlist.clear();
    }
    queueReady.notify_all();
    if (speaker)
        speaker->Cut();
    if (player.joinable())
        player.join();
    speaker.reset();
    pose.reset();
}

std::string Voice::Language(const std::string& aLang) const
{
    auto catalog = settings.Catalog();
    const auto& languages = catalog.contains("languages") && catalog["languages"].is_array() ? catalog["languages"] : Json::array();
    for (const auto& lang : languages)
        if (lang == aLang)
            return aLang;
    return !languages.empty() && languages[0].is_string() ? languages[0].get<std::string>() : std::string("en");
}

std::optional<std::string> Voice::Unavailable(const std::string& aLang) const
{
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("tts");
    }
    if (choice.id == "piper" || choice.id == "kokoro")
        return choice.label + " is a local voice: the native bridge has none yet (phase 5)";
    if (choice.id != "azure" && choice.id != "cartesia" && choice.id != "groq" && choice.id != "openai")
        return choice.label + " is not supported by the native bridge";
    if (choice.entry.contains("only_langs") && choice.entry["only_langs"].is_array())
    {
        const auto& only = choice.entry["only_langs"];
        if (std::find(only.begin(), only.end(), Json(aLang)) == only.end())
            return choice.label + " does not speak " + aLang + " (local voices come in phase 5)";
    }
    if (auto problem = providers::Missing(choice))
        return *problem;
    return std::nullopt;
}

std::string Voice::VoiceName(const std::string& aEngine, const std::string& aLang) const
{
    // Apiko's voice is ours to pick, not the player's: one fixed voice per provider and language.
    auto catalog = settings.Catalog();
    auto voices = catalog["tts"]["providers"].value(aEngine, Json::object()).value("voices", Json::object());
    std::string name;
    if (voices.contains(aLang) && voices[aLang].is_string())
        name = voices[aLang].get<std::string>();
    else if (catalog["languages"].is_array() && !catalog["languages"].empty() && catalog["languages"][0].is_string())
    {
        auto first = catalog["languages"][0].get<std::string>();
        if (voices.contains(first) && voices[first].is_string())
            name = voices[first].get<std::string>();
    }
    return text::Trim(name);
}

double Voice::Speed(const std::string& aEngine) const
{
    // Speaking rate: the provider's own in the catalog (part of Apiko's voice), else config.json's.
    auto catalog = settings.Catalog();
    auto entry = catalog["tts"]["providers"].value(aEngine, Json::object());
    return entry.contains("speed") && entry["speed"].is_number() ? entry["speed"].get<double>()
                                                                   : config.value("voice_speed", 1.0);
}

std::vector<float> Voice::Synthesize(const std::string& aText, const std::string& aLang)
{
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("tts");
    }
    if (auto problem = Unavailable(aLang))
        throw std::runtime_error(*problem);
    auto voiceName = VoiceName(choice.id, aLang);
    double speed = Speed(choice.id);
    double timeout = config.value("tts_timeout_seconds", 8.0);
    Samples rendered;
    if (choice.id == "azure")
        rendered = Azure(choice, aText, aLang, voiceName, speed, timeout);
    else if (choice.id == "cartesia")
        rendered = Cartesia(choice, aText, aLang, voiceName, speed, timeout);
    else if (choice.id == "groq")
        rendered = Groq(choice, aText, aLang, voiceName, speed, timeout);
    else
        rendered = OpenAi(choice, aText, aLang, voiceName, speed, timeout);
    return Resample(std::move(rendered.audio), rendered.rate);
}

Json Voice::StyleJson() const
{
    // The catalog's tts.style with the chosen provider's own overrides.
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("tts");
    }
    auto catalog = settings.Catalog();
    Json style = catalog["tts"].value("style", Json::object());
    auto own = catalog["tts"]["providers"].value(choice.id, Json::object()).value("style", Json::object());
    if (!style.is_object())
        style = Json::object();
    if (own.is_object())
        style.update(own);
    return style;
}

dsp::Style Voice::MachineStyle() const
{
    auto style = StyleJson();
    dsp::Style out;
    out.keep = style.value("keep", out.keep);
    out.semitones = style.value("semitones", out.semitones);
    out.steps = style.value("steps", out.steps);
    out.removeBreaths = style.value("remove_breaths", out.removeBreaths);
    out.level = style.value("level", out.level);
    out.octaveMix = style.value("octave_mix", out.octaveMix);
    return out;
}

std::vector<float> Voice::CachedSpeech(const std::string& aText, const std::string& aLang)
{
    // The same key as the Python bridge (sha1 of json.dumps([engine, voice, style, speed, lang, text],
    // sort_keys=True)), so the lines it already rendered are reused.
    providers::Choice choice;
    {
        std::lock_guard lock(settingsMutex);
        choice = settings.Pick("tts");
    }
    auto key = PyJson(Json::array({choice.id, VoiceName(choice.id, aLang), StyleJson(), Speed(choice.id), aLang, aText}));
    auto hash = Sha1Hex(key);
    auto file = cacheDir / text::Widen(hash + ".npy");
    if (auto cached = LoadNpy(file))
    {
        log::Write("speech cache: " + hash.substr(0, 8) + " reused");
        return *cached;
    }
    log::Write("speech cache: " + hash.substr(0, 8) + " new");
    auto speech = dsp::MachineVoice(Synthesize(aText, aLang), Rate, MachineStyle());
    std::error_code error;
    std::filesystem::create_directories(cacheDir, error);
    if (!SaveNpy(file, speech))
        log::Write("speech cache: could not write " + text::PathString(file));
    return speech;
}

std::vector<float> Voice::Render(const std::string& aText, const std::string& aLang, double aInstability, bool aCache,
                                 bool aPhone)
{
    // Each piece of speech gets the machine voice; each glitch token becomes a glitch sound; then the effects.
    auto lang = Language(aLang);
    auto style = MachineStyle();
    std::vector<float> audio;
    std::optional<std::vector<float>> previous;
    const auto& token = GlitchToken();
    std::sregex_token_iterator it(aText.begin(), aText.end(), token, {-1, 0}), end;
    for (; it != end; ++it)
    {
        auto piece = text::Trim(it->str());
        if (piece.empty())
            continue;
        if (std::regex_match(piece, token))
        {
            auto glitch = dsp::GlitchSound(previous ? &*previous : nullptr, Rate, aInstability, random);
            audio.insert(audio.end(), glitch.begin(), glitch.end());
            continue;
        }
        if (!HasWord(piece))
            continue;
        // Speech only: glitch sounds are added afterwards and must not be flattened or gated.
        auto machine = aCache ? CachedSpeech(piece, lang) : dsp::MachineVoice(Synthesize(piece, lang), Rate, style);
        auto speech = dsp::RandomGlitches(std::move(machine), Rate, aInstability, random);
        audio.insert(audio.end(), speech.begin(), speech.end());
        previous = std::move(speech);
    }
    if (audio.empty())
        audio.assign(Rate / 5, 0.0f);
    double volume = config.value("voice_volume", 0.8);
    auto out = dsp::Effects(audio, Rate, aInstability, volume);
    return aPhone ? dsp::PhoneLine(out, Rate, volume) : out;
}

int Voice::NewReply()
{
    int id = ++generation;
    if (speaker)
        speaker->Cut();
    return id;
}

void Voice::Queue(int aGeneration, std::vector<float> aAudio, std::function<void()> aOnStart)
{
    {
        std::lock_guard lock(queueMutex);
        playlist.push_back({aGeneration, std::move(aAudio), std::move(aOnStart)});
    }
    queueReady.notify_one();
}

void Voice::Play()
{
    for (;;)
    {
        Chunk chunk;
        {
            std::unique_lock lock(queueMutex);
            queueReady.wait(lock, [this] { return stopping || !playlist.empty(); });
            if (stopping)
                return;
            chunk = std::move(playlist.front());
            playlist.pop_front();
        }
        if (chunk.generation != generation.load())
            continue;
        try
        {
            if (chunk.onStart)
                chunk.onStart();
            speaker->Play(chunk.audio);
        }
        catch (const std::exception& e)
        {
            log::Write(std::string("playback failed: ") + e.what());
        }
    }
}
} // namespace apiko::voice
