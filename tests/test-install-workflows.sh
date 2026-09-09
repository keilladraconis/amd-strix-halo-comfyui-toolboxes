#!/usr/bin/env bash
# Unit tests for install_workflows.sh. No container: SRC, COMFY_BASE_DIR and
# STAMP are pointed at temp directories.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/install_workflows.sh"

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# new_env -> a sandbox with a fake /opt/comfy-workflows containing two depth-1
# workflows plus an API/ subdirectory that must never be copied.
new_env() {
  local env; env="$(mktemp -d)"
  mkdir -p "$env/src/API" "$env/src/input"
  echo '{"v":1}' > "$env/src/Alpha.json"
  echo '{"v":1}' > "$env/src/Beta.json"
  echo '{"api":1}' > "$env/src/API/Alpha.json"
  echo 'notjson' > "$env/src/input/pic.png"
  echo "$env"
}

run() { # env [args...]
  local env="$1"; shift
  OUT="$(SRC="$env/src" COMFY_BASE_DIR="$env/base" STAMP="$env/stamp" \
         bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  DEST="$env/base/user/default/workflows"
  INSTALLED="$(ls -1 "$DEST" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
}

# --- plain invocation --------------------------------------------------------
E="$(new_env)"
run "$E"
check "plain run exits 0" "0" "$RC"
check "copies depth-1 workflows into the ComfyUI user directory" "Alpha.json Beta.json " "$INSTALLED"
check "does not copy the API/ subdirectory" "1" \
  "$([[ -e "$DEST/API" ]]; echo $?)"
check "reports the count" "0" "$(grep -qF 'Installed 2 workflow(s)' <<<"$OUT"; echo $?)"
rm -rf "$E"

# --- plain invocation overwrites, so container refreshes pick up updates -----
E="$(new_env)"
run "$E"
echo '{"edited":true}' > "$E/base/user/default/workflows/Alpha.json"
run "$E"
check "a plain re-run overwrites existing files" '{"v":1}' \
  "$(cat "$E/base/user/default/workflows/Alpha.json")"
rm -rf "$E"

# --- --if-needed: install once per image ------------------------------------
E="$(new_env)"
run "$E" --if-needed
check "--if-needed installs when no stamp exists" "Alpha.json Beta.json " "$INSTALLED"
check "--if-needed writes the stamp" "0" "$([[ -f "$E/stamp" ]]; echo $?)"

# This is the behaviour that protects your work: ComfyUI saves an edited
# bundled workflow back to the same filename, and start_comfy_ui runs this on
# every launch.
echo '{"edited":true}' > "$E/base/user/default/workflows/Alpha.json"
run "$E" --if-needed
check "--if-needed does not clobber saved edits once stamped" '{"edited":true}' \
  "$(cat "$E/base/user/default/workflows/Alpha.json")"
check "--if-needed is silent when it skips" "" "$OUT"
check "--if-needed still exits 0 when it skips" "0" "$RC"

# Recreating the toolbox resets the image, and with it the stamp.
rm -f "$E/stamp"
run "$E" --if-needed
check "a reset stamp (new toolbox) reinstalls the bundled copies" '{"v":1}' \
  "$(cat "$E/base/user/default/workflows/Alpha.json")"
rm -rf "$E"

# --- new workflows arrive on a fresh image ----------------------------------
E="$(new_env)"
run "$E" --if-needed
echo '{"v":1}' > "$E/src/Gamma.json"      # a new bundled workflow
rm -f "$E/stamp"                          # ... delivered by a new image
run "$E" --if-needed
check "a new bundled workflow arrives after a toolbox refresh" \
  "Alpha.json Beta.json Gamma.json " "$INSTALLED"
rm -rf "$E"

# --- errors ------------------------------------------------------------------
E="$(new_env)"
run "$E" --bogus
check "an unknown option exits 1" "1" "$RC"
check "an unknown option names itself" "0" \
  "$(grep -qF 'Unknown option: --bogus' <<<"$OUT"; echo $?)"
rm -rf "$E"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
