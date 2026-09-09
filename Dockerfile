FROM registry.fedoraproject.org/fedora:rawhide

# Base packages (keep compilers/headers for Triton JIT at runtime)
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
    libdrm-devel python3.13 python3.13-devel git rsync libatomic bash ca-certificates curl \
    gcc gcc-c++ binutils make git ffmpeg-free vim dialog \
    && dnf clean all && rm -rf /var/cache/dnf/*

# Python venv
RUN /usr/bin/python3.13 -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
ENV PIP_NO_CACHE_DIR=1
RUN printf 'source /opt/venv/bin/activate\n' > /etc/profile.d/venv.sh
RUN python -m pip install --upgrade pip setuptools wheel

# Helper scripts (ComfyUI-only)
COPY scripts/get_wan22.sh /opt/
COPY scripts/set_extra_paths.sh /opt/
COPY scripts/get_qwen_image.sh /opt/
COPY scripts/get_hunyuan15.sh /opt/
COPY scripts/get_ltx2.sh /opt/
COPY scripts/get_minimax_h3.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/
COPY --chmod=755 scripts/install_workflows.sh /opt/
COPY --chmod=755 scripts/install_custom_nodes.sh /opt/
COPY --chmod=755 scripts/setup_comfy_cli.sh /opt/
RUN chmod 0755 /opt/model_manager.py && ln -s /opt/model_manager.py /opt/venv/bin/model_manager
COPY workflows/API /opt/comfy-workflows


# ROCm + PyTorch (TheRock multi-arch release, scoped to Strix Halo gfx1151)
RUN python -m pip install \
    --index-url https://rocm.nightlies.amd.com/whl-multi-arch/ \
    --pre "torch[device-gfx1151]" "torchvision[device-gfx1151]" torchaudio

WORKDIR /opt

# ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI 
WORKDIR /opt/ComfyUI
RUN python -m pip install -r requirements.txt && \
    python -m pip install --prefer-binary \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client

COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ComfyUI plugins
WORKDIR /opt/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials /opt/ComfyUI/custom_nodes/ComfyUI_essentials 
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-AMDGPUMonitor /opt/ComfyUI/custom_nodes/ComfyUI-AMDGPUMonitor 
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-GGUF-H3 /opt/ComfyUI/custom_nodes/ComfyUI-GGUF && \
    python -m pip install -r /opt/ComfyUI/custom_nodes/ComfyUI-GGUF/requirements.txt
RUN git clone --depth=1 https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-Turbo

# ── Constraints: pin what the image curates ───────────────────────────────────
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
# Manager does not replace scripts/install_custom_nodes.sh. The bundled packs
# are what the shipped workflows require, and Manager installs pack
# requirements with no constraints of its own -- it is here for packs the USER
# chooses to add.
RUN python -m pip install -r /opt/ComfyUI/manager_requirements.txt

# comfy-cli is the engine the Comfy MCP shells out to for everything; comfy-mcp
# is the stdio server itself, launched from the host by
# scripts/comfy-mcp-host.sh. Both resolve by bare name because ENV PATH already
# puts /opt/venv/bin first.
RUN python -m pip install "comfy-cli>=1.20" comfy-mcp

# Permissions & trims (keep compilers/headers and installed shared libraries intact)
RUN chmod -R a+rwX /opt && chmod +x /opt/*.sh || true && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    python -m pip cache purge || true && rm -rf /root/.cache/pip || true && \
    dnf clean all && rm -rf /var/cache/dnf/*

# Catch incompatible or damaged PyTorch shared libraries before publishing an image.
RUN python -c 'import torch; print(torch.__version__)'

# Enable torch TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
COPY scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh

# Single source of truth for ComfyUI's launch flags. Sourced before the banner,
# which defines the start_comfy_ui alias that calls comfy_launch_args().
COPY --chmod=0644 scripts/comfy_launch_args.sh /etc/profile.d/02-comfy-launch-args.sh

# Banner script (runs on login). Use a high sort key so it runs after venv.sh and 01-rocm-env...
COPY scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
RUN chmod 0644 /etc/profile.d/99-toolbox-banner.sh

# Keep /opt/venv/bin first after user dotfiles
COPY scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN chmod 0644 /etc/profile.d/zz-venv-last.sh

# Disable core dumps in interactive shells (helps with recovering faster from ROCm crashes)
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

CMD ["/bin/bash"]
