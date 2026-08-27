#!/usr/bin/env bash
# Unit tests for get_ltx25.sh's target dispatch and gated-repo handling.
# No network, no venv: $HF points at a stub that logs "<repo> <remote>", fakes
# `hf auth whoami`, and creates the staged file the script moves into place.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# new_home -> a fake $HOME containing an `hf` stub.
#   LOGGED_IN=0 makes `hf auth whoami` fail, simulating no HF login.
#   FAIL_MATCH makes downloads of matching remotes fail, simulating a 401.
new_home() {
  local home stub
  home="$(mktemp -d)"
  stub="$home/hf"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "whoami" ]]; then
  [[ "${LOGGED_IN:-1}" == "1" ]] && { echo "someone"; exit 0; }
  exit 1
fi
repo="$2"; remote="$3"; stage=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--local-dir" ]] && stage="$2"
  shift
done
echo "$repo $remote" >>"$DOWNLOAD_LOG"
[[ -n "${FAIL_MATCH:-}" && "$remote" == *"$FAIL_MATCH"* ]] && exit 1
mkdir -p "$stage/$(dirname "$remote")"
: >"$stage/$remote"
STUB
  chmod +x "$stub"
  echo "$home"
}

# run HOME TARGET... -> sets OUT, RC, DOWNLOADED, FILES
run() {
  local home="$1"; shift
  : >"$home/downloads.log"
  OUT="$(HOME="$home" HF="$home/hf" DOWNLOAD_LOG="$home/downloads.log" \
         MODEL_HOME="$home/models" \
         LOGGED_IN="${LOGGED_IN:-1}" FAIL_MATCH="${FAIL_MATCH:-}" \
         bash ./scripts/get_ltx25.sh "$@" 2>&1)"
  RC=$?
  DOWNLOADED="$(cat "$home/downloads.log")"
  FILES="$( (cd "$home/models" 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ') || true)"
}

# --- common ------------------------------------------------------------------
H="$(new_home)"; LOGGED_IN=1 FAIL_MATCH="" run "$H" common
check "common exits 0" "0" "$RC"
check "common fetches the int8 text encoder and all three VAEs" \
  "Lightricks/LTX-2.5 text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors
Lightricks/LTX-2.5 vae/ltx-2.5-video-vae-bf16.safetensors
Lightricks/LTX-2.5 vae/ltx-2.5-video-vae-conv-bf16.safetensors
Lightricks/LTX-2.5 vae/ltx-2.5-audio-vae-bf16.safetensors" \
  "$DOWNLOADED"
check "common places files under text_encoders/ and vae/" \
  "text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors vae/ltx-2.5-audio-vae-bf16.safetensors vae/ltx-2.5-video-vae-bf16.safetensors vae/ltx-2.5-video-vae-conv-bf16.safetensors " \
  "$FILES"
LOGGED_IN=1 FAIL_MATCH="" run "$H" common
check "common is idempotent" "" "$DOWNLOADED"
rm -rf "$H"

# --- the quantised builds are the ones actually requested --------------------
H="$(new_home)"; LOGGED_IN=1 FAIL_MATCH="" run "$H" distilled
check "distilled fetches the int8-convrot transformer, not bf16" \
  "Lightricks/LTX-2.5 diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors" \
  "$DOWNLOADED"
rm -rf "$H"

H="$(new_home)"; LOGGED_IN=1 FAIL_MATCH="" run "$H" upscaler
check "upscaler fetches the spatial upscaler into latent_upscale_models/" \
  "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors " \
  "$FILES"
rm -rf "$H"

# --- the enhancer comes from the public repo, and needs no login -------------
H="$(new_home)"; LOGGED_IN=0 FAIL_MATCH="" run "$H" enhancer
check "enhancer works while logged out (its repo is public)" "0" "$RC"
check "enhancer fetches from Comfy-Org/gemma-4" \
  "Comfy-Org/gemma-4 text_encoders/gemma4_e2b_it_int8_convrot.safetensors" \
  "$DOWNLOADED"
rm -rf "$H"

# --- gated access is checked before any download is attempted ----------------
for target in common distilled upscaler; do
  H="$(new_home)"; LOGGED_IN=0 FAIL_MATCH="" run "$H" "$target"
  check "$target refuses to run when logged out" "1" "$RC"
  check "$target explains how to get access" "0" \
    "$(grep -qF 'Agree and access repository' <<<"$OUT"; echo $?)"
  check "$target downloads nothing when logged out" "" "$DOWNLOADED"
  rm -rf "$H"
done

# --- a mid-run failure is reported, not silently swallowed -------------------
H="$(new_home)"; LOGGED_IN=1 FAIL_MATCH="audio-vae" run "$H" common
check "a failed download makes common exit non-zero" "1" "$RC"
check "the failed file is named" "0" \
  "$(grep -qF 'Download failed: vae/ltx-2.5-audio-vae-bf16.safetensors' <<<"$OUT"; echo $?)"
check "the gated hint is offered on failure" "0" \
  "$(grep -qF 'gated-access note' <<<"$OUT"; echo $?)"
check "the other three files still landed" "3" \
  "$(find "$H/models" -type f | wc -l)"
rm -rf "$H"

# --- all -----------------------------------------------------------------
H="$(new_home)"; LOGGED_IN=1 FAIL_MATCH="" run "$H" all
# 4 from common (encoder + 3 VAEs) + enhancer + transformer + upscaler
check "all fetches every target" "7" "$(find "$H/models" -type f | wc -l)"
check "all includes the public enhancer" "0" \
  "$(grep -qF 'Comfy-Org/gemma-4' <<<"$DOWNLOADED"; echo $?)"
rm -rf "$H"

# --- error and read-only modes ----------------------------------------------
H="$(new_home)"; LOGGED_IN=1 FAIL_MATCH="" run "$H" bogus
check "an unknown target exits 1" "1" "$RC"
check "an unknown target names itself" "0" \
  "$(grep -qF 'Unknown target: bogus' <<<"$OUT"; echo $?)"

LOGGED_IN=1 FAIL_MATCH="" run "$H"
check "no argument prints usage and exits 0" "0" "$RC"
check "usage warns that the repo is gated" "0" \
  "$(grep -qF 'GATED' <<<"$OUT"; echo $?)"
check "no argument downloads nothing" "" "$DOWNLOADED"
rm -rf "$H"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
