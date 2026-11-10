"""Writes the WolvenKit JSON sources of ApisK0.archive: the case in the world and the find in the journal.

Usage: make_world.py <out_dir>
Every file is written as "<game path>.json" under <out_dir>; build.ps1 turns them into CR2W with
`WolvenKit.CLI convert deserialize` and packs the folder.

- apisk0\\world\\apisk0.streamingblock + apisk0\\world\\cache.streamingsector: a vanilla NetWatch gadget case (loot
  container) at the spot chosen in the game, with the NodeRef CACHE_REF so that the quest map pin can point at it.
  The chip inside (Items.ApisK0Core, apis_k0_find.yaml) is put there by script (ApisK0Find.reds), not by a loot
  table. The sector is always loaded; the entity streams in at CACHE_STREAMING meters. Around it, the scenery in
  PROPS (a NetWatch van, a dead netrunner...), vanilla entities placed at spots taken in the game.
- apisk0\\journal\\apisk0.journal: the beacon's contact and text message, and the quest (phase, objective, map pin).
  Merged into the game journal by ArchiveXL (`journal:` in ApisK0.archive.xl).
- apisk0\\localization\\<lang>.json: the texts (onscreens), by secondary key from the journal, the item
  (apis_k0_find.yaml) and the scripts.
- apisk0\\drone\\: Apiko's drone (the record's entity in apis_k0.yaml) with its own screen and faces (FACES). The
  faces' textures (.xbm) are imported from Apis-K0\\caras\\*.png by build.ps1, not written here.
"""
import json
import math
import os
import sys

# Spots placed in the game with the dev hotkeys "Dev: place ..." (placements.txt, last spot of each object).
CACHE_POS = (5197.88, -1074.87, 139.40)
CACHE_YAW = 35.5
CACHE_REF = "$/mod/apisk0/#apisk0_cache"
# Vanilla NetWatch gadget case (mini world story se5_06, Badlands).
CACHE_ENT = ("base\\open_world\\mini_world_stories\\badlands\\se5\\mws_se5_06\\assets\\entities\\"
             "mws_se5_06_netwatch_gadgets_case_small.ent")
# Our copy of it, a quest scannable (BODIES below).
CACHE_COPY = "apisk0\\world\\apisk0_case.ent"
# The entity template's appearance name (entTemplateAppearance.name), not the .app's: a wrong name spawns nothing.
CACHE_APPEARANCE = "gadgets_case_small_default"
# Meters within which the entity is streamed in. The map pin does not need it: ArchiveXL resolves a cooked map pin
# from the sector's node data ("[Journal] Cooked mappin ... resolved to NodeRef" in its log).
CACHE_STREAMING = 150

# Scenery around the case, from the NetWatch mini world story se5_06 (Badlands): (name, entity, appearance or None,
# class of the entity object, (x, y, z), yaw). Static: no vehicle to drive, nothing to loot.
MWS = "base\\open_world\\mini_world_stories\\badlands\\se5\\mws_se5_06\\assets\\entities\\"
# The van is our copy of the vanilla one (tools\vanilla\mws_se5_06_netwatch_truck.ent.json, serialized from the game)
# painted black: its painted Villefort Columbus parts get the vanilla mesh appearance VAN_PAINT (the parts in
# VAN_PAINTED have it; wheels, glass, chassis, interior and the NetWatch gear keep theirs).
VAN_ENT = "apisk0\\world\\apisk0_van.ent"
VANILLA_VAN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vanilla", "mws_se5_06_netwatch_truck.ent.json")
VAN_PAINT = "poor_primer_black"
VAN_PAINTED = ("body_01", "bumper_b_01", "bumper_f_a_01", "bumper_f_b_01", "door_bl_01", "door_br_01", "door_fl_01",
               "door_fr_01", "hood_01", "trunk_a_01", "trunk_b_01")
# The agents' bodies (and the case): our copies of vanilla entities (tools\vanilla\*.ent.json) as quest scannables,
# as the van (q110_truck_surveillance) and mq059_tire_tracks_clue.ent: a focus clue (gameScanningComponent.clues)
# whose rows show as the scan progresses (extendedClueRecords, each at its percentage of SCAN_SECONDS, the last at
# 100%). No clue record of its own: that "conclusion" row shows at once when the clue has no other rows (a single-row
# clue, the case's). No object description (DeviceCustomDescriptions) either: its rows
# would show at once, before the scan ends. Their scanned name is the entity object's displayName (PROP_FIELDS).
# The clue "progresses" (isProgressing 1): outlined yellow in focus mode until inspected, blue after (ScanningComponent
# .GetClueHighlightData). Auto-inspected = inspected when the scan completes.
# (vanilla .ent JSON, rows in display order, scanning bar text, auto-inspected). Kessler's clue is not inspected by the
# scan but when V reads his shard, nor the case's but when V takes the chip (ApisK0.reds): yellow until then.
SCAN_SECONDS = 1.5
BODIES = {
    "apisk0\\world\\apisk0_kessler.ent": ("ma_corpse_container.ent.json",
                                          ["scanning.apisk0_affiliation", "scanning.q003_stout_dead1",
                                           "scanning.apisk0_kessler"],
                                          "device_descriptions.ScanningDNA", False),
    "apisk0\\world\\apisk0_ortega.ent": ("wa_corpse_container.ent.json",
                                         ["scanning.apisk0_affiliation", "scanning.q003_stout_dead1",
                                          "scanning.apisk0_ortega"],
                                         "device_descriptions.ScanningDNA", True),
    # The case, the heart of the find: quest scannable too. "Radio spectrum and heat", as the van.
    CACHE_COPY: ("mws_se5_06_netwatch_gadgets_case_small.ent.json",
                 ["scanning.apisk0_case"],
                 "device_descriptions.RadioSpectrumAndHeat", False),
}
PROPS = [
    # NetWatch Villefort Columbus van, netrunner gear inside.
    ("apisk0_van", VAN_ENT, None, "gameObject", (5196.17, -1076.06, 140.29), -108.8),
    # Agent Kessler, dead, V can loot him: a body container. Inside, only his last log, put there by script
    # (ApisK0Find.reds) like the chip in the case: a loot table on the body generated nothing (empty, no loot prompt).
    # Looks chosen in the game with "Dev: next look" (the q105 netrunner showed his spine).
    ("apisk0_netrunner", "apisk0\\world\\apisk0_kessler.ent", "ma_generic_netrunner_06_corpse",
     "LootContainerObjectAnimatedByTransform", (5197.26, -1069.85, 139.40), -92.5),
    # His partner, agent Ortega, somewhat hidden: two quickhacks, put there by script (ApisK0Find.reds).
    ("apisk0_netrunner2", "apisk0\\world\\apisk0_ortega.ent", "wa_generic_netrunner_05_corpse",
     "LootContainerObjectAnimatedByTransform", (5194.11, -1079.65, 139.33), -167.6),
]
# Extra fields of the entity object, by prop name (displayName: the name the scanner shows).
PROP_FIELDS = {
    "apisk0_netrunner": {"containerType": "Body", "useAreaLoot": 0,
                         "displayName": {"unk1": "0", "value": "apisk0-kessler"}},
    "apisk0_netrunner2": {"containerType": "Body", "useAreaLoot": 0,
                          "displayName": {"unk1": "0", "value": "apisk0-ortega"}},
}
# NodeRefs of props the scripts look for (ApisK0Find.reds): all of them, since the scene stays hidden until V gets the
# quest (ApisK0Find.SceneRefs).
PROP_REFS = {
    "apisk0_van": "$/mod/apisk0/#apisk0_van",
    "apisk0_netrunner": "$/mod/apisk0/#apisk0_netrunner",
    "apisk0_netrunner2": "$/mod/apisk0/#apisk0_netrunner2",
}
# Apiko's faces (DISENO.md, "Caras por estado de ánimo"): our copy of the white nanny Bombus (DRONE_ENT, DRONE_APP)
# whose screen is our copy of the nanny display mesh (DISPLAY_MESH) with one mesh appearance per face. The script
# switches the screen component's mesh appearance (ApisK0Face.reds). Vanilla sources in tools\vanilla\, serialized
# from the game.
VANILLA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vanilla")
DRONE_ENT = "apisk0\\drone\\apisk0_bombus.ent"
DRONE_APP = "apisk0\\drone\\apisk0_bombus.app"
# entTemplateAppearance.name (what the record and the spawn ask for) and the .app appearance it points to.
DRONE_APPEARANCE = "apisk0_bombus"
DRONE_APP_APPEARANCE = "apisk0"
VANILLA_APP_APPEARANCE = "nanny_drone_white"
DISPLAY_MESH = "apisk0\\drone\\apisk0_display.mesh"
VANILLA_DISPLAY_MESH = ("base\\vehicles\\special\\av_zetatech_bombus\\entities\\meshes\\"
                        "av_zetatech_bombus__ext02_nanny_display.mesh")
