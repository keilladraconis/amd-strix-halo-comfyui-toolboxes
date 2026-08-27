#!/usr/bin/env bash
# Checks that the Dockerfile ships everything the repo expects it to.
# Static analysis only: no podman, no build.
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

# Every downloader in scripts/ must be COPYed into /opt.
missing=()
for f in scripts/get_*.sh; do
  grep -qF "COPY --chmod=755 $f /opt/" Dockerfile || missing+=("$f")
done
check "every scripts/get_*.sh is copied into the image" "" "${missing[*]-}"

# The Turbo workflows are unusable without their custom node.
check "the MiniMax-H3 Turbo custom node is cloned" "0" \
  "$(grep -qF 'github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo' Dockerfile; echo $?)"

# Custom nodes must be world-writable: the venv installs node deps at runtime.
check "the MiniMax-H3 Turbo clone is chmod'ed like its neighbours" "0" \
  "$(grep -qF 'chmod -R a+rwX ComfyUI-MiniMax-H3-Turbo' Dockerfile; echo $?)"

# Every workflow the model manager can offer must reach the image.
check "workflows/*.json are copied into /opt/comfy-workflows" "0" \
  "$(grep -qF 'COPY workflows/*.json /opt/comfy-workflows/' Dockerfile; echo $?)"

# Each bundled workflow needs a README table row so §8.2's checklist holds.
check "MiniMax-H3 appears in the README workflow table" "0" \
  "$(grep -qF '| **MiniMax-H3** |' README.md; echo $?)"
check "MiniMax-H3 Turbo appears in the README workflow table" "0" \
  "$(grep -qF '| **MiniMax-H3 Turbo** |' README.md; echo $?)"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
