// APIS-K0 - phase 4, piece 6: V's surroundings (DISENO.md, "Pieza 6").
// - Other people's fights: NPCs fighting near V while V is not in combat (who vs who, how close). A fight that
//   starts is a world event ("fight|<factions>|close" / "fight|<factions>|nearby"; close ones get a written line).
// - Bodies V left: enemies and civilians V killed or knocked out, while V is near them; how many are in view and
//   whether a living enemy is close enough to find one. Bodies put in a disposal container are dropped.
// - Notable loot: legendary or iconic containers and dropped items in view (nothing ordinary).
// - Vehicles: AVs, V's own car, police cars and vehicles with hostiles in them, near V.
// Loot and vehicles come from a targeting query ("other" objects) near V; the NPCs come from the enemy scan.
module ApisK0

public abstract class ApisK0SurroundingsConfig {
  public static func FightRange() -> Float { return 60.0; }
  // A fight starting this close gets a written warning.
  public static func FightClose() -> Float { return 30.0; }
  // Bodies are followed while V is this close; "in view" up to BodySightRange with a clear line.
  public static func BodyKeepRange() -> Float { return 50.0; }
  public static func BodySightRange() -> Float { return 25.0; }
  // A living enemy this close to a body could find it.
  public static func BodyFindRange() -> Float { return 15.0; }
  public static func LootRange() -> Float { return 20.0; }
  public static func VehicleRange() -> Float { return 40.0; }
  public static func MaxRaycastsPerScan() -> Int32 { return 12; }
  public static func SightTolerance() -> Float { return 1.0; }
  public static func MaxQueuedEvents() -> Int32 { return 20; }
}

public class ApisK0Surroundings extends IScriptable {
  private let m_events: array<String>;
  private let m_containers: array<wref<gameLootContainerBase>>;
  private let m_drops: array<wref<gameItemDropObject>>;
  private let m_vehicles: array<wref<VehicleObject>>;
  private let m_bodies: array<wref<NPCPuppet>>;
  private let m_hiddenBodies: array<EntityID>;
  // Last scan's readings, for the state ("" = nothing).
  private let m_fight: String;
  private let m_bodiesState: String;
  private let m_loot: String;
  private let m_vehiclesState: String;
  private let m_fightGoing: Bool;
  private let m_bodiesAtRisk: Bool;
  private let m_fightClose: Bool;

  public static func Create(game: GameInstance) -> ref<ApisK0Surroundings> {
    return new ApisK0Surroundings();
  }

  // A load: the world is streamed again (loot and vehicles register again as they attach).
  public func Reset() -> Void {
    ArrayClear(this.m_events);
    ArrayClear(this.m_bodies);
    ArrayClear(this.m_hiddenBodies);
    this.m_fight = "";
    this.m_bodiesState = "";
    this.m_loot = "";
    this.m_vehiclesState = "";
    this.m_fightGoing = false;
    this.m_bodiesAtRisk = false;
    this.m_fightClose = false;
  }

  // Session end: also forget the loot and vehicles of the old world.
  public func Release() -> Void {
    this.Reset();
    ArrayClear(this.m_containers);
    ArrayClear(this.m_drops);
    ArrayClear(this.m_vehicles);
  }

  public func DrainEvents() -> array<String> {
    let events: array<String> = this.m_events;
    ArrayClear(this.m_events);
    return events;
  }

  private func PushEvent(action: String, kind: String, detail: String) -> Void {
    ArrayPush(this.m_events, action + "|" + kind + "|" + detail);
    if ArraySize(this.m_events) > ApisK0SurroundingsConfig.MaxQueuedEvents() {
      ArrayErase(this.m_events, 0);
    };
  }

  // A body V left (an enemy or civilian V killed or knocked out).
  public func AddBody(npc: ref<NPCPuppet>) -> Void {
    let i: Int32 = 0;
    while i < ArraySize(this.m_bodies) {
      if this.m_bodies[i] == npc {
        return;
      };
      i += 1;
    };
    ArrayPush(this.m_bodies, npc);
  }

