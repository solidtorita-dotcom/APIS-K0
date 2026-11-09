#include "Providers.hpp"

#include "Text.hpp"

#include <chrono>
#include <regex>
#include <set>
#include <thread>

namespace apiko::providers
{
namespace
{
constexpr const char* Kinds[] = {"llm", "stt", "tts"};
constexpr double MaxRetryWait = 6.0;

std::string Str(const Json& aObject, const char* aKey)
{
    if (!aObject.is_object())
        return {};
    auto it = aObject.find(aKey);
    return it != aObject.end() && it->is_string() ? it->get<std::string>() : std::string();
}

const Json& Field(const Json& aObject, const char* aKey)
{
    static const Json empty = Json::object();
    if (!aObject.is_object())
        return empty;
    auto it = aObject.find(aKey);
    return it != aObject.end() ? *it : empty;
}

std::string RealKey(const std::string& aValue)
{
    auto value = text::Trim(aValue);
    return value.empty() || value.find("PUT-YOUR") != std::string::npos ? std::string() : value;
}

std::string RecommendedModel(const Json& aEntry)
{
    const auto& models = Field(aEntry, "models");
    if (!models.is_array() || models.empty())
        return {};
    for (const auto& model : models)
        if (Str(model, "badge") == "Recommended")
            return Str(model, "id");
    return Str(models[0], "id");
}

Json FindPreset(const Json& aEntry, const std::string& aModel)
{
    const auto& models = Field(aEntry, "models");
    if (models.is_array())
        for (const auto& model : models)
            if (Str(model, "id") == aModel)
                return model;
    return Json::object();
}

std::string StripSlash(std::string aUrl)
{
    aUrl = text::Trim(aUrl);
    while (!aUrl.empty() && aUrl.back() == '/')
        aUrl.pop_back();
    return aUrl;
}

std::int64_t WriteTime(const std::filesystem::path& aFile)
{
    return std::filesystem::last_write_time(aFile).time_since_epoch().count();
}

// POST, retried once when the provider says to wait a few seconds (rate limit, HTTP 429).
std::string RequestWithRetry(const std::string& aUrl, const std::string& aBody,
                             const std::map<std::string, std::string>& aHeaders, double aTimeout)
{
    try
    {
        return http::Request(aUrl, &aBody, aHeaders, aTimeout);
    }
    catch (const Error& e)
    {
        static const std::regex retryAfter(R"(try again in ([\d.]+)\s*(ms|s))", std::regex::icase);
        std::smatch match;
        std::string message = e.what();
        if (e.status != 429 || !std::regex_search(message, match, retryAfter))
            throw;
        double wait = std::stod(match[1].str()) / (text::Lower(match[2].str()) == "ms" ? 1000.0 : 1.0);
        if (wait > MaxRetryWait)
            throw;
        std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>((wait + 0.2) * 1000)));
        return http::Request(aUrl, &aBody, aHeaders, aTimeout);
    }
}

// Anthropic models through OpenRouter only cache with cache_control marks; the others cache repeated prefixes by
// themselves.
bool ExplicitCache(const Choice& aChoice)
{
    return aChoice.id == "openrouter" && aChoice.model.rfind("anthropic/", 0) == 0;
}

// "cache": true marks get a cache_control breakpoint with aExplicit, else they are dropped. Consecutive system
// messages are joined into one (some providers reject several), keeping their order.
Json PrepareMessages(const Json& aMessages, bool aExplicit)
{
    Json out = Json::array();
    for (const auto& message : aMessages)
    {
        std::string role = Str(message, "role");
        std::string content = Str(message, "content");
        Json value = content;
        if (aExplicit)
        {
            Json part = {{"type", "text"}, {"text", content}};
            // 1 h instead of the default 5 min: Apiko talks in bursts with long silences.
            if (message.value("cache", false))
                part["cache_control"] = {{"type", "ephemeral"}, {"ttl", "1h"}};
            value = Json::array({part});
        }
        if (role == "system" && !out.empty() && out.back()["role"] == "system")
        {
            auto& last = out.back()["content"];
            if (aExplicit)
                last.insert(last.end(), value.begin(), value.end());
            else
                last = last.get<std::string>() + "\n\n" + content;
            continue;
        }
        out.push_back({{"role", role}, {"content", value}});
    }
    return out;
}
} // namespace

const std::vector<std::pair<std::string, std::string>>& LanguageNames()
{
    static const std::vector<std::pair<std::string, std::string>> names = {
        {"spanish", "es"}, {"english", "en"}, {"french", "fr"},   {"german", "de"},   {"italian", "it"},
        {"portuguese", "pt"}, {"polish", "pl"}, {"russian", "ru"}, {"japanese", "ja"}, {"chinese", "zh"}};
    return names;
}

