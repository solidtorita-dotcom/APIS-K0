// APIS-K0 - phase 4, piece 5: the people around V that are not enemies (DISENO.md, "Pieza 5").
// - Civilians: how busy the place is (counted around V, no cards), how many are panicking, and how many afraid
//   civilians can see V (witnesses: they call NCPD).
// - NCPD: V's wanted level (stars); the officers Apiko perceives come from the enemy scan (PoliceSummary).
// - Named characters: non-hostile characters with a proper name in V's space, and companions following V.
// - World events: the wanted level rose ("heat|<stars>|", a written warning line), V hurt or killed a civilian
//   ("civilian|hurt|" / "civilian|killed|", diary only).
// Uses the NPCs the enemy scan already queried (one targeting query per second for both).
module ApisK0

public abstract class ApisK0PeopleConfig {
  // Civilians are counted this close to V (meters), on about V's floor (height difference below FloorHeight).
  public static func CrowdRange() -> Float { return 20.0; }
  public static func FloorHeight() -> Float { return 3.0; }
  // Crowd words: fewer than Few is "empty", fewer than Crowded is "a few people".
  public static func FewPeople() -> Int32 { return 1; }
  public static func CrowdedPeople() -> Int32 { return 6; }
  // Named characters are "here" up to this distance with a clear line from V's eyes.
  public static func HereRange() -> Float { return 25.0; }
  public static func MaxRaycastsPerScan() -> Int32 { return 15; }
  public static func SightTolerance() -> Float { return 0.8; }
  // A civilian V hurt is reported again only after this many seconds.
  public static func HurtRepeat() -> Float { return 60.0; }
  public static func MaxNames() -> Int32 { return 4; }
  // Vendors are listed this close to V (stalls and counters are often behind something: no line of sight needed).
  public static func VendorRange() -> Float { return 40.0; }
  public static func MaxQueuedEvents() -> Int32 { return 20; }
}

public class ApisK0People extends IScriptable {
  private let m_events: array<String>;
  private let m_heat: Int32;
  private let m_primed: Bool;
  // Last scan's readings, for the state.
  private let m_crowd: Int32;
  private let m_panic: Int32;
  private let m_witnesses: Int32;
  // ApisK0Enemies.PoliceSummary() of the last scan ("" = no police perceived).
  private let m_police: String;
  private let m_named: array<String>;
  private let m_companions: array<String>;
  private let m_vendors: array<String>;
  // Civilians V hurt lately (one report each per HurtRepeat) and when.
  private let m_hurtIDs: array<EntityID>;
  private let m_hurtTimes: array<Float>;
  private let m_now: Float;

  public static func Create(game: GameInstance) -> ref<ApisK0People> {
    return new ApisK0People();
  }

  public func Reset() -> Void {
    ArrayClear(this.m_events);
    ArrayClear(this.m_named);
    ArrayClear(this.m_companions);
    ArrayClear(this.m_vendors);
    ArrayClear(this.m_hurtIDs);
    ArrayClear(this.m_hurtTimes);
    this.m_primed = false;
    this.m_crowd = 0;
    this.m_panic = 0;
    this.m_witnesses = 0;
    this.m_police = "";
  }

  public func DrainEvents() -> array<String> {
    let events: array<String> = this.m_events;
    ArrayClear(this.m_events);
    return events;
  }

  private func PushEvent(action: String, kind: String, detail: String) -> Void {
    ArrayPush(this.m_events, action + "|" + kind + "|" + detail);
    if ArraySize(this.m_events) > ApisK0PeopleConfig.MaxQueuedEvents() {
      ArrayErase(this.m_events, 0);
    };
  }

