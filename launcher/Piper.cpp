#include "Piper.hpp"

#include "Http.hpp"
#include "Log.hpp"
#include "Text.hpp"

#include <Windows.h>

#define LIBESPEAK_NG_EXPORT 1 // espeak-ng is linked in statically (see build_deps.bat)
#include <espeak-ng/speak_lib.h>
#include <onnxruntime_c_api.h>

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <regex>
#include <set>
#include <stdexcept>

#pragma comment(lib, "Normaliz.lib")

namespace apiko::piper
{
using Json = nlohmann::json;

namespace
{
// espeak-ng's clause terminators (translate.h): what kind of punctuation ended a clause.
constexpr int ClauseIntonationFullStop = 0x00000000;
constexpr int ClauseIntonationComma = 0x00001000;
constexpr int ClauseIntonationQuestion = 0x00002000;
constexpr int ClauseIntonationExclamation = 0x00003000;
constexpr int ClauseTypeClause = 0x00040000;
constexpr int ClauseTypeSentence = 0x00080000;
constexpr int ClausePeriod = 40 | ClauseIntonationFullStop | ClauseTypeSentence;
constexpr int ClauseComma = 20 | ClauseIntonationComma | ClauseTypeClause;
constexpr int ClauseQuestion = 40 | ClauseIntonationQuestion | ClauseTypeSentence;
constexpr int ClauseExclamation = 45 | ClauseIntonationExclamation | ClauseTypeSentence;
constexpr int ClauseColon = 30 | ClauseIntonationFullStop | ClauseTypeClause;
constexpr int ClauseSemicolon = 30 | ClauseIntonationComma | ClauseTypeClause;

constexpr const char* VoicesUrl = "https://huggingface.co/rhasspy/piper-voices/resolve/main/";

std::u32string Utf32(const std::string& aText)
{
    std::u32string out;
    for (std::size_t i = 0; i < aText.size();)
    {
        auto c = static_cast<unsigned char>(aText[i]);
        int extra = c < 0x80 ? 0 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
        char32_t code = extra == 0 ? c : extra == 1 ? c & 0x1F : extra == 2 ? c & 0x0F : c & 0x07;
        for (int k = 1; k <= extra && i + k < aText.size(); ++k)
            code = (code << 6) | (static_cast<unsigned char>(aText[i + k]) & 0x3F);
        out += code;
        i += 1 + extra;
    }
    return out;
}

// Unicode NFD of UTF-8 text, as code points (accents become their own "phonemes", as in piper).
std::u32string Decomposed(const std::string& aText)
{
    auto wide = text::Widen(aText);
    if (wide.empty())
        return {};
    int size = NormalizeString(NormalizationD, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0);
    std::wstring nfd(size > 0 ? size : 0, L'\0');
    if (size > 0)
    {
        size = NormalizeString(NormalizationD, wide.c_str(), static_cast<int>(wide.size()), nfd.data(), size);
        nfd.resize(size > 0 ? size : 0);
    }
    if (nfd.empty())
        nfd = wide;
    std::u32string out;
    for (std::size_t i = 0; i < nfd.size(); ++i)
    {
        char32_t c = nfd[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < nfd.size())
            c = 0x10000 + ((c - 0xD800) << 10) + (nfd[++i] - 0xDC00);
        out += c;
    }
    return out;
}

void Check(const OrtApi* aApi, OrtStatus* aStatus)
{
    if (!aStatus)
        return;
    std::string message = aApi->GetErrorMessage(aStatus);
    aApi->ReleaseStatus(aStatus);
    throw std::runtime_error("onnxruntime: " + message);
}
} // namespace

// onnxruntime.dll, loaded on first use.
struct Piper::Runtime
{
    HMODULE module = nullptr;
    const OrtApi* api = nullptr;
    OrtEnv* env = nullptr;
    OrtMemoryInfo* memory = nullptr;

    explicit Runtime(const std::filesystem::path& aDll)
    {
        // A full path: never Windows' own System32\onnxruntime.dll.
        module = LoadLibraryExW(aDll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module)
            throw std::runtime_error("cannot load " + text::PathString(aDll));
        using GetApiBase = const OrtApiBase*(ORT_API_CALL*)();
        auto getBase = reinterpret_cast<GetApiBase>(GetProcAddress(module, "OrtGetApiBase"));
        if (!getBase || !(api = getBase()->GetApi(ORT_API_VERSION)))
            throw std::runtime_error("onnxruntime.dll does not offer API version " + std::to_string(ORT_API_VERSION));
        Check(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "apiko", &env));
        Check(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
    }

