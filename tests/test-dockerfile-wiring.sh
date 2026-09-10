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

# Removing the baked packs also removed the pip install of their requirements.
# gguf came in that way; without it every GGUF workflow dies at import.
check "gguf is installed independently of the custom node packs" "0" \
  "$(grep -qE '^RUN python -m pip install gguf' Dockerfile; echo $?)"

# Baking packs into the image is what broke them: ComfyUI would not scan there.
check "no custom node packs are cloned into the image" "" \
  "$(grep -nE '^RUN git clone.*ComfyUI[-_]' Dockerfile)"

# The installer is useless unless it reaches the image.
check "the custom node installer is copied into the image" "0" \
  "$(grep -qF 'COPY --chmod=755 scripts/install_custom_nodes.sh /opt/' Dockerfile; echo $?)"

# A fresh toolbox must not be able to start ComfyUI with an empty custom_nodes
# or workflows directory -- forgetting either is the failure this guards.
check "start_comfy_ui installs custom nodes before launching" "0" \
  "$(grep -qE "alias start_comfy_ui=.*install_custom_nodes\.sh" scripts/99-toolbox-banner.sh; echo $?)"
check "start_comfy_ui installs workflows before launching" "0" \
  "$(grep -qE "alias start_comfy_ui=.*install_workflows\.sh" scripts/99-toolbox-banner.sh; echo $?)"
# Without --if-needed it would overwrite edits saved to a bundled workflow on
# every launch, since ComfyUI saves back to the same filename.
check "start_comfy_ui installs workflows with --if-needed" "0" \
  "$(grep -qE "alias start_comfy_ui=.*install_workflows\.sh --if-needed" scripts/99-toolbox-banner.sh; echo $?)"

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

# Forge was removed: its 2024-era pins (peft 0.13.2, kornia 0.6.7, transformers
# 4.46.1) shared one venv with ComfyUI and held the resolver below what current
# node packs need. Nothing should reintroduce it or its launcher.
check "Forge is not reintroduced into the image" "" \
  "$(grep -inE 'forge' Dockerfile)"
check "the Forge launcher is gone" "1" \
  "$([[ -e scripts/start_forge.sh ]]; echo $?)"
check "no Forge alias survives in the banner" "" \
  "$(grep -inE 'start_forge|7860' scripts/99-toolbox-banner.sh)"

# The constraints file is what stops a node pack's requirements from replacing
# the image's pinned torch/transformers/numpy/pillow.
check "the build records an image constraints file" "0" \
  "$(grep -qF 'image-constraints.txt' Dockerfile; echo $?)"

# Every package the toolbox's own scripts depend on at runtime must be
# constrained, or a node pack's requirements can replace it. huggingface_hub
# provides the `hf` CLI that all six downloaders shell out to; when it was left
# off this list, ComfyUI-LTXVideo pulled it from 0.36.2 to 1.29.0 and every
# model download failed on incompatible flags.
constrained=$(sed -n '/image-constraints.txt/,/^PY$/p' Dockerfile)
for pkg in torch numpy transformers pillow huggingface_hub; do
  check "the constraints file pins $pkg" "0" \
    "$(grep -qF "\"$pkg\"" <<<"$constrained"; echo $?)"
done

# The flag combination that broke downloads: huggingface_hub >= 1.0 rejects
# --cache-dir alongside --local-dir, and --cache-dir was doing nothing anyway.
check "no downloader passes --cache-dir alongside --local-dir" "" \
  "$(grep -ln 'cache-dir' scripts/get_*.sh)"

# The hub must be free to reach 1.x: transformers and diffusers in this image
# both declare huggingface-hub>=1.x, so pinning below 1.0 ships a dependency
# set they consider unsatisfiable.
check "the huggingface_hub install is not capped below 1.0" "" \
  "$(grep -n 'huggingface_hub[^ ]*<1\.0' Dockerfile)"

# hf_transfer is a deprecated no-op on hub 1.x ("'hf_transfer' is not used
# anymore"); Xet's high-performance mode is the replacement the hub names.
check "no downloader sets the deprecated hf_transfer variable" "" \
  "$(grep -ln 'HF_HUB_ENABLE_HF_TRANSFER' scripts/get_*.sh)"
check "downloaders opt into the Xet fast path instead" "" \
  "$(grep -Ln 'HF_XET_HIGH_PERFORMANCE' scripts/get_hunyuan15.sh scripts/get_wan22.sh)"
