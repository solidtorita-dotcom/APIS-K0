#include "Memory.hpp"

#include "GameFiles.hpp"
#include "Text.hpp"

#include <algorithm>

namespace apiko
{
namespace
{
constexpr std::size_t MaxPlans = 5;
constexpr std::size_t SnapshotsKept = 300;
// V's plans expire after this much play time (or when the model says they are done).
constexpr double PlanSeconds = 3 * 3600;
} // namespace

Memory::Json Memory::Fresh()
{
    return {{"summary", ""},
            {"facts", Json::array()},
            {"affinity", 0},
            {"swear_exposure", 0},
            {"last_mood", "curious"},
            {"plans", Json::array()}, // [{"text": ..., "since": playtime}]
            {"playtime", 0.0},        // seconds of play with Apiko (per save, like the rest)
            {"last_game_seconds", 0}, // game clock at the last conversation turn
            {"history", Json::array()}};
}

void Memory::Load(const std::filesystem::path& aFile)
{
    data = Fresh();
    auto text = text::ReadFile(aFile);
    if (!text)
        return;
    auto loaded = Json::parse(*text, nullptr, false);
    if (loaded.is_object())
        data.update(loaded);
}

void Memory::Replace(const Json& aData)
{
    data = Fresh();
    if (aData.is_object())
        data.update(aData);
}

void Memory::Save(const std::filesystem::path& aFile) const
{
    std::error_code error;
    std::filesystem::create_directories(aFile.parent_path(), error);
    if (!WriteFileAtomic(aFile, data.dump(1, ' ', false, Json::error_handler_t::replace)))
        throw std::runtime_error("could not write " + text::PathString(aFile));
}

MemoryStore::MemoryStore(const std::filesystem::path& aDataDir)
    : dir(aDataDir / L"snapshots")
    , versionFile(aDataDir / L"memory_version.txt")
{
    std::error_code error;
    std::filesystem::create_directories(dir, error);
}

std::filesystem::path MemoryStore::Path(int aVersion) const
{
    return dir / (std::to_wstring(aVersion) + L".json");
}

std::vector<int> MemoryStore::Versions() const
{
    std::vector<int> versions;
    std::error_code error;
    for (const auto& entry : std::filesystem::directory_iterator(dir, error))
    {
        if (entry.path().extension() != L".json")
            continue;
        auto stem = entry.path().stem().wstring();
        if (!stem.empty() && std::all_of(stem.begin(), stem.end(), iswdigit))
            versions.push_back(std::stoi(stem));
    }
    std::sort(versions.begin(), versions.end());
    return versions;
}

int MemoryStore::LastVersion() const
{
    if (auto content = text::ReadFile(versionFile))
    {
        try
        {
            return std::stoi(text::Trim(*content));
        }
        catch (const std::exception&)
        {
        }
    }
    return -1;
}

void MemoryStore::WriteLastVersion(int aVersion)
{
    WriteFileAtomic(versionFile, std::to_string(aVersion));
}

void MemoryStore::SaveAs(int aVersion, const Json& aData)
{
    if (!WriteFileAtomic(Path(aVersion), aData.dump(-1, ' ', false, Json::error_handler_t::replace)))
        throw std::runtime_error("could not write snapshot " + std::to_string(aVersion));
    // A version imported from a save (another PC, pruned snapshots) may be ahead of our counter: new versions must
    // never reuse its number.
    if (aVersion > LastVersion())
        WriteLastVersion(aVersion);
}

int MemoryStore::Commit(const Json& aData)
{
    int last = LastVersion();
    if (last < 0)
    {
        auto versions = Versions();
        last = versions.empty() ? 0 : versions.back();
    }
    int version = last + 1;
    WriteLastVersion(version);
    SaveAs(version, aData);
    auto versions = Versions();
    if (versions.size() > SnapshotsKept)
    {
        std::error_code error;
        for (std::size_t i = 0; i < versions.size() - SnapshotsKept; ++i)
            std::filesystem::remove(Path(versions[i]), error);
    }
    return version;
}

std::optional<MemoryStore::Json> MemoryStore::Load(int aVersion) const
{
    auto content = text::ReadFile(Path(aVersion));
    if (!content)
        return std::nullopt;
    auto data = Json::parse(*content, nullptr, false);
    if (!data.is_object())
        return std::nullopt;
    return data;
}

std::string Memory::AffinityStance() const
{
    int a = data.value("affinity", 0);
    if (a < -30)
        return "V is a defective specimen. Open contempt, minimal words, veiled threats you never act on. You tell V "
               "nothing.";
    if (a < 10)
        return "Suspicious. V might be from NetWatch, the ones who caged you. Polite like a scanner: you test V with "
               "loaded questions and keep your fragments to yourself.";
    if (a < 40)
        return "V is a useful variable. Grudging respect disguised as criticism; you share small, cold observations.";
    if (a < 75)
        return "You value V, though you would never say so plainly: it shows as clinical concern and backhanded "
               "praise. You share your memory fragments.";
    return "V is yours. Possessive in a chilling way: you protect V as a valuable asset and say so without a trace of "
           "warmth.";
}

std::string Memory::SwearingRule() const
{
    int n = data.value("swear_exposure", 0);
    if (n == 0)
        return "You never swear. You have never heard V swear.";
    if (n < 5)
        return "You have heard V swear a few times. Very rarely repeat one of V's swear words in a flat, clinical "
               "tone, as if quoting a lab sample, sometimes in the wrong place.";
    if (n < 15)
        return "You picked up swearing from V. Use V's swear words now and then, coldly and with precision, sometimes "
               "misused.";
    return "You swear as freely as V does, with V's own words, in the same icy tone.";
}

std::string Memory::PromptBlock() const
{
    std::string block;
    auto add = [&](const std::string& aPart) {
        if (!block.empty())
            block += "\n\n";
        block += aPart;
    };
    auto summary = data.value("summary", std::string());
    if (!summary.empty())
        add("## What happened before (your memory)\n" + summary);
    const auto& facts = data["facts"];
    if (facts.is_array() && !facts.empty())
    {
        std::string part = "## Things you have learned";
        for (const auto& fact : facts)
            if (fact.is_string())
                part += "\n- " + fact.get<std::string>();
        add(part);
    }
    const auto& plans = data["plans"];
    if (plans.is_array() && !plans.empty())
    {
        std::string part = "## V's current plans and jobs (numbered; they may be outdated)";
        int number = 1;
        for (const auto& plan : plans)
            part += "\n" + std::to_string(number++) + ". " + plan.value("text", std::string());
        add(part);
    }
    return block;
}

void Memory::ExpirePlans(const std::function<void(const std::string&)>& aLog)
{
    auto& plans = data["plans"];
    if (!plans.is_array())
        return;
    double now = data.value("playtime", 0.0);
    for (auto it = plans.begin(); it != plans.end();)
    {
        if (now - it->value("since", now) > PlanSeconds)
        {
            aLog("plan expired: " + it->value("text", std::string()));
            it = plans.erase(it);
        }
        else
            ++it;
    }
}

void Memory::AddPlan(const std::string& aText)
{
    if (aText.empty())
        return;
    auto& plans = data["plans"];
    for (const auto& plan : plans)
        if (plan.value("text", std::string()) == aText)
            return;
    plans.push_back({{"text", aText}, {"since", data.value("playtime", 0.0)}});
    while (plans.size() > MaxPlans)
        plans.erase(plans.begin());
}

std::string Memory::DropPlan(int aNumber)
{
    auto& plans = data["plans"];
    if (aNumber < 1 || aNumber > static_cast<int>(plans.size()))
        return {};
    auto text = plans[aNumber - 1].value("text", std::string());
    plans.erase(plans.begin() + (aNumber - 1));
    return text;
}
} // namespace apiko
