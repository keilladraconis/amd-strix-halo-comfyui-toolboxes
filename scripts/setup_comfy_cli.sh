#!/usr/bin/env bash
# setup_comfy_cli.sh – Point comfy-cli at this image's ComfyUI.
#
# comfy-cli keeps its config in the user's home and the launch flags embed
# $HOME, so this cannot run at build time. It runs at runtime instead, from two
# places, so that whichever door the user comes through leaves comfy-cli
# correct:
#
#   * the start_comfy_ui alias, beside install_workflows / install_custom_nodes
#   * scripts/comfy-mcp-host.sh, before exec'ing comfy-mcp
#
# Without it, the Comfy MCP's launch_comfyui tool starts ComfyUI with comfy-cli's
# defaults -- no --base-directory, no gfx1151 tuning -- and an agent gets a
# quietly broken instance.
#
# Re-running is harmless: `comfy set-default` overwrites its own config.
#
# Usage:
#   setup_comfy_cli            Register the workspace and its launch flags
set -uo pipefail

WORKSPACE="${WORKSPACE:-/opt/ComfyUI}"
ARGS_FILE="${ARGS_FILE:-/etc/profile.d/02-comfy-launch-args.sh}"
COMFY="${COMFY_BIN:-comfy}"

if [[ ! -r "$ARGS_FILE" ]]; then
  echo "✗ Cannot read $ARGS_FILE — no launch flags to register" >&2
  exit 1
fi
# shellcheck source=comfy_launch_args.sh
. "$ARGS_FILE"

# --skip-prompt is a TOP-LEVEL option on comfy-cli's app callback, so it comes
# before the subcommand. Placed after it, comfy-cli does not recognise it and a
# fresh config raises an interactive telemetry consent prompt -- which on the
# MCP path would be written into the JSON-RPC stream.
if "$COMFY" --skip-prompt set-default "$WORKSPACE" \
     --launch-extras "$(comfy_launch_args)" >/dev/null 2>&1; then
  echo "✅ comfy-cli pointed at $WORKSPACE"
else
  echo "⚠ Could not register $WORKSPACE with comfy-cli — the Comfy MCP may" >&2
  echo "  launch ComfyUI without this toolbox's tuning flags." >&2
  exit 1
fi
