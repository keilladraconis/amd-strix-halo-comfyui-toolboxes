FROM registry.fedoraproject.org/fedora:rawhide

# ── 1. Base packages ──────────────────────────────────────────────────────────
# (keep compilers/headers for Triton JIT at runtime)
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
    libdrm-devel python3.13 python3.13-devel git rsync libatomic bash ca-certificates curl \
    gcc gcc-c++ binutils make git ffmpeg-free vim dialog ncurses-term \
    && dnf clean all && rm -rf /var/cache/dnf/*

# ── 2. Python venv ────────────────────────────────────────────────────────────
RUN /usr/bin/python3.13 -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
ENV PIP_NO_CACHE_DIR=1
RUN printf 'source /opt/venv/bin/activate\n' > /etc/profile.d/venv.sh
RUN sed -i 's/include-system-site-packages =.*/include-system-site-packages = true/' /opt/venv/pyvenv.cfg
RUN python -m pip install --upgrade pip setuptools wheel

# ── 3. ROCm + PyTorch ─────────────────────────────────────────────────────────
# (TheRock; include torchaudio for resolver)
# Defaults to the latest nightly. Some nightlies are broken on gfx1151 (e.g.
# 2026-06-12 / rocm7.14.0a20260612 segfaults: rocminfo and torch.cuda init both
# dump core). To pin a known-good build: run ./find-good-nightly.sh, which
# writes nightly-overrides.conf; ./refresh-toolbox.sh --local then passes it
# here as --build-arg. Empty arg => unpinned latest.
ARG TORCH_VERSION=
ARG TORCHAUDIO_VERSION=
ARG TORCHVISION_VERSION=
RUN python -m pip install \
    --index-url https://rocm.nightlies.amd.com/v2-staging/gfx1151 \
    --pre "torch${TORCH_VERSION:+==$TORCH_VERSION}" \
          "torchaudio${TORCHAUDIO_VERSION:+==$TORCHAUDIO_VERSION}" \
          "torchvision${TORCHVISION_VERSION:+==$TORCHVISION_VERSION}" && \
    find /opt/venv -type f -name "*.so" -exec strip -s {} + 2>/dev/null || true

# ── 4. Core Python deps ───────────────────────────────────────────────────────
WORKDIR /opt
RUN python -m pip install gguf transformers==4.56.2

# ── Source refresh barrier ────────────────────────────────────────────────────
# Every `git clone --depth=1` below is cached on its command string, which never
# changes — so podman keeps whatever ComfyUI and the studios it first
# cloned, indefinitely. Bumping this arg invalidates this layer and, since
# layer caching is sequential, every clone after it.
#
#   ./refresh-toolbox.sh --local --refresh-sources
#
# Deliberately placed after the ROCm/PyTorch install (§3): refreshing sources
# re-runs the clones and their pip installs, but never the ~10GB torch step.
# Any clone added ABOVE this line silently stops being refreshable.
#
# The recorded date is when the clones actually last ran (it freezes with the
# cache), not when this build ran — that is what the banner reports.
ARG SOURCES_EPOCH=0
RUN printf 'refreshed=%s\nrequested_epoch=%s\n' \
      "$(date -u +%Y-%m-%d)" "$SOURCES_EPOCH" > /etc/toolbox-sources

# ── 5. External studios ───────────────────────────────────────────────────────
WORKDIR /opt
RUN git clone --depth=1 https://github.com/kyuz0/qwen-image-studio /opt/qwen-image-studio && \
    python -m pip install -r /opt/qwen-image-studio/requirements.txt

RUN git clone --depth=1 https://github.com/kyuz0/wan-video-studio /opt/wan-video-studio && \
    python -m pip install --prefer-binary \
    opencv-python-headless diffusers tokenizers accelerate \
    imageio[ffmpeg] easydict ftfy dashscope imageio-ffmpeg decord librosa

# ── 6. ComfyUI ────────────────────────────────────────────────────────────────
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI && \
    chmod -R a+rwX /opt/ComfyUI
WORKDIR /opt/ComfyUI
RUN python -m pip install -r requirements.txt && \
    python -m pip install --prefer-binary \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub>=1.5,<2.0" pyyaml websocket-client

# ── 7. ComfyUI custom nodes ───────────────────────────────────────────────────
# Not installed at build time. ComfyUI runs with `--base-directory $HOME/comfy-ui`
# and folder_paths.py resolves custom_nodes against that base, so anything under
# /opt/ComfyUI/custom_nodes is never scanned. scripts/install_custom_nodes.sh
# clones the packs into the user's base directory instead — run automatically by
# start_comfy_ui — and installs each pack's own requirements.txt into the venv,
# which is why the venv is made world-writable below.

# Constraints for runtime custom-node dependency installs. Node packs list
# their own requirements, and pip will happily satisfy them by replacing what
# the image carefully pinned — observed: transformers 4.56.2 -> 5.16.1 and
# pillow -> 12.3.0. The worst case is a pack listing `torch`, which would swap
# the ROCm nightly for a generic PyPI wheel and take GPU support with it.
#
# Recorded from what is actually installed, so it tracks the nightly in use.
# Only load-bearing packages are listed: a pack needing anything else resolves
# freely, and one that genuinely needs a newer pin now fails loudly at install
# time instead of silently breaking ComfyUI.
#
# huggingface_hub is on this list because the `hf` CLI it provides is what every
# get_*.sh downloader runs. ComfyUI-LTXVideo asks for huggingface_hub>=0.25.2,
# which unconstrained resolved to 1.29.0 and broke every model download.
RUN /opt/venv/bin/python - <<'PY' > /opt/venv/image-constraints.txt
import importlib.metadata as md
for pkg in ("torch", "torchvision", "torchaudio", "numpy",
            "transformers", "pillow", "huggingface_hub"):
    try:
        print(f"{pkg}=={md.version(pkg)}")
    except md.PackageNotFoundError:
        pass
