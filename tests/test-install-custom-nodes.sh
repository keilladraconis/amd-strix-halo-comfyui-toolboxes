#!/usr/bin/env bash
# Unit tests for install_custom_nodes.sh. No network, no venv: `git` is stubbed
# on PATH and the interpreter is replaced with a stub that logs pip calls.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/install_custom_nodes.sh"

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# new_env [failing-repo-substring] -> echoes a fresh sandbox directory.
# The git stub creates a plausible clone (a .git dir plus a requirements.txt) so
# the dependency pass has something to find, and fails for any URL matching
# FAIL_MATCH so the no-network path can be exercised.
new_env() {
  local env; env="$(mktemp -d)"
  mkdir -p "$env/bin" "$env/base"
  printf 'torch==2.13.0\ntransformers==4.56.2\n' > "$env/constraints.txt"

  cat >"$env/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >>"$GIT_LOG"
if [[ "$1" == "clone" ]]; then
  url="${@: -2:1}"; target="${@: -1}"
  if [[ -n "${FAIL_MATCH:-}" && "$url" == *"$FAIL_MATCH"* ]]; then exit 1; fi
  mkdir -p "$target/.git"
  printf 'somedep\n' > "$target/requirements.txt"
  exit 0
fi
if [[ "$1" == "-C" ]]; then   # git -C <dir> pull ...
  [[ -n "${FAIL_MATCH:-}" && "$2" == *"$FAIL_MATCH"* ]] && exit 1
  exit 0
fi
exit 0
STUB
  chmod +x "$env/bin/git"

  cat >"$env/bin/py" <<'STUB'
#!/usr/bin/env bash
echo "py $*" >>"$PIP_LOG"
exit 0
STUB
  chmod +x "$env/bin/py"

  echo "$env"
}

