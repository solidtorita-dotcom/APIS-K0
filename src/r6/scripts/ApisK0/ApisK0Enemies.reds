// APIS-K0 - phase 4, piece 3: the enemies Apiko perceives around V (DISENO.md, "Pieza 3"). Apiko never fights: it
// perceives, warns and judges.
// - Enemies: NPCs hostile to V now, plus potential ones (armed gang or corp members, aggressive and not civilians,
//   police or vendors) that would attack V in their territory but have not yet.
// - Same two levels as devices (ApisK0Devices.reds):
//   - "here": a clear line from V's eyes (any direction) or from the drone, within SightRange. A new enemy needs
//     a clear line in two scans in a row (one-scan glimpses through gaps are leaks), and the drone only counts while
//     it is in V's space itself (a clear line from V's eyes to it).
//   - known elsewhere, live: tagged by V in focus mode, in a squad V pinged now, or seen by a camera of a breached
//     network; up to NetworkRange.
//   - remembered: an enemy Apiko lost sight of keeps the card it had when last seen (position, health, awareness),
//     never live readings, and is forgotten after MemorySeconds or when V moves away from where it was.
// - Each known enemy gets a detailed card (faction, role, rarity, difficulty for V, awareness of V, health, weapon,
//   visible cyberware, own name) sent to the bridge as one "enemies=" state line.
// - World events for the diary: V killed or knocked out an enemy (and how), a boss fell, an enemy detected V.
// - Tension (2026-11-07): enemies around are often no threat at all. The "tension=" sensor says why they matter
//   now (restricted or hostile security area, weapon drawn, V sneaking, an enemy noticing V, combat); the bridge
//   only shows enemies to the model with tension or when V asks. Entering a restricted or hostile area is a world
//   event ("zone|restricted|" / "zone|dangerous|") for a written line.
// - Warnings (written lines, never the model): an enemy netrunner hacking V, a sniper with V in sight, an enemy in
//   combat right behind V and out of view, an elite/boss/heavy/mech showing up.
module ApisK0

public abstract class ApisK0EnemiesConfig {
  public static func ScanInterval() -> Float { return 1.0; }
  // Enemies are seen ("here") up to this distance from V (meters).
  public static func SightRange() -> Float { return 40.0; }
  // Tagged, pinged or camera-seen enemies are known up to this distance from V.
  public static func NetworkRange() -> Float { return 60.0; }
  // Line-of-sight raycasts per scan (V's eyes, the drone, network cameras).
  public static func MaxRaycastsPerScan() -> Int32 { return 60; }
  // A raycast that stops this close to the enemy still counts as a clear line (it often hits the body itself).
  public static func SightTolerance() -> Float { return 0.8; }
  // V's eyes to the drone: a ray that stops this close to it still counts (it hits the drone's own body).
  public static func DroneTolerance() -> Float { return 1.0; }
  // An enemy out of sight (and not tagged, pinged or on a camera) is forgotten this many seconds after last seen.
  public static func MemorySeconds() -> Float { return 30.0; }
  // Height above the enemy's feet aimed at by the raycasts (chest).
  public static func AimHeight() -> Float { return 1.2; }
  // A breached camera sees enemies up to this distance from it.
  public static func CameraRange() -> Float { return 25.0; }
  public static func FloorHeight() -> Float { return 2.0; }
  public static func MaxListed() -> Int32 { return 15; }
  public static func MaxQueuedEvents() -> Int32 { return 30; }
  // "Enemy behind V" warning: closer than this, and again for the same enemy only after BehindRepeat seconds.
  public static func BehindDistance() -> Float { return 6.0; }
  public static func BehindRepeat() -> Float { return 20.0; }
  // A sniper with V in sight is announced again only after this many seconds.
  public static func SniperRepeat() -> Float { return 30.0; }
  // Several enemies of a squad detect V at once: one "detected" event per this many seconds.
  public static func DetectedRepeat() -> Float { return 15.0; }
}

public class ApisK0KnownEnemy extends IScriptable {
  // Short id shown to the model ("e3"); stable while the enemy stays known, so V's orders can refer to it.
  public let shortID: Int32;
  public let entityID: EntityID;
  public let npc: wref<NPCPuppet>;
  // Card, read once: gamedataAffiliation name ("TygerClaws"), role, rarity, own name ("" for generic ones),
  // visible cyberware ("sandevistan+mantis blades").
  public let faction: String;
  public let role: String;
  public let threat: String;
  public let name: String;
  public let cyberware: String;
  // Live readings.
  public let power: String;
  public let weapon: String;
  public let distance: Float;
  public let direction: String;
  public let awareness: String;
  public let health: Int32;
  public let hostile: Bool;
  public let targetingV: Bool;
  public let hackingV: Bool;
  // In the same space as V right now (clear line from V's eyes or from the drone).
  public let here: Bool;
  public let pinged: Bool;
  public let tagged: Bool;
  public let byCamera: Bool;
  // How Apiko first learned of it: "V sight", "drone sight", "tagged", "ping" or "camera" (debug window).
  public let source: String;
  public let lastScan: Int32;
  // Last time and place Apiko perceived it live (seen, tagged, pinged or on a camera).
  public let lastSeen: Float;
  public let lastPosition: Vector4;
  public let nextBehindWarning: Float;
  public let nextSniperWarning: Float;
}

public class ApisK0Enemies extends IScriptable {
  private let m_known: array<ref<ApisK0KnownEnemy>>;
  private let m_events: array<String>;
  private let m_nextScan: Float;
  private let m_scan: Int32;
  private let m_nextShortID: Int32;
  // Enemies already announced by the "elite" warning, and netrunners already hacking V (one warning per upload).
  private let m_announced: array<EntityID>;
  private let m_hackers: array<EntityID>;
  private let m_nextDetected: Float;
  private let m_vInCombat: Bool;
  // Debug window.
  private let m_lastQueried: Int32;
  // Every NPC the last scan queried, and whether this tick scanned: the people scan (ApisK0People.reds) reuses it.
  private let m_found: array<ref<NPCPuppet>>;
  // Enemies V downed since the last drain: their bodies (ApisK0Surroundings.reds).
  private let m_downedByV: array<ref<NPCPuppet>>;
  private let m_scanned: Bool;
  private let m_lastCandidates: Int32;
  private let m_lastRaycasts: Int32;
  private let m_eye: Vector4;
  private let m_now: Float;
  // The drone has a clear line to V's eyes this scan: only then does its own sight count.
  private let m_droneInSpace: Bool;
  // Enemies with a clear line last scan but not known yet (a second one in a row makes them known), and this scan's.
  private let m_glimpsed: array<EntityID>;
  private let m_glimpsing: array<EntityID>;
  // V's security area at the last scan (-1 = not read yet after a load: the first reading fires no event).
  private let m_zone: Int32;
  // NCPD officers not hostile to V, perceived like enemies (sight in two scans, tag, ping, camera, remembered) but
  // only counted (PoliceSummary, for ApisK0People.reds). Hostile police are enemies.
  private let m_police: array<ref<ApisK0KnownEnemy>>;

