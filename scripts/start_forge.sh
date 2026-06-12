#!/usr/bin/env bash
# Launch Stable Diffusion WebUI Forge with shared model paths and home-dir I/O
set -euo pipefail

FORGE_DIR="/opt/stable-diffusion-webui-forge"
DATA_DIR="${HOME}/comfy-ui/forge"
MODEL_HOME="${HOME}/comfy-ui/models"

# ── Ensure output / input dirs exist ─────────────────────────────────────────
mkdir -p "${DATA_DIR}/outputs/txt2img-images" \
         "${DATA_DIR}/outputs/img2img-images" \
         "${DATA_DIR}/outputs/extras-images" \
         "${DATA_DIR}/outputs/txt2img-grids" \
         "${DATA_DIR}/outputs/img2img-grids" \
         "${DATA_DIR}/log/images"

# ── Write config.json (output paths, only if missing) ───────────────────────
CONF="${DATA_DIR}/config.json"
if [[ ! -f "$CONF" ]]; then
  cat > "$CONF" <<'JSON'
{
    "outdir_txt2img_samples": "outputs/txt2img-images",
    "outdir_img2img_samples": "outputs/img2img-images",
    "outdir_extras_samples": "outputs/extras-images",
    "outdir_txt2img_grids": "outputs/txt2img-grids",
    "outdir_img2img_grids": "outputs/img2img-grids",
    "outdir_save": "log/images"
}
JSON
  echo "[forge] Created default config at ${CONF}"
fi

# ── Map ComfyUI model dirs → Forge flags ─────────────────────────────────────
MODEL_ARGS=()
[[ -d "${MODEL_HOME}/checkpoints" ]]    && MODEL_ARGS+=(--ckpt-dir        "${MODEL_HOME}/checkpoints")
[[ -d "${MODEL_HOME}/vae" ]]            && MODEL_ARGS+=(--vae-dir         "${MODEL_HOME}/vae")
[[ -d "${MODEL_HOME}/loras" ]]          && MODEL_ARGS+=(--lora-dir        "${MODEL_HOME}/loras")
[[ -d "${MODEL_HOME}/embeddings" ]]     && MODEL_ARGS+=(--embeddings-dir  "${MODEL_HOME}/embeddings")
[[ -d "${MODEL_HOME}/controlnet" ]]     && MODEL_ARGS+=(--controlnet-dir  "${MODEL_HOME}/controlnet")
[[ -d "${MODEL_HOME}/text_encoders" ]]  && MODEL_ARGS+=(--text-encoder-dir "${MODEL_HOME}/text_encoders")
[[ -d "${MODEL_HOME}/clip_vision" ]]    && MODEL_ARGS+=(--clip-models-path "${MODEL_HOME}/clip_vision")
[[ -d "${MODEL_HOME}/hypernetworks" ]]  && MODEL_ARGS+=(--hypernetwork-dir "${MODEL_HOME}/hypernetworks")

cd "${FORGE_DIR}"
exec python launch.py \
    --skip-install \
    --listen \
    --port 7860 \
    --data-dir "${DATA_DIR}" \
    --no-download-sd-model \
    --vae-in-bf16 \
    --theme dark \
    "${MODEL_ARGS[@]}" \
    "$@"
