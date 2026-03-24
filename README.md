# AMD Ryzen AI Max “Strix Halo” (64GB-128GB) — ComfyUI Toolbox

A Fedora **toolbox** image with a full **ROCm environment** (TheRock Nightlies / ROCm 7) for **image & video generation** on the **AMD Ryzen AI Max “Strix Halo”** (gfx1151, 64GB-128GB).

This repository provides a pre-configured Docker container to run **ComfyUI** with validated workflows on the **AMD Ryzen AI Max** (64GB-128GB).

---

### 📦 Project Context

This repository is part of the **[Strix Halo AI Toolboxes](https://strix-halo-toolboxes.com)** project. Check out the website for an overview of all toolboxes, tutorials, and host configuration guides.

### ❤️ Support

This is a hobby project maintained in my spare time. If you find these toolboxes and tutorials useful, you can **[buy me a coffee](https://buymeacoffee.com/dcapitella)** to support the work! ☕

## Watch the YouTube Video

> [!IMPORTANT]
> **Work In Progress**: This toolbox is functional, but is still under active testing.  
> A full setup guide and video walkthrough is planned for second half of**February 2025**.

## Watch the YouTube Video

*Coming Soon (February 2025)*


---

## Table of Contents

- [1. Included Workflows](#1-included-workflows)
- [2. Toolbox Setup](#2-toolbox-setup)
- [3. First Run Setup (Required)](#3-first-run-setup-required)
- [4. Benchmarks](#4-benchmarks)
- [5. Kernel Log Collection](#5-kernel-log-collection)
- [6. Maintainer Notes](#6-maintainer-notes)
- [7. Host Configuration](#7-host-configuration)
- [8. Development Guide](#8-development-guide)

---

## 1. Included Workflows

The repository comes with a collection of ComfyUI workflows pre-validated on this hardware. UI-format workflows are baked into the image at `/opt/comfy-workflows/` and copied to `~/comfy-ui/user/default/workflows/` by `install_workflows`. API-format workflows live under `/opt/comfy-workflows/API/` and are used by the benchmark scripts.

| Workflow | Type | Description |
| :--- | :--- | :--- |
| **HunyuanVideo 1.5** | I2V / T2V | 4-step LoRA, 720p resolution. Configured for 32GB. |
| **LTX Video 2** | I2V / T2V | BF16, standard single-stage generation. |
| **LTX Video 2.3 — Single Stage** | I2V / T2V | BF16, single-stage distilled full pipeline. |
| **LTX Video 2.3 — Two Stage** | I2V / T2V | BF16, two-stage distilled pipeline for higher quality. |
| **Qwen Image** | T2I | Qwen Image 2512 (FP8) & Lightning LoRA (4 steps). |
| **Qwen Image Edit** | Image Editing | Qwen Image Edit 2511 (FP8) & Lightning LoRA (4/20 steps). |
| **Wan 2.2** | I2V / T2V | 14B model with 4-step Lightning LoRA. |

---

## 2. Toolbox Setup

This project uses `toolbox` (built on Podman) to provide a seamless development environment that integrates with your home directory.

### 2.1. Create the Toolbox

Use the provided script to pull the latest image and create the toolbox with the correct GPU device flags:

```bash
./refresh-toolbox.sh
```

> [!WARNING]
> If a toolbox named `amd-strix-halo-comfyui` already exists, this script will **delete and recreate** it. Any files stored *inside* the container (e.g., `/opt`, `/usr`) will be lost. **Files in your home directory (`~`) are safe.**

### 2.2. Enter the Toolbox

```bash
toolbox enter amd-strix-halo-comfyui
```

Once inside, you have access to a full ROCm environment with PyTorch, ComfyUI, and helper scripts in `/opt`.

> [!IMPORTANT]
> The included `start_comfy_ui` alias launches ComfyUI with `--bf16-vae`, `--disable-mmap`, and `--cache-none`.
> *   **`--bf16-vae`**: Prevents OOM during VAE decoding.
> *   **`--disable-mmap`**: **Critical for Strix Halo (gfx1151)**. Memory mapping above 64GB is currently very slow due to a ROCm issue; disabling it prevents performance degradation and hangs.
> *   **`--cache-none`**: Disables model caching to manage the unified memory more aggressively (`GTT` vs `RAM`).

### 2.3. Updating the Toolbox

To update to a newer image (e.g., for newer ROCm nightly builds), run the same script again:

```bash
./refresh-toolbox.sh
```

Your downloaded models are safe as long as they live in your home directory (`~/comfy-ui/models`).

---

## 3. First Run Setup (Required)

After entering the toolbox for the first time, install the bundled workflows and download the model weights.

### Step 1: Install Bundled Workflows

Copy the pre-validated workflows into your ComfyUI user directory:

```bash
install_workflows
```

This copies the UI-format workflow JSONs from `/opt/comfy-workflows/` to `~/comfy-ui/user/default/workflows/`. Re-run after any toolbox refresh to pick up new workflows.

### Step 2: Download Models

Use the **Model Manager TUI** to download the required checkpoints and LoRAs for the included workflows. This tool handles the complex dependency chains (e.g., downloading base models before LoRAs).

```bash
python /opt/model_manager.py
```

Select the workflow you want to run (e.g., "Wan 2.2 - Text to Video"), and the manager will download the necessary files to `~/comfy-ui/models`.

> **Note:** The manager calls the helper scripts in `/opt/` (e.g. `get_qwen_image.sh`, `get_wan22.sh`) under the hood. You can run these directly if you prefer CLI arguments.

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

---

## 7. Host Configuration

This should work on any Strix Halo. For a complete list of available hardware, see: [Strix Halo Hardware Database](https://strixhalo-homelab.d7.wtf/Hardware)

### 7.1 Test Configuration

|                    |                                               |
| ------------------ | --------------------------------------------- |
| **Test Machine**   | Framework Desktop                             |
| **CPU**            | Ryzen AI MAX+ 395 "Strix Halo"                |
| **System Memory**  | 128 GB RAM                                    |
| **GPU Memory**     | 512 MB allocated in BIOS                      |
| **Host OS**        | Fedora 43                                     |
| **Host OS**        | 6.18.4-100.fc43.x86\_64                       |
| **Linux firmware** | 20251111                                      |

### 7.2 Kernel Parameters

Add these boot parameters to enable unified memory while reserving a minimum of 4 GiB for the OS (max 128 GiB for iGPU):

| Parameter                    | Purpose                                                                                     |
|------------------------------|---------------------------------------------------------------------------------------------|
| `amd_iommu=off`              | Disables IOMMU for lower latency                                                            |
| `amdgpu.gttsize=126976`      | Caps GPU unified memory to 124 GiB; 126976 MiB ÷ 1024 = 124 GiB                            |
| `ttm.pages_limit=32505856`   | Caps pinned memory to 124 GiB; 32505856 × 4 KiB = 126976 MiB = 124 GiB                     |

Source: [Framework Community — AMD Strix Halo llama.cpp installation guide for Fedora 42](https://community.frame.work/t/amd-strix-halo-llama-cpp-installation-guide-for-fedora-42/75856#p-297775-h-11-add-kernel-parameters-using-grubby-4)

**Apply the changes (Fedora):**

```bash
sudo grubby --update-kernel=ALL --args='amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856'
sudo reboot
```

---

## 8. Development Guide

This section covers how to build and test changes to this toolbox locally, and how to add or update workflows.

### 8.1. Building and Testing the Image Locally

The `refresh-toolbox.sh` script supports a `--local` flag that builds the `Dockerfile` from your local checkout instead of pulling from the registry. Use this when iterating on the image (e.g., adding packages, changing scripts):

```bash
./refresh-toolbox.sh --local
```

This will:
1. Run `podman build` against the `Dockerfile` in the repo root and tag the result as the production image name.
2. Delete the existing `amd-strix-halo-comfyui` toolbox (if present).
3. Recreate it from the freshly-built local image with the correct GPU device flags.

After it completes, enter the toolbox as usual to test your changes:

```bash
toolbox enter amd-strix-halo-comfyui
```

> [!WARNING]
> Like a normal refresh, `--local` will **delete and recreate** the toolbox container. Files inside the container (e.g., `/opt`, `/usr`) will be reset. Your home directory is safe.

### 8.2. Adding or Updating Workflows

Workflows are stored in two formats, both required:

| Directory | Format | Purpose |
| :--- | :--- | :--- |
| `workflows/` | **UI format** | Human-readable; load directly in the ComfyUI browser interface. |
| `workflows/API/` | **API format** | Minimal JSON used by the benchmark and log-collection scripts. |

Both files should share the same base filename (e.g., `My-Workflow.json`).

#### Exporting from the ComfyUI UI

1. Design and validate your workflow in the ComfyUI browser interface.
2. Export the **UI format**: `Menu → Save (workflow)` — save as `workflows/<workflow-name>.json`.
3. Export the **API format**: `Menu → Save (API format)` — save as `workflows/API/<workflow-name>.json`.

> [!NOTE]
> The "Save (API format)" option is only visible when **Dev Mode** is enabled in ComfyUI settings (`Settings → Enable Dev Mode Options`).

#### Checklist for new workflows

- [ ] Both `workflows/<name>.json` and `workflows/API/<name>.json` are committed.
- [ ] The workflow has been validated end-to-end on Strix Halo hardware.
- [ ] Required models are listed in the workflow table in [Section 1](#1-included-workflows).
- [ ] Any new model download scripts or `model_manager` entries are updated accordingly.
