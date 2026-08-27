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
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]>=0.34,<1.0" pyyaml websocket-client

# ── 7. ComfyUI custom nodes ───────────────────────────────────────────────────
WORKDIR /opt/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials && \
    chmod -R a+rwX ComfyUI_essentials
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-AMDGPUMonitor && \
    chmod -R a+rwX ComfyUI-AMDGPUMonitor
RUN git clone --depth=1 https://github.com/city96/ComfyUI-GGUF && \
    chmod -R a+rwX ComfyUI-GGUF
# LTX-2.3 nodes: GemmaAPITextEncode, LTXVImgToVideoConditionOnly
RUN git clone --depth=1 https://github.com/Lightricks/ComfyUI-LTXVideo && \
    chmod -R a+rwX ComfyUI-LTXVideo && \
    python -m pip install --prefer-binary einops ninja timm
# LTX-2.3 nodes: CM_FloatToInt
RUN git clone --depth=1 https://github.com/evanspearman/ComfyMath && \
    chmod -R a+rwX ComfyMath
# MiniMax-H3 Turbo nodes: MiniMaxH3TurboLoRA, MiniMaxH3TurboSampler
RUN git clone --depth=1 https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo && \
    chmod -R a+rwX ComfyUI-MiniMax-H3-Turbo

# ── 8. Stable Diffusion WebUI Forge ───────────────────────────────────────────
RUN git clone --depth=1 https://github.com/lllyasviel/stable-diffusion-webui-forge /opt/stable-diffusion-webui-forge && \
    chmod -R a+rwX /opt/stable-diffusion-webui-forge
WORKDIR /opt/stable-diffusion-webui-forge
# Install Forge deps for Python 3.13:
#  - Filter out Pillow (9.5.0 can't build on 3.13; already installed from ComfyUI)
#  - Filter out torch/torchvision/torchaudio (already from ROCm nightlies)
#  - Filter out blendmodes (pins Pillow<10 transitively); install it --no-deps
#    since its only runtime needs are Pillow + numpy + aenum, all already present
#  - Filter out huggingface-hub (pins ==0.26.2, which predates the `hf` CLI the
#    get_*.sh model scripts need; already installed >=0.34 from ComfyUI step)
#  - Filter out numpy (pins ==1.26.2, which has no cp313 wheel and silently
#    downgraded the numpy 2.x that torch and ComfyUI are built against, for the
#    whole shared venv)
#  - Filter out scikit-image (pins ==0.21.0, no cp313 wheel). Building it from
#    source fails on current rawhide: its meson build compiles pythran-generated
#    C++ with -std=c++14, and GCC 16's libstdc++ no longer exposes the C++17
#    std::is_integral_v that pythran's headers use. Reinstalled from a wheel
#    below — Forge imports skimage in modules/processing.py and 4 other files.
#    Pinned: unpinned resolves to 0.26.0, which drags numpy to 2.5.2 and breaks
#    numba (requires numpy<2.5).
RUN grep -ivE '^(pillow|torch|torchvision|torchaudio|blendmodes|huggingface-hub|numpy|scikit-image)\b' requirements_versions.txt \
      > /tmp/forge-reqs.txt && \
    python -m pip install --prefer-binary -r /tmp/forge-reqs.txt && \
    python -m pip install --no-deps blendmodes==2022 && \
    python -m pip install --prefer-binary gradio-rangeslider && \
    python -m pip install --prefer-binary "scikit-image==0.25.2" && \
    rm /tmp/forge-reqs.txt

# Make the venv writable by the running (non-root) toolbox user, like every
# other install target above. Custom Nodes install node dependencies into
# the venv at runtime; if it isn't writable, pip falls back to
# `pip install --user`, which pip then rejects ("will not install to the user
# site because it will lack sys.path precedence ..."). Toolbox containers are
# per-user, so a world-writable venv is not a multi-tenant concern.
RUN chmod -R a+rwX /opt/venv

# ── 9. Static profile.d scripts (rarely change) ───────────────────────────────
COPY --chmod=0644 scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh
COPY --chmod=0644 scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
COPY --chmod=0644 scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh
# Fall back to a known terminfo entry when the host terminal's is unavailable
# (e.g. kitty/foot/alacritty entries are packaged outside ncurses-term)
RUN printf 'if ! infocmp "$TERM" >/dev/null 2>&1; then export TERM=xterm-256color; fi\n' \
      > /etc/profile.d/00-term-fallback.sh && chmod 0644 /etc/profile.d/00-term-fallback.sh

# ── 10. Input images (rarely change) ─────────────────────────────────────────
COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

# ── 11. Workflows (change when adding/updating models or workflows) ────────────
# Depth-1 JSONs → /opt/comfy-workflows/ (install_workflows.sh copies at runtime)
# API JSONs     → /opt/comfy-workflows/API/  (used by benchmark scripts)
COPY workflows/*.json /opt/comfy-workflows/
COPY workflows/API /opt/comfy-workflows/API

# ── 12. Helper scripts & model manager (change most often) ────────────────────
COPY --chmod=755 scripts/install_workflows.sh /opt/
COPY --chmod=755 scripts/get_wan22.sh /opt/
COPY --chmod=755 scripts/get_qwen_image.sh /opt/
COPY --chmod=755 scripts/get_hunyuan15.sh /opt/
COPY --chmod=755 scripts/get_ltx2.sh /opt/
COPY --chmod=755 scripts/get_minimax_h3.sh /opt/
COPY --chmod=755 scripts/start_forge.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/

CMD ["/bin/bash"]