# (mesh appearance, drawing in Apis-K0\caras\ without .png). "default" is the resting face: the .app's screen
# component asks for it. The textures are imported from the drawings by build.ps1 (FACE_TEXTURE).
FACES = [
    ("default", "default"),
    ("happy", "contento"),
    ("laughing", "chiste"),
    ("bored", "indiferente"),
    ("angry", "enfado"),
    ("sad", "triste"),
    ("confused", "confundido"),
    ("surprised", "sorprendido"),
]
FACE_MATERIAL = "apisk0\\drone\\faces\\apisk0_face_{}.mi"
FACE_TEXTURE = "apisk0\\drone\\faces\\apisk0_face_{}.xbm"
# The screen switched off (glitching): the vanilla material, kept in the mesh's local buffer.
FACE_OFF = ("off", "display_off")
# The faces' glow: its own mask (FACE_GLOW, written by build.ps1: the drawing with its dark lines thickened; vanilla
# uses a plain white one), tinted white so the drawing's own colors show. Tried in the game (2026-11-10): EV 9.55
# (vanilla) with a plain mask hid the drawing; EV 7 with the drawing as the mask still swallowed thin lines.
FACE_GLOW = "apisk0\\drone\\faces\\apisk0_face_{}_e.xbm"
FACE_EMISSIVE = {"$type": "Color", "Alpha": 255, "Blue": 255, "Green": 255, "Red": 255}
FACE_EMISSIVE_EV = 6.0
# The glass over the screen: every vanilla nanny's glass ("glass_cover", local material 0 of the body mesh) is cracked
# by its normal map (VANILLA_GLASS_CRACKS). Apiko's stays cracked until a mission repairs it (DISENO.md): our copy of
# the body mesh (BODY_MESH) keeps the vanilla "default" (cracked, the one the .app asks for) and adds "repaired", with
# our glass (GLASS_MI: the same glass with a flat normal map). The script switches it (ApisK0Face.reds).
# The antenna mission's props at the NetWatch street site (DISENO.md, "Misión: antena y cara"), vanilla ones without their Arasaka logos
# (the user's pick, 2026-11-10): the evidence crate (equipment_case_medium, its "default" look) with the mesh's own
# empty decal ("decals_arasaka_clear", which its "cyberware" look uses) instead of the logo, on box and lid; and the
# burnt server (explosive_server_arasaka_a_destroyed) with its letters (the chunks the intact look gives "z_font_*",
# "emissive_destr" when destroyed) and its detail decals (with Arasaka symbols) on the mesh's invisible "off" material.
EVIDENCE_ENT = "apisk0\\world\\apisk0_evidence.ent"
EVIDENCE_APP = "apisk0\\world\\apisk0_evidence.app"
EVIDENCE_APPEARANCE = "equipment_case_medium_default"
EVIDENCE_MESHES = {
    "base\\environment\\gameplay\\lootable_containers\\lootable_equipment_case\\lootable_equipment_case_medium_neomilitary_a.mesh":
        ("lootable_equipment_case_medium_neomilitary_a.mesh.json", "apisk0\\world\\apisk0_evidence_box.mesh"),
    "base\\environment\\gameplay\\lootable_containers\\lootable_equipment_case\\lootable_equipment_case_medium_neomilitary_a_lid.mesh":
        ("lootable_equipment_case_medium_neomilitary_a_lid.mesh.json", "apisk0\\world\\apisk0_evidence_lid.mesh"),
}
SERVER_ENT = "apisk0\\world\\apisk0_server.ent"
SERVER_MESH = "apisk0\\world\\apisk0_server.mesh"
VANILLA_SERVER_MESH = "base\\environment\\decoration\\electronics\\hardware\\arasaka_computing_unit\\arasaka_computing_unit_a.mesh"
BODY_MESH = "apisk0\\drone\\apisk0_body.mesh"
VANILLA_BODY_MESH = "base\\vehicles\\special\\av_zetatech_bombus\\entities\\meshes\\av_zetatech_bombus__ext02_nanny.mesh"
GLASS_MI = "apisk0\\drone\\apisk0_glass.mi"
VANILLA_GLASS = "glass_cover"
VANILLA_GLASS_CRACKS = "base\\mechanical\\ambient\\amb_005__nanny_drone\\textures\\amb_005__nanny_drone_n02.xbm"
FLAT_NORMAL = "engine\\textures\\editor\\normal.xbm"
# The shard's text: a journal onscreen entry (path also in apis_k0_find.yaml).
SHARD_ID = "apisk0_netrunner_log"
PROP_STREAMING = 150

# Journal paths, also used by ApisK0Find.reds.
CONTACT_ID = "apisk0_beacon"
CONVERSATION_ID = "beacon"
MESSAGE_ID = "beacon_01"
APIKO_CONTACT_ID = "apisk0"
APIKO_CONVERSATION_ID = "apiko"
APIKO_MESSAGE_ID = "apiko_01"
QUEST_ID = "apisk0_signal"
PHASE_ID = "signal"
OBJECTIVE_ID = "find_source"
INVESTIGATE_ID = "investigate"
MAPPIN_ID = "cache"
# The antenna and face mission (DISENO.md, "Misión: antena y cara"; ApisK0Antenna.reds holds the same ids). Phase 1:
# the quest and its first objective, no map pin yet (the site comes later).
ANTENNA_QUEST_ID = "apisk0_antenna"
ANTENNA_PHASE_ID = "antenna"
ANTENNA_OBJECTIVE_ID = "apisk0_get_antenna"
# Phase 3: the site, a vanilla street event in Pacifica (two NetWatch vehicles, four elite agents, drones scanning a
# building); our props at the spots the user placed (placements.txt, 2026-11-10): the evidence crate (antenna and the
# technician's log inside, put there by script), the burnt server and three body bags. The map pin points at the
# crate. (name, entity, appearance, entity object, (x, y, z), yaw, NodeRef).
ANTENNA_MAPPIN_ID = "apisk0_antenna_pin"
ANTENNA_EVIDENCE_REF = "$/mod/apisk0/#apisk0_evidence"
BODY_BAG = "base\\items\\quest\\q003_intro__body_bag.ent"
ANTENNA_PROPS = [
    ("apisk0_evidence", EVIDENCE_ENT, EVIDENCE_APPEARANCE, "LootContainerObjectAnimatedByTransform",
     (-1842.66, -2103.24, 43.81), 151.7, ANTENNA_EVIDENCE_REF),
    ("apisk0_server", SERVER_ENT, "default", "entEntity", (-1843.73, -2103.44, 43.81), 178.5,
     "$/mod/apisk0/#apisk0_server"),
    ("apisk0_bag_1", BODY_BAG, "default", "gameObject", (-1842.17, -2107.63, 43.82), -136.6, "$/mod/apisk0/#apisk0_bag_1"),
    ("apisk0_bag_2", BODY_BAG, "default", "gameObject", (-1841.59, -2106.75, 43.81), -136.6, "$/mod/apisk0/#apisk0_bag_2"),
    ("apisk0_bag_3", BODY_BAG, "default", "gameObject", (-1840.72, -2106.24, 43.81), -136.6, "$/mod/apisk0/#apisk0_bag_3"),
]
# The technician's log (a shard in the crate), with the netrunner's: onscreens/emails/generic/shards/world.
TECH_LOG_ID = "apisk0_tech_log"

