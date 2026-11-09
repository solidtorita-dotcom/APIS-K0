"""Prints the tree of one vanilla journal quest (or lists small quests with map pins)."""
import json
import sys

path = sys.argv[1]
target = sys.argv[2] if len(sys.argv) > 2 else None
data = json.load(open(path, encoding="utf-8"))


def entries(node):
    """Child entries of a journal container node (handles in 'entries')."""
    for handle in node.get("entries", []) or []:
        child = handle.get("Data") if isinstance(handle, dict) else None
        if child:
            yield child


def count(node, kind):
    n = 1 if node.get("$type") == kind else 0
    for child in entries(node):
        n += count(child, kind)
    return n


def size(node):
    return 1 + sum(size(c) for c in entries(node))


def show(node, depth=0, full=False):
    scalars = {k: v for k, v in node.items() if k not in ("entries", "$type") and not isinstance(v, list)}
    text = json.dumps(scalars, ensure_ascii=False)
    print("  " * depth + node["$type"] + " " + (text if full else text[:400]))
    for child in entries(node):
        show(child, depth + 1, full)


def find(node, trail):
    if node.get("$type") == "gameJournalQuest":
        yield node, trail
    for child in entries(node):
        yield from find(child, trail + [child.get("id", "")])


root = data["Data"]["RootChunk"]["entry"]["Data"]
if target:
    for quest, trail in find(root, []):
        if quest.get("id") == target:
            print("/".join(trail))
            show(quest, full=True)
            break
else:
    small = []
    for quest, trail in find(root, []):
        pins = count(quest, "gameJournalQuestMapPin")
        if pins and size(quest) < 15:
            small.append((size(quest), "/".join(trail), pins))
    for s, t, p in sorted(small)[:25]:
        print(s, p, t)
