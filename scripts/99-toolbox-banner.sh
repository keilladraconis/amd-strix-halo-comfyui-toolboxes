#!/usr/bin/env bash
# Lightweight banner with machine/GPU and ROCm nightly version

# Load ROCm env quietly if present
[[ -f /etc/profile.d/01-rocm-envs.sh ]] && . /etc/profile.d/01-rocm-envs.sh

oem_info() {
  local v="" m="" d lv lm
  for d in /sys/class/dmi/id /sys/devices/virtual/dmi/id; do
    [[ -r "$d/sys_vendor" ]] && v=$(<"$d/sys_vendor")
    [[ -r "$d/product_name" ]] && m=$(<"$d/product_name")
    [[ -n "$v" || -n "$m" ]] && break
  done
  # ARM/SBC fallback
  if [[ -z "$v" && -z "$m" && -r /proc/device-tree/model ]]; then
    tr -d '\0' </proc/device-tree/model
    return
  fi
  lv=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  lm=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$m" && "$lm" == "$lv "* ]]; then
    printf '%s\n' "$m"
  else
    printf '%s %s\n' "${v:-Unknown}" "${m:-Unknown}"
  fi
}

gpu_name() {
  local name=""
  if command -v rocm-smi >/dev/null 2>&1; then
    name=$(rocm-smi --showproductname --csv 2>/dev/null | tail -n1 | cut -d, -f2)
    [[ -z "$name" ]] && name=$(rocm-smi --showproductname 2>/dev/null | grep -m1 -E 'Product Name|Card series' | sed 's/.*: //')
  fi
  if [[ -z "$name" ]] && command -v rocminfo >/dev/null 2>&1; then
    name=$(rocminfo 2>/dev/null | awk -F': ' '/^[[:space:]]*Name:/{print $2; exit}')
  fi
  if [[ -z "$name" ]] && command -v lspci >/dev/null 2>&1; then
    name=$(lspci -nn 2>/dev/null | grep -Ei 'vga|display|gpu' | grep -i amd | head -n1 | cut -d: -f3-)
  fi
  # trim leading/trailing spaces and squeeze multiple spaces to one
  name=$(printf '%s' "$name" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' -e 's/[[:space:]]\{2,\}/ /g')
  printf '%s\n' "${name:-Unknown AMD GPU}"
}

rocm_version() {
  local PY="/opt/venv/bin/python"
  [[ -x "$PY" ]] || PY="python"
  "$PY" - <<'PY' 2>/dev/null || true
try:
    import importlib.metadata as im
    try:
        print(im.version('_rocm_sdk_core'))
    except Exception:
        print(im.version('rocm'))
except Exception:
    print("")
PY
}

# Date the bundled sources (ComfyUI, custom nodes, studios, Forge) were last
# cloned. Written by the Dockerfile's refresh barrier and frozen with the layer
# cache, so it reports the real age of the clones, not of the build.
sources_line() {
  local refreshed age
  [[ -r /etc/toolbox-sources ]] || return
  refreshed=$(sed -n 's/^refreshed=//p' /etc/toolbox-sources)
  [[ -n "$refreshed" ]] || return
  age=$(( ( $(date -u +%s) - $(date -u -d "$refreshed" +%s 2>/dev/null || echo 0) ) / 86400 ))
  if (( age >= 14 )); then
    printf 'Sources: %s (%sd old — refresh: ./refresh-toolbox.sh --local --refresh-sources)\n' \
      "$refreshed" "$age"
  else
    printf 'Sources: %s\n' "$refreshed"
  fi
}

MACHINE="$(oem_info)"
GPU="$(gpu_name)"
ROCM_VER="$(rocm_version)"
SOURCES="$(sources_line)"

echo
cat <<'ASCII'
███████╗████████╗██████╗ ██╗██╗  ██╗      ██╗  ██╗ █████╗ ██╗      ██████╗ 
██╔════╝╚══██╔══╝██╔══██╗██║╚██╗██╔╝      ██║  ██║██╔══██╗██║     ██╔═══██╗
███████╗   ██║   ██████╔╝██║ ╚███╔╝       ███████║███████║██║     ██║   ██║
╚════██║   ██║   ██╔══██╗██║ ██╔██╗       ██╔══██║██╔══██║██║     ██║   ██║
███████║   ██║   ██║  ██║██║██╔╝ ██╗      ██║  ██║██║  ██║███████╗╚██████╔╝
╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝      ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝ ╚═════╝ 

                          C O M F Y   U I                        

ASCII
echo
printf 'AMD Ryzen AI Max “Strix Halo” — Image & Video Toolbox (gfx1151, ROCm via TheRock)\n'
[[ -n "$ROCM_VER" ]] && printf 'ROCm nightly: %s\n' "$ROCM_VER"
[[ -n "$SOURCES" ]] && printf '%s\n' "$SOURCES"
echo
printf 'Machine: %s\n' "$MACHINE"
printf 'GPU    : %s\n\n' "$GPU"
printf 'Repo   : https://github.com/kyuz0/amd-strix-halo-comfyui-toolboxes\n'
printf 'Image  : docker.io/kyuz0/amd-strix-halo-comfyui:latest\n\n'
printf 'Included:\n'
printf '  - %-16s → %s\n' "ComfyUI"            "start_comfy_ui (http://localhost:8000)"
printf '  - %-16s → %s\n' "SD Forge"           "start_forge    (http://localhost:7860)"
printf '  - %-16s → %s\n' "Install Workflows"  "install_workflows  (copy bundled workflows to ~/comfy-ui)"
printf '  - %-16s → %s\n' "Custom Nodes"       "install_custom_nodes / update_custom_nodes"
printf '  - %-16s → %s\n' "Model Manager"  "model_manager (select and install models for workflows)"

echo
printf 'SSH tip: ssh -L 8000:localhost:8000 -L 7860:localhost:7860 user@host\n\n'

# Aliases
# Custom node packs live in the ComfyUI base directory, not in the image — see
# /opt/install_custom_nodes.sh. Installing before launch means a fresh toolbox
# can never start with an empty custom_nodes directory. A failure there (no
# network, say) is reported but must not stop ComfyUI from starting.
alias start_comfy_ui='/opt/install_custom_nodes.sh || echo "⚠ Continuing without some custom nodes."; cd /opt/ComfyUI && python main.py --port 8000 --base-directory $HOME/comfy-ui --disable-mmap --gpu-only --disable-smart-memory --cache-none --bf16-vae'
alias install_custom_nodes='/opt/install_custom_nodes.sh'
alias update_custom_nodes='/opt/install_custom_nodes.sh update'
alias start_forge='/opt/start_forge.sh'
alias install_workflows='/opt/install_workflows.sh'
alias model_manager='python /opt/model_manager.py'