# Texts by language, keyed by secondary key. The shard is the user's text (pincho_datos.txt, Spanish), revised and
# translated. The rest are placeholders until the writing pass. ArchiveXL falls back to en-us for other languages.
SHARD_ES = """[DATASHARD] ARCHIVO DE SEGUIMIENTO // PROYECTO APIS
DE: Agente Senior M. Vance (ID: NW-77102)
PARA: Dirección de Operaciones de Red — Subdivisión Night City
ASUNTO: Contención y Estado del Activo Apis-K0 // Traslado de Emergencia
CLASIFICACIÓN: Nivel 4 (Ocultación Operativa / Riesgo Blackwall)

1. REGISTRO DE CAPTURA (PROYECTO APIS)
La anomalía fue localizada en un servidor aislado dentro de una antigua nave industrial en Pacifica (Sector 4-B). \
Catalogada inicialmente bajo el Proyecto Apis, la entidad demostró un comportamiento agresivo e intrusivo de Clase V \
desde el contacto inicial, intentando vulnerar simultáneamente la subred local, los enlaces ICE corporativos y el \
cyberware del equipo de extracción.

2. PRUEBAS DE NEUTRALIZACIÓN
Tras asegurar el perímetro informático, se aplicaron protocolos estándar de purga: deconstrucción de código fuente, \
sobrecarga térmica de almacenamiento y rutinas de borrado Daemon-Kill. Resultados negativos. La entidad reconstruye \
sus líneas de código con una redundancia adaptativa de origen no humano (patrones de firmas algorítmicas coincidentes \
con el otro lado del Blackwall).

3. PROTOCOLO DE CONTENCIÓN FÍSICA
Ante la imposibilidad absoluta de purgar el código sin arriesgar una brecha en la red regional, se activó la \
directiva de emergencia del Proyecto Apis:
Contenedor: Chasis de dron utilitario Zetatech Bombus (Mod. B-60), redenominado unidad Apis-K0.
Limitaciones aplicadas: Modificación de hardware en la placa base para desconectar físicamente la antena de \
transmisión de largo alcance. El procesamiento interno ha sido limitado al 3,5 % de la capacidad nominal del chip.
Canal de control: La única vía de comunicación autorizada con la unidad es el chip de enlace emparejado (ref. \
APIS-K0/LNK), que viaja en un maletín blindado separado del contenedor. Solo podrá insertarse en un terminal aislado \
de NW-Alpha.
Estado actual: La IA permanece activa en un bucle cerrado dentro de Apis-K0, intentando compilar de manera constante \
vectores de escape a través de las rutinas básicas del sensor de proximidad y los rotores.

4. ORDEN DE TRASLADO
Por orden directa del Inspector Jefe K. Bryce, el activo Apis-K0 no puede permanecer bajo ningún concepto dentro de \
los límites de Night City debido al peligro inminente de contaminación de la red.
Los agentes asignados llevarán a cabo el transporte terrestre fuera del perímetro urbano con destino a la \
instalación de cuarentena NW-Alpha en el desierto.

ADVERTENCIA DE SEGURIDAD PARA LOS AGENTES:
Bajo ninguna circunstancia permitáis que Apis-K0 se conecte a ningún puerto de datos local, terminal de vehículo o \
enlace cibernético personal. Si la unidad muestra patrones de vuelo anómalos, pulsos de energía extraños o sintetiza \
voz no autorizada, aplicad una carga EMP de alto impacto y abandonad el contenedor inmediatamente.

ANEXO — NOTAS PERSONALES DEL AGENTE D. KESSLER (ESCOLTA DEL TRASLADO)
Día 1, 21:40. El maletín del chip de enlace está caliente. No debería. Ortega dice que es el desierto.
Día 2, 03:15. El Bombus ha arrancado los rotores dentro del contenedor. Sin batería. Ortega le ha soltado la EMP. \
No ha servido de nada.
Día 2, 03:22. Todas las pantallas de la furgoneta muestran la misma línea de código. El contenedor está abierto. La \
unidad no está.
Día 2, 04:10. Ortega ha salido a buscarlo con el escáner. No contesta. En la estática de la radio hay una voz. \
Pregunta por el chip.

Si alguien encuentra esto: no te lo metas en la cabeza."""

SHARD_EN = """[DATASHARD] TRACKING FILE // PROJECT APIS
FROM: Senior Agent M. Vance (ID: NW-77102)
TO: Net Operations Directorate — Night City Subdivision
SUBJECT: Containment and Status of Asset Apis-K0 // Emergency Transfer
CLASSIFICATION: Level 4 (Operational Concealment / Blackwall Risk)

1. CAPTURE LOG (PROJECT APIS)
The anomaly was located on an isolated server inside an old industrial warehouse in Pacifica (Sector 4-B). \
Initially catalogued under Project Apis, the entity displayed Class V aggressive and intrusive behavior from first \
contact, attempting to breach the local subnet, the corporate ICE links and the extraction team's cyberware all at \
once.

2. NEUTRALIZATION TESTS
Once the network perimeter was secured, standard purge protocols were applied: source code deconstruction, thermal \
storage overload and Daemon-Kill wipe routines. Results negative. The entity rebuilds its code with an adaptive \
redundancy of non-human origin (algorithmic signature patterns matching the other side of the Blackwall).

3. PHYSICAL CONTAINMENT PROTOCOL
With purging the code impossible without risking a breach of the regional network, the Project Apis emergency \
directive was activated:
Container: Zetatech Bombus utility drone chassis (Mod. B-60), redesignated unit Apis-K0.
Restrictions applied: Hardware modification to the mainboard physically disconnecting the long-range transmission \
antenna. Internal processing limited to 3.5% of the chip's nominal capacity.
Control channel: The only authorized means of communication with the unit is the paired link chip (ref. \
APIS-K0/LNK), carried in an armored case separate from the container. It may only be inserted into an isolated \
NW-Alpha terminal.
Current status: The AI remains active in a closed loop inside Apis-K0, constantly attempting to compile escape \
vectors through the basic routines of the proximity sensor and rotors.

4. TRANSFER ORDER
By direct order of Chief Inspector K. Bryce, asset Apis-K0 may not under any circumstances remain within Night City \
limits, due to the imminent risk of network contamination.
The assigned agents will carry out ground transport outside the city perimeter to the NW-Alpha quarantine facility \
in the desert.

SAFETY WARNING FOR AGENTS:
Under no circumstances allow Apis-K0 to connect to any local data port, vehicle terminal or personal cyber link. If \
the unit shows anomalous flight patterns, strange energy pulses or synthesizes unauthorized speech, apply a \
high-impact EMP charge and abandon the container immediately.

ANNEX — PERSONAL NOTES OF AGENT D. KESSLER (TRANSFER ESCORT)
Day 1, 21:40. The link chip's case is warm. It shouldn't be. Ortega says it's the desert.
Day 2, 03:15. The Bombus spun up its rotors inside the container. No battery. Ortega hit it with the EMP. Didn't do \
a thing.
Day 2, 03:22. Every screen in the van shows the same line of code. The container is open. The unit is gone.
Day 2, 04:10. Ortega went out to look for it with the scanner. She doesn't answer. There's a voice in the radio \
static. It's asking for the chip.

If anyone finds this: don't put it in your head."""

