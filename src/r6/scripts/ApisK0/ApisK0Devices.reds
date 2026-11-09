// APIS-K0 - phase 4, piece 1: what Apiko perceives of the devices around V (DISENO.md, "Fase 4").
// - Every few seconds the devices near V are queried. Two levels:
//   - "here": a clear line of sight from V's eyes (any direction, not only on screen) or from the drone, within
//     SightRange. Rechecked on every scan: this is how "in the same room" is told apart from "behind a wall or under
//     the floor" (the game has no room concept). A new device needs a clear line in two scans in a row (one-scan
//     glimpses through gaps are leaks), and the drone only counts while it is in V's space itself (a clear line from
//     V's eyes to it).
//   - known through the network: devices on a network V has pinged or breached, up to NetworkRange, even unseen.
//   A device seen before stays known (not "here") until V moves away. Ambient devices (tv, radio, traffic
//   lights...) only count while "here", never through the network.
// - Ping: for PingWindow seconds after V's Ping quickhack (on an NPC or a device), devices with an active ping link
//   become known. The window keeps out the links that scanning in focus mode also draws (and the device flag
//   WasRevealedInNetworkPing is never cleared, so it would reveal old networks forever).
// - Known devices go to the bridge as one compact "devices=" state line (the bridge decides how much of it the
//   model sees). Changes and V's actions on devices are queued as world events for Apiko's diary.
// Everything here is local: nothing reaches the model unless V talks or a rare event (breach, alarm) is commented.
module ApisK0

public abstract class ApisK0DevicesConfig {
  public static func ScanInterval() -> Float { return 1.5; }
  // Devices are seen ("here") up to this distance from V (meters).
  public static func SightRange() -> Float { return 25.0; }
  // Devices on a pinged or breached network are known up to this distance from V.
  public static func NetworkRange() -> Float { return 60.0; }
  // Line-of-sight raycasts per scan (up to two per device within SightRange: from V's eyes, then from the drone).
  public static func MaxRaycastsPerScan() -> Int32 { return 80; }
  // A raycast that stops this close to the device still counts as a clear line (the ray often hits the device
  // itself or the wall it hangs on). Small, so a device behind a thin wall is not taken as seen.
  public static func SightTolerance() -> Float { return 0.5; }
  // V's eyes to the drone: a ray that stops this close to it still counts (it hits the drone's own body).
  public static func DroneTolerance() -> Float { return 1.0; }
  // Height difference from V's eyes that makes a device "above" or "below" (another floor, the basement ceiling).
  public static func FloorHeight() -> Float { return 2.0; }
  // Devices sent in the state line: "here" first, then by category and distance.
  public static func MaxListed() -> Int32 { return 20; }
  public static func MaxQueuedEvents() -> Int32 { return 30; }
  // Seconds after V's Ping during which ping-linked devices become known.
  public static func PingWindow() -> Float { return 10.0; }
  // Loading a save re-applies the Ping status of pinged NPCs (and fires the wrapper once per NPC): pings in the
  // first seconds after a load are not V's.
  public static func IgnorePingsAfterLoad() -> Float { return 15.0; }
}

// Category of a device: what it means for V.
public abstract class ApisK0DeviceCategory {
  public static func Security() -> Int32 { return 0; }
  public static func Access() -> Int32 { return 1; }
  public static func Distraction() -> Int32 { return 2; }
  public static func Ambient() -> Int32 { return 3; }
  public static func Ignored() -> Int32 { return -1; }
}

