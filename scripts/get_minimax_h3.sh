#!/usr/bin/env bash
# /opt/get_minimax_h3.sh  (resume-friendly)
# Downloads the open-weight MiniMax-H3 model files for ComfyUI.
set -euo pipefail

export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"   # persistent HF cache
HF="${HF:-/opt/venv/bin/hf}"                            # overridable for tests

MODEL_HOME="$HOME/comfy-ui/models"
STAGE="$MODEL_HOME/.hf_stage_minimax_h3"                # persistent staging (enables resume)

REPO="Comfy-Org/MiniMax-H3"
TURBO_REPO="larryvrh/MiniMax-H3-Turbo-Lora"

mkdir -p "$MODEL_HOME"/{text_encoders,vae,diffusion_models,loras}
mkdir -p "$STAGE"

download_if_missing () {
  local remote="$1"
  local dest_path="$2"          # Relative path under MODEL_HOME, e.g. "vae"
  local repo="${3:-$REPO}"      # Defaults to the Comfy-Org H3 repo

  local dest_dir="$MODEL_HOME/$dest_path"
  local dest_file="$dest_dir/$(basename "$remote")"
  local staged="$STAGE/$remote"

  if [[ -f "$dest_file" ]]; then
    echo "✓ Already present: $dest_file"
    return
  fi

  echo "HF Transfer: ${HF_HUB_ENABLE_HF_TRANSFER}"
  echo "↓ Downloading $(basename "$remote") → $dest_file"
  mkdir -p "$(dirname "$staged")"        # ensure stage path exists
  mkdir -p "$dest_dir"                   # ensure dest dir exists

  "$HF" download "$repo" "$remote" \
      --repo-type model \
      --cache-dir "$HF_HOME" \
      --local-dir "$STAGE"
  mv -f "$staged" "$dest_file"
}

usage() {
  cat <<'USAGE'
Usage: get_minimax_h3.sh <target>

Targets:
  common      Shared text encoder (Qwen3-VL 32B NVFP4) + video/audio VAEs
  fl2va       T2V and I2V diffusion model
  ref2va      Reference-to-video (R2V) diffusion model
  turbo       MiniMax-H3 Turbo LoRA (v4, step 600 EMA)
  all         common + fl2va + ref2va (does not include turbo)

Maintenance:
  clean-stage   Remove staging folder (keeps final models)
  clean-cache   Remove Hugging Face cache (~/.cache/huggingface)

Notes:
- Downloads RESUME automatically via persistent --cache-dir and --local-dir.
- The Turbo LoRA comes from larryvrh/MiniMax-H3-Turbo-Lora; everything else
  comes from Comfy-Org/MiniMax-H3.
- The Turbo workflows also need the ComfyUI-MiniMax-H3-Turbo custom node,
  which is baked into the image.
USAGE
}

case "${1:-}" in
  common)
    echo "==> Text Encoder + Video/Audio VAEs"
    download_if_missing "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "text_encoders"
    download_if_missing "vae/minimax_h3_video_vae_fp16.safetensors" "vae"
    download_if_missing "vae/minimax_h3_audio_vae_fp32.safetensors" "vae"
    ;;

  fl2va)
    echo "==> MiniMax-H3 T2V/I2V diffusion model"
    download_if_missing "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" "diffusion_models"
    ;;

  ref2va)
    echo "==> MiniMax-H3 R2V diffusion model"
    download_if_missing "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" "diffusion_models"
    ;;

  turbo)
    echo "==> MiniMax-H3 Turbo LoRA"
    download_if_missing "minimax_h3_turbo_v4_step600_ema.safetensors" "loras" "$TURBO_REPO"
    ;;

  all)
    "$0" common
    "$0" fl2va
    "$0" ref2va
    ;;

  clean-stage)
    rm -rf "$STAGE"; echo "✓ Removed stage: $STAGE"
    ;;
  clean-cache)
    rm -rf "$HF_HOME"; echo "✓ Removed HF cache: $HF_HOME"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown target: $1" >&2
    usage
    exit 1
    ;;
esac

echo "✓ Done."
