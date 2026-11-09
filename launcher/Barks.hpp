// Apiko's written lines (barks.json) for world and chat events, said without asking the model: port of
// bridge\apiko_barks.py. A line is picked by situation, instability tier and V's language, never repeating one until
// all of that situation, tier and language were used.
#pragma once

#include <filesystem>
#include <map>
#include <optional>
#include <random>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace apiko::barks
{
// The barks.json situation for a world event ("action|kind|detail"), or "" (no line for it).
std::string SituationFor(const std::string& aEvent);
// "calm", "cracked" or "unhinged".
std::string Tier(double aInstability);

// Enemy warnings and V's wanted level rising: urgent, their own short pause, never the model.
bool IsWarning(const std::string& aSituation);
// Enemy situations (an improvised one goes to the model as "enemy_<situation>").
bool IsEnemySituation(const std::string& aSituation);
// Device situations (an improvised one goes to the model as "device_<situation>").
bool IsDeviceSituation(const std::string& aSituation);
// Always a written line, never the model.
bool IsWrittenOnly(const std::string& aSituation);
// The game's chat events that became written lines, with their chance (times "chatter"); none for others.
std::optional<double> ChatChance(const std::string& aEvent);
// Chat events that go like a warning (low_health).
bool IsUrgentChat(const std::string& aEvent);

class Barks
{
public:
    // barks.json; without it there are no written lines (logged).
    void Load(const std::filesystem::path& aFile);
    bool Has(const std::string& aSituation) const;
    // The district situation for the state's "district_keys" ("Kabuki,Watson"), most specific first; "" if none.
    std::string DistrictSituation(const std::string& aKeys) const;
    // A line for this situation and its language, or nothing. Unknown languages use aFallbackLang (the default
    // one), else English, else the first the situation has.
    std::optional<std::pair<std::string, std::string>> Pick(const std::string& aSituation, double aInstability,
                                                            const std::string& aLang, const std::string& aFallbackLang);

private:
    using Languages = std::vector<std::pair<std::string, std::vector<std::string>>>; // file order
    std::map<std::string, std::map<std::string, Languages>> lines;                   // situation -> tier -> languages
    std::map<std::tuple<std::string, std::string, std::string>, std::vector<std::string>> decks;
    std::mt19937 random{std::random_device{}()};
};
} // namespace apiko::barks
