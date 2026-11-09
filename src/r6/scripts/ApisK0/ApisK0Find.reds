// APIS-K0 - the find (DISENO.md, "Hallazgo de Apiko"): the drone's distress beacon texts V, which opens a quest whose
// map pin leads to a NetWatch case in the Badlands. Inside is Apiko's core, a chip (Items.ApisK0Core); when V takes
// it, the chip forces a handshake with V's neural port (screen glitches and upload notices, ApisK0System.UpdateUpload)
// and Apiko comes online in a drone behind V. The journal entries and the case come from ApisK0.archive
// (tools\make_world.py, which holds the same ids); the item from apis_k0_find.yaml. Journal states are saved with the
// game; the chip stays in V's inventory as a quest item.
// A drone wreck that V reactivated was tried first and dropped: the drone popped to its flying height on spawn and
// could not be made to lift off convincingly. The chip upload covers the drone's arrival instead.
module ApisK0

public abstract class ApisK0Find {
  // The find starts by itself (ApisK0System.UpdateTrigger): the vanilla fact set when "Playing for Time" (q101) is
  // done, the end of the prologue, and the seconds V must then spend in the Badlands before the beacon calls.
  public static func PrologueDoneFact() -> CName { return n"q101_done"; }
  public static func TriggerSeconds() -> Float { return 20.0; }
  // The beacon calls V before texting (ApisK0System.UpdateBeaconCall): its journal contact id, and the quest fact the
  // vanilla PhoneSystem keeps for the call (questPhoneTalkingState: 0 ended, 1 ringing, 2 talking, 3 rejected).
  public static func BeaconContact() -> CName { return n"apisk0_beacon"; }
  public static func BeaconCallFact() -> String { return "phonecall_apisk0_beacon_with_player"; }
  // Seconds of noise once V answers, then the call ends; seconds before calling again when V does not answer.
  public static func BeaconAnsweredSeconds() -> Float { return 4.5; }
  public static func BeaconRetrySeconds() -> Float { return 5.0; }
  // With the bridge running, the answered call lasts until NetWatch's recording and Apiko's line have sounded (the
  // bridge's "beacon_done" cue), at most this long.
  public static func BeaconVoicedTimeout() -> Float { return 30.0; }
  // A ringing call that never got an answer nor ended (the phone UI's own timeout should end it before).
  public static func BeaconRingTimeout() -> Float { return 60.0; }
  // On the line once V answers, all vanilla: the static loop of an enemy netrunner hacking V, and the effects of a
  // holocall with Blackwall interference (Phantom Liberty's q301; without it, that one does nothing).
  public static func BeaconStatic() -> CName { return n"nme_netrunner_static_lp"; }
  public static func BeaconStaticStop() -> CName { return n"nme_netrunner_static_lp_stop"; }
  public static func BeaconInterference() -> CName { return n"hacking_interference_shot"; }
  public static func BeaconBlackwall() -> CName { return n"q301_holocall_blackwall"; }
  // Apiko's contact after the first contact (the beacon's goes away).
  public static func ApikoContactPath() -> String { return "contacts/apisk0"; }
  public static func ApikoConversationPath() -> String { return "contacts/apisk0/apiko"; }
  public static func ApikoMessagePath() -> String { return "contacts/apisk0/apiko/apiko_01"; }
  // V calls APIKO (ApisK0System.UpdateApikoCall): the contact's id, the fact the PhoneSystem keeps for a call V makes
  // (questPhoneTalkingState, as above), seconds it rings before Apiko answers, and a cap for the answered call.
  public static func ApikoContact() -> CName { return n"apisk0"; }
  public static func ApikoCallFact() -> String { return "phonecall_player_with_apisk0"; }
  public static func ApikoAnswerSeconds() -> Float { return 2.5; }
  public static func ApikoCallMaxSeconds() -> Float { return 15.0; }

