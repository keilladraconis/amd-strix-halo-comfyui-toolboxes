#!/usr/bin/env bash
# install_custom_nodes.sh – Install the bundled ComfyUI custom node packs.
#
# ComfyUI is launched with `--base-directory $HOME/comfy-ui`, and
# folder_paths.py resolves custom_nodes relative to that base — so packs baked
# into /opt/ComfyUI/custom_nodes are never scanned. They belong in the user's
# base directory instead, where they also survive `toolbox rm`.
#
# Each pack's own requirements.txt drives its dependencies into the venv,
# rather than the Dockerfile hand-curating them.
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
STAMP="${STAMP:-/opt/venv/.custom-nodes-deps}"
# Stops a pack's requirements.txt from replacing the image's pinned torch,
# transformers, numpy, pillow or gradio. Written at build time from what is
# actually installed. Absent (e.g. an older image) means installs run
# unconstrained, as they did before.
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
  https://github.com/city96/ComfyUI-GGUF
  https://github.com/Lightricks/ComfyUI-LTXVideo
  https://github.com/evanspearman/ComfyMath
  https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo
)

MODE="${1:-install}"
failed=0

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

# Reinstall deps when a clone changed, when the venv was reset (stamp gone), or
# on an explicit update.
if [[ "$changed" == "1" || ! -f "$STAMP" || "$MODE" == "update" ]]; then
  # Effective constraints = the image's pins plus the known-bad-combination
  # pins above. Written to a temp file so pip sees them as one set.
  effective="$(mktemp)"
  trap 'rm -f "$effective"' EXIT
  if [[ -f "$CONSTRAINTS" ]]; then
    cat "$CONSTRAINTS" > "$effective"
  else
    echo "⚠ No constraints file at $CONSTRAINTS — node dependencies may replace" >&2
    echo "  the image's pinned torch/transformers/numpy/pillow." >&2
  fi
  printf '%s\n' "${NODE_PINS[@]}" >> "$effective"
  pip_args=(--quiet --prefer-binary -c "$effective")

  echo
  echo "Installing custom node dependencies into the venv ..."
  for url in "${REPOS[@]}"; do
    name="$(basename "$url")"
    reqs="$DEST/$name/requirements.txt"
    [[ -f "$reqs" ]] || continue
    echo "  → $name"
    if ! "$PY" -m pip install "${pip_args[@]}" -r "$reqs"; then
      echo "  ⚠ Dependency install failed for $name" >&2
      echo "    If it conflicts with a pinned package, the constraint is deliberate:" >&2
      echo "    $CONSTRAINTS" >&2
      failed=1
    fi
  done
  if [[ "$failed" == "0" ]]; then
    : > "$STAMP" 2>/dev/null || true
  fi
fi

echo
if [[ "$failed" == "0" ]]; then
  echo "✅ Custom nodes ready → $DEST"
else
  echo "⚠ Finished with problems — some packs may not load. See warnings above." >&2
fi
exit "$failed"
