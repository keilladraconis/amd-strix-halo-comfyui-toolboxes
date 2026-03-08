FROM registry.fedoraproject.org/fedora:rawhide

# ── 1. Base packages ──────────────────────────────────────────────────────────
# (keep compilers/headers for Triton JIT at runtime)
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
    libdrm-devel python3.13 python3.13-devel git rsync libatomic bash ca-certificates curl \
    gcc gcc-c++ binutils make git ffmpeg-free vim dialog \
    && dnf clean all && rm -rf /var/cache/dnf/*

# ── 2. Python venv ────────────────────────────────────────────────────────────
RUN /usr/bin/python3.13 -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
ENV PIP_NO_CACHE_DIR=1
RUN printf 'source /opt/venv/bin/activate\n' > /etc/profile.d/venv.sh
RUN python -m pip install --upgrade pip setuptools wheel

# ── 3. ROCm + PyTorch ─────────────────────────────────────────────────────────
# (TheRock; include torchaudio for resolver)
RUN python -m pip install \
    --index-url https://rocm.nightlies.amd.com/v2-staging/gfx1151 \
    --pre torch torchaudio torchvision && \
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
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client

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
# LTX-2.3 nodes: ClownSampler
RUN git clone --depth=1 https://github.com/ClownsharkBatwing/RES4LYF && \
    chmod -R a+rwX RES4LYF && \
    python -m pip install -r RES4LYF/requirements.txt
# LTX-2.3 nodes: rgthree
RUN git clone --depth=1 https://github.com/rgthree/rgthree-comfy.git && \
    chmod -R a+rwX rgthree-comfy

# ── 9. Static profile.d scripts (rarely change) ───────────────────────────────
COPY --chmod=0644 scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh
COPY --chmod=0644 scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
COPY --chmod=0644 scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

# ── 10. Input images (rarely change) ─────────────────────────────────────────
COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

# ── 11. Workflows (change when adding/updating models or workflows) ────────────
COPY workflows/API /opt/comfy-workflows
COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ── 12. Helper scripts & model manager (change most often) ────────────────────
COPY --chmod=755 scripts/set_extra_paths.sh /opt/
COPY --chmod=755 scripts/get_wan22.sh /opt/
COPY --chmod=755 scripts/get_qwen_image.sh /opt/
COPY --chmod=755 scripts/get_hunyuan15.sh /opt/
COPY --chmod=755 scripts/get_ltx2.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/

CMD ["/bin/bash"]