  public static func Create(game: GameInstance) -> ref<ApisK0Enemies> {
    let enemies: ref<ApisK0Enemies> = new ApisK0Enemies();
    enemies.m_nextShortID = 1;
    return enemies;
  }

  public func Reset() -> Void {
    ArrayClear(this.m_known);
    ArrayClear(this.m_police);
    ArrayClear(this.m_events);
    ArrayClear(this.m_announced);
    ArrayClear(this.m_hackers);
    ArrayClear(this.m_glimpsed);
    ArrayClear(this.m_glimpsing);
    this.m_zone = -1;
    this.m_nextScan = 0.0;
    this.m_nextDetected = 0.0;
  }

  // Session end: drop every NPC reference (m_found and m_downedByV hold strong ones).
  public func Release() -> Void {
    this.Reset();
    ArrayClear(this.m_found);
    ArrayClear(this.m_downedByV);
    this.m_scanned = false;
  }

  // World events, "action|kind|detail". Oldest first; clears the queue.
  public func DrainEvents() -> array<String> {
    let events: array<String> = this.m_events;
    ArrayClear(this.m_events);
    return events;
  }

  private func PushEvent(action: String, kind: String, detail: String) -> Void {
    ArrayPush(this.m_events, action + "|" + kind + "|" + detail);
    if ArraySize(this.m_events) > ApisK0EnemiesConfig.MaxQueuedEvents() {
      ArrayErase(this.m_events, 0);
    };
  }

  // Called from the system tick while Apiko is awake. `drone` may be null (not spawned yet).
  public func Update(now: Float, player: ref<PlayerPuppet>, drone: ref<GameObject>, devices: ref<ApisK0Devices>) -> Void {
    let found: array<ref<NPCPuppet>>;
    let cameras: array<wref<Device>>;
    let npc: ref<NPCPuppet>;
    let known: ref<ApisK0KnownEnemy>;
    let distance: Float;
    let raycasts: Int32;
    let sight: String;
    let how: String;
    let pinged: Bool;
    let tagged: Bool;
    let network: ref<NetworkSystem>;
    let i: Int32;
    this.m_scanned = false;
    if now < this.m_nextScan || !IsDefined(player) {
      return;
    };
    this.m_nextScan = now + ApisK0EnemiesConfig.ScanInterval();
    this.m_scanned = true;
    ArrayClear(this.m_found);
    // Apiko is not around while V drives; what it knew is stale when V gets out.
    if IsDefined(GetMountedVehicle(player)) {
      ArrayClear(this.m_known);
      ArrayClear(this.m_police);
      ArrayClear(this.m_glimpsed);
      return;
    };
    this.m_scan += 1;
    this.m_now = now;
    this.m_eye = this.EyePosition(player);
    this.m_droneInSpace = false;
    if IsDefined(drone) {
      raycasts += 1;
      this.m_droneInSpace = this.DroneInSpace(drone);
    };
    this.CheckZone(player);
    // First what happened to the enemies Apiko knew: killed or knocked out since the last scan.
    this.CheckDowned(player);
    found = this.QueryNPCs(player);
    this.m_found = found;
    this.m_lastQueried = ArraySize(found);
    this.m_lastCandidates = 0;
    cameras = devices.GetNetworkCameras();
    network = GameInstance.GetScriptableSystemsContainer(GetGameInstance()).Get(n"NetworkSystem") as NetworkSystem;
    i = 0;
    while i < ArraySize(found) {
      npc = found[i];
      if this.IsQuietPolice(npc, player) {
        this.TrackPolice(npc, now, player, drone, cameras, network, raycasts);
      } else {
      if this.IsEnemy(npc, player) {
        this.DropPolice(npc.GetEntityID());
        this.m_lastCandidates += 1;
        distance = Vector4.Distance(npc.GetWorldPosition(), player.GetWorldPosition());
        this.CheckHacking(npc);
        pinged = IsDefined(network) && network.IsSquadMarkedWithPing(AISquadHelper.GetSquadName(npc));
        tagged = npc.IsTaggedinFocusMode();
        // "V sight", "drone sight", "" (no clear line) or "?" (not checked: out of range or out of raycasts).
        sight = distance <= ApisK0EnemiesConfig.SightRange() ? this.Sight(npc, player, drone, raycasts) : "";
        known = this.FindKnown(npc.GetEntityID());
        if IsDefined(known) {
          known.lastScan = this.m_scan;
          if NotEquals(sight, "?") {
            known.here = StrLen(sight) > 0;
          };
          // Live sources only while they last (a ping wears off); then the enemy is remembered, not tracked.
          known.pinged = pinged;
          known.tagged = tagged;
          known.byCamera = !known.here && this.SeenByCamera(npc, cameras, raycasts);
          if this.Live(known) {
            known.lastSeen = now;
            known.lastPosition = npc.GetWorldPosition();
            this.Refresh(known, now, player, distance);
          };
        } else {
          how = this.FirstSource(npc, sight, tagged, pinged, cameras, raycasts);
          if StrLen(how) > 0 {
            this.AddKnown(npc, now, player, distance, how);
          };
        };
      };
      };
      i += 1;
    };
    this.m_glimpsed = this.m_glimpsing;
    ArrayClear(this.m_glimpsing);
    this.UpdateRemembered(this.m_known, player);
    this.UpdateRemembered(this.m_police, player);
    this.m_lastRaycasts = raycasts;
    this.ForgetGone(now);
    this.ForgetPolice(now);
    this.m_vInCombat = player.IsInCombat();
  }

