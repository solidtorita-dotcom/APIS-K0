// The services the player picked in the in-game APIKO Settings window: port of bridge\apiko_providers.py.
// providers.json (catalog, in the CET mod folder) lists the providers for the reply model ("llm"), speech recognition
// ("stt") and voice ("tts"). settings.json (same folder, written by the settings window) holds the player's choices
// and API keys; it is reloaded when it changes. See apiko_providers.py for the format.
#pragma once

#include "Http.hpp"

#include <nlohmann/json.hpp>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace apiko::providers
{
using Json = nlohmann::json;
using Error = http::Error;

// One provider and model for llm / stt / tts, resolved against the catalog.
struct Choice
{
    std::string kind;
    std::string id;
    std::string label;
    Json entry;  // the catalog entry of the provider
    Json preset; // the catalog entry of the model, or {}
    std::string model;
    std::string baseUrl;
    std::string keyName;
    std::string key;
    bool think = false; // reply models: the player lets them think before answering
};

class Settings
{
public:
    explicit Settings(std::filesystem::path aModDir);

    // Reloads when either file changed; true if it did. A half-written file is retried on the next check. The
    // first call loads them; it throws when providers.json is missing or broken.
    bool Check(const std::function<void(const std::string&)>& aLog);

    Choice Pick(const std::string& aKind, const std::string& aProvider = {}) const;
    // Reply models to try in order: the player's choice, then (unless turned off) the catalog's fallback order,
    // skipping repeats and models that cannot be used.
    std::vector<Choice> LlmChain() const;
    std::string Describe() const;
    // A value from settings.json, e.g. Value("llm", "improvise"); null when missing.
    Json Value(const std::string& aSection, const std::string& aKey) const;
    // A copy of providers.json (voices, styles, languages...).
    Json Catalog() const;

private:
    void Reload();
    std::optional<std::pair<std::int64_t, std::int64_t>> Stamp() const;

    std::filesystem::path settingsPath;
    std::filesystem::path catalogPath;
    mutable std::mutex mutex;
    Json catalog;
    Json data;
    std::optional<std::pair<std::int64_t, std::int64_t>> stamp;
    std::string lastError;
    bool loaded = false;
};

// Why this choice cannot be used yet, or nothing.
std::optional<std::string> Missing(const Choice& aChoice);
// Short, readable cause of a failed call (for the in-game notice).
std::string Reason(const Error& aError);

struct ChatResult
{
    std::string text;
    Json usage;
};

// Any OpenAI-compatible chat endpoint. aMessages: [{"role", "content", optional "cache": true at the end of a prefix
// that repeats next turn}]. Optional fields a provider rejects (HTTP 400) are dropped and the call retried.
// aThink false keeps the catalog's lowest reasoning even when the player turned thinking on (background calls).
ChatResult Chat(const Choice& aChoice, const Json& aMessages, bool aJsonMode, int aMaxTokens, double aTimeout,
                bool aThink = true);

// Two-letter codes by English language name ("spanish" -> "es"), as in apiko_providers.LANGUAGE_NAMES.
const std::vector<std::pair<std::string, std::string>>& LanguageNames();
} // namespace apiko::providers
