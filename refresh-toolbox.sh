#!/usr/bin/env bash

NAME="amd-strix-halo-comfyui"
IMAGE="docker.io/kyuz0/amd-strix-halo-comfyui:latest"
REPO="${IMAGE%:*}"  # docker.io/kyuz0/amd-strix-halo-comfyui
CHANNEL="${CHANNEL:-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Channel selection (latest / dev) ---
resolve_channel() {
    local arg="${1:-}"
    case "$arg" in
        latest)  echo "latest" ;;
        dev)     echo "dev" ;;
        "")
            # Interactive menu
            echo "" >&2
            echo "Which image channel do you want?" >&2
            echo "  1) latest  — Stable build (recommended)" >&2
            echo "  2) dev     — Development build (may be unstable)" >&2
            echo "" >&2
            read -rp "Choice [1]: " choice
            case "${choice:-1}" in
                1|latest)  echo "latest" ;;
                2|dev)     echo "dev" ;;
                *)
                    echo "Invalid choice: $choice" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Usage: $0 [latest|dev]" >&2
            echo "  latest  — Pull the stable build (default)" >&2
            echo "  dev     — Pull the development build" >&2
            exit 1
            ;;
    esac
}

# Parse args
VALID_ARGS=$(getopt -o lc: --long local,channel: -- "$@")

eval set -- "$VALID_ARGS"
while [ : ]; do
    case "$1" in
        -l | --local)
            LOCAL=1
            shift
            ;;
        -c | --channel)
            CHANNEL="$(resolve_channel "${2:-}")"
            shift
            ;;
        --) shift ;
            break
            ;;
    esac
done


LOCAL=0
for arg in "$@"; do
  [[ "$arg" == "--local" || "$arg" == "local" ]] && LOCAL=1
done

TOOLBOX_ARGS=(
  -- --device /dev/dri --device /dev/kfd
     --group-add video --group-add render
     --security-opt seccomp=unconfined
)

if [[ "$LOCAL" == "1" ]]; then
  echo "Building local image from $SCRIPT_DIR/Dockerfile ..."
  podman build -t "$IMAGE" "$SCRIPT_DIR"

  echo "Recreating toolbox $NAME from local build ..."
  toolbox rm -f "$NAME" 2>/dev/null || true
  toolbox create "$NAME" --image "$IMAGE" "${TOOLBOX_ARGS[@]}"

  echo "Done."
  exit 0
fi

TOOLBOX_NAME="amd-strix-halo-comfyui"
IMAGE_REPO="docker.io/kyuz0/amd-strix-halo-comfyui"
IMAGE="${IMAGE_REPO}:${CHANNEL}"

# Base options
OPTIONS="--device /dev/dri --device /dev/kfd --group-add video --group-add render --security-opt seccomp=unconfined"

# Detect container manager (toolbox requires podman; distrobox works with either)
if command -v toolbox &>/dev/null && command -v podman &>/dev/null; then
    MANAGER="toolbox"
elif command -v distrobox &>/dev/null; then
    MANAGER="distrobox"
else
    echo "Error: neither 'toolbox' (with podman) nor 'distrobox' is installed." >&2
    exit 1
fi

# Detect container runtime for image pull and cleanup
if command -v podman &>/dev/null; then
    RUNTIME="podman"
elif command -v docker &>/dev/null; then
    RUNTIME="docker"
else
    echo "Error: neither 'podman' nor 'docker' is installed." >&2
    exit 1
fi

# --- Check if already up-to-date ---
# Only compare if we have skopeo and jq, otherwise just pull
if command -v skopeo &>/dev/null && command -v jq &>/dev/null; then
    echo "🔎 Checking for remote updates..."
    local_digest="$($RUNTIME image inspect --format '{{.Digest}}' "$IMAGE" 2>/dev/null || true)"
    remote_digest="$(skopeo inspect docker://$IMAGE 2>/dev/null | jq -r '.Digest' || true)"
    
    if [[ -n "$remote_digest" && "$remote_digest" != "null" && "$local_digest" == "$remote_digest" ]]; then
        echo "Already up to date."
        # If the container itself doesn't exist, we should still recreate it!
        if ! $MANAGER list 2>/dev/null | grep -q "$TOOLBOX_NAME"; then
            echo "Container $TOOLBOX_NAME is missing. Creating it now..."
        else
            exit 0
        fi
    fi
fi

echo "🔄 Refreshing $TOOLBOX_NAME via $MANAGER (channel: $CHANNEL, image: $IMAGE)"
toolbox rm -f "$NAME" 2>/dev/null || true
toolbox create "$NAME" \
  --image "$IMAGE" \
  "${TOOLBOX_ARGS[@]}"

# Remove existing container if it exists
if $MANAGER list 2>/dev/null | grep -q "$TOOLBOX_NAME"; then
    echo "🧹 Removing existing $MANAGER: $TOOLBOX_NAME"
    $MANAGER rm -f "$TOOLBOX_NAME"
fi

echo "⬇️ Pulling image: $IMAGE"
$RUNTIME pull "$IMAGE"

# Identify current image ID/digest for cleanup
new_id="$($RUNTIME image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
new_digest="$($RUNTIME image inspect --format '{{.Digest}}' "$IMAGE" 2>/dev/null || true)"

echo "📦 Recreating $MANAGER: $TOOLBOX_NAME"
echo "   Options: $OPTIONS"

if [ "$MANAGER" = "toolbox" ]; then
    # toolbox passes extra flags to podman via '--'
    toolbox create "$TOOLBOX_NAME" --image "$IMAGE" -- $OPTIONS
else
    # distrobox passes extra flags via --additional-flags
    distrobox create -n "$TOOLBOX_NAME" --image "$IMAGE" --additional-flags "$OPTIONS"
fi

# --- Cleanup: keep only the most recent image for this tag ---
repo="${IMAGE%:*}"

while read -r id ref dig; do
    if [[ "$id" != "$new_id" ]]; then
        $RUNTIME image rm -f "$id" >/dev/null 2>&1 || true
    fi
done < <($RUNTIME images --digests --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Digest}}' \
         | awk -v ref="$IMAGE" -v ndig="$new_digest" '$2==ref && $3!=ndig')

while read -r id; do
    $RUNTIME image rm -f "$id" >/dev/null 2>&1 || true
done < <($RUNTIME images --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
         | awk -v r="$repo" '$2==r":<none>" {print $1}')
# --- end cleanup ---

echo "✅ $TOOLBOX_NAME refreshed (channel: $CHANNEL)"
