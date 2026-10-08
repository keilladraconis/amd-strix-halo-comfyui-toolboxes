#!/usr/bin/env bash
# start_comfy_ui.sh – The toolbox's ComfyUI entry point.
#
# Single source of truth for ComfyUI's launch flags. Two consumers need an
# identical list:
#
#   * the launch below, aliased as start_comfy_ui in 99-toolbox-banner.sh
#   * setup_comfy_cli.sh, which captures `--launch-extras` output and persists
#     it into comfy-cli -- which is what the Comfy MCP's launch_comfyui tool
#     ends up running. When those two disagree, an agent silently gets an
#     untuned ComfyUI on the wrong port.
#
# The old launcher was a sourceable profile.d function whose output the alias
# expanded unquoted: $(...) word-splits AND pathname-expands, so
# --enable-cors-header '*' globbed against the caller's cwd. Here the flags
# are a bash array, quoted on every path; nothing globs.
#
# Why these flags (see README §2.2):
#   --disable-mmap          mmap above 64GB is pathologically slow on gfx1151
#   --bf16-vae              prevents OOM during VAE decode
#   --cache-none            unified memory is GTT, not spare VRAM
#   --base-directory        models, workflows and custom_nodes live in $HOME
#   --enable-manager        ComfyUI-Manager is in core but opt-in for git installs
#   --enable-cors-header *  host-side tools (and SSH-tunnelled UIs) talk to the
#                           API from a different origin than the server's
#
# NOT the only place these flags appear. benchmark_workflows.py and
# collect_perf_logs.py spawn their own ComfyUI and hardcode the same tuning
# flags, deliberately diverging elsewhere (they add --output-directory and
# omit --enable-manager, which a benchmark run must not have). They cannot
# call this script, so tests/test-start-comfy-ui.sh asserts the tuning subset
# stays in sync. Change a tuning flag here and that test tells you which other
# files to change.
set -uo pipefail

# $HOME is expanded when this RUNS, not when the image is built -- the script
# is baked in, the home directory belongs to whoever entered the toolbox.
args=(--port 8188
      --base-directory "$HOME/comfy-ui"
      --disable-mmap
      --gpu-only
      --cache-none
      --bf16-vae
      --enable-manager
      --enable-cors-header '*')

# COMFY_OUTPUT_DIR (optional) sends renders somewhere other than
# $HOME/comfy-ui/output -- typically into the project that produced them, so
# takes never accumulate in a shared pile outside it. --output-directory
# overrides --base-directory for outputs ONLY; the model tree and inputs stay
# put. Repointing --base-directory instead would drag the models with it.
# Unset, the flag is absent and behaviour is unchanged.
if [[ -n ${COMFY_OUTPUT_DIR:-} ]]; then
  args+=(--output-directory "$COMFY_OUTPUT_DIR")
fi

# comfy-cli's view of the same flags: one space-separated string, which
# setup_comfy_cli.sh registers as comfy-cli's default_launch_extras. comfy-cli
# replays it with a plain split(" ") -- no shlex -- so no argument may contain
# a space, and quote characters would survive as literal text: the CORS
# wildcard goes out BARE here even though the array above must keep it quoted.
if [[ "${1:-}" == "--launch-extras" ]]; then
  printf '%s\n' "${args[*]}"
  exit 0
fi

# Install before launching so a fresh toolbox can never start with an empty
# custom_nodes or workflows directory -- both live in the ComfyUI base
# directory, not in the image; see /opt/install_custom_nodes.sh and
# /opt/install_workflows.sh. Workflows use --if-needed so saved edits are not
# overwritten on every launch. A failure (no network, say) is reported but
# must not stop ComfyUI from starting.
/opt/install_workflows.sh --if-needed
/opt/install_custom_nodes.sh || echo "⚠ Continuing without some custom nodes."
/opt/setup_comfy_cli.sh >/dev/null || echo "⚠ comfy-cli not registered — the Comfy MCP may launch ComfyUI untuned."

cd /opt/ComfyUI
exec python main.py "${args[@]}"