  // V's call to APIKO through the vanilla PhoneSystem, as a quest's call node answers one: StartCall picks up, EndCall
  // hangs up.
  public static func ApikoCall(game: GameInstance, phase: questPhoneCallPhase) -> Void {
    let request: ref<questTriggerCallRequest> = new questTriggerCallRequest();
    request.caller = n"player";
    request.addressee = ApisK0Find.ApikoContact();
    request.callPhase = phase;
    request.callMode = questPhoneCallMode.Audio;
    request.isPlayerTriggered = false;
    request.isRejectable = false;
    request.showAvatar = true;
    request.visuals = questPhoneCallVisuals.Default;
    GameInstance.GetScriptableSystemsContainer(game).Get(n"PhoneSystem").QueueRequest(request);
  }
  public static func ContactPath() -> String { return "contacts/apisk0_beacon"; }
  public static func ConversationPath() -> String { return "contacts/apisk0_beacon/beacon"; }
  public static func MessagePath() -> String { return "contacts/apisk0_beacon/beacon/beacon_01"; }
  public static func QuestPath() -> String { return "quests/minor_quest/apisk0_signal"; }
  public static func PhasePath() -> String { return "quests/minor_quest/apisk0_signal/signal"; }
  public static func ObjectivePath() -> String { return "quests/minor_quest/apisk0_signal/signal/find_source"; }
  public static func MappinPath() -> String { return "quests/minor_quest/apisk0_signal/signal/find_source/cache"; }
  // Optional: find out what happened, done when V reads Kessler's shard (ApisK0System.UpdateShardRead).
  public static func InvestigatePath() -> String { return "quests/minor_quest/apisk0_signal/signal/investigate"; }
  public static func DescriptionPath() -> String { return "quests/minor_quest/apisk0_signal/desc"; }

  // The case in the world (make_world.py: CACHE_REF, CACHE_POS) and the chip in it.
  public static func CacheRef() -> String { return "$/mod/apisk0/#apisk0_cache"; }
  public static func CachePosition() -> Vector4 { return new Vector4(5197.88, -1074.87, 139.40, 1.0); }
  public static func Core() -> ItemID { return ItemID.FromTDBID(t"Items.ApisK0Core"); }
  // The dead netrunner by the van (make_world.py: PROP_REFS) and his last log, a shard, with its journal entry.
  public static func NetrunnerRef() -> String { return "$/mod/apisk0/#apisk0_netrunner"; }
  public static func Shard() -> ItemID { return ItemID.FromTDBID(t"Items.ApisK0NetrunnerShard"); }
  public static func ShardEntryPath() -> String { return "onscreens/emails/generic/shards/world/apisk0_netrunner_log"; }
  // The second, hidden netrunner and her loot (apis_k0_find.yaml).
  public static func Netrunner2Ref() -> String { return "$/mod/apisk0/#apisk0_netrunner2"; }
  // Everything at the site (make_world.py: CACHE_REF, PROP_REFS): hidden until V gets the quest.
  public static func SceneRefs() -> array<String> {
    return [ApisK0Find.CacheRef(), "$/mod/apisk0/#apisk0_van", ApisK0Find.NetrunnerRef(), ApisK0Find.Netrunner2Ref()];
  }
  public static func StashItems() -> array<ItemID> {
    return [ItemID.FromTDBID(t"Items.ApisK0StashMemoryWipe"), ItemID.FromTDBID(t"Items.ApisK0StashSystemCollapse")];
  }
  // Meters from the case within which the system checks that the chip is in it (the case streams in at 150 m).
  public static func NearDistance() -> Float { return 140.0; }

  // The upload once V has the chip (ApisK0System.UpdateUpload): seconds from the pickup for each step, the player
  // glitch effects (vanilla, the ones of being quickhacked) and the notices (localization keys, make_world.py).
  public static func UploadStep1() -> Float { return 0.5; }
  public static func UploadStep2() -> Float { return 2.5; }
  public static func UploadStep3() -> Float { return 4.5; }
  public static func UploadDone() -> Float { return 6.0; }
  // With the bridge running, the upload lasts as long as Apiko's voice in V's head (the bridge's "head_done" cue):
  // the second glitch step comes at this time, and the end at the latest at the timeout.
  public static func VoicedStep2() -> Float { return 8.0; }
  public static func VoicedTimeout() -> Float { return 45.0; }
  public static func GlitchLow() -> CName { return n"hacking_glitch_low"; }
  public static func GlitchMedium() -> CName { return n"hacking_glitch_medium"; }
  public static func GlitchHeavy() -> CName { return n"hacking_glitch_heavy"; }