  // V's security area: ESecurityAreaType as Int32 (0 disabled, 1 safe, 2 restricted, 3 dangerous).
  private func Zone(player: ref<PlayerPuppet>) -> Int32 {
    let blackboard: ref<IBlackboard> = player.GetPlayerStateMachineBlackboard();
    let variant: Variant;
    let data: SecurityAreaData;
    if !IsDefined(blackboard) {
      return 0;
    };
    variant = blackboard.GetVariant(GetAllBlackboardDefs().PlayerStateMachine.SecurityZoneData);
    if !IsDefined(variant) {
      return 0;
    };
    data = FromVariant<SecurityAreaData>(variant);
    return EnumInt(data.securityAreaType);
  }

  // Entering a restricted or hostile area (from a safer one) is a world event for a written line.
  private func CheckZone(player: ref<PlayerPuppet>) -> Void {
    let zone: Int32 = this.Zone(player);
    if this.m_zone >= 0 && zone > this.m_zone && zone >= 2 {
      this.PushEvent("zone", zone >= 3 ? "dangerous" : "restricted", "");
    };
    this.m_zone = zone;
  }

  // Why enemies matter right now, as words joined by ", " ("" = no tension: enemies around are just around).
  // Weapon and sneaking only count with enemies known.
  public func GetTension(player: ref<PlayerPuppet>) -> String {
    let words: array<String>;
    let zone: Int32;
    let blackboard: ref<IBlackboard>;
    let known: ref<ApisK0KnownEnemy>;
    let noticed: Bool;
    let hostileNear: Bool;
    let tension: String;
    let i: Int32;
    if !IsDefined(player) {
      return "";
    };
    zone = this.Zone(player);
    if zone >= 3 {
      ArrayPush(words, "hostile area");
    } else {
      if zone == 2 {
        ArrayPush(words, "restricted area");
      };
    };
    if player.IsInCombat() {
      ArrayPush(words, "combat");
    };
    i = 0;
    while i < ArraySize(this.m_known) {
      known = this.m_known[i];
      if this.Live(known) {
        if Equals(known.awareness, "suspicious") || Equals(known.awareness, "searching") || Equals(known.awareness, "combat") {
          noticed = true;
        } else {
          if known.hostile && Equals(known.awareness, "calm") {
            hostileNear = true;
          };
        };
      };
      i += 1;
    };
    if noticed {
      ArrayPush(words, "an enemy is onto V");
    };
    // Hostile to V but unaware of V yet (gangs that shoot on sight, a hostile area).
    if hostileNear {
      ArrayPush(words, "hostiles near, unaware of V");
    };
    if ArraySize(this.m_known) > 0 {
      if IsDefined(ScriptedPuppet.GetActiveWeapon(player)) {
        ArrayPush(words, "weapon drawn");
      };
      blackboard = player.GetPlayerStateMachineBlackboard();
      if IsDefined(blackboard) && blackboard.GetInt(GetAllBlackboardDefs().PlayerStateMachine.Locomotion) == EnumInt(gamePSMLocomotionStates.Crouch) {
        ArrayPush(words, "sneaking");
      };
    };
    i = 0;
    while i < ArraySize(words) {
      tension += (i > 0 ? ", " : "") + words[i];
      i += 1;
    };
    return tension;
  }

  public func GetFound() -> array<ref<NPCPuppet>> {
    return this.m_found;
  }

  public func ScannedThisTick() -> Bool {
    return this.m_scanned;
  }

  // Perceived live right now: seen, tagged, in a pinged squad or on a breached camera.
  private func Live(known: ref<ApisK0KnownEnemy>) -> Bool {
    return known.here || known.pinged || known.tagged || known.byCamera;
  }

  // A new enemy with a clear line ("?" = not checked this scan). True on the second scan in a row with one; a
  // "?" keeps a pending glimpse for the next scan without confirming it.
  private func Glimpse(id: EntityID, sight: String) -> Bool {
    let pending: Bool = ArrayContains(this.m_glimpsed, id);
    if Equals(sight, "?") {
      if pending {
        ArrayPush(this.m_glimpsing, id);
      };
      return false;
    };
    if pending {
      return true;
    };
    ArrayPush(this.m_glimpsing, id);
    return false;
  }

  // How Apiko first learns of an NPC this scan: a clear line in two scans in a row ("V sight" / "drone sight"),
  // "tagged", "ping", "camera", or "" (not perceived).
  private func FirstSource(npc: ref<NPCPuppet>, sight: String, tagged: Bool, pinged: Bool, cameras: array<wref<Device>>,
    out raycasts: Int32) -> String {
    if StrLen(sight) > 0 && this.Glimpse(npc.GetEntityID(), sight) {
      return sight;
    };
    if tagged {
      return "tagged";
    };
    if pinged {
      return "ping";
    };
    if this.SeenByCamera(npc, cameras, raycasts) {
      return "camera";
    };
    return "";
  }

  // An NCPD officer not hostile to V (a hostile one is an enemy).
  private func IsQuietPolice(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>) -> Bool {
    return npc.IsActive() && !npc.IsCrowd() && npc.IsCharacterPolice()
      && NotEquals(GameObject.GetAttitudeTowards(npc, player), EAIAttitude.AIA_Hostile);
  }