  // From the disposal wrapper: this body is hidden now.
  public func HideBody(id: EntityID) -> Void {
    if !ArrayContains(this.m_hiddenBodies, id) {
      ArrayPush(this.m_hiddenBodies, id);
      this.PushEvent("body_hidden", "", "");
    };
  }

  // Loot and vehicles near V, from the targeting system ("other" objects). Hooking their OnGameAttached instead made
  // the game crash on load (2026-11-07).
  private func Discover(player: ref<PlayerPuppet>) -> Void {
    let query: TargetSearchQuery;
    let parts: array<TS_TargetPartInfo>;
    let component: ref<TargetingComponent>;
    let entity: ref<Entity>;
    let container: ref<gameLootContainerBase>;
    let drop: ref<gameItemDropObject>;
    let vehicle: ref<VehicleObject>;
    let i: Int32 = 0;
    ArrayClear(this.m_containers);
    ArrayClear(this.m_drops);
    ArrayClear(this.m_vehicles);
    query.testedSet = TargetingSet.Complete;
    query.searchFilter = TSF_Any(TSFMV.Obj_Other);
    query.maxDistance = ApisK0SurroundingsConfig.VehicleRange();
    query.filterObjectByDistance = true;
    query.includeSecondaryTargets = false;
    query.ignoreInstigator = true;
    GameInstance.GetTargetingSystem(GetGameInstance()).GetTargetParts(player, query, parts);
    while i < ArraySize(parts) {
      component = TS_TargetPartInfo.GetComponent(parts[i]);
      entity = IsDefined(component) ? component.GetEntity() : null;
      if IsDefined(entity) {
        container = entity as gameLootContainerBase;
        drop = entity as gameItemDropObject;
        vehicle = entity as VehicleObject;
        if IsDefined(container) && !this.HasContainer(container) {
          ArrayPush(this.m_containers, container);
        };
        if IsDefined(drop) && !this.HasDrop(drop) {
          ArrayPush(this.m_drops, drop);
        };
        if IsDefined(vehicle) && !this.HasVehicle(vehicle) {
          ArrayPush(this.m_vehicles, vehicle);
        };
      };
      i += 1;
    };
  }

  private func HasContainer(container: ref<gameLootContainerBase>) -> Bool {
    let i: Int32 = 0;
    while i < ArraySize(this.m_containers) {
      if this.m_containers[i] == container {
        return true;
      };
      i += 1;
    };
    return false;
  }

  private func HasDrop(drop: ref<gameItemDropObject>) -> Bool {
    let i: Int32 = 0;
    while i < ArraySize(this.m_drops) {
      if this.m_drops[i] == drop {
        return true;
      };
      i += 1;
    };
    return false;
  }

  private func HasVehicle(vehicle: ref<VehicleObject>) -> Bool {
    let i: Int32 = 0;
    while i < ArraySize(this.m_vehicles) {
      if this.m_vehicles[i] == vehicle {
        return true;
      };
      i += 1;
    };
    return false;
  }

  // --- scan (after the enemy scan, with the NPCs it found) ---

  public func Update(player: ref<PlayerPuppet>, npcs: array<ref<NPCPuppet>>, scanned: Bool, devices: ref<ApisK0Devices>, enemies: ref<ApisK0Enemies>) -> Void {
    let eye: Vector4;
    let raycasts: Int32;
    if !IsDefined(player) || !scanned {
      return;
    };
    if IsDefined(GetMountedVehicle(player)) {
      this.Reset();
      return;
    };
    eye = this.EyePosition(player);
    this.Discover(player);
    this.ScanFights(player, npcs);
    this.ScanBodies(player, npcs, enemies, eye, raycasts);
    this.ScanLoot(player, eye, raycasts);
    this.ScanVehicles(player);
  }