    ~Runtime()
    {
        if (api)
        {
            if (memory)
                api->ReleaseMemoryInfo(memory);
            if (env)
                api->ReleaseEnv(env);
        }
        // The module stays loaded: unloading onnxruntime while the game runs gains nothing.
    }
};

// One voice: its model session and its config.
struct Piper::Model
{
    const OrtApi* api = nullptr;
    OrtSession* session = nullptr;
    std::string outputName;
    int sampleRate = 22050;
    std::string espeakVoice = "en-us";
    int numSpeakers = 1;
    float noiseScale = 0.667f;
    float lengthScale = 1.0f;
    float noiseW = 0.8f;
    std::map<std::u32string, std::vector<std::int64_t>> ids;
    std::set<std::u32string> vowelClusters;
    std::size_t longestCluster = 0;

    ~Model()
    {
        if (api && session)
            api->ReleaseSession(session);
    }
};

Piper::Piper(std::filesystem::path aRuntime, std::filesystem::path aEspeakData, std::filesystem::path aModels)
    : runtimePath(std::move(aRuntime))
    , espeakData(std::move(aEspeakData))
    , models(std::move(aModels))
{
}

Piper::~Piper()
{
    loaded.clear();
    if (espeakReady)
        espeak_Terminate();
}

std::optional<std::string> Piper::Missing() const
{
    std::error_code error;
    if (!std::filesystem::exists(runtimePath, error))
        return "Piper needs " + text::PathString(runtimePath) + " (reinstall the mod)";
    if (!std::filesystem::exists(espeakData / L"phontab", error))
        return "Piper needs " + text::PathString(espeakData) + " (reinstall the mod)";
    return std::nullopt;
}

std::filesystem::path Piper::Download(const std::string& aName, const std::string& aSuffix)
{
    auto file = models / text::Widen(aName + aSuffix);
    std::error_code error;
    if (std::filesystem::exists(file, error))
        return file;
    // "es_ES-sharvard-medium" -> es/es_ES/sharvard/medium/es_ES-sharvard-medium.onnx
    auto first = aName.find('-');
    auto last = aName.rfind('-');
    if (first == std::string::npos || last == first)
        throw std::runtime_error("bad Piper voice name: " + aName);
    auto region = aName.substr(0, first);
    auto url = std::string(VoicesUrl) + region.substr(0, region.find('_')) + "/" + region + "/" +
               aName.substr(first + 1, last - first - 1) + "/" + aName.substr(last + 1) + "/" + aName + aSuffix;
    log::Write("downloading Piper voice " + aName + aSuffix + " (first use, only once)...");
    http::Download(url, file, 120.0);
    return file;
}

Piper::Model& Piper::Load(const std::string& aName)
{
    if (auto it = loaded.find(aName); it != loaded.end())
        return *it->second;
    if (!runtime)
        runtime = std::make_unique<Runtime>(runtimePath);
    auto onnx = Download(aName, ".onnx");
    auto configText = text::ReadFile(Download(aName, ".onnx.json"));
    auto config = configText ? Json::parse(*configText, nullptr, false) : Json();
    if (!config.is_object())
        throw std::runtime_error("bad Piper voice config: " + aName);

    auto model = std::make_unique<Model>();
    model->api = runtime->api;
    model->sampleRate = config["audio"].value("sample_rate", 22050);
    model->espeakVoice = config["espeak"].value("voice", std::string("en-us"));
    model->numSpeakers = config.value("num_speakers", 1);
    model->noiseScale = config["inference"].value("noise_scale", 0.667f);
    model->lengthScale = config["inference"].value("length_scale", 1.0f);
    model->noiseW = config["inference"].value("noise_w", 0.8f);
    for (const auto& [phoneme, list] : config["phoneme_id_map"].items())
    {
        auto& ids = model->ids[Utf32(phoneme)];
        for (const auto& id : list)
            ids.push_back(id.get<std::int64_t>());
    }
    if (config.contains("vowel_clusters") && config["vowel_clusters"].is_array())
        for (const auto& cluster : config["vowel_clusters"])
        {
            std::u32string joined;
            for (const auto& part : cluster)
                joined += Utf32(part.get<std::string>());
            model->vowelClusters.insert(joined);
            model->longestCluster = std::max(model->longestCluster, static_cast<std::size_t>(cluster.size()));
        }

    const auto* api = runtime->api;
    OrtSessionOptions* options = nullptr;
    Check(api, api->CreateSessionOptions(&options));
    // Two threads: the game needs the rest of the CPU.
    api->SetIntraOpNumThreads(options, 2);
    api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL);
    auto status = api->CreateSession(runtime->env, onnx.c_str(), options, &model->session);
    api->ReleaseSessionOptions(options);
    Check(api, status);
    OrtAllocator* allocator = nullptr;
    Check(api, api->GetAllocatorWithDefaultOptions(&allocator));
    char* name = nullptr;
    Check(api, api->SessionGetOutputName(model->session, 0, allocator, &name));
    model->outputName = name;
    allocator->Free(allocator, name);
    log::Write("Piper voice " + aName + " ready");
    return *loaded.emplace(aName, std::move(model)).first->second;
}