  // The enemy perception for a quiet officer, without the card or events: only where and how Apiko knows of it.
  private func TrackPolice(npc: ref<NPCPuppet>, now: Float, player: ref<PlayerPuppet>, drone: ref<GameObject>,
    cameras: array<wref<Device>>, network: ref<NetworkSystem>, out raycasts: Int32) -> Void {
    let distance: Float = Vector4.Distance(npc.GetWorldPosition(), player.GetWorldPosition());
    let pinged: Bool = IsDefined(network) && network.IsSquadMarkedWithPing(AISquadHelper.GetSquadName(npc));
    let tagged: Bool = npc.IsTaggedinFocusMode();
    let sight: String = distance <= ApisK0EnemiesConfig.SightRange() ? this.Sight(npc, player, drone, raycasts) : "";
    let cop: ref<ApisK0KnownEnemy> = this.FindPolice(npc.GetEntityID());
    let how: String;
    if IsDefined(cop) {
      cop.lastScan = this.m_scan;
      if NotEquals(sight, "?") {
        cop.here = StrLen(sight) > 0;
      };
      cop.pinged = pinged;
      cop.tagged = tagged;
      cop.byCamera = !cop.here && this.SeenByCamera(npc, cameras, raycasts);
      if this.Live(cop) {
        cop.lastSeen = now;
        cop.lastPosition = npc.GetWorldPosition();
        cop.distance = distance;
      };
      return;
    };
    how = this.FirstSource(npc, sight, tagged, pinged, cameras, raycasts);
    if StrLen(how) == 0 {
      return;
    };
    cop = new ApisK0KnownEnemy();
    cop.entityID = npc.GetEntityID();
    cop.npc = npc;
    cop.source = how;
    cop.lastScan = this.m_scan;
    cop.lastSeen = now;
    cop.lastPosition = npc.GetWorldPosition();
    cop.distance = distance;
    cop.here = Equals(how, "V sight") || Equals(how, "drone sight");
    cop.pinged = Equals(how, "ping");
    cop.tagged = Equals(how, "tagged");
    cop.byCamera = Equals(how, "camera");
    cop.threat = this.Threat(npc);
    ArrayPush(this.m_police, cop);
  }

  private func FindPolice(id: EntityID) -> ref<ApisK0KnownEnemy> {
    let i: Int32 = 0;
    while i < ArraySize(this.m_police) {
      if this.m_police[i].entityID == id {
        return this.m_police[i];
      };
      i += 1;
    };
    return null;
  }

  // An officer that turned hostile is an enemy now.
  private func DropPolice(id: EntityID) -> Void {
    let i: Int32 = ArraySize(this.m_police) - 1;
    while i >= 0 {
      if this.m_police[i].entityID == id {
        ArrayErase(this.m_police, i);
      };
      i -= 1;
    };
  }

  // Same forgetting as enemies; a dead or unconscious officer is dropped.
  private func ForgetPolice(now: Float) -> Void {
    let cop: ref<ApisK0KnownEnemy>;
    let npc: ref<NPCPuppet>;
    let limit: Float;
    let forget: Bool;
    let i: Int32 = ArraySize(this.m_police) - 1;
    while i >= 0 {
      cop = this.m_police[i];
      npc = cop.npc;
      forget = !IsDefined(npc) || npc.IsDead() || ScriptedPuppet.IsUnconscious(npc);
      if !forget {
        if this.Live(cop) {
          limit = cop.here ? ApisK0EnemiesConfig.SightRange() : ApisK0EnemiesConfig.NetworkRange();
          forget = cop.distance > limit;
        } else {
          forget = now - cop.lastSeen > ApisK0EnemiesConfig.MemorySeconds() || cop.distance > ApisK0EnemiesConfig.SightRange();
        };
      };
      if forget {
        ArrayErase(this.m_police, i);
      };
      i -= 1;
    };
  }

  // Quiet police Apiko perceives: "2 here, 1 elsewhere, 1 out of sight, 1 MaxTac" ("" = none). Elsewhere = tagged,
  // pinged or on a camera; out of sight = seen lately, remembered.
  public func PoliceSummary() -> String {
    let here: Int32;
    let away: Int32;
    let lost: Int32;
    let maxtac: Int32;
    let cop: ref<ApisK0KnownEnemy>;
    let parts: array<String>;
    let summary: String;
    let i: Int32 = 0;
    while i < ArraySize(this.m_police) {
      cop = this.m_police[i];
      if cop.here {
        here += 1;
      } else {
        if this.Live(cop) {
          away += 1;
        } else {
          lost += 1;
        };
      };
      if Equals(cop.threat, "maxtac") {
        maxtac += 1;
      };
      i += 1;
    };
    if here > 0 {
      ArrayPush(parts, IntToString(here) + " here");
    };
    if away > 0 {
      ArrayPush(parts, IntToString(away) + " elsewhere");
    };
    if lost > 0 {
      ArrayPush(parts, IntToString(lost) + " out of sight");
    };
    if maxtac > 0 {
      ArrayPush(parts, IntToString(maxtac) + " MaxTac");
    };
    i = 0;
    while i < ArraySize(parts) {
      summary += (i > 0 ? ", " : "") + parts[i];
      i += 1;
    };
    return summary;
  }

  // Remembered NPCs (not live): no live readings, only where they were last seen, from where V is now. NPCs the
  // query no longer returned (out of range, dead) are not live either.
  private func UpdateRemembered(list: array<ref<ApisK0KnownEnemy>>, player: ref<PlayerPuppet>) -> Void {
    let known: ref<ApisK0KnownEnemy>;
    let i: Int32 = 0;
    while i < ArraySize(list) {
      known = list[i];
      if known.lastScan != this.m_scan {
        known.here = false;
        known.pinged = false;
        known.tagged = false;
        known.byCamera = false;
      };
      if !this.Live(known) {
        known.distance = Vector4.Distance(known.lastPosition, player.GetWorldPosition());
        known.direction = this.Direction(known.lastPosition, player);
        known.targetingV = false;
        known.hackingV = false;
      };
      i += 1;
    };
  }

  // A clear line from V's eyes to the drone: it is in V's space, not inside a wall, a ceiling or on another floor.
  private func DroneInSpace(drone: ref<GameObject>) -> Bool {
    let result: TraceResult;
    let target: Vector4 = drone.GetWorldPosition();
    if !GameInstance.GetSpatialQueriesSystem(GetGameInstance()).SyncRaycastByQueryPreset(this.m_eye, target, n"Sight Blocker", result) {
      return true;
    };
    return Vector4.Distance(Vector4.Vector3To4(result.position), target) <= ApisK0EnemiesConfig.DroneTolerance();
  }