  // Called after the enemy scan with the NPCs it found (`scanned` is false when it did not scan this tick) and its
  // police summary.
  public func Update(now: Float, player: ref<PlayerPuppet>, npcs: array<ref<NPCPuppet>>, scanned: Bool, police: String) -> Void {
    let heat: Int32;
    this.m_now = now;
    if !IsDefined(player) || !scanned {
      return;
    };
    // Wanted level: a rise is a world event (the first reading after a load is only the baseline). Also while V
    // drives (decided 2026-11-08): Apiko talks through the chip, and car chases are where the stars change.
    heat = this.Heat(player);
    if this.m_primed && heat > this.m_heat {
      this.PushEvent("heat", IntToString(heat), "");
    };
    // V shook the police off (a load is no escape: the first reading only sets the baseline).
    if this.m_primed && heat == 0 && this.m_heat > 0 {
      this.PushEvent("heat_lost", "", "");
    };
    this.m_primed = true;
    this.m_heat = heat;
    if IsDefined(GetMountedVehicle(player)) {
      this.m_crowd = 0;
      this.m_panic = 0;
      this.m_witnesses = 0;
      this.m_police = "";
      ArrayClear(this.m_named);
      ArrayClear(this.m_companions);
      ArrayClear(this.m_vendors);
      return;
    };
    this.Count(player, npcs);
    this.m_police = police;
  }

  private func Heat(player: ref<PlayerPuppet>) -> Int32 {
    let prevention: ref<PreventionSystem> = player.GetPreventionSystem();
    let stage: Int32;
    if !IsDefined(prevention) {
      return 0;
    };
    stage = EnumInt(prevention.GetHeatStage());
    return stage >= 0 && stage <= 5 ? stage : 0;
  }

  private func Count(player: ref<PlayerPuppet>, npcs: array<ref<NPCPuppet>>) -> Void {
    let eye: Vector4 = this.EyePosition(player);
    let npc: ref<NPCPuppet>;
    let offset: Vector4;
    let distance: Float;
    let name: String;
    let raycasts: Int32;
    let afraid: Bool;
    let i: Int32 = 0;
    this.m_crowd = 0;
    this.m_panic = 0;
    this.m_witnesses = 0;
    this.m_police = "";
    ArrayClear(this.m_named);
    ArrayClear(this.m_companions);
    ArrayClear(this.m_vendors);
    while i < ArraySize(npcs) {
      npc = npcs[i];
      if IsDefined(npc) && npc.IsActive() && !npc.IsDead() && npc.GetRecordID() != ApisK0Config.RecordID() {
        offset = npc.GetWorldPosition() - player.GetWorldPosition();
        distance = Vector4.Length(offset);
        name = this.OwnName(npc);
        if this.IsCompanion(npc) {
          if StrLen(name) > 0 && ArraySize(this.m_companions) < ApisK0PeopleConfig.MaxNames() {
            ArrayPush(this.m_companions, name);
          };
        } else {
          if npc.IsVendor() {
            // Vendors (food stalls, shops, ripperdocs...): their own name or what the scanner calls them.
            if distance <= ApisK0PeopleConfig.VendorRange() && ArraySize(this.m_vendors) < ApisK0PeopleConfig.MaxNames() {
              name = StrLen(name) > 0 ? name : this.DisplayName(npc);
              if StrLen(name) > 0 && !ArrayContains(this.m_vendors, name) {
                ArrayPush(this.m_vendors, name);
              };
            };
          } else {
          if npc.IsCharacterPolice() {
            // Perceived by the enemy scan (PoliceSummary).
          } else {
            if StrLen(name) > 0 && NotEquals(GameObject.GetAttitudeTowards(npc, player), EAIAttitude.AIA_Hostile) {
              if distance <= ApisK0PeopleConfig.HereRange() && ArraySize(this.m_named) < ApisK0PeopleConfig.MaxNames()
                && !ArrayContains(this.m_named, name) && this.Visible(npc, player, eye, raycasts) {
                ArrayPush(this.m_named, name);
              };
            } else {
              if (npc.IsCrowd() || npc.IsCharacterCivilian()) && distance <= ApisK0PeopleConfig.CrowdRange()
                && AbsF(offset.Z) < ApisK0PeopleConfig.FloorHeight() {
                this.m_crowd += 1;
                afraid = this.IsAfraid(npc);
                if afraid {
                  this.m_panic += 1;
                  if this.SeesV(npc, player, distance) {
                    this.m_witnesses += 1;
                  };
                };
              };
            };
          };
          };
        };
      };
      i += 1;
    };
  }

  // A companion following V (a quest follower), never Apiko's own drone.
  private func IsCompanion(npc: ref<NPCPuppet>) -> Bool {
    let ai: ref<AIHumanComponent> = npc.GetAIControllerComponent();
    return IsDefined(ai) && IsDefined(ai.GetAIRole()) && Equals(ai.GetAIRole().GetRoleEnum(), EAIRole.Follower);
  }

