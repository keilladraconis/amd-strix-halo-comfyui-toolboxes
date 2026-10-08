#!/usr/bin/env bash
# setup_comfy_cli.sh – Point comfy-cli at this image's ComfyUI.
#
# comfy-cli keeps its config in the user's home and the launch flags embed
# $HOME, so this cannot run at build time. It runs at runtime instead, from two
# places, so that whichever door the user comes through leaves comfy-cli
# correct:
#
#   * /opt/start_comfy_ui.sh, beside install_workflows / install_custom_nodes
#   * scripts/comfy-mcp-host.sh, before exec'ing comfy-mcp
#
# Without it, the Comfy MCP's launch_comfyui tool starts ComfyUI with comfy-cli's
# defaults -- no --base-directory, no gfx1151 tuning -- and an agent gets a
# quietly broken instance.
#
# Re-running is harmless: `comfy set-default` overwrites its own config.
#
# KNOWN LIMITATION: comfy-cli has no equivalent of ComfyUI's --base-directory.
# The workspace registered here is /opt/ComfyUI, while the running server reads
# models, workflows and custom_nodes from $HOME/comfy-ui. Agent-side operations
# that resolve paths through comfy-cli rather than through ComfyUI's HTTP API
# (install_node, search_models, download_model) may therefore act on
# /opt/ComfyUI/... and appear to succeed while the server never sees the result.
# Unverified — it depends on which of the two comfy-mcp actually uses. See
# README section 4.3 and the post-build check in the design doc before relying
# on those tools.
#
# Usage:
#   setup_comfy_cli            Register the workspace and its launch flags
set -uo pipefail

WORKSPACE="${WORKSPACE:-/opt/ComfyUI}"
LAUNCH_SCRIPT="${LAUNCH_SCRIPT:-/opt/start_comfy_ui.sh}"
COMFY="${COMFY_BIN:-comfy}"

# The flags' single source of truth is start_comfy_ui.sh; --launch-extras is
# its introspection mode, which prints exactly what comfy-cli wants: one
# space-separated string (comfy-cli parses it with a plain split(" ")).
# Never duplicate the flags here.
if [[ ! -x "$LAUNCH_SCRIPT" ]]; then
  echo "✗ Cannot run $LAUNCH_SCRIPT — no launch flags to register" >&2
  exit 1
fi
launch_extras="$("$LAUNCH_SCRIPT" --launch-extras)"
if [[ $? -ne 0 || -z "$launch_extras" ]]; then
  echo "✗ $LAUNCH_SCRIPT --launch-extras produced nothing" >&2
  exit 1
fi

# --skip-prompt is a TOP-LEVEL option on comfy-cli's app callback, so it comes
# before the subcommand. Placed after it, comfy-cli does not recognise it and a
# fresh config raises an interactive telemetry consent prompt -- which on the
# MCP path would be written into the JSON-RPC stream.
if "$COMFY" --skip-prompt set-default "$WORKSPACE" \
     --launch-extras "$launch_extras" >/dev/null 2>&1; then
  echo "✅ comfy-cli pointed at $WORKSPACE" >&2
else
  echo "⚠ Could not register $WORKSPACE with comfy-cli — the Comfy MCP may" >&2
  echo "  launch ComfyUI without this toolbox's tuning flags." >&2
  exit 1
fi