  private func ScanFights(player: ref<PlayerPuppet>, npcs: array<ref<NPCPuppet>>) -> Void {
    let factions: array<String>;
    let npc: ref<NPCPuppet>;
    let faction: String;
    let nearest: Float = -1.0;
    let distance: Float;
    let fighters: Int32;
    let text: String;
    let i: Int32 = 0;
    // V's own fight is not "other people's fight".
    if !player.IsInCombat() {
      while i < ArraySize(npcs) {
        npc = npcs[i];
        if IsDefined(npc) && npc.IsActive() && !npc.IsDead() && npc.GetRecordID() != ApisK0Config.RecordID()
          && Equals(npc.GetHighLevelStateFromBlackboard(), gamedataNPCHighLevelState.Combat) && !npc.IsPuppetTargetingPlayer() {
          fighters += 1;
          faction = this.Faction(npc);
          if !ArrayContains(factions, faction) {
            ArrayPush(factions, faction);
          };
          distance = Vector4.Distance(npc.GetWorldPosition(), player.GetWorldPosition());
          if nearest < 0.0 || distance < nearest {
            nearest = distance;
          };
        };
        i += 1;
      };
    };
    if fighters < 2 {
      this.m_fight = "";
      this.m_fightGoing = false;
      this.m_fightClose = false;
      return;
    };
    i = 0;
    while i < ArraySize(factions) {
      text += (i > 0 ? " vs " : "") + factions[i];
      i += 1;
    };
    this.m_fightClose = nearest <= ApisK0SurroundingsConfig.FightClose();
    if !this.m_fightGoing {
      this.PushEvent("fight", text, this.m_fightClose ? "close" : "nearby");
    };
    this.m_fightGoing = true;
    this.m_fight = text + ", " + IntToString(fighters) + " fighting, nearest " + IntToString(RoundF(nearest)) + " m";
  }

  private func ScanBodies(player: ref<PlayerPuppet>, npcs: array<ref<NPCPuppet>>, enemies: ref<ApisK0Enemies>, eye: Vector4, out raycasts: Int32) -> Void {
    let body: ref<NPCPuppet>;
    let distance: Float;
    let inView: Int32;
    let atRisk: Int32;
    let i: Int32 = ArraySize(this.m_bodies) - 1;
    while i >= 0 {
      body = this.m_bodies[i];
      if !IsDefined(body) || !body.IsAttached() || ArrayContains(this.m_hiddenBodies, body.GetEntityID()) {
        ArrayErase(this.m_bodies, i);
      } else {
        distance = Vector4.Distance(body.GetWorldPosition(), player.GetWorldPosition());
        if distance > ApisK0SurroundingsConfig.BodyKeepRange() {
          ArrayErase(this.m_bodies, i);
        } else {
          if distance <= ApisK0SurroundingsConfig.BodySightRange() && this.Visible(eye, body.GetWorldPosition() + new Vector4(0.0, 0.0, 0.3, 0.0), raycasts) {
            inView += 1;
          };
          if this.EnemyNear(body, npcs, player, enemies) {
            atRisk += 1;
          };
        };
      };
      i -= 1;
    };
    this.m_bodiesAtRisk = atRisk > 0;
    if ArraySize(this.m_bodies) == 0 {
      this.m_bodiesState = "";
      return;
    };
    this.m_bodiesState = IntToString(ArraySize(this.m_bodies)) + " left by V, " + IntToString(inView) + " in view, "
      + IntToString(atRisk) + " with a living enemy close enough to find it";
  }

  // A living enemy (not fighting already) close enough to stumble on the body.
  private func EnemyNear(body: ref<NPCPuppet>, npcs: array<ref<NPCPuppet>>, player: ref<PlayerPuppet>, enemies: ref<ApisK0Enemies>) -> Bool {
    let npc: ref<NPCPuppet>;
    let i: Int32 = 0;
    while i < ArraySize(npcs) {
      npc = npcs[i];
      if IsDefined(npc) && npc != body && !npc.IsDead() && !ScriptedPuppet.IsUnconscious(npc) && enemies.IsEnemyOf(npc, player)
        && NotEquals(npc.GetHighLevelStateFromBlackboard(), gamedataNPCHighLevelState.Combat)
        && Vector4.Distance(npc.GetWorldPosition(), body.GetWorldPosition()) <= ApisK0SurroundingsConfig.BodyFindRange() {
        return true;
      };
      i += 1;
    };
    return false;
  }

