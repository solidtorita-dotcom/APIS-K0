// APIS-K0 - Apiko, a Blackwall AI fragment trapped in a Zetatech Bombus drone.
// Phase 1: once unlocked, the drone always exists next to V and follows with the vanilla follower AI
// (AIFollowerRole, like the cut Flathead companion). The Bombus flies slowly, so it catches up the way
// vanilla human followers do (FollowerTasks.swift): its individual time dilation rises with the
// distance to V. It is removed while V is in a vehicle and spawned again when V gets out, and
// teleported back if it falls too far behind. It can't be destroyed.
// Teleporting the drone every frame (tried before) does not work: it flickers and stays in place.
// The drone is spawned through Codeware's DynamicEntitySystem and is NOT saved with the game:
// only the unlock flag is persistent, and the drone is spawned again after every load.
module ApisK0

import Codeware.Localization.*

public abstract class ApisK0Config {
  public static func RecordID() -> TweakDBID { return t"Character.ApisK0"; }
  public static func Tag() -> CName { return n"ApisK0"; }
  // White nanny Bombus (the one with a face). Appearance names are from av_zetatech_bombus__basic.ent.
  // Also set in apis_k0.yaml (appearanceName).
  public static func Appearance() -> CName { return n"zetatech_bombus__basic_nanny_drone_white"; }
  // Seconds between updates.
  public static func TickInterval() -> Float { return 0.25; }
  // Catch-up: normal speed up to MinCatchUpDistance meters from V, MaxSpeedFactor at MaxCatchUpDistance.
  // The follow actions in apis_k0_follow.yaml keep 1.5 m (+-0.5) from V.
  public static func MinCatchUpDistance() -> Float { return 3.0; }
  public static func MaxCatchUpDistance() -> Float { return 12.0; }
  public static func MaxSpeedFactor() -> Float { return 4.0; }
  // Flying height change (meters, negative = lower). Vanilla drone actions use +-0.45.
  // Spawning in mid-air (fixed now) may have been why it flew high, so this is only a small trim.
  public static func AltitudeOffset() -> Float { return -0.25; }
  // Farther than this (meters) and the drone is teleported back behind V.
  public static func LeashDistance() -> Float { return 40.0; }
  // Where the drone appears or is put back: about this many meters behind V, on the navmesh.
  public static func PlaceBack() -> Float { return 2.5; }
  // Seconds to wait for a requested spawn before requesting it again.
  public static func SpawnRetryDelay() -> Float { return 5.0; }
  // Apiko at home (sent away): it waits at one of these spots in V's apartment in Megabuilding H10 (floor points,
  // picked by the user in the game on 2026-11-08, all inside Districts.VApartment) while V is this close to one.
  public static func HomeRadius() -> Float { return 40.0; }
  public static func HomeSpotCount() -> Int32 { return 4; }
  // V walked out without it: it stays where V left it until V is this far from it, or this long.
  public static func HomeLingerDistance() -> Float { return 6.0; }
  public static func HomeLingerSeconds() -> Float { return 20.0; }
  // At most one greeting per this many seconds when V comes home.
  public static func HomeGreetCooldown() -> Float { return 60.0; }
  public static func HomeSpot(i: Int32) -> Vector4 {
    switch i {
      case 1:
        return new Vector4(-1379.54, 1267.49, 122.66, 1.0);
      case 2:
        return new Vector4(-1384.13, 1268.22, 123.07, 1.0);
      case 3:
        return new Vector4(-1386.11, 1273.44, 123.07, 1.0);
      default:
        return new Vector4(-1380.68, 1273.70, 123.06, 1.0);
    };
  }
  // Seconds between checks of the follower role.
  public static func SetupInterval() -> Float { return 1.0; }
}

public class ApisK0System extends ScriptableSystem {
  // True once V has found and woken the drone. Phase 1: toggled with the CET debug hotkey.
  private persistent let m_unlocked: Bool;
  // Apiko's memory belongs to the save (DISENO.md, "memoria por partida"): the version the bridge gave it (0 = none
  // yet) and a copy of the memory itself, UTF-8 bytes packed four per Int32 by the CET side (the bridge restores it
  // when it has no snapshot of that version). Persistent strings are not an option: the game saves none.
  private persistent let m_memoryVersion: Int32;
  private persistent let m_memoryBlob: array<Int32>;
  private persistent let m_memoryLength: Int32;
  // Apiko has been woken at least once in this save (the first wake starts its memory from scratch).
  private persistent let m_everWoken: Bool;
  // The find: V has taken the dead netrunner's shard (ApisK0Find.reds), so it is not put back in his body.
  private persistent let m_shardTaken: Bool;
  // The find: V has taken the hidden netrunner's quickhacks, so they are not put back in her body.
  private persistent let m_stashTaken: Bool;
  // The find: the beacon keeps calling V until V answers (then the text and the quest come).
  private persistent let m_beaconCalling: Bool;
  // The find starts by itself (UpdateTrigger): V has been in the Badlands since m_badlandsSince (while
  // m_inBadlands), after the prologue; the next check.
  private let m_inBadlands: Bool;
  private let m_badlandsSince: Float;
  private let m_nextTriggerCheck: Float;
  private let m_spawnRequestTime: Float;
  private let m_nextSetupTime: Float;
  // The find (ApisK0Find.reds): the next check, and the chip's upload (UpdateUpload: running, start, steps done).
  private let m_nextFindCheck: Float;
  // The site hidden before the quest (UpdateScene): ids of the hidden objects, and the components turned off.
  private let m_sceneHidden: array<EntityID>;
  private let m_hiddenComponents: array<wref<IComponent>>;
  private let m_uploading: Bool;
  private let m_uploadStart: Float;
  private let m_uploadStep: Int32;
  // The upload with Apiko's voice in V's head (bridge running when it started), the bridge's "head_done" cue, when the
  // last heavy glitch ends, and whether the bridge is running (set by the CET side).
  private let m_uploadVoiced: Bool;
  private let m_headDone: Bool;
  private let m_headFinishAt: Float;
  private let m_bridgeOnline: Bool;
  // The beacon's call (UpdateBeaconCall): ringing, the phone showed it ringing, when it started, when V answered (-1:
  // not answered), when to call again.
  private let m_callRinging: Bool;
  private let m_callSawRing: Bool;
  private let m_callStart: Float;
  private let m_callAnsweredAt: Float;
  private let m_nextCallAt: Float;
  // The answered call with voice (bridge running when V answered): NetWatch's recording and Apiko's line, until the
  // bridge's "beacon_done" cue.
  private let m_beaconVoiced: Bool;
  // A development install (SetDev, from the CET side): debug lines are queued for CET's log.
  private let m_dev: Bool;
  private let m_beaconDone: Bool;
  // Apiko sent away by V (the bridge's "leave" cue, V asked it to go): it stays in V's apartment in Megabuilding H10
  // (decided 2026-11-08). Out of it: no drone, no events, silence until V calls the APIKO contact. Saved with the game.
  private persistent let m_away: Bool;
  // Away, and V is in the apartment with it (Update): the drone is there and follows V inside, it can be talked to,
  // and V can tell it to come along (the bridge's "follow" cue). Leaving the apartment leaves it there.
  private let m_atHomeWithV: Bool;
  // Its spot in the apartment (ApisK0Config.HomeSpot), where it waits when V comes near, so it is already inside when
  // V opens the door: one picked at random each time it settles (V comes near, or V walks out). m_homeSettled: the
  // drone in the world is the one spawned at that spot (not the one that followed V: that one is removed, since
  // teleporting this drone does nothing, and it spawns again at a spot).
  private let m_homeIndex: Int32;
  private let m_homeSettled: Bool;
  // When V walked out leaving the drone that followed it (-1: not now; UpdateHomeWait), and the last greeting.
  private let m_leftHomeAt: Float;
  private let m_homeGreetAt: Float;
  // V's call to APIKO (UpdateApikoCall): ringing or talking, answered, when, the bridge's "call_done" cue.
  private let m_apikoCalling: Bool;
  private let m_apikoCallStart: Float;
  private let m_apikoCallAnswered: Bool;
  private let m_apikoCallAnsweredAt: Float;
  private let m_apikoCallDone: Bool;
  // Bumped on every player attach / restart so callbacks from an older loop stop by themselves.
  private let m_generation: Int32;
  // Debug: state changes and a periodic report, pulled and printed by the CET side.
  private let m_state: String;
  private let m_nextReportTime: Float;
  private let m_debugLines: array<String>;
  // Phase 2: game side of the conversation (state, events, subtitles). See ApisK0Chat.reds.
  private let m_chat: ref<ApisK0Chat>;
  // Phase 4: devices Apiko perceives and V's actions on them. See ApisK0Devices.reds.
  private let m_devices: ref<ApisK0Devices>;
  // Phase 4: enemies Apiko perceives, V's kills, warnings. See ApisK0Enemies.reds.
  private let m_enemies: ref<ApisK0Enemies>;
  // Phase 4: tracked quest, conversations V hears, news, text messages. See ApisK0Story.reds.
  private let m_story: ref<ApisK0Story>;
  // Phase 4: civilians, police, wanted level, named characters, companions. See ApisK0People.reds.
  private let m_people: ref<ApisK0People>;
  // Phase 4: other fights, bodies, notable loot, vehicles. See ApisK0Surroundings.reds.
  private let m_surroundings: ref<ApisK0Surroundings>;