public class ApisK0KnownDevice extends IScriptable {
  // Short id shown to the model ("d12"); stable while the device stays known, so V's orders can refer to it.
  public let shortID: Int32;
  public let entityID: EntityID;
  public let device: wref<Device>;
  public let kind: String;
  public let category: Int32;
  public let distance: Float;
  public let direction: String;
  // In the same space as V right now (clear line from V's eyes or from the drone).
  public let here: Bool;
  // Last readings, to notice changes.
  public let isOn: Bool;
  public let breached: Bool;
  // Revealed by V's Ping: kept like a breached network until V moves away.
  public let pinged: Bool;
  // How Apiko first learned of it: "V sight", "drone sight", "breach" or "ping" (debug window).
  public let source: String;
  // Its network (access point, or security system without one) as a local index (1, 2...; 0 = none) and name, and
  // whether V is inside one of its security areas.
  public let network: Int32;
  public let networkName: String;
  public let vInZone: Bool;
  public let watchingV: Bool;
  public let hostile: Bool;
  public let alarm: Bool;
  // Scan number of the last time it was found by the query.
  public let lastScan: Int32;
}

public class ApisK0Devices extends IScriptable {
  // No stored GameInstance: one captured on player attach left the time, weather, stat pool and targeting
  // systems returning defaults (time 00:00, health 0, no devices). Fetched on every call instead.
  private let m_known: array<ref<ApisK0KnownDevice>>;
  private let m_events: array<String>;
  private let m_nextScan: Float;
  private let m_scan: Int32;
  private let m_nextShortID: Int32;
  private let m_pingUntil: Float;
  private let m_ignorePingsUntil: Float;
  // Networks seen so far, by entity (access point or security system): position here = local index - 1.
  private let m_networks: array<EntityID>;
  // Devices the last query returned and raycasts it used (debug window).
  private let m_lastQueried: Int32;
  private let m_lastRaycasts: Int32;
  // V's eyes (camera position) at the last scan.
  private let m_eye: Vector4;
  // The drone has a clear line to V's eyes this scan: only then does its own sight count.
  private let m_droneInSpace: Bool;
  // Devices with a clear line last scan but not known yet (a second one in a row makes them known), and this scan's.
  private let m_glimpsed: array<EntityID>;
  private let m_glimpsing: array<EntityID>;
  // Last action V did on a device, to drop the duplicate the game sometimes reports in the same moment.
  private let m_lastActionDevice: EntityID;
  private let m_lastActionName: CName;
  private let m_lastActionTime: Float;

  public static func Create(game: GameInstance) -> ref<ApisK0Devices> {
    let devices: ref<ApisK0Devices> = new ApisK0Devices();
    devices.m_nextShortID = 1;
    return devices;
  }

  // `now`: sim time when the player is attached (a load or a new game).
  public func Reset(now: Float) -> Void {
    ArrayClear(this.m_known);
    ArrayClear(this.m_events);
    ArrayClear(this.m_glimpsed);
    ArrayClear(this.m_glimpsing);
    this.m_nextScan = 0.0;
    this.m_pingUntil = 0.0;
    this.m_ignorePingsUntil = now + ApisK0DevicesConfig.IgnorePingsAfterLoad();
  }

  // V used Ping (on an NPC or a device). `now` is the current sim time, read by the caller (a load fires the
  // wrapper before any tick).
  public func OnPlayerPing(now: Float, chat: ref<ApisK0Chat>) -> Void {
    // One Ping reaches the wrapper once per squad member (or forwarded device): only the first one counts.
    if now < this.m_ignorePingsUntil || now < this.m_pingUntil {
      return;
    };
    this.m_pingUntil = now + ApisK0DevicesConfig.PingWindow();
    // A sooner scan, so the revealed devices are picked up while the ping links are still drawn.
    this.m_nextScan = 0.0;
    this.PushEvent("pinged", "network", "");
    chat.PushEvent("network_pinged");
  }

  // World events, "action|kind|detail" (detail may be empty). Oldest first; clears the queue.
  public func DrainEvents() -> array<String> {
    let events: array<String> = this.m_events;
    ArrayClear(this.m_events);
    return events;
  }

  private func PushEvent(action: String, kind: String, detail: String) -> Void {
    ArrayPush(this.m_events, action + "|" + kind + "|" + detail);
    if ArraySize(this.m_events) > ApisK0DevicesConfig.MaxQueuedEvents() {
      ArrayErase(this.m_events, 0);
    };
  }

