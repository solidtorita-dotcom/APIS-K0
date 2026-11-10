// APIS-K0 - phase 4, piece 4: narrative perception (DISENO.md, "Pieza 4").
// - Tracked quest: name and current objective as sensors; a new objective, and quests started, completed or failed
//   go to Apiko's diary.
// - Hearing: the subtitles of the conversations and calls V takes part in (speaker + text), the news V hears on
//   TVs and radios and, since 2026-11-10, ambient chatter (lines over NPCs' heads, "chatter": only for when V asks
//   about it). Nothing while V drives (Apiko is not around then).
// - Conversation state: V is in a conversation while in a locked scene, on a call, or while lines keep coming. The
//   bridge keeps Apiko quiet meanwhile and may let it remark on the conversation when it ends.
// - Text messages V receives: sender and text to the diary.
// Lines go to the CET side as "story" messages: "heard|conv|speaker|text", "heard|news|speaker|text",
// "scene|start" and "scene|end|<lines heard>". Quest and message events go with the world events
// ("action|kind|detail").
module ApisK0

public abstract class ApisK0StoryConfig {
  public static func CheckInterval() -> Float { return 1.0; }
  // A conversation goes on while its lines keep coming this close together (seconds), even out of a locked scene.
  public static func ConversationGap() -> Float { return 10.0; }
  // Scene tier from which V is in a locked scene (Tier3_LimitedGameplay and above).
  public static func LockedSceneTier() -> Int32 { return 3; }
  // Journal changes right after a load are the game restoring state, not news.
  public static func IgnoreJournalAfterLoad() -> Float { return 10.0; }
  public static func MaxText() -> Int32 { return 300; }
  public static func MaxQueued() -> Int32 { return 60; }
  // Seconds between walks of the journal for the completed quests (a completed quest refreshes it at once).
  public static func QuestsDoneRefresh() -> Float { return 60.0; }
}

public class ApisK0Story extends IScriptable {
  private let m_messages: array<String>;
  private let m_events: array<String>;
  private let m_lineHandle: ref<CallbackHandle>;
  private let m_journalRegistered: Bool;
  private let m_nextCheck: Float;
  private let m_primed: Bool;
  private let m_objective: String;
  private let m_inConversation: Bool;
  private let m_lastConvLine: Float;
  private let m_sceneLines: Int32;
  private let m_ignoreJournalUntil: Float;
  // Sim time of the last Update, for the callbacks (they get no time of their own).
  private let m_now: Float;
  private let m_questsDone: String;
  private let m_questsDoneAt: Float;

  public static func Create(game: GameInstance) -> ref<ApisK0Story> {
    return new ApisK0Story();
  }

  // On every player attach (a load or a new game): fresh state, listeners (re)registered.
  public func Reset(now: Float) -> Void {
    let bbDefs: ref<UIGameDataDef> = GetAllBlackboardDefs().UIGameData;
    let blackboard: ref<IBlackboard> = GameInstance.GetBlackboardSystem(GetGameInstance()).Get(bbDefs);
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    ArrayClear(this.m_messages);
    ArrayClear(this.m_events);
    this.m_primed = false;
    this.m_nextCheck = 0.0;
    this.m_objective = "";
    this.m_inConversation = false;
    this.m_lastConvLine = -1000.0;
    this.m_sceneLines = 0;
    this.m_now = now;
    this.m_questsDone = "";
    this.m_questsDoneAt = 0.0;
    this.m_ignoreJournalUntil = now + ApisK0StoryConfig.IgnoreJournalAfterLoad();
    if IsDefined(blackboard) {
      if IsDefined(this.m_lineHandle) {
        blackboard.UnregisterListenerVariant(bbDefs.ShowDialogLine, this.m_lineHandle);
      };
      this.m_lineHandle = blackboard.RegisterListenerVariant(bbDefs.ShowDialogLine, this, n"OnDialogLine");
    };
    if IsDefined(journal) {
      if this.m_journalRegistered {
        journal.UnregisterScriptCallback(this, n"OnJournalUpdate");
      };
      journal.RegisterScriptCallback(this, n"OnJournalUpdate", gameJournalListenerType.State);
      this.m_journalRegistered = true;
    };
  }