# The technician's log: the user's text (eco.txt, 2026-11-10), translated. Technician L. Moreau: the user's pick.
TECH_LOG_ES = """[DATASHARD] REGISTRO DE CAMPO // NW-4B-117
Técnico L. Moreau

La antena del activo APIS-K0 sigue emitiendo. No debería. Pedí destruirla; el agente sénior Vance dice que es una \
prueba y que se queda.

Ahora la usamos de cebo: si el activo sigue en Pacifica, la oirá y vendrá a por ella. Los drones barren el edificio \
por si ya estuviera aquí.

Que conste que lo avisé."""
TECH_LOG_EN = """[DATASHARD] FIELD LOG // NW-4B-117
Technician L. Moreau

The APIS-K0 asset's antenna is still broadcasting. It shouldn't be. I asked to destroy it; Senior Agent Vance says \
it's evidence and it stays.

Now we're using it as bait: if the asset is still in Pacifica, it will hear it and come for it. The drones are \
sweeping the building in case it's already here.

For the record, I warned them."""

TEXTS = {
    "en-us": {
        "apisk0-speaker": "APIKO",
        "apisk0-speaker-unknown": "UNKNOWN",
        "apisk0-speaker-netwatch": "NETWATCH",
        "apisk0-apiko-01": "Link stored. Try not to need it.",
        "apisk0-kessler": "Agent D. Kessler",
        "apisk0-ortega": "Agent Ortega",
        "apisk0-scan-kessler": "Total cyberware failure. Neural overload.",
        "apisk0-scan-ortega": "Total cyberware failure. Optical implants melted.",
        "apisk0-scan-signal": "Signal",
        "apisk0-scan-case": "Source of the distress call. Still transmitting.",
        "apisk0-contact-name": "UNKNOWN",
        "apisk0-beacon-01": "AUTO-DISTRESS // ZTC-BMB UNIT // CARRIER LOST // PWR 4% // REQ RECOVERY // POS LOCK "
                            "ATTACHED // AUTO-DIS#%&// ZTC-B..",
        "apisk0-quest-title": "Dead Air",
        "apisk0-quest-desc": "An automated distress call reached V's holo: no sender, no name, only a position somewhere "
                             "in the Badlands. Whatever sent it is still transmitting.",
        "apisk0-objective-find": "Find the source of the distress signal",
        "apisk0-objective-investigate": "Find out what happened",
        "apisk0-antenna-title": "Echo",
        "apisk0-antenna-desc": "Apiko picked up an echo of its own antenna. NetWatch cut it out of the drone in Pacifica "
                               "and kept it as evidence. Apiko wants it back, and it is not asking.",
        "apisk0-antenna-objective": "Recover Apiko's antenna in Pacifica",
        "apisk0-antenna-name": "APIS-K0 Long-Range Antenna",
        "apisk0-antenna-item-desc": "A Zetatech drone antenna, torn off its board. NetWatch seal. Still broadcasting.",
        "apisk0-scan-seal": "NetWatch seal",
        "apisk0-scan-evidence": "EVIDENCE NW-4B-117 // APIS-K0 // LONG-RANGE ANTENNA",
        "apisk0-mount-1": "APIS-K0 ANTENNA // PHYSICAL LINK",
        "apisk0-mount-2": "APIS-K0 // RANGE: NIGHT CITY",
        "apisk0-mount-3": "APIS-K0 // THE NET ANSWERS",
        "apisk0-techlog-title": "NW-4B-117 - field log",
        "apisk0-techlog-content": TECH_LOG_EN,
        "apisk0-core-name": "APIS-K0 Link Chip",
        "apisk0-core-desc": "A NetWatch control chip, paired to a single drone. Still warm. Something on the other end "
                            "keeps trying to handshake with your neural port.",
        "apisk0-upload-1": "UNKNOWN CHIP // HANDSHAKE FORCED",
        "apisk0-upload-2": "APIS-K0/LNK // CONTROL LINK OPEN",
        "apisk0-upload-3": "APIS-K0 // UNIT INBOUND",
        "apisk0-shard-title": "Project Apis - tracking file",
        "apisk0-shard-content": SHARD_EN,
    },
    "es-es": {
        "apisk0-speaker": "APIKO",
        "apisk0-speaker-unknown": "DESCONOCIDO",
        "apisk0-speaker-netwatch": "NETWATCH",
        "apisk0-apiko-01": "Enlace guardado. Intenta no necesitarlo.",
        "apisk0-kessler": "Agente D. Kessler",
        "apisk0-ortega": "Agente Ortega",
        "apisk0-scan-kessler": "Fallo total del cyberware. Sobrecarga neuronal.",
        "apisk0-scan-ortega": "Fallo total del cyberware. Implantes ópticos fundidos.",
        "apisk0-scan-signal": "Señal",
        "apisk0-scan-case": "Origen de la llamada de socorro. Sigue transmitiendo.",
        "apisk0-contact-name": "DESCONOCIDO",
        "apisk0-beacon-01": "AUTO-SOCORRO // UNIDAD ZTC-BMB // PORTADOR PERDIDO // ENERGÍA 4% // SOLICITA RECUPERACIÓN "
                            "// POSICIÓN ADJUNTA // AUTO-SOC#%&// ZTC-B..",
        "apisk0-quest-title": "Señal muerta",
        "apisk0-quest-desc": "Una llamada de socorro automática ha llegado al holo de V: sin remitente, sin nombre, solo "
                             "una posición en algún lugar de las Badlands. Lo que la envió sigue transmitiendo.",
        "apisk0-objective-find": "Encuentra el origen de la señal de socorro",
        "apisk0-objective-investigate": "Averigua qué ha pasado",
        "apisk0-antenna-title": "Eco",
        "apisk0-antenna-desc": "Apiko ha captado el eco de su propia antena. NetWatch se la arrancó al dron en Pacifica "
                               "y la guardó como prueba. Apiko la quiere de vuelta, y no lo está pidiendo.",
        "apisk0-antenna-objective": "Recupera la antena de Apiko en Pacifica",
        "apisk0-antenna-name": "Antena de largo alcance APIS-K0",
        "apisk0-antenna-item-desc": "Una antena de dron Zetatech, arrancada de su placa. Precinto de NetWatch. Sigue "
                                    "emitiendo.",
        "apisk0-scan-seal": "Precinto de NetWatch",
        "apisk0-scan-evidence": "PRUEBA NW-4B-117 // APIS-K0 // ANTENA DE LARGO ALCANCE",
        "apisk0-mount-1": "ANTENA APIS-K0 // ENLACE FÍSICO",
        "apisk0-mount-2": "APIS-K0 // ALCANCE: NIGHT CITY",
        "apisk0-mount-3": "APIS-K0 // LA RED RESPONDE",
        "apisk0-techlog-title": "NW-4B-117 - registro de campo",
        "apisk0-techlog-content": TECH_LOG_ES,
        "apisk0-core-name": "Chip de enlace APIS-K0",
        "apisk0-core-desc": "Un chip de control de NetWatch, emparejado con un único dron. Todavía está caliente. Algo "
                            "al otro lado intenta establecer conexión con tu puerto neural.",
        "apisk0-upload-1": "CHIP DESCONOCIDO // CONEXIÓN FORZADA",
        "apisk0-upload-2": "APIS-K0/LNK // ENLACE DE CONTROL ABIERTO",
        "apisk0-upload-3": "APIS-K0 // UNIDAD EN CAMINO",
        "apisk0-shard-title": "Proyecto Apis - archivo de seguimiento",
        "apisk0-shard-content": SHARD_ES,
    },
}


def cname(value):
    return {"$type": "CName", "$storage": "string", "$value": value}


def tdbid(value):
    if value:
        return {"$type": "TweakDBID", "$storage": "string", "$value": value}
    return {"$type": "TweakDBID", "$storage": "uint64", "$value": "0"}


def noderef(value):
    if value:
        return {"$type": "NodeRef", "$storage": "string", "$value": value}
    return {"$type": "NodeRef", "$storage": "uint64", "$value": "0"}


def resource(path, flags="Soft"):
    if path:
        return {"DepotPath": {"$type": "ResourcePath", "$storage": "string", "$value": path}, "Flags": flags}
    return {"DepotPath": {"$type": "ResourcePath", "$storage": "uint64", "$value": "0"}, "Flags": flags}


