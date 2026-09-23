#!/usr/bin/env bash
# Daily rebuild from local harness listings and Artificial Analysis quality/prices
# (https://artificialanalysis.ai/). The existing FirstmateModelCatalog job owns
# refreshes; dispatch/classify/pick read config/model-catalog.json, even if stale.
#
# Usage:
#   fm-model-catalog.sh              write config/model-catalog.json
#   fm-model-catalog.sh --print      score to stdout, do not write
#   fm-model-catalog.sh --ensure     read-only check that a catalog exists
#   fm-model-catalog.sh --stale      exit 1 when the file is missing or stale
#   fm-model-catalog.sh --expand <dispatch.json>
#                                    resolve @flagship/@current/@cheap against
#                                    the catalog; print JSON on stdout
#
# Roles: flagship = highest AA coding/intelligence index at high/default effort;
# current = best quality/price at medium/default; cheap = best measured economy.
# Fast SKUs never receive roles. Unmatched models retain generation scoring.
# Price is USD per million tokens: blended 3:1 when present, else input + output.
# ARTIFICIAL_ANALYSIS_API_KEY or Windows secret-vault's artificial-analysis-api-key
# supplies the credential. Missing key permits heuristics; API failures preserve
# the previous catalog and fail. config/artificial-analysis.json caches all pages
# for 24 hours. The key is never stored. Only a rebuild may fetch AA, once across
# all harnesses, reusing that cache inside its TTL.
# bin/fm-dispatch-resolve.sh expands @roles after snapshotting crew-dispatch.json
# so daily weights reach Jev spawn without rewriting the rules by hand.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CATALOG="$CONFIG/model-catalog.json"
SCORER="$FM_ROOT/bin/fm-model-catalog.mjs"
MAX_AGE_HOURS="${FM_MODEL_CATALOG_MAX_AGE_HOURS:-24}"

MODE="write"
EXPAND_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print) MODE=print; shift ;;
    --ensure) MODE=ensure; shift ;;
    --stale) MODE=stale; shift ;;
    --expand) [ $# -ge 2 ] || { echo "error: --expand needs a file" >&2; exit 2; }
      MODE="expand"; EXPAND_PATH=$2; shift 2 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "error: node required" >&2; exit 1; }
[ -f "$SCORER" ] || { echo "error: missing $SCORER" >&2; exit 1; }

catalog_age_hours() {
  [ -f "$CATALOG" ] || return 1
  python - "$CATALOG" <<'PY'
import os, sys, time
path = sys.argv[1]
try:
    age = (time.time() - os.path.getmtime(path)) / 3600.0
except OSError:
    sys.exit(1)
print(f"{age:.3f}")
PY
}

is_stale() {
  local age
  age=$(catalog_age_hours 2>/dev/null) || return 0
  python - "$age" "$MAX_AGE_HOURS" <<'PY'
import sys
age=float(sys.argv[1]); cap=float(sys.argv[2])
sys.exit(0 if age >= cap else 1)
PY
}

if [ "$MODE" = stale ]; then
  if is_stale; then exit 1; fi
  exit 0
fi

if [ "$MODE" = expand ]; then
  [ -r "$EXPAND_PATH" ] || { echo "error: dispatch file not readable" >&2; exit 2; }
  [ -r "$CATALOG" ] || { echo "error: catalog absent; run the daily catalog job" >&2; exit 1; }
  node "$SCORER" expand <<EOF
{"dispatch": $(cat "$EXPAND_PATH"), "catalog": $(cat "$CATALOG")}
EOF
  exit $?
fi

if [ "$MODE" = ensure ]; then
  [ -r "$CATALOG" ] || { echo "error: catalog absent; run the daily catalog job" >&2; exit 1; }
  exit 0
fi

mkdir -p "$CONFIG"
LOCK="$CONFIG/.model-catalog.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: daily catalog rebuild already locked" >&2
  exit 1
fi
INPUT=""
cleanup() { [ -z "$INPUT" ] || rm -f "$INPUT" "$INPUT.aa"; rmdir "$LOCK"; }
trap cleanup EXIT
INPUT=$(mktemp "${TMPDIR:-/tmp}/fm-model-catalog.XXXXXX") || exit 1

# Listings can be large; collect via python rather than environment variables.
python - "$INPUT" <<'PY'
import json, os, shutil, subprocess, sys
from pathlib import Path

out = Path(sys.argv[1])
home = Path.home()
userprofile = Path(os.environ.get("USERPROFILE") or str(home))

def run(argv):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=25)
        return r.stdout or ""
    except Exception:
        return ""

def which(name):
    return shutil.which(name)

cursor = ""
cursor_bin = which("cursor-agent")
if cursor_bin:
    cursor = run([cursor_bin, "--list-models"])
elif (home / ".local/bin/cursor-agent").exists():
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    shim = str(home / ".local/bin/cursor-agent")
    if git_bash.is_file():
        cursor = run([str(git_bash), "-lc", f'"{shim}" --list-models'])
    else:
        cursor = run([shim, "--list-models"])

grok = ""
grok_bin = which("grok")
if grok_bin:
    grok = run([grok_bin, "models"])

codex = {}
for candidate in (
    Path(os.environ.get("CODEX_HOME") or (home / ".codex")) / "models_cache.json",
    userprofile / ".codex" / "models_cache.json",
):
    if candidate.is_file():
        try:
            codex = json.loads(candidate.read_text(encoding="utf-8"))
        except Exception:
            codex = {}
        break

payload = {
    "cursorText": cursor,
    "grokText": grok,
    "claudeText": "",
    "codexCache": codex,
    "generatedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
}
out.write_text(json.dumps(payload), encoding="utf-8")
PY

node "$SCORER" refresh-aa "$CONFIG/artificial-analysis.json" < "$INPUT" > "$INPUT.aa"
mv "$INPUT.aa" "$INPUT"

if [ "$MODE" = print ]; then
  node "$SCORER" score < "$INPUT"
  exit $?
fi

node "$SCORER" write "$CATALOG" < "$INPUT" >/dev/null
chmod 600 "$CATALOG" 2>/dev/null || true
printf 'model-catalog: wrote %s\n' "$CATALOG"
# Show the roles that dispatch will consume.
node -e 'const fs=require("fs"); const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
for (const [h,v] of Object.entries(c.harnesses||{})) {
  const r=v.roles||{};
  const line=["flagship","current","cheap"].map(k => {
    const row=r[k]; if(!row||!row.model) return k+"=-";
    return k+"="+row.model+(row.effort?"/"+row.effort:"");
  }).join(" ");
  console.log("  "+h+": "+line);
}' "$CATALOG"