  // Session end: no listener of ours stays on the UI blackboard or the journal of the old session.
  public func Unregister() -> Void {
    let bbDefs: ref<UIGameDataDef> = GetAllBlackboardDefs().UIGameData;
    let blackboard: ref<IBlackboard> = GameInstance.GetBlackboardSystem(GetGameInstance()).Get(bbDefs);
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    if IsDefined(blackboard) && IsDefined(this.m_lineHandle) {
      blackboard.UnregisterListenerVariant(bbDefs.ShowDialogLine, this.m_lineHandle);
    };
    this.m_lineHandle = null;
    if IsDefined(journal) && this.m_journalRegistered {
      journal.UnregisterScriptCallback(this, n"OnJournalUpdate");
    };
    this.m_journalRegistered = false;
    this.m_inConversation = false;
  }

  // "story" messages for the bridge, oldest first. Clears the queue.
  public func DrainMessages() -> array<String> {
    let messages: array<String> = this.m_messages;
    ArrayClear(this.m_messages);
    return messages;
  }

  // Quest and message events for the diary ("action|kind|detail"). Clears the queue.
  public func DrainEvents() -> array<String> {
    let events: array<String> = this.m_events;
    ArrayClear(this.m_events);
    return events;
  }

  private func PushMessage(message: String) -> Void {
    ArrayPush(this.m_messages, message);
    if ArraySize(this.m_messages) > ApisK0StoryConfig.MaxQueued() {
      ArrayErase(this.m_messages, 0);
    };
  }

  private func PushEvent(action: String, kind: String, detail: String) -> Void {
    ArrayPush(this.m_events, action + "|" + kind + "|" + detail);
    if ArraySize(this.m_events) > ApisK0StoryConfig.MaxQueued() {
      ArrayErase(this.m_events, 0);
    };
  }

  // Called from the system tick while Apiko is awake.
  public func Update(now: Float, player: ref<PlayerPuppet>) -> Void {
    let objective: String;
    let quest: String;
    let talking: Bool;
    this.m_now = now;
    if now < this.m_nextCheck || !IsDefined(player) {
      return;
    };
    this.m_nextCheck = now + ApisK0StoryConfig.CheckInterval();
    // A new objective (the first reading after a load is only the baseline).
    objective = this.TrackedObjective();
    if !this.m_primed {
      this.m_primed = true;
      this.m_objective = objective;
    } else {
      if NotEquals(objective, this.m_objective) {
        this.m_objective = objective;
        quest = this.TrackedQuest();
        if StrLen(objective) > 0 {
          this.PushEvent("objective", quest, objective);
        };
      };
    };
    // Conversation start and end.
    talking = !IsDefined(GetMountedVehicle(player))
      && (PlayerPuppet.GetSceneTier(player) >= ApisK0StoryConfig.LockedSceneTier()
        || GameInstance.GetPhoneManager(GetGameInstance()).IsPhoneCallActive()
        || now - this.m_lastConvLine < ApisK0StoryConfig.ConversationGap());
    if talking && !this.m_inConversation {
      this.m_inConversation = true;
      this.m_sceneLines = 0;
      this.PushMessage("scene|start");
    } else {
      if !talking && this.m_inConversation {
        this.m_inConversation = false;
        this.PushMessage("scene|end|" + IntToString(this.m_sceneLines));
      };
    };
  }

  // Sensors: the tracked quest and its current objective, plus what the bridge needs to judge what matters now
  // (never recited): quest type, meters to the objective's map marker, objectives already done, the quest's
  // journal description.
  public func GetState(player: ref<PlayerPuppet>) -> array<String> {
    let state: array<String>;
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    let objective: wref<JournalQuestObjective> = this.TrackedEntry();
    let quest: wref<JournalQuest> = this.QuestOf(objective);
    let meters: Int32;
    let text: String;
    // Story progress for the bridge's lore (what Night City already knows): ids of the main and side quests done.
    text = this.QuestsDone();
    if StrLen(text) > 0 {
      ArrayPush(state, "quests_done=" + text);
    };
    if !IsDefined(objective) {
      return state;
    };
    text = this.Clean(this.Localized(objective.GetDescription()));
    if StrLen(text) > 0 {
      ArrayPush(state, "objective=" + text);
    };
    meters = this.MetersToObjective(objective, player);
    if meters >= 0 {
      ArrayPush(state, "objective_meters=" + IntToString(meters));
    };
    if !IsDefined(quest) {
      return state;
    };
    text = this.Clean(this.Localized(quest.GetTitle(journal)));
    if StrLen(text) > 0 {
      ArrayPush(state, "quest=" + text);
    };
    ArrayPush(state, "quest_type=" + this.QuestType(journal.GetQuestType(quest)));
    text = this.DoneObjectives(journal, quest);
    if StrLen(text) > 0 {
      ArrayPush(state, "objectives_done=" + text);
    };
    text = this.Description(journal, quest);
    if StrLen(text) > 0 {
      ArrayPush(state, "quest_description=" + text);
    };
    return state;
  }

