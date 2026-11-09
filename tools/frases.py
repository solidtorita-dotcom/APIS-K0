"""Rebuilds FRASES.md (the readable review copy of Apiko's written lines) from bridge/barks.json.

Usage (from the Apis-K0 folder): python tools/frases.py
Edit the lines in barks.json, then run this. A situation missing from GROUPS below is listed at the end.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TIERS = (("calm", "Helado (inestabilidad < 0,3)"), ("cracked", "Con grietas (0,3-0,6)"),
         ("unhinged", "Desquiciado (> 0,6)"))

# (group title, intro, [(situation, title)])
GROUPS = [
    ("Dispositivos (pieza 2)",
     "Comparten la pausa normal de las frases. A veces (control \"Improvised remarks\" de APIKO Settings) improvisa el "
     "modelo en vez de la frase.",
     [("spotted", "Una cámara o torreta te detecta"), ("hostile", "Una torreta se vuelve hostil"),
      ("alarm", "Salta una alarma"), ("breached", "V hace una brecha en una red"), ("pinged", "V hace Ping"),
      ("destroyed", "Se destruye un dispositivo"), ("hacked", "V hackea un dispositivo")]),
    ("Enemigos (pieza 3)",
     "Los avisos (`warn_*`) tienen su propia pausa corta (`warning_cooldown_seconds`, 8 s) y casi siempre suenan;\n"
     "nunca van al modelo. Las demás comparten la pausa normal de las frases.",
     [("warn_netrunner", "Un netrunner enemigo está hackeando a V"), ("warn_sniper", "Un francotirador tiene a V a tiro"),
      ("warn_behind", "Un enemigo en combate a la espalda de V, fuera de su vista"),
      ("warn_elite", "Aparece un enemigo élite, jefe, MaxTac, pesado o mech"),
      ("detected", "Un enemigo detecta a V (fuera de combate)"),
      ("stealth_kill", "V mata en sigilo (el enemigo no sabía de V)"), ("knockout", "V deja inconsciente a un enemigo")]),
    ("Zonas de seguridad (2026-11-07)",
     "Solo frase escrita, nunca el modelo. Se dicen al entrar en la zona, con la probabilidad y pausa de siempre.",
     [("zone_restricted", "V entra en una zona restringida"), ("zone_dangerous", "V entra en una zona hostil")]),
    ("Gente (pieza 5, 2026-11-07)",
     "Aviso urgente (como los de enemigos): pausa corta propia, probabilidad alta, nunca el modelo.",
     [("heat_up", "Sube el nivel de búsqueda de la NCPD")]),
    ("Entorno (pieza 6, 2026-11-07)",
     "Solo frase escrita, nunca el modelo, con la probabilidad y pausa de siempre.",
     [("fight_close", "Empieza cerca una pelea en la que V no está")]),
    ("Combate y hora del día (2026-11-07)",
     "Antes iban siempre al modelo. Cada una con su probabilidad (empieza 0,5, acaba 0,6, anochecer y amanecer 0,4)\n"
     "y la pausa normal. V malherido es urgente: pausa corta propia y nunca el modelo.",
     [("combat_start", "Empieza un combate"), ("combat_end", "Acaba un combate"),
      ("low_health", "V está malherido en combate"), ("nightfall", "Anochece (20:00)"), ("dawn", "Amanece (6:00)")]),
    ("Distritos (2026-11-07)",
     "Al entrar en un distrito (probabilidad 0,9). Gana el más concreto con frases propias (Kabuki antes que Watson,\n"
     "Japantown antes que Westbrook, Dogtown antes que Pacifica); `district` es el genérico. Cambiar de subdistrito\n"
     "dentro del mismo no repite.",
     [("district", "Distrito sin frases propias"), ("district_watson", "Watson"), ("district_kabuki", "Kabuki"),
      ("district_westbrook", "Westbrook"), ("district_japantown", "Japantown"), ("district_citycenter", "City Center"),
      ("district_heywood", "Heywood"), ("district_santodomingo", "Santo Domingo"), ("district_pacifica", "Pacifica"),
      ("district_dogtown", "Dogtown"), ("district_badlands", "Badlands")]),
    ("Lo que hace V (2026-11-07)",
     "Con la probabilidad y pausa normales de las frases.",
     [("civilian_killed", "V mata a un civil"), ("police_killed", "V mata a un policía de la NCPD"),
      ("boss_down", "V derriba a un jefe"), ("heat_lost", "V despista a la policía (búsqueda a cero)"),
      ("body_hidden", "V esconde un cuerpo")]),
    ("Misiones y mensajes (2026-11-07)",
     "Un juicio frío, sin nombrar la misión ni leer el mensaje.",
     [("quest_done", "Misión completada"), ("quest_failed", "Misión fallida"), ("sms", "V recibe un mensaje")]),
    ("Silencios largos (2026-11-07)",
     "Tras `idle_seconds` (480 s) sin que nadie hable, sin tensión, combate ni coche, con probabilidad `idle_chance`\n"
     "(0,6). De noche (21:00-5:00) y con lluvia se suman sus propias frases a las generales.",
     [("idle", "Un pensamiento suelto"), ("idle_night", "De noche"), ("idle_rain", "Con lluvia")]),
]


def table(lines_es, lines_en):
    rows = ["| # | Español | English |", "|---|---|---|"]
    for i, (es, en) in enumerate(zip(lines_es, lines_en), 1):
        rows.append(f"| {i} | {es.replace('|', '/')} | {en.replace('|', '/')} |")
    return rows


def main():
    barks = json.loads((ROOT / "bridge" / "barks.json").read_text(encoding="utf-8"))
    out = ["# Frases escritas de Apiko", "",
           "Revisión del banco `bridge\\barks.json`: lo que Apiko dice sin usar el modelo (0 tokens). Para cambiar una",
           "frase, edítala en `barks.json` y regenera este archivo con `python tools/frases.py` (este archivo es solo",
           "para leerlas). Los `0x3F`, `NULL` y `//` suenan como fallos de audio. En español se evita el género de V.", ""]
    done = set()
    groups = GROUPS + [("Sin clasificar", "Situaciones de barks.json sin título en tools/frases.py.",
                        [(s, s) for s in barks if not s.startswith("_")
                         and s not in {k for _, _, items in GROUPS for k, _ in items}])]
    for title, intro, items in groups:
        items = [(s, t) for s, t in items if s in barks]
        if not items:
            continue
        out += [f"# {title}", "", intro, ""]
        for situation, name in items:
            done.add(situation)
            out += [f"## {name} (`{situation}`)", ""]
            for tier, label in TIERS:
                langs = barks[situation].get(tier, {})
                out += [f"**{label}**", ""] + table(langs.get("es", []), langs.get("en", [])) + [""]
    (ROOT / "FRASES.md").write_text("\n".join(out), encoding="utf-8")
    print(f"FRASES.md: {len(done)} situations")


if __name__ == "__main__":
    main()