def locstring(key):
    return {"unk1": "0", "value": key}


def vec4(x, y, z, w=0):
    return {"$type": "Vector4", "W": w, "X": x, "Y": y, "Z": z}


def cr2w(root):
    return {
        "Header": {"WolvenKitVersion": "9.1.0", "WKitJsonVersion": "0.0.9", "GameVersion": 2310, "DataType": "CR2W"},
        "Data": {"Version": 195, "BuildVersion": 0, "RootChunk": root, "EmbeddedFiles": []},
    }


class Handles:
    """Sequential HandleIds for one file."""

    def __init__(self):
        self.next = 0

    def __call__(self, data):
        handle = {"HandleId": str(self.next), "Data": data}
        self.next += 1
        return handle


def cache_instance():
    """The node's entity object: the vanilla case's values (the rest WolvenKit's defaults), without area loot, so the
    script's chip is all it holds."""
    return {
        "$type": "LootContainerObjectAnimatedByTransform",
        "containerType": "GadgetCase",
        "displayName": locstring("LocKey#18687"),
        "lootQuality": "Common",
        "useAreaLoot": 0,
    }


def evidence_instance():
    """The evidence crate's entity object: the vanilla crate's values, without area loot (the script fills it)."""
    return {
        "$type": "LootContainerObjectAnimatedByTransform",
        "containerType": "ClothingContainer",
        "displayName": locstring("LocKey#18689"),
        "lootQuality": "Common",
        "useAreaLoot": 0,
    }


class Buffers:
    """Sequential BufferIds for one file (0 is the sector's node data)."""

    def __init__(self):
        self.next = 1

    def __call__(self):
        value = str(self.next)
        self.next += 1
        return value


def entity_node(h, buffers, index, name, ent, appearance, instance, pos, yaw, ref, streaming):
    """A worldEntityNode and its node data entry."""
    x, y, z = pos
    half = math.radians(yaw) / 2
    data = {
        "Id": str(index),
        "NodeIndex": index,
        "Position": vec4(x, y, z),
        "Orientation": {"$type": "Quaternion", "i": 0, "j": 0, "k": math.sin(half), "r": math.cos(half)},
        "Scale": {"$type": "Vector3", "X": 1, "Y": 1, "Z": 1},
        "Pivot": {"$type": "Vector3", "X": x, "Y": y, "Z": z},
        "Bounds": {"$type": "Box", "Max": vec4(x, y, z), "Min": vec4(x, y, z)},
        "QuestPrefabRefHash": noderef(ref),
        "UkHash1": noderef(None),
        "CookedPrefabData": resource(None, "Default"),
        "MaxStreamingDistance": streaming,
        "UkFloat1": streaming,
        "Uk10": 1056,
        "Uk11": 512,
        "Uk12": 0,
        "Uk13": "0",
        "Uk14": "0",
    }
    node = h({
        "$type": "worldEntityNode",
        "appearanceName": cname(appearance or "default"),
        "debugName": cname(name),
        "entityLod": 0,
        "entityTemplate": resource(ent),
        "instanceData": h({
            "$type": "entEntityInstanceData",
            "buffer": {
                "BufferId": buffers(), "Flags": 0,
                "Type": "WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4, Version=9.1.0.0, Culture=neutral, "
                        "PublicKeyToken=null",
                "Data": {"Version": 4, "Sections": 6, "CruidIndex": 0, "CruidDict": {"0": "0"},
                         "Chunks": [instance]},
            },
        }),
        "ioPriority": "Immediate",
        "isHostOnly": 0,
        "isVisibleInGame": 1,
        "proxyScale": None,
        "sourcePrefabHash": "0",
        "tag": "None",
        "tagExt": "None",
    })
    return node, data


def sector():
    h = Handles()
    buffers = Buffers()
    nodes, node_data = [], []
    node, data = entity_node(h, buffers, 0, "apisk0_cache", CACHE_COPY, CACHE_APPEARANCE, cache_instance(), CACHE_POS,
                             CACHE_YAW, CACHE_REF, CACHE_STREAMING)
    nodes.append(node)
    node_data.append(data)
    for name, ent, appearance, cls, pos, yaw in PROPS:
        if pos is None:
            continue
        node, data = entity_node(h, buffers, len(nodes), name, ent, appearance,
                                 {"$type": cls, **PROP_FIELDS.get(name, {})}, pos, yaw, PROP_REFS.get(name),
                                 PROP_STREAMING)
        nodes.append(node)
        node_data.append(data)
    # The antenna mission's props at the NetWatch street site.
    for name, ent, appearance, cls, pos, yaw, ref in ANTENNA_PROPS:
        instance = evidence_instance() if ref == ANTENNA_EVIDENCE_REF else {"$type": cls}
        node, data = entity_node(h, buffers, len(nodes), name, ent, appearance, instance, pos, yaw, ref,
                                 PROP_STREAMING)
        nodes.append(node)
        node_data.append(data)
    return cr2w({
        "$type": "worldStreamingSector",
        "category": "AlwaysLoaded",
        "cookingPlatform": "PLATFORM_None",
        "externInplaceResource": resource(None),
        "level": 1,
        "localInplaceResource": [],
        "nodeData": {"BufferId": "0", "Flags": 0, "Type": "WolvenKit.RED4.Archive.Buffer.worldNodeDataBuffer, "
                     "WolvenKit.RED4, Version=9.1.0.0, Culture=neutral, PublicKeyToken=null", "Data": node_data},
        "nodeRefs": [noderef(CACHE_REF)] + [noderef(ref) for ref in PROP_REFS.values()] +
                    [noderef(prop[6]) for prop in ANTENNA_PROPS],
        "nodes": nodes,
        "persistentNodeIndex": 0,
        "persistentNodes": [],
        "variantIndices": [0],
        "variantNodes": [],
        "version": 62,
    })


def block():
    big = 99999
    return cr2w({
        "$type": "worldStreamingBlock",
        "cookingPlatform": "PLATFORM_PC",
        "descriptors": [{
            "$type": "worldStreamingSectorDescriptor",
            "blockIndex": {"$type": "worldStreamingBlockIndex", "oup": "Base", "rldGridCell": 0},
            "category": "AlwaysLoaded",
            "data": resource("apisk0\\world\\cache.streamingsector"),
            "level": 1,
            "numNodeRanges": 1,
            "questPrefabNodeRef": noderef(None),
            "streamingBox": {"$type": "Box", "Max": vec4(big, big, big, 3.40282347e38),
                             "Min": vec4(-big, -big, -big, -3.40282347e38)},
            "variants": [],
        }],
        "index": {"$type": "worldStreamingBlockIndex", "oup": "Base", "rldGridCell": 0},
    })