  // The beacon's text message arrives and the quest starts, tracked. Returns false if the journal entries are missing
  // (ApisK0.archive or ArchiveXL not installed).
  public static func Start(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let objective: wref<JournalEntry>;
    if !IsDefined(journal) || !IsDefined(journal.GetEntryByString(ApisK0Find.QuestPath(), "gameJournalQuest")) {
      return false;
    };
    journal.ChangeEntryState(ApisK0Find.ContactPath(), "gameJournalContact", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Find.ConversationPath(), "gameJournalPhoneConversation", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Find.MessagePath(), "gameJournalPhoneMessage", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Find.QuestPath(), "gameJournalQuest", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Find.DescriptionPath(), "gameJournalQuestDescription", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.PhasePath(), "gameJournalQuestPhase", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ObjectivePath(), "gameJournalQuestObjective", gameJournalEntryState.Active, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Find.MappinPath(), "gameJournalQuestMapPin", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.InvestigatePath(), "gameJournalQuestObjective", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
    objective = journal.GetEntryByString(ApisK0Find.ObjectivePath(), "gameJournalQuestObjective");
    if IsDefined(objective) {
      journal.TrackEntry(objective);
    };
    return true;
  }

  // A call from the beacon to V through the vanilla PhoneSystem (as a quest's call node does): `phase` IncomingCall
  // rings, EndCall hangs up. The incoming call screen finds the contact by its journal id.
  public static func BeaconCall(game: GameInstance, phase: questPhoneCallPhase) -> Void {
    let request: ref<questTriggerCallRequest> = new questTriggerCallRequest();
    request.caller = ApisK0Find.BeaconContact();
    request.addressee = n"player";
    request.callPhase = phase;
    request.callMode = questPhoneCallMode.Audio;
    request.isPlayerTriggered = false;
    request.isRejectable = true;
    request.showAvatar = true;
    request.visuals = questPhoneCallVisuals.Default;
    GameInstance.GetScriptableSystemsContainer(game).Get(n"PhoneSystem").QueueRequest(request);
  }

  // Whether the beacon may ring now: not in combat, not in a scene, no other call going on.
  public static func CanCall(game: GameInstance, player: ref<PlayerPuppet>) -> Bool {
    let phone: ref<PhoneSystem> = GameInstance.GetScriptableSystemsContainer(game).Get(n"PhoneSystem") as PhoneSystem;
    if !IsDefined(player) || player.IsInCombat() || PlayerPuppet.GetSceneTier(player) > 1 {
      return false;
    };
    if GameInstance.GetPhoneManager(game).IsPhoneCallActive() {
      return false;
    };
    return !IsDefined(phone) || phone.IsPhoneAvailable();
  }

  // V met Apiko: its contact replaces the beacon's. No text: Apiko just said it all in person (its conversation and
  // first message, "link established", stay in the journal unused).
  public static func MeetApiko(game: GameInstance) -> Void {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    if !IsDefined(journal) {
      return;
    };
    journal.ChangeEntryState(ApisK0Find.ContactPath(), "gameJournalContact", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ApikoContactPath(), "gameJournalContact", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify);
  }

  // V has got the quest (active, or done): the site is there from then on, for good.
  public static func QuestStarted(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let quest: wref<JournalEntry>;
    if !IsDefined(journal) {
      return false;
    };
    quest = journal.GetEntryByString(ApisK0Find.QuestPath(), "gameJournalQuest");
    return IsDefined(quest) && NotEquals(journal.GetEntryState(quest), gameJournalEntryState.Inactive);
  }

  // Hides an object of the site (every visual component, colliders, interaction) and adds the components it turned off
  // to `hidden`, to turn them back on (only those: some may be off by design). Returns how many it turned off.
  // Called again and again while the site is hidden: a body's character appearance (meshes, cloth, hair) attaches
  // after the entity shows up, so hiding it once left the bodies in sight.
  public static func Hide(object: ref<GameObject>, hidden: script_ref<array<wref<IComponent>>>) -> Int32 {
    let components: array<ref<IComponent>> = object.GetComponents();
    let name: String;
    let count: Int32 = 0;
    let i: Int32 = 0;
    while i < ArraySize(components) {
      name = NameToString(components[i].GetClassName());
      if components[i].IsEnabled() && (components[i].IsA(n"entIVisualComponent") || StrContains(name, "Mesh")
          || StrContains(name, "Cloth") || StrContains(name, "Collider") || StrContains(name, "nteraction")) {
        components[i].Toggle(false);
        ArrayPush(Deref(hidden), components[i]);
        count += 1;
      };
      i += 1;
    };
    return count;
  }

  // V is looking for the case: the objective is active.
  public static func IsSearching(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let objective: wref<JournalEntry>;
    if !IsDefined(journal) {
      return false;
    };
    objective = journal.GetEntryByString(ApisK0Find.ObjectivePath(), "gameJournalQuestObjective");
    return IsDefined(objective) && Equals(journal.GetEntryState(objective), gameJournalEntryState.Active);
  }

  // Apiko is online: objective and quest done, map pin off.
  public static func Complete(game: GameInstance) -> Void {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    if !IsDefined(journal) {
      return;
    };
    journal.ChangeEntryState(ApisK0Find.MappinPath(), "gameJournalQuestMapPin", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    // The optional objective left undone fails with the quest, as vanilla's do (reading the shard later still
    // completes it).
    if !ApisK0Find.Investigated(game) {
      journal.ChangeEntryState(ApisK0Find.InvestigatePath(), "gameJournalQuestObjective", gameJournalEntryState.Failed, JournalNotifyOption.DoNotNotify);
    };
    journal.ChangeEntryState(ApisK0Find.ObjectivePath(), "gameJournalQuestObjective", gameJournalEntryState.Succeeded, JournalNotifyOption.Notify);
    journal.ChangeEntryState(ApisK0Find.PhasePath(), "gameJournalQuestPhase", gameJournalEntryState.Succeeded, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.QuestPath(), "gameJournalQuest", gameJournalEntryState.Succeeded, JournalNotifyOption.Notify);
  }

  // Development: every entry back to inactive and the chip out of V's inventory, to test the find again in the same
  // save (the system puts the chip back in the case). Returns how many of the site's objects it reset (streamed in).
  public static func Reset(game: GameInstance) -> Int32 {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let refs: array<String> = ApisK0Find.SceneRefs();
    let object: ref<GameObject>;
    let scanning: ref<ScanningComponent>;
    let count: Int32 = 0;
    let i: Int32 = 0;
    // The site's objects back to never scanned (those streamed in now: V is expected to be near for this test hotkey):
    // the clue not inspected, and the scanned flag off (the progress bar only shows the first time; both are saved).
    while i < ArraySize(refs) {
      object = ApisK0Find.FindByRef(game, refs[i]);
      if IsDefined(object) {
        count += 1;
        ApisK0Find.InspectClue(object, true);
        scanning = object.FindComponentByType(n"gameScanningComponent") as ScanningComponent;
        if IsDefined(scanning) {
          scanning.SetIsScanned_Event(false);
        };
      };
      i += 1;
    };
    if IsDefined(player) {
      ApisK0Find.RemoveAll(game, player, ApisK0Find.Core());
      ApisK0Find.RemoveAll(game, player, ApisK0Find.Shard());
      ApisK0Find.RemoveAll(game, player, ApisK0Find.StashItems()[0]);
      ApisK0Find.RemoveAll(game, player, ApisK0Find.StashItems()[1]);
    };
    if !IsDefined(journal) {
      return count;
    };
    journal.ChangeEntryState(ApisK0Find.ShardEntryPath(), "gameJournalOnscreen", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ApikoMessagePath(), "gameJournalPhoneMessage", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ApikoConversationPath(), "gameJournalPhoneConversation", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ApikoContactPath(), "gameJournalContact", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.MappinPath(), "gameJournalQuestMapPin", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.InvestigatePath(), "gameJournalQuestObjective", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ObjectivePath(), "gameJournalQuestObjective", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.PhasePath(), "gameJournalQuestPhase", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.DescriptionPath(), "gameJournalQuestDescription", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.QuestPath(), "gameJournalQuest", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.MessagePath(), "gameJournalPhoneMessage", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ConversationPath(), "gameJournalPhoneConversation", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    journal.ChangeEntryState(ApisK0Find.ContactPath(), "gameJournalContact", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify);
    return count;
  }

  public static func HasCore(game: GameInstance, object: ref<GameObject>) -> Bool {
    return ApisK0Find.Count(game, object, ApisK0Find.Core()) > 0;
  }

  // How many items of this record the object holds. By record, not by ItemID: a non-stackable item (a quickhack)
  // gets a new ItemID on every GiveItem, so HasItem(ItemID.FromTDBID(...)) never finds it (the body got one more copy
  // every half second).
  public static func Count(game: GameInstance, object: ref<GameObject>, item: ItemID) -> Int32 {
    let items: array<wref<gameItemData>>;
    let record: TweakDBID = ItemID.GetTDBID(item);
    let count: Int32 = 0;
    let i: Int32 = 0;
    if !IsDefined(object) || !GameInstance.GetTransactionSystem(game).GetItemList(object, items) {
      return 0;
    };
    while i < ArraySize(items) {
      if IsDefined(items[i]) && ItemID.GetTDBID(items[i].GetID()) == record {
        count += Max(1, items[i].GetQuantity());
      };
      i += 1;
    };
    return count;
  }

  // Every item of this record out of the object (by record, see Count).
  public static func RemoveAll(game: GameInstance, object: ref<GameObject>, item: ItemID) -> Void {
    let ts: ref<TransactionSystem> = GameInstance.GetTransactionSystem(game);
    let items: array<wref<gameItemData>>;
    let ids: array<ItemID>;
    let record: TweakDBID = ItemID.GetTDBID(item);
    let i: Int32 = 0;
    if !IsDefined(object) {
      return;
    };
    ts.GetItemList(object, items);
    while i < ArraySize(items) {
      if IsDefined(items[i]) && ItemID.GetTDBID(items[i].GetID()) == record {
        ArrayPush(ids, items[i].GetID());
      };
      i += 1;
    };
    i = 0;
    while i < ArraySize(ids) {
      ts.RemoveItem(object, ids[i], ts.GetItemQuantity(object, ids[i]));
      i += 1;
    };
  }

  // Exactly one item of this record in the object: given if missing, extra copies removed.
  public static func EnsureOne(game: GameInstance, object: ref<GameObject>, item: ItemID) -> Void {
    let ts: ref<TransactionSystem> = GameInstance.GetTransactionSystem(game);
    let items: array<wref<gameItemData>>;
    let extra: array<ItemID>;
    let record: TweakDBID = ItemID.GetTDBID(item);
    let found: Bool = false;
    let i: Int32 = 0;
    if !IsDefined(object) {
      return;
    };
    ts.GetItemList(object, items);
    while i < ArraySize(items) {
      if IsDefined(items[i]) && ItemID.GetTDBID(items[i].GetID()) == record {
        if found {
          ArrayPush(extra, items[i].GetID());
        };
        found = true;
      };
      i += 1;
    };
    if !found {
      ts.GiveItem(object, item, 1);
      return;
    };
    i = 0;
    while i < ArraySize(extra) {
      ts.RemoveItem(object, extra[i], 1);
      i += 1;
    };
  }

  // The case's entity if it is streamed in, or null (a static entity's id is its node's hash).
  public static func FindCache(game: GameInstance) -> ref<GameObject> {
    return ApisK0Find.FindByRef(game, ApisK0Find.CacheRef());
  }

  public static func FindNetrunner(game: GameInstance) -> ref<GameObject> {
    return ApisK0Find.FindByRef(game, ApisK0Find.NetrunnerRef());
  }

  public static func FindByRef(game: GameInstance, path: String) -> ref<GameObject> {
    return GameInstance.FindEntityByID(game, ApisK0Find.IdOf(path)) as GameObject;
  }

  public static func IdOf(path: String) -> EntityID {
    return Cast<EntityID>(CreateNodeRef(path));
  }

  // The optional objective is done.
  public static func Investigated(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let entry: wref<JournalEntry>;
    if !IsDefined(journal) {
      return false;
    };
    entry = journal.GetEntryByString(ApisK0Find.InvestigatePath(), "gameJournalQuestObjective");
    return IsDefined(entry) && Equals(journal.GetEntryState(entry), gameJournalEntryState.Succeeded);
  }

  public static func CompleteInvestigation(game: GameInstance) -> Void {
    GameInstance.GetJournalManager(game).ChangeEntryState(ApisK0Find.InvestigatePath(), "gameJournalQuestObjective", gameJournalEntryState.Succeeded, JournalNotifyOption.Notify);
  }

  // The optional objective, as the UI asks: its journal "optional" flag (make_world.py) does not reach the native
  // JournalManager.GetIsObjectiveOptional (no setter either), so the wraps below ask this too.
  public static func IsOptionalObjective(entry: wref<JournalEntry>) -> Bool {
    let journal: ref<JournalManager>;
    let ours: wref<JournalEntry>;
    if !IsDefined(entry) || NotEquals(entry.GetId(), "investigate") {
      return false;
    };
    journal = GameInstance.GetJournalManager(GetGameInstance());
    if !IsDefined(journal) {
      return false;
    };
    ours = journal.GetEntryByString(ApisK0Find.InvestigatePath(), "gameJournalQuestObjective");
    return IsDefined(ours) && journal.GetEntryHash(ours) == journal.GetEntryHash(entry);
  }

  // Kessler's body as scanned (blue in focus mode): its clue inspected, saved in its persistent state. His clue is
  // not inspected by the scan (make_world.py, BODIES) but when V reads his shard.
  public static func InspectClue(object: ref<GameObject>, opt undo: Bool) -> Void {
    let evt: ref<ToggleFocusClueEvent> = new ToggleFocusClueEvent();
    evt.clueIndex = 0;
    evt.isEnabled = true;
    evt.investigationState = undo ? EFocusClueInvestigationState.NOT_INSPECTED : EFocusClueInvestigationState.INSPECTED;
    evt.updatePS = true;
    object.QueueEvent(evt);
  }

  // V has read the netrunner's shard (reading a shard activates its journal entry).
  public static func ShardRead(game: GameInstance) -> Bool {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
    let entry: wref<JournalEntry>;
    if !IsDefined(journal) {
      return false;
    };
    entry = journal.GetEntryByString(ApisK0Find.ShardEntryPath(), "gameJournalOnscreen");
    return IsDefined(entry) && Equals(journal.GetEntryState(entry), gameJournalEntryState.Active);
  }

  // The localization key of an agent's name if the entity is one of the agents' bodies, else None.
  public static func AgentNameKey(id: EntityID) -> CName {
    if Equals(id, ApisK0Find.IdOf(ApisK0Find.NetrunnerRef())) {
      return n"apisk0-kessler";
    };
    if Equals(id, ApisK0Find.IdOf(ApisK0Find.Netrunner2Ref())) {
      return n"apisk0-ortega";
    };
    return n"None";
  }

  // A notice text by localization key, with the key itself if the text is missing.
  public static func Text(key: CName) -> String {
    let text: String = GetLocalizedTextByKey(key);
    return StrLen(text) > 0 ? text : NameToString(key);
  }
}

// Scanning an agent's body: its name in the scanner's header, localized. A body container's displayName shows raw
// there ("LOCKEY#APISK0-KESSLER" with our key); its rows come from the body's scan description (make_world.py,
// BODIES). Only called when V scans something, unlike the per-entity callbacks that crashed the game when wrapped.
@wrapMethod(GameObject)
public const func CompileScannerChunks() -> Bool {
  let result: Bool = wrappedMethod();
  let key: CName = ApisK0Find.AgentNameKey(this.GetEntityID());
  let blackboard: wref<IBlackboard>;
  let chunk: ref<ScannerName>;
  let name: String;
  if IsNameValid(key) {
    blackboard = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_ScannerModules);
    if IsDefined(blackboard) {
      name = GetLocalizedTextByKey(key);
      chunk = new ScannerName();
      chunk.Set(name);
      blackboard.SetVariant(GetAllBlackboardDefs().UI_ScannerModules.ScannerName, ToVariant(chunk), true);
    };
  };
  return result;
}

// V calls APIKO from the phone: an audio call (vanilla makes every contact call a holocall, and Apiko has no face).
@wrapMethod(NewHudPhoneGameController)
public final func CallSelectedContact(contactData: wref<ContactData>) -> Void {
  let request: ref<questTriggerCallRequest>;
  if IsDefined(contactData) && Equals(StringToName(contactData.contactId), ApisK0Find.ApikoContact()) {
    request = new questTriggerCallRequest();
    request.addressee = ApisK0Find.ApikoContact();
    request.caller = n"Player";
    request.callPhase = questPhoneCallPhase.IncomingCall;
    request.callMode = questPhoneCallMode.Audio;
    GameInstance.GetScriptableSystemsContainer(GetGameInstance()).Get(n"PhoneSystem").QueueRequest(request);
    return;
  };
  wrappedMethod(contactData);
}

// The optional objective in the UI (ApisK0Find.IsOptionalObjective): "[Optional]" and the optional group (green).
// HUD tracker line.
@wrapMethod(QuestTrackerObjectiveLogicController)
public final func SetData(const objectiveTitle: script_ref<String>, isTracked: Bool, isOptional: Bool, currentCounter: Int32, totalCounter: Int32, objectiveEntry: wref<JournalQuestObjective>, isQuestType: Bool) -> Void {
  wrappedMethod(objectiveTitle, isTracked, isOptional || ApisK0Find.IsOptionalObjective(objectiveEntry), currentCounter, totalCounter, objectiveEntry, isQuestType);
}

// HUD tracker: lines are spawned in the native objective order (by timestamp), which put the optional one on top.
// It goes below the others.
// (The first version moved it to the last index and it stayed on top: the panel may draw its children backwards.)
@wrapMethod(QuestTrackerGameController)
private final func UpdateTrackerData() -> Void {
  let panel: ref<inkCompoundWidget>;
  let count: Int32;
  let i: Int32;
  let target: Int32;
  let widget: wref<inkWidget>;
  let controller: ref<QuestTrackerObjectiveLogicController>;
  wrappedMethod();
  panel = inkCompoundRef.Get(this.m_ObjectiveContainer) as inkCompoundWidget;
  if !IsDefined(panel) {
    return;
  };
  count = panel.GetNumChildren();
  // The bottom line on screen: the last child, or the first one in a panel drawn backwards.
  target = Equals(panel.GetChildOrder(), inkEChildOrder.Backward) ? 0 : count - 1;
  i = 0;
  while i < count {
    widget = panel.GetWidgetByIndex(i);
    controller = widget.GetController() as QuestTrackerObjectiveLogicController;
    if IsDefined(controller) && ApisK0Find.IsOptionalObjective(controller.GetObjectiveEntry()) {
      if i != target {
        panel.ReorderChild(widget, target);
        ApisK0System.Get(GetGameInstance()).DebugNote("tracker: optional line " + IntToString(i) + " -> " + IntToString(target) + " of " + IntToString(count) + (target == 0 ? " (backward panel)" : ""));
      };
      return;
    };
    i += 1;
  };
}

// HUD quest list: its optional list and header, and the entry's text.
@addField(QuestListGameController)
private let m_apisK0Optional: Bool;

@wrapMethod(QuestListGameController)
private final func UpdateObjectives(questData: ref<QuestDataWrapper>, parent: wref<ObjectiveEntryLogicController>, isParentTracked: Bool) -> Bool {
  let result: Bool = wrappedMethod(questData, parent, isParentTracked);
  let objectives: array<ref<QuestObjectiveWrapper>>;
  let i: Int32;
  if result {
    return true;
  };
  objectives = questData.GetObjectives();
  i = 0;
  while i < ArraySize(objectives) {
    if Equals(objectives[i].GetStatus(), gameJournalEntryState.Active) && ApisK0Find.IsOptionalObjective(objectives[i].GetQuestObjective()) {
      return true;
    };
    i += 1;
  };
  return false;
}

@wrapMethod(QuestListGameController)
private final func UpdateObjective(objectiveData: ref<QuestObjectiveWrapper>, parent: wref<ObjectiveEntryLogicController>, isParentTracked: Bool) -> Void {
  this.m_apisK0Optional = ApisK0Find.IsOptionalObjective(objectiveData.GetQuestObjective());
  wrappedMethod(objectiveData, parent, isParentTracked);
  this.m_apisK0Optional = false;
}

@wrapMethod(QuestListGameController)
private final func GetOrCreateEntry(id: Int32, entryType: UIObjectiveEntryType, parent: wref<ObjectiveEntryLogicController>, opt isOptional: Bool) -> wref<ObjectiveEntryLogicController> {
  let ours: Bool = this.m_apisK0Optional && Equals(entryType, UIObjectiveEntryType.Objective);
  if ours && !IsDefined(this.FindEntry(id)) {
    ApisK0System.Get(GetGameInstance()).DebugNote("quest list: optional entry created");
  };
  return wrappedMethod(id, entryType, parent, isOptional || ours);
}

@wrapMethod(QuestListGameController)
private final func BuildEntryData(inData: ref<ABaseWrapper>) -> UIObjectiveEntryData {
  let data: UIObjectiveEntryData = wrappedMethod(inData);
  let objective: ref<QuestObjectiveWrapper> = inData as QuestObjectiveWrapper;
  if IsDefined(objective) && ApisK0Find.IsOptionalObjective(objective.GetQuestObjective()) {
    data.m_isOptional = true;
  };
  return data;
}

// Journal: the quest's objective line.
@addField(QuestDetailsObjectiveController)
public let m_apisK0Optional: Bool;

@wrapMethod(QuestDetailsObjectiveController)
public final func Setup(objective: wref<JournalQuestObjective>, journalManager: wref<JournalManager>, currentCounter: Int32, totalCounter: Int32, opt isTracked: Bool) -> Void {
  let title: String;
  wrappedMethod(objective, journalManager, currentCounter, totalCounter, isTracked);
  this.m_apisK0Optional = ApisK0Find.IsOptionalObjective(objective);
  if this.m_apisK0Optional && !journalManager.GetIsObjectiveOptional(objective) {
    title = objective.GetDescription();
    if totalCounter > 0 {
      title = GetLocalizedText(title) + " [" + IntToString(currentCounter) + "/" + IntToString(totalCounter) + "]";
    };
    title = GetLocalizedText(title) + " [" + GetLocalizedText("UI-ScriptExports-Optional0") + "]";
    inkTextRef.SetText(this.m_objectiveName, title);
  };
}

// Journal: objectives come in the native JournalManager.GetChildren order, which put the optional one first. It goes
// last (with its action links, if it ever has any: the widgets after it until the next objective).
@wrapMethod(QuestDetailsPanelController)
private final func PopulateObjectives() -> Void {
  let count: Int32;
  let i: Int32;
  let start: Int32 = -1;
  let moved: Int32;
  let controller: ref<QuestDetailsObjectiveController>;
  wrappedMethod();
  count = inkCompoundRef.GetNumChildren(this.m_activeObjectives);
  i = 0;
  while i < count && start < 0 {
    controller = inkCompoundRef.GetWidgetByIndex(this.m_activeObjectives, i).GetController() as QuestDetailsObjectiveController;
    if IsDefined(controller) && controller.m_apisK0Optional {
      start = i;
    };
    i += 1;
  };
  if start < 0 {
    return;
  };
  // The optional line and what follows it up to the next objective line, moved to the end in order.
  moved = 0;
  while start < count - moved {
    controller = inkCompoundRef.GetWidgetByIndex(this.m_activeObjectives, start).GetController() as QuestDetailsObjectiveController;
    if moved > 0 && IsDefined(controller) {
      return;
    };
    inkCompoundRef.ReorderChild(this.m_activeObjectives, inkCompoundRef.GetWidgetByIndex(this.m_activeObjectives, start), count - 1);
    moved += 1;
  };
}

// Old journal layout (questLogElements), in case.
@wrapMethod(ObjectiveController)
public final func Setup(data: ref<ABaseQuestObjectiveWrapper>, isOptional: Bool) -> Void {
  let objective: ref<QuestObjectiveWrapper> = data as QuestObjectiveWrapper;
  wrappedMethod(data, isOptional || IsDefined(objective) && ApisK0Find.IsOptionalObjective(objective.GetQuestObjective()));
}
