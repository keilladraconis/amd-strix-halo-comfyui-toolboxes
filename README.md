# AMD Ryzen AI Max “Strix Halo” (64GB-128GB) — ComfyUI Toolbox

A pre-configured ComfyUI container with a full ROCm environment and validated image and video workflows for **AMD Ryzen AI Max “Strix Halo”** systems (`gfx1151`, 64–128 GB).

> [!IMPORTANT]
> This repository is part of the **[Strix Halo AI Toolboxes](https://strix-halo-toolboxes.com/)** project. Follow the central guide for the recommended host setup, including unified-memory allocation and OS-specific configuration.

## Recommended setup: AI Toolbox Cockpit

[AI Toolbox Cockpit](https://github.com/kyuz0/ai-toolbox-cockpit) is the preferred way to install, launch, and update this toolbox. It provides tested, pre-configured profiles; supports Toolbx and Distrobox; and can run supported services directly with Podman or Docker, so Toolbx is not required.

```bash
pipx install git+https://github.com/kyuz0/ai-toolbox-cockpit.git
ai-toolbox-cockpit
```

The repository's [`refresh-toolbox.sh`](refresh-toolbox.sh) remains available for manual Toolbx refreshes. The Cockpit is recommended for normal installation and updates.

## Available image channels

| Image | Purpose |
| :--- | :--- |
| `docker.io/kyuz0/amd-strix-halo-comfyui:latest` | Stable, verified build recommended for most users. |
| `docker.io/kyuz0/amd-strix-halo-comfyui:dev` | Development build with newer workflows and dependencies; may be less stable. |

### ❤️ Support

This is a hobby project maintained in my spare time. If you find these toolboxes and tutorials useful, you can **[buy me a coffee](https://buymeacoffee.com/dcapitella)** to support the work! ☕

---

## Table of Contents

- [1. Included Workflows](#1-included-workflows)
- [2. Manual Toolbox Setup](#2-manual-toolbox-setup)
- [3. First Run Setup (Required)](#3-first-run-setup-required)
- [4. Benchmarks](#4-benchmarks)
- [5. Kernel Log Collection](#5-kernel-log-collection)
- [6. Maintainer Notes](#6-maintainer-notes)

---

## 1. Included Workflows

The repository comes with a collection of ComfyUI workflows bundled into the image. API benchmark workflows are also available in `workflows/API` (mapped to `/opt/comfy-workflows` inside the container).

| Workflow | Type | Description |
| :--- | :--- | :--- |
| **HunyuanVideo 1.5** | I2V / T2V | 4-step LoRA, 720p resolution. Configured for 32GB. |
| **LTX-2.3** | T2V / I2V / GGUF | BF16 workflows use either the dev model with the distilled 1.1 LoRA or the distilled checkpoint without LoRAs; 128GB is recommended. Q6_K GGUF copies provide the same two choices with lower memory use. |
| **MiniMax-H3** | T2V / I2V / R2V / Turbo / GGUF / GGUF Turbo | Open-weight video generation with native stereo audio; separate Turbo, low-memory GGUF, and GGUF Turbo workflows are included. |
| **Qwen Image** | T2I | Qwen Image 2512 in BF16, FP8, and GGUF Q4_K_M, with optional 4-step Lightning LoRA. |
| **Qwen Image Edit** | Image Editing | Qwen Image Edit 2511 in BF16, FP8, and GGUF Q4_K_M, with 4/20-step workflows. |
| **Wan 2.2** | I2V / T2V | 14B model with 4-step Lightning LoRA. |

The GGUF workflows use [`kyuz0/ComfyUI-GGUF-H3`](https://github.com/kyuz0/ComfyUI-GGUF-H3), based on `molbal/ComfyUI-GGUF` with support for Unsloth's metadata-free MiniMax-H3 text encoders. The Qwen GGUF downloader includes the matching Qwen2.5-VL text encoder and vision projector; the MiniMax-H3 downloader uses Unsloth's Q2 low-memory model pair; and LTX-2.3 uses Unsloth's Q6_K diffusion models with its matching Gemma encoder, connector, projector, and VAEs. These workflows are currently part of the development channel pending hardware validation.

LTX-2.3 defaults to BF16 on Strix Halo because gfx1151 has native BF16 matrix support. FP8 checkpoints can load, but they are not downloaded or selected automatically; the Q6_K GGUF workflows are the bundled lower-memory alternative.

---

## 2. Manual Toolbox Setup

Use this section only if you prefer to create and maintain the container yourself. For the guided, tested path across Toolbx, Distrobox, Podman, and Docker, use [AI Toolbox Cockpit](#recommended-setup-ai-toolbox-cockpit).

The example below uses Toolbx and shares your home directory with the container. See the [central Strix Halo setup guide](https://strix-halo-toolboxes.com/) for host preparation and other supported container engines.

### 2.1. Create the Toolbox

Run the following command on your host to create the container with GPU access:

```bash
toolbox create strix-halo-comfyui \
  --image docker.io/kyuz0/amd-strix-halo-comfyui:latest \
  -- --device /dev/dri --device /dev/kfd \
  --group-add video --group-add render --security-opt seccomp=unconfined
```

*   `--device /dev/dri` & `/dev/kfd`: Exposes AMD GPU and compute devices.
*   `--security-opt seccomp=unconfined`: Required for some ROCm/GPU operations.

### 2.2. Enter the Toolbox

```bash
toolbox enter strix-halo-comfyui
```

Once inside, you have access to a full ROCm environment with PyTorch, ComfyUI, and helper scripts in `/opt`.

> [!IMPORTANT]
> The included `start_comfy_ui` alias launches ComfyUI with `--bf16-vae`, `--disable-mmap`, and `--cache-none`.
> *   **`--bf16-vae`**: Prevents OOM during VAE decoding.
> *   **`--disable-mmap`**: **Critical for Strix Halo (gfx1151)**. Memory mapping above 64GB is currently very slow due to a ROCm issue; disabling it prevents performance degradation and hangs.
> *   **`--cache-none`**: Disables model caching to manage unified memory more aggressively.

### 2.3. Manual updates

AI Toolbox Cockpit is the recommended update path. If you created the Toolbx container manually, use the repository script to pull a newer image without deleting models stored in your home directory.

You can run it interactively to select a channel, or pass the channel name as an argument (`latest` or `dev`):

```bash
./refresh-toolbox.sh [latest|dev]
```

- **`latest`**: Stable / verified working build (default, recommended).
- **`dev`**: Development build (may be unstable).

> [!WARNING]
> This will **delete and recreate** the toolbox container. Any files stored *inside* the container system (e.g., `/opt`, `/usr`) will be lost. **Files in your home directory (`~`) are safe.**

---

## 3. First Run Setup (Required)

After entering the toolbox for the first time, you must configure the storage paths and download the model weights.

### Step 1: Configure Persistent Paths

Run the setup script to link ComfyUI's model directories to your home folder (`~/comfy-models`). This ensures you don't download 100GB+ of models every time you refresh the container.

```bash
/opt/set_extra_paths.sh
```

### Step 2: Download Models

Use the **Model Manager TUI** to download the required checkpoints and LoRAs for the included workflows. This tool handles the complex dependency chains (e.g., downloading base models before LoRAs).

```bash
model_manager
```
*(Or `python /opt/model_manager.py`)*

Select the workflow you want to run (e.g., "Wan 2.2 - Text to Video"), and the manager will download the necessary files to `~/comfy-models`.

> **Note:** The manager uses the helper scripts located in `/opt/` (like `get_qwen_image.sh`, `get_wan22.sh`) under the hood. You can run these manually if you prefer CLI arguments.

---

## 4. Benchmarks

We maintain a list of performance benchmarks for these workflows on the AMD Ryzen AI Max “Strix Halo”.

👉 **View Benchmarks:** [https://kyuz0.github.io/amd-strix-halo-comfyui-toolboxes/](https://kyuz0.github.io/amd-strix-halo-comfyui-toolboxes/)

To run benchmarks yourself:
```bash
python /opt/benchmark_workflows.py
```

---

## 5. Kernel Log Collection

We are working directly with AMD to improve kernel stability and performance for the Strix Halo (gfx1151). If you encounter performance issues or crashes, you can help by collecting execution logs.

**Tracking Issue:** [ROCm/TheRock#2591](https://github.com/ROCm/TheRock/issues/2591)

### How to Collect Logs

1.  Make sure you are inside the toolbox.
2.  Run the log collection script:

```bash
python /opt/collect_perf_logs.py
```

This script will:
*   Run the workflows in isolation.
*   Capture `hipblaslt` and `miopen` logs.
*   Save them to the `perf_logs/` directory in your current folder.

Please zip the `perf_logs` folder and attach it to the GitHub issue mentioned above, or share it with the maintainers.

---

## 6. Maintainer Notes

### Publishing Log Releases

To publish collected performance logs as a GitHub Release (for tracking historical data):

1.  **Zip the logs:**
    ```bash
    zip -r perf_logs_$(date +%Y%m%d).zip perf_logs/
    ```

2.  **Create a Release:**
    ```bash
    gh release create logs-$(date +%Y%m%d) perf_logs_$(date +%Y%m%d).zip \
      --title "Performance Logs $(date +%Y-%m-%d)" \
      --notes "Logs collected on Strix Halo for kernel analysis."
    ```
