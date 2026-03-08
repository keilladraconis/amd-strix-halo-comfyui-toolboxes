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
    --pre torch torchaudio torchvision

# ── 4. Core Python deps ───────────────────────────────────────────────────────
WORKDIR /opt
RUN python -m pip install gguf transformers==4.56.2

# ── 5. ComfyUI ────────────────────────────────────────────────────────────────
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI
WORKDIR /opt/ComfyUI
RUN python -m pip install -r requirements.txt && \
    python -m pip install --prefer-binary \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client

# ── 6. ComfyUI custom nodes ───────────────────────────────────────────────────
WORKDIR /opt/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials /opt/ComfyUI/custom_nodes/ComfyUI_essentials
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-AMDGPUMonitor /opt/ComfyUI/custom_nodes/ComfyUI-AMDGPUMonitor
RUN git clone --depth=1 https://github.com/city96/ComfyUI-GGUF /opt/ComfyUI/custom_nodes/ComfyUI-GGUF
# LTX-2.3 nodes: GemmaAPITextEncode, LTXVImgToVideoConditionOnly
RUN git clone --depth=1 https://github.com/Lightricks/ComfyUI-LTXVideo /opt/ComfyUI/custom_nodes/ComfyUI-LTXVideo && \
    python -m pip install --prefer-binary einops ninja timm
# LTX-2.3 nodes: CM_FloatToInt
RUN git clone --depth=1 https://github.com/evanspearman/ComfyMath /opt/ComfyUI/custom_nodes/ComfyMath

# ── 7. External studios ───────────────────────────────────────────────────────
WORKDIR /opt
RUN git clone --depth=1 https://github.com/kyuz0/qwen-image-studio /opt/qwen-image-studio && \
    python -m pip install -r /opt/qwen-image-studio/requirements.txt

RUN git clone --depth=1 https://github.com/kyuz0/wan-video-studio /opt/wan-video-studio && \
    python -m pip install --prefer-binary \
    opencv-python-headless diffusers tokenizers accelerate \
    imageio[ffmpeg] easydict ftfy dashscope imageio-ffmpeg decord librosa

# ── 8. Permissions & size trim ────────────────────────────────────────────────
# (keep compilers/headers for Triton JIT; no scripts here yet — chmod +x added below)
RUN chmod -R a+rwX /opt && \
    find /opt/venv -type f -name "*.so" -exec strip -s {} + 2>/dev/null || true && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    dnf clean all && rm -rf /var/cache/dnf/*

# ── 9. Static profile.d scripts (rarely change) ───────────────────────────────
COPY scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh
COPY scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
COPY scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN chmod 0644 /etc/profile.d/99-toolbox-banner.sh /etc/profile.d/zz-venv-last.sh && \
    printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

# ── 10. Input images (rarely change) ─────────────────────────────────────────
COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

# ── 11. Workflows (change when adding/updating models or workflows) ────────────
COPY workflows/API /opt/comfy-workflows
COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ── 12. Helper scripts & model manager (change most often) ────────────────────
COPY scripts/set_extra_paths.sh /opt/
COPY scripts/get_wan22.sh /opt/
COPY scripts/get_qwen_image.sh /opt/
COPY scripts/get_hunyuan15.sh /opt/
COPY scripts/get_ltx2.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/
RUN chmod +x /opt/*.sh

CMD ["/bin/bash"]