  // Between the player's attach and detach (OnPlayerAttach / Release).
  private let m_inSession: Bool;

  public static func Get(game: GameInstance) -> ref<ApisK0System> {
    return GameInstance.GetScriptableSystemsContainer(game).Get(n"ApisK0.ApisK0System") as ApisK0System;
  }

  private func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    this.m_inSession = true;
    this.Chat().Reset();
    this.Devices().Reset(this.Now());
    this.Enemies().Reset();
    this.Story().Reset(this.Now());
    this.People().Reset();
    this.Surroundings().Reset();
    // An upload cut short by a load starts again (V still has the chip and the objective is still open).
    this.m_uploading = false;
    // A beacon call cut short by a load: it rings again a bit after the load.
    this.m_callRinging = false;
    this.m_callAnsweredAt = -1.0;
    this.m_nextCallAt = this.Now() + 10.0;
    // A call to APIKO cut short by a load is over.
    this.m_apikoCalling = false;
    // The drone is spawned anew after a load: nothing left at the door.
    this.m_leftHomeAt = -1.0;
    this.m_homeSettled = false;
    this.RestartLoop();
  }

  // Session end (a load, or quitting to the menu): stop the loop and let go of every game object and listener, so
  // nothing of ours keeps entities of the old world alive while it is torn down.
  private func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    this.Release();
  }

  private func OnDetach() -> Void {
    this.Release();
  }

  // A save is loaded and V is in the world (CET tells the bridge: Apiko is never heard outside a session).
  public func IsInSession() -> Bool {
    return this.m_inSession;
  }

  private func Release() -> Void {
    this.m_inSession = false;
    this.m_generation += 1;
    if IsDefined(this.m_enemies) {
      this.m_enemies.Release();
    };
    if IsDefined(this.m_surroundings) {
      this.m_surroundings.Release();
    };
    if IsDefined(this.m_devices) {
      this.m_devices.Reset(0.0);
    };
    if IsDefined(this.m_story) {
      this.m_story.Unregister();
    };
  }

  private func Chat() -> ref<ApisK0Chat> {
    if !IsDefined(this.m_chat) {
      this.m_chat = ApisK0Chat.Create(this.GetGameInstance());
    };
    return this.m_chat;
  }

  private func Devices() -> ref<ApisK0Devices> {
    if !IsDefined(this.m_devices) {
      this.m_devices = ApisK0Devices.Create(this.GetGameInstance());
    };
    return this.m_devices;
  }

  private func Enemies() -> ref<ApisK0Enemies> {
    if !IsDefined(this.m_enemies) {
      this.m_enemies = ApisK0Enemies.Create(this.GetGameInstance());
    };
    return this.m_enemies;
  }

  private func Story() -> ref<ApisK0Story> {
    if !IsDefined(this.m_story) {
      this.m_story = ApisK0Story.Create(this.GetGameInstance());
    };
    return this.m_story;
  }

  private func People() -> ref<ApisK0People> {
    if !IsDefined(this.m_people) {
      this.m_people = ApisK0People.Create(this.GetGameInstance());
    };
    return this.m_people;
  }

  private func Surroundings() -> ref<ApisK0Surroundings> {
    if !IsDefined(this.m_surroundings) {
      this.m_surroundings = ApisK0Surroundings.Create(this.GetGameInstance());
    };
    return this.m_surroundings;
  }

  // The spawned drone, or null.
  private func Drone() -> ref<GameObject> {
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    if !IsDefined(des) || !des.IsPopulated(ApisK0Config.Tag()) {
      return null;
    };
    return des.GetEntity(des.GetTaggedID(ApisK0Config.Tag())) as GameObject;
  }

  public func IsUnlocked() -> Bool {
    return this.m_unlocked;
  }

  // Development (CET hotkeys): start the find (beacon text + quest) or put its journal entries back to inactive.
  public func DebugStartFind() -> Void {
    this.StartBeacon();
  }

  // The find starts by itself once the prologue is over ("Playing for Time" done) and V has spent
  // ApisK0Find.TriggerSeconds() in the Badlands: the beacon calls. Only in a save where Apiko was never found
  // (no quest, no chip, never woken); a beacon call cut by a save and reload goes on through m_beaconCalling.
  private func UpdateTrigger(now: Float) -> Void {
    let game: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let district: wref<District>;
    if this.m_beaconCalling || this.m_unlocked || this.m_uploading || this.m_everWoken || !IsDefined(player) {
      this.m_inBadlands = false;
      return;
    };
    if now < this.m_nextTriggerCheck {
      return;
    };
    this.m_nextTriggerCheck = now + 1.0;
    if GameInstance.GetQuestsSystem(game).GetFact(ApisK0Find.PrologueDoneFact()) == 0 || ApisK0Find.QuestStarted(game)
      || ApisK0Find.HasCore(game, player) {
      this.m_inBadlands = false;
      return;
    };
    district = player.GetPreventionSystem().GetCurrentDistrict();
    if !IsDefined(district) || !district.IsBadlands() {
      this.m_inBadlands = false;
      return;
    };
    if !this.m_inBadlands {
      this.m_inBadlands = true;
      this.m_badlandsSince = now;
      this.Debug("find trigger: V in the Badlands after the prologue");
      return;
    };
    if now - this.m_badlandsSince >= ApisK0Find.TriggerSeconds() {
      this.m_inBadlands = false;
      this.StartBeacon();
    };
  }

  // The find starts: the beacon calls V (again and again until V answers; UpdateBeaconCall).
  private func StartBeacon() -> Void {
    let journal: ref<JournalManager> = GameInstance.GetJournalManager(this.GetGameInstance());
    if !IsDefined(journal) || !IsDefined(journal.GetEntryByString(ApisK0Find.QuestPath(), "gameJournalQuest")) {
      this.ShowNotice("APIS-K0: find entries missing (ApisK0.archive / ArchiveXL)", 6.0);
      return;
    };
    this.Debug("find started: the beacon calls V");
    this.m_beaconCalling = true;
    this.m_callRinging = false;
    this.m_callAnsweredAt = -1.0;
    this.m_nextCallAt = 0.0;
  }

  // The beacon's call: it rings (when V can take a call) and rings again 5 s after V rejects or lets it ring out.
  // When V answers: glitches and static (vanilla), with the bridge running NetWatch's recording cut off by Apiko
  // (until its "beacon_done" cue), then the call ends, the text arrives and the quest starts.
  private func UpdateBeaconCall(now: Float) -> Void {
    let game: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let state: Int32;
    if !this.m_beaconCalling || !IsDefined(player) {
      return;
    };
    state = GameInstance.GetQuestsSystem(game).GetFactStr(ApisK0Find.BeaconCallFact());
    if this.m_callAnsweredAt >= 0.0 {
      if this.m_beaconVoiced ? (this.m_beaconDone || now - this.m_callAnsweredAt >= ApisK0Find.BeaconVoicedTimeout())
          : (now - this.m_callAnsweredAt >= ApisK0Find.BeaconAnsweredSeconds()) {
        this.m_beaconVoiced = false;
        ApisK0Find.BeaconCall(game, questPhoneCallPhase.EndCall);
        GameObjectEffectHelper.BreakEffectLoopEvent(player, ApisK0Find.GlitchLow());
        GameObject.PlaySoundEvent(player, ApisK0Find.BeaconStaticStop());
        this.m_beaconCalling = false;
        this.m_callRinging = false;
        this.m_callAnsweredAt = -1.0;
        ApisK0Find.Start(game);
        this.Debug("beacon call over: text and quest");
      };
      return;
    };
    if this.m_callRinging {
      if state == 1 {
        this.m_callSawRing = true;
      };
      if state == 2 {
        this.Debug("beacon call answered");
        // Picked up, as a quest's call node does: the HUD leaves the incoming call (name and answer/reject keys) for
        // the call box with the caller's avatar.
        ApisK0Find.BeaconCall(game, questPhoneCallPhase.StartCall);
        this.m_callAnsweredAt = now;
        this.m_beaconVoiced = this.m_bridgeOnline;
        this.m_beaconDone = false;
        if this.m_beaconVoiced {
          this.Chat().PushEvent("beacon_call");
        };
        GameObjectEffectHelper.StartEffectEvent(player, ApisK0Find.GlitchLow());
        GameObjectEffectHelper.StartEffectEvent(player, ApisK0Find.BeaconInterference());
        GameObjectEffectHelper.StartEffectEvent(player, ApisK0Find.BeaconBlackwall());
        GameObject.PlaySoundEvent(player, ApisK0Find.BeaconStatic());
        return;
      };
      if this.m_callSawRing && (state == 0 || state == 3) || now - this.m_callStart > ApisK0Find.BeaconRingTimeout() {
        this.Debug("beacon call not answered (" + IntToString(state) + ")");
        // Hung up, as a quest's call node does: otherwise the HUD keeps the incoming call on screen.
        ApisK0Find.BeaconCall(game, questPhoneCallPhase.EndCall);
        this.m_callRinging = false;
        this.m_nextCallAt = now + ApisK0Find.BeaconRetrySeconds();
      };
      return;
    };
    if now >= this.m_nextCallAt && ApisK0Find.CanCall(game, player) {
      ApisK0Find.BeaconCall(game, questPhoneCallPhase.IncomingCall);
      this.m_callRinging = true;
      this.m_callSawRing = false;
      this.m_callStart = now;
    };
  }

  // Development (CET "Dev: place ..." hotkeys): a preview of one of the find's objects at a spot, replacing its
  // previous preview. The orientation is built as tools\make_world.py builds it for the sector (yaw about Z), so the
  // preview shows what the archive will place. Not saved with the game. Only reachable from a development install.
  public func DevPreview(name: String, template: String, appearance: String, x: Float, y: Float, z: Float, yaw: Float) -> Void {
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    let tag: CName = StringToName("ApisK0Preview_" + name);
    let spec: ref<DynamicEntitySpec> = new DynamicEntitySpec();
    let half: Float = Deg2Rad(yaw) / 2.0;
    if !IsDefined(des) {
      return;
    };
    des.DeleteTagged(tag);
    spec.templatePath = ResRef.FromString(template);
    spec.appearanceName = StringToName(appearance);
    spec.position = new Vector4(x, y, z, 1.0);
    spec.orientation = new Quaternion(0.0, 0.0, SinF(half), CosF(half));
    spec.alwaysSpawned = true;
    spec.persistState = false;
    spec.persistSpawn = false;
    spec.tags = [tag];
    des.CreateEntity(spec);
  }

  public func DebugResetFind() -> Void {
    let objects: Int32 = ApisK0Find.Reset(this.GetGameInstance());
    // Back to a save that never found Apiko, so the find can start again on its own (UpdateTrigger).
    if this.m_unlocked {
      this.m_unlocked = false;
      this.Despawn();
    };
    this.m_uploading = false;
    this.m_inBadlands = false;
    this.m_shardTaken = false;
    this.m_stashTaken = false;
    this.m_everWoken = false;
    this.m_away = false;
    this.m_beaconCalling = false;
    this.m_callRinging = false;
    this.m_callAnsweredAt = -1.0;
    this.m_beaconVoiced = false;
    this.ShowMessage("APIS-K0: find reset (" + IntToString(objects) + "/4 site objects in range)");
  }

  // Phase 1 debug (CET hotkey): wake the drone or remove it.
  public func DebugToggle() -> Void {
    if !this.m_unlocked {
      this.ShowMessage("APIS-K0: online");
      this.Wake();
    } else {
      this.m_unlocked = false;
      this.Despawn();
      this.ShowMessage("APIS-K0: offline");
    };
  }

  // The find, while V is near the case: the chip goes back in the case whenever V does not have it (the case keeps no
  // inventory in the save, and "Dev: reset find" takes it from V); once V has it, the upload starts.
  private func UpdateFind(now: Float) -> Void {
    let game: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let cache: ref<GameObject>;
    if now < this.m_nextFindCheck || !IsDefined(player) {
      return;
    };
    this.m_nextFindCheck = now + 0.5;
    if !this.UpdateScene(game, player) {
      return;
    };
    this.UpdateNetrunner(game, player);
    this.UpdateStash(game, player);
    this.UpdateShardRead(game, player);
    this.UpdateCaseEmptied(game, player);
    if this.m_unlocked || this.m_uploading {
      return;
    };
    if !ApisK0Find.IsSearching(game) {
      return;
    };
    if ApisK0Find.HasCore(game, player) {
      this.StartUpload(now);
      return;
    };
    if Vector4.Distance(player.GetWorldPosition(), ApisK0Find.CachePosition()) > ApisK0Find.NearDistance() {
      return;
    };
    cache = ApisK0Find.FindCache(game);
    if IsDefined(cache) {
      ApisK0Find.EnsureOne(game, cache, ApisK0Find.Core());
    };
  }

  // The site (case, van, bodies) is in the world from the start (an always-loaded sector) but hidden until V gets the
  // quest; from then on it stays. Objects are hidden as they stream in (150 m, out of sight) and shown at once if the
  // quest starts with V nearby. True once the quest has started (the site's contents may be filled).
  private func UpdateScene(game: GameInstance, player: ref<PlayerPuppet>) -> Bool {
    let refs: array<String>;
    let object: ref<GameObject>;
    let id: EntityID;
    let count: Int32;
    let i: Int32;
    if ApisK0Find.QuestStarted(game) {
      if ArraySize(this.m_sceneHidden) > 0 {
        i = 0;
        while i < ArraySize(this.m_hiddenComponents) {
          if IsDefined(this.m_hiddenComponents[i]) {
            this.m_hiddenComponents[i].Toggle(true);
          };
          i += 1;
        };
        ArrayClear(this.m_hiddenComponents);
        ArrayClear(this.m_sceneHidden);
        this.Debug("site shown");
      };
      return true;
    };
    if Vector4.Distance(player.GetWorldPosition(), ApisK0Find.CachePosition()) > ApisK0Find.NearDistance() + 30.0 {
      ArrayClear(this.m_sceneHidden);
      ArrayClear(this.m_hiddenComponents);
      return false;
    };
    // Hidden again on every check: components that attach late (a body's appearance) are caught too.
    refs = ApisK0Find.SceneRefs();
    i = 0;
    while i < ArraySize(refs) {
      id = ApisK0Find.IdOf(refs[i]);
      object = GameInstance.FindEntityByID(game, id) as GameObject;
      if !IsDefined(object) {
        ArrayRemove(this.m_sceneHidden, id);
      } else {
        count = ApisK0Find.Hide(object, this.m_hiddenComponents);
        if !ArrayContains(this.m_sceneHidden, id) {
          ArrayPush(this.m_sceneHidden, id);
        };
        if count > 0 {
          this.Debug("site hidden: " + refs[i] + ", " + IntToString(count) + " components");
        };
      };
      i += 1;
    };
    return false;
  }

  // The netrunner's shard goes in his body until V has taken it once (remembered in the save) or read it: a read
  // shard leaves the inventory, so "V does not have it" alone would refill the body for ever.
  private func UpdateNetrunner(game: GameInstance, player: ref<PlayerPuppet>) -> Void {
    let body: ref<GameObject>;
    if this.m_shardTaken {
      return;
    };
    if ApisK0Find.Count(game, player, ApisK0Find.Shard()) > 0 || ApisK0Find.ShardRead(game) {
      this.m_shardTaken = true;
      // Taken with Apiko already out: the warning comes a bit late (a written line, bridge: "find_shard_late").
      if this.m_unlocked {
        this.Chat().PushEvent("find_shard_late");
        this.Debug("shard taken after the first contact");
      };
      return;
    };
    if Vector4.Distance(player.GetWorldPosition(), ApisK0Find.CachePosition()) > ApisK0Find.NearDistance() {
      return;
    };
    body = ApisK0Find.FindNetrunner(game);
    if IsDefined(body) {
      ApisK0Find.EnsureOne(game, body, ApisK0Find.Shard());
    };
  }

  // V read Kessler's shard: the optional objective is done and his body shows as scanned (blue), now or when it
  // streams in again (the clue's state is saved with the body).
  private func UpdateShardRead(game: GameInstance, player: ref<PlayerPuppet>) -> Void {
    let body: ref<GameObject>;
    if !ApisK0Find.ShardRead(game) {
      return;
    };
    if !ApisK0Find.Investigated(game) {
      ApisK0Find.CompleteInvestigation(game);
      this.Debug("shard read: optional objective done");
    };
    if Vector4.Distance(player.GetWorldPosition(), ApisK0Find.CachePosition()) > ApisK0Find.NearDistance() {
      return;
    };
    body = ApisK0Find.FindNetrunner(game);
    if IsDefined(body) && !body.IsClueInspected() {
      ApisK0Find.InspectClue(body);
    };
  }

  // V took the link chip from the case: the case shows as scanned (blue), now or when it streams in again. Its clue is
  // not inspected by the scan (make_world.py, BODIES): yellow until then.
  private func UpdateCaseEmptied(game: GameInstance, player: ref<PlayerPuppet>) -> Void {
    let cache: ref<GameObject>;
    if !this.m_unlocked && !this.m_uploading && !ApisK0Find.HasCore(game, player) {
      return;
    };
    if Vector4.Distance(player.GetWorldPosition(), ApisK0Find.CachePosition()) > ApisK0Find.NearDistance() {
      return;
    };
    cache = ApisK0Find.FindCache(game);
    if IsDefined(cache) && !cache.IsClueInspected() {
      ApisK0Find.InspectClue(cache);
      this.Debug("chip taken: case inspected");
    };
  }

  // The hidden netrunner's quickhacks go in her body until V has taken any of them (remembered in the save).
  private func UpdateStash(game: GameInstance, player: ref<PlayerPuppet>) -> Void {
    let items: array<ItemID> = ApisK0Find.StashItems();
    let body: ref<GameObject>;
    let i: Int32;
    if this.m_stashTaken {
      return;
    };
    i = 0;
    while i < ArraySize(items) {
      if ApisK0Find.Count(game, player, items[i]) > 0 {
        this.m_stashTaken = true;
        return;
      };
      i += 1;
    };
    if Vector4.Distance(player.GetWorldPosition(), ApisK0Find.CachePosition()) > ApisK0Find.NearDistance() {
      return;
    };
    body = ApisK0Find.FindByRef(game, ApisK0Find.Netrunner2Ref());
    if !IsDefined(body) {
      return;
    };
    i = 0;
    while i < ArraySize(items) {
      ApisK0Find.EnsureOne(game, body, items[i]);
      i += 1;
    };
  }

  // The chip is taken: the upload starts, and with the bridge running Apiko speaks in V's head meanwhile (the written
  // first contact, bridge first_contact.json). Without the bridge, a short upload of fixed steps.
  private func StartUpload(now: Float) -> Void {
    this.Debug("chip taken: upload" + (this.m_bridgeOnline ? ", Apiko in V's head" : ", bridge offline"));
    this.m_uploading = true;
    this.m_uploadStart = now;
    this.m_uploadStep = 0;
    this.m_headDone = false;
    this.m_headFinishAt = -1.0;
    this.m_uploadVoiced = this.m_bridgeOnline;
    if this.m_uploadVoiced {
      this.Chat().PushEvent("first_contact_head");
    };
  }

  // The chip's upload: glitches growing over V's view, with notices, while Apiko speaks in V's head (until the
  // bridge's "head_done" cue, or a timeout); then a last heavy glitch, the quest is done and Apiko comes online in a
  // drone behind V (Wake). Quest and wake together: a load during the upload leaves the objective open.
  private func UpdateUpload(now: Float) -> Void {
    let player: ref<PlayerPuppet> = GetPlayer(this.GetGameInstance());
    let elapsed: Float = now - this.m_uploadStart;
    let finishing: Bool;
    if !this.m_uploading || !IsDefined(player) {
      return;
    };
    if this.m_uploadStep < 1 && elapsed >= ApisK0Find.UploadStep1() {
      this.m_uploadStep = 1;
      GameObjectEffectHelper.StartEffectEvent(player, ApisK0Find.GlitchLow());
      this.ShowNotice(ApisK0Find.Text(n"apisk0-upload-1"), 2.0);
    };
    if this.m_uploadStep < 2 && elapsed >= (this.m_uploadVoiced ? ApisK0Find.VoicedStep2() : ApisK0Find.UploadStep2()) {
      this.m_uploadStep = 2;
      GameObjectEffectHelper.StartEffectEvent(player, ApisK0Find.GlitchMedium());
      this.ShowNotice(ApisK0Find.Text(n"apisk0-upload-2"), 2.0);
    };
    // The last step: at a fixed time without the bridge; with it, when the voice in V's head is over.
    if this.m_uploadVoiced {
      finishing = this.m_headDone || elapsed >= ApisK0Find.VoicedTimeout();
    } else {
      finishing = elapsed >= ApisK0Find.UploadStep3();
    };
    if this.m_uploadStep < 3 && finishing {
      this.m_uploadStep = 3;
      this.m_headFinishAt = now + ApisK0Find.UploadDone() - ApisK0Find.UploadStep3();
      GameObjectEffectHelper.StartEffectEvent(player, ApisK0Find.GlitchHeavy());
      this.ShowNotice(ApisK0Find.Text(n"apisk0-upload-3"), 1.5);
    };
    if this.m_uploadStep >= 3 && now >= this.m_headFinishAt {
      GameObjectEffectHelper.BreakEffectLoopEvent(player, ApisK0Find.GlitchLow());
      GameObjectEffectHelper.BreakEffectLoopEvent(player, ApisK0Find.GlitchMedium());
      GameObjectEffectHelper.BreakEffectLoopEvent(player, ApisK0Find.GlitchHeavy());
      this.m_uploading = false;
      ApisK0Find.Complete(this.GetGameInstance());
      this.Debug("upload done: Apiko online");
      this.Wake(this.m_uploadVoiced);
    };
  }

  // From the CET side: a cue in the bridge's replies ("head_done": Apiko finished speaking in V's head).
  // "leave": V sent Apiko away and its parting line has sounded. "call_done": Apiko's line on V's call has sounded.
  public func OnBridgeCue(cue: String) -> Void {
    if Equals(cue, "head_done") {
      this.m_headDone = true;
    };
    if Equals(cue, "beacon_done") {
      this.m_beaconDone = true;
    };
    if Equals(cue, "leave") && this.m_unlocked && !this.m_away {
      this.m_away = true;
      // Told to stay while at home: it stays there with V, no greeting.
      this.m_atHomeWithV = this.InApartment(GetPlayer(this.GetGameInstance()));
      this.Debug("V sent Apiko away" + (this.m_atHomeWithV ? " (stays home, V is here)" : ""));
    };
    if Equals(cue, "follow") && this.m_away {
      this.m_away = false;
      this.m_atHomeWithV = false;
      this.m_leftHomeAt = -1.0;
      // Following again at once (V may already be out of the door, the drone staying where V left it).
      this.m_nextSetupTime = 0.0;
      this.Debug("V took Apiko along from home");
    };
    if Equals(cue, "call_done") {
      this.m_apikoCallDone = true;
    };
  }

  // Out of reach: sent away and V is not at home with it (the CET side sends nothing to the bridge then, but the
  // phone call).
  public func IsAway() -> Bool {
    return this.m_unlocked && this.m_away && !this.m_atHomeWithV;
  }

  // A random spot, other than the current one.
  private func PickHomeSpot() -> Void {
    let count: Int32 = ApisK0Config.HomeSpotCount();
    let index: Int32;
    if count <= 1 {
      this.m_homeIndex = 0;
      return;
    };
    index = RandRange(0, count - 1);
    if index >= this.m_homeIndex && this.m_homeIndex >= 0 && this.m_homeIndex < count {
      index += 1;
    };
    this.m_homeIndex = Min(index, count - 1);
  }

  private func HomePosition() -> Vector4 {
    return ApisK0Config.HomeSpot(this.m_homeIndex);
  }

  // V is near home: within HomeRadius of any spot.
  private func NearHome(player: ref<PlayerPuppet>) -> Bool {
    let position: Vector4 = player.GetWorldPosition();
    let i: Int32 = 0;
    while i < ApisK0Config.HomeSpotCount() {
      if Vector4.Distance(position, ApisK0Config.HomeSpot(i)) <= ApisK0Config.HomeRadius() {
        return true;
      };
      i += 1;
    };
    return false;
  }

  // Apiko at home, V near but not inside: the drone waits at a spot, not following (no role), facing V. The drone
  // that followed V (sent away nearby, or V walked out) is removed and spawns again at a spot: teleporting it did
  // nothing (2026-11-08).
  private func UpdateHomeWait(now: Float, des: ref<DynamicEntitySystem>, player: ref<PlayerPuppet>) -> Void {
    let drone: ref<NPCPuppet>;
    let ai: ref<AIHumanComponent>;
    let godMode: ref<GodModeSystem>;
    let facing: Vector4;
    // The drone that followed V: it stays where V left it (at the door, say), not following; it goes, and one spawns
    // at a spot, once V is HomeLingerDistance away from it or after HomeLingerSeconds (2026-11-08: going at once,
    // the moment V crossed the door, looked wrong). Back inside before that, V finds it there, following again.
    if des.IsPopulated(ApisK0Config.Tag()) && !this.m_homeSettled {
      if this.m_leftHomeAt < 0.0 {
        this.m_leftHomeAt = now;
        this.Debug("at home: V walked out, Apiko stays where it is");
      };
      drone = des.GetEntity(des.GetTaggedID(ApisK0Config.Tag())) as NPCPuppet;
      if IsDefined(drone) && drone.IsAttached() {
        ai = drone.GetAIControllerComponent();
        if IsDefined(ai) && IsDefined(ai.GetAIRole()) && Equals(ai.GetAIRole().GetRoleEnum(), EAIRole.Follower) {
          AIHumanComponent.SetCurrentRole(drone, new AINoRole());
        };
      };
      if !IsDefined(drone) || Vector4.Distance(drone.GetWorldPosition(), player.GetWorldPosition()) > ApisK0Config.HomeLingerDistance()
        || now - this.m_leftHomeAt >= ApisK0Config.HomeLingerSeconds() {
        des.DeleteTagged(ApisK0Config.Tag());
        this.m_spawnRequestTime = -1000.0;
        this.m_leftHomeAt = -1.0;
        this.Debug("at home: the drone that followed V goes, it spawns at a spot");
      };
      this.SetState("at home, staying where V left it");
      return;
    };
    if !des.IsPopulated(ApisK0Config.Tag()) {
      if now - this.m_spawnRequestTime >= ApisK0Config.SpawnRetryDelay() {
        this.PickHomeSpot();
        facing = player.GetWorldPosition() - this.HomePosition();
        facing.Z = 0.0;
        this.Debug("spawn requested at home, spot " + IntToString(this.m_homeIndex + 1));
        this.SpawnAt(this.HomePosition(), Quaternion.BuildFromDirectionVector(facing));
        this.m_homeSettled = true;
        this.m_spawnRequestTime = now;
      };
      this.SetState("at home, waiting for V (spawning)");
      return;
    };
    drone = des.GetEntity(des.GetTaggedID(ApisK0Config.Tag())) as NPCPuppet;
    if !IsDefined(drone) || !drone.IsAttached() {
      return;
    };
    godMode = GameInstance.GetGodModeSystem(this.GetGameInstance());
    if !godMode.HasGodMode(drone.GetEntityID(), gameGodModeType.Invulnerable) {
      godMode.AddGodMode(drone.GetEntityID(), gameGodModeType.Invulnerable, n"ApisK0");
    };
    ai = drone.GetAIControllerComponent();
    if IsDefined(ai) && IsDefined(ai.GetAIRole()) && Equals(ai.GetAIRole().GetRoleEnum(), EAIRole.Follower) {
      AIHumanComponent.SetCurrentRole(drone, new AINoRole());
    };
    this.SetState("at home, waiting for V");
  }

  // V is inside their apartment in Megabuilding H10 (the game's own district for it).
  private func InApartment(player: ref<PlayerPuppet>) -> Bool {
    let district: wref<District>;
    if !IsDefined(player) {
      return false;
    };
    district = player.GetPreventionSystem().GetCurrentDistrict();
    return IsDefined(district) && district.GetDistrictID() == t"Districts.VApartment";
  }

  // V calls the APIKO contact (the phone's own call, ApisK0Find.ApikoCallFact): it rings a moment, Apiko answers (the
  // bridge says a written line), the call ends when the line has sounded (or V hangs up, or a timeout), and if Apiko
  // was away it comes back: the drone appears behind V.
  private func UpdateApikoCall(now: Float) -> Void {
    let game: GameInstance = this.GetGameInstance();
    let state: Int32;
    let over: Bool;
    if !this.m_unlocked {
      return;
    };
    state = GameInstance.GetQuestsSystem(game).GetFactStr(ApisK0Find.ApikoCallFact());
    if !this.m_apikoCalling {
      if state == 1 {
        this.m_apikoCalling = true;
        this.m_apikoCallStart = now;
        this.m_apikoCallAnswered = false;
        this.m_apikoCallDone = false;
        this.Debug("V is calling APIKO" + (this.IsAway() ? " (away)" : ""));
      };
      return;
    };
    if !this.m_apikoCallAnswered {
      if state != 1 {
        this.Debug("V hung up before Apiko answered");
        this.m_apikoCalling = false;
        return;
      };
      if now - this.m_apikoCallStart >= ApisK0Find.ApikoAnswerSeconds() {
        ApisK0Find.ApikoCall(game, questPhoneCallPhase.StartCall);
        this.m_apikoCallAnswered = true;
        this.m_apikoCallAnsweredAt = now;
        this.Chat().PushEvent(this.IsAway() ? "phone_call:away" : "phone_call:present");
      };
      return;
    };
    // Without the bridge there is no line (and no "call_done"): a short silent call.
    over = this.m_apikoCallDone || state == 0 || state == 3
      || now - this.m_apikoCallAnsweredAt >= (this.m_bridgeOnline ? ApisK0Find.ApikoCallMaxSeconds() : 3.0);
    if !over {
      return;
    };
    if state == 1 || state == 2 {
      ApisK0Find.ApikoCall(game, questPhoneCallPhase.EndCall);
    };
    this.m_apikoCalling = false;
    if this.IsAway() {
      this.m_away = false;
      this.m_spawnRequestTime = -1000.0;
      // Fresh baselines: what changed while it was away (district, hour, wanted level) is not news.
      this.Chat().Reset();
      this.People().Reset();
      this.Debug("Apiko called back: it comes");
    };
  }

  // From the CET side, every couple of seconds: whether the bridge is running (the upload waits for its voice).
  public func SetBridgeOnline(online: Bool) -> Void {
    this.m_bridgeOnline = online;
  }

  // The find needs the bridge before Apiko is awake (the chip's upload: Apiko in V's head): the CET side talks with it
  // then too.
  public func NeedsBridge() -> Bool {
    return this.m_uploading || this.m_beaconVoiced;
  }

  // `firstContact`: woken by the find with the bridge running, so the bridge says the rest of the written first
  // contact, by what V did at the site ("first_wake:shard_read,ortega"); otherwise the model's own first words.
  // The find is Apiko's real start: its first contact (and fresh memory) even if the debug hotkey woke it before in
  // this save (that sent a plain "wake" and the model improvised over the script).
  private func Wake(opt firstContact: Bool) -> Void {
    let game: GameInstance = this.GetGameInstance();
    let flags: array<String>;
    let event: String;
    this.m_unlocked = true;
    this.m_away = false;
    // First words after waking up. The very first wake in this save starts a fresh Apiko (the bridge resets its
    // memory only then: a load never does).
    event = this.m_everWoken ? "wake" : "first_wake";
    if firstContact {
      ApisK0Find.MeetApiko(game);
      if ApisK0Find.ShardRead(game) {
        ArrayPush(flags, "shard_read");
      };
      if this.m_stashTaken {
        ArrayPush(flags, "ortega");
      };
      event = "first_wake:" + (ArraySize(flags) > 0 ? flags[0] : "") + (ArraySize(flags) > 1 ? "," + flags[1] : "");
    };
    this.Debug("wake event: " + event);
    this.Chat().PushEvent(event);
    this.m_everWoken = true;
    this.RestartLoop();
  }

  private func RestartLoop() -> Void {
    this.m_spawnRequestTime = -1000.0;
    this.m_nextSetupTime = 0.0;
    this.m_state = "";
    this.m_generation += 1;
    this.Schedule();
  }

  public func Tick(generation: Int32) -> Void {
    if generation != this.m_generation {
      return;
    };
    this.UpdateTrigger(this.Now());
    this.UpdateBeaconCall(this.Now());
    this.UpdateFind(this.Now());
    this.UpdateUpload(this.Now());
    this.UpdateApikoCall(this.Now());
    // The upload woke Apiko: RestartLoop already scheduled the new loop.
    if generation != this.m_generation {
      return;
    };
    if this.m_unlocked {
      // Saves from before m_everWoken existed: Apiko is awake there, so it has been woken.
      this.m_everWoken = true;
      this.Update(this.Now());
    };
    // Out of reach: no perception and no events until V calls it back or comes home (Update keeps the drone gone).
    if this.m_unlocked && !this.IsAway() {
      this.Chat().Update(this.Now(), GetPlayer(this.GetGameInstance()));
      this.Devices().Update(this.Now(), GetPlayer(this.GetGameInstance()), this.Drone(), this.Chat());
      this.Enemies().Update(this.Now(), GetPlayer(this.GetGameInstance()), this.Drone(), this.Devices());
      this.Story().Update(this.Now(), GetPlayer(this.GetGameInstance()));
      this.People().Update(this.Now(), GetPlayer(this.GetGameInstance()), this.Enemies().GetFound(), this.Enemies().ScannedThisTick(),
        this.Enemies().PoliceSummary());
      this.UpdateSurroundings();
    };
    this.Schedule();
  }

  // Bodies of the enemies V downed, then the surroundings scan (after the enemy scan, with its NPCs).
  private func UpdateSurroundings() -> Void {
    let downed: array<ref<NPCPuppet>> = this.Enemies().DrainDowned();
    let i: Int32 = 0;
    while i < ArraySize(downed) {
      this.Surroundings().AddBody(downed[i]);
      i += 1;
    };
    this.Surroundings().Update(GetPlayer(this.GetGameInstance()), this.Enemies().GetFound(), this.Enemies().ScannedThisTick(),
      this.Devices(), this.Enemies());
  }

  // From the disposal wrapper: a body was hidden in a container.
  public func OnBodyHidden(id: EntityID) -> Void {
    this.Surroundings().HideBody(id);
  }

  private func Update(now: Float) -> Void {
    let game: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    let entity: ref<Entity>;
    let drone: ref<NPCPuppet>;
    let distance: Float;
    if !IsDefined(player) || !IsDefined(des) || !des.IsReady() {
      return;
    };

    if this.m_away {
      if !this.InApartment(player) {
        this.m_atHomeWithV = false;
        // V is near home: Apiko waits at its spot, already inside when V opens the door.
        if this.NearHome(player) {
          this.UpdateHomeWait(now, des, player);
          return;
        };
        if des.IsPopulated(ApisK0Config.Tag()) {
          des.DeleteTagged(ApisK0Config.Tag());
        };
        this.m_homeSettled = false;
        this.m_leftHomeAt = -1.0;
        this.m_spawnRequestTime = -1000.0;
        this.SetState("away in V's apartment (call APIKO, or go home and tell it to come)");
        return;
      };
      // V came home: Apiko is there and follows V inside. Only when it was waiting at a spot (not when V just stepped
      // out and back in: that spammed greetings at the door), fresh baselines (what changed while it was away is not
      // news) and a greeting, at most one per HomeGreetCooldown.
      this.m_leftHomeAt = -1.0;
      if !this.m_atHomeWithV {
        this.m_atHomeWithV = true;
        this.m_nextSetupTime = 0.0;
        if this.m_homeSettled || !des.IsPopulated(ApisK0Config.Tag()) {
          this.Chat().Reset();
          this.People().Reset();
          if now - this.m_homeGreetAt >= ApisK0Config.HomeGreetCooldown() {
            this.m_homeGreetAt = now;
            this.Chat().PushEvent("home_greet");
          };
          this.Debug("V came home: Apiko is there");
        };
        // It follows V inside now: when V walks out, it stays where it is, then goes and one spawns at a spot.
        this.m_homeSettled = false;
      };
    } else {
      this.m_atHomeWithV = false;
    };

    if IsDefined(GetMountedVehicle(player)) {
      if des.IsPopulated(ApisK0Config.Tag()) {
        des.DeleteTagged(ApisK0Config.Tag());
      };
      this.m_spawnRequestTime = -1000.0;
      this.SetState("removed while V is in a vehicle");
      return;
    };

    // Found by tag: IsManaged() with the id returned by CreateEntity never reported the drone.
    if !des.IsPopulated(ApisK0Config.Tag()) {
      this.SetState("absent");
      // CreateEntity is asynchronous: give a request time to show up before trying again.
      if now - this.m_spawnRequestTime >= ApisK0Config.SpawnRetryDelay() {
        this.Debug("spawn requested");
        this.Spawn(player, des);
        this.m_spawnRequestTime = now;
      };
      return;
    };
    entity = des.GetEntity(des.GetTaggedID(ApisK0Config.Tag()));
    drone = entity as NPCPuppet;
    if !IsDefined(entity) {
      this.SetState("tagged, no entity yet");
      return;
    };
    if !IsDefined(drone) {
      this.SetState("entity is not an NPCPuppet: " + NameToString(entity.GetClassName()));
      return;
    };
    if !drone.IsAttached() {
      this.SetState("entity not attached yet");
      return;
    };
    this.SetState("following");

    if now >= this.m_nextSetupTime {
      this.EnsureSetup(drone, player);
      this.m_nextSetupTime = now + ApisK0Config.SetupInterval();
    };

    distance = Vector4.Distance(drone.GetWorldPosition(), player.GetWorldPosition());
    if distance > ApisK0Config.LeashDistance() {
      this.Debug("too far (" + FloatToString(distance) + " m), teleported behind V");
      GameInstance.GetTeleportationFacility(game).Teleport(drone, this.BehindPosition(player), Quaternion.ToEulerAngles(player.GetWorldOrientation()));
      distance = 0.0;
    };
    this.UpdateSpeed(drone, distance);
    this.UpdateAltitude(drone);

    if this.m_dev && now >= this.m_nextReportTime {
      this.m_nextReportTime = now + 2.0;
      this.Debug("drone " + FloatToString(distance) + " m from V, speed x" + FloatToString(this.SpeedFactor(distance)));
    };
  }

  // Same idea as vanilla AIFollowerInterpolateFollowingSpeed: faster the farther behind it is.
  private func SpeedFactor(distance: Float) -> Float {
    let alpha: Float = (distance - ApisK0Config.MinCatchUpDistance()) / (ApisK0Config.MaxCatchUpDistance() - ApisK0Config.MinCatchUpDistance());
    return 1.0 + ClampF(alpha, 0.0, 1.0) * (ApisK0Config.MaxSpeedFactor() - 1.0);
  }

  private func UpdateSpeed(drone: ref<NPCPuppet>, distance: Float) -> Void {
    let factor: Float = this.SpeedFactor(distance);
    if factor > 1.01 {
      // Negative duration = until changed. Other dilations (hit reactions, quickhacks) win.
      if !drone.HasIndividualTimeDilation() || drone.HasIndividualTimeDilation(n"ApisK0CatchUp") {
        drone.SetIndividualTimeDilation(n"ApisK0CatchUp", factor, -1.0, n"None", n"None");
      };
    } else {
      if drone.HasIndividualTimeDilation(n"ApisK0CatchUp") {
        drone.UnsetIndividualTimeDilation();
      };
    };
  }

  // Same anim feature as the vanilla AISubActionDroneModifyAltitude (desired offset from the drone's normal
  // flying height). Re-applied every tick because vanilla drone actions reset it to 0 when they end.
  private func UpdateAltitude(drone: ref<NPCPuppet>) -> Void {
    let feature: ref<AnimFeature_DroneActionAltitudeOffset> = new AnimFeature_DroneActionAltitudeOffset();
    feature.desiredOffset = ApisK0Config.AltitudeOffset();
    AnimationControllerComponent.ApplyFeatureToReplicate(drone, n"ActionAltitudeOffset", feature);
  }

  private func Spawn(player: ref<PlayerPuppet>, des: ref<DynamicEntitySystem>) -> Void {
    this.m_homeSettled = false;
    this.SpawnAt(this.BehindPosition(player), player.GetWorldOrientation());
  }

  private func SpawnAt(position: Vector4, orientation: Quaternion) -> Void {
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    let spec: ref<DynamicEntitySpec> = new DynamicEntitySpec();
    spec.recordID = ApisK0Config.RecordID();
    spec.appearanceName = ApisK0Config.Appearance();
    spec.position = position;
    spec.orientation = orientation;
    spec.alwaysSpawned = true;
    spec.persistState = false;
    spec.persistSpawn = false;
    spec.tags = [ApisK0Config.Tag()];
    des.CreateEntity(spec);
    this.m_nextSetupTime = 0.0;
  }

  private func Despawn() -> Void {
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    if IsDefined(des) {
      des.DeleteTagged(ApisK0Config.Tag());
    };
    this.m_spawnRequestTime = -1000.0;
  }

  // Checked periodically instead of once on spawn: right after spawning the AI may not be ready and
  // silently drop the role, and quests or other mods could clear it later. The check is on the
  // actual result (V as friendly target), not on the role type.
  private func EnsureSetup(drone: ref<NPCPuppet>, player: ref<PlayerPuppet>) -> Void {
    let godMode: ref<GodModeSystem> = GameInstance.GetGodModeSystem(this.GetGameInstance());
    let ai: ref<AIHumanComponent> = drone.GetAIControllerComponent();
    let friendly: wref<GameObject>;
    let role: ref<AIFollowerRole>;
    let noNames: array<CName>;
    if !godMode.HasGodMode(drone.GetEntityID(), gameGodModeType.Invulnerable) {
      godMode.AddGodMode(drone.GetEntityID(), gameGodModeType.Invulnerable, n"ApisK0");
    };
    // Gates the closer follow actions in apis_k0_follow.yaml to this drone only.
    if !StatusEffectSystem.ObjectHasStatusEffect(drone, t"ApisK0.Marker") {
      StatusEffectHelper.ApplyStatusEffect(drone, t"ApisK0.Marker", drone.GetEntityID());
    };
    if !IsDefined(ai) {
      this.SetState("no AI component");
      return;
    };
    if IsDefined(ai.GetAIRole()) && Equals(ai.GetAIRole().GetRoleEnum(), EAIRole.Follower)
      && ai.GetFriendlyTarget(friendly) && IsDefined(friendly) && friendly.IsPlayer() {
      return;
    };
    this.Debug("follower role applied");
    role = new AIFollowerRole();
    // OnRoleSet resolves the follow target from followerRef, not from SetFollowTarget.
    role.ApisK0SetFollowerRef(CreateEntityReference("#player", noNames));
    role.SetFollowTarget(player);
    AIHumanComponent.SetCurrentRole(drone, role);
  }

  // A navmesh point behind V. The drone's root must be on the navmesh (its flying height comes from the
  // animation): spawned in mid-air it was stuck, unable to path, until the vanilla catch-up moved it.
  private func BehindPosition(player: ref<PlayerPuppet>) -> Vector4 {
    let point: Vector4;
    if GameInstance.GetAINavigationSystem(this.GetGameInstance()).GetNearestNavmeshPointBehind(player, ApisK0Config.PlaceBack() / 2.0, 3, point) {
      return point;
    };
    return player.GetWorldPosition() - ApisK0Config.PlaceBack() * player.GetWorldForward();
  }

  private func Now() -> Float {
    return EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGameInstance()));
  }

  private func Schedule() -> Void {
    GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(ApisK0TickCallback.Create(this, this.m_generation), ApisK0Config.TickInterval(), false);
  }

  private func SetState(state: String) -> Void {
    if NotEquals(state, this.m_state) {
      this.m_state = state;
      this.Debug("state: " + state);
    };
  }

  // Queued for the CET side, which prints them to its console and scripting.log
  // (FTLog output did not reach any log file).
  private func Debug(text: String) -> Void {
    if this.m_dev {
      ArrayPush(this.m_debugLines, FloatToString(this.Now()) + " " + text);
      // Without CET nothing drains the queue.
      if ArraySize(this.m_debugLines) > 200 {
        ArrayErase(this.m_debugLines, 0);
      };
    };
  }

  // Called by the CET side: a development install (its dev.lua), where debug lines are queued.
  public func SetDev(dev: Bool) -> Void {
    this.m_dev = dev;
  }

  // A debug line from outside the system (UI wraps).
  public func DebugNote(text: String) -> Void {
    this.Debug(text);
  }

  // Called by the CET side: returns the queued debug lines and clears the queue.
  public func DebugDrain() -> array<String> {
    let lines: array<String> = this.m_debugLines;
    ArrayClear(this.m_debugLines);
    return lines;
  }

  // Called by the CET side: game state Apiko perceives, as "key=value" lines.
  public func GetChatState() -> array<String> {
    let state: array<String> = this.Chat().GetState(GetPlayer(this.GetGameInstance()));
    let devices: String = this.Devices().GetStateLine();
    let enemies: String = this.Enemies().GetStateLine();
    let story: array<String> = this.Story().GetState(GetPlayer(this.GetGameInstance()));
    let people: array<String> = this.People().GetState();
    let surroundings: array<String> = this.Surroundings().GetState();
    let words: array<String> = this.People().GetTensionWords();
    let more: array<String> = this.Surroundings().GetTensionWords();
    let tension: String = this.Enemies().GetTension(GetPlayer(this.GetGameInstance()));
    let i: Int32 = 0;
    while i < ArraySize(more) {
      ArrayPush(words, more[i]);
      i += 1;
    };
    i = 0;
    while i < ArraySize(words) {
      tension += (StrLen(tension) > 0 ? ", " : "") + words[i];
      i += 1;
    };
    i = 0;
    while i < ArraySize(surroundings) {
      ArrayPush(state, surroundings[i]);
      i += 1;
    };
    if StrLen(tension) > 0 {
      ArrayPush(state, "tension=" + tension);
    };
    i = 0;
    while i < ArraySize(story) {
      ArrayPush(state, story[i]);
      i += 1;
    };
    i = 0;
    while i < ArraySize(people) {
      ArrayPush(state, people[i]);
      i += 1;
    };
    if StrLen(devices) > 0 {
      ArrayPush(state, "devices=" + devices);
    };
    if StrLen(enemies) > 0 {
      ArrayPush(state, "enemies=" + enemies);
    };
    // Sent away, at home with V: the model knows it stays here unless V tells it to come along.
    if this.m_away {
      ArrayPush(state, "apiko=staying in V's apartment (Megabuilding H10), not following V outside");
    };
    return state;
  }

  // Called by the CET side: the memory stored in this save (see m_memoryVersion).
  public func GetMemoryVersion() -> Int32 {
    return this.m_memoryVersion;
  }

  public func GetMemoryLength() -> Int32 {
    return this.m_memoryLength;
  }

  public func GetMemoryBlob() -> array<Int32> {
    return this.m_memoryBlob;
  }

  // Called by the CET side with each new memory version from the bridge; it goes into the next save.
  public func SetMemory(version: Int32, blob: array<Int32>, length: Int32) -> Void {
    this.m_memoryVersion = version;
    this.m_memoryBlob = blob;
    this.m_memoryLength = length;
  }

  // Called by the CET side: lines for the "APIKO Senses" debug window.
  public func GetSensesDebug() -> array<String> {
    return this.Devices().GetDebugLines(this.Now());
  }

  // Called by the CET side: enemy lines for the "APIKO Senses" debug window.
  public func GetEnemiesDebug() -> array<String> {
    return this.Enemies().GetDebugLines();
  }

  // Called by the CET side: device, enemy, quest and message events for Apiko's diary ("action|kind|detail"),
  // oldest first within each source. Clears the queues.
  public func DrainWorldEvents() -> array<String> {
    let events: array<String> = this.Devices().DrainEvents();
    let enemies: array<String> = this.Enemies().DrainEvents();
    let story: array<String> = this.Story().DrainEvents();
    let people: array<String> = this.People().DrainEvents();
    let surroundings: array<String> = this.Surroundings().DrainEvents();
    let i: Int32 = 0;
    while i < ArraySize(surroundings) {
      ArrayPush(people, surroundings[i]);
      i += 1;
    };
    i = 0;
    while i < ArraySize(enemies) {
      ArrayPush(events, enemies[i]);
      i += 1;
    };
    i = 0;
    while i < ArraySize(people) {
      ArrayPush(events, people[i]);
      i += 1;
    };
    i = 0;
    while i < ArraySize(story) {
      ArrayPush(events, story[i]);
      i += 1;
    };
    return events;
  }

  // Called by the CET side: lines Apiko heard and conversation start/end (ApisK0Story.reds). Clears the queue.
  public func DrainStoryMessages() -> array<String> {
    return this.Story().DrainMessages();
  }

  // From the damage and death wrappers (ApisK0People.reds): V hurt or killed a civilian.
  public func OnCivilianHit(npc: ref<ScriptedPuppet>, killed: Bool) -> Void {
    if this.m_unlocked {
      this.People().OnCivilianHit(npc, killed);
      if killed && IsDefined(npc as NPCPuppet) {
        this.Surroundings().AddBody(npc as NPCPuppet);
      };
    };
  }

  // From the Device.OnPerformedAction wrapper (ApisK0Devices.reds).
  public func OnPlayerDeviceAction(device: ref<Device>, action: ref<ScriptableDeviceAction>) -> Void {
    if this.m_unlocked {
      this.Devices().OnPlayerAction(this.Now(), device, action, this.Chat());
    };
  }

  // From the PingSquadEffector wrapper (ApisK0Devices.reds).
  public func OnPlayerPing() -> Void {
    if this.m_unlocked {
      this.Devices().OnPlayerPing(this.Now(), this.Chat());
    };
  }

  // Called by the CET side: events Apiko may comment on, oldest first. Clears the queue.
  public func DrainChatEvents() -> array<String> {
    return this.Chat().DrainEvents();
  }

  // Called by the CET side: where the drone is, for the bridge's simulated 3D voice. "distance pan front":
  // metres from the camera; -1 left .. 1 right; -1 behind .. 1 ahead. "car" while V drives, "none" without drone.
  public func GetAudioPose() -> String {
    let game: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(game);
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    let cameras: ref<CameraSystem> = GameInstance.GetCameraSystem(game);
    let drone: ref<Entity>;
    let camera: Transform;
    let toDrone: Vector4;
    let direction: Vector4;
    if !IsDefined(player) {
      return "none";
    };
    if IsDefined(GetMountedVehicle(player)) {
      return "car";
    };
    if !IsDefined(des) || !des.IsPopulated(ApisK0Config.Tag()) {
      return "none";
    };
    drone = des.GetEntity(des.GetTaggedID(ApisK0Config.Tag()));
    if !IsDefined(drone) || !IsDefined(cameras) || !cameras.GetActiveCameraWorldTransform(camera) {
      return "none";
    };
    toDrone = drone.GetWorldPosition() - Transform.GetPosition(camera);
    direction = Vector4.Normalize(toDrone);
    return FloatToStringPrec(Vector4.Length(toDrone), 2) + " "
      + FloatToStringPrec(Vector4.Dot(direction, cameras.GetActiveCameraRight()), 2) + " "
      + FloatToStringPrec(Vector4.Dot(direction, cameras.GetActiveCameraForward()), 2);
  }

  // Called by the CET side with a reply from the bridge.
  public func Say(text: String, duration: Float) -> Void {
    this.Chat().Say(text, duration, this.Speaker());
  }

  // NetWatch's recording on the beacon's call: subtitled by NETWATCH.
  public func SayNetWatch(text: String, duration: Float) -> Void {
    this.Chat().Say(text, duration, this.Speaker(), false, true);
  }

  // The first contact before Apiko gives its name: subtitled by an unknown speaker.
  public func SayUnknown(text: String, duration: Float) -> Void {
    this.Chat().Say(text, duration, this.Speaker(), true);
  }

  // The drone, or V when there is none (Apiko in V's head, or V driving).
  private func Speaker() -> ref<GameObject> {
    let des: ref<DynamicEntitySystem> = GameInstance.GetDynamicEntitySystem();
    let speaker: ref<GameObject>;
    if IsDefined(des) && des.IsPopulated(ApisK0Config.Tag()) {
      speaker = des.GetEntity(des.GetTaggedID(ApisK0Config.Tag())) as GameObject;
    };
    if !IsDefined(speaker) {
      speaker = GetPlayer(this.GetGameInstance());
    };
    return speaker;
  }

  private func ShowMessage(text: String) -> Void {
    this.ShowNotice(text, 4.0);
  }

  // HUD warning line; also used from CET (bridge not running).
  public func ShowNotice(text: String, seconds: Float) -> Void {
    let message: SimpleScreenMessage;
    this.Debug(text);
    message.isShown = true;
    message.duration = seconds;
    message.message = text;
    GameInstance.GetBlackboardSystem(this.GetGameInstance()).Get(GetAllBlackboardDefs().UI_Notifications).SetVariant(GetAllBlackboardDefs().UI_Notifications.WarningMessage, ToVariant(message), true);
  }
}

