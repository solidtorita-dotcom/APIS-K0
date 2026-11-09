// APIS-K0 - phase 2: game side of the conversation with Apiko.
// - Collects the game state the AI is allowed to perceive (time, district, combat, health). The tracked quest and
//   what Apiko hears come from ApisK0Story.reds.
// - Detects events Apiko may comment on (combat, new district, nightfall/dawn, low health, wake up) and
//   queues them for the CET side, which forwards them to the external bridge.
// - Shows Apiko's replies as dialogue subtitles (UIGameData.ShowDialogLine), with its own speaker color.
module ApisK0

public abstract class ApisK0ChatConfig {
  // The subtitles' speaker: a localization key (ApisK0.archive, make_world.py), since the vanilla "{NAME}:" format
  // resolves the name as one; with the plain "APIKO" it came out as ": text" or "{NAME}:" when redrawn.
  public static func SpeakerName() -> String { return "LocKey#apisk0-speaker"; }
  public static func SpeakerLabel() -> String { return "APIKO"; }
  // The first contact before Apiko gives its name ("UNKNOWN" / "DESCONOCIDO").
  public static func UnknownSpeakerName() -> String { return "LocKey#apisk0-speaker-unknown"; }
  public static func UnknownSpeakerKey() -> CName { return n"apisk0-speaker-unknown"; }
  // NetWatch's recording on the beacon's call (the find).
  public static func NetWatchSpeakerName() -> String { return "LocKey#apisk0-speaker-netwatch"; }
  public static func NetWatchSpeakerKey() -> CName { return n"apisk0-speaker-netwatch"; }
  public static func IsOwnSpeaker(name: String) -> Bool {
    return Equals(name, ApisK0ChatConfig.SpeakerName()) || Equals(name, ApisK0ChatConfig.UnknownSpeakerName())
      || Equals(name, ApisK0ChatConfig.NetWatchSpeakerName());
  }
  // Speaker name tint in the subtitles.
  public static func SpeakerColor() -> HDRColor { return new HDRColor(0.50, 0.91, 0.85, 1.0); }
  // The unknown voice (before Apiko gives its name): the HUD's hostile red.
  public static func UnknownSpeakerColor() -> HDRColor { return new HDRColor(1.0, 0.33, 0.30, 1.0); }
  // NetWatch: a cold corporate blue.
  public static func NetWatchSpeakerColor() -> HDRColor { return new HDRColor(0.45, 0.70, 1.0, 1.0); }
  // Seconds between state checks for events.
  public static func EventCheckInterval() -> Float { return 1.0; }
  // Health percentage below which (in combat) Apiko may react.
  public static func LowHealth() -> Float { return 30.0; }
  // Health percentage that re-arms the low health event.
  public static func HealthRecovered() -> Float { return 60.0; }
  // Calm moments (no combat, on foot) the bridge may fill with a loose thought after a long silence: one check
  // this often (seconds of game time).
  public static func IdleCheckInterval() -> Float { return 90.0; }
  public static func NightfallHour() -> Int32 { return 20; }
  public static func DawnHour() -> Int32 { return 6; }
  public static func MaxQueuedEvents() -> Int32 { return 10; }
}

public class ApisK0Chat extends IScriptable {
  // No stored GameInstance: one captured on player attach left the time, weather, stat pool and targeting
  // systems returning defaults (time 00:00, health 0, no devices). Fetched on every call instead.
  private let m_events: array<String>;
  // Baselines are taken on the first check after a load, so loading a save fires no events.
  private let m_primed: Bool;
  private let m_inCombat: Bool;
  private let m_district: TweakDBID;
  private let m_hour: Int32;
  private let m_lowHealthArmed: Bool;
  private let m_nextCheck: Float;
  private let m_nextIdleCheck: Float;
  private let m_lineCounter: Uint64;
  private let m_currentLine: CRUID;
  private let m_hasLine: Bool;

