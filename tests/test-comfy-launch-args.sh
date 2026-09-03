#!/usr/bin/env bash
# Unit tests for comfy_launch_args.sh, plus the port-agreement checks that stop
# ComfyUI's port from half-moving again. Static: no container, no build.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

SCRIPT="$PWD/scripts/comfy_launch_args.sh"
BANNER="$PWD/scripts/99-toolbox-banner.sh"

check "the launch args script exists" "0" "$([[ -f "$SCRIPT" ]]; echo $?)"

# --- the function's exact output --------------------------------------------
# Sourced in a child shell with a fixed HOME, so the expansion is deterministic
# and a stray leading space or a lost separator shows up as an exact mismatch.
ARGS="$(HOME=/home/test bash -c ". '$SCRIPT'; comfy_launch_args")"
check "emits exactly the expected flag string" \
  "--port 8188 --base-directory /home/test/comfy-ui --disable-mmap --gpu-only --disable-smart-memory --cache-none --bf16-vae --enable-manager" \
  "$ARGS"

# HOME must expand when the function is CALLED, not when the image is built --
# the file is baked in, the home directory belongs to whoever entered the
# toolbox.
ARGS2="$(HOME=/home/other bash -c ". '$SCRIPT'; comfy_launch_args")"
check "expands HOME at call time" "0" \
  "$(grep -qF '/home/other/comfy-ui' <<<"$ARGS2"; echo $?)"

# printf '%s', not echo: the string is embedded in `--launch-extras "..."`.
check "emits no trailing newline" "0" \
  "$(HOME=/home/test bash -c ". '$SCRIPT'; comfy_launch_args" | wc -l)"

# --enable-manager belongs in the shared definition, not appended at one call
# site, or the two launch paths disagree about whether Manager is on.
check "enables the built-in ComfyUI-Manager" "0" \
  "$(grep -qF -- '--enable-manager' <<<"$ARGS"; echo $?)"

# --- the alias defers to the function ---------------------------------------
check "start_comfy_ui calls comfy_launch_args" "0" \
  "$(grep -qE 'alias start_comfy_ui=.*\$\(comfy_launch_args\)' "$BANNER"; echo $?)"
check "start_comfy_ui hardcodes no launch flags of its own" "" \
  "$(grep -oE 'alias start_comfy_ui=.*' "$BANNER" | grep -oE '\-\-(port|base-directory|disable-mmap|gpu-only|disable-smart-memory|cache-none|bf16-vae|enable-manager)')"

# --- every consumer agrees on 8188 ------------------------------------------
check "the banner advertises port 8188" "0" \
  "$(grep -qF 'http://localhost:8188' "$BANNER"; echo $?)"
check "the SSH tip forwards 8188" "0" \
  "$(grep -qF 'ssh -L 8188:localhost:8188' "$BANNER"; echo $?)"
check "benchmark_workflows.py defaults to 8188" "0" \
  "$(grep -qF '"localhost:8188"' scripts/benchmark_workflows.py; echo $?)"
check "collect_perf_logs.py defaults to 8188" "0" \
  "$(grep -qE '^\s*server_port = 8188' scripts/collect_perf_logs.py; echo $?)"

# The whole point of moving to the ecosystem default is that comfy-cli and
# comfy-mcp need no address override. A surviving 8000 means one did not move.
check "no port 8000 survives anywhere in scripts/" "" \
  "$(grep -rnE --include='*.sh' --include='*.py' '(localhost|127\.0\.0\.1|--port |server_port = |-L )[:= ]?8000' scripts/)"
check "COMFY_LOCAL_URL is not reintroduced" "" \
  "$(grep -rn 'COMFY_LOCAL_URL' scripts/ Dockerfile)"

# --- the function must reach the image --------------------------------------
check "the launch args script is installed into profile.d" "0" \
  "$(grep -qF 'COPY --chmod=0644 scripts/comfy_launch_args.sh /etc/profile.d/02-comfy-launch-args.sh' Dockerfile; echo $?)"

# Numeric prefix matters: 99-toolbox-banner.sh defines the alias that calls the
# function, and profile.d is sourced in lexical order. Both names are read back
# out of the Dockerfile -- comparing two literals here would pass no matter what
# the Dockerfile actually installs.
args_dest="$(grep -oE '/etc/profile\.d/[^ ]*comfy-launch-args\.sh' Dockerfile | head -1)"
banner_dest="$(grep -oE '/etc/profile\.d/[^ ]*toolbox-banner\.sh' Dockerfile | head -1)"
check "the launch args file sorts before the banner in profile.d" "yes" \
  "$([[ -n "$args_dest" && -n "$banner_dest" && "${args_dest##*/}" < "${banner_dest##*/}" ]] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
