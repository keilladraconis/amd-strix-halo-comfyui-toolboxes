#!/usr/bin/env bash
# Unit tests for setup_comfy_cli.sh. No container: WORKSPACE, ARGS_FILE and
# COMFY_BIN are pointed at a sandbox with a stub `comfy` that records its argv.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/setup_comfy_cli.sh"

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# new_env -> a sandbox holding a stub `comfy` that appends its full argv to
# argv.log (one invocation per line) and exits 0, plus a fake launch script
# with the --launch-extras introspection mode.
new_env() {
  local env; env="$(mktemp -d)"
  cat > "$env/comfy" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$env/argv.log"
exit 0
STUB
  chmod +x "$env/comfy"
  cat > "$env/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--launch-extras" ]]; then
  printf '%s\n' "--port 8188 --base-directory $HOME/comfy-ui --enable-manager"
  exit 0
fi
LAUNCH
  chmod +x "$env/launch.sh"
  echo "$env"
}

run() { # env
  local env="$1"
  OUT="$(HOME=/home/test WORKSPACE=/opt/ComfyUI LAUNCH_SCRIPT="$env/launch.sh" \
         COMFY_BIN="$env/comfy" bash "$SCRIPT" 2>&1)"
  RC=$?
  ARGV="$(cat "$env/argv.log" 2>/dev/null)"
}

check "the setup script exists" "0" "$([[ -f "$SCRIPT" ]]; echo $?)"

# --- the happy path ----------------------------------------------------------
E="$(new_env)"
run "$E"
check "plain run exits 0" "0" "$RC"

# --skip-prompt is a top-level option on comfy-cli's app callback, so it must
# precede the subcommand. After the subcommand it is not recognised, and a fresh
# config then raises an interactive consent prompt.
check "passes --skip-prompt before the subcommand" "0" \
  "$(grep -qF -- '--skip-prompt set-default' <<<"$ARGV"; echo $?)"
check "registers /opt/ComfyUI as the workspace" "0" \
  "$(grep -qF -- 'set-default /opt/ComfyUI' <<<"$ARGV"; echo $?)"

# The flags must come from the shared function, not be duplicated here -- that
# duplication is exactly what this whole change removes.
check "forwards the shared launch args verbatim" "0" \
  "$(grep -qF -- '--launch-extras --port 8188 --base-directory /home/test/comfy-ui --enable-manager' <<<"$ARGV"; echo $?)"
# `-- ` guard rather than escaping the dashes: ugrep warns "stray \ before -"
# on the escaped form, and an ERE does not need `-` escaped anyway.
check "hardcodes no launch flags of its own" "" \
  "$(grep -oE -- '--(port|disable-mmap|bf16-vae|cache-none|gpu-only)' "$SCRIPT")"

# --- idempotency -------------------------------------------------------------
# Called from both start_comfy_ui and the MCP host wrapper, so it runs often.
run "$E"
check "a second run also exits 0" "0" "$RC"
check "the second run invokes comfy again rather than short-circuiting" "2" \
  "$(wc -l < "$E/argv.log")"

# --- failure paths -----------------------------------------------------------
E2="$(new_env)"
rm "$E2/launch.sh"
run "$E2"
check "a missing launch script is a hard failure" "1" "$RC"
check "the missing launch script is named in the error" "0" \
  "$(grep -q 'launch.sh' <<<"$OUT"; echo $?)"

E3="$(new_env)"
cat > "$E3/comfy" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$E3/comfy"
run "$E3"
check "a failing comfy-cli is reported as failure" "1" "$RC"

# --- wiring ------------------------------------------------------------------
check "the setup script is copied into the image" "0" \
  "$(grep -qF 'COPY --chmod=755 scripts/setup_comfy_cli.sh /opt/' Dockerfile; echo $?)"

BANNER="$PWD/scripts/99-toolbox-banner.sh"
LAUNCHER="$PWD/scripts/start_comfy_ui.sh"
# Whichever door the user comes through must leave comfy-cli correct: an agent
# that calls launch_comfyui before anyone has run start_comfy_ui would otherwise
# get an unregistered workspace.
check "the banner aliases start_comfy_ui to the launcher script" "0" \
  "$(grep -qE "alias start_comfy_ui='/opt/start_comfy_ui\.sh'" "$BANNER"; echo $?)"
check "start_comfy_ui registers comfy-cli before launching" "0" \
  "$(grep -qE '/opt/setup_comfy_cli\.sh' "$LAUNCHER"; echo $?)"
# A failed registration must not stop ComfyUI from starting, matching how a
# failed install_custom_nodes is handled.
check "a failed registration does not block the launch" "0" \
  "$(grep -qE 'setup_comfy_cli\.sh[^|]*\|\|' "$LAUNCHER"; echo $?)"
check "setup_comfy_cli is exposed as an alias" "0" \
  "$(grep -qE "^alias setup_comfy_cli=" "$BANNER"; echo $?)"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