  // NPCs near V the targeting system knows about (seen or not).
  private func QueryNPCs(player: ref<PlayerPuppet>) -> array<ref<NPCPuppet>> {
    let query: TargetSearchQuery;
    let parts: array<TS_TargetPartInfo>;
    let component: ref<TargetingComponent>;
    let npc: ref<NPCPuppet>;
    let npcs: array<ref<NPCPuppet>>;
    let i: Int32;
    query.testedSet = TargetingSet.Complete;
    query.searchFilter = TSF_Any(TSFMV.Obj_Puppet);
    query.maxDistance = ApisK0EnemiesConfig.NetworkRange();
    query.filterObjectByDistance = true;
    query.includeSecondaryTargets = false;
    query.ignoreInstigator = true;
    GameInstance.GetTargetingSystem(GetGameInstance()).GetTargetParts(player, query, parts);
    i = 0;
    while i < ArraySize(parts) {
      component = TS_TargetPartInfo.GetComponent(parts[i]);
      if IsDefined(component) {
        npc = component.GetEntity() as NPCPuppet;
        if IsDefined(npc) && !ArrayContains(npcs, npc) {
          ArrayPush(npcs, npc);
        };
      };
      i += 1;
    };
    return npcs;
  }

  // Hostile to V now, or a potential enemy: aggressive (gang and corp presets), not a civilian, cop or vendor.
  // Apiko's own drone and V's companions are friendly, so they never pass.
  public func IsEnemyOf(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>) -> Bool {
    return this.IsEnemy(npc, player);
  }

  public func DrainDowned() -> array<ref<NPCPuppet>> {
    let downed: array<ref<NPCPuppet>> = this.m_downedByV;
    ArrayClear(this.m_downedByV);
    return downed;
  }

  private func IsEnemy(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>) -> Bool {
    let attitude: EAIAttitude;
    if !npc.IsActive() || npc.IsCrowd() {
      return false;
    };
    attitude = GameObject.GetAttitudeTowards(npc, player);
    if Equals(attitude, EAIAttitude.AIA_Hostile) {
      return true;
    };
    if Equals(attitude, EAIAttitude.AIA_Friendly) {
      return false;
    };
    return !npc.IsCharacterCivilian() && !npc.IsCharacterPolice() && !npc.IsVendor() && npc.IsAggressive();
  }

  private func EyePosition(player: ref<PlayerPuppet>) -> Vector4 {
    let camera: Transform;
    if GameInstance.GetCameraSystem(GetGameInstance()).GetActiveCameraWorldTransform(camera) {
      return Transform.GetPosition(camera);
    };
    return player.GetWorldPosition() + new Vector4(0.0, 0.0, 1.7, 0.0);
  }

  private func Chest(npc: ref<NPCPuppet>) -> Vector4 {
    return npc.GetWorldPosition() + new Vector4(0.0, 0.0, ApisK0EnemiesConfig.AimHeight(), 0.0);
  }

  // "V sight" (on screen and visible, or a clear line from V's eyes in any direction), "drone sight", "" or "?".
  private func Sight(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>, drone: ref<GameObject>, out raycasts: Int32) -> String {
    let target: Vector4 = this.Chest(npc);
    if GameInstance.GetTargetingSystem(GetGameInstance()).IsVisibleTarget(player, npc) {
      return "V sight";
    };
    if raycasts >= ApisK0EnemiesConfig.MaxRaycastsPerScan() {
      return "?";
    };
    raycasts += 1;
    if this.ClearLine(this.m_eye, target) {
      return "V sight";
    };
    if !IsDefined(drone) || !this.m_droneInSpace {
      return "";
    };
    if raycasts >= ApisK0EnemiesConfig.MaxRaycastsPerScan() {
      return "?";
    };
    raycasts += 1;
    if this.ClearLine(drone.GetWorldPosition(), target) {
      return "drone sight";
    };
    return "";
  }

  // A camera of a breached network (switched on, close enough) has a clear line to the enemy. Field of view is not
  // checked: a breached camera can be turned at will.
  private func SeenByCamera(npc: ref<NPCPuppet>, cameras: array<wref<Device>>, out raycasts: Int32) -> Bool {
    let target: Vector4 = this.Chest(npc);
    let camera: wref<Device>;
    let i: Int32 = 0;
    while i < ArraySize(cameras) {
      camera = cameras[i];
      if IsDefined(camera) && Vector4.Distance(camera.GetWorldPosition(), target) <= ApisK0EnemiesConfig.CameraRange() {
        if raycasts >= ApisK0EnemiesConfig.MaxRaycastsPerScan() {
          return false;
        };
        raycasts += 1;
        if this.ClearLine(camera.GetWorldPosition(), target) {
          return true;
        };
      };
      i += 1;
    };
    return false;
  }

  private func ClearLine(start: Vector4, end: Vector4) -> Bool {
    let result: TraceResult;
    if !GameInstance.GetSpatialQueriesSystem(GetGameInstance()).SyncRaycastByQueryPreset(start, end, n"Sight Blocker", result) {
      return true;
    };
    return Vector4.Distance(Vector4.Vector3To4(result.position), end) <= ApisK0EnemiesConfig.SightTolerance();
  }

  private func FindKnown(id: EntityID) -> ref<ApisK0KnownEnemy> {
    let i: Int32 = 0;
    while i < ArraySize(this.m_known) {
      if this.m_known[i].entityID == id {
        return this.m_known[i];
      };
      i += 1;
    };
    return null;
  }

  private func AddKnown(npc: ref<NPCPuppet>, now: Float, player: ref<PlayerPuppet>, distance: Float, source: String) -> Void {
    let known: ref<ApisK0KnownEnemy> = new ApisK0KnownEnemy();
    known.shortID = this.m_nextShortID;
    this.m_nextShortID += 1;
    known.entityID = npc.GetEntityID();
    known.npc = npc;
    known.source = source;
    known.lastScan = this.m_scan;
    known.lastSeen = now;
    known.lastPosition = npc.GetWorldPosition();
    known.here = Equals(source, "V sight") || Equals(source, "drone sight");
    known.pinged = Equals(source, "ping");
    known.tagged = Equals(source, "tagged");
    known.byCamera = Equals(source, "camera");
    known.faction = this.Faction(npc);
    known.role = this.Role(npc);
    known.threat = this.Threat(npc);
    known.name = this.OwnName(npc);
    known.cyberware = this.Cyberware(npc);
    this.Read(known, player, distance);
    ArrayPush(this.m_known, known);
    if this.IsNotable(known) && !ArrayContains(this.m_announced, known.entityID) {
      ArrayPush(this.m_announced, known.entityID);
      this.PushEvent("warn_elite", this.Describe(known), known.name);
    };
  }

