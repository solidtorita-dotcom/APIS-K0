// APIS-K0 - Apiko's faces on the drone's screen (DISENO.md, "Caras por estado de ánimo").
// Apiko does not show what it feels: it holds up a drawing, half to mock V, so V gets what it means. Two moments
// (the user's sketch, Apis-K0\emociones.png): a reaction face at V's words while the reply is on its way (the
// bridge's "react" reply), then each model reply's mood while the reply is said (a "face" reply with every subtitle,
// with the same duration); then the screen goes back to the resting face. "glitching": random faces and the screen
// off, flickering.
// The faces are mesh appearances of our screen mesh (tools\make_world.py, FACES), switched on the screen component
// alone with Codeware's IComponent.ChangeAppearance. An entAppearanceEvent with componentName (as devices switch
// their meshes) left the screen transparent (tried in the game, 2026-11-10): no material loaded.
module ApisK0

public abstract class ApisK0FaceConfig {
  // The screen component in our drone's appearance (apisk0\drone\apisk0_bombus.app).
  public static func Component() -> CName { return n"av_zetatech_bombus__ext02_nanny_display"; }
  // The resting face (the .app asks for it, so a new drone starts with it): the "curious" mood and anything unknown.
  public static func Resting() -> CName { return n"default"; }
  public static func Off() -> CName { return n"off"; }
  // glitching: on each tick, the chance that the screen goes off instead of showing a random face.
  public static func GlitchOffChance() -> Float { return 0.3; }
  // The body component and its mesh appearances (apisk0\drone\apisk0_body.mesh): the glass over the screen comes
  // cracked (vanilla "default") until the repair mission (DISENO.md), then "repaired".
  public static func Body() -> CName { return n"av_zetatech_bombus__ext02_nanny"; }
  public static func GlassCracked() -> CName { return n"default"; }
  public static func GlassRepaired() -> CName { return n"repaired"; }
}

public class ApisK0Face {
  // The face of the reply being said, until m_until (sim time); m_glitching instead of a face.
  private let m_face: CName;
  private let m_glitching: Bool;
  private let m_until: Float;
  // The face is a reaction to V's words (React), not a reply's.
  private let m_reacting: Bool;
  // What the screen shows, and on which drone (a new drone starts with the resting face).
  private let m_shown: CName;
  private let m_shownOn: EntityID;
  // The glass the body shows (a new drone starts cracked).
  private let m_glassShown: CName;

  public static func Create() -> ref<ApisK0Face> {
    let face: ref<ApisK0Face> = new ApisK0Face();
    face.m_face = ApisK0FaceConfig.Resting();
    face.m_shown = ApisK0FaceConfig.Resting();
    return face;
  }

  // A "face" reply from the bridge: the mood for the next duration seconds (each subtitle of a reply extends it).
  // "neutral" (a plain answer) keeps the face on the screen: the reaction face if there is one, else the resting one.
  public func Show(mood: String, duration: Float, now: Float) -> Void {
    if Equals(mood, "neutral") {
      if now >= this.m_until {
        this.m_face = ApisK0FaceConfig.Resting();
        this.m_glitching = false;
      };
    } else {
      this.m_glitching = Equals(mood, "glitching");
      this.m_face = ApisK0Face.FaceOf(mood);
    };
    this.m_until = now + duration;
    this.m_reacting = false;
  }

  // A "react" reply: the face Apiko puts up at V's words before it answers (the bridge's small call). Never over a
  // reply's face; the reply's own face replaces it.
  public func React(mood: String, duration: Float, now: Float) -> Void {
    if now < this.m_until && !this.m_reacting {
      return;
    };
    this.m_glitching = false;
    this.m_face = ApisK0Face.FaceOf(mood);
    this.m_until = now + duration;
    this.m_reacting = true;
  }

  // Every tick: puts the face wanted now on the drone's screen when it shows another one, and the glass (repaired:
  // the save's flag, ApisK0System.m_glassRepaired).
  public func Update(now: Float, drone: ref<GameObject>, repaired: Bool) -> Void {
    let wanted: CName = ApisK0FaceConfig.Resting();
    let glass: CName = repaired ? ApisK0FaceConfig.GlassRepaired() : ApisK0FaceConfig.GlassCracked();
    let screen: ref<IComponent>;
    let body: ref<IComponent>;
    if !IsDefined(drone) {
      return;
    };
    if now < this.m_until {
      wanted = this.m_glitching ? ApisK0Face.GlitchFrame() : this.m_face;
    };
    if drone.GetEntityID() != this.m_shownOn {
      this.m_shownOn = drone.GetEntityID();
      this.m_shown = ApisK0FaceConfig.Resting();
      this.m_glassShown = ApisK0FaceConfig.GlassCracked();
    };
    if !Equals(glass, this.m_glassShown) {
      body = drone.ApisK0FindComponent(ApisK0FaceConfig.Body());
      if IsDefined(body) && body.ChangeAppearance(glass) {
        this.m_glassShown = glass;
      };
    };
    if Equals(wanted, this.m_shown) {
      return;
    };
    // Not attached yet (just spawned): tried again on the next tick.
    screen = drone.ApisK0FindComponent(ApisK0FaceConfig.Component());
    if !IsDefined(screen) || !screen.ChangeAppearance(wanted) {
      return;
    };
    this.m_shown = wanted;
  }

  // The mesh appearance of a mood (the model's moods, Brain.cpp): named after the mood, "curious" is the resting face.
  private static func FaceOf(mood: String) -> CName {
    let faces: array<String> = ["happy", "laughing", "bored", "angry", "sad", "confused", "surprised"];
    if ArrayContains(faces, mood) {
      return StringToName(mood);
    };
    return ApisK0FaceConfig.Resting();
  }

  private static func GlitchFrame() -> CName {
    let faces: array<CName> = [n"default", n"happy", n"laughing", n"bored", n"angry", n"sad", n"confused", n"surprised"];
    if RandF() < ApisK0FaceConfig.GlitchOffChance() {
      return ApisK0FaceConfig.Off();
    };
    return faces[RandRange(0, ArraySize(faces))];
  }
}

// Entity.FindComponentByName is protected.
@addMethod(Entity)
public func ApisK0FindComponent(name: CName) -> ref<IComponent> {
  return this.FindComponentByName(name);
}