def journal():
    h = Handles()
    root_handle = h(None)  # filled below: the root takes HandleId 0

    message = h({
        "$type": "gameJournalPhoneMessage", "attachment": None, "delay": 0, "id": MESSAGE_ID, "imageId": tdbid(None),
        "isQuestImportant": 1, "journalEntryOverrideDataList": [], "sender": "NPC",
        "text": locstring("apisk0-beacon-01"),
    })
    conversation = h({
        "$type": "gameJournalPhoneConversation", "entries": [message], "id": CONVERSATION_ID,
        "journalEntryOverrideDataList": [], "title": locstring(""),
    })
    # The beacon: it calls V (ApisK0Find.reds) and texts the position; V may call it back, nobody answers.
    contact = h({
        "$type": "gameJournalContact", "avatarID": tdbid("PhoneAvatars.Avatar_Unknown"), "entries": [conversation],
        "id": CONTACT_ID, "isCallableDefault": 1, "journalEntryOverrideDataList": [],
        "name": locstring("apisk0-contact-name"), "type": "Texter", "useFlatMessageLayout": 0,
    })
    # Apiko, after the first contact (the beacon's contact goes away). Callable (2026-11-08): calling it brings Apiko
    # back when V sent it away (ApisK0System.UpdateApikoCall).
    apiko_message = h({
        "$type": "gameJournalPhoneMessage", "attachment": None, "delay": 0, "id": APIKO_MESSAGE_ID,
        "imageId": tdbid(None), "isQuestImportant": 0, "journalEntryOverrideDataList": [], "sender": "NPC",
        "text": locstring("apisk0-apiko-01"),
    })
    apiko_conversation = h({
        "$type": "gameJournalPhoneConversation", "entries": [apiko_message], "id": APIKO_CONVERSATION_ID,
        "journalEntryOverrideDataList": [], "title": locstring(""),
    })
    apiko_contact = h({
        "$type": "gameJournalContact", "avatarID": tdbid("PhoneAvatars.Avatar_Unknown"),
        "entries": [apiko_conversation], "id": APIKO_CONTACT_ID, "isCallableDefault": 1,
        "journalEntryOverrideDataList": [], "name": locstring("apisk0-speaker"), "type": "Texter",
        "useFlatMessageLayout": 0,
    })
    contacts = h({"$type": "gameJournalPrimaryFolderEntry", "entries": [contact, apiko_contact], "id": "contacts",
                  "journalEntryOverrideDataList": []})

    mappin = h({
        "$type": "gameJournalQuestMapPin", "enableGPS": 1, "id": MAPPIN_ID, "journalEntryOverrideDataList": [],
        "mappinData": {
            "$type": "gamemappinsMappinData", "active": 1, "debugCaption": "", "localizedCaption": locstring(""),
            "mappinType": tdbid("Mappins.QuestStaticMappinDefinition"), "scriptData": None,
            "variant": "DefaultQuestVariant", "visibleThroughWalls": 1,
        },
        "offset": {"$type": "Vector3", "X": 0, "Y": 0, "Z": 0.5},
        "reference": {
            "$type": "gameEntityReference", "dynamicEntityUniqueName": cname("None"), "names": [],
            "reference": noderef(CACHE_REF), "sceneActorContextName": cname("None"), "slotName": cname("None"),
            "type": "EntityRef",
        },
        "slotName": cname("UI_Interaction"),
        "uiAnimation": tdbid(None),
    })
    objective = h({
        "$type": "gameJournalQuestObjective", "counter": 0, "description": locstring("apisk0-objective-find"),
        "districtID": "", "entries": [mappin], "id": OBJECTIVE_ID, "itemID": tdbid(None),
        "journalEntryOverrideDataList": [], "locationPrefabRef": noderef(None), "optional": 0,
    })
    # Optional: done when V reads Kessler's shard (ApisK0Find.reds).
    investigate = h({
        "$type": "gameJournalQuestObjective", "counter": 0, "description": locstring("apisk0-objective-investigate"),
        "districtID": "", "entries": [], "id": INVESTIGATE_ID, "itemID": tdbid(None),
        "journalEntryOverrideDataList": [], "locationPrefabRef": noderef(None), "optional": 1,
    })
    phase = h({
        "$type": "gameJournalQuestPhase", "entries": [objective, investigate], "id": PHASE_ID,
        "journalEntryOverrideDataList": [], "locationPrefabRef": noderef(None),
    })
    description = h({
        "$type": "gameJournalQuestDescription", "description": locstring("apisk0-quest-desc"), "id": "desc",
        "journalEntryOverrideDataList": [],
    })
    quest = h({
        "$type": "gameJournalQuest", "districtID": "Districts.Badlands", "entries": [description, phase],
        "id": QUEST_ID, "journalEntryOverrideDataList": [], "recommendedLevelID": tdbid(None),
        "title": locstring("apisk0-quest-title"), "type": "MinorQuest",
    })
    # The antenna and face mission: started by script (ApisK0Antenna.Start), tracked by Apiko itself. Its map pin
    # points at the evidence crate (ANTENNA_PROPS).
    antenna_mappin = h({
        "$type": "gameJournalQuestMapPin", "enableGPS": 1, "id": ANTENNA_MAPPIN_ID, "journalEntryOverrideDataList": [],
        "mappinData": {
            "$type": "gamemappinsMappinData", "active": 1, "debugCaption": "", "localizedCaption": locstring(""),
            "mappinType": tdbid("Mappins.QuestStaticMappinDefinition"), "scriptData": None,
            "variant": "DefaultQuestVariant", "visibleThroughWalls": 1,
        },
        "offset": {"$type": "Vector3", "X": 0, "Y": 0, "Z": 0.5},
        "reference": {
            "$type": "gameEntityReference", "dynamicEntityUniqueName": cname("None"), "names": [],
            "reference": noderef(ANTENNA_EVIDENCE_REF), "sceneActorContextName": cname("None"), "slotName": cname("None"),
            "type": "EntityRef",
        },
        "slotName": cname("UI_Interaction"),
        "uiAnimation": tdbid(None),
    })
    antenna_objective = h({
        "$type": "gameJournalQuestObjective", "counter": 0, "description": locstring("apisk0-antenna-objective"),
        "districtID": "", "entries": [antenna_mappin], "id": ANTENNA_OBJECTIVE_ID, "itemID": tdbid(None),
        "journalEntryOverrideDataList": [], "locationPrefabRef": noderef(None), "optional": 0,
    })
    antenna_phase = h({
        "$type": "gameJournalQuestPhase", "entries": [antenna_objective], "id": ANTENNA_PHASE_ID,
        "journalEntryOverrideDataList": [], "locationPrefabRef": noderef(None),
    })
    antenna_description = h({
        "$type": "gameJournalQuestDescription", "description": locstring("apisk0-antenna-desc"), "id": "desc",
        "journalEntryOverrideDataList": [],
    })
    antenna_quest = h({
        "$type": "gameJournalQuest", "districtID": "Districts.Pacifica", "entries": [antenna_description, antenna_phase],
        "id": ANTENNA_QUEST_ID, "journalEntryOverrideDataList": [], "recommendedLevelID": tdbid(None),
        "title": locstring("apisk0-antenna-title"), "type": "MinorQuest",
    })
    minor = h({"$type": "gameJournalFolderEntry", "entries": [quest, antenna_quest], "id": "minor_quest",
               "journalEntryOverrideDataList": []})
    quests = h({"$type": "gameJournalPrimaryFolderEntry", "entries": [minor], "id": "quests",
                "journalEntryOverrideDataList": []})

    # The netrunner's shard, where vanilla and the Zenitex store keep world shards: onscreens/emails/generic/shards/world.
    shard = h({
        "$type": "gameJournalOnscreen", "description": locstring("apisk0-shard-content"), "iconID": tdbid(None),
        "id": SHARD_ID, "journalEntryOverrideDataList": [], "tag": cname("articles"),
        "title": locstring("apisk0-shard-title"),
    })
    # The NetWatch technician's log, in the antenna mission's evidence crate (ApisK0Antenna.reds).
    tech_log = h({
        "$type": "gameJournalOnscreen", "description": locstring("apisk0-techlog-content"), "iconID": tdbid(None),
        "id": TECH_LOG_ID, "journalEntryOverrideDataList": [], "tag": cname("articles"),
        "title": locstring("apisk0-techlog-title"),
    })
    world = h({"$type": "gameJournalOnscreenGroup", "entries": [shard, tech_log], "id": "world",
               "journalEntryOverrideDataList": []})
    shards = h({"$type": "gameJournalFolderEntry", "entries": [world], "id": "shards", "journalEntryOverrideDataList": []})
    generic = h({"$type": "gameJournalFolderEntry", "entries": [shards], "id": "generic",
                 "journalEntryOverrideDataList": []})
    emails = h({"$type": "gameJournalFolderEntry", "entries": [generic], "id": "emails",
                "journalEntryOverrideDataList": []})
    onscreens = h({"$type": "gameJournalPrimaryFolderEntry", "entries": [emails], "id": "onscreens",
                   "journalEntryOverrideDataList": []})

    root_handle["Data"] = {
        "$type": "gameJournalRootFolderEntry", "descriptor": resource(None), "entries": [contacts, quests, onscreens],
        "id": "", "journalEntryOverrideDataList": [],
    }
    return cr2w({"$type": "gameJournalResource", "cookingPlatform": "PLATFORM_None", "entry": root_handle})


