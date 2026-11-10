#include "Barks.hpp"

#include "Log.hpp"
#include "Text.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <set>

namespace apiko::barks
{
namespace
{
// Diary action (from the game's world events) -> situation in barks.json: the same names.
const std::set<std::string> DeviceSituations = {"spotted", "hostile", "alarm", "breached", "pinged", "destroyed", "hacked"};
const std::set<std::string> Warnings = {"warn_netrunner", "warn_sniper", "warn_behind", "warn_elite",
                                        // V's wanted level rose: urgent like the others, but it goes to the diary too.
                                        "heat_up",
                                        // A camera or turret started tracking V: urgent too (user, 2026-11-09).
                                        "spotted"};
const std::set<std::string> EnemySituations = {"detected", "stealth_kill", "knockout"};
// V entered a restricted or hostile security area, or a fight between others started close by: always written.
const std::set<std::string> WrittenOnly = {"zone_restricted", "zone_dangerous", "fight_close"};
// Everything that needs no talk with V and no concrete information is a written line; the model only improvises
// one now and then (the player's "improvise" setting).
const std::map<std::string, double> ChatSituations = {
    {"combat_start", 0.5}, {"combat_end", 0.6}, {"nightfall", 0.4}, {"dawn", 0.4}, {"low_health", 0.8},
    // A new district (V gets there on foot or gets out of the car in it): almost always worth a line.
    {"entered_district", 0.9}};
// District lines: the most specific district with lines of its own wins (Dogtown and Kabuki before Pacifica and
// Watson); "district" is the generic fallback. Keys are the game's untranslated district names, lowercased.
const std::set<std::string> DistrictLines = {"watson",   "kabuki",       "westbrook", "japantown", "citycenter",
                                             "heywood",  "santodomingo", "pacifica",  "dogtown",   "badlands"};

std::vector<std::string> SplitBar(const std::string& aText, std::size_t aParts)
{
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (parts.size() + 1 < aParts)
    {
        auto at = aText.find('|', start);
        if (at == std::string::npos)
            break;
        parts.push_back(aText.substr(start, at - start));
        start = at + 1;
    }
    parts.push_back(aText.substr(start));
    parts.resize(aParts);
    return parts;
}
} // namespace

std::string SituationFor(const std::string& aEvent)
{
    // Python's partition twice: action | kind | detail (the detail keeps any further "|").
    auto parts = SplitBar(aEvent, 3);
    const auto& action = parts[0];
    const auto& kind = parts[1];
    const auto& detail = parts[2];
    if (DeviceSituations.count(action))
        return action;
    if (Warnings.count(action) || action == "detected")
        return action;
    // What V did: a police officer killed (before the stealth check), a civilian killed, a boss down, the police
    // shaken off, a body hidden.
    if (action == "killed" && kind == "NCPD")
        return "police_killed";
    if (action == "civilian" && kind == "killed")
        return "civilian_killed";
    if (action == "boss_down" || action == "heat_lost" || action == "body_hidden" || action == "sms")
        return action;
    // Missions: a cold judgment, never the quest's name.
    if (action == "quest" && (detail == "completed" || detail == "failed"))
        return detail == "completed" ? "quest_done" : "quest_failed";
    if (action == "killed" && detail == "stealth")
        return "stealth_kill";
    if (action == "knocked_out")
        return "knockout";
    if (action == "heat")
        return "heat_up";
    if (action == "fight")
        // Only a fight starting close by gets a line; one farther away only goes to the diary.
        return detail == "close" ? "fight_close" : "";
    if (action == "zone")
        return kind == "restricted" || kind == "dangerous" ? "zone_" + kind : "";
    return {};
}

std::string Tier(double aInstability)
{
    if (aInstability < 0.3)
        return "calm";
    return aInstability <= 0.6 ? "cracked" : "unhinged";
}

bool IsWarning(const std::string& aSituation)
{
    return Warnings.count(aSituation) > 0;
}

bool IsEnemySituation(const std::string& aSituation)
{
    return EnemySituations.count(aSituation) > 0;
}

bool IsDeviceSituation(const std::string& aSituation)
{
    return DeviceSituations.count(aSituation) > 0;
}

bool IsWrittenOnly(const std::string& aSituation)
{
    return WrittenOnly.count(aSituation) > 0;
}

std::optional<double> ChatChance(const std::string& aEvent)
{
    auto it = ChatSituations.find(aEvent);
    return it == ChatSituations.end() ? std::nullopt : std::optional<double>(it->second);
}

bool IsUrgentChat(const std::string& aEvent)
{
    return aEvent == "low_health";
}

void Barks::Load(const std::filesystem::path& aFile)
{
    lines.clear();
    decks.clear();
    nlohmann::ordered_json data;
    if (auto content = text::ReadFile(aFile))
        data = nlohmann::ordered_json::parse(*content, nullptr, false);
    if (!data.is_object())
    {
        log::Write("barks.json not loaded, no written lines: " + text::PathString(aFile));
        return;
    }
    for (const auto& [situation, tiers] : data.items())
    {
        if (situation.rfind('_', 0) == 0 || !tiers.is_object())
            continue;
        auto& byTier = lines[situation];
        for (const auto& [tier, languages] : tiers.items())
        {
            if (!languages.is_object())
                continue;
            auto& byLang = byTier[tier];
            for (const auto& [lang, texts] : languages.items())
            {
                std::vector<std::string> list;
                if (texts.is_array())
                    for (const auto& line : texts)
                        if (line.is_string())
                            list.push_back(line.get<std::string>());
                if (!list.empty())
                    byLang.emplace_back(lang, std::move(list));
            }
        }
    }
    log::Write("barks: " + std::to_string(lines.size()) + " situations");
}

bool Barks::Has(const std::string& aSituation) const
{
    return lines.count(aSituation) > 0;
}

std::string Barks::DistrictSituation(const std::string& aKeys) const
{
    std::size_t start = 0;
    for (;;)
    {
        auto end = aKeys.find(',', start);
        auto key = text::Lower(text::Trim(aKeys.substr(start, end == std::string::npos ? std::string::npos : end - start)));
        if (DistrictLines.count(key) && Has("district_" + key))
            return "district_" + key;
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
    return Has("district") ? "district" : "";
}

std::optional<std::pair<std::string, std::string>> Barks::Pick(const std::string& aSituation, double aInstability,
                                                               const std::string& aLang, const std::string& aFallbackLang)
{
    auto level = Tier(aInstability);
    auto situation = lines.find(aSituation);
    if (situation == lines.end())
        return std::nullopt;
    // "any": the same lines at every instability (the missions' lines, which lose their context otherwise; the
    // user's call, 2026-11-10).
    if (situation->second.count("any"))
        level = "any";
    auto tier = situation->second.find(level);
    if (tier == situation->second.end() || tier->second.empty())
        return std::nullopt;
    const auto& byLang = tier->second;
    auto find = [&](const std::string& aCode) {
        return std::find_if(byLang.begin(), byLang.end(), [&](const auto& l) { return l.first == aCode; });
    };
    auto chosen = find(aLang);
    if (chosen == byLang.end())
        chosen = find(aFallbackLang);
    if (chosen == byLang.end())
        chosen = find("en");
    if (chosen == byLang.end())
        chosen = byLang.begin();
    auto& deck = decks[{aSituation, level, chosen->first}];
    if (deck.empty())
    {
        deck = chosen->second;
        std::shuffle(deck.begin(), deck.end(), random);
    }
    auto line = deck.back();
    deck.pop_back();
    return std::make_pair(line, chosen->first);
}
} // namespace apiko::barks
