#!/usr/bin/env bash
# install_custom_nodes.sh – Install the bundled ComfyUI custom node packs.
#
# ComfyUI is launched with `--base-directory $HOME/comfy-ui`, and
# folder_paths.py resolves custom_nodes relative to that base — so packs baked
# into /opt/ComfyUI/custom_nodes are never scanned. They belong in the user's
# base directory instead, where they also survive `toolbox rm`.
#
# Each pack's own requirements.txt drives its dependencies into the venv,
# rather than the Dockerfile hand-curating them -- for user-installed packs
# (ComfyUI-Manager, manual clones) as well as the bundled ones, since both
# persist in $HOME across toolbox recreations while the venv does not.
#
# Usage:
#   install_custom_nodes            Clone anything missing, ensure deps
#   install_custom_nodes update     Also fast-forward existing clones
#   install_custom_nodes list       Show packs and their state, change nothing
set -uo pipefail

DEST="${COMFY_BASE_DIR:-$HOME/comfy-ui}/custom_nodes"
PY="${PY:-/opt/venv/bin/python}"
# Dependency installs land in the venv, which lives in the image and is reset
# whenever the toolbox is recreated. Keeping the stamp there means a fresh
# toolbox reinstalls deps even though the clones in $HOME persisted.
# The stamp holds a fingerprint of every pack's requirements.txt in the base
# directory, so packs installed later (ComfyUI-Manager, a manual clone) and
# packs whose requirements changed also trigger a reinstall.
STAMP="${STAMP:-/opt/venv/.custom-nodes-deps}"
# Stops a pack's requirements.txt from replacing the image's pinned torch,
# transformers, numpy or pillow. Written at build time from what is actually
# installed, and pointed at by PIP_CONSTRAINT/UV_CONSTRAINT image-wide, so the
# explicit -c below only adds the known-bad pins on top. Absent means the image
# is older than that change, or broken.
CONSTRAINTS="${CONSTRAINTS:-/opt/venv/image-constraints.txt}"

# Known-bad upstream combinations, applied on top of the image constraints.
# A pack listing a dependency unpinned can otherwise resolve to a release that
# breaks it. Each entry needs a comment saying which pack and which symbol.
NODE_PINS=(
  # ComfyUI-LTXVideo's pyramid_blending.py does
  #   from kornia.geometry.transform.pyramid import (pad, ...)
  # and kornia stopped re-exporting `pad` from that module in 0.8.2.
  "kornia<0.8.2"
)

REPOS=(
  https://github.com/cubiq/ComfyUI_essentials
  https://github.com/kyuz0/ComfyUI-AMDGPUMonitor
  # kyuz0's fork of city96/ComfyUI-GGUF, via molbal/ComfyUI-GGUF: it adds
  # support for Unsloth's metadata-free MiniMax-H3 text encoders, which the
  # bundled H3 GGUF workflows load. city96's original cannot read them.
  #
  # This installs as ComfyUI-GGUF-H3, a different directory from the
  # ComfyUI-GGUF that earlier versions cloned. If you have that older directory
  # in $HOME/comfy-ui/custom_nodes, delete it: both register the same node
  # classes, and ComfyUI will load whichever it scans first.
  https://github.com/kyuz0/ComfyUI-GGUF-H3
  https://github.com/Lightricks/ComfyUI-LTXVideo
  https://github.com/evanspearman/ComfyMath
  https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo
)

MODE="${1:-install}"
failed=0

# Membership test for REPOS, so bundled and user-installed packs can be told
# apart in the dependency pass (bundled packs are the image's contract; user
# packs are best effort).
declare -A IN_MANIFEST=()
for url in "${REPOS[@]}"; do IN_MANIFEST["$(basename "$url")"]=1; done

case "$MODE" in
  install|update|list) ;;
  -h|--help|help)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: install_custom_nodes [install|update|list]" >&2
    exit 1
    ;;
esac

if [[ "$MODE" == "list" ]]; then
  for url in "${REPOS[@]}"; do
    name="$(basename "$url")"
    if [[ -d "$DEST/$name" ]]; then
      printf '  %-32s installed\n' "$name"
    else
      printf '  %-32s missing\n' "$name"
    fi
  done
  # Packs the user installed by other means (Manager, a manual clone) — shown
  # so it is visible which dependency sets the install path will cover.
  for d in "$DEST"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ -n "${IN_MANIFEST[$name]:-}" ]] && continue
    printf '  %-32s user-installed\n' "$name"
  done
  exit 0
fi

mkdir -p "$DEST" || { echo "✗ Cannot create $DEST" >&2; exit 1; }