# The fork used to expose these as a dialog checklist in model_manager.py.
# Upstream has since removed that download-options step entirely, so asserting
# the toggle here would mean re-adding a feature upstream deleted -- divergence
# for no benefit. The downloaders set the variable directly instead.

# Each bundled workflow needs a README table row so §8.2's checklist holds.
check "MiniMax-H3 appears in the README workflow table" "0" \
  "$(grep -qF '| **MiniMax-H3** |' README.md; echo $?)"
check "MiniMax-H3 Turbo appears in the README workflow table" "0" \
  "$(grep -qF '| **MiniMax-H3 Turbo** |' README.md; echo $?)"

# --- comfy-cli / Comfy MCP / built-in ComfyUI-Manager ------------------------
# Ordering is the whole safety argument. comfyui_manager depends on unpinned
# transformers and huggingface-hub>0.20 -- the two packages the constraints file
# exists to hold still -- so it must install AFTER the file is written and
# PIP_CONSTRAINT is set, not alongside ComfyUI's own requirements in section 6.
constraints_line=$(grep -n 'image-constraints.txt$' Dockerfile | head -1 | cut -d: -f1)
pipenv_line=$(grep -n '^ENV PIP_CONSTRAINT' Dockerfile | head -1 | cut -d: -f1)
# Anchored to the RUN lines, not to any mention: the comments in this section
# name comfy-cli and manager_requirements.txt above the instructions that
# install them, and a bare grep would measure the comment's position instead.
manager_line=$(grep -nE '^RUN .*pip install -r /opt/ComfyUI/manager_requirements.txt' Dockerfile | head -1 | cut -d: -f1)
cli_line=$(grep -nE '^RUN .*pip install .*comfy-cli' Dockerfile | head -1 | cut -d: -f1)
chmod_line=$(grep -n '^RUN chmod -R a+rwX /opt/venv' Dockerfile | tail -1 | cut -d: -f1)

check "PIP_CONSTRAINT is set after the constraints file is generated" "yes" \
  "$([[ -n "$constraints_line" && -n "$pipenv_line" && "$constraints_line" -lt "$pipenv_line" ]] && echo yes || echo no)"
check "ComfyUI-Manager installs after PIP_CONSTRAINT is set" "yes" \
  "$([[ -n "$pipenv_line" && -n "$manager_line" && "$pipenv_line" -lt "$manager_line" ]] && echo yes || echo no)"
check "comfy-cli installs after PIP_CONSTRAINT is set" "yes" \
  "$([[ -n "$pipenv_line" && -n "$cli_line" && "$pipenv_line" -lt "$cli_line" ]] && echo yes || echo no)"

# Anything pip-installed after the chmod is root-owned and unwritable by the
# non-root toolbox user, which is what breaks runtime node dependency installs.
check "the venv chmod is the last thing in the section" "yes" \
  "$([[ -n "$chmod_line" && -n "$manager_line" && -n "$cli_line" && "$chmod_line" -gt "$manager_line" && "$chmod_line" -gt "$cli_line" ]] && echo yes || echo no)"
check "only one venv chmod survives" "1" \
  "$(grep -c '^RUN chmod -R a+rwX /opt/venv' Dockerfile)"

# Manager's version must track core, so it comes from core's own requirements
# file rather than a hand-written pin that would silently go stale.
check "ComfyUI-Manager is installed from core's manager_requirements.txt" "0" \
  "$(grep -qF 'pip install -r /opt/ComfyUI/manager_requirements.txt' Dockerfile; echo $?)"
check "comfyui_manager is not hand-pinned" "" \
  "$(grep -n 'comfyui[-_]manager==' Dockerfile)"

# The MCP is a thin wrapper over comfy-cli; both must be present or the host
# wrapper starts a server that cannot do anything.
check "comfy-cli is installed with a version floor" "0" \
  "$(grep -qE 'pip install .*"?comfy-cli>=1\.20' Dockerfile; echo $?)"
check "comfy-mcp is installed" "0" \
  "$(grep -qE 'pip install .*comfy-mcp' Dockerfile; echo $?)"

# The constraint is what makes enabling Manager safe: it closes the Manager UI,
# the MCP's install_node, and update_comfyui(target="comfy") -- which re-runs
# ComfyUI's requirements.txt, and that file lists a bare `torch`.
check "PIP_CONSTRAINT points at the image constraints file" "0" \
  "$(grep -qF 'ENV PIP_CONSTRAINT=/opt/venv/image-constraints.txt' Dockerfile; echo $?)"