  // Journal ids ("q005_heist"...) of the main and side quests completed, comma-separated; refreshed now and then
  // (the journal is not cheap to walk and it changes slowly).
  private func QuestsDone() -> String {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    let context: JournalRequestContext;
    let filter: JournalRequestStateFilter;
    let quests: array<wref<JournalEntry>>;
    let ids: String;
    let i: Int32;
    if this.m_now < this.m_questsDoneAt && StrLen(this.m_questsDone) > 0 || !IsDefined(journal) {
      return this.m_questsDone;
    };
    this.m_questsDoneAt = this.m_now + ApisK0StoryConfig.QuestsDoneRefresh();
    filter.succeeded = true;
    context.stateFilter = filter;
    JournalRequestContext.CreateQuestTypeRequestFilter(context, GetGameInstance(), true, true, false, false, false);
    journal.GetQuests(context, quests);
    i = 0;
    while i < ArraySize(quests) {
      if IsDefined(quests[i]) {
        ids += (StrLen(ids) > 0 ? "," : "") + quests[i].GetId();
      };
      i += 1;
    };
    this.m_questsDone = ids;
    return ids;
  }

  private func QuestOf(objective: wref<JournalQuestObjective>) -> wref<JournalQuest> {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    let phase: wref<JournalQuestPhase>;
    if !IsDefined(objective) || !IsDefined(journal) {
      return null;
    };
    phase = journal.GetParentEntry(objective) as JournalQuestPhase;
    if !IsDefined(phase) {
      return null;
    };
    return journal.GetParentEntry(phase) as JournalQuest;
  }

  private func QuestType(type: gameJournalQuestType) -> String {
    switch type {
      case gameJournalQuestType.MainQuest:
        return "main story";
      case gameJournalQuestType.Contract:
        return "gig";
      case gameJournalQuestType.CyberPsycho:
        return "cyberpsycho sighting";
    };
    return "side job";
  }

  // Meters from V to the nearest map marker of the objective, or -1 without one.
  private func MetersToObjective(objective: wref<JournalQuestObjective>, player: ref<PlayerPuppet>) -> Int32 {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    let positions: array<Vector3>;
    let best: Float = -1.0;
    let distance: Float;
    let i: Int32;
    if !IsDefined(player) || !IsDefined(journal) {
      return -1;
    };
    if !GameInstance.GetMappinSystem(GetGameInstance()).GetQuestMappinPositionsByObjective(Cast<Uint32>(journal.GetEntryHash(objective)), positions) {
      return -1;
    };
    i = 0;
    while i < ArraySize(positions) {
      distance = Vector4.Distance(Vector4.Vector3To4(positions[i]), player.GetWorldPosition());
      if best < 0.0 || distance < best {
        best = distance;
      };
      i += 1;
    };
    return best < 0.0 ? -1 : RoundF(best);
  }