  public static func Create(game: GameInstance) -> ref<ApisK0Chat> {
    let chat: ref<ApisK0Chat> = new ApisK0Chat();
    chat.m_lowHealthArmed = true;
    return chat;
  }

  public func Reset() -> Void {
    this.m_primed = false;
    this.m_nextCheck = 0.0;
    this.m_nextIdleCheck = 0.0;
    ArrayClear(this.m_events);
  }

  public func PushEvent(name: String) -> Void {
    ArrayPush(this.m_events, name);
    if ArraySize(this.m_events) > ApisK0ChatConfig.MaxQueuedEvents() {
      ArrayErase(this.m_events, 0);
    };
  }

  public func DrainEvents() -> array<String> {
    let events: array<String> = this.m_events;
    ArrayClear(this.m_events);
    return events;
  }

  // Called from the system tick while Apiko is awake.
  public func Update(now: Float, player: ref<PlayerPuppet>) -> Void {
    let inVehicle: Bool;
    let inCombat: Bool;
    let district: wref<District>;
    let districtID: TweakDBID;
    let hour: Int32;
    let health: Float;
    if now < this.m_nextCheck || !IsDefined(player) {
      return;
    };
    this.m_nextCheck = now + ApisK0ChatConfig.EventCheckInterval();
    // While V drives the drone is gone, but Apiko still talks through the chip (decided 2026-11-08): only districts
    // and long silences then. Combat, the hour and low health wait, so a change is noticed on getting out.
    inVehicle = IsDefined(GetMountedVehicle(player));
    inCombat = player.IsInCombat();
    district = player.GetPreventionSystem().GetCurrentDistrict();
    if IsDefined(district) {
      districtID = district.GetDistrictID();
    };
    hour = GameTime.Hours(GameInstance.GetTimeSystem(GetGameInstance()).GetGameTime());
    health = this.HealthPercent(player);

    if !this.m_primed {
      this.m_primed = true;
      this.m_inCombat = inCombat;
      this.m_district = districtID;
      this.m_hour = hour;
      this.m_nextIdleCheck = now + ApisK0ChatConfig.IdleCheckInterval();
      return;
    };

    // A calm moment: the bridge decides whether the silence has been long enough for a loose thought.
    if now >= this.m_nextIdleCheck {
      this.m_nextIdleCheck = now + ApisK0ChatConfig.IdleCheckInterval();
      if !inCombat {
        this.PushEvent("idle_check");
      };
    };

    if TDBID.IsValid(districtID) && districtID != this.m_district {
      this.m_district = districtID;
      this.PushEvent("entered_district");
    };
    if inVehicle {
      return;
    };
    if NotEquals(inCombat, this.m_inCombat) {
      this.m_inCombat = inCombat;
      this.PushEvent(inCombat ? "combat_start" : "combat_end");
    };
    if hour != this.m_hour {
      this.m_hour = hour;
      if hour == ApisK0ChatConfig.NightfallHour() {
        this.PushEvent("nightfall");
      } else {
        if hour == ApisK0ChatConfig.DawnHour() {
          this.PushEvent("dawn");
        };
      };
    };
    if inCombat && this.m_lowHealthArmed && health > 0.0 && health < ApisK0ChatConfig.LowHealth() {
      this.m_lowHealthArmed = false;
      this.PushEvent("low_health");
    } else {
      if health >= ApisK0ChatConfig.HealthRecovered() {
        this.m_lowHealthArmed = true;
      };
    };
  }