  // Called from the system tick while Apiko is awake. `drone` may be null (not spawned yet).
  public func Update(now: Float, player: ref<PlayerPuppet>, drone: ref<GameObject>, chat: ref<ApisK0Chat>) -> Void {
    let found: array<ref<Device>>;
    let device: ref<Device>;
    let known: ref<ApisK0KnownDevice>;
    let distance: Float;
    let pinged: Bool;
    let network: ref<NetworkSystem>;
    let raycasts: Int32;
    let sight: String;
    let how: String;
    let newlyBreached: Int32;
    let i: Int32;
    if now < this.m_nextScan || !IsDefined(player) {
      return;
    };
    this.m_nextScan = now + ApisK0DevicesConfig.ScanInterval();
    // Apiko is not around while V drives; what it knew is stale when V gets out.
    if IsDefined(GetMountedVehicle(player)) {
      ArrayClear(this.m_known);
      ArrayClear(this.m_glimpsed);
      return;
    };
    this.m_scan += 1;
    this.m_eye = this.EyePosition(player);
    this.m_droneInSpace = false;
    if IsDefined(drone) {
      raycasts += 1;
      this.m_droneInSpace = this.DroneInSpace(drone);
    };
    found = this.QueryDevices(player);
    this.m_lastQueried = ArraySize(found);
    if now < this.m_pingUntil {
      network = GameInstance.GetScriptableSystemsContainer(GetGameInstance()).Get(n"NetworkSystem") as NetworkSystem;
    };
    i = 0;
    while i < ArraySize(found) {
      device = found[i];
      distance = Vector4.Distance(device.GetWorldPosition(), player.GetWorldPosition());
      known = this.FindKnown(device.GetEntityID());
      // An active ping link (true with pings counted, false without them).
      pinged = IsDefined(network) && distance <= ApisK0DevicesConfig.NetworkRange()
        && network.HasNetworkLink(device.GetEntityID(), false) && !network.HasNetworkLink(device.GetEntityID(), true);
      // "V sight", "drone sight", "" (no clear line) or "?" (not checked: out of range or out of raycasts).
      sight = distance <= ApisK0DevicesConfig.SightRange() ? this.Sight(device, player, drone, raycasts) : "";
      if IsDefined(known) {
        known.lastScan = this.m_scan;
        if pinged {
          known.pinged = true;
        };
        if NotEquals(sight, "?") {
          known.here = StrLen(sight) > 0;
        };
        if this.Refresh(known, player, distance, chat) {
          newlyBreached += 1;
        };
      } else {
        how = "";
        if StrLen(sight) > 0 && this.Glimpse(device.GetEntityID(), sight) {
          how = sight;
        } else {
          // Ambient devices only count while seen.
          if this.Category(device) != ApisK0DeviceCategory.Ambient() {
            if pinged {
              how = "ping";
            } else {
              if device.IsBreached() && distance <= ApisK0DevicesConfig.NetworkRange() {
                how = "breach";
              };
            };
          };
        };
        if StrLen(how) > 0 {
          this.AddKnown(device, player, distance, pinged, how);
        };
      };
      i += 1;
    };
    this.m_glimpsed = this.m_glimpsing;
    ArrayClear(this.m_glimpsing);
    this.m_lastRaycasts = raycasts;
    this.ForgetGone();
    if newlyBreached > 0 {
      this.PushEvent("breached", "network", IntToString(newlyBreached));
      chat.PushEvent("network_breached");
    };
  }

  // Camera position (V's eyes, also when crouching); the player's position plus a standing eye height without it.
  private func EyePosition(player: ref<PlayerPuppet>) -> Vector4 {
    let camera: Transform;
    if GameInstance.GetCameraSystem(GetGameInstance()).GetActiveCameraWorldTransform(camera) {
      return Transform.GetPosition(camera);
    };
    return player.GetWorldPosition() + new Vector4(0.0, 0.0, 1.7, 0.0);
  }

