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

# The Turbo workflows are unusable without their custom node. Packs are no
# longer baked into the image -- they are cloned into the ComfyUI base directory
# at runtime, because --base-directory means /opt/ComfyUI/custom_nodes is never
# scanned. The manifest is the single source of truth.
check "the MiniMax-H3 Turbo custom node is in the installer manifest" "0" \
  "$(grep -qF 'github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo' scripts/install_custom_nodes.sh; echo $?)"

# Baking packs into the image is what broke them: ComfyUI would not scan there.
check "no custom node packs are cloned into the image" "" \
  "$(grep -nE '^RUN git clone.*ComfyUI[-_]' Dockerfile)"

# The installer is useless unless it reaches the image.
check "the custom node installer is copied into the image" "0" \
  "$(grep -qF 'COPY --chmod=755 scripts/install_custom_nodes.sh /opt/' Dockerfile; echo $?)"

# A fresh toolbox must not be able to start ComfyUI with an empty custom_nodes.
check "start_comfy_ui installs custom nodes before launching" "0" \
  "$(grep -qE "alias start_comfy_ui=.*install_custom_nodes\.sh" scripts/99-toolbox-banner.sh; echo $?)"

# Every workflow the model manager can offer must reach the image.
check "workflows/*.json are copied into /opt/comfy-workflows" "0" \
  "$(grep -qF 'COPY workflows/*.json /opt/comfy-workflows/' Dockerfile; echo $?)"

# The source refresh barrier only refreshes clones BELOW it, and layer caching
# is sequential — a clone added above it silently stops being refreshable.
barrier=$(grep -n '^ARG SOURCES_EPOCH' Dockerfile | head -1 | cut -d: -f1)
first_clone=$(grep -nE '^RUN .*git clone' Dockerfile | head -1 | cut -d: -f1)
check "the source refresh barrier precedes every git clone" "yes" \
  "$([[ -n "$barrier" && -n "$first_clone" && "$barrier" -lt "$first_clone" ]] && echo yes || echo no)"

# An ARG only busts the cache if something actually references it.
check "the refresh barrier references SOURCES_EPOCH so it busts the cache" "0" \
  "$(grep -qF '$SOURCES_EPOCH' Dockerfile; echo $?)"

# The flag is useless unless refresh-toolbox.sh plumbs it into the build.
check "refresh-toolbox.sh passes SOURCES_EPOCH as a build arg" "0" \
  "$(grep -qF 'SOURCES_EPOCH=$(date +%s)' refresh-toolbox.sh; echo $?)"
check "refresh-toolbox.sh accepts --refresh-sources in getopt" "0" \
  "$(grep -qE 'getopt .*--long .*refresh-sources' refresh-toolbox.sh; echo $?)"

# Forge's requirements_versions.txt carries pins that break on Python 3.13 and
# current rawhide. Each one we filter out is either already installed by an
# earlier step or must be reinstalled here — filtering without reinstalling
# silently removes a package Forge imports at runtime.
forge_filter=$(grep -oP "grep -ivE '\^\(\K[^)]+" Dockerfile)
for pkg in numpy scikit-image transformers; do
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