changed=0
for url in "${REPOS[@]}"; do
  name="$(basename "$url")"
  target="$DEST/$name"

  if [[ -d "$target/.git" ]]; then
    if [[ "$MODE" == "update" ]]; then
      echo "↻ Updating $name"
      if git -C "$target" pull --ff-only --quiet; then
        changed=1
      else
        echo "  ⚠ Could not update $name (leaving the existing clone in place)" >&2
        failed=1
      fi
    else
      echo "✓ Already present: $name"
    fi
  elif [[ -e "$target" ]]; then
    # Someone put a non-git directory here; never clobber a user's own work.
    echo "⚠ Skipping $name: $target exists but is not a git clone" >&2
    failed=1
  else
    echo "↓ Cloning $name"
    if git clone --depth=1 --quiet "$url" "$target"; then
      changed=1
    else
      echo "  ⚠ Could not clone $name (no network?)" >&2
      failed=1
    fi
  fi
done

# Should the dependency pass run? The stamp records a fingerprint of every
# requirements.txt under $DEST — bundled packs and user packs alike. It is
# gone after a venv reset (the stamp lives in the venv), and it changes when a
# pack is added, removed, updated, or hand-fixed. An empty stamp (older
# images) never matches, so this also migrates.
requirements_fingerprint() {
  local f line
  for f in "$DEST"/*/requirements.txt; do
    [[ -f "$f" ]] || continue
    line="$(sha256sum "$f")"
    printf '%s %s\n' "$(basename "$(dirname "$f")")" "${line%% *}"
  done | sort | sha256sum | cut -d' ' -f1
}

wanted_fp="$(requirements_fingerprint)"
stamped_fp=""
[[ -f "$STAMP" ]] && stamped_fp="$(cat "$STAMP" 2>/dev/null || true)"

if [[ "$changed" == "1" || "$MODE" == "update" || "$stamped_fp" != "$wanted_fp" ]]; then
  # Effective constraints = the image's pins plus the known-bad-combination
  # pins above. Written to a temp file so pip sees them as one set.
  effective="$(mktemp)"
  trap 'rm -f "$effective"' EXIT
  if [[ -f "$CONSTRAINTS" ]]; then
    cat "$CONSTRAINTS" > "$effective"
  else
    echo "⚠ No constraints file at $CONSTRAINTS." >&2
    echo "  This file is now the image-wide pin set — PIP_CONSTRAINT and" >&2
    echo "  UV_CONSTRAINT point at it too — so without it nothing stops a node" >&2
    echo "  pack, ComfyUI-Manager or the Comfy MCP from replacing the ROCm" >&2
    echo "  torch. Refresh the toolbox rather than installing over this." >&2
  fi
  printf '%s\n' "${NODE_PINS[@]}" >> "$effective"
  pip_args=(--quiet --prefer-binary -c "$effective")

  # Every pack on disk with a requirements.txt is a dependency target: packs
  # survive a toolbox recreation in $HOME, but their pip installs do not, and
  # ComfyUI-Manager does not repair them for packs that are already present.
  # Bundled packs go first so a slow or broken user pack cannot delay them.
  targets=()
  for url in "${REPOS[@]}"; do
    [[ -f "$DEST/$(basename "$url")/requirements.txt" ]] && targets+=("$(basename "$url")")
  done
  for d in "$DEST"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ -f "$d/requirements.txt" && -z "${IN_MANIFEST[$name]:-}" ]] && targets+=("$name")
  done

  echo
  echo "Installing custom node dependencies into the venv ..."
  user_failed=()
  for name in "${targets[@]}"; do
    reqs="$DEST/$name/requirements.txt"
    if [[ -n "${IN_MANIFEST[$name]:-}" ]]; then
      echo "  → $name"
    else
      echo "  → $name (user-installed)"
    fi
    if ! "$PY" -m pip install "${pip_args[@]}" -r "$reqs"; then
      if [[ -n "${IN_MANIFEST[$name]:-}" ]]; then
        echo "  ⚠ Dependency install failed for $name" >&2
        echo "    If it conflicts with a pinned package, the constraint is deliberate:" >&2
        echo "    $CONSTRAINTS" >&2
        failed=1
      else
        # Best effort: a user pack whose deps cannot build here (a source
        # compile that needs CUDA, say) must not stall every start, so its
        # failure still lets the stamp record this requirements set.
        echo "  ⚠ Dependency install failed for $name (user-installed; continuing)" >&2
        user_failed+=("$name")
      fi
    fi
  done
  if [[ "$failed" == "0" ]]; then
    printf '%s\n' "$wanted_fp" > "$STAMP" 2>/dev/null || true
  fi
fi

echo
if [[ "${#user_failed[@]}" -gt 0 ]]; then
  echo "⚠ Dependencies failed for user-installed pack(s): ${user_failed[*]}" >&2
  echo "  They may not load in ComfyUI. update_custom_nodes retries every pack;" >&2
  echo "  a bundled pack is unaffected." >&2
fi
echo
if [[ "$failed" == "0" ]]; then
  echo "✅ Custom nodes ready → $DEST"
else
  echo "⚠ Finished with problems — some packs may not load. See warnings above." >&2
fi
exit "$failed"