  // Updates a known enemy and queues events for what changed (detected V, sniper, behind V).
  private func Refresh(known: ref<ApisK0KnownEnemy>, now: Float, player: ref<PlayerPuppet>, distance: Float) -> Void {
    let wasAware: Bool = Equals(known.awareness, "combat");
    this.Read(known, player, distance);
    // Detected: this enemy turned to fight V, and V was not in a fight already (then it is no news).
    if !wasAware && Equals(known.awareness, "combat") && known.targetingV && !this.m_vInCombat && now >= this.m_nextDetected {
      this.m_nextDetected = now + ApisK0EnemiesConfig.DetectedRepeat();
      this.PushEvent("detected", this.Describe(known), "");
    };
    if Equals(known.role, "sniper") && Equals(known.awareness, "combat") && known.targetingV && now >= known.nextSniperWarning
      && known.npc.GetSensesComponent().IsAgentVisible(player) {
      known.nextSniperWarning = now + ApisK0EnemiesConfig.SniperRepeat();
      this.PushEvent("warn_sniper", this.Describe(known), "");
    };
    if known.here && known.hostile && Equals(known.awareness, "combat") && known.distance <= ApisK0EnemiesConfig.BehindDistance()
      && StrBeginsWith(known.direction, "behind") && now >= known.nextBehindWarning
      && !GameInstance.GetTargetingSystem(GetGameInstance()).IsVisibleTarget(player, known.npc) {
      known.nextBehindWarning = now + ApisK0EnemiesConfig.BehindRepeat();
      this.PushEvent("warn_behind", this.Describe(known), "");
    };
  }

  // An enemy netrunner started uploading a quickhack to V (the game outlines it in red): one warning per upload.
  private func CheckHacking(npc: ref<NPCPuppet>) -> Void {
    let id: EntityID = npc.GetEntityID();
    if npc.IsHackingPlayer() {
      if !ArrayContains(this.m_hackers, id) {
        ArrayPush(this.m_hackers, id);
        this.PushEvent("warn_netrunner", this.Faction(npc), "");
      };
    } else {
      ArrayRemove(this.m_hackers, id);
    };
  }

  private func Read(known: ref<ApisK0KnownEnemy>, player: ref<PlayerPuppet>, distance: Float) -> Void {
    let npc: ref<NPCPuppet> = known.npc;
    let weapon: wref<WeaponObject>;
    if !IsDefined(npc) {
      return;
    };
    known.distance = distance;
    known.direction = this.Direction(npc.GetWorldPosition(), player);
    known.hostile = Equals(GameObject.GetAttitudeTowards(npc, player), EAIAttitude.AIA_Hostile);
    known.targetingV = npc.IsPuppetTargetingPlayer();
    known.hackingV = npc.IsHackingPlayer();
    known.awareness = this.Awareness(npc, player);
    known.health = RoundF(GameInstance.GetStatPoolsSystem(GetGameInstance()).GetStatPoolValue(Cast<StatsObjectID>(npc.GetEntityID()), gamedataStatPoolType.Health, true));
    known.power = this.Power(npc);
    weapon = ScriptedPuppet.GetActiveWeapon(npc);
    known.weapon = IsDefined(weapon) ? EnumValueToString("gamedataItemType", Cast<Int64>(EnumInt(WeaponObject.GetWeaponType(weapon.GetItemID())))) : "";
  }

  // "combat", "searching", "fleeing", "suspicious" (V is filling its detection meter) or "calm".
  private func Awareness(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>) -> String {
    let state: gamedataNPCHighLevelState = npc.GetHighLevelStateFromBlackboard();
    let senses: ref<SenseComponent>;
    if Equals(state, gamedataNPCHighLevelState.Combat) {
      return "combat";
    };
    if Equals(state, gamedataNPCHighLevelState.Alerted) || Equals(state, gamedataNPCHighLevelState.Stealth) {
      return "searching";
    };
    if Equals(state, gamedataNPCHighLevelState.Fear) {
      return "fleeing";
    };
    senses = npc.GetSensesComponent();
    if IsDefined(senses) && senses.GetDetection(player.GetEntityID()) > 0.0 {
      return "suspicious";
    };
    return "calm";
  }

  // Known enemies that went down since the last scan. Only V's doing counts (the last hit came from V): "killed" or
  // "knocked_out", detail "stealth" (it never knew V was there), "quickhack", "melee", "explosive", "thrown" or "".
  // Bosses also queue "boss_down". Down enemies are dropped from the known list, except a remembered one downed by
  // someone else: Apiko did not see it fall, so it stays as last seen until forgotten.
  private func CheckDowned(player: ref<PlayerPuppet>) -> Void {
    let known: ref<ApisK0KnownEnemy>;
    let npc: ref<NPCPuppet>;
    let killed: Bool;
    let method: String;
    let i: Int32 = ArraySize(this.m_known) - 1;
    while i >= 0 {
      known = this.m_known[i];
      npc = known.npc;
      if IsDefined(npc) {
        killed = npc.IsDead();
        if killed || ScriptedPuppet.IsUnconscious(npc) {
          if npc.GetLastHitInstigator() == player {
            ArrayPush(this.m_downedByV, npc);
            method = npc.ApisK0LastHitMethod();
            if Equals(known.awareness, "calm") || Equals(known.awareness, "suspicious") {
              method = "stealth";
            };
            this.PushEvent(killed ? "killed" : "knocked_out", known.faction, method);
            if Equals(known.threat, "boss") {
              this.PushEvent("boss_down", StrLen(known.name) > 0 ? known.name : known.faction, killed ? "killed" : "spared");
            };
            ArrayErase(this.m_known, i);
          } else {
            if this.Live(known) {
              ArrayErase(this.m_known, i);
            };
          };
        };
      };
      i -= 1;
    };
  }

  // Drops enemies that are gone, beyond what Apiko can know about, or remembered for too long.
  private func ForgetGone(now: Float) -> Void {
    let known: ref<ApisK0KnownEnemy>;
    let limit: Float;
    let i: Int32 = ArraySize(this.m_known) - 1;
    while i >= 0 {
      known = this.m_known[i];
      if !IsDefined(known.npc) {
        ArrayErase(this.m_known, i);
      } else {
        if this.Live(known) {
          limit = known.here ? ApisK0EnemiesConfig.SightRange() : ApisK0EnemiesConfig.NetworkRange();
          if known.distance > limit {
            ArrayErase(this.m_known, i);
          };
        } else {
          // Remembered: forgotten with time, or when V is far from where it was last seen.
          if now - known.lastSeen > ApisK0EnemiesConfig.MemorySeconds() || known.distance > ApisK0EnemiesConfig.SightRange() {
            ArrayErase(this.m_known, i);
          };
        };
      };
      i -= 1;
    };
  }

