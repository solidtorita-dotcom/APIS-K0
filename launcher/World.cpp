#include "World.hpp"

#include "Log.hpp"
#include "Text.hpp"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdio>

namespace apiko::world
{
namespace
{
constexpr double DiarySeconds = 600;
constexpr std::size_t DiaryLines = 6; // tokens: the 6 latest are enough context
constexpr int Security = 0;
constexpr double RepeatSeconds = 10;
constexpr double SaidSeconds = 120;
// Hearing: lines further apart than this start a new conversation; the last one is kept, up to SceneLines lines,
// and shown for HeardSeconds (the last SceneLinesShort lines unless V asks about it).
constexpr double SceneGapSeconds = 60;
constexpr std::size_t SceneLines = 12;
constexpr std::size_t SceneLinesShort = 4;
constexpr double HeardSeconds = 600;
constexpr std::size_t NewsLines = 2;
constexpr std::size_t NewsChars = 160;
// Ambient chatter (people talking near V, not to V): the latest ChatterLines, shown for ChatterSeconds and only when
// V asks about what was said. Apiko made up a chat it never got (tried in the game, 2026-11-10).
constexpr std::size_t ChatterLines = 10;
constexpr std::size_t ChatterChars = 160;
constexpr double ChatterSeconds = 240;
// A conversation that never ended (a lost "scene|end") stops silencing Apiko after this long without lines.
constexpr double SceneStuckSeconds = 180;
// An objective change this soon after a conversation means the conversation led to it.
constexpr double LedSeconds = 45;
// A settled conversation (earlier objective) can still be asked about for this long.
constexpr double PastSeconds = 1800;
// Objective marker closer than this: V is at the objective.
constexpr int AtObjectiveMeters = 40;
constexpr std::size_t FocusDescriptionChars = 200;
constexpr std::size_t LoreMax = 3; // entries per turn (tokens)

double Now()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::string Str(const Json& aObject, const char* aKey)
{
    if (!aObject.is_object())
        return {};
    auto it = aObject.find(aKey);
    if (it == aObject.end() || it->is_null())
        return {};
    return it->is_string() ? it->get<std::string>() : it->dump();
}

std::vector<std::string> Split(const std::string& aText, const std::string& aSeparator, int aMaxSplit = -1)
{
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (aMaxSplit < 0 || static_cast<int>(parts.size()) < aMaxSplit)
    {
        auto at = aText.find(aSeparator, start);
        if (at == std::string::npos)
            break;
        parts.push_back(aText.substr(start, at - start));
        start = at + aSeparator.size();
    }
    parts.push_back(aText.substr(start));
    return parts;
}

// Python's str.split(): runs of whitespace, no empty parts.
std::vector<std::string> Words(const std::string& aText)
{
    std::vector<std::string> words;
    std::string word;
    for (char c : aText)
    {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
            if (!word.empty())
                words.push_back(std::move(word));
            word.clear();
        }
        else
            word += c;
    }
    if (!word.empty())
        words.push_back(std::move(word));
    return words;
}

std::string Join(const std::vector<std::string>& aParts, const std::string& aSeparator)
{
    std::string out;
    for (std::size_t i = 0; i < aParts.size(); ++i)
        out += (i ? aSeparator : "") + aParts[i];
    return out;
}

std::string Replace(std::string aText, const std::string& aFrom, const std::string& aTo)
{
    for (std::size_t at = 0; (at = aText.find(aFrom, at)) != std::string::npos; at += aTo.size())
        aText.replace(at, aFrom.size(), aTo);
    return aText;
}

bool StartsWith(const std::string& aText, const std::string& aPrefix)
{
    return aText.rfind(aPrefix, 0) == 0;
}

bool EndsWith(const std::string& aText, const std::string& aSuffix)
{
    return aText.size() >= aSuffix.size() && aText.compare(aText.size() - aSuffix.size(), aSuffix.size(), aSuffix) == 0;
}

bool Contains(const std::vector<std::string>& aList, const std::string& aValue)
{
    return std::find(aList.begin(), aList.end(), aValue) != aList.end();
}

// Python's int(): the whole text must be a number.
std::optional<int> ParseInt(const std::string& aText)
{
    auto text = text::Trim(aText);
    int value = 0;
    auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
    if (text.empty() || error != std::errc() || end != text.data() + text.size())
        return std::nullopt;
    return value;
}

// At most aMax bytes, cut at the last space, with "...".
std::string Shorten(const std::string& aText, std::size_t aMax)
{
    if (aText.size() <= aMax)
        return aText;
    auto cut = text::Truncate(aText, aMax);
    auto space = cut.rfind(' ');
    return (space == std::string::npos ? cut : cut.substr(0, space)) + "...";
}

std::vector<std::string> FindAll(const std::string& aText, const std::regex& aPattern)
{
    std::vector<std::string> found;
    for (auto it = std::sregex_iterator(aText.begin(), aText.end(), aPattern); it != std::sregex_iterator(); ++it)
        found.push_back(it->str());
    return found;
}

// Game names (gamedataAffiliation) that read badly as they come.
std::string FactionName(const std::string& aName)
{
    static const std::map<std::string, std::string> factions = {
        {"TygerClaws", "Tyger Claws"},
        {"SixthStreet", "6th Street"},
        {"SixthStreetAndroid", "6th Street android"},
        {"VoodooBoys", "Voodoo Boys"},
        {"TheMox", "The Mox"},
        {"KangTao", "Kang Tao"},
        {"AfterlifeMercs", "Afterlife mercs"},
        {"MaelstromAndroid", "Maelstrom android"},
        {"ScavengersAndroid", "Scavengers android"},
        {"WraithsAndroid", "Wraiths android"},
        {"Wraiths_Former", "former Wraiths"},
        {"NCPrison", "NC prison"},
        {"TraumaTeam", "Trauma Team"},
        {"CityCouncil", "City Council"},
        {"UnaffiliatedCorpo", "corpo"},
        {"Unaffiliated", "unaffiliated"},
        {"Unknown", "unknown"},
        {"corpbud", "corpo"},
        {"OA", "Arasaka"},
        {"SSI", "SSI"},
        {"NUSA", "NUSA"},
        {"REDACTED", "unknown"},
        {"RecordingAgency", "recording agency"},
        {"SouthCalifornia", "SoCal"},
    };
    auto it = factions.find(aName);
    return it == factions.end() ? aName : it->second;
}

// "Wea_AssaultRifle" -> "assault rifle".
std::string WeaponName(const std::string& aItemType)
{
    static const std::regex parts(R"([A-Z][a-z]+|[A-Z]+(?![a-z])|\d+)");
    auto name = StartsWith(aItemType, "Wea_") ? aItemType.substr(4) : aItemType;
    auto words = FindAll(name, parts);
    for (auto& word : words)
        word = text::Lower(word);
    return words.empty() ? text::Lower(name) : Join(words, " ");
}

// Event kinds come as "<faction> <role>" or "<faction> <threat> <role>": humanize the faction.
std::string EnemyLabel(const std::string& aKind)
{
    auto parts = Split(aKind, " ", 1);
    return text::Trim(FactionName(parts[0]) + (parts.size() > 1 && !parts[1].empty() ? " " + parts[1] : ""));
}

// Game action class names ("QuickHackDistraction", "ToggleON") as plain words ("distraction", "toggle on").
std::string Humanize(std::string aName)
{
    for (const std::string prefix : {"QuickHack", "Action"})
        if (StartsWith(aName, prefix) && aName.size() > prefix.size())
            aName = aName.substr(prefix.size());
    static const std::regex parts(R"([A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+)");
    auto words = FindAll(aName, parts);
    for (auto& word : words)
        word = text::Lower(word);
    return words.empty() ? text::Lower(aName) : Join(words, " ");
}

std::string Plural(const std::string& aKind)
{
    return aKind + (EndsWith(aKind, "x") || EndsWith(aKind, "s") ? "es" : "s");
}

std::string Count(int aCount, const std::string& aKind)
{
    if (aCount == 1)
        return (!aKind.empty() && std::string("aeiou").find(aKind[0]) != std::string::npos ? "an " : "a ") + aKind;
    return std::to_string(aCount) + " " + Plural(aKind);
}

std::string AgeText(double aSeconds)
{
    return aSeconds < 60 ? "just now" : std::to_string(static_cast<int>(aSeconds / 60)) + " min ago";
}

// Counts of each value in first-seen order, then most frequent first (stable, like Python's sorted).
std::vector<std::pair<std::string, int>> Tally(const std::vector<std::string>& aValues)
{
    std::vector<std::pair<std::string, int>> counts;
    for (const auto& value : aValues)
    {
        auto it = std::find_if(counts.begin(), counts.end(), [&](const auto& c) { return c.first == value; });
        if (it == counts.end())
            counts.emplace_back(value, 1);
        else
            ++it->second;
    }
    std::stable_sort(counts.begin(), counts.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    return counts;
}

// --- devices ---

struct Device
{
    std::string id;
    std::string kind;
    int category = 0;
    int meters = 0;
    std::string direction;
    std::vector<std::string> flags;
};

// The game's "devices=" line: "id,kind,category,meters,direction,flags" entries joined by ";".
std::vector<Device> ParseDevices(const std::string& aLine)
{
    std::vector<Device> devices;
    for (const auto& entry : Split(aLine, ";"))
    {
        auto fields = Split(entry, ",");
        if (fields.size() < 6)
            continue;
        auto category = ParseInt(fields[2]);
        auto meters = ParseInt(fields[3]);
        if (!category || !meters)
            continue;
        devices.push_back({fields[0], fields[1], *category, *meters, fields[4], Words(fields[5])});
    }
    return devices;
}

struct Group
{
    int n = 0;
    std::map<std::string, int> states{{"watching-V", 0}, {"hostile", 0}, {"ringing", 0}, {"off", 0}};
    std::set<std::string> levels;
};

// Security devices by kind (first-seen order), with counts of each state and where they are (above/below).
std::vector<std::pair<std::string, Group>> SecurityGroups(const std::vector<const Device*>& aDevices)
{
    std::vector<std::pair<std::string, Group>> groups;
    for (const auto* d : aDevices)
    {
        if (d->category != Security)
            continue;
        auto it = std::find_if(groups.begin(), groups.end(), [&](const auto& g) { return g.first == d->kind; });
        if (it == groups.end())
        {
            groups.emplace_back(d->kind, Group{});
            it = groups.end() - 1;
        }
        auto& group = it->second;
        ++group.n;
        for (const auto& flag : d->flags)
            if (group.states.count(flag))
                ++group.states[flag];
        for (const auto& word : Words(d->direction))
            if (word == "above" || word == "below")
                group.levels.insert(word);
    }
    return groups;
}

std::string DescribeGroups(const std::vector<std::pair<std::string, Group>>& aGroups, bool aWithLevels)
{
    std::vector<std::string> parts;
    for (const auto& [kind, group] : aGroups)
    {
        // Every state is spelled out, the "no" too: with "2 cameras" alone the model said they were watching V.
        std::vector<std::string> notes;
        auto state = [&](const char* aName) { return group.states.at(aName); };
        if (aWithLevels && !group.levels.empty())
            notes.push_back(Join({group.levels.begin(), group.levels.end()}, " and "));
        if (kind == "camera" || kind == "turret" || kind == "sniper nest")
            notes.push_back(group.n > 1 ? std::to_string(state("watching-V")) + " watching V"
                                        : (state("watching-V") ? "watching V" : "not watching V"));
        if (kind == "turret" || kind == "sniper nest")
            notes.push_back(group.n > 1 ? std::to_string(state("hostile")) + " hostile"
                                        : (state("hostile") ? "hostile" : "not hostile"));
        if (kind == "alarm")
            notes.push_back(state("ringing") ? "ringing" : "silent");
        if (state("off"))
            notes.push_back(group.n > 1 ? std::to_string(state("off")) + " off" : "off");
        parts.push_back(Count(group.n, kind) + (notes.empty() ? "" : " (" + Join(notes, ", ") + ")"));
    }
    return Join(parts, "; ");
}

// --- enemies ---

struct Enemy
{
    std::string id, faction, role, threat, power;
    int meters = 0;
    std::string direction, awareness;
    int health = 0;
    std::vector<std::string> flags;
    std::string weapon;
    std::vector<std::string> cyberware;
    std::string name;

    bool Has(const std::string& aFlag) const { return Contains(flags, aFlag); }
};

// The game's "enemies=" line: "id,faction,role,threat,power,meters,direction,awareness,health,flags,weapon,
// cyberware,name" entries joined by ";" (flags space-separated, cyberware joined by "+").
std::vector<Enemy> ParseEnemies(const std::string& aLine)
{
    std::vector<Enemy> enemies;
    for (const auto& entry : Split(aLine, ";"))
    {
        auto f = Split(entry, ",");
        if (f.size() < 13)
            continue;
        auto meters = ParseInt(f[5]);
        auto health = ParseInt(f[8]);
        if (!meters || !health)
            continue;
        Enemy e{f[0], FactionName(f[1]), f[2], f[3], f[4], *meters, f[6], f[7], *health, Words(f[9])};
        e.weapon = f[10].empty() ? "" : WeaponName(f[10]);
        for (const auto& part : Split(f[11], "+"))
            if (!part.empty())
                e.cyberware.push_back(part);
        e.name = text::Trim(f[12]);
        enemies.push_back(std::move(e));
    }
    return enemies;
}

std::string Awareness(const Enemy& aEnemy)
{
    if (aEnemy.awareness == "combat" && aEnemy.Has("targeting-V"))
        return "fighting V";
    static const std::map<std::string, std::string> names = {{"combat", "fighting"},
                                                             {"searching", "searching"},
                                                             {"fleeing", "fleeing"},
                                                             {"suspicious", "getting suspicious of V"},
                                                             {"calm", "unaware of V"}};
    auto it = names.find(aEnemy.awareness);
    auto text = it == names.end() ? aEnemy.awareness : it->second;
    if (!aEnemy.Has("hostile") && (aEnemy.awareness == "calm" || aEnemy.awareness == "suspicious"))
        text += ", not hostile yet";
    return text;
}

bool Notable(const std::string& aThreat)
{
    return aThreat == "elite" || aThreat == "boss" || aThreat == "maxtac";
}

// "3 Maelstrom (2 gunners, 1 netrunner; 2 fighting V, 1 unaware of V; 1 elite)": every count spelled out, so the
// model does not invent states.
std::string DescribeFaction(const std::string& aFaction, const std::vector<const Enemy*>& aGroup)
{
    std::vector<std::string> roles, states, threats, notes;
    for (const auto* e : aGroup)
    {
        roles.push_back(e->role);
        states.push_back(Awareness(*e));
        if (Notable(e->threat))
            threats.push_back(e->threat);
    }
    std::vector<std::string> parts;
    for (const auto& [role, n] : Tally(roles))
        parts.push_back(std::to_string(n) + " " + role + (n > 1 ? "s" : ""));
    notes.push_back(Join(parts, ", "));
    parts.clear();
    for (const auto& [state, n] : Tally(states))
        parts.push_back(std::to_string(n) + " " + state);
    notes.push_back(Join(parts, ", "));
    if (!threats.empty())
    {
        // First-seen order, as Python's dict.
        std::vector<std::pair<std::string, int>> counts;
        for (const auto& threat : threats)
        {
            auto it = std::find_if(counts.begin(), counts.end(), [&](const auto& c) { return c.first == threat; });
            if (it == counts.end())
                counts.emplace_back(threat, 1);
            else
                ++it->second;
        }
        parts.clear();
        for (const auto& [threat, n] : counts)
            parts.push_back(std::to_string(n) + " " + threat);
        notes.push_back(Join(parts, ", "));
    }
    auto hacking = std::count_if(aGroup.begin(), aGroup.end(), [](const Enemy* e) { return e->Has("hacking-V"); });
    if (hacking)
        notes.push_back(std::to_string(hacking) + " hacking V right now");
    std::vector<std::string> named;
    for (const auto* e : aGroup)
        if (!e->name.empty())
            named.push_back(Notable(e->threat) ? e->name + " (" + e->threat + ")" : e->name);
    if (!named.empty())
        notes.push_back("named: " + Join(named, ", "));
    std::set<std::string> levels;
    for (const auto* e : aGroup)
        for (const auto& word : Words(e->direction))
            if (word == "above" || word == "below")
                levels.insert(word);
    if (!levels.empty())
        notes.push_back(Join({levels.begin(), levels.end()}, " and "));
    return std::to_string(aGroup.size()) + " " + aFaction + " (" + Join(notes, "; ") + ")";
}

std::string DescribePlace(const std::vector<const Enemy*>& aEnemies)
{
    std::vector<std::pair<std::string, std::vector<const Enemy*>>> byFaction;
    for (const auto* e : aEnemies)
    {
        auto it = std::find_if(byFaction.begin(), byFaction.end(), [&](const auto& g) { return g.first == e->faction; });
        if (it == byFaction.end())
            byFaction.push_back({e->faction, {e}});
        else
            it->second.push_back(e);
    }
    std::vector<std::string> parts;
    for (const auto& [faction, group] : byFaction)
        parts.push_back(DescribeFaction(faction, group));
    return Join(parts, "; ");
}

// Seconds since a remembered enemy (lost from sight, not tracked) was last seen; none for a live one.
std::optional<int> LastSeen(const Enemy& aEnemy)
{
    for (const auto& flag : aEnemy.flags)
        if (StartsWith(flag, "last-seen-") && EndsWith(flag, "s"))
            return ParseInt(flag.substr(10, flag.size() - 11)).value_or(0);
    return std::nullopt;
}

// Lore matching: a key counts only as a whole word (like Python's (?<!\w)key(?!\w)); bytes over 0x7F are letters.
bool WordChar(char c)
{
    auto u = static_cast<unsigned char>(c);
    return u >= 0x80 || u == '_' || (u >= '0' && u <= '9') || (u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z');
}

std::optional<std::size_t> FindWord(const std::string& aText, const std::string& aKey)
{
    if (aKey.empty())
        return std::nullopt;
    for (std::size_t at = aText.find(aKey); at != std::string::npos; at = aText.find(aKey, at + 1))
    {
        bool before = at > 0 && WordChar(aText[at - 1]);
        auto end = at + aKey.size();
        bool after = end < aText.size() && WordChar(aText[end]);
        if (!before && !after)
            return at;
    }
    return std::nullopt;
}
} // namespace

// --- Diary ---

void Diary::Clear()
{
    std::lock_guard lock(mutex);
    entries.clear();
    lastSaid.reset();
}

void Diary::NoteSaid(const std::string& aLine)
{
    std::lock_guard lock(mutex);
    lastSaid = std::make_pair(aLine, Now());
}

std::string Diary::Add(const std::string& aEvent)
{
    auto parts = Split(aEvent, "|");
    parts.resize(std::max<std::size_t>(parts.size(), 3));
    auto action = text::Trim(parts[0]);
    auto kind = text::Trim(parts[1]);
    auto detail = text::Trim(parts[2]);
    // Routine uses (doors, vending machines...) say nothing about V, and doors are ignored altogether: Apiko told V
    // "you opened nine doors".
    if (action.empty() || action == "used" || kind == "door")
        return {};
    // Warnings are for the moment only: a written line, never the diary.
    if (StartsWith(action, "warn_"))
    {
        log::Write(text::Trim("world: " + action + " " + kind + " " + detail));
        return action;
    }
    if (action == "killed" || action == "knocked_out" || action == "detected" || action == "boss_down")
        // boss_down: the boss's own name, or its faction.
        kind = action == "boss_down" ? FactionName(kind) : EnemyLabel(kind);
    if ((action == "hacked" || action == "used") && !detail.empty())
        detail = Humanize(detail);
    else if (action == "breached" || action == "pinged")
        detail.clear(); // number of devices exposed: only logged
    auto now = Now();
    {
        std::lock_guard lock(mutex);
        auto key = std::make_tuple(action, kind, detail);
        auto it = entries.find(key);
        // One ping, breach or alarm can reach us many times at once (a save load re-applies the Ping status to every
        // pinged NPC): repeats within RepeatSeconds are the same event.
        if (it != entries.end() && (action == "pinged" || action == "breached" || action == "alarm") &&
            now - it->second.last < RepeatSeconds)
            return {};
        auto& entry = entries.try_emplace(key, Entry{0, now}).first->second;
        ++entry.count;
        entry.last = now;
    }
    if (action != "said")
        log::Write(text::Trim("world: " + action + " " + kind + " " + detail));
    return action;
}

std::string Diary::Describe()
{
    auto now = Now();
    using Item = std::pair<std::tuple<std::string, std::string, std::string>, Entry>;
    std::vector<Item> items;
    std::optional<std::pair<std::string, double>> said;
    {
        std::lock_guard lock(mutex);
        for (auto it = entries.begin(); it != entries.end();)
            it = now - it->second.last > DiarySeconds ? entries.erase(it) : std::next(it);
        items.assign(entries.begin(), entries.end());
        said = lastSaid;
    }
    std::stable_sort(items.begin(), items.end(), [](const Item& a, const Item& b) { return a.second.last > b.second.last; });
    if (items.size() > DiaryLines)
        items.resize(DiaryLines);
    std::vector<std::string> lines;
    for (const auto& [key, entry] : items)
    {
        const auto& [action, kind, detail] = key;
        auto count = entry.count;
        auto what = Count(count, kind);
        std::string text;
        if (action == "hacked")
            text = "V hacked " + what + (detail.empty() ? "" : " (" + detail + ")");
        else if (action == "used")
            text = "V used " + what + (detail.empty() ? "" : " (" + detail + ")");
        else if (action == "spotted")
            text = what + " spotted V";
        else if (action == "hostile")
            text = what + " turned hostile";
        else if (action == "alarm")
            text = what + " went off";
        else if (action == "destroyed")
            text = what + " destroyed";
        else if (action == "breached")
            text = "V breached a local network" + (count > 1 ? " " + std::to_string(count) + " times" : "");
        else if (action == "pinged")
            text = "V pinged a local network" + (count > 1 ? " " + std::to_string(count) + " times" : "");
        else if (action == "killed" || action == "knocked_out")
        {
            auto who = count == 1 ? "a " + kind + " enemy" : std::to_string(count) + " " + kind + " enemies";
            static const std::map<std::string, std::string> hows = {{"stealth", " unseen, in stealth"},
                                                                    {"quickhack", " with quickhacks"},
                                                                    {"melee", " in melee"},
                                                                    {"explosive", " with explosives"},
                                                                    {"thrown", " with thrown weapons"}};
            auto how = hows.find(detail);
            text = (action == "killed" ? "V killed " : "V knocked out (non-lethal) ") + who +
                   (how == hows.end() ? "" : how->second);
        }
        else if (action == "detected")
            text = what + " detected V and attacked";
        else if (action == "boss_down")
            text = "V took down " + kind + (detail == "killed" ? " and killed them" : " without killing them");
        else if (action == "objective")
            text = "new objective" + (kind.empty() ? "" : " in \"" + kind + "\"") + ": " + detail;
        else if (action == "quest")
            text = "quest \"" + kind + "\" " + detail;
        else if (action == "fight")
            text = std::string("a fight broke out ") + (detail == "close" ? "close by" : "nearby") +
                   ", not involving V (" + Replace(kind, " vs ", " against ") + ")";
        else if (action == "heat")
            text = "NCPD wanted level rose to " + kind + " star" + (kind == "1" ? "" : "s");
        else if (action == "heat_lost")
            text = "V lost the NCPD (wanted level back to zero)";
        else if (action == "body_hidden")
            text = count == 1 ? "V hid a body" : "V hid " + std::to_string(count) + " bodies";
        else if (action == "civilian")
            text = std::string(kind == "killed" ? "V killed " : "V hurt ") +
                   (count == 1 ? "a civilian" : std::to_string(count) + " civilians");
        else if (action == "zone")
            text = std::string("V entered ") + (kind == "dangerous" ? "a hostile area (they shoot on sight)"
                                                                    : "a restricted area (trespassing)");
        else if (action == "sms")
            text = kind + " texted V: \"" + text::Truncate(detail, 120) + "\"";
        else
            text = action + " " + what;
        lines.push_back(text + ", " + AgeText(now - entry.last));
    }
    if (said && now - said->second <= SaidSeconds)
        lines.push_back("you said \"" + said->first + "\", " + AgeText(now - said->second));
    if (lines.empty())
        return {};
    return "[recent around V, last 10 min] " + Join(lines, "; ");
}

// --- Hearing ---

void Hearing::Clear()
{
    std::lock_guard lock(mutex);
    scene.clear();
    sceneStatus = "current";
    news.clear();
    chatter.clear();
    inSceneSince.reset();
}

void Hearing::OnObjective()
{
    std::string status;
    {
        std::lock_guard lock(mutex);
        if (scene.empty())
            return;
        bool recent = inSceneSince.has_value() || Now() - scene.back().time <= LedSeconds;
        status = recent && sceneStatus == "current" ? "led" : "past";
        if (status == sceneStatus)
            return;
        sceneStatus = status;
    }
    log::Write("last conversation is now '" + status + "' (objective changed)");
}

std::string Hearing::SceneNote()
{
    std::lock_guard lock(mutex);
    if (scene.empty() || Now() - scene.back().time > HeardSeconds)
        return {};
    std::set<std::string> who;
    for (const auto& line : scene)
        if (!line.speaker.empty() && line.speaker != "V")
            who.insert(line.speaker);
    auto withWhom = who.empty() ? std::string() : " with " + Join({who.begin(), who.end()}, ", ");
    if (sceneStatus == "led")
        return "the last conversation" + withWhom + " led to the current objective";
    if (sceneStatus == "past")
        return "the conversation" + withWhom + " belongs to an earlier objective: settled, don't bring it up";
    return {};
}

std::optional<int> Hearing::Handle(const std::string& aEvent)
{
    auto parts = Split(aEvent, "|", 3);
    auto now = Now();
    if (parts[0] == "heard" && parts.size() == 4)
    {
        auto kind = parts[1];
        auto speaker = text::Trim(parts[2]);
        auto said = text::Trim(parts[3]);
        if (said.empty())
            return std::nullopt;
        {
            std::lock_guard lock(mutex);
            if (kind == "conv")
            {
                // The game sometimes shows the same line twice a few seconds apart.
                if (!scene.empty() && scene.back().speaker == speaker && scene.back().text == said &&
                    now - scene.back().time < RepeatSeconds)
                    return std::nullopt;
                if (!scene.empty() && (now - scene.back().time > SceneGapSeconds || sceneStatus == "past"))
                    scene.clear();
                if (scene.empty())
                    sceneStatus = "current";
                scene.push_back({speaker, said, now});
                if (scene.size() > SceneLines)
                    scene.erase(scene.begin(), scene.end() - SceneLines);
            }
            else if (kind == "news")
            {
                // Commercials ("ad_mrstud", "ad_foreign_body"...) are noise, not news.
                if (StartsWith(text::Lower(speaker), "ad_"))
                    return std::nullopt;
                said = Shorten(said, NewsChars);
                if (std::none_of(news.begin(), news.end(), [&](const Line& l) { return l.text == said; }))
                {
                    news.push_back({speaker, said, now});
                    if (news.size() > NewsLines)
                        news.erase(news.begin(), news.end() - NewsLines);
                }
            }
            else if (kind == "chatter")
            {
                said = Shorten(said, ChatterChars);
                if (!chatter.empty() && chatter.back().speaker == speaker && chatter.back().text == said &&
                    now - chatter.back().time < RepeatSeconds)
                    return std::nullopt;
                chatter.push_back({speaker, said, now});
                if (chatter.size() > ChatterLines)
                    chatter.erase(chatter.begin(), chatter.end() - ChatterLines);
            }
        }
        log::Write("heard (" + kind + ") " + (speaker.empty() ? "?" : speaker) + ": " + said);
    }
    else if (parts[0] == "scene" && parts.size() > 1)
    {
        if (parts[1] == "start")
        {
            {
                std::lock_guard lock(mutex);
                inSceneSince = now;
            }
            log::Write("conversation started: Apiko keeps quiet");
        }
        else if (parts[1] == "end")
        {
            {
                std::lock_guard lock(mutex);
                inSceneSince.reset();
            }
            // "scene|end|lines": with Split's limit, a "|" in the number part would stay; ParseInt rejects it.
            int lines = parts.size() > 2 ? ParseInt(parts[2]).value_or(0) : 0;
            log::Write("conversation ended (" + std::to_string(lines) + " lines)");
            return lines;
        }
    }
    return std::nullopt;
}

bool Hearing::InScene()
{
    std::lock_guard lock(mutex);
    if (!inSceneSince)
        return false;
    double last = *inSceneSince;
    if (!scene.empty())
        last = std::max(last, scene.back().time);
    return Now() - last < SceneStuckSeconds;
}

std::string Hearing::Describe(bool aFull, bool aPlan)
{
    auto now = Now();
    std::vector<Line> lines, heardNews, heardChatter;
    std::string status;
    {
        std::lock_guard lock(mutex);
        lines = scene;
        status = sceneStatus;
        for (const auto& item : news)
            if (now - item.time <= HeardSeconds)
                heardNews.push_back(item);
        for (const auto& item : chatter)
            if (now - item.time <= ChatterSeconds)
                heardChatter.push_back(item);
    }
    std::vector<std::string> out;
    // Tokens: the transcript only when V asks about it or it just ended (aFull), or its last lines when V asks what
    // to do and it led to the current objective (aPlan). A settled one only when asked.
    bool wanted = aFull || (aPlan && status == "led");
    if (!lines.empty() && wanted && now - lines.back().time <= (status == "past" ? PastSeconds : HeardSeconds))
    {
        auto first = aFull || lines.size() <= SceneLinesShort ? lines.begin() : lines.end() - SceneLinesShort;
        auto shown = static_cast<std::size_t>(lines.end() - first);
        auto cut = shown == lines.size()
                       ? std::string()
                       : ", last " + std::to_string(shown) + " of " + std::to_string(lines.size()) + " lines";
        std::vector<std::string> transcript;
        for (auto it = first; it != lines.end(); ++it)
            transcript.push_back((it->speaker.empty() ? "?" : it->speaker) + ": " + it->text);
        auto label = status == "led"    ? "; it led to the current objective"
                     : status == "past" ? "; from an earlier objective, settled"
                                        : "";
        out.push_back("[last conversation V had, " + AgeText(now - lines.back().time) + cut + label + "; overheard] " +
                      Join(transcript, " / "));
    }
    if (!heardNews.empty() && aFull)
    {
        std::vector<std::string> items;
        for (const auto& item : heardNews)
            items.push_back((item.speaker.empty() ? "news" : item.speaker) + ": " + item.text);
        out.push_back("[heard on TV/radio lately] " + Join(items, " / "));
    }
    if (!heardChatter.empty() && aFull)
    {
        std::vector<std::string> items;
        for (const auto& item : heardChatter)
            items.push_back((item.speaker.empty() ? "someone" : item.speaker) + ": " + item.text);
        out.push_back("[people talking near V lately, not to V; " + AgeText(now - heardChatter.back().time) +
                      " the last line; overheard] " + Join(items, " / "));
    }
    return Join(out, "\n");
}

// --- Lore ---

void Lore::Load(const std::filesystem::path& aFile)
{
    gates.clear();
    entries.clear();
    lastDone.reset();
    Json data;
    if (auto content = text::ReadFile(aFile))
        data = Json::parse(*content, nullptr, false);
    if (!data.is_object())
    {
        log::Write("lore.json not loaded, Apiko knows no public lore: " + text::PathString(aFile));
        return;
    }
    if (data.contains("gates") && data["gates"].is_object())
        for (const auto& [name, ids] : data["gates"].items())
            if (ids.is_array())
                for (const auto& id : ids)
                    if (id.is_string())
                        gates[name].insert(id.get<std::string>());
    if (data.contains("entries") && data["entries"].is_array())
        for (const auto& item : data["entries"])
        {
            Entry entry{Str(item, "id"), {}, Str(item, "text"), Str(item, "after"), Str(item, "until")};
            if (item.contains("keys") && item["keys"].is_array())
                for (const auto& key : item["keys"])
                    if (key.is_string() && !key.get<std::string>().empty())
                        entry.keys.push_back(text::Plain(key.get<std::string>()));
            if (!entry.keys.empty())
                entries.push_back(std::move(entry));
        }
    log::Write("lore: " + std::to_string(entries.size()) + " entries");
}

std::set<std::string> Lore::DoneGates(const Json& aState)
{
    auto done = Split(Str(aState, "quests_done"), ",");
    std::set<std::string> passed;
    for (const auto& [name, ids] : gates)
        if (std::any_of(done.begin(), done.end(), [&](const std::string& id) { return ids.count(id) > 0; }))
            passed.insert(name);
    if (passed != lastDone)
    {
        lastDone = passed;
        log::Write("lore: story gates passed in this save: " +
                   (passed.empty() ? std::string("none") : Join({passed.begin(), passed.end()}, ", ")));
    }
    return passed;
}

std::string Lore::Describe(const std::string& aWords, const Json& aState)
{
    if (text::Trim(aWords).empty())
        return {};
    auto passed = DoneGates(aState);
    std::vector<std::pair<std::size_t, const Entry*>> found;
    for (const auto& entry : entries)
    {
        if (!entry.after.empty() && !passed.count(entry.after))
            continue;
        if (!entry.until.empty() && passed.count(entry.until))
            continue;
        std::optional<std::size_t> first;
        for (const auto& key : entry.keys)
            if (auto at = FindWord(aWords, key); at && (!first || *at < *first))
                first = at;
        if (first)
            found.emplace_back(*first, &entry);
    }
    std::stable_sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    if (found.size() > LoreMax)
        found.resize(LoreMax);
    if (found.empty())
        return {};
    std::vector<std::string> ids, lines;
    for (const auto& [at, entry] : found)
    {
        ids.push_back(entry->id);
        lines.push_back(entry->text);
    }
    log::Write("lore: " + Join(ids, ", "));
    return "[found on the Net: public info, use it as your own knowledge] " + Join(lines, " | ");
}

// --- what V asks about (patterns over text::Plain words: lower case, no accents) ---

const std::regex& AsksConversation()
{
    // V's words about what was said: the full transcript of the last conversation.
    static const std::regex pattern(
        R"(\b(dijo|dicho|dice|decia|habl\w*|conversaci\w*|charla|llamad\w*|llam\w*|mensaje\w*|sms|opinas|crees|parece|)"
        R"(noticias?|tele|radio|said|says|told|talk\w*|conversation|call\w*|messages?|texts?|think|news|tv|radio)\b)");
    return pattern;
}

const std::regex& AsksDevices()
{
    // Questions about the surroundings and orders on devices: the detailed device list.
    static const std::regex pattern(
        R"(\b(camaras?|torretas?|francotirador\w*|alarmas?|dispositivos?|aparatos?|hacke\w*|jacke\w*|hack\w*|)"
        R"(puertas?|verjas?|red|redes|punto de acceso|terminal\w*|ordenador\w*|maquinas?|altavo\w*|explosiv\w*|)"
        R"(pantallas?|teles?|televis\w*|radios?|carteles?|semaforos?|)"
        R"(alrededor|cerca|aqui|ves|apaga\w*|enciende|distrae\w*|vigil\w*|seguridad|)"
        R"(cameras?|turrets?|snipers?|alarms?|devices?|doors?|gates?|network|access point|terminals?|computers?|)"
        R"(machines?|speakers?|explosives?|screens?|tvs?|radios?|billboards?|signs?|traffic lights?|around|nearby|)"
        R"(see|turn off|switch off|distract\w*|security)\b)");
    return pattern;
}

const std::regex& AsksEnemies()
{
    // People around and threats, orders about them: the detailed enemy cards. Generic words (who, guy, see, near...)
    // are left out: a question about a conversation brought the enemies up.
    static const std::regex pattern(
        R"(\b(enemig\w*|alguien|nadie|guardias?|bandas?|pandiller\w*|matones|someone|anyone|nobody|)"
        R"(netrunners?|francotirador\w*|jefes?|amenazas?|peligr\w*|hostil\w*|armad\w*|vigil\w*|combat\w*|pelea\w*|)"
        R"(enemy|enemies|guards?|gang\w*|thugs?|snipers?|boss|threats?|danger\w*|hostiles?|armed|fight\w*)\b)");
    return pattern;
}

const std::regex& AsksPlan()
{
    // What to do or about the job: the focus line then carries the quest details.
    static const std::regex pattern(
        R"(\b(que hac\w*|ahora que|y ahora|siguiente|donde|adonde|mision|encargo|objetivo|plan|trabajo|)"
        R"(como (entro|entramos|lo hago|lo hacemos|sigo|seguimos)|ayuda|)"
        R"(what now|what do (i|we)|what next|next|where|mission|job|gig|objective|plan|how do (i|we)|help)\b)");
    return pattern;
}

const std::regex& AsksBodies()
{
    static const std::regex pattern(R"(\b(cuerpos?|cadaver\w*|muertos?|escond\w*|rastro|bodies|body|corpses?|hide|hidden)\b)");
    return pattern;
}

const std::regex& AsksVehicles()
{
    static const std::regex pattern(R"(\b(coches?|moto\w*|vehicul\w*|av|cars?|bikes?|vehicles?|ride)\b)");
    return pattern;
}

const std::regex& AsksShop()
{
    // Food, drinks or shopping: the vendors near.
    static const std::regex pattern(
        R"(\b(comer|comida|comemos|hambre|beber|bebida\w*|tienda\w*|vendedor\w*|venden|comprar|compro|compramos|)"
        R"(ripperdoc\w*|matasanos|armer\w*|ropa|puestos?|eat|eating|food|hungry|drinks?|buy|shop\w*|stores?|)"
        R"(vendors?|clothes|stalls?)\b)");
    return pattern;
}

const std::regex& AsksPeople()
{
    // People that are not enemies: the crowd, the police, someone there.
    static const std::regex pattern(
        R"(\b(gente|alguien|nadie|personas?|civil\w*|testigos?|polic\w*|poli|polis|ncpd|maxtac|multitud|)"
        R"(quien(es)?|people|someone|anyone|nobody|civilians?|witness\w*|police|cops?|crowd|who)\b)");
    return pattern;
}

bool Asks(const std::regex& aPattern, const std::string& aPlainWords)
{
    return !aPlainWords.empty() && std::regex_search(aPlainWords, aPattern);
}

// --- descriptions ---

std::string DescribePeople(const Json& aState, bool aAsked, bool aAsksShop)
{
    std::vector<std::string> items;
    auto vendors = Str(aState, "vendors_near");
    if (!vendors.empty() && (aAsked || aAsksShop))
        items.push_back("vendors near: " + Replace(vendors, " / ", ", "));
    else if (aAsksShop)
        items.push_back("no vendor within 40 m (there may be some farther away)");
    if (auto named = Str(aState, "named_here"); !named.empty())
        items.push_back("here: " + Replace(named, " / ", ", "));
    if (auto companions = Str(aState, "companions"); !companions.empty())
        items.push_back("following V: " + Replace(companions, " / ", ", "));
    auto stars = Str(aState, "wanted_stars");
    auto witnesses = Str(aState, "witnesses");
    if (!stars.empty())
        items.push_back("NCPD wanted level " + stars + " of 5 stars");
    // Police around is ordinary background: it matters only with a wanted level or witnesses, or when V asks.
    if (auto police = Str(aState, "police"); !police.empty() && (aAsked || !stars.empty() || !witnesses.empty()))
        items.push_back("police Apiko perceives: " + police);
    if (!witnesses.empty())
        items.push_back(witnesses + " civilians saw V (they call NCPD)");
    if (auto panic = Str(aState, "crowd_panic"); !panic.empty())
        items.push_back(panic + " civilians panicking");
    if (items.empty() && !aAsked)
        return {};
    auto crowd = Str(aState, "crowd");
    if (crowd == "crowded")
        items.push_back("a crowd around");
    else if (crowd == "a few people")
        items.push_back("a few people around");
    else if (crowd == "empty")
        items.push_back("nobody else around");
    return items.empty() ? std::string() : "[people around V] " + Join(items, "; ");
}

std::string DescribeSurroundings(const Json& aState, const std::string& aPlainWords)
{
    std::vector<std::string> items;
    if (auto fight = Str(aState, "fight_nearby"); !fight.empty())
    {
        auto parts = Split(fight, ", ", 1);
        std::vector<std::string> sides;
        for (const auto& side : Split(parts[0], " vs "))
            sides.push_back(FactionName(side));
        items.push_back("fight not involving V: " + Join(sides, " against ") +
                        (parts.size() > 1 && !parts[1].empty() ? ", " + parts[1] : ""));
    }
    if (auto loot = Str(aState, "notable_loot"); !loot.empty())
        items.push_back("notable loot in view: " + loot);
    if (auto bodies = Str(aState, "bodies");
        !bodies.empty() && (!Str(aState, "tension").empty() || Asks(AsksBodies(), aPlainWords)))
        items.push_back("bodies: " + bodies);
    if (auto vehicles = Str(aState, "vehicles"); !vehicles.empty())
    {
        bool asked = Asks(AsksVehicles(), aPlainWords);
        std::vector<std::string> shown;
        for (const auto& vehicle : Split(vehicles, ", "))
            if (asked || vehicle != "V's own vehicle")
                shown.push_back(vehicle);
        if (!shown.empty())
            items.push_back("vehicles near: " + Join(shown, ", "));
    }
    return items.empty() ? std::string() : "[around V] " + Join(items, "; ");
}

std::string DescribeFocus(const Json& aState, const std::string& aSceneNote, bool aEnemiesAround, bool aDetailed)
{
    std::vector<std::string> items;
    auto tension = Str(aState, "tension");
    if (tension.find("combat") != std::string::npos)
        items.push_back("combat: V's survival comes first");
    else if (!tension.empty())
        items.push_back("tension: " + tension);
    auto objective = Str(aState, "objective");
    auto meters = ParseInt(Str(aState, "objective_meters"));
    bool atObjective = meters && *meters <= AtObjectiveMeters;
    // The objective only when it helps: V asks what to do, it just changed, a conversation ended, or V is at it.
    // Always there, the model kept pushing V towards it ("your objective is 1.5 km away").
    if (!objective.empty() && (aDetailed || atObjective))
    {
        auto quest = Str(aState, "quest");
        auto kind = Str(aState, "quest_type");
        if (!aState.contains("quest_type"))
            kind = "job";
        auto line = "objective \"" + objective + "\"" + (quest.empty() ? "" : " (" + kind + " \"" + quest + "\")");
        if (meters)
        {
            if (*meters <= AtObjectiveMeters)
                line += "; V is there now";
            else if (*meters < 1000)
                line += "; its marker is " + std::to_string(*meters) + " m away";
            else
            {
                char km[32];
                std::snprintf(km, sizeof(km), "%.1f", *meters / 1000.0);
                line += "; its marker is " + std::string(km) + " km away";
            }
        }
        items.push_back(line);
        auto done = aDetailed ? Str(aState, "objectives_done") : std::string();
        if (!done.empty())
            items.push_back("steps already completed (finished, never suggest them): " + done);
        auto description = aDetailed ? Str(aState, "quest_description") : std::string();
        if (!description.empty())
        {
            // Journal texts come with literal "\n" and fixer chatter: one line, short.
            static const std::regex spaces(R"(\s+)");
            description = text::Trim(std::regex_replace(Replace(description, "\\n", " "), spaces, " "));
            description = Shorten(description, FocusDescriptionChars);
            items.push_back("background of the job (context only; the current objective is what counts now): " +
                            description);
        }
    }
    else if (objective.empty() && aDetailed)
        items.push_back("no tracked objective");
    if (!aSceneNote.empty())
        items.push_back(aSceneNote);
    if (aEnemiesAround && tension.empty())
        items.push_back("enemies nearby are no threat right now: not worth mentioning");
    if (items.empty())
        return {};
    return "[what matters now; to choose what to say, never recite it; earlier turns' readings are stale] " +
           Join(items, "; ");
}

std::string DescribeDevices(const std::string& aLine, bool aDetailed)
{
    auto devices = ParseDevices(aLine);
    if (devices.empty())
        return {};
    auto flagged = [&](const char* aFlag) {
        return std::any_of(devices.begin(), devices.end(), [&](const Device& d) { return Contains(d.flags, aFlag); });
    };
    bool breached = flagged("breached");
    bool pinged = flagged("pinged");
    if (aDetailed)
    {
        std::vector<std::string> items;
        for (const auto& d : devices)
        {
            auto place = Contains(d.flags, "here") ? "here" : "elsewhere";
            std::vector<std::string> flags;
            for (const auto& flag : d.flags)
                if (flag != "on" && flag != "here") // "on" is the normal case
                    flags.push_back(flag);
            items.push_back(d.id + " " + d.kind + " " + std::to_string(d.meters) + "m " + d.direction + ", " + place +
                            (flags.empty() ? "" : " (" + Join(flags, ", ") + ")"));
        }
        return "[devices you perceive; here = in V's space, elsewhere = behind walls or on another floor; ids are "
               "internal, never say them] " +
               Join(items, "; ");
    }
    std::vector<const Device*> hereList, awayList;
    for (const auto& d : devices)
        (Contains(d.flags, "here") ? hereList : awayList).push_back(&d);
    auto here = SecurityGroups(hereList);
    auto away = SecurityGroups(awayList);
    if (here.empty() && away.empty() && !breached && !pinged)
        return {};
    auto hereText = DescribeGroups(here, false);
    std::vector<std::string> lines{"[security here, in V's space] " + (hereText.empty() ? std::string("none") : hereText)};
    if (!away.empty())
        lines.push_back("[security elsewhere on the network, not in V's space] " + DescribeGroups(away, true));
    if (breached)
        lines.push_back("[network] V has breached the local network");
    else if (pinged)
        lines.push_back("[network] V's ping revealed the local network");
    return Join(lines, "\n");
}

std::string DescribeEnemies(const std::string& aLine, bool aDetailed)
{
    auto enemies = ParseEnemies(aLine);
    if (enemies.empty())
        return {};
    if (aDetailed)
    {
        std::vector<std::string> items;
        for (const auto& e : enemies)
        {
            std::string place;
            if (auto ago = LastSeen(e))
                place = std::to_string(e.meters) + "m " + e.direction + " when last seen " + std::to_string(*ago) +
                        "s ago, out of sight since; may have moved, the rest is as it was then";
            else
                place = std::to_string(e.meters) + "m " + e.direction + ", " + (e.Has("here") ? "here" : "elsewhere");
            std::vector<std::string> card{e.id + " " + e.faction + " " + e.role + (e.name.empty() ? "" : " \"" + e.name + "\""),
                                          e.threat + " rank, " + e.power + " for V", place, Awareness(e),
                                          std::to_string(e.health) + "% health"};
            if (!e.weapon.empty())
                card.push_back(e.weapon);
            if (!e.cyberware.empty())
                card.push_back("cyberware: " + Join(e.cyberware, ", "));
            if (e.Has("hacking-V"))
                card.push_back("hacking V right now");
            std::vector<std::string> how;
            for (const char* way : {"tagged", "pinged", "camera"})
                if (e.Has(way))
                    how.push_back(way);
            if (!how.empty() && !e.Has("here"))
                card.push_back("known via " + Join(how, "/"));
            items.push_back(Join(card, ", "));
        }
        return "[enemies you perceive; here = in V's view now, elsewhere = marked (V saw it), tagged or pinged but "
               "out of view now (behind V, around a corner, behind walls); last seen = no longer tracked, only where "
               "it was; ids are internal, never say them] " +
               Join(items, "; ");
    }
    std::vector<const Enemy*> here, lost, away;
    for (const auto& e : enemies)
    {
        if (e.Has("here"))
            here.push_back(&e);
        else if (LastSeen(e))
            lost.push_back(&e);
        else
            away.push_back(&e);
    }
    std::vector<std::string> lines;
    if (!here.empty())
        lines.push_back("[threats here, in V's view] " + DescribePlace(here));
    if (!away.empty())
        lines.push_back("[threats elsewhere, marked, tagged or pinged but out of V's view now] " + DescribePlace(away));
    if (!lost.empty())
    {
        int newest = *LastSeen(*lost[0]);
        for (const auto* e : lost)
            newest = std::min(newest, *LastSeen(*e));
        lines.push_back("[threats you saw and lost sight of (latest " + std::to_string(newest) +
                        "s ago); only where they were then, they may have moved] " + DescribePlace(lost));
    }
    return Join(lines, "\n");
}
} // namespace apiko::world
