#!/usr/bin/env bash
# Unit tests for get_minimax_h3.sh's target dispatch. No network, no venv:
# $HF points at a stub that logs "<repo> <remote>" and creates the staged
# file the script then moves into place.
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

# new_home -> echoes a fresh fake $HOME containing an `hf` stub.
new_home() {
  local home stub
  home="$(mktemp -d)"
  stub="$home/hf"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
# Mimics: hf download <repo> <remote> --repo-type model --cache-dir D --local-dir S
repo="$2"; remote="$3"; stage=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--local-dir" ]] && stage="$2"
  shift
done
echo "$repo $remote" >>"$DOWNLOAD_LOG"
mkdir -p "$stage/$(dirname "$remote")"
: >"$stage/$remote"
STUB
  chmod +x "$stub"
  : >"$home/downloads.log"
  echo "$home"
}

# run_in HOME TARGET... -> sets OUT, RC, DOWNLOADED, FILES
#   DOWNLOADED = newline-joined "<repo> <remote>" lines from this call only
#   FILES      = space-joined sorted paths under HOME/comfy-ui/models
run_in() {
  local home="$1"; shift
  : >"$home/downloads.log"
  OUT="$(HOME="$home" HF="$home/hf" DOWNLOAD_LOG="$home/downloads.log" \
         bash ./scripts/get_minimax_h3.sh "$@" 2>&1)"
  RC=$?
  DOWNLOADED="$(cat "$home/downloads.log")"
  FILES="$( (cd "$home/comfy-ui/models" 2>/dev/null && \
             find . -type f | sed 's|^\./||' | sort | tr '\n' ' ') || true)"
}

H="$(new_home)"
run_in "$H" common
check "common downloads the text encoder and both VAEs" \
  "Comfy-Org/MiniMax-H3 text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
Comfy-Org/MiniMax-H3 vae/minimax_h3_video_vae_fp16.safetensors
Comfy-Org/MiniMax-H3 vae/minimax_h3_audio_vae_fp32.safetensors" \
  "$DOWNLOADED"
check "common places files under text_encoders/ and vae/" \
  "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors vae/minimax_h3_audio_vae_fp32.safetensors vae/minimax_h3_video_vae_fp16.safetensors " \
  "$FILES"

run_in "$H" common
check "common is idempotent: nothing re-downloaded on a second run" "" "$DOWNLOADED"
rm -rf "$H"

H="$(new_home)"
run_in "$H" fl2va
check "fl2va downloads the T2V/I2V diffusion model" \
  "Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
  "$DOWNLOADED"
rm -rf "$H"

H="$(new_home)"
run_in "$H" ref2va
check "ref2va downloads the R2V diffusion model" \
  "Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
  "$DOWNLOADED"
rm -rf "$H"

H="$(new_home)"
run_in "$H" turbo
check "turbo downloads the LoRA from the larryvrh repo" \
  "larryvrh/MiniMax-H3-Turbo-Lora minimax_h3_turbo_v4_step600_ema.safetensors" \
  "$DOWNLOADED"
check "turbo places the LoRA under loras/" \
  "loras/minimax_h3_turbo_v4_step600_ema.safetensors " \
  "$FILES"
rm -rf "$H"

H="$(new_home)"
run_in "$H" all
check "all fetches common + fl2va + ref2va and not the Turbo LoRA" \
  "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors vae/minimax_h3_audio_vae_fp32.safetensors vae/minimax_h3_video_vae_fp16.safetensors " \
  "$FILES"
rm -rf "$H"

H="$(new_home)"
run_in "$H" bogus-target
check "an unknown target exits 1" "1" "$RC"
check "an unknown target names itself" "0" "$(grep -qF 'Unknown target: bogus-target' <<<"$OUT"; echo $?)"
check "an unknown target prints usage" "0" "$(grep -qF 'Usage: get_minimax_h3.sh' <<<"$OUT"; echo $?)"
rm -rf "$H"

H="$(new_home)"
run_in "$H"
check "no argument prints usage and exits 0" "0" "$RC"
check "no argument downloads nothing" "" "$DOWNLOADED"
rm -rf "$H"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