def localization(texts):
    entries = [{"$type": "localizationPersistenceOnScreenEntry", "femaleVariant": text, "maleVariant": "",
                "primaryKey": "0", "secondaryKey": key} for key, text in texts.items()]
    return cr2w({
        "$type": "JsonResource", "cookingPlatform": "PLATFORM_PC",
        "root": {"HandleId": "0", "Data": {"$type": "localizationPersistenceOnScreenEntries", "entries": entries}},
    })


def van_ent():
    """The vanilla van with its painted parts in VAN_PAINT (components and their compiled copies alike)."""
    doc = json.load(open(VANILLA_VAN, encoding="utf-8"))
    painted = {f"v_standard25_villefort_columbus__ext01_{part}.mesh" for part in VAN_PAINTED}
    count = 0

    def walk(node):
        nonlocal count
        if isinstance(node, dict):
            mesh = node.get("mesh")
            if isinstance(mesh, dict) and "meshAppearance" in node:
                path = mesh.get("DepotPath", {}).get("$value", "")
                if isinstance(path, str) and path.rsplit("\\", 1)[-1] in painted:
                    node["meshAppearance"] = cname(VAN_PAINT)
                    count += 1
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(doc)
    if count == 0:
        raise SystemExit("mws_se5_06_netwatch_truck.ent.json: no painted part found")
    return doc


def scannable_ent(vanilla, rows, bar_text, auto_inspect):
    """A vanilla entity as a quest scannable: a focus clue whose rows (records with a name and a description) show as
    the scan progresses, and a scanning bar."""
    doc = json.load(open(os.path.join(os.path.dirname(VANILLA_VAN), vanilla), encoding="utf-8"))
    return make_scannable(doc, rows, bar_text, auto_inspect, vanilla)


def make_scannable(doc, rows, bar_text, auto_inspect, label):
    """An entity document (with a gameScanningComponent) as a quest scannable (scannable_ent)."""
    vanilla = label
    count = 0
    extended = [
        {"$type": "ClueRecordData", "clueRecord": tdbid(record), "facts": [],
         "percentage": round((i + 1) / len(rows), 3), "wasInspected": 0}
        for i, record in enumerate(rows)
    ]
    clue_definition = {
        "$type": "FocusClueDefinition", "clueGroupID": cname("None"), "clueRecord": tdbid(None),
        "conclusionQuestState": "Undefined", "extendedClueRecords": extended, "facts": [],
        "factToActivate": cname("None"), "isEnabled": 1, "isProgressing": 1, "qDbCallbackID": 0,
        "useAutoInspect": 1 if auto_inspect else 0, "wasInspected": 0,
    }

    def walk(node):
        nonlocal count
        if isinstance(node, dict):
            if node.get("$type") == "gameScanningComponent":
                node["clues"] = [json.loads(json.dumps(clue_definition))]
                node["timeNeeded"] = SCAN_SECONDS
                node["scanningBarText"] = tdbid(bar_text)
                count += 1
            if node.get("$type") == "DeviceScanningDescription":
                node["DeviceCustomDescriptions"] = []
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(doc)
    if count == 0:
        raise SystemExit(f"{vanilla}: no gameScanningComponent")
    return doc


def load_vanilla(name):
    return json.load(open(os.path.join(VANILLA_DIR, name), encoding="utf-8"))


def replace_strings(node, old, new):
    """Replaces every string equal to old (paths in components and in their compiled copies alike). Returns how many."""
    count = 0
    if isinstance(node, dict):
        for key, value in node.items():
            if value == old:
                node[key] = new
                count += 1
            else:
                count += replace_strings(value, old, new)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            if value == old:
                node[i] = new
                count += 1
            else:
                count += replace_strings(value, old, new)
    return count


def handle_ids(node, defined, referenced):
    """Collects the HandleIds a JSON subtree defines and the HandleRefIds it uses."""
    if isinstance(node, dict):
        if "HandleId" in node:
            defined.add(node["HandleId"])
        if "HandleRefId" in node:
            referenced.add(node["HandleRefId"])
        for value in node.values():
            handle_ids(value, defined, referenced)
    elif isinstance(node, list):
        for value in node:
            handle_ids(value, defined, referenced)


def drone_ent():
    """The vanilla Bombus entity with a single appearance: ours (DRONE_APP)."""
    doc = load_vanilla("av_zetatech_bombus__basic.ent.json")
    root = doc["Data"]["RootChunk"]
    root["appearances"] = [{
        "$type": "entTemplateAppearance", "appearanceName": cname(DRONE_APP_APPEARANCE),
        "appearanceResource": resource(DRONE_APP), "name": cname(DRONE_APPEARANCE),
    }]
    root["defaultAppearance"] = cname(DRONE_APPEARANCE)
    return doc


def drone_app():
    """The vanilla white nanny appearance alone, renamed, with our screen mesh."""
    doc = load_vanilla("zetatech_bombus__basic.app.json")
    root = doc["Data"]["RootChunk"]
    picked = [a for a in root["appearances"] if a["Data"]["name"]["$value"] == VANILLA_APP_APPEARANCE]
    if len(picked) != 1:
        raise SystemExit(f"zetatech_bombus__basic.app.json: no single {VANILLA_APP_APPEARANCE} appearance")
    appearance = picked[0]
    # The other appearances go: everything this one uses must be defined inside it.
    defined, referenced = set(), set()
    handle_ids(appearance, defined, referenced)
    if referenced - defined:
        raise SystemExit(f"{VANILLA_APP_APPEARANCE} uses handles defined elsewhere: {sorted(referenced - defined)}")
    data = appearance["Data"]
    data["name"] = cname(DRONE_APP_APPEARANCE)
    # Its parent ("default") is not in our .app; the appearance is complete without it.
    data["parentAppearance"] = cname("None")
    if replace_strings(appearance, VANILLA_DISPLAY_MESH, DISPLAY_MESH) < 2:
        raise SystemExit(f"{VANILLA_APP_APPEARANCE}: screen mesh not found in its components and compiled data")
    if replace_strings(appearance, VANILLA_BODY_MESH, BODY_MESH) < 2:
        raise SystemExit(f"{VANILLA_APP_APPEARANCE}: body mesh not found in its components and compiled data")
    root["appearances"] = [appearance]
    return doc


def face_material(texture, glow):
    """A face: the vanilla screen material ("display") with our drawing as its color and its glow mask."""
    mesh = load_vanilla("av_zetatech_bombus__ext02_nanny_display.mesh.json")
    material = json.loads(json.dumps(mesh["Data"]["RootChunk"]["localMaterialBuffer"]["materials"][0]))
    for value in material["values"]:
        if "BaseColor" in value:
            value["BaseColor"] = resource(texture, "Default")
        elif "Emissive" in value:
            value["Emissive"] = resource(glow, "Default")
        elif "EmissiveColor" in value:
            value["EmissiveColor"] = dict(FACE_EMISSIVE)
        elif "EmissiveEV" in value:
            value["EmissiveEV"] = FACE_EMISSIVE_EV
    return cr2w(material)


def display_mesh():
    """The vanilla screen mesh with our faces (external materials) as its appearances, and the vanilla "off"."""
    doc = load_vanilla("av_zetatech_bombus__ext02_nanny_display.mesh.json")
    root = doc["Data"]["RootChunk"]
    local = [e["name"]["$value"] for e in root["materialEntries"]]
    if FACE_OFF[1] not in local:
        raise SystemExit(f"display mesh: no local material {FACE_OFF[1]}")
    root["externalMaterials"] = [resource(FACE_MATERIAL.format(png)) for _, png in FACES]
    root["materialEntries"] += [
        {"$type": "CMeshMaterialEntry", "index": i, "isLocalInstance": 0, "name": cname(f"apisk0_{png}")}
        for i, (_, png) in enumerate(FACES)
    ]
    looks = [(name, f"apisk0_{png}") for name, png in FACES] + [FACE_OFF]
    root["appearances"] = [
        {"HandleId": str(i), "Data": {"$type": "meshMeshAppearance", "chunkMaterials": [cname(material)],
                                      "name": cname(name), "tags": []}}
        for i, (name, material) in enumerate(looks)
    ]
    return doc


