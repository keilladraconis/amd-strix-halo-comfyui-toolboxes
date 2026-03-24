#!/usr/bin/env bash
# install_workflows.sh – Copy bundled workflows into the ComfyUI user directory.
#
# Copies depth-1 workflow JSONs from /opt/comfy-workflows/ (not subdirs like
# API/ or input/) to $HOME/comfy-ui/user/default/workflows/.  Existing files
# are overwritten so updates take effect on container refresh.
set -euo pipefail

SRC="/opt/comfy-workflows"
DEST="${COMFY_BASE_DIR:-$HOME/comfy-ui}/user/default/workflows"

mkdir -p "$DEST"

count=0
for f in "$SRC"/*.json; do
    [[ -f "$f" ]] || continue
    cp "$f" "$DEST/"
    (( count++ )) || true
done

echo "✅ Installed $count workflow(s) → $DEST"
