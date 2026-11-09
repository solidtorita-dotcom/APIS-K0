"""Where the bridge finds its files, run from source (python apiko_bridge.py) or packaged (Apiko.exe).

Read-only files shipped with the bridge (prompt.md, barks.json, lore.json, config.example.json) sit next to the
code: Path(__file__).parent, which PyInstaller also points at its bundle folder.
What the bridge writes (config.json, data/: memory, log, speech cache; models/: voices and Whisper, downloaded on
first use) goes to the player's folder, %LOCALAPPDATA%\\Apiko (APIKO_HOME overrides it), so it survives reinstalling
or updating the mod. Run from source the first time, the old bridge/config.json, data/ and models/ move there.
The game's mod folder: the packaged bridge lives in <mod>\\bridge\\Apiko.exe, so it is the exe's grandparent;
config.json's game_mod_dir overrides it (needed when run from source).
"""

import os
import shutil
import sys
from pathlib import Path

FROZEN = getattr(sys, "frozen", False)
HERE = Path(__file__).resolve().parent

USER_DIR = Path(os.environ.get("APIKO_HOME") or Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "Apiko")
CONFIG_FILE = USER_DIR / "config.json"
DATA_DIR = USER_DIR / "data"
MODELS_DIR = USER_DIR / "models"


def migrate_from_source_folder():
    """Moves what an older bridge kept next to its code into USER_DIR (only what USER_DIR does not have yet)."""
    if FROZEN:
        return []
    moved = []
    for name in ("config.json", "data", "models"):
        old, new = HERE / name, USER_DIR / name
        if old.exists() and not new.exists():
            USER_DIR.mkdir(parents=True, exist_ok=True)
            shutil.move(str(old), str(new))
            moved.append(name)
    return moved


def mod_dir(config):
    """The ApisK0 CET mod folder, or None when unknown (run from source without game_mod_dir)."""
    configured = str(config.get("game_mod_dir") or "").strip()
    if configured:
        return Path(configured)
    if FROZEN:
        return Path(sys.executable).resolve().parent.parent
    return None
