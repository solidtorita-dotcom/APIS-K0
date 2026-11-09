"""Extracts the cleaned lead section of selected wiki articles (by category) into batch text files."""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

dump, out_dir = sys.argv[1], Path(sys.argv[2])
GROUPS = {
    "gangs": ["Cyberpunk 2077 Gangs", "Cyberpunk 2077 Organized Crime", "Cyberpunk 2077 Nomad Organizations"],
    "orgs": ["Cyberpunk 2077 Organizations", "Cyberpunk 2077 Fixers"],
    "corps": ["Cyberpunk 2077 Corporations", "Cyberpunk 2077 Brands"],
    "places": ["Cyberpunk 2077 Districts", "Cyberpunk 2077 Sub-districts", "Cyberpunk 2077 Locations",
               "Cyberpunk 2077 Locations - Badlands", "Cyberpunk 2077 Locations - City Center",
               "Cyberpunk 2077 Locations - Heywood", "Cyberpunk 2077 Locations - Pacifica",
               "Cyberpunk 2077 Locations - Santo Domingo", "Cyberpunk 2077 Locations - Watson",
               "Cyberpunk 2077 Locations - Westbrook"],
    "culture": ["Cyberpunk 2077 Artists/Bands", "Cyberpunk 2077 Radio Stations", "Cyberpunk 2077 TV Shows",
                "Cyberpunk 2077 Technology", "Cyberpunk 2077 Lore", "Cyberpunk 2077 Drugs"],
}
want = {cat: g for g, cats in GROUPS.items() for cat in cats}
CAT = re.compile(r"\[\[Category:([^\]|]+)", re.IGNORECASE)


def strip_templates(text):
    out, depth, i = [], 0, 0
    while i < len(text):
        if text.startswith("{{", i):
            depth += 1; i += 2; continue
        if text.startswith("}}", i) and depth:
            depth -= 1; i += 2; continue
        if not depth:
            out.append(text[i])
        i += 1
    return "".join(out)


def clean(text):
    text = re.sub(r"<ref[^>]*/>|<ref.*?</ref>", "", text, flags=re.S)
    text = strip_templates(text)
    text = re.sub(r"\{\|.*?\|\}", "", text, flags=re.S)
    text = re.sub(r"\[\[(File|Image|Category):[^\]]*\]\]", "", text, flags=re.I)
    text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"\[https?://\S+ ([^\]]*)\]", r"\1", text)
    text = re.sub(r"'{2,}", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text


groups = {g: [] for g in GROUPS}
for _, elem in ET.iterparse(dump, events=("end",)):
    if elem.tag.split("}")[-1] != "page":
        continue
    ns = elem.tag.split("}")[0] + "}"
    if elem.find(ns + "ns").text != "0" or elem.find(ns + "redirect") is not None:
        elem.clear(); continue
    rev = elem.find(ns + "revision")
    raw = (rev.find(ns + "text").text or "") if rev is not None else ""
    cats = [c.strip() for c in CAT.findall(raw)]
    group = next((want[c] for c in cats if c in want), None)
    if group:
        lead = clean(raw.split("\n==", 1)[0])
        lead = re.sub(r"\s+", " ", lead).strip()
        if len(lead) > 40:
            groups[group].append((elem.find(ns + "title").text, len(raw), lead[:700]))
    elem.clear()
for g, items in groups.items():
    items.sort(key=lambda x: -x[1])
    with open(out_dir / f"{g}.txt", "w", encoding="utf-8") as f:
        for title, size, lead in items:
            f.write(f"### {title} ({size})\n{lead}\n")
    print(g, len(items))
