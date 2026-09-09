#!/usr/bin/env bash
# comfy-mcp-host.sh – Run the Comfy MCP server inside the toolbox, for an MCP
# client running on the host.
#
# comfy-mcp is a STDIO server: the client spawns it as a subprocess and speaks
# JSON-RPC over its stdin/stdout. ComfyUI, comfy-cli, the venv, the models and
# the live node registry all live in the container, so the server has to run
# there too. `toolbox run` proxies stdio, which is all this needs to be.
#
# The alternative -- comfy-mcp on the host with COMFYUI_URL pointed at the
# container -- was rejected: that variable remotes only the submit and job
# tools, so search_nodes and search_models would read the host's non-existent
# workspace and tell the agent this machine has no models.
#
# Register it with Claude Code:
#   claude mcp add comfy-mcp -- /path/to/repo/scripts/comfy-mcp-host.sh
#
# Or in a client's JSON config:
#   "comfy-mcp": { "command": "/path/to/repo/scripts/comfy-mcp-host.sh" }
#
# No `env` block is needed: comfy-cli and comfy-mcp both default to
# 127.0.0.1:8188, which is where this toolbox serves, and COMFY_BIN is
# unnecessary because the image's PATH already puts /opt/venv/bin first.
#
# Three details that are load-bearing:
#
#   * NOTHING may reach stdout before comfy-mcp takes over -- stdout is the
#     protocol transport, and one stray line desynchronises it. Hence the
#     redirection on the setup call.
#   * `sh -lc`, not `sh -c`: a LOGIN shell sources /etc/profile.d, where the
#     ROCm tuning (TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL,
#     TORCH_BLAS_PREFER_HIPBLASLT) and the launch-flag definition live.
#   * `exec` at both levels: the client stops the server by killing this
#     process, and a wrapper left in between swallows the signal.
set -uo pipefail

if ! command -v toolbox >/dev/null 2>&1; then
  echo "comfy-mcp-host: \`toolbox\` not found on PATH." >&2
  echo "  This script runs on the HOST and needs toolbox (podman) installed." >&2
  exit 1
fi

exec toolbox run --container "${COMFY_TOOLBOX:-amd-strix-halo-comfyui}" \
  -- sh -lc '/opt/setup_comfy_cli.sh >/dev/null 2>&1; exec comfy-mcp'
