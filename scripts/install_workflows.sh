#!/usr/bin/env bash
# install_workflows.sh – Copy bundled workflows into the ComfyUI user directory.
#
# Copies depth-1 workflow JSONs from /opt/comfy-workflows/ (not subdirs like
# API/ or input/) to $HOME/comfy-ui/user/default/workflows/.  Existing files
# are overwritten so updates take effect on container refresh.
#
# Usage:
#   install_workflows              Copy now, overwriting existing files
#   install_workflows --if-needed  Copy only once per image (see below)
#
# start_comfy_ui passes --if-needed so a fresh toolbox always has the bundled
# workflows, without re-copying on every launch. Re-copying every time would
# overwrite edits you saved to a bundled workflow, since ComfyUI saves back to
# the same filename. The stamp lives in the image, not in $HOME, so recreating
# the toolbox re-installs the workflows -- which is exactly when the bundled
# copies may have changed.
set -euo pipefail

SRC="${SRC:-/opt/comfy-workflows}"
DEST="${COMFY_BASE_DIR:-$HOME/comfy-ui}/user/default/workflows"
STAMP="${STAMP:-/opt/venv/.workflows-installed}"

IF_NEEDED=0
case "${1:-}" in
    --if-needed) IF_NEEDED=1 ;;
    "")          ;;
    -h|--help|help)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: install_workflows [--if-needed]" >&2
        exit 1
        ;;
esac

if [[ "$IF_NEEDED" == "1" && -f "$STAMP" ]]; then
    exit 0
fi

mkdir -p "$DEST"

count=0
for f in "$SRC"/*.json; do
    [[ -f "$f" ]] || continue
    cp "$f" "$DEST/"
    (( count++ )) || true
done

: > "$STAMP" 2>/dev/null || true

echo "✅ Installed $count workflow(s) → $DEST"