Settings::Settings(std::filesystem::path aModDir)
    : settingsPath(aModDir / L"settings.json")
    , catalogPath(aModDir / L"providers.json")
{
}

std::optional<std::pair<std::int64_t, std::int64_t>> Settings::Stamp() const
{
    try
    {
        // A missing settings.json (the window never saved) counts as 0: the catalog alone still works.
        std::error_code error;
        auto settingsTime = std::filesystem::exists(settingsPath, error) ? WriteTime(settingsPath) : 0;
        return std::make_pair(settingsTime, WriteTime(catalogPath));
    }
    catch (const std::filesystem::filesystem_error&)
    {
        return std::nullopt;
    }
}

void Settings::Reload()
{
    auto newStamp = Stamp();
    auto catalogText = text::ReadFile(catalogPath);
    if (!catalogText)
        throw std::runtime_error(text::PathString(catalogPath) + " missing: install the mod");
    Json newCatalog = Json::parse(*catalogText);
    Json newData = Json::object();
    std::error_code error;
    if (std::filesystem::exists(settingsPath, error))
    {
        auto settingsText = text::ReadFile(settingsPath);
        if (!settingsText)
            throw std::runtime_error("settings.json could not be read");
        newData = Json::parse(*settingsText);
        if (!newData.is_object())
            throw std::runtime_error("settings.json is not a JSON object");
    }
    for (const char* kind : Kinds)
        if (!newData[kind].is_object())
            newData[kind] = Json::object();
    if (!newData["keys"].is_object())
        newData["keys"] = Json::object();
    std::lock_guard lock(mutex);
    catalog = std::move(newCatalog);
    data = std::move(newData);
    stamp = newStamp;
    loaded = true;
}

bool Settings::Check(const std::function<void(const std::string&)>& aLog)
{
    if (!loaded)
    {
        Reload(); // throws: without a catalog nothing works
        return true;
    }
    auto newStamp = Stamp();
    if (!newStamp || newStamp == stamp)
        return false;
    try
    {
        Reload();
    }
    catch (const std::exception& e)
    {
        if (e.what() != lastError)
        {
            lastError = e.what();
            aLog(std::string("settings.json not reloaded yet: ") + e.what());
        }
        return false;
    }
    lastError.clear();
    return true;
}

Choice Settings::Pick(const std::string& aKind, const std::string& aProvider) const
{
    std::lock_guard lock(mutex);
    const auto& section = Field(catalog, aKind.c_str());
    const auto& mine = Field(data, aKind.c_str());
    const auto& providers = Field(section, "providers");
    std::string pid = aProvider.empty() ? Str(mine, "provider") : aProvider;
    if (!providers.contains(pid))
        pid = Str(section, "default");
    Choice choice;
    choice.kind = aKind;
    choice.id = pid;
    choice.entry = Field(providers, pid.c_str());
    choice.label = Str(choice.entry, "label");
    choice.model = text::Trim(Str(Field(mine, "models"), pid.c_str()));
    if (choice.model.empty())
        choice.model = RecommendedModel(choice.entry);
    choice.baseUrl = StripSlash(Str(Field(mine, "urls"), pid.c_str()));
    if (choice.baseUrl.empty())
        choice.baseUrl = StripSlash(Str(choice.entry, "base_url"));
    choice.keyName = Str(choice.entry, "key");
    if (!choice.keyName.empty())
        choice.key = RealKey(Str(Field(data, "keys"), choice.keyName.c_str()));
    choice.preset = FindPreset(choice.entry, choice.model);
    choice.think = aKind == "llm" && Field(mine, "think") == true;
    return choice;
}

std::vector<Choice> Settings::LlmChain() const
{
    std::vector<Choice> chain{Pick("llm")};
    Json fallbackOrder;
    {
        std::lock_guard lock(mutex);
        if (Field(Field(data, "llm"), "fallback") == false)
            return chain;
        fallbackOrder = Field(Field(catalog, "llm"), "fallback_order");
    }
    std::set<std::pair<std::string, std::string>> seen{{chain[0].id, chain[0].model}};
    if (!fallbackOrder.is_array())
        return chain;
    for (const auto& item : fallbackOrder)
    {
        auto provider = Str(item, "provider");
        auto candidate = Pick("llm", provider);
        if (candidate.id != provider)
            continue; // not in the catalog
        if (!Str(item, "model").empty())
        {
            candidate.model = Str(item, "model");
            candidate.preset = FindPreset(candidate.entry, candidate.model);
        }
        if (seen.count({candidate.id, candidate.model}) || Missing(candidate))
            continue;
        seen.insert({candidate.id, candidate.model});
        chain.push_back(std::move(candidate));
    }
    return chain;
}