std::vector<std::vector<std::u32string>> Piper::Phonemize(const std::string& aText, const std::string& aEspeakVoice)
{
    if (!espeakReady)
    {
        auto path = text::PathString(espeakData);
        if (espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, path.c_str(), 0) < 0)
            throw std::runtime_error("espeak-ng could not start with " + path);
        espeakReady = true;
    }
    if (espeak_SetVoiceByName(aEspeakVoice.c_str()) != EE_OK)
        throw std::runtime_error("espeak-ng has no voice " + aEspeakVoice);

    static const std::regex languageSwitch(R"(\([^)]+\))"); // "(en)...(es)" around foreign words
    std::vector<std::vector<std::u32string>> sentences;
    std::vector<std::u32string> sentence;
    const void* cursor = aText.c_str();
    while (cursor)
    {
        int terminator = 0;
        const char* clause = espeak_TextToPhonemesWithTerminator(&cursor, espeakCHARS_AUTO, espeakPHONEMES_IPA, &terminator);
        std::string phonemes = clause ? std::regex_replace(clause, languageSwitch, "") : std::string();
        // Keep punctuation even though it's not technically a phoneme.
        int punctuation = terminator & 0x000FFFFF;
        if (punctuation == ClausePeriod)
            phonemes += ".";
        else if (punctuation == ClauseQuestion)
            phonemes += "?";
        else if (punctuation == ClauseExclamation)
            phonemes += "!";
        else if (punctuation == ClauseComma)
            phonemes += ", ";
        else if (punctuation == ClauseColon)
            phonemes += ": ";
        else if (punctuation == ClauseSemicolon)
            phonemes += "; ";
        for (char32_t c : Decomposed(phonemes))
            sentence.push_back(std::u32string(1, c));
        if ((terminator & ClauseTypeSentence) == ClauseTypeSentence)
        {
            sentences.push_back(std::move(sentence));
            sentence.clear();
        }
    }
    if (!sentence.empty())
        sentences.push_back(std::move(sentence));
    return sentences;
}

std::string Piper::PhonemeText(const std::string& aText, const std::string& aEspeakVoice)
{
    std::string out;
    for (const auto& sentence : Phonemize(aText, aEspeakVoice))
    {
        std::wstring line;
        for (const auto& phoneme : sentence)
            for (char32_t c : phoneme)
                line += static_cast<wchar_t>(c); // IPA is all in the BMP
        out += text::Narrow(line) + "\n";
    }
    return out;
}