  // Panicking or fleeing: a crowd member's fear stage (alarmed or panic), or a civilian's fear state.
  private func IsAfraid(npc: ref<NPCPuppet>) -> Bool {
    let reactions: ref<ReactionManagerComponent> = npc.GetStimReactionComponent();
    if Equals(npc.GetHighLevelStateFromBlackboard(), gamedataNPCHighLevelState.Fear) {
      return true;
    };
    return IsDefined(reactions) && EnumInt(reactions.ApisK0FearStage()) >= EnumInt(gameFearStage.Alarmed);
  }

  // An afraid civilian that can see V counts as a witness (its senses, or close by without them).
  private func SeesV(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>, distance: Float) -> Bool {
    let senses: ref<SenseComponent> = npc.GetSensesComponent();
    if IsDefined(senses) {
      return senses.IsAgentVisible(player);
    };
    return distance <= 10.0;
  }

  // On screen and visible, or a clear line from V's eyes to the chest (limited raycasts per scan).
  private func Visible(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>, eye: Vector4, out raycasts: Int32) -> Bool {
    let result: TraceResult;
    let target: Vector4 = npc.GetWorldPosition() + new Vector4(0.0, 0.0, 1.2, 0.0);
    if GameInstance.GetTargetingSystem(GetGameInstance()).IsVisibleTarget(player, npc) {
      return true;
    };
    if raycasts >= ApisK0PeopleConfig.MaxRaycastsPerScan() {
      return false;
    };
    raycasts += 1;
    if !GameInstance.GetSpatialQueriesSystem(GetGameInstance()).SyncRaycastByQueryPreset(eye, target, n"Sight Blocker", result) {
      return true;
    };
    return Vector4.Distance(Vector4.Vector3To4(result.position), target) <= ApisK0PeopleConfig.SightTolerance();
  }

  private func EyePosition(player: ref<PlayerPuppet>) -> Vector4 {
    let camera: Transform;
    if GameInstance.GetCameraSystem(GetGameInstance()).GetActiveCameraWorldTransform(camera) {
      return Transform.GetPosition(camera);
    };
    return player.GetWorldPosition() + new Vector4(0.0, 0.0, 1.7, 0.0);
  }

  // Characters with a name of their own (the scanner's full name); generic ones get "".
  private func OwnName(npc: ref<NPCPuppet>) -> String {
    let record: ref<Character_Record> = npc.GetRecord();
    let name: String;
    if !IsDefined(record) || !IsNameValid(record.FullDisplayName()) {
      return "";
    };
    name = GetLocalizedText(LocKeyToString(record.FullDisplayName()));
    return StrReplaceAll(StrReplaceAll(StrReplaceAll(name, ",", " "), ";", " "), "/", " ");
  }

  // What the scanner calls a generic NPC ("Vendedor de comida"), or "".
  private func DisplayName(npc: ref<NPCPuppet>) -> String {
    let record: ref<Character_Record> = npc.GetRecord();
    let name: String;
    if !IsDefined(record) || !IsNameValid(record.DisplayName()) {
      return "";
    };
    name = GetLocalizedText(LocKeyToString(record.DisplayName()));
    return StrReplaceAll(StrReplaceAll(StrReplaceAll(name, ",", " "), ";", " "), "/", " ");
  }

  // Sensors: crowd, panic, witnesses, wanted level, police, named characters and companions. Only what is there.
  public func GetState() -> array<String> {
    let state: array<String>;
    if this.m_crowd >= ApisK0PeopleConfig.CrowdedPeople() {
      ArrayPush(state, "crowd=crowded");
    } else {
      if this.m_crowd >= ApisK0PeopleConfig.FewPeople() {
        ArrayPush(state, "crowd=a few people");
      } else {
        ArrayPush(state, "crowd=empty");
      };
    };
    if this.m_panic > 0 {
      ArrayPush(state, "crowd_panic=" + IntToString(this.m_panic));
    };
    if this.m_witnesses > 0 {
      ArrayPush(state, "witnesses=" + IntToString(this.m_witnesses));
    };
    if this.m_heat > 0 {
      ArrayPush(state, "wanted_stars=" + IntToString(this.m_heat));
    };
    if StrLen(this.m_police) > 0 {
      ArrayPush(state, "police=" + this.m_police);
    };
    if ArraySize(this.m_named) > 0 {
      ArrayPush(state, "named_here=" + this.Join(this.m_named));
    };
    if ArraySize(this.m_companions) > 0 {
      ArrayPush(state, "companions=" + this.Join(this.m_companions));
    };
    if ArraySize(this.m_vendors) > 0 {
      ArrayPush(state, "vendors_near=" + this.Join(this.m_vendors));
    };
    return state;
  }

