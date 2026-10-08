#!/usr/bin/env bash
# /opt/get_sam3.sh (resume-friendly)
# Downloads SAM 3.1 for ComfyUI's core SAM3_Detect node (text-prompted
# segmentation). Used by the reference-plate detailer pass: segment "eyes" /
# "hands", crop to the returned bbox, re-render at full model resolution,
# composite back.
#
# SAM3 is a first-class supported model in ComfyUI (comfy/ldm/sam3, the SAM3
# entry in supported_models.py, comfy/text_encoders/sam3_clip.py). Its text
# encoder ships INSIDE the same checkpoint under
# detector.backbone.language_backbone., so CheckpointLoaderSimple yields both
# the MODEL and the CLIP that SAM3_Detect needs. There is no separate encoder
# to fetch.
set -euo pipefail

export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"  # Xet fast path
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
HF="/opt/venv/bin/hf"

# ComfyUI runs with --base-directory $HOME/comfy-ui (see
# scripts/start_comfy_ui.sh), so models live under $HOME/comfy-ui/models.
# Do NOT use $HOME/comfy-models here -- that is the pre-base-directory layout
# and ComfyUI does not scan it unless set_extra_paths.sh has been run.
MODEL_HOME="${MODEL_HOME:-$HOME/comfy-ui/models}"
STAGE="$MODEL_HOME/.hf_stage_sam3"

REPO="Comfy-Org/sam3.1"
REMOTE="checkpoints/sam3.1_multiplex_fp16.safetensors"
DEST_DIR="$MODEL_HOME/checkpoints"
DEST_FILE="$DEST_DIR/$(basename "$REMOTE")"

mkdir -p "$DEST_DIR" "$STAGE"

if [[ -f "$DEST_FILE" ]]; then
  echo "✓ Already present: $DEST_FILE"
  exit 0
fi

echo "↓ Downloading $(basename "$REMOTE") (~1.8 GB) → $DEST_FILE"
"$HF" download "$REPO" "$REMOTE" \
    --repo-type model \
    --local-dir "$STAGE"

mv -f "$STAGE/$REMOTE" "$DEST_FILE"
rm -rf "$STAGE"

echo "✓ SAM 3.1 ready: $DEST_FILE"
echo
echo "  Load with CheckpointLoaderSimple -> MODEL + CLIP, then:"
echo "    CLIPTextEncode(\"eyes\") -> SAM3_Detect(model, image, conditioning)"
echo "  SAM3_Detect returns MASK and BBOX; the bbox is what makes a"
echo "  crop-resample-composite detail pass possible rather than plain"
echo "  masked inpainting."
