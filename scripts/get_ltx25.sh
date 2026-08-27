#!/usr/bin/env bash
# /opt/get_ltx25.sh  (resume-friendly)
# Downloads LTX-2.5 (22B) model files for ComfyUI.
#
# Kept separate from get_ltx2.sh: LTX-2.5 shares little with 2 / 2.3 beyond the
# vendor. It loads a transformer from diffusion_models rather than a checkpoint,
# uses a Gemma-4 text encoder instead of Gemma-3, and adds an audio VAE.
#
# NOTE: Lightricks/LTX-2.5 is a GATED repo. Accept the licence on the model page
# and log in with `hf auth login` before running; see check_gated_access below.
set -uo pipefail

export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"   # persistent HF cache
HF="${HF:-/opt/venv/bin/hf}"                            # overridable for tests

MODEL_HOME="${MODEL_HOME:-$HOME/comfy-ui/models}"
STAGE="$MODEL_HOME/.hf_stage_ltx25"                     # persistent staging (enables resume)

REPO="Lightricks/LTX-2.5"                # gated
ENHANCER_REPO="Comfy-Org/gemma-4"        # public

mkdir -p "$MODEL_HOME"/{text_encoders,vae,diffusion_models,latent_upscale_models}
mkdir -p "$STAGE"

# Lightricks/LTX-2.5 returns 401 to anonymous clients. Every other downloader in
# this image works without credentials, so fail early with instructions rather
# than letting `hf download` surface a bare HTTP error mid-run.
check_gated_access() {
  if "$HF" auth whoami >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'GATED'
✗ Not logged in to Hugging Face, and Lightricks/LTX-2.5 is a gated repository.

  1. Open https://huggingface.co/Lightricks/LTX-2.5 and click
     "Agree and access repository" (one time, needs an HF account).
  2. Create a read token at https://huggingface.co/settings/tokens
  3. Run:  hf auth login

  Then re-run this script. Downloads resume, so nothing already fetched
  is lost.

  The 'enhancer' target is public and works without any of this.
GATED
  return 1
}

download_if_missing () {
  local remote="$1"
  local dest_path="$2"          # Relative path under MODEL_HOME, e.g. "vae"
  local repo="${3:-$REPO}"      # Defaults to the gated LTX-2.5 repo

  local dest_dir="$MODEL_HOME/$dest_path"
  local dest_file="$dest_dir/$(basename "$remote")"
  local staged="$STAGE/$remote"

  if [[ -f "$dest_file" ]]; then
    echo "✓ Already present: $dest_file"
    return 0
  fi

  echo "HF Transfer: ${HF_HUB_ENABLE_HF_TRANSFER}"
  echo "↓ Downloading $(basename "$remote") → $dest_file"
  mkdir -p "$(dirname "$staged")"        # ensure stage path exists
  mkdir -p "$dest_dir"                   # ensure dest dir exists

  if ! "$HF" download "$repo" "$remote" \
      --repo-type model \
      --cache-dir "$HF_HOME" \
      --local-dir "$STAGE"; then
    echo "  ⚠ Download failed: $remote" >&2
    [[ "$repo" == "$REPO" ]] && echo "    If this is a 401/403, see the gated-access note above." >&2
    return 1
  fi
  mv -f "$staged" "$dest_file"
}

usage() {
  cat <<'USAGE'
Usage: get_ltx25.sh <target>

LTX-2.5 (22B) Targets:
  common      Text encoder (Gemma-4 12B int8) + video/audio VAEs
  enhancer    Prompt-enhancer CLIP (Gemma-4 E2B int8, public repo)
  distilled   LTX-2.5 22B distilled transformer (int8-convrot)
  upscaler    Latent spatial upscaler x2 (needed by the two-stage workflow)
  all         common + enhancer + distilled + upscaler  (~46 GB)

Maintenance:
  clean-stage   Remove staging folder (keeps final models)
  clean-cache   Remove Hugging Face cache (~/.cache/huggingface)

Notes:
- Lightricks/LTX-2.5 is GATED: accept the licence on the model page and run
  `hf auth login` first. The 'enhancer' target is public.
- int8-convrot builds are used deliberately: transformer + text encoder come to
  ~37 GB versus ~68 GB for bf16, which leaves headroom on a 128 GB machine.
- The VAEs and the upscaler ship only in bf16, so those are unquantised.
- Both video VAEs are fetched: the workflows default to the diffusion decoder
  (ltx-2.5-video-vae-bf16); ltx-2.5-video-vae-conv-bf16 is the lower-memory,
  faster alternative you can select in the loader node.
- Downloads RESUME automatically via persistent --cache-dir and --local-dir.
USAGE
}

rc=0

case "${1:-}" in
  common)
    check_gated_access || exit 1
    echo "==> LTX-2.5 Text Encoder + VAEs"
    download_if_missing "text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors" "text_encoders" || rc=1
    download_if_missing "vae/ltx-2.5-video-vae-bf16.safetensors" "vae" || rc=1
    download_if_missing "vae/ltx-2.5-video-vae-conv-bf16.safetensors" "vae" || rc=1
    download_if_missing "vae/ltx-2.5-audio-vae-bf16.safetensors" "vae" || rc=1
    ;;

  enhancer)
    echo "==> LTX-2.5 Prompt Enhancer (public repo)"
    download_if_missing "text_encoders/gemma4_e2b_it_int8_convrot.safetensors" "text_encoders" "$ENHANCER_REPO" || rc=1
    ;;

  distilled)
    check_gated_access || exit 1
    echo "==> LTX-2.5 22B Distilled Transformer (int8-convrot)"
    download_if_missing "diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors" "diffusion_models" || rc=1
    ;;

  upscaler)
    check_gated_access || exit 1
    echo "==> LTX-2.5 Latent Spatial Upscaler x2"
    download_if_missing "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors" "latent_upscale_models" || rc=1
    ;;

  all)
    "$0" common && "$0" enhancer && "$0" distilled && "$0" upscaler || rc=1
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

if [[ "$rc" == "0" ]]; then
  echo "✓ Done."
else
  echo "⚠ Finished with problems — see warnings above." >&2
fi
exit "$rc"
