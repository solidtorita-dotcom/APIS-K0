// Apiko's memory of V: port of Memory and MemoryStore in bridge\apiko_bridge.py (same files, so the Python bridge
// and the native one share it): data\memory.json, data\snapshots\<version>.json, data\memory_version.txt.
#pragma once

#include <nlohmann/json.hpp>

#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace apiko
{
class Memory
{
public:
    using Json = nlohmann::json;

    // Apiko's memory before it has met V.
    static Json Fresh();

    void Load(const std::filesystem::path& aFile);
    // Fresh memory with aData's fields on top.
    void Replace(const Json& aData);
    void Save(const std::filesystem::path& aFile) const;

    std::string AffinityStance() const;
    std::string SwearingRule() const;
    // The memory part of the system prompt: summary, facts, current plans.
    std::string PromptBlock() const;

    void ExpirePlans(const std::function<void(const std::string&)>& aLog);
    void AddPlan(const std::string& aText);
    // The plan with this number (1-based), removed; empty when there is none.
    std::string DropPlan(int aNumber);

    Json data = Fresh();
};

// Apiko's memory belongs to the save game, not to the PC: loading an older save brings back what Apiko knew then.
// Every change gets a new version number (never reused, so branches don't collide) and a snapshot; the game keeps
// the version (and a copy of the memory) in the save. Old snapshots are pruned.
class MemoryStore
{
public:
    using Json = nlohmann::json;

    explicit MemoryStore(const std::filesystem::path& aDataDir);

    std::vector<int> Versions() const;
    void SaveAs(int aVersion, const Json& aData);
    // A new version for aData; returns its number.
    int Commit(const Json& aData);
    std::optional<Json> Load(int aVersion) const;

private:
    std::filesystem::path Path(int aVersion) const;
    int LastVersion() const;
    void WriteLastVersion(int aVersion);

    std::filesystem::path dir;
    std::filesystem::path versionFile;
};
} // namespace apiko
