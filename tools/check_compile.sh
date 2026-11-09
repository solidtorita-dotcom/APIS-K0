#!/bin/sh
# Compile-checks the APIS-K0 scripts (src\r6\scripts\ApisK0) against every script installed in the game,
# including the red4ext plugin scripts (Codeware, mod_settings...), in a sandbox. Run from Git Bash:
#   sh tools/check_compile.sh [sandbox_dir]
# Prints warnings/errors; "Compilation complete" means it compiles.
G="/c/Steam/steamapps/common/Cyberpunk 2077"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="${1:-${TMPDIR:-/tmp}/apisk0_compile}"
rm -rf "$SB"; mkdir -p "$SB/scripts" "$SB/cache"
cp -r "$G/r6/scripts/." "$SB/scripts/"
rm -rf "$SB/scripts/ApisK0"
cp -r "$ROOT/src/r6/scripts/ApisK0" "$SB/scripts/"
find "$G/red4ext/plugins" -name '*.reds' | while read -r f; do
    d="$SB/scripts/_red4ext/$(basename "$(dirname "$f")")"; mkdir -p "$d"; cp "$f" "$d/"
done
cp "$G/r6/cache/final.redscripts" "$SB/cache/final.redscripts"
"$G/engine/tools/scc.exe" -compile "$(cygpath -w "$SB/scripts")" "$(cygpath -w "$SB/cache/final.redscripts")" > "$SB/compile.log" 2>&1
grep -E "WARN|ERROR|Compilation" "$SB/compile.log" | head -40
