"""Indexes a MediaWiki XML dump: article pages (namespace 0, no redirects) with their categories and size."""
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter

dump, out = sys.argv[1], sys.argv[2]
NS = "{http://www.mediawiki.org/xml/export-0.11/}"
CAT = re.compile(r"\[\[Category:([^\]|]+)", re.IGNORECASE)
pages = []
ns_tag = None
for event, elem in ET.iterparse(dump, events=("end",)):
    tag = elem.tag.split("}")[-1]
    if tag != "page":
        continue
    q = lambda name: elem.find(elem.tag.split("}")[0] + "}" + name)
    title = q("title").text
    ns = q("ns").text
    redirect = q("redirect") is not None
    rev = q("revision")
    text = rev.find(elem.tag.split("}")[0] + "}text").text or "" if rev is not None else ""
    if ns == "0" and not redirect:
        pages.append({"title": title, "cats": [c.strip() for c in CAT.findall(text)], "size": len(text)})
    elem.clear()
json.dump(pages, open(out, "w", encoding="utf-8"), ensure_ascii=False)
counts = Counter(c for p in pages for c in p["cats"])
print(len(pages), "articles")
for cat, n in counts.most_common(120):
    print(n, cat)