  // What Apiko perceives, as "key=value" lines (the CET side turns them into JSON for the bridge).
  public func GetState(player: ref<PlayerPuppet>) -> array<String> {
    let state: array<String>;
    let time: GameTime;
    let district: wref<District>;
    let record: wref<District_Record>;
    let districtName: String;
    let districtKeys: String;
    let gangs: String;
    let i: Int32;
    if !IsDefined(player) {
      return state;
    };
    time = GameInstance.GetTimeSystem(GetGameInstance()).GetGameTime();
    ArrayPush(state, "time=" + this.TwoDigits(GameTime.Hours(time)) + ":" + this.TwoDigits(GameTime.Minutes(time)));
    // Total game time, for the bridge only (how long since Apiko last talked with V); never shown to the model.
    ArrayPush(state, "game_seconds=" + IntToString(GameTime.GetSeconds(time)));

    district = player.GetPreventionSystem().GetCurrentDistrict();
    if IsDefined(district) {
      record = district.GetDistrictRecord();
      // Most specific first: "Sub-district, District".
      while IsDefined(record) {
        if StrLen(districtName) > 0 {
          districtName += ", ";
        };
        districtName += GetLocalizedText(record.LocalizedName());
        // Untranslated names (Kabuki, Watson...) for the bridge's district lines; never shown to the model.
        districtKeys += (StrLen(districtKeys) > 0 ? "," : "") + record.EnumName();
        if StrLen(gangs) == 0 {
          i = 0;
          while i < record.GetGangsCount() {
            if StrLen(gangs) > 0 {
              gangs += ", ";
            };
            gangs += GetLocalizedTextByKey(record.GetGangsItem(i).LocalizedName());
            i += 1;
          };
        };
        record = record.ParentDistrict();
      };
      ArrayPush(state, "district=" + districtName);
      ArrayPush(state, "district_keys=" + districtKeys);
      if StrLen(gangs) > 0 {
        ArrayPush(state, "district_gangs=" + gangs);
      };
    };

    ArrayPush(state, "weather=" + this.Weather());
    ArrayPush(state, "in_combat=" + (player.IsInCombat() ? "yes" : "no"));
    ArrayPush(state, "v_health_percent=" + IntToString(RoundF(this.HealthPercent(player))));
    ArrayPush(state, "v_in_vehicle=" + (IsDefined(GetMountedVehicle(player)) ? "yes" : "no"));
    if StrLen(this.VehicleName(player)) > 0 {
      ArrayPush(state, "v_vehicle=" + this.VehicleName(player));
    };
    ArrayPush(state, "v_gender=" + NameToString(player.GetResolvedGenderName()));
    return state;
  }

  // Shows a line as a dialogue subtitle spoken by "APIKO" (or by an unknown speaker, or by NetWatch's recording). The
  // previous line is hidden first.
  public func Say(text: String, duration: Float, speaker: ref<GameObject>, opt unknown: Bool, opt netwatch: Bool) -> Void {
    let bbDefs: ref<UIGameDataDef> = GetAllBlackboardDefs().UIGameData;
    let blackboard: ref<IBlackboard> = GameInstance.GetBlackboardSystem(GetGameInstance()).Get(bbDefs);
    let line: scnDialogLineData;
    let lines: array<scnDialogLineData>;
    this.HideCurrent();
    this.m_lineCounter += 1ul;
    // High base so the ids never collide with the game's own lines.
    line.id = CreateCRUID(7300000000000000000ul + this.m_lineCounter);
    line.text = text;
    // OwnerlessRegular is shown even without a speaker (the drone is removed while V drives).
    line.type = scnDialogLineType.OwnerlessRegular;
    line.speaker = speaker;
    line.speakerName = netwatch ? ApisK0ChatConfig.NetWatchSpeakerName()
      : unknown ? ApisK0ChatConfig.UnknownSpeakerName() : ApisK0ChatConfig.SpeakerName();
    line.isPersistent = false;
    line.duration = duration;
    ArrayPush(lines, line);
    blackboard.SetVariant(bbDefs.ShowDialogLine, ToVariant(lines), true);
    this.m_currentLine = line.id;
    this.m_hasLine = true;
    GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(ApisK0HideLineCallback.Create(this, line.id), duration, false);
  }

  public func Hide(id: CRUID) -> Void {
    let bbDefs: ref<UIGameDataDef> = GetAllBlackboardDefs().UIGameData;
    let ids: array<CRUID>;
    if !this.m_hasLine || NotEquals(id, this.m_currentLine) {
      return;
    };
    this.m_hasLine = false;
    ArrayPush(ids, id);
    GameInstance.GetBlackboardSystem(GetGameInstance()).Get(bbDefs).SetVariant(bbDefs.HideDialogLine, ToVariant(ids), true);
  }