PY

# Promote the constraints file from an install_custom_nodes.sh detail to a
# container-wide invariant. Enabling ComfyUI-Manager and shipping the Comfy MCP
# both open install paths this image does not curate: the Manager UI,
# comfy-mcp's install_node, and its update_comfyui(target="comfy") -- which
# re-runs ComfyUI's own requirements.txt, and that file lists a bare `torch`.
# Any of them would otherwise swap the ROCm nightly for a generic PyPI wheel and
# take gfx1151 support with it. A user typing `pip install -U torch` is covered
# by the same env var.
#
# pip's --constraint is an append option, so install_custom_nodes.sh's explicit
# `-c` still stacks its own kornia pin on top rather than replacing these.
# UV_CONSTRAINT covers the same ground for comfy-cli and comfyui-manager, which
# both use uv for some installs.
ENV PIP_CONSTRAINT=/opt/venv/image-constraints.txt
ENV UV_CONSTRAINT=/opt/venv/image-constraints.txt

# comfy-cli's telemetry clients (mixpanel, posthog) honour both of these, and
# comfy-cli already defaults to no tracking when non-interactive. Setting them
# explicitly also guarantees the first-run consent prompt can never appear: on
# the Comfy MCP path stdout is the JSON-RPC transport, and a rich prompt written
# there would corrupt the stream.
ENV DO_NOT_TRACK=1
ENV COMFY_NO_TELEMETRY=1

# ComfyUI-Manager is in core now, but a git-clone install has to opt in: core
# keeps it out of requirements.txt and ships it in manager_requirements.txt,
# enabled with --enable-manager (see scripts/comfy_launch_args.sh). Taken from
# core's own file so its version tracks core rather than a stale hand-written
# pin. This is deliberately below the constraints ENV above: comfyui_manager
# depends on unpinned transformers and huggingface-hub>0.20, which is precisely
# what the constraints file exists to hold still.
#
# Manager does not replace scripts/install_custom_nodes.sh. The six bundled
# packs are what the shipped workflows require, and Manager installs pack
# requirements with no constraints of its own -- it is here for packs the USER
# chooses to add.
RUN python -m pip install -r /opt/ComfyUI/manager_requirements.txt

# comfy-cli is the engine the Comfy MCP shells out to for everything; comfy-mcp
# is the stdio server itself, launched from the host by
# scripts/comfy-mcp-host.sh. Both resolve by bare name because ENV PATH already
# puts /opt/venv/bin first.
RUN python -m pip install "comfy-cli>=1.20" comfy-mcp

# Make the venv writable by the running (non-root) toolbox user, like every
# other install target above. Custom Nodes install node dependencies into
# the venv at runtime; if it isn't writable, pip falls back to
# `pip install --user`, which pip then rejects ("will not install to the user
# site because it will lack sys.path precedence ..."). Toolbox containers are
# per-user, so a world-writable venv is not a multi-tenant concern.
#
# Must stay LAST in this section: anything pip-installed after this chmod is
# root-owned, and the toolbox user then cannot install node dependencies.
RUN chmod -R a+rwX /opt/venv

# ── 8. Static profile.d scripts (rarely change) ───────────────────────────────
COPY --chmod=0644 scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh
COPY --chmod=0644 scripts/comfy_launch_args.sh /etc/profile.d/02-comfy-launch-args.sh
COPY --chmod=0644 scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
COPY --chmod=0644 scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh
# Fall back to a known terminfo entry when the host terminal's is unavailable
# (e.g. kitty/foot/alacritty entries are packaged outside ncurses-term)
RUN printf 'if ! infocmp "$TERM" >/dev/null 2>&1; then export TERM=xterm-256color; fi\n' \
      > /etc/profile.d/00-term-fallback.sh && chmod 0644 /etc/profile.d/00-term-fallback.sh

# ── 9. Input images (rarely change) ─────────────────────────────────────────
COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

# ── 10. Workflows (change when adding/updating models or workflows) ────────────
# Depth-1 JSONs → /opt/comfy-workflows/ (install_workflows.sh copies at runtime)
# API JSONs     → /opt/comfy-workflows/API/  (used by benchmark scripts)
COPY workflows/*.json /opt/comfy-workflows/
COPY workflows/API /opt/comfy-workflows/API

# ── 11. Helper scripts & model manager (change most often) ────────────────────
COPY --chmod=755 scripts/install_workflows.sh /opt/
COPY --chmod=755 scripts/install_custom_nodes.sh /opt/
COPY --chmod=755 scripts/get_wan22.sh /opt/
COPY --chmod=755 scripts/get_qwen_image.sh /opt/
COPY --chmod=755 scripts/get_hunyuan15.sh /opt/
COPY --chmod=755 scripts/get_ltx2.sh /opt/
COPY --chmod=755 scripts/get_ltx25.sh /opt/
COPY --chmod=755 scripts/get_minimax_h3.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/

CMD ["/bin/bash"]