  // The quest's objectives already done, latest last, joined by " / " (at most the last 4).
  private func DoneObjectives(journal: ref<JournalManager>, entry: wref<JournalQuest>) -> String {
    let filter: JournalRequestStateFilter;
    let entries: array<wref<JournalEntry>>;
    let done: array<String>;
    let objective: wref<JournalQuestObjective>;
    let text: String;
    let list: String;
    let i: Int32;
    filter.succeeded = true;
    QuestLogUtils.UnpackRecursiveWithFilter(journal, entry, filter, entries);
    i = 0;
    while i < ArraySize(entries) {
      objective = entries[i] as JournalQuestObjective;
      if IsDefined(objective) && Equals(journal.GetEntryState(objective), gameJournalEntryState.Succeeded) {
        text = StrReplaceAll(this.Clean(this.Localized(objective.GetDescription())), " / ", " - ");
        if StrLen(text) > 0 && !ArrayContains(done, text) {
          ArrayPush(done, text);
        };
      };
      i += 1;
    };
    i = Max(0, ArraySize(done) - 4);
    while i < ArraySize(done) {
      list += (StrLen(list) > 0 ? " / " : "") + done[i];
      i += 1;
    };
    return list;
  }

  // The quest log's description of the quest (its journal texts, joined).
  private func Description(journal: ref<JournalManager>, entry: wref<JournalQuest>) -> String {
    let entries: array<wref<JournalQuestDescription>> = QuestLogUtils.GetDescriptions(journal, entry);
    let seen: array<String>;
    let text: String;
    let description: String;
    let i: Int32 = 0;
    while i < ArraySize(entries) {
      text = this.Localized(entries[i].GetDescription());
      if StrLen(text) > 0 && !ArrayContains(seen, text) {
        ArrayPush(seen, text);
        description += (StrLen(description) > 0 ? " " : "") + text;
      };
      i += 1;
    };
    return this.Clean(description);
  }

  private func TrackedEntry() -> wref<JournalQuestObjective> {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    if !IsDefined(journal) {
      return null;
    };
    return journal.GetTrackedEntry() as JournalQuestObjective;
  }

  private func TrackedObjective() -> String {
    let objective: wref<JournalQuestObjective> = this.TrackedEntry();
    if !IsDefined(objective) {
      return "";
    };
    return this.Clean(this.Localized(objective.GetDescription()));
  }

  private func TrackedQuest() -> String {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    let objective: wref<JournalQuestObjective> = this.TrackedEntry();
    let phase: wref<JournalQuestPhase>;
    let quest: wref<JournalQuest>;
    if !IsDefined(objective) {
      return "";
    };
    phase = journal.GetParentEntry(objective) as JournalQuestPhase;
    if !IsDefined(phase) {
      return "";
    };
    quest = journal.GetParentEntry(phase) as JournalQuest;
    if !IsDefined(quest) {
      return "";
    };
    return this.Clean(this.Localized(quest.GetTitle(journal)));
  }

  // Subtitles: every line the game shows (and Apiko's own, which are skipped).
  protected cb func OnDialogLine(value: Variant) -> Bool {
    let lines: array<scnDialogLineData> = FromVariant<array<scnDialogLineData>>(value);
    let player: ref<PlayerPuppet> = GetPlayer(GetGameInstance());
    let system: ref<ApisK0System> = ApisK0System.Get(GetGameInstance());
    let line: scnDialogLineData;
    let kind: String;
    let speaker: String;
    let text: String;
    let i: Int32 = 0;
    if !IsDefined(system) || !system.IsUnlocked() || !IsDefined(player) || IsDefined(GetMountedVehicle(player)) {
      return false;
    };
    while i < ArraySize(lines) {
      line = lines[i];
      kind = this.LineKind(line.type);
      // A regular line spoken by a device (a TV or radio playing a show) is news, not a conversation.
      if Equals(kind, "conv") && IsDefined(line.speaker) && !IsDefined(line.speaker as ScriptedPuppet) {
        kind = "news";
      };
      text = this.Clean(line.text);
      if StrLen(kind) > 0 && StrLen(text) > 0 && !ApisK0ChatConfig.IsOwnSpeaker(line.speakerName) {
        speaker = this.Speaker(line, player);
        if Equals(kind, "conv") {
          this.m_lastConvLine = this.m_now;
          this.m_sceneLines += 1;
        };
        this.PushMessage("heard|" + kind + "|" + speaker + "|" + text);
      };
      i += 1;
    };
    return false;
  }