  private func HideCurrent() -> Void {
    if this.m_hasLine {
      this.Hide(this.m_currentLine);
    };
  }

  // The vehicle V is in ("Quadra Turbo-R V-Tech"), or "".
  private func VehicleName(player: ref<PlayerPuppet>) -> String {
    let vehicle: wref<VehicleObject> = GetMountedVehicle(player);
    let record: wref<Vehicle_Record>;
    if !IsDefined(vehicle) {
      return "";
    };
    record = vehicle.GetRecord();
    if !IsDefined(record) {
      return "";
    };
    return GetLocalizedText(LocKeyToString(record.DisplayName()));
  }

  // The weather system only exposes rain (no fog or sandstorm state).
  private func Weather() -> String {
    let weather: ref<WeatherSystem> = GameInstance.GetWeatherSystem(GetGameInstance());
    let rain: worldRainIntensity;
    if !IsDefined(weather) {
      return "unknown";
    };
    rain = weather.GetRainIntensityType();
    if Equals(rain, worldRainIntensity.HeavyRain) {
      return "heavy rain";
    };
    if Equals(rain, worldRainIntensity.LightRain) {
      return "light rain";
    };
    if weather.GetRainPuddles() > 0.3 {
      return "no rain, wet streets";
    };
    return "no rain";
  }

  private func HealthPercent(player: ref<PlayerPuppet>) -> Float {
    return GameInstance.GetStatPoolsSystem(GetGameInstance()).GetStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, true);
  }

  private func TwoDigits(value: Int32) -> String {
    return value < 10 ? "0" + IntToString(value) : IntToString(value);
  }
}

public class ApisK0HideLineCallback extends DelayCallback {
  private let m_chat: wref<ApisK0Chat>;
  private let m_id: CRUID;

  public static func Create(chat: ref<ApisK0Chat>, id: CRUID) -> ref<ApisK0HideLineCallback> {
    let callback: ref<ApisK0HideLineCallback> = new ApisK0HideLineCallback();
    callback.m_chat = chat;
    callback.m_id = id;
    return callback;
  }

  public func Call() -> Void {
    if IsDefined(this.m_chat) {
      this.m_chat.Hide(this.m_id);
    };
  }
}

// Apiko's name in its own color. Other speakers are left untouched.
@wrapMethod(SubtitleLineLogicController)
public func SetLineData(const lineData: script_ref<scnDialogLineData>) -> Void {
  wrappedMethod(lineData);
  let label: String;
  let color: HDRColor;
  if ApisK0ChatConfig.IsOwnSpeaker(Deref(lineData).speakerName) {
    // The vanilla "{NAME}:" format resolves NAME as a localization key (now ours): set as plain text too, in case the
    // key is missing (ApisK0.archive not installed).
    label = ApisK0ChatConfig.SpeakerLabel();
    color = ApisK0ChatConfig.SpeakerColor();
    if Equals(Deref(lineData).speakerName, ApisK0ChatConfig.UnknownSpeakerName()) {
      label = GetLocalizedTextByKey(ApisK0ChatConfig.UnknownSpeakerKey());
      if StrLen(label) == 0 {
        label = "???";
      };
      color = ApisK0ChatConfig.UnknownSpeakerColor();
    };
    if Equals(Deref(lineData).speakerName, ApisK0ChatConfig.NetWatchSpeakerName()) {
      label = GetLocalizedTextByKey(ApisK0ChatConfig.NetWatchSpeakerKey());
      if StrLen(label) == 0 {
        label = "NETWATCH";
      };
      color = ApisK0ChatConfig.NetWatchSpeakerColor();
    };
    inkTextRef.SetText(this.m_speakerNameWidget, label + ":");
    inkTextRef.SetTintColor(this.m_speakerNameWidget, color);
  };
}