  private func ScanLoot(player: ref<PlayerPuppet>, eye: Vector4, out raycasts: Int32) -> Void {
    let found: array<String>;
    let container: ref<gameLootContainerBase>;
    let drop: ref<gameItemDropObject>;
    let label: String;
    let i: Int32 = 0;
    while i < ArraySize(this.m_containers) {
      container = this.m_containers[i];
      if IsDefined(container) && container.IsAttached() && !container.IsEmpty()
        && Vector4.Distance(container.GetWorldPosition(), player.GetWorldPosition()) <= ApisK0SurroundingsConfig.LootRange() {
        label = this.Notable(container.ApisK0LootQuality(), container.ApisK0IsIconic());
        if StrLen(label) > 0 && this.Visible(eye, container.GetWorldPosition() + new Vector4(0.0, 0.0, 0.5, 0.0), raycasts) {
          ArrayPush(found, label + " container");
        };
      };
      i += 1;
    };
    i = 0;
    while i < ArraySize(this.m_drops) {
      drop = this.m_drops[i];
      if IsDefined(drop) && drop.IsAttached() && !drop.ApisK0IsEmpty()
        && Vector4.Distance(drop.GetWorldPosition(), player.GetWorldPosition()) <= ApisK0SurroundingsConfig.LootRange() {
        label = this.Notable(drop.ApisK0LootQuality(), drop.ApisK0IsIconic());
        if StrLen(label) > 0 && this.Visible(eye, drop.GetWorldPosition() + new Vector4(0.0, 0.0, 0.3, 0.0), raycasts) {
          ArrayPush(found, label + " item on the ground");
        };
      };
      i += 1;
    };
    this.m_loot = this.Join(found, ", ");
  }

  // "iconic", "legendary" or "" (not notable).
  private func Notable(quality: gamedataQuality, iconic: Bool) -> String {
    if iconic || Equals(quality, gamedataQuality.Iconic) {
      return "iconic";
    };
    if Equals(quality, gamedataQuality.Legendary) || Equals(quality, gamedataQuality.LegendaryPlus) || Equals(quality, gamedataQuality.LegendaryPlusPlus) {
      return "legendary";
    };
    return "";
  }

  private func ScanVehicles(player: ref<PlayerPuppet>) -> Void {
    let found: array<String>;
    let vehicle: ref<VehicleObject>;
    let label: String;
    let i: Int32 = 0;
    while i < ArraySize(this.m_vehicles) {
      vehicle = this.m_vehicles[i];
      if IsDefined(vehicle) && vehicle.IsAttached() && !vehicle.IsDestroyed()
        && Vector4.Distance(vehicle.GetWorldPosition(), player.GetWorldPosition()) <= ApisK0SurroundingsConfig.VehicleRange() {
        label = this.VehicleLabel(vehicle, player);
        if StrLen(label) > 0 && !ArrayContains(found, label) {
          ArrayPush(found, label);
        };
      };
      i += 1;
    };
    this.m_vehiclesState = this.Join(found, ", ");
  }

  // "V's own vehicle", "an AV", "a police car", "a <faction> vehicle with hostiles in it" or "" (not notable).
  private func VehicleLabel(vehicle: ref<VehicleObject>, player: ref<PlayerPuppet>) -> String {
    let record: wref<Vehicle_Record> = vehicle.GetRecord();
    let passengers: array<wref<GameObject>>;
    let i: Int32;
    if vehicle.IsPlayerVehicle() {
      return "V's own vehicle";
    };
    if IsDefined(vehicle as AVObject) {
      return "an AV";
    };
    if IsDefined(record) && IsDefined(record.Affiliation()) && Equals(record.Affiliation().Type(), gamedataAffiliation.NCPD) {
      return "a police car";
    };
    if vehicle.HasPassengers() {
      VehicleComponent.GetAllPassengers(vehicle.GetGame(), vehicle.GetEntityID(), false, passengers);
      i = 0;
      while i < ArraySize(passengers) {
        if IsDefined(passengers[i]) && Equals(GameObject.GetAttitudeTowards(passengers[i], player), EAIAttitude.AIA_Hostile) {
          return "a vehicle with hostiles in it";
        };
        i += 1;
      };
    };
    return "";
  }