  // "conv" (a conversation or call V is in), "news" (TV and radio), "chatter" (people talking near V, the lines over
  // their heads: the bridge keeps them apart and shows them only when V asks what was said) or "" (invisible lines).
  private func LineKind(type: scnDialogLineType) -> String {
    switch type {
      case scnDialogLineType.Regular:
      case scnDialogLineType.Holocall:
      case scnDialogLineType.SceneComment:
      case scnDialogLineType.OwnerlessRegular:
      case scnDialogLineType.AlwaysCinematicNoSpeaker:
      case scnDialogLineType.Narrator:
        return "conv";
      case scnDialogLineType.Radio:
      case scnDialogLineType.GlobalTV:
      case scnDialogLineType.GlobalTVAlwaysVisible:
        return "news";
      case scnDialogLineType.OverHead:
      case scnDialogLineType.OverHeadAlwaysVisible:
        return "chatter";
    };
    return "";
  }

  // "V" for V's own lines; otherwise the subtitle name (a localization key or plain text), or "".
  private func Speaker(line: scnDialogLineData, player: ref<PlayerPuppet>) -> String {
    let name: String = line.speakerName;
    if IsDefined(line.speaker) && line.speaker.IsPlayer() {
      return "V";
    };
    if StrLen(name) == 0 && IsDefined(line.speaker) {
      name = line.speaker.GetDisplayName();
    };
    return StrReplaceAll(this.Clean(this.Localized(name)), "|", "/");
  }

  // Quests started, completed or failed, and text messages V receives.
  protected cb func OnJournalUpdate(hash: Uint32, className: CName, notifyOption: JournalNotifyOption, changeType: JournalChangeType) -> Bool {
    let system: ref<ApisK0System> = ApisK0System.Get(GetGameInstance());
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(GetGameInstance());
    let entry: wref<JournalEntry>;
    let quest: wref<JournalQuest>;
    let message: wref<JournalPhoneMessage>;
    let contact: wref<JournalContact>;
    let state: gameJournalEntryState;
    if !IsDefined(system) || !system.IsUnlocked() || !IsDefined(journal) || this.m_now < this.m_ignoreJournalUntil {
      return false;
    };
    entry = journal.GetEntry(hash);
    if !IsDefined(entry) {
      return false;
    };
    state = journal.GetEntryState(entry);
    if Equals(className, n"gameJournalQuest") {
      quest = entry as JournalQuest;
      if !IsDefined(quest) || NotEquals(notifyOption, JournalNotifyOption.Notify) {
        return false;
      };
      if Equals(state, gameJournalEntryState.Active) {
        this.PushEvent("quest", this.Clean(this.Localized(quest.GetTitle(journal))), "started");
      } else {
        if Equals(state, gameJournalEntryState.Succeeded) {
          this.m_questsDoneAt = 0.0;  // the lore may change: walk the journal again on the next state
          this.PushEvent("quest", this.Clean(this.Localized(quest.GetTitle(journal))), "completed");
        } else {
          if Equals(state, gameJournalEntryState.Failed) {
            this.PushEvent("quest", this.Clean(this.Localized(quest.GetTitle(journal))), "failed");
          };
        };
      };
      return false;
    };
    if Equals(className, n"gameJournalPhoneMessage") {
      message = entry as JournalPhoneMessage;
      if !IsDefined(message) || NotEquals(state, gameJournalEntryState.Active) || NotEquals(message.GetSender(), gameMessageSender.NPC) {
        return false;
      };
      contact = journal.GetContactByMessage(message);
      this.PushEvent("sms", IsDefined(contact) ? this.Clean(this.Localized(contact.GetLocalizedName(journal))) : "someone",
        this.Clean(this.Localized(message.GetText())));
    };
    return false;
  }

  // Journal and subtitle texts may come as localization keys ("LocKey#123") or as plain text.
  private func Localized(text: String) -> String {
    let localized: String;
    if StrLen(text) == 0 {
      return "";
    };
    localized = GetLocalizedText(text);
    return StrLen(localized) > 0 ? localized : text;
  }

  // One line, no field separator, capped.
  private func Clean(text: String) -> String {
    let clean: String = StrReplaceAll(StrReplaceAll(StrReplaceAll(text, "\n", " "), "\r", " "), "|", "/");
    if StrLen(clean) > ApisK0StoryConfig.MaxText() {
      clean = StrLeft(clean, ApisK0StoryConfig.MaxText()) + "...";
    };
    return clean;
  }
}