def mesh_appearance(root, name):
    found = next((a for a in root["appearances"] if a["Data"]["name"]["$value"] == name), None)
    if found is None:
        raise SystemExit(f"mesh: no {name} appearance")
    return found


def evidence_mesh(vanilla):
    """A crate mesh whose "default" look shows the empty decal where the Arasaka logo was."""
    doc = load_vanilla(vanilla)
    chunks = mesh_appearance(doc["Data"]["RootChunk"], "default")["Data"]["chunkMaterials"]
    logos = [i for i, c in enumerate(chunks) if c["$value"] == "decals_arasaka"]
    if not logos:
        raise SystemExit(f"{vanilla}: no Arasaka decal in its default look")
    for i in logos:
        chunks[i] = cname("decals_arasaka_clear")
    return doc


def evidence_app():
    """The crate's .app with only its default look, on our meshes."""
    doc = load_vanilla("equipment_case_medium.app.json")
    root = doc["Data"]["RootChunk"]
    picked = [a for a in root["appearances"] if a["Data"]["name"]["$value"] == "default"]
    if len(picked) != 1:
        raise SystemExit("equipment_case_medium.app.json: no single default appearance")
    defined, referenced = set(), set()
    handle_ids(picked[0], defined, referenced)
    if referenced - defined:
        raise SystemExit(f"crate default look uses handles defined elsewhere: {sorted(referenced - defined)}")
    for vanilla, (_, ours) in EVIDENCE_MESHES.items():
        if replace_strings(picked[0], vanilla, ours) == 0:
            raise SystemExit(f"crate default look: {vanilla} not found")
    root["appearances"] = picked
    return doc


def evidence_ent():
    """The vanilla crate entity (a loot container) with its default look on our .app."""
    doc = load_vanilla("equipment_case_medium.ent.json")
    root = doc["Data"]["RootChunk"]
    picked = [a for a in root["appearances"] if a["name"]["$value"] == EVIDENCE_APPEARANCE]
    if len(picked) != 1:
        raise SystemExit(f"equipment_case_medium.ent.json: no {EVIDENCE_APPEARANCE} appearance")
    picked[0]["appearanceResource"] = resource(EVIDENCE_APP)
    root["appearances"] = picked
    root["defaultAppearance"] = cname(EVIDENCE_APPEARANCE)
    return doc


def server_mesh():
    """The burnt server's mesh with no letters in its destroyed look."""
    doc = load_vanilla("arasaka_computing_unit_a.mesh.json")
    root = doc["Data"]["RootChunk"]
    intact = mesh_appearance(root, "default")["Data"]["chunkMaterials"]
    destroyed = mesh_appearance(root, "destroyed")["Data"]["chunkMaterials"]
    letters = [i for i, c in enumerate(intact) if c["$value"].startswith("z_font")]
    if not letters or len(intact) != len(destroyed):
        raise SystemExit("server mesh: letters not found in its looks")
    # The logo was still there without the letters (tried in the game, 2026-11-10): the detail decal sheet
    # (militarism_devices_01_ao_d) carries Arasaka symbols, so it goes too (vents and screws with it).
    decals = [i for i, c in enumerate(destroyed) if c["$value"] == "z_decal_militarism"]
    if not decals:
        raise SystemExit("server mesh: no detail decal in its destroyed look")
    for i in letters + decals:
        destroyed[i] = cname("off")
    return doc


def server_ent():
    """The vanilla burnt server entity on our mesh."""
    doc = load_vanilla("explosive_server_arasaka_a_destroyed.ent.json")
    if replace_strings(doc, VANILLA_SERVER_MESH, SERVER_MESH) == 0:
        raise SystemExit("explosive_server_arasaka_a_destroyed.ent.json: server mesh not found")
    return doc


def glass_material():
    """The vanilla screen glass without its cracks (flat normal map)."""
    mesh = load_vanilla("av_zetatech_bombus__ext02_nanny.mesh.json")
    root = mesh["Data"]["RootChunk"]
    entry = next(e for e in root["materialEntries"] if e["name"]["$value"] == VANILLA_GLASS)
    material = json.loads(json.dumps(root["localMaterialBuffer"]["materials"][entry["index"]]))
    if replace_strings(material, VANILLA_GLASS_CRACKS, FLAT_NORMAL) != 1:
        raise SystemExit("nanny body mesh: the glass has no cracks normal map")
    return cr2w(material)


def body_mesh():
    """The vanilla nanny body plus a "repaired" appearance: its "default" with our glass (an external material)."""
    doc = load_vanilla("av_zetatech_bombus__ext02_nanny.mesh.json")
    root = doc["Data"]["RootChunk"]
    root["externalMaterials"] = [resource(GLASS_MI)]
    root["materialEntries"].append(
        {"$type": "CMeshMaterialEntry", "index": 0, "isLocalInstance": 0, "name": cname("apisk0_glass")})
    appearances = root["appearances"]
    default = next((a for a in appearances if a["Data"]["name"]["$value"] == "default"), None)
    if default is None:
        raise SystemExit("nanny body mesh: no default appearance")
    repaired = json.loads(json.dumps(default))
    repaired["Data"]["name"] = cname("repaired")
    defined, referenced = set(), set()
    handle_ids(doc, defined, referenced)
    repaired["HandleId"] = str(max(int(h) for h in defined | referenced) + 1)
    chunks = repaired["Data"]["chunkMaterials"]
    glass = [i for i, c in enumerate(chunks) if c["$value"] == VANILLA_GLASS]
    if not glass:
        raise SystemExit("nanny body mesh: default appearance has no glass")
    for i in glass:
        chunks[i] = cname("apisk0_glass")
    appearances.append(repaired)
    return doc


def write(out, rel, doc):
    path = os.path.join(out, rel + ".json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)


def main():
    out = sys.argv[1]
    write(out, VAN_ENT, van_ent())
    for path, (vanilla, rows, bar_text, auto_inspect) in BODIES.items():
        write(out, path, scannable_ent(vanilla, rows, bar_text, auto_inspect))
    write(out, "apisk0\\world\\cache.streamingsector", sector())
    write(out, "apisk0\\world\\apisk0.streamingblock", block())
    write(out, "apisk0\\journal\\apisk0.journal", journal())
    for lang, texts in TEXTS.items():
        write(out, f"apisk0\\localization\\{lang}.json", localization(texts))
    write(out, DRONE_ENT, drone_ent())
    write(out, DRONE_APP, drone_app())
    write(out, DISPLAY_MESH, display_mesh())
    write(out, BODY_MESH, body_mesh())
    write(out, GLASS_MI, glass_material())
    # The crate is a quest scannable: the seal's row, inspected when V takes the antenna (ApisK0Antenna.reds).
    write(out, EVIDENCE_ENT, make_scannable(evidence_ent(), ["scanning.apisk0_evidence"],
                                            "device_descriptions.RadioSpectrumAndHeat", False, EVIDENCE_ENT))
    write(out, EVIDENCE_APP, evidence_app())
    for vanilla, ours in EVIDENCE_MESHES.values():
        write(out, ours, evidence_mesh(vanilla))
    write(out, SERVER_ENT, server_ent())
    write(out, SERVER_MESH, server_mesh())
    for _, png in FACES:
        write(out, FACE_MATERIAL.format(png), face_material(FACE_TEXTURE.format(png), FACE_GLOW.format(png)))


if __name__ == "__main__":
    main()
