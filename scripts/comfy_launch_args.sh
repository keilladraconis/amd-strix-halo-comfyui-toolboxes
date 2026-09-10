#!/usr/bin/env bash
# Single source of truth for ComfyUI's launch flags.
#
# Two consumers need an identical list: the `start_comfy_ui` alias in
# 99-toolbox-banner.sh, and the --launch-extras that setup_comfy_cli.sh
# persists into comfy-cli -- which is what the Comfy MCP's launch_comfyui tool
# ends up running. When those two disagree, an agent silently gets an untuned
# ComfyUI on the wrong port, so the flags live here and nowhere else.
#
# Installed as /etc/profile.d/02-comfy-launch-args.sh: sourced by login shells
# before 99-toolbox-banner.sh, which defines the alias that calls it. Scripts
# that are not login shells must source this file themselves.
#
# $HOME is expanded when the function is CALLED, not when the image is built --
# the file is baked in, the home directory belongs to whoever entered the
# toolbox.
#
# Why these flags (see README §2.2):
#   --disable-mmap          mmap above 64GB is pathologically slow on gfx1151
#   --bf16-vae              prevents OOM during VAE decode
#   --cache-none            unified memory is GTT, not spare VRAM
#   --base-directory        models, workflows and custom_nodes live in $HOME
#   --enable-manager        ComfyUI-Manager is in core but opt-in for git installs
#
# NOT the only place these flags appear. benchmark_workflows.py and
# collect_perf_logs.py spawn their own ComfyUI and hardcode the same five
# tuning flags, deliberately diverging elsewhere (they add --output-directory
# and omit --enable-manager, which a benchmark run must not have). They cannot
# source a shell function, so tests/test-comfy-launch-args.sh asserts the
# tuning subset stays byte-identical across all three. Change a tuning flag
# here and that test tells you which other files to change.

# COMFY_OUTPUT_DIR (optional) sends renders somewhere other than
# $HOME/comfy-ui/output -- typically into the project that produced them, so
# takes never accumulate in a shared pile outside it. --output-directory
# overrides --base-directory for outputs ONLY; the model tree and inputs stay
# put. Repointing --base-directory instead would drag the models with it.
# Unset, the flag is absent and behaviour is unchanged.
comfy_launch_args() {
  printf '%s' "--port 8188 \
--base-directory $HOME/comfy-ui \
--disable-mmap \
--gpu-only \
--disable-smart-memory \
--cache-none \
--bf16-vae \
--enable-manager${COMFY_OUTPUT_DIR:+ --output-directory $COMFY_OUTPUT_DIR}"
}