  // --- state ---

  public func GetState() -> array<String> {
    let state: array<String>;
    if StrLen(this.m_fight) > 0 {
      ArrayPush(state, "fight_nearby=" + this.m_fight);
    };
    if StrLen(this.m_bodiesState) > 0 {
      ArrayPush(state, "bodies=" + this.m_bodiesState);
    };
    if StrLen(this.m_loot) > 0 {
      ArrayPush(state, "notable_loot=" + this.m_loot);
    };
    if StrLen(this.m_vehiclesState) > 0 {
      ArrayPush(state, "vehicles=" + this.m_vehiclesState);
    };
    return state;
  }

  // Words for the "tension=" sensor.
  public func GetTensionWords() -> array<String> {
    let words: array<String>;
    if this.m_fightClose {
      ArrayPush(words, "a fight close by");
    };
    if this.m_bodiesAtRisk {
      ArrayPush(words, "a body an enemy could find");
    };
    return words;
  }

  // --- helpers ---

  private func Visible(eye: Vector4, target: Vector4, out raycasts: Int32) -> Bool {
    let result: TraceResult;
    if raycasts >= ApisK0SurroundingsConfig.MaxRaycastsPerScan() {
      return false;
    };
    raycasts += 1;
    if !GameInstance.GetSpatialQueriesSystem(GetGameInstance()).SyncRaycastByQueryPreset(eye, target, n"Sight Blocker", result) {
      return true;
    };
    return Vector4.Distance(Vector4.Vector3To4(result.position), target) <= ApisK0SurroundingsConfig.SightTolerance();
  }

  private func EyePosition(player: ref<PlayerPuppet>) -> Vector4 {
    let camera: Transform;
    if GameInstance.GetCameraSystem(GetGameInstance()).GetActiveCameraWorldTransform(camera) {
      return Transform.GetPosition(camera);
    };
    return player.GetWorldPosition() + new Vector4(0.0, 0.0, 1.7, 0.0);
  }

  private func Faction(npc: ref<NPCPuppet>) -> String {
    let record: wref<Affiliation_Record> = npc.GetRecord().Affiliation();
    if npc.IsCharacterPolice() {
      return "NCPD";
    };
    if !IsDefined(record) {
      return "Unknown";
    };
    return NameToString(record.EnumName());
  }

  private func Join(items: array<String>, separator: String) -> String {
    let text: String;
    let i: Int32 = 0;
    while i < ArraySize(items) {
      text += (i > 0 ? separator : "") + items[i];
      i += 1;
    };
    return text;
  }
}

// --- accessors for private game fields ---

@addMethod(gameLootContainerBase)
public func ApisK0LootQuality() -> gamedataQuality {
  return this.m_lootQuality;
}

@addMethod(gameLootContainerBase)
public func ApisK0IsIconic() -> Bool {
  return this.m_isIconic;
}

@addMethod(gameLootObject)
public func ApisK0LootQuality() -> gamedataQuality {
  return this.m_lootQuality;
}

@addMethod(gameItemDropObject)
public func ApisK0IsIconic() -> Bool {
  return this.m_isIconic;
}

@addMethod(gameItemDropObject)
public func ApisK0IsEmpty() -> Bool {
  return this.m_isEmpty;
}

// A body put in a disposal container (dumpster, fridge...) is hidden.
@wrapMethod(DisposalDevice)
private final func SetNpcIsDisposedBlackboard() -> Void {
  let system: ref<ApisK0System>;
  wrappedMethod();
  system = ApisK0System.Get(this.GetGame());
  if IsDefined(system) && IsDefined(this.m_npcBody) {
    system.OnBodyHidden(this.m_npcBody.GetEntityID());
  };
}