  // Elite, boss or MaxTac, or a heavy or a mech: worth a warning when it shows up.
  private func IsNotable(known: ref<ApisK0KnownEnemy>) -> Bool {
    return Equals(known.threat, "elite") || Equals(known.threat, "boss") || Equals(known.threat, "maxtac")
      || Equals(known.role, "heavy") || Equals(known.role, "mech");
  }

  // "TygerClaws netrunner" style label for events (the bridge humanizes the faction).
  private func Describe(known: ref<ApisK0KnownEnemy>) -> String {
    let label: String = known.faction + " " + known.role;
    if NotEquals(known.threat, "normal") && NotEquals(known.threat, "weak") {
      label = known.faction + " " + known.threat + " " + known.role;
    };
    return label;
  }

  // gamedataAffiliation name ("Maelstrom", "TygerClaws"...), "Unknown" without one.
  private func Faction(npc: ref<NPCPuppet>) -> String {
    let record: wref<Affiliation_Record> = npc.GetRecord().Affiliation();
    if !IsDefined(record) {
      return "Unknown";
    };
    return NameToString(record.EnumName());
  }

  private func Role(npc: ref<NPCPuppet>) -> String {
    let type: gamedataNPCType = npc.GetNPCType();
    let archetype: String;
    let data: wref<ArchetypeData_Record>;
    if Equals(type, gamedataNPCType.Drone) || Equals(type, gamedataNPCType.Spiderbot) {
      return "drone";
    };
    if Equals(type, gamedataNPCType.Mech) || Equals(type, gamedataNPCType.Chimera) || Equals(type, gamedataNPCType.Cerberus) {
      return "mech";
    };
    data = npc.GetRecord().ArchetypeData();
    if IsDefined(data) && IsDefined(data.Type()) {
      archetype = EnumValueToString("gamedataArchetypeType", Cast<Int64>(EnumInt(data.Type().Type())));
    };
    if Equals(type, gamedataNPCType.Android) {
      return "android";
    };
    if StrContains(archetype, "Netrunner") || npc.IsNetrunnerPuppet() {
      return "netrunner";
    };
    if StrContains(archetype, "Sniper") {
      return "sniper";
    };
    if StrContains(archetype, "Heavy") || npc.IsMassive() {
      return "heavy";
    };
    if StrContains(archetype, "Shotgun") {
      return "shotgunner";
    };
    if StrContains(archetype, "Techie") {
      return "techie";
    };
    if StrContains(archetype, "Melee") {
      return "melee";
    };
    return "gunner";
  }

  private func Threat(npc: ref<NPCPuppet>) -> String {
    switch npc.GetNPCRarity() {
      case gamedataNPCRarity.Boss:
        return "boss";
      case gamedataNPCRarity.MaxTac:
        return "maxtac";
      case gamedataNPCRarity.Elite:
        return "elite";
      case gamedataNPCRarity.Officer:
      case gamedataNPCRarity.Rare:
        return "strong";
      case gamedataNPCRarity.Trash:
      case gamedataNPCRarity.Weak:
        return "weak";
    };
    return "normal";
  }

  // How hard it is for V, from the game's own power differential (the scanner's skull icons).
  private func Power(npc: ref<NPCPuppet>) -> String {
    switch RPGManager.CalculatePowerDifferential(npc) {
      case gameEPowerDifferential.TRASH:
        return "trivial";
      case gameEPowerDifferential.EASY:
        return "easy";
      case gameEPowerDifferential.HARD:
        return "hard";
      case gameEPowerDifferential.IMPOSSIBLE:
        return "impossible";
    };
    return "even";
  }

  // Characters with a name of their own (the scanner's full name); generic ones get "".
  private func OwnName(npc: ref<NPCPuppet>) -> String {
    let record: ref<Character_Record> = npc.GetRecord();
    let name: String;
    if !IsDefined(record) || !IsNameValid(record.FullDisplayName()) {
      return "";
    };
    name = GetLocalizedText(LocKeyToString(record.FullDisplayName()));
    // The state line is split on "," and ";".
    name = StrReplaceAll(StrReplaceAll(name, ",", " "), ";", " ");
    return name;
  }

  // Combat cyberware the NPC has (from its abilities), joined by "+".
  private func Cyberware(npc: ref<NPCPuppet>) -> String {
    let list: String;
    list = this.AddIfAbility(npc, list, t"Ability.HasSandevistan", "sandevistan");
    list = this.AddIfAbility(npc, list, t"Ability.HasKerenzikov", "kerenzikov");
    list = this.AddIfAbility(npc, list, t"Ability.CanUseMantisBlades", "mantis blades");
    list = this.AddIfAbility(npc, list, t"Ability.CanUseStrongArms", "gorilla arms");
    list = this.AddIfAbility(npc, list, t"Ability.CanUseProjectileLauncher", "projectile launcher");
    list = this.AddIfAbility(npc, list, t"Ability.CanUseOpticalCamo", "optical camo");
    list = this.AddIfAbility(npc, list, t"Ability.CanUseRetractableShield", "arm shield");
    list = this.AddIfAbility(npc, list, t"Ability.HasSubdermalArmor", "subdermal armor");
    list = this.AddIfAbility(npc, list, t"Ability.HasSecondHeart", "second heart");
    list = this.AddIfAbility(npc, list, t"Ability.HasBerserk", "berserk");
    return list;
  }

  private func AddIfAbility(npc: ref<NPCPuppet>, list: String, id: TweakDBID, label: String) -> String {
    let ability: wref<GameplayAbility_Record> = TweakDBInterface.GetGameplayAbilityRecord(id);
    if !IsDefined(ability) || !AIActionHelper.CheckAbility(npc, ability) {
      return list;
    };
    return StrLen(list) > 0 ? list + "+" + label : label;
  }