check "UV_CONSTRAINT points at the image constraints file" "0" \
  "$(grep -qF 'ENV UV_CONSTRAINT=/opt/venv/image-constraints.txt' Dockerfile; echo $?)"

# stdout is the MCP's JSON-RPC transport. comfy-cli's first-run consent prompt
# written there would corrupt the stream.
check "comfy-cli telemetry is disabled in the image" "0" \
  "$(grep -qF 'ENV DO_NOT_TRACK=1' Dockerfile; echo $?)"
check "the Comfy-specific telemetry opt-out is set too" "0" \
  "$(grep -qF 'ENV COMFY_NO_TELEMETRY=1' Dockerfile; echo $?)"

# The constraints file stopped being a local detail of install_custom_nodes.sh,
# so its "file is missing" warning must describe the image-wide consequence.
check "install_custom_nodes.sh says the constraints file is image-wide" "0" \
  "$(grep -qF 'PIP_CONSTRAINT' scripts/install_custom_nodes.sh; echo $?)"
# Forge was removed in 4d39352; nothing in the image pins gradio any more.
check "the installer's constraints comment does not still claim gradio" "" \
  "$(grep -n 'gradio' scripts/install_custom_nodes.sh)"

# --- agent access docs -------------------------------------------------------
check "the README documents agent access" "0" \
  "$(grep -qF '## 4. Agent Access (Comfy MCP)' README.md; echo $?)"
# opencode has no `mcp add` CLI, so registration is a config-file edit. Its
# schema differs from every other client's in three ways that are easy to get
# wrong when copying their docs: the key is `mcp` (not `mcpServers`), `command`
# is an ARRAY, and the env key is `environment` (not `env`).
check "the README names opencode's config file" "0" \
  "$(grep -qF 'opencode.json' README.md; echo $?)"
check "the README shows opencode's array command form" "0" \
  "$(grep -qE '"command": \[' README.md; echo $?)"
check "the README uses opencode's environment key, not env" "0" \
  "$(grep -qF '"environment": { "COMFY_TOOLBOX"' README.md; echo $?)"
# The switch to opencode must be complete: a half-replaced section would leave
# a reader following instructions for a client this repo no longer documents.
# `"mcpServers"` is matched WITH quotes so it only fires inside a JSON block:
# the prose above legitimately names the key to warn readers off it, and an
# unscoped pattern would forbid saying so.
check "no stale Claude/Cursor MCP instructions survive" "" \
  "$(grep -nE 'claude mcp add|"mcpServers"|cursor/mcp\.json' README.md)"
check "the README names the host wrapper" "0" \
  "$(grep -qF 'scripts/comfy-mcp-host.sh' README.md; echo $?)"
# The port move is the only user-visible break in this change; it must not be a
# silent edit that people discover through a dead SSH tunnel.
check "the README calls out the port change" "0" \
  "$(grep -qE '8000.*8188|8188.*8000' README.md; echo $?)"
# Manager and install_node execute third-party code. Constrained now, but not
# curated and not validated on gfx1151.
check "the README warns that Manager installs uncurated code" "0" \
  "$(grep -qiE 'manager.*(third-party|not validated|uncurated)' README.md; echo $?)"
# The port callout necessarily quotes the OLD tunnel, so this asserts the new
# port is documented rather than that 8000 is absent.
check "the README documents the new port" "0" \
  "$(grep -qF 'localhost:8188' README.md; echo $?)"

# Renumbering five sections by hand is how a table of contents silently drifts
# out of sync with its headings. Check every top-level numbered heading has a
# matching TOC entry with the same number.
toc_mismatch=""
while IFS= read -r heading; do
  title="${heading#\#\# }"
  # `--` is required: the pattern starts with a dash, which grep would
  # otherwise parse as an option (ugrep rejects it outright).
  grep -qF -- "- [$title](#" README.md || toc_mismatch+="$title "
done < <(grep -E '^## [0-9]+\. ' README.md)
check "every numbered section appears in the table of contents" "" "$toc_mismatch"

# --- banner ------------------------------------------------------------------
check "the banner advertises the Comfy MCP" "0" \
  "$(grep -qF 'Comfy MCP' scripts/99-toolbox-banner.sh; echo $?)"
check "the banner advertises the built-in node manager" "0" \
  "$(grep -qF 'Node Manager' scripts/99-toolbox-banner.sh; echo $?)"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
