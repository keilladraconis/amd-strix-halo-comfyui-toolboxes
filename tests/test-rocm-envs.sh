#!/usr/bin/env bash
# Static test: the ROCm env profile script must set MIOpen's find mode to FAST.
#
# MIOpen ships no tuning data for gfx1151 -- share/miopen/db in the
# rocm-sdk-device-gfx1151 wheel covers gfx908/90a/942/950 only, verified on both
# ROCm 7.14.0a20260608 and 10.1.0a20260822. With no system find-db the default
# exhaustive search benchmarks every candidate solver against the real tensor on
# each unseen conv config, including ConvDirectNaiveConv. On MiniMax-H3's 3D
# convs that solver measures ~5.6 s where the GEMM solver it then picks takes
# 0.55 ms, so a first run stalls for tens of minutes before the sampler starts.
#
# No container, no build: this only reads the checked-in files.
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

S="$PWD/scripts/01-rocm-envs.sh"

check "the rocm env script exists" "0" "$([[ -f "$S" ]]; echo $?)"

check "MIOPEN_FIND_MODE is exported as 2 (FAST)" "1" \
  "$(grep -cE '^export MIOPEN_FIND_MODE=2$' "$S" || true)"

# The fix only works if login shells source it: ComfyUI is started through
# `sh -lc`, so profile.d is the delivery mechanism.
check "the Dockerfile installs it into profile.d" "1" \
  "$(grep -cE '^COPY .*scripts/01-rocm-envs\.sh /etc/profile\.d/' Dockerfile || true)"

# A bare mode number with no explanation invites someone to "clean it up" later,
# and the symptom it prevents (a silent 55-minute stall) is not self-evident.
check "the export explains why MIOpen needs it" "0" \
  "$([[ $(grep -ci 'miopen' "$S") -ge 2 ]]; echo $?)"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
