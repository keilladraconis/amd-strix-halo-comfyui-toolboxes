#!/usr/bin/env bash
# Unit tests for scripts/start_comfy_ui.sh -- the single source of truth for
# ComfyUI's launch flags. Only the --launch-extras introspection mode runs;
# the real launch (and its /opt install scripts) is never reached.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/start_comfy_ui.sh"

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# Run the introspection from a directory that CONTAINS files: the old launcher
# shape expanded its flags unquoted at the call site, so --enable-cors-header
# '*' globbed against the caller's cwd. Nothing may expand here either.
GLOB_DIR="$(mktemp -d)"; touch "$GLOB_DIR/decoy.txt"
EXTRAS="$(cd "$GLOB_DIR" && HOME=/home/test bash "$SCRIPT" --launch-extras)"
RC=$?
rm -rf "$GLOB_DIR"

check "introspection exits 0" "0" "$RC"
check "the port is registered" "0" \
  "$(grep -qF -- '--port 8188' <<<"$EXTRAS"; echo $?)"
check "base-directory expands HOME at call time, not build time" "0" \
  "$(grep -qF -- '--base-directory /home/test/comfy-ui' <<<"$EXTRAS"; echo $?)"
check "the manager is registered" "0" \
  "$(grep -qF -- '--enable-manager' <<<"$EXTRAS"; echo $?)"
# comfy-cli replays this string with a plain split(" ") -- no shlex -- so a
# quote character would arrive at ComfyUI as literal text inside the header
# value, and the wildcard must be the bare *.
check "the CORS wildcard goes out bare" "0" \
  "$(grep -qF -- '--enable-cors-header *' <<<"$EXTRAS"; echo $?)"
check "no quote characters leak into the string" "" \
  "$(printf '%s' "$EXTRAS" | grep -oE "[\"']")"
# split(" ") on a string with leading/trailing space yields empty argv
# entries, which ComfyUI's argparse rejects.
check "no leading or trailing space" "" \
  "$(grep -oE '^ +| +$' <<<"$EXTRAS")"
check "the wildcard survived a directory of files unglobbed" "" \
  "$(grep -oF 'decoy.txt' <<<"$EXTRAS")"

# COMFY_OUTPUT_DIR (README §2.2 / the passthrough feature): appended when set,
# absent when not -- it must not appear as an empty --output-directory.
check "COMFY_OUTPUT_DIR appends --output-directory" "0" \
  "$(HOME=/home/test COMFY_OUTPUT_DIR=/srv/out bash "$SCRIPT" --launch-extras \
     | grep -qF -- '--output-directory /srv/out'; echo $?)"
check "unset COMFY_OUTPUT_DIR leaves the flag absent" "" \
  "$(HOME=/home/test bash "$SCRIPT" --launch-extras | grep -oE -- '--output-directory')"

# --- the launch itself ---------------------------------------------------------
# The regression this whole change is about: bare $(...) expansion globs and
# word-splits; the array form must stay quoted on both consumers' paths.
check "the launch execs with a quoted array" "0" \
  "$(grep -qF 'exec python main.py "${args[@]}"' "$SCRIPT"; echo $?)"
check "no unquoted args expansion in the launcher" "" \
  "$(grep -nF '${args[*]}' "$SCRIPT" | grep -v 'printf')"

# --- tuning subset stays in sync with the benchmark spawners -------------------
# benchmark_workflows.py and collect_perf_logs.py spawn their own ComfyUI and
# hardcode the same tuning flags; they cannot call this script, so the subset
# is asserted here (the guard test-comfy-launch-args.sh used to carry).
for flag in --disable-mmap --bf16-vae --cache-none --gpu-only; do
  check "$flag lives in the launcher and both benchmark spawners" "3" \
    "$(grep -lF -- "$flag" scripts/start_comfy_ui.sh scripts/benchmark_workflows.py scripts/collect_perf_logs.py | wc -l)"
done

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