  // Where a point is from V's point of view, as in ApisK0Devices.
  private func Direction(position: Vector4, player: ref<PlayerPuppet>) -> String {
    let offset: Vector4 = position - player.GetWorldPosition();
    let forward: Vector4 = player.GetWorldForward();
    let ahead: Float = offset.X * forward.X + offset.Y * forward.Y;
    let right: Float = offset.X * forward.Y - offset.Y * forward.X;
    let angle: Float = AbsF(Rad2Deg(AtanF(right, ahead)));
    let side: String = right >= 0.0 ? "right" : "left";
    // Feet height against V's eyes minus a standing eye height: same floor reads as level.
    let height: Float = position.Z + 1.7 - this.m_eye.Z;
    let direction: String;
    if angle < 30.0 {
      direction = "ahead";
    } else {
      if angle < 60.0 {
        direction = "ahead-" + side;
      } else {
        if angle < 120.0 {
          direction = side;
        } else {
          if angle < 150.0 {
            direction = "behind-" + side;
          } else {
            direction = "behind";
          };
        };
      };
    };
    if height > ApisK0EnemiesConfig.FloorHeight() {
      direction += " above";
    } else {
      if height < -ApisK0EnemiesConfig.FloorHeight() {
        direction += " below";
      };
    };
    return direction;
  }

  // "enemies=" state line: "id,faction,role,threat,power,meters,direction,awareness,health,flags,weapon,cyberware,name"
  // entries joined by ";", enemies "here" first, then fighting ones, then by distance. Flags are space-separated
  // words: here, hostile, targeting-V, hacking-V, tagged, pinged, camera, and "last-seen-<seconds>s" for a
  // remembered enemy (its card is as it was then; meters and direction point to where it was seen).
  public func GetStateLine() -> String {
    let order: array<ref<ApisK0KnownEnemy>> = this.SortedKnown();
    let line: String;
    let known: ref<ApisK0KnownEnemy>;
    let i: Int32 = 0;
    while i < ArraySize(order) && i < ApisK0EnemiesConfig.MaxListed() {
      known = order[i];
      if StrLen(line) > 0 {
        line += ";";
      };
      line += "e" + IntToString(known.shortID) + "," + known.faction + "," + known.role + "," + known.threat + ","
        + known.power + "," + IntToString(RoundF(known.distance)) + "," + known.direction + "," + known.awareness + ","
        + IntToString(known.health) + "," + this.Flags(known) + "," + known.weapon + "," + known.cyberware + "," + known.name;
      i += 1;
    };
    return line;
  }

  private func Flags(known: ref<ApisK0KnownEnemy>) -> String {
    let flags: String = known.here ? "here" : "elsewhere";
    if known.hostile {
      flags += " hostile";
    };
    if known.targetingV {
      flags += " targeting-V";
    };
    if known.hackingV {
      flags += " hacking-V";
    };
    if known.tagged {
      flags += " tagged";
    };
    if known.pinged {
      flags += " pinged";
    };
    if known.byCamera {
      flags += " camera";
    };
    if !this.Live(known) {
      flags += " last-seen-" + IntToString(RoundF(this.m_now - known.lastSeen)) + "s";
    };
    return flags;
  }

  private func SortedKnown() -> array<ref<ApisK0KnownEnemy>> {
    let sorted: array<ref<ApisK0KnownEnemy>>;
    let item: ref<ApisK0KnownEnemy>;
    let i: Int32 = 0;
    let j: Int32;
    while i < ArraySize(this.m_known) {
      item = this.m_known[i];
      j = 0;
      while j < ArraySize(sorted) && this.Before(sorted[j], item) {
        j += 1;
      };
      ArrayInsert(sorted, j, item);
      i += 1;
    };
    return sorted;
  }

  private func Before(a: ref<ApisK0KnownEnemy>, b: ref<ApisK0KnownEnemy>) -> Bool {
    if NotEquals(a.here, b.here) {
      return a.here;
    };
    if NotEquals(Equals(a.awareness, "combat"), Equals(b.awareness, "combat")) {
      return Equals(a.awareness, "combat");
    };
    return a.distance <= b.distance;
  }

  // "APIKO Senses" debug window: a summary line, then one line per known enemy.
  public func GetDebugLines() -> array<String> {
    let lines: array<String>;
    let order: array<ref<ApisK0KnownEnemy>> = this.SortedKnown();
    let known: ref<ApisK0KnownEnemy>;
    let i: Int32;
    ArrayPush(lines, "scan #" + IntToString(this.m_scan) + ": " + IntToString(this.m_lastQueried) + " NPCs within "
      + IntToString(RoundF(ApisK0EnemiesConfig.NetworkRange())) + " m, " + IntToString(this.m_lastCandidates) + " enemies, "
      + IntToString(ArraySize(this.m_known)) + " known, " + IntToString(this.m_lastRaycasts) + " raycasts");
    i = 0;
    while i < ArraySize(order) {
      known = order[i];
      ArrayPush(lines, (known.here ? "HERE  " : "away  ") + "e" + IntToString(known.shortID) + "  " + known.faction + " "
        + known.role + (StrLen(known.name) > 0 ? " \"" + known.name + "\"" : "") + "  " + IntToString(RoundF(known.distance))
        + " m " + known.direction + "  |  " + known.threat + ", " + known.power + ", " + known.awareness + ", "
        + IntToString(known.health) + "% hp  |  " + known.weapon + (StrLen(known.cyberware) > 0 ? ", " + known.cyberware : "")
        + "  |  " + this.Flags(known) + "  |  via " + known.source);
      i += 1;
    };
    return lines;
  }
}

// How the last hit on this NPC was dealt: "quickhack", "melee", "explosive", "thrown" or "" (guns and the rest).
@addMethod(NPCPuppet)
public func ApisK0LastHitMethod() -> String {
  switch this.GetLastHitAttackType() {
    case gamedataAttackType.Hack:
      return "quickhack";
    case gamedataAttackType.Melee:
    case gamedataAttackType.QuickMelee:
    case gamedataAttackType.StrongMelee:
    case gamedataAttackType.WhipAttack:
    case gamedataAttackType.ChargedWhipAttack:
    case gamedataAttackType.GuardBreak:
      return "melee";
    case gamedataAttackType.Explosion:
      return "explosive";
    case gamedataAttackType.Thrown:
      return "thrown";
  };
  return "";
}
