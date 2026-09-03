#!/usr/bin/env bash
# Unit tests for comfy-mcp-host.sh. No container: a stub `toolbox` on PATH
# records its argv, so the wrapper can be run for real without podman.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/comfy-mcp-host.sh"

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# new_env -> a sandbox with a stub `toolbox` that writes its argv to a log on
# STDERR's side (a file), and prints a fixed marker to stdout so the test can
# assert nothing else got there first.
new_env() {
  local env; env="$(mktemp -d)"
  cat > "$env/toolbox" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$env/argv.log"
printf 'MCP-STDOUT-MARKER\n'
exit 0
STUB
  chmod +x "$env/toolbox"
  echo "$env"
}

run() { # env [VAR=VAL ...]
  local env="$1"; shift
  STDOUT="$(env PATH="$env:$PATH" "$@" bash "$SCRIPT" 2>/dev/null)"
  RC=$?
  ARGV="$(cat "$env/argv.log" 2>/dev/null)"
}

check "the host wrapper exists" "0" "$([[ -f "$SCRIPT" ]]; echo $?)"
check "the host wrapper is executable" "0" "$([[ -x "$SCRIPT" ]]; echo $?)"

# --- stdout discipline -------------------------------------------------------
# stdout IS the MCP transport. A banner, a progress line, or setup output
# written before comfy-mcp takes over desynchronises the JSON-RPC stream, and
# the client reports an opaque handshake failure.
E="$(new_env)"
run "$E"
check "the wrapper writes nothing to stdout before exec" "MCP-STDOUT-MARKER" "$STDOUT"
check "the setup call's output is redirected away from stdout" "0" \
  "$(grep -qF 'setup_comfy_cli.sh >/dev/null 2>&1' "$SCRIPT"; echo $?)"

# --- what it actually runs ---------------------------------------------------
check "runs against the default container" "0" \
  "$(grep -qF -- '--container amd-strix-halo-comfyui' <<<"$ARGV"; echo $?)"
check "registers comfy-cli before starting the server" "0" \
  "$(grep -qF -- '/opt/setup_comfy_cli.sh' <<<"$ARGV"; echo $?)"
check "starts comfy-mcp" "0" \
  "$(grep -qF -- 'comfy-mcp' <<<"$ARGV"; echo $?)"

# A login shell is what sources /etc/profile.d -- where the ROCm tuning
# (TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL, TORCH_BLAS_PREFER_HIPBLASLT) and the
# launch-flag definition live. `sh -c` would silently drop all of it.
check "uses a login shell so /etc/profile.d is sourced" "0" \
  "$(grep -qE 'sh -lc' <<<"$ARGV"; echo $?)"

# exec, not a trailing command: the client kills this process to stop the
# server, and a wrapper left in between swallows the signal.
check "execs rather than leaving a wrapper process in between" "0" \
  "$(grep -qE '^exec toolbox run' "$SCRIPT"; echo $?)"
check "the inner shell execs comfy-mcp too" "0" \
  "$(grep -qF 'exec comfy-mcp' "$SCRIPT"; echo $?)"

# --- container name override -------------------------------------------------
# A user who renamed their toolbox must not have to edit a tracked file.
E2="$(new_env)"
run "$E2" COMFY_TOOLBOX=my-box
check "COMFY_TOOLBOX overrides the container name" "0" \
  "$(grep -qF -- '--container my-box' <<<"$ARGV"; echo $?)"

# --- it must NOT be in the image ---------------------------------------------
# It runs on the host, where `toolbox` exists. Copying it inside would offer a
# path that recurses into the container it is already in.
# Scoped to COPY/ADD instructions: a section-7 comment legitimately names this
# script as what launches comfy-mcp, and an unscoped grep would forbid that.
check "the host wrapper is not copied into the image" "" \
  "$(grep -nE '^\s*(COPY|ADD)\b.*comfy-mcp-host' Dockerfile)"

# --- no address override -----------------------------------------------------
# The move to port 8188 exists precisely so no env block is needed here.
# Scoped to non-comment lines: the header legitimately explains WHY no
# COMFY_BIN or COMFYUI_URL is needed, and an unscoped grep would forbid
# saying so.
check "needs no address or binary overrides" "" \
  "$(grep -vE '^\s*#' "$SCRIPT" | grep -nE 'COMFY_BIN|COMFY_LOCAL_URL|COMFYUI_URL')"

echo

# --- the banner must not speak on the MCP path ------------------------------
# `sh -lc` sources /etc/profile.d/99-toolbox-banner.sh, and stdout is the
# JSON-RPC transport. Source it non-interactively and assert silence, rather
# than trusting the base image's profile.d redirection.
BANNER_OUT="$(bash -c '. "$PWD/scripts/99-toolbox-banner.sh"' 2>/dev/null)"
check "the banner writes nothing to stdout in a non-interactive shell" "" "$BANNER_OUT"
check "the banner guards on interactivity rather than relying on /etc/profile" "0" \
  "$(grep -qE '^\s*\*i\*\)' scripts/99-toolbox-banner.sh; echo $?)"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