  // Words for the "tension=" sensor: a wanted level, witnesses.
  public func GetTensionWords() -> array<String> {
    let words: array<String>;
    if this.m_heat > 0 {
      ArrayPush(words, "wanted by NCPD (" + IntToString(this.m_heat) + " stars)");
    };
    if this.m_witnesses > 0 {
      ArrayPush(words, "civilians saw V");
    };
    return words;
  }

  private func Join(names: array<String>) -> String {
    let text: String;
    let i: Int32 = 0;
    while i < ArraySize(names) {
      text += (i > 0 ? " / " : "") + names[i];
      i += 1;
    };
    return text;
  }

  // From the ScriptedPuppet.OnDamageReceived / NPCPuppet.OnDeath wrappers: V hurt or killed a civilian.
  public func OnCivilianHit(npc: ref<ScriptedPuppet>, killed: Bool) -> Void {
    let id: EntityID = npc.GetEntityID();
    let index: Int32 = ArrayFindFirst(this.m_hurtIDs, id);
    if killed {
      this.PushEvent("civilian", "killed", "");
      if index >= 0 {
        ArrayErase(this.m_hurtIDs, index);
        ArrayErase(this.m_hurtTimes, index);
      };
      return;
    };
    if index >= 0 {
      if this.m_now - this.m_hurtTimes[index] < ApisK0PeopleConfig.HurtRepeat() {
        return;
      };
      this.m_hurtTimes[index] = this.m_now;
    } else {
      ArrayPush(this.m_hurtIDs, id);
      ArrayPush(this.m_hurtTimes, this.m_now);
    };
    this.PushEvent("civilian", "hurt", "");
  }
}

@addMethod(ReactionManagerComponent)
public func ApisK0FearStage() -> gameFearStage {
  return this.m_crowdFearStage;
}

// A civilian (not police, not hostile to V) is "V's victim" when V dealt the damage.
public static func ApisK0IsCivilianVictim(puppet: ref<ScriptedPuppet>, instigator: ref<GameObject>) -> Bool {
  let npc: ref<NPCPuppet> = puppet as NPCPuppet;
  return IsDefined(npc) && IsDefined(instigator) && instigator.IsPlayer()
    && (npc.IsCrowd() || npc.IsCharacterCivilian()) && !npc.IsCharacterPolice()
    && NotEquals(GameObject.GetAttitudeTowards(npc, instigator), EAIAttitude.AIA_Hostile);
}

@wrapMethod(ScriptedPuppet)
protected cb func OnDamageReceived(evt: ref<gameDamageReceivedEvent>) -> Bool {
  let result: Bool = wrappedMethod(evt);
  let instigator: ref<GameObject>;
  let system: ref<ApisK0System>;
  if evt.totalDamageReceived > 0.0 && IsDefined(evt.hitEvent) && !this.IsDead() {
    instigator = evt.hitEvent.attackData.GetInstigator();
    if ApisK0IsCivilianVictim(this, instigator) {
      system = ApisK0System.Get(this.GetGame());
      if IsDefined(system) {
        system.OnCivilianHit(this, false);
      };
    };
  };
  return result;
}

@wrapMethod(NPCPuppet)
protected cb func OnDeath(evt: ref<gameDeathEvent>) -> Bool {
  let result: Bool = wrappedMethod(evt);
  let system: ref<ApisK0System>;
  if ApisK0IsCivilianVictim(this, this.GetLastHitInstigator()) {
    system = ApisK0System.Get(this.GetGame());
    if IsDefined(system) {
      system.OnCivilianHit(this, true);
    };
  };
  return result;
}