  // Every device near V the targeting system knows about (seen or not).
  private func QueryDevices(player: ref<PlayerPuppet>) -> array<ref<Device>> {
    let query: TargetSearchQuery;
    let parts: array<TS_TargetPartInfo>;
    let component: ref<TargetingComponent>;
    let device: ref<Device>;
    let devices: array<ref<Device>>;
    let i: Int32;
    query.testedSet = TargetingSet.Complete;
    query.searchFilter = TSF_Any(TSFMV.Obj_Device);
    query.maxDistance = ApisK0DevicesConfig.NetworkRange();
    query.filterObjectByDistance = true;
    query.includeSecondaryTargets = false;
    query.ignoreInstigator = true;
    GameInstance.GetTargetingSystem(GetGameInstance()).GetTargetParts(player, query, parts);
    i = 0;
    while i < ArraySize(parts) {
      component = TS_TargetPartInfo.GetComponent(parts[i]);
      if IsDefined(component) {
        device = component.GetEntity() as Device;
        if IsDefined(device) && !ArrayContains(devices, device) && this.Category(device) != ApisK0DeviceCategory.Ignored() {
          ArrayPush(devices, device);
        };
      };
      i += 1;
    };
    return devices;
  }

  // "V sight" (on screen and visible, or a clear line from V's eyes in any direction), "drone sight" (clear line
  // from the drone), "" (blocked) or "?" (out of raycasts this scan).
  private func Sight(device: ref<Device>, player: ref<PlayerPuppet>, drone: ref<GameObject>, out raycasts: Int32) -> String {
    let target: Vector4 = device.GetWorldPosition();
    if GameInstance.GetTargetingSystem(GetGameInstance()).IsVisibleTarget(player, device) {
      return "V sight";
    };
    if raycasts >= ApisK0DevicesConfig.MaxRaycastsPerScan() {
      return "?";
    };
    raycasts += 1;
    if this.ClearLine(this.m_eye, target) {
      return "V sight";
    };
    if !IsDefined(drone) || !this.m_droneInSpace {
      return "";
    };
    if raycasts >= ApisK0DevicesConfig.MaxRaycastsPerScan() {
      return "?";
    };
    raycasts += 1;
    if this.ClearLine(drone.GetWorldPosition(), target) {
      return "drone sight";
    };
    return "";
  }

  private func ClearLine(start: Vector4, end: Vector4) -> Bool {
    let result: TraceResult;
    if !GameInstance.GetSpatialQueriesSystem(GetGameInstance()).SyncRaycastByQueryPreset(start, end, n"Sight Blocker", result) {
      return true;
    };
    return Vector4.Distance(Vector4.Vector3To4(result.position), end) <= ApisK0DevicesConfig.SightTolerance();
  }

  // A clear line from V's eyes to the drone: it is in V's space, not inside a wall, a ceiling or on another floor.
  private func DroneInSpace(drone: ref<GameObject>) -> Bool {
    let result: TraceResult;
    let target: Vector4 = drone.GetWorldPosition();
    if !GameInstance.GetSpatialQueriesSystem(GetGameInstance()).SyncRaycastByQueryPreset(this.m_eye, target, n"Sight Blocker", result) {
      return true;
    };
    return Vector4.Distance(Vector4.Vector3To4(result.position), target) <= ApisK0DevicesConfig.DroneTolerance();
  }

  // A new device with a clear line ("?" = not checked this scan). True on the second scan in a row with one; a
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

  private func FindKnown(id: EntityID) -> ref<ApisK0KnownDevice> {
    let i: Int32 = 0;
    while i < ArraySize(this.m_known) {
      if this.m_known[i].entityID == id {
        return this.m_known[i];
      };
      i += 1;
    };
    return null;
  }