std::vector<float> Piper::Synthesize(const std::string& aText, const std::string& aVoice, double aSpeed, int& aRate)
{
    if (auto problem = Missing())
        throw std::runtime_error(*problem);
    auto hash = aVoice.find('#');
    auto name = aVoice.substr(0, hash);
    std::optional<std::int64_t> speaker;
    if (hash != std::string::npos)
        speaker = std::stoll(aVoice.substr(hash + 1));
    auto& model = Load(name);
    aRate = model.sampleRate;
    if (model.numSpeakers <= 1)
        speaker.reset();
    else if (!speaker)
        speaker = 0;
    const auto* api = runtime->api;

    std::vector<float> audio;
    for (auto& phonemes : Phonemize(aText, model.espeakVoice))
    {
        if (phonemes.empty())
            continue;
        // Known vowel clusters become one phoneme.
        if (!model.vowelClusters.empty())
        {
            std::vector<std::u32string> merged;
            for (std::size_t i = 0; i < phonemes.size();)
            {
                std::size_t taken = 1;
                for (auto n = std::min(model.longestCluster, phonemes.size() - i); n > 1; --n)
                {
                    std::u32string candidate;
                    for (std::size_t k = 0; k < n; ++k)
                        candidate += phonemes[i + k];
                    if (model.vowelClusters.count(candidate))
                    {
                        merged.push_back(candidate);
                        taken = n;
                        break;
                    }
                }
                if (taken == 1)
                    merged.push_back(phonemes[i]);
                i += taken;
            }
            phonemes = std::move(merged);
        }
        // ^ _ phoneme _ phoneme _ ... $ (phonemes missing from the map are skipped).
        std::vector<std::int64_t> ids;
        auto add = [&](const std::u32string& aPhoneme) {
            auto it = model.ids.find(aPhoneme);
            if (it == model.ids.end())
                return false;
            ids.insert(ids.end(), it->second.begin(), it->second.end());
            return true;
        };
        add(U"^");
        add(U"_");
        for (const auto& phoneme : phonemes)
            if (add(phoneme))
                add(U"_");
        add(U"$");

        std::int64_t idsShape[] = {1, static_cast<std::int64_t>(ids.size())};
        std::int64_t lengths[] = {static_cast<std::int64_t>(ids.size())};
        std::int64_t one[] = {1};
        std::int64_t three[] = {3};
        // As the Python bridge asks piper: length_scale = 1 / speed (instead of the voice's own).
        float scales[] = {model.noiseScale, static_cast<float>(1.0 / aSpeed), model.noiseW};
        std::int64_t sid[] = {speaker.value_or(0)};
        std::vector<OrtValue*> inputs(speaker ? 4 : 3, nullptr);
        OrtValue* output = nullptr;
        auto release = [&] {
            for (auto* value : inputs)
                if (value)
                    api->ReleaseValue(value);
            if (output)
                api->ReleaseValue(output);
        };
        try
        {
            Check(api, api->CreateTensorWithDataAsOrtValue(runtime->memory, ids.data(), ids.size() * sizeof(std::int64_t),
                                                           idsShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[0]));
            Check(api, api->CreateTensorWithDataAsOrtValue(runtime->memory, lengths, sizeof(lengths), one, 1,
                                                           ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[1]));
            Check(api, api->CreateTensorWithDataAsOrtValue(runtime->memory, scales, sizeof(scales), three, 1,
                                                           ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputs[2]));
            if (speaker)
                Check(api, api->CreateTensorWithDataAsOrtValue(runtime->memory, sid, sizeof(sid), one, 1,
                                                               ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[3]));
            const char* inputNames[] = {"input", "input_lengths", "scales", "sid"};
            const char* outputNames[] = {model.outputName.c_str()};
            Check(api, api->Run(model.session, nullptr, inputNames, inputs.data(), inputs.size(), outputNames, 1, &output));
            float* data = nullptr;
            Check(api, api->GetTensorMutableData(output, reinterpret_cast<void**>(&data)));
            OrtTensorTypeAndShapeInfo* info = nullptr;
            Check(api, api->GetTensorTypeAndShape(output, &info));
            std::size_t count = 0;
            api->GetTensorShapeElementCount(info, &count);
            api->ReleaseTensorTypeAndShapeInfo(info);
            // Each sentence scaled to the full range (piper's normalize_audio).
            float peak = 0.0f;
            for (std::size_t i = 0; i < count; ++i)
                peak = std::max(peak, std::abs(data[i]));
            float gain = peak < 1e-8f ? 0.0f : 1.0f / peak;
            for (std::size_t i = 0; i < count; ++i)
                audio.push_back(std::clamp(data[i] * gain, -1.0f, 1.0f));
        }
        catch (...)
        {
            release();
            throw;
        }
        release();
    }
    return audio;
}
} // namespace apiko::piper
