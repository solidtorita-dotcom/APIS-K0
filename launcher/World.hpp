// What Apiko perceives of the world, turned into as few tokens as possible: port of bridge\apiko_world.py.
// - Diary: world events from the game ("action|kind|detail"), kept for a few minutes and aggregated ("V hacked 3
//   cameras"). Only read when a turn happens.
// - Hearing: the last conversation V had and the latest TV/radio news (the game's subtitles), and whether V is in a
//   conversation right now.
// - Lore: Night City's public Net (lore.json), only the entries V's words touch and the save's story allows.
// - Describe*: the game's state readings (devices, enemies, people, surroundings, quest) as short lines for the model.
// V's words are matched by the Asks* patterns after text::Plain (lower case, no accents), so the patterns are ASCII.
// Diary and Hearing are fed on the poll thread and read on the worker: they lock. Lore is worker-only.
#pragma once

#include <nlohmann/json.hpp>

#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <regex>
#include <set>
#include <string>
#include <tuple>
#include <vector>

namespace apiko::world
{
using Json = nlohmann::json;

// A conversation with fewer lines than this is not worth a remark when it ends.
constexpr int SceneCommentMinLines = 3;

class Diary
{
public:
    // Another save was loaded: what happened in the last minutes belongs to another timeline.
    void Clear();
    // Apiko's last written line: only that one, and only for a while, reaches the model ("what did you say?").
    void NoteSaid(const std::string& aLine);
    // Records an event ("action|kind|detail"). Returns the action when it is new (not a repeat or ignored), so the
    // bridge can react to it; "" otherwise. Warnings (warn_*) are returned but never stored.
    std::string Add(const std::string& aEvent);
    // One line with the latest events, newest first, or "" when nothing happened lately.
    std::string Describe();

private:
    struct Entry
    {
        int count = 0;
        double last = 0;
    };
    std::mutex mutex;
    std::map<std::tuple<std::string, std::string, std::string>, Entry> entries;
    std::optional<std::pair<std::string, double>> lastSaid;
};

class Hearing
{
public:
    void Clear();
    // The tracked objective changed: a conversation going on or just ended led to it; an older one is history.
    void OnObjective();
    // For the focus line: how the last conversation relates to the current objective, or "".
    std::string SceneNote();
    // A "story" message ("heard|conv|speaker|text", "heard|news|...", "heard|chatter|...", "scene|start",
    // "scene|end|lines"). Returns the
    // number of lines of a conversation that just ended.
    std::optional<int> Handle(const std::string& aEvent);
    // V is talking with someone: Apiko keeps quiet. A conversation that never ended stops counting after a while.
    bool InScene();
    // The last conversation and the latest news (aFull: V asks about them, or it just ended), or the end of a
    // conversation that led to the current objective (aPlan: V asks what to do); else "".
    std::string Describe(bool aFull, bool aPlan);

private:
    struct Line
    {
        std::string speaker;
        std::string text;
        double time = 0;
    };
    std::mutex mutex;
    std::vector<Line> scene;
    // "current"; "led" (the objective changed right after it); "past" (settled, shown only when V asks).
    std::string sceneStatus = "current";
    std::vector<Line> news;
    // Ambient chatter around V ("heard|chatter|..."): never a conversation, only shown when V asks.
    std::vector<Line> chatter;
    std::optional<double> inSceneSince;
};

class Lore
{
public:
    // lore.json; without it Apiko knows no public lore (logged).
    void Load(const std::filesystem::path& aFile);
    // "[found on the Net]" with the entries V's words touch (aWords already text::Plain), or "".
    std::string Describe(const std::string& aWords, const Json& aState);

private:
    struct Entry
    {
        std::string id;
        std::vector<std::string> keys; // plain
        std::string text;
        std::string after;
        std::string until;
    };
    std::set<std::string> DoneGates(const Json& aState);

    std::map<std::string, std::set<std::string>> gates;
    std::vector<Entry> entries;
    std::optional<std::set<std::string>> lastDone;
};

// V's words (text::Plain) asking about these subjects.
const std::regex& AsksConversation();
const std::regex& AsksDevices();
const std::regex& AsksEnemies();
const std::regex& AsksPlan();
const std::regex& AsksBodies();
const std::regex& AsksVehicles();
const std::regex& AsksShop();
const std::regex& AsksPeople();
bool Asks(const std::regex& aPattern, const std::string& aPlainWords);

// "[people around V]": named characters, companions, police and wanted level, panic and witnesses, the crowd.
std::string DescribePeople(const Json& aState, bool aAsked, bool aAsksShop);
// "[around V]": other people's fights, notable loot, bodies (with tension or when asked), vehicles.
std::string DescribeSurroundings(const Json& aState, const std::string& aPlainWords);
// "[what matters now]": tension, the tracked objective (details when aDetailed), what is settled.
std::string DescribeFocus(const Json& aState, const std::string& aSceneNote, bool aEnemiesAround, bool aDetailed);
// Security devices here / elsewhere, or the full list when aDetailed.
std::string DescribeDevices(const std::string& aLine, bool aDetailed);
// Enemies here / elsewhere / lost sight of, or the full cards when aDetailed.
std::string DescribeEnemies(const std::string& aLine, bool aDetailed);
} // namespace apiko::world