  private func AddKnown(device: ref<Device>, player: ref<PlayerPuppet>, distance: Float, pinged: Bool, source: String) -> Void {
    let known: ref<ApisK0KnownDevice> = new ApisK0KnownDevice();
    known.shortID = this.m_nextShortID;
    this.m_nextShortID += 1;
    known.entityID = device.GetEntityID();
    known.device = device;
    known.kind = this.Kind(device);
    known.lastScan = this.m_scan;
    known.pinged = pinged;
    known.source = source;
    known.here = Equals(source, "V sight") || Equals(source, "drone sight");
    this.Read(known, player, distance);
    ArrayPush(this.m_known, known);
  }

  // Updates a known device and queues events for what changed. Returns true when its network was just breached.
  private func Refresh(known: ref<ApisK0KnownDevice>, player: ref<PlayerPuppet>, distance: Float, chat: ref<ApisK0Chat>) -> Bool {
    let wasWatching: Bool = known.watchingV;
    let wasHostile: Bool = known.hostile;
    let wasAlarm: Bool = known.alarm;
    let wasBreached: Bool = known.breached;
    this.Read(known, player, distance);
    if known.watchingV && !wasWatching {
      this.PushEvent("spotted", known.kind, "");
    };
    if known.hostile && !wasHostile {
      this.PushEvent("hostile", known.kind, "");
    };
    if known.alarm && !wasAlarm {
      this.PushEvent("alarm", known.kind, "");
      chat.PushEvent("alarm");
    };
    return known.breached && !wasBreached;
  }

  private func Read(known: ref<ApisK0KnownDevice>, player: ref<PlayerPuppet>, distance: Float) -> Void {
    let device: ref<Device> = known.device;
    let sensor: ref<SensorDevice>;
    let alarm: ref<SecurityAlarm>;
    let state: ESecuritySystemState;
    if !IsDefined(device) {
      return;
    };
    known.distance = distance;
    known.direction = this.Direction(device.GetWorldPosition(), player);
    known.category = this.Category(device);
    known.isOn = device.GetDevicePS().IsON();
    known.breached = device.IsBreached();
    this.ReadNetwork(known, device);
    known.vInZone = ArraySize(device.GetDevicePS().GetSecurityAreasWithUserInside(player)) > 0;
    sensor = device as SensorDevice;
    if IsDefined(sensor) {
      known.watchingV = sensor.GetCurrentlyFollowedTarget() == player;
      known.hostile = Equals(GameObject.GetAttitudeTowards(sensor, player), EAIAttitude.AIA_Hostile);
    };
    alarm = device as SecurityAlarm;
    if IsDefined(alarm) {
      state = alarm.GetDevicePS().GetAlarmState();
      known.alarm = Equals(state, ESecuritySystemState.ALERTED) || Equals(state, ESecuritySystemState.COMBAT);
    };
  }

  // Drops devices that are gone, destroyed (queued as an event), too far, or ambient and no longer in view.
  private func ForgetGone() -> Void {
    let known: ref<ApisK0KnownDevice>;
    let limit: Float;
    let i: Int32 = ArraySize(this.m_known) - 1;
    while i >= 0 {
      known = this.m_known[i];
      if !IsDefined(known.device) || known.lastScan != this.m_scan {
        ArrayErase(this.m_known, i);
      } else {
        if known.device.GetDevicePS().IsBroken() {
          this.PushEvent("destroyed", known.kind, "");
          ArrayErase(this.m_known, i);
        } else {
          limit = known.breached || known.pinged ? ApisK0DevicesConfig.NetworkRange() : ApisK0DevicesConfig.SightRange();
          if known.distance > limit || (known.category == ApisK0DeviceCategory.Ambient() && !known.here) {
            ArrayErase(this.m_known, i);
          };
        };
      };
      i -= 1;
    };
  }

