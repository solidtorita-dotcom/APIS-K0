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
    return cr2w({
        "$type": "worldStreamingSector",
        "category": "AlwaysLoaded",
        "cookingPlatform": "PLATFORM_None",
        "externInplaceResource": resource(None),
        "level": 1,
        "localInplaceResource": [],
        "nodeData": {"BufferId": "0", "Flags": 0, "Type": "WolvenKit.RED4.Archive.Buffer.worldNodeDataBuffer, "
                     "WolvenKit.RED4, Version=9.1.0.0, Culture=neutral, PublicKeyToken=null", "Data": node_data},
        "nodeRefs": [noderef(CACHE_REF)] + [noderef(ref) for ref in PROP_REFS.values()],
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
    minor = h({"$type": "gameJournalFolderEntry", "entries": [quest], "id": "minor_quest",
               "journalEntryOverrideDataList": []})
    quests = h({"$type": "gameJournalPrimaryFolderEntry", "entries": [minor], "id": "quests",
                "journalEntryOverrideDataList": []})

    # The netrunner's shard, where vanilla and the Zenitex store keep world shards: onscreens/emails/generic/shards/world.
    shard = h({
        "$type": "gameJournalOnscreen", "description": locstring("apisk0-shard-content"), "iconID": tdbid(None),
        "id": SHARD_ID, "journalEntryOverrideDataList": [], "tag": cname("articles"),
        "title": locstring("apisk0-shard-title"),
    })
    world = h({"$type": "gameJournalOnscreenGroup", "entries": [shard], "id": "world", "journalEntryOverrideDataList": []})
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


if __name__ == "__main__":
    main()