# run ENV MODE... -> sets RC, OUT, CLONED (sorted pack names), PIPS (count)
run() {
  local env="$1"; shift
  : >"$env/git.log"; : >"$env/pip.log"
  OUT="$(PATH="$env/bin:$PATH" \
         COMFY_BASE_DIR="$env/base" \
         PY="$env/bin/py" \
         STAMP="$env/stamp" \
         CONSTRAINTS="${CONSTRAINTS_OVERRIDE:-$env/constraints.txt}" \
         GIT_LOG="$env/git.log" \
         PIP_LOG="$env/pip.log" \
         CONSTRAINTS_COPY="${CONSTRAINTS_COPY:-$env/seen.txt}" \
         FAIL_MATCH="${FAIL_MATCH:-}" \
         bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  CLONED="$(ls -1 "$env/base/custom_nodes" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
  # grep -c prints 0 and exits 1 on no match; the printed 0 is what we want.
  PIPS="$(grep -c 'pip install' "$env/pip.log" 2>/dev/null)"
}

EXPECTED="ComfyMath ComfyUI-AMDGPUMonitor ComfyUI-GGUF ComfyUI-LTXVideo ComfyUI-MiniMax-H3-Turbo ComfyUI_essentials "

# --- fresh install -----------------------------------------------------------
E="$(new_env)"
FAIL_MATCH="" run "$E" install
check "a fresh install exits 0" "0" "$RC"
check "a fresh install clones every pack in the manifest" "$EXPECTED" "$CLONED"
check "a fresh install installs each pack's requirements" "6" "$PIPS"
check "packs land in the ComfyUI base directory, not /opt" "0" \
  "$([[ -d "$E/base/custom_nodes/ComfyMath" ]]; echo $?)"

# --- the image's pins are protected from node requirements -------------------
# A pack listing `torch` must not be able to replace the ROCm nightly, and one
# listing `transformers` must not blow past the image's pin.
check "dependency installs pass a constraints file to pip" "6" \
  "$(grep -c -- '-c /tmp/' "$E/pip.log")"

# The effective constraints must carry BOTH the image's pins and the known-bad
# combination pins, or a pack resolves a dependency that breaks it.
E3="$(new_env)"
cat >"$E3/bin/py" <<'STUB'
#!/usr/bin/env bash
# Capture the constraints file pip was handed, before the script deletes it.
for i in $(seq 1 $#); do
  if [[ "${!i}" == "-c" ]]; then j=$((i+1)); cp "${!j}" "$CONSTRAINTS_COPY" 2>/dev/null; fi
done
echo "py $*" >>"$PIP_LOG"
STUB
chmod +x "$E3/bin/py"
CONSTRAINTS_COPY="$E3/seen.txt" FAIL_MATCH="" run "$E3" install
check "the image's pins reach pip" "0" \
  "$(grep -qF 'torch==2.13.0' "$E3/seen.txt"; echo $?)"
check "the kornia pin that keeps ComfyUI-LTXVideo importable reaches pip" "0" \
  "$(grep -qF 'kornia<0.8.2' "$E3/seen.txt"; echo $?)"
rm -rf "$E3"

E2="$(new_env)"
CONSTRAINTS_OVERRIDE="$E2/nonexistent.txt" FAIL_MATCH="" run "$E2" install
check "a missing constraints file is warned about, not silently ignored" "0" \
  "$(grep -qF 'No constraints file' <<<"$OUT"; echo $?)"
check "and installs still proceed unconstrained on older images" "0" "$RC"
unset CONSTRAINTS_OVERRIDE
rm -rf "$E2"

# --- idempotence -------------------------------------------------------------
FAIL_MATCH="" run "$E" install
check "a second install re-clones nothing" "0" "$(grep -c 'git clone' "$E/git.log")"
check "a second install skips dependency work once stamped" "0" "$PIPS"
check "a second install still exits 0" "0" "$RC"
rm -rf "$E"

# --- venv reset: clones persist in \$HOME but deps must be reinstalled --------
E="$(new_env)"
FAIL_MATCH="" run "$E" install
rm -f "$E/stamp"          # toolbox recreated: venv (and its stamp) is gone
FAIL_MATCH="" run "$E" install
check "deps are reinstalled when the venv stamp is gone" "6" "$PIPS"
check "but nothing is re-cloned" "0" "$(grep -c 'git clone' "$E/git.log")"
rm -rf "$E"

# --- update ------------------------------------------------------------------
E="$(new_env)"
FAIL_MATCH="" run "$E" install
FAIL_MATCH="" run "$E" update
check "update pulls each existing clone" "6" "$(grep -c 'git -C' "$E/git.log")"
check "update refreshes dependencies" "6" "$PIPS"
rm -rf "$E"

# --- network failure is reported but not fatal to the other packs ------------
E="$(new_env)"
FAIL_MATCH="ComfyUI-GGUF" run "$E" install
check "a failed clone makes the script exit non-zero" "1" "$RC"
check "a failed clone is named in a warning" "0" \
  "$(grep -qF 'Could not clone ComfyUI-GGUF' <<<"$OUT"; echo $?)"
check "the other five packs still install" "5" "$(ls -1 "$E/base/custom_nodes" | wc -l)"
check "a failed run leaves no stamp, so the next run retries deps" "1" \
  "$([[ -f "$E/stamp" ]]; echo $?)"
rm -rf "$E"

# --- never clobber a user's own directory ------------------------------------
E="$(new_env)"
mkdir -p "$E/base/custom_nodes/ComfyMath"
echo "mine" > "$E/base/custom_nodes/ComfyMath/notes.txt"
FAIL_MATCH="" run "$E" install
check "a non-git directory is left untouched" "mine" \
  "$(cat "$E/base/custom_nodes/ComfyMath/notes.txt")"
check "and that pack is reported as skipped" "0" \
  "$(grep -qF 'Skipping ComfyMath' <<<"$OUT"; echo $?)"
rm -rf "$E"

# --- read-only and error modes ----------------------------------------------
E="$(new_env)"
FAIL_MATCH="" run "$E" list
check "list exits 0" "0" "$RC"
check "list clones nothing" "0" "$(grep -c 'git clone' "$E/git.log")"
check "list reports every pack as missing before install" "6" \
  "$(grep -c 'missing' <<<"$OUT")"

FAIL_MATCH="" run "$E" bogus
check "an unknown mode exits 1" "1" "$RC"
check "an unknown mode names itself" "0" \
  "$(grep -qF 'Unknown mode: bogus' <<<"$OUT"; echo $?)"
rm -rf "$E"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