  // Called from the Device.OnPerformedAction wrapper: V hacked or used a device.
  public func OnPlayerAction(now: Float, device: ref<Device>, action: ref<ScriptableDeviceAction>, chat: ref<ApisK0Chat>) -> Void {
    let kind: String;
    if IsDefined(action as PingDevice) {
      this.OnPlayerPing(now, chat);
      return;
    };
    // A load replays some device actions (three "hacked computer" in the same second): not V's.
    if now < this.m_ignorePingsUntil {
      return;
    };
    if this.Category(device) == ApisK0DeviceCategory.Ignored() {
      return;
    };
    if device.GetEntityID() == this.m_lastActionDevice && Equals(action.GetClassName(), this.m_lastActionName)
      && now - this.m_lastActionTime < 1.0 {
      return;
    };
    this.m_lastActionDevice = device.GetEntityID();
    this.m_lastActionName = action.GetClassName();
    this.m_lastActionTime = now;
    kind = this.Kind(device);
    if action.IsQuickHack() {
      this.PushEvent("hacked", kind, NameToString(action.GetClassName()));
    } else {
      this.PushEvent("used", kind, NameToString(action.GetClassName()));
    };
  }

  // A device's network: its access point (what Ping and breaching reveal), or its security system when it has no
  // access point. Stored as a local index (1, 2...; 0 = none) plus the name the game gives the network.
  private func ReadNetwork(known: ref<ApisK0KnownDevice>, device: ref<Device>) -> Void {
    let ps: ref<ScriptableDeviceComponentPS> = device.GetDevicePS();
    let ownAP: ref<AccessPointControllerPS> = ps as AccessPointControllerPS;
    let aps: array<ref<AccessPointControllerPS>>;
    let system: ref<SecuritySystemControllerPS>;
    let id: EntityID;
    let i: Int32;
    if IsDefined(ownAP) {
      id = ownAP.GetMyEntityID();
      known.networkName = ownAP.GetNetworkName();
    } else {
      aps = ps.GetAccessPoints();
      if ArraySize(aps) > 0 {
        id = aps[0].GetMyEntityID();
        known.networkName = aps[0].GetNetworkName();
      } else {
        system = ps.GetSecuritySystem();
        if !IsDefined(system) {
          known.network = 0;
          known.networkName = "";
          return;
        };
        id = system.GetMyEntityID();
        known.networkName = "security system";
      };
    };
    i = 0;
    while i < ArraySize(this.m_networks) {
      if this.m_networks[i] == id {
        known.network = i + 1;
        return;
      };
      i += 1;
    };
    ArrayPush(this.m_networks, id);
    known.network = ArraySize(this.m_networks);
  }

  // Cameras on a breached network, switched on: through them Apiko also sees enemies (ApisK0Enemies.reds).
  public func GetNetworkCameras() -> array<wref<Device>> {
    let cameras: array<wref<Device>>;
    let known: ref<ApisK0KnownDevice>;
    let i: Int32 = 0;
    while i < ArraySize(this.m_known) {
      known = this.m_known[i];
      if known.breached && known.isOn && Equals(known.kind, "camera") && IsDefined(known.device) {
        ArrayPush(cameras, known.device);
      };
      i += 1;
    };
    return cameras;
  }

  // "APIKO Senses" debug window: a summary line, then one line per known device.
  public func GetDebugLines(now: Float) -> array<String> {
    let lines: array<String>;
    let order: array<ref<ApisK0KnownDevice>> = this.SortedKnown();
    let known: ref<ApisK0KnownDevice>;
    let network: String;
    let here: Int32;
    let i: Int32;
    i = 0;
    while i < ArraySize(order) {
      if order[i].here {
        here += 1;
      };
      i += 1;
    };
    ArrayPush(lines, "scan #" + IntToString(this.m_scan) + ": " + IntToString(this.m_lastQueried) + " devices within "
      + IntToString(RoundF(ApisK0DevicesConfig.NetworkRange())) + " m, " + IntToString(ArraySize(this.m_known)) + " known, "
      + IntToString(here) + " here, " + IntToString(this.m_lastRaycasts) + " raycasts"
      + (now < this.m_pingUntil ? ", ping window open" : "") + (now < this.m_ignorePingsUntil ? ", ignoring pings (load)" : ""));
    i = 0;
    while i < ArraySize(order) {
      known = order[i];
      network = known.network > 0 ? "net" + IntToString(known.network) + " " + known.networkName + (known.vInZone ? " (V in zone)" : "") : "no net";
      ArrayPush(lines, (known.here ? "HERE  " : "away  ") + "d" + IntToString(known.shortID) + "  " + known.kind + "  "
        + IntToString(RoundF(known.distance)) + " m " + known.direction + "  |  " + this.CategoryName(known.category)
        + "  |  " + this.Flags(known) + "  |  via " + known.source + "  |  " + network);
      i += 1;
    };
    return lines;
  }

