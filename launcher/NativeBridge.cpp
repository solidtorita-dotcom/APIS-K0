#include "NativeBridge.hpp"

#include "Brain.hpp"
#include "GameFiles.hpp"
#include "Log.hpp"
#include "Text.hpp"

#include <Windows.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace apiko::native
{
namespace
{
constexpr auto PollInterval = std::chrono::milliseconds(100);
constexpr auto AliveInterval = std::chrono::seconds(2);
constexpr auto OwnerInterval = std::chrono::seconds(1);
constexpr auto SettingsInterval = std::chrono::seconds(1);
constexpr auto SessionInterval = std::chrono::milliseconds(500);

using Clock = std::chrono::steady_clock;

std::string Str(const nlohmann::json& aMessage, const char* aKey)
{
    auto it = aMessage.find(aKey);
    if (it == aMessage.end())
        return {};
    return it->is_string() ? it->get<std::string>() : it->dump();
}

class Bridge
{
public:
    Bridge(const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir)
        : files(aModDir)
        , brain(files, aModDir, aDataDir)
        , ownerFile(aDataDir / L"bridge_owner.txt")
        , stopEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr))
    {
    }

    ~Bridge() { CloseHandle(stopEvent); }

    void Start()
    {
        poller = std::thread([this] { Run(); });
        worker = std::thread([this] { Work(); });
    }

    // Waits for the worker: a model call in flight ends within its timeout (request_timeout_seconds).
    void Stop()
    {
        SetEvent(stopEvent);
        {
            std::lock_guard lock(workMutex);
            stopping = true;
        }
        workReady.notify_all();
        if (poller.joinable())
            poller.join();
        if (worker.joinable())
            worker.join();
    }

private:
    // The poll thread: reads the game's messages, keeps the files alive. Never waits for the model.
    void Run()
    {
        // Only one bridge may serve the game; the newest one started wins (see Bridge.still_owner in the Python
        // bridge, which reads the same file): a Python bridge started by hand later takes over, and this one stops.
        ownerToken = "native-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(UnixMillis());
        if (!WriteFileAtomic(ownerFile, ownerToken))
            log::Write("could not write bridge_owner.txt");
        log::Write("APIS-K0 bridge 0.3.0 running in the game. Mod folder: " + text::PathString(files.ModDir()));
        try
        {
            brain.Start();
            brainReady = true;
            // Local voices load on the worker, not here: the first time they are downloaded.
            Queue({{"type", "warm_up"}});
        }
        catch (const std::exception& e)
        {
            brainError = e.what();
            log::Write("the brain could not start: " + brainError);
        }

        // What the file already holds was sent before this bridge started: only its latest save load counts.
        std::optional<nlohmann::json> load;
        for (auto& message : files.ReadNewMessages())
            if (Str(message, "type") == "memory_load")
                load = std::move(message);
        if (load)
            Dispatch(std::move(*load));

        auto nextAlive = Clock::now();
        auto nextOwner = Clock::now() + OwnerInterval;
        auto nextSettings = Clock::now() + SettingsInterval;
        auto nextSession = Clock::now();
        while (WaitForSingleObject(stopEvent, static_cast<DWORD>(PollInterval.count())) == WAIT_TIMEOUT)
        {
            auto messages = files.ReadNewMessages();
            if (brainReady && !messages.empty())
                brain.NoteGameMessage();
            // Only the latest save load of a batch counts: an older one must not reset the memory.
            std::size_t lastLoad = messages.size();
            for (std::size_t i = 0; i < messages.size(); ++i)
                if (Str(messages[i], "type") == "memory_load")
                    lastLoad = i;
            for (std::size_t i = 0; i < messages.size(); ++i)
                if (Str(messages[i], "type") != "memory_load" || i == lastLoad)
                    Dispatch(std::move(messages[i]));

            auto now = Clock::now();
            if (now >= nextAlive)
            {
                nextAlive = now + AliveInterval;
                files.Heartbeat();
            }
            if (now >= nextOwner)
            {
                nextOwner = now + OwnerInterval;
                if (!StillOwner())
                {
                    log::Write("another bridge was started: this one stops");
                    break;
                }
            }
            if (brainReady && now >= nextSettings)
            {
                nextSettings = now + SettingsInterval;
                Guard("settings", [this] { brain.CheckSettings(); });
            }
            if (now >= nextSession)
            {
                nextSession = now + SessionInterval;
                WatchSession();
            }
            if (brainReady)
                Guard("cues", [this] { brain.Tick(); });
        }

        // The alive file belongs to the newer bridge when this one was replaced.
        if (StillOwner())
            files.RemoveAlive();
        log::Write("native bridge stopped");
    }

    // The worker thread: one message at a time through the brain (model calls block here).
    void Work()
    {
        for (;;)
        {
            nlohmann::json message;
            {
                std::unique_lock lock(workMutex);
                workReady.wait(lock, [this] { return stopping || !work.empty(); });
                if (stopping)
                    return;
                message = std::move(work.front());
                work.pop_front();
            }
            Guard(Str(message, "type"), [&] { brain.Handle(message); });
        }
    }

    // One bad message or turn must not kill the bridge.
    template <typename F> void Guard(const std::string& aWhat, F&& aAction)
    {
        try
        {
            aAction();
        }
        catch (const std::exception& e)
        {
            log::Write("error handling " + aWhat + ": " + e.what());
        }
    }

    void Dispatch(nlohmann::json aMessage)
    {
        auto type = Str(aMessage, "type");
        if (type == "say" || type == "test" || type == "memory_load" || type == "event")
        {
            if (!brainReady)
            {
                if (type == "test")
                    files.WriteReply("test", Str(aMessage, "what") + "|error|" + text::Truncate(brainError, 200));
                return;
            }
            Queue(std::move(aMessage));
        }
        else if (type == "world" || type == "story")
        {
            // Local and at once (diary, hearing); a written line or a remark goes to the worker.
            if (!brainReady)
                return;
            std::optional<nlohmann::json> followUp;
            Guard(type, [&] { followUp = brain.Perceive(aMessage); });
            if (followUp)
                Queue(std::move(*followUp));
        }
        else if (type == "ptt_start")
        {
            // At once, not on the worker: recording must start right away (and Apiko hush).
            if (brainReady)
                Guard(type, [this] { brain.StartListening(); });
        }
        else if (type == "ptt_stop")
        {
            std::optional<nlohmann::json> clip;
            if (brainReady)
                Guard(type, [&] { clip = brain.StopListening(aMessage); });
            if (clip)
                Queue(std::move(*clip));
        }
        else
            log::Write("message (not handled yet): " + type);
    }

    void Queue(nlohmann::json aMessage)
    {
        {
            std::lock_guard lock(workMutex);
            work.push_back(std::move(aMessage));
        }
        workReady.notify_one();
    }

    bool StillOwner()
    {
        std::string token;
        if (!ReadSharedFile(ownerFile, token))
            return true;
        return text::Trim(token) == ownerToken;
    }

    // The session ended (main menu, another load, game closed): only when two checks in a row say so.
    void WatchSession()
    {
        misses = files.GameLive() ? 0 : misses + 1;
        bool now = misses == 1 ? live : misses == 0;
        if (now != live)
        {
            log::Write(now ? "game session started" : "game session ended: Apiko goes quiet");
            if (!now && brainReady)
                brain.Hush();
        }
        // Why Apiko cannot talk, said on the first session, not at start: the plugin starts before CET, which skips
        // the replies already in from_bridge.txt when it starts.
        if (now && !greeted)
        {
            greeted = true;
            if (!brainReady)
                files.WriteReply("status", "Apiko bridge: " + text::Truncate(brainError, 250));
        }
        live = now;
    }

    GameFiles files;
    Brain brain;
    bool brainReady = false;
    std::string brainError;
    std::filesystem::path ownerFile;
    std::string ownerToken;
    HANDLE stopEvent;
    std::thread poller;
    std::thread worker;
    std::mutex workMutex;
    std::condition_variable workReady;
    std::deque<nlohmann::json> work;
    bool stopping = false;
    bool live = false;
    bool greeted = false;
    int misses = 0;
};

std::unique_ptr<Bridge> bridge;
} // namespace

void Start(const std::filesystem::path& aModDir, const std::filesystem::path& aDataDir)
{
    if (bridge)
        return;
    log::Open(aDataDir / L"native.log");
    bridge = std::make_unique<Bridge>(aModDir, aDataDir);
    bridge->Start();
}

void Stop()
{
    if (!bridge)
        return;
    bridge->Stop();
    bridge.reset();
    log::Close();
}
} // namespace apiko::native
