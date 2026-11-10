// APIS-K0 - the antenna and face mission (DISENO.md, "Misión: antena y cara"; texts in MISION_ANTENA.md).
// Phase 3 (the site): the NetWatch agents of a vanilla street event turn hostile, the crate holds the antenna and the
// technician's log, Apiko remarks on arriving and on the server (a memory), and taking the antenna mounts it (a light
// glitch, a line) and completes the quest. Its lines do not depend on Apiko's instability (barks.json "any").
// Phase 1: the start and Apiko keeping its quest tracked. The first time V leaves the Badlands with Apiko awake,
// Apiko picks up its antenna's echo: it says so (the bridge's written line "antenna_start"), comes back if V had sent
// it away, and the quest starts, tracked. No text message. While the quest is active and Apiko is with V, V tracking
// another quest makes Apiko track its own again, with a line now and then ("antenna_retrack").
// The journal entries come from ApisK0.archive (tools\make_world.py, which holds the same ids).
module ApisK0

public abstract class ApisK0Antenna {
  public static func QuestPath() -> String { return "quests/minor_quest/apisk0_antenna"; }
  public static func DescriptionPath() -> String { return "quests/minor_quest/apisk0_antenna/desc"; }
  public static func PhasePath() -> String { return "quests/minor_quest/apisk0_antenna/antenna"; }
  public static func ObjectivePath() -> String { return "quests/minor_quest/apisk0_antenna/antenna/apisk0_get_antenna"; }
  public static func ObjectiveId() -> String { return "apisk0_get_antenna"; }
  // Out of the Badlands this long (seconds) before the echo comes: driving along the border flips the district.
  public static func LeaveSeconds() -> Float { return 5.0; }
  // Seconds between checks (start and tracking).
  public static func CheckInterval() -> Float { return 0.5; }
  // V tracked another quest: Apiko tracks its own again after this many seconds (a beat, not at once: tried in the
  // game, 2026-11-10), every time, with a line, at most one per RetrackLineCooldown (the start's line does not count).
  public static func RetrackDelay() -> Float { return 2.0; }
  public static func RetrackLineCooldown() -> Float { return 10.0; }

  // The site (DISENO.md, "Sitio"): a vanilla street event in Pacifica with four NetWatch agents guarding the evidence,
  // picked by the user on 2026-11-10. Its agents are police-type (Factions.NCPD, police presets) and never attacked V; while the quest is
  // active they turn hostile towards V (ApisK0System.UpdateAntennaSite, the user's choice). The site's center (the
  // agents' spots), how far from it they count, and how near V must be for the check.
  public static func SiteCenter() -> Vector4 { return new Vector4(-1845.35, -2102.52, 43.81, 1.0); }
  public static func SiteRadius() -> Float { return 35.0; }
  public static func SiteCheckDistance() -> Float { return 150.0; }
  public static func SiteAgent() -> TweakDBID { return t"Character.netwatch_agent_netrunner3_omaha_elite"; }

  // Phase 3: our props at the site (make_world.py, ANTENNA_PROPS, same refs and spots) and what the crate holds.
  public static func MappinPath() -> String { return "quests/minor_quest/apisk0_antenna/antenna/apisk0_get_antenna/apisk0_antenna_pin"; }
  public static func EvidenceRef() -> String { return "$/mod/apisk0/#apisk0_evidence"; }
  public static func ServerPosition() -> Vector4 { return new Vector4(-1843.73, -2103.44, 44.4, 1.0); }
  public static func Antenna() -> ItemID { return ItemID.FromTDBID(t"Items.ApisK0Antenna"); }
  public static func TechLog() -> ItemID { return ItemID.FromTDBID(t"Items.ApisK0TechLog"); }
  public static func TechLogEntryPath() -> String { return "onscreens/emails/generic/shards/world/apisk0_tech_log"; }
  // Apiko's lines at the site: when V comes this close (meters) the first time; when V looks at the server this close
  // (and within LookCone of the view's center, as a dot product), its memories one by one (MemoryCount, at least
  // MemoryCooldown seconds apart; one since the user's review, 2026-11-10, which also dropped the body bags' line).
  public static func ArriveDistance() -> Float { return 35.0; }
  public static func LookDistance() -> Float { return 7.0; }
  public static func LookCone() -> Float { return 0.95; }
  public static func MemoryCount() -> Int32 { return 1; }
  public static func MemoryCooldown() -> Float { return 20.0; }
  // Mounting the antenna once V takes it (as the chip's upload): glitch steps, the line (the bridge's "antenna_done"
  // cue ends it, or the timeout; without the bridge a fixed time), then the quest is done.
  public static func MountStep1() -> Float { return 0.5; }
  public static func MountStep2() -> Float { return 3.0; }
  public static func MountFixed() -> Float { return 5.0; }
  public static func MountTimeout() -> Float { return 25.0; }
  public static func MountFinish() -> Float { return 1.5; }