  private func CategoryName(category: Int32) -> String {
    switch category {
      case 0:
        return "security";
      case 1:
        return "access";
      case 2:
        return "distraction";
      case 3:
        return "ambient";
    };
    return "?";
  }

  // "devices=" state line: "id,kind,category,meters,direction,flags" entries joined by ";", devices "here" first,
  // then by category and distance. Flags are space-separated words ("here" marks the ones in V's space).
  public func GetStateLine() -> String {
    let order: array<ref<ApisK0KnownDevice>> = this.SortedKnown();
    let line: String;
    let known: ref<ApisK0KnownDevice>;
    let i: Int32 = 0;
    while i < ArraySize(order) && i < ApisK0DevicesConfig.MaxListed() {
      known = order[i];
      if StrLen(line) > 0 {
        line += ";";
      };
      line += "d" + IntToString(known.shortID) + "," + known.kind + "," + IntToString(known.category) + ","
        + IntToString(RoundF(known.distance)) + "," + known.direction + "," + this.Flags(known);
      i += 1;
    };
    return line;
  }

  // "here" first, then category, then distance.
  private func SortedKnown() -> array<ref<ApisK0KnownDevice>> {
    let sorted: array<ref<ApisK0KnownDevice>>;
    let item: ref<ApisK0KnownDevice>;
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

  private func Before(a: ref<ApisK0KnownDevice>, b: ref<ApisK0KnownDevice>) -> Bool {
    if NotEquals(a.here, b.here) {
      return a.here;
    };
    if a.category != b.category {
      return a.category < b.category;
    };
    return a.distance <= b.distance;
  }

  private func Flags(known: ref<ApisK0KnownDevice>) -> String {
    let flags: String = known.isOn ? "on" : "off";
    if known.here {
      flags += " here";
    };
    if known.hostile {
      flags += " hostile";
    };
    if known.watchingV {
      flags += " watching-V";
    };
    if known.alarm {
      flags += " ringing";
    };
    if known.breached {
      flags += " breached";
    } else {
      if known.pinged {
        flags += " pinged";
      };
    };
    return flags;
  }

  // Where a point is from V's point of view: ahead, ahead-left, left, behind-right... plus above/below, measured
  // from V's eyes (a camera on the basement ceiling is only ~2 m below them).
  private func Direction(position: Vector4, player: ref<PlayerPuppet>) -> String {
    let offset: Vector4 = position - player.GetWorldPosition();
    let forward: Vector4 = player.GetWorldForward();
    let ahead: Float = offset.X * forward.X + offset.Y * forward.Y;
    // Right of the forward vector in a Z-up world.
    let right: Float = offset.X * forward.Y - offset.Y * forward.X;
    let angle: Float = AbsF(Rad2Deg(AtanF(right, ahead)));
    let side: String = right >= 0.0 ? "right" : "left";
    let height: Float = position.Z - this.m_eye.Z;
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
    if height > ApisK0DevicesConfig.FloorHeight() {
      direction += " above";
    } else {
      if height < -ApisK0DevicesConfig.FloorHeight() {
        direction += " below";
      };
    };
    return direction;
  }

  // Order matters: subclasses before their parents (Computer is a Terminal, ExplosiveDevice a
  // BasicDistractionDevice...).
  private func Kind(device: ref<Device>) -> String {
    if IsDefined(device as SurveillanceCamera) { return "camera"; };
    if IsDefined(device as SecurityTurret) { return "turret"; };
    if IsDefined(device as SniperNest) { return "sniper nest"; };
    if IsDefined(device as SecurityAlarm) { return "alarm"; };
    if IsDefined(device as AccessPoint) { return "access point"; };
    if IsDefined(device as SecurityGate) || IsDefined(device as SecurityGateLock) { return "security gate"; };
    if IsDefined(device as Computer) { return "computer"; };
    if IsDefined(device as Terminal) { return "terminal"; };
    if IsDefined(device as ExplosiveDevice) { return "explosive"; };
    if IsDefined(device as SmokeMachine) { return "smoke machine"; };
    if IsDefined(device as VendingMachine) { return "vending machine"; };
    if IsDefined(device as ElectricBox) { return "electric box"; };
    if IsDefined(device as Speaker) { return "speaker"; };
    if IsDefined(device as BasicDistractionDevice) { return "distraction device"; };
    if IsDefined(device as TV) { return "tv"; };
    if IsDefined(device as Radio) { return "radio"; };
    if IsDefined(device as Jukebox) { return "jukebox"; };
    if IsDefined(device as ArcadeMachine) { return "arcade machine"; };
    if IsDefined(device as BillboardDevice) { return "billboard"; };
    if IsDefined(device as LcdScreen) { return "screen"; };
    if IsDefined(device as TrafficLight) { return "traffic light"; };
    return "device";
  }

  // Doors and unnamed devices (lights and the like) are ignored (user, 2026-11-06): everywhere, and they add nothing.
  private func Category(device: ref<Device>) -> Int32 {
    if IsDefined(device as SurveillanceCamera) || IsDefined(device as SecurityTurret) || IsDefined(device as SniperNest) || IsDefined(device as SecurityAlarm) {
      return ApisK0DeviceCategory.Security();
    };
    if IsDefined(device as Door) {
      return ApisK0DeviceCategory.Ignored();
    };
    if IsDefined(device as AccessPoint) || IsDefined(device as SecurityGate) || IsDefined(device as SecurityGateLock) || IsDefined(device as Terminal) {
      return ApisK0DeviceCategory.Access();
    };
    if IsDefined(device as BasicDistractionDevice) || IsDefined(device as VendingMachine) || IsDefined(device as ElectricBox) || IsDefined(device as Speaker) {
      return ApisK0DeviceCategory.Distraction();
    };
    if IsDefined(device as TV) || IsDefined(device as Radio) || IsDefined(device as Jukebox) || IsDefined(device as ArcadeMachine) || IsDefined(device as BillboardDevice) || IsDefined(device as LcdScreen) || IsDefined(device as TrafficLight) {
      return ApisK0DeviceCategory.Ambient();
    };
    return ApisK0DeviceCategory.Ignored();
  }
}

// V's quickhacks and interactions on devices, for Apiko's diary. Subclass overrides call super.
@wrapMethod(Device)
protected cb func OnPerformedAction(evt: ref<PerformedAction>) -> Bool {
  let result: Bool = wrappedMethod(evt);
  let action: ref<ScriptableDeviceAction> = evt.m_action as ScriptableDeviceAction;
  let executor: wref<GameObject>;
  let system: ref<ApisK0System>;
  if IsDefined(action) {
    executor = action.GetExecutor();
    if IsDefined(executor) && executor.IsPlayer() {
      system = ApisK0System.Get(this.GetGame());
      if IsDefined(system) {
        system.OnPlayerDeviceAction(this, action);
      };
    };
  };
  return result;
}

// V's Ping on an NPC (marks its squad and pings its network).
@wrapMethod(PingSquadEffector)
protected func ActionOn(owner: ref<GameObject>) -> Void {
  let system: ref<ApisK0System>;
  wrappedMethod(owner);
  if IsDefined(owner) && !owner.IsPlayer() {
    system = ApisK0System.Get(owner.GetGame());
    if IsDefined(system) {
      system.OnPlayerPing();
    };
  };
}
