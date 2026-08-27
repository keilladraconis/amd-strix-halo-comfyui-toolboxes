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

# Forge's requirements_versions.txt carries pins that break on Python 3.13 and
# current rawhide. Each one we filter out is either already installed by an
# earlier step or must be reinstalled here — filtering without reinstalling
# silently removes a package Forge imports at runtime.
forge_filter=$(grep -oP "grep -ivE '\^\(\K[^)]+" Dockerfile)
for pkg in numpy scikit-image; do
  check "Forge deps filter excludes the incompatible $pkg pin" "0" \
    "$(grep -qE "(^|\|)${pkg}(\||$)" <<<"$forge_filter"; echo $?)"
done

# Forge imports skimage (modules/processing.py and 4 others), so filtering the
# pin obliges us to put a working scikit-image back.
check "a replacement scikit-image is installed after filtering its pin" "0" \
  "$(grep -qE 'pip install .*scikit-image==' Dockerfile; echo $?)"

# Each bundled workflow needs a README table row so §8.2's checklist holds.
check "MiniMax-H3 appears in the README workflow table" "0" \
  "$(grep -qF '| **MiniMax-H3** |' README.md; echo $?)"
check "MiniMax-H3 Turbo appears in the README workflow table" "0" \
  "$(grep -qF '| **MiniMax-H3 Turbo** |' README.md; echo $?)"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