std::string Settings::Describe() const
{
    auto llm = Pick("llm");
    auto stt = Pick("stt");
    auto tts = Pick("tts");
    return "model " + llm.label + " (" + (llm.model.empty() ? "none" : llm.model) + (llm.think ? ", thinks" : "") +
           "), speech " + stt.label + ", voice " + tts.label;
}

Json Settings::Value(const std::string& aSection, const std::string& aKey) const
{
    std::lock_guard lock(mutex);
    const auto& section = Field(data, aSection.c_str());
    auto it = section.find(aKey);
    return it != section.end() ? *it : Json();
}

Json Settings::Catalog() const
{
    std::lock_guard lock(mutex);
    return catalog;
}

std::optional<std::string> Missing(const Choice& aChoice)
{
    if (!aChoice.keyName.empty() && aChoice.key.empty())
        return "No API key for " + aChoice.label + ": add it in APIKO Settings (CET overlay).";
    if (aChoice.kind == "llm" && aChoice.model.empty())
        return "No model chosen for " + aChoice.label + ": pick or type one in APIKO Settings.";
    if (Field(aChoice.entry, "url_editable") == true && aChoice.baseUrl.empty())
        return "No URL for " + aChoice.label + ": set it in APIKO Settings.";
    return std::nullopt;
}

std::string Reason(const Error& aError)
{
    switch (aError.status)
    {
    case 401:
    case 403:
        return "invalid key";
    case 402:
        return "no credits";
    case 429:
        return "rate limit";
    default:
        if (aError.status >= 500)
            return "server error";
        return text::Truncate(aError.what(), 80);
    }
}

ChatResult Chat(const Choice& aChoice, const Json& aMessages, bool aJsonMode, int aMaxTokens, double aTimeout,
                bool aThink)
{
    if (auto problem = Missing(aChoice))
        throw Error(*problem);
    const auto& entry = aChoice.entry;
    std::string tokensField = Str(entry, "max_tokens_field");
    if (tokensField.empty())
        tokensField = "max_tokens";
    Json body = {{"model", aChoice.model},
                 {"messages", PrepareMessages(aMessages, ExplicitCache(aChoice))},
                 {tokensField, aMaxTokens}};
    Json optional = Json::object();
    if (aJsonMode)
        optional["response_format"] = {{"type", "json_object"}};
    // The catalog's effort is the least each model allows. Thinking on = the model's own default (no field).
    std::string effort = Str(aChoice.preset, "reasoning_effort");
    if (aThink && aChoice.think)
        effort.clear();
    std::string reasoning = Str(entry, "reasoning");
    if (!effort.empty() && reasoning == "openrouter")
        optional["reasoning"] = {{"effort", effort}};
    else if (!effort.empty() && reasoning == "openai")
        optional["reasoning_effort"] = effort;

    std::map<std::string, std::string> headers = {{"Content-Type", "application/json"}};
    if (!aChoice.key.empty())
        headers["Authorization"] = "Bearer " + aChoice.key;
    if (aChoice.id == "openrouter")
        headers["X-Title"] = "APIS-K0 (Cyberpunk 2077 mod)";
    std::string url = aChoice.baseUrl + "/chat/completions";

    Json full = body;
    full.update(optional);
    std::string raw;
    try
    {
        raw = RequestWithRetry(url, full.dump(-1, ' ', false, Json::error_handler_t::replace), headers, aTimeout);
    }
    catch (const Error& e)
    {
        if (e.status != 400 || (optional.empty() && !ExplicitCache(aChoice)))
            throw;
        // Plain request: no optional fields and no cache marks.
        body["messages"] = PrepareMessages(aMessages, false);
        raw = RequestWithRetry(url, body.dump(-1, ' ', false, Json::error_handler_t::replace), headers, aTimeout);
    }

    Json result = Json::parse(raw, nullptr, false);
    if (result.is_discarded())
        throw Error("bad response: " + http::Snippet(raw));
    if (result.contains("error"))
        throw Error(http::Snippet(result["error"].dump()));
    try
    {
        const auto& message = result.at("choices").at(0).at("message");
        auto content = message.find("content");
        ChatResult out;
        out.text = content != message.end() && content->is_string() ? content->get<std::string>() : "";
        out.usage = result.value("usage", Json::object());
        return out;
    }
    catch (const Json::exception&)
    {
        throw Error("unexpected response: " + http::Snippet(result.dump()));
    }
}
} // namespace apiko::providers