public class ApisK0TickCallback extends DelayCallback {
  private let m_system: wref<ApisK0System>;
  private let m_generation: Int32;

  public static func Create(system: ref<ApisK0System>, generation: Int32) -> ref<ApisK0TickCallback> {
    let callback: ref<ApisK0TickCallback> = new ApisK0TickCallback();
    callback.m_system = system;
    callback.m_generation = generation;
    return callback;
  }

  public func Call() -> Void {
    if IsDefined(this.m_system) {
      this.m_system.Tick(this.m_generation);
    };
  }
}

@addMethod(AIFollowerRole)
public func ApisK0SetFollowerRef(entityRef: EntityReference) -> Void {
  this.followerRef = entityRef;
}

// Texts for TweakDB LocKey#ApisK0-* keys.
public class ApisK0LocalizationProvider extends ModLocalizationProvider {
  public func GetPackage(language: CName) -> ref<ModLocalizationPackage> {
    if Equals(language, n"es-es") || Equals(language, n"es-mx") {
      return new ApisK0LocalizationES();
    };
    return new ApisK0LocalizationEN();
  }

  public func GetFallback() -> CName {
    return n"en-us";
  }
}

public class ApisK0LocalizationEN extends ModLocalizationPackage {
  protected func DefineTexts() {
    this.Text("ApisK0-Name", "APIS-K0");
  }
}

public class ApisK0LocalizationES extends ModLocalizationPackage {
  protected func DefineTexts() {
    this.Text("ApisK0-Name", "APIS-K0");
  }
}