  // V looks at a spot: close enough and near the middle of the view.
  public static func LooksAt(game: GameInstance, player: ref<PlayerPuppet>, spot: Vector4) -> Bool {
    let cameras: ref<CameraSystem> = GameInstance.GetCameraSystem(game);
    let camera: Transform;
    let toSpot: Vector4;
    if !IsDefined(cameras) || !cameras.GetActiveCameraWorldTransform(camera) {
      return false;
    };
    toSpot = spot - Transform.GetPosition(camera);
    return Vector4.Length(toSpot) <= ApisK0Antenna.LookDistance()
      && Vector4.Dot(Vector4.Normalize(toSpot), cameras.GetActiveCameraForward()) >= ApisK0Antenna.LookCone();
  }

  // The antenna is mounted: the objective and the quest are done, the map pin off.
  public static func Complete(game: GameInstance) -> Void {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    if !IsDefined(journal) {
      return;
    };
    journal.ChangeEntryState(ApisK0Antenna.MappinPath(), "gameJournalQuestMapPin", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.ObjectivePath(), "gameJournalQuestObjective", gameJournalEntryState.Succeeded, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Antenna.PhasePath(), "gameJournalQuestPhase", gameJournalEntryState.Succeeded, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.QuestPath(), "gameJournalQuest", gameJournalEntryState.Succeeded, JournalNotifyOption.Notify);
  }

  // V has read the technician's log (reading a shard activates its journal entry).
  public static func TechLogRead(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let entry: wref<JournalEntry>;
    if !IsDefined(journal) {
      return false;
    };
    entry = journal.GetEntryByString(ApisK0Antenna.TechLogEntryPath(), "gameJournalOnscreen");
    return IsDefined(entry) && NotEquals(journal.GetEntryState(entry), gameJournalEntryState.Inactive);
  }

  // The quest's journal entries are installed (ApisK0.archive and ArchiveXL).
  public static func Exists(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    return IsDefined(journal) && IsDefined(journal.GetEntryByString(ApisK0Antenna.QuestPath(), "gameJournalQuest"));
  }

  // The quest has started (active, or done): the echo never comes again.
  public static func Started(game: GameInstance) -> Bool {
    return NotEquals(ApisK0Antenna.State(game), gameJournalEntryState.Inactive);
  }

  public static func Active(game: GameInstance) -> Bool {
    return Equals(ApisK0Antenna.State(game), gameJournalEntryState.Active);
  }

  private static func State(game: GameInstance) -> gameJournalEntryState {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let quest: wref<JournalEntry>;
    if !IsDefined(journal) {
      return gameJournalEntryState.Inactive;
    };
    quest = journal.GetEntryByString(ApisK0Antenna.QuestPath(), "gameJournalQuest");
    if !IsDefined(quest) {
      return gameJournalEntryState.Inactive;
    };
    return journal.GetEntryState(quest);
  }

  // The quest starts with its first objective, tracked. False when the entries are missing.
  public static func Start(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    if !ApisK0Antenna.Exists(game) {
      return false;
    };
    journal.ChangeEntryState(ApisK0Antenna.QuestPath(), "gameJournalQuest", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Antenna.DescriptionPath(), "gameJournalQuestDescription", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.PhasePath(), "gameJournalQuestPhase", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.ObjectivePath(), "gameJournalQuestObjective", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Antenna.MappinPath(), "gameJournalQuestMapPin", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    ApisK0Antenna.Track(game);
    return true;
  }

  // V tracks the quest's current objective.
  public static func IsTracked(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let tracked: wref<JournalEntry>;
    if !IsDefined(journal) {
      return false;
    };
    tracked = journal.GetTrackedEntry();
    return IsDefined(tracked) && Equals(tracked.GetId(), ApisK0Antenna.ObjectiveId());
  }

  public static func Track(game: GameInstance) -> Void {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let objective: wref<JournalEntry>;
    if !IsDefined(journal) {
      return;
    };
    objective = journal.GetEntryByString(ApisK0Antenna.ObjectivePath(), "gameJournalQuestObjective");
    if IsDefined(objective) {
      journal.TrackEntry(objective);
    };
  }

  // Development: the quest back to inactive, to start it again in the same save.
  public static func Reset(game: GameInstance) -> Void {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    if !IsDefined(journal) {
      return;
    };
    journal.ChangeEntryState(ApisK0Antenna.MappinPath(), "gameJournalQuestMapPin", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.TechLogEntryPath(), "gameJournalOnscreen", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.ObjectivePath(), "gameJournalQuestObjective", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.PhasePath(), "gameJournalQuestPhase", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.DescriptionPath(), "gameJournalQuestDescription", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Antenna.QuestPath(), "gameJournalQuest", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
  }
}
