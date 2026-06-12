#!/usr/bin/env bash
# Find the newest AMD ROCm nightly (gfx1151) whose torch stack passes a GPU
# smoke test, without rebuilding the toolbox image.
#
# Each candidate is tested in a throwaway fedora container with GPU devices:
#   1. rocminfo detects gfx1151
#   2. torch.cuda.is_available()
#   3. a small matmul on the GPU
# This is exactly the class of breakage seen in the 2026-06-12 nightly
# (rocminfo/torch.cuda segfault on Strix Halo).
set -euo pipefail

INDEX_BASE="https://rocm.nightlies.amd.com/v2-staging/gfx1151"
PYTAG="cp313"
BASE_IMAGE="registry.fedoraproject.org/fedora:rawhide"
MAX_CANDIDATES=5
SMOKE_TIMEOUT=120

usage() {
  cat <<'USAGE'
Usage: find-good-nightly.sh [--max N] [--list] [SUFFIX]

Finds the newest ROCm nightly whose torch/torchaudio/torchvision wheels pass
a GPU smoke test in a throwaway container (downloads ~4-5 GB per candidate;
nothing is cached or left behind).

  --max N   Test at most N candidates, newest first (default: 5)
  --list    Only print available complete candidates (no downloads)
  SUFFIX    Test a single nightly, e.g. 7.13.0a20260323

On success prints ready-to-paste 'podman build --build-arg' flags.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

preflight() {
  command -v podman >/dev/null 2>&1 || die "podman is required"
  [[ -e /dev/kfd ]] || die "/dev/kfd not found — no AMD GPU compute device on this host"
}

# Print "BASE SUFFIX" pairs for one package, e.g. "2.12.0a0 7.13.0a20260323".
# Handles both literal '+' and URL-encoded '%2B' in wheel filenames.
pkg_versions() {
  local pkg="$1"
  curl -fsSL "$INDEX_BASE/$pkg/" \
    | grep -oE "${pkg}-[0-9][^\"<>#]*-${PYTAG}-[^\"<>#]*linux_x86_64\.whl" \
    | sed -E "s/^${pkg}-([0-9][^+%]*)(\+|%2B)rocm([0-9a-zA-Z.]+)-${PYTAG}.*/\1 \3/" \
    | sort -u
}

# Print complete candidates "SUFFIX TORCH TORCHAUDIO TORCHVISION", newest
# first. A nightly hosts several release streams per package (e.g. torch
# 2.9.1 … 2.13.0a0 under one suffix); pick the highest base version of each
# package, which is what an unpinned `pip install --pre` would resolve to.
candidates() {
  local torch ta tv suffix tb ab vb
  torch="$(pkg_versions torch)"    || die "cannot list torch wheels from $INDEX_BASE/torch/"
  ta="$(pkg_versions torchaudio)"  || die "cannot list torchaudio wheels from $INDEX_BASE/torchaudio/"
  tv="$(pkg_versions torchvision)" || die "cannot list torchvision wheels from $INDEX_BASE/torchvision/"
  [[ -n "$torch" ]] || die "no ${PYTAG} torch wheels parsed from the index"
  highest_for() { awk -v s="$2" '$2==s{print $1}' <<<"$1" | sort -V | tail -1; }
  while read -r suffix; do
    tb="$(highest_for "$torch" "$suffix")"
    ab="$(highest_for "$ta" "$suffix")"
    vb="$(highest_for "$tv" "$suffix")"
    if [[ -n "$tb" && -n "$ab" && -n "$vb" ]]; then
      printf '%s %s %s %s\n' "$suffix" "$tb" "$ab" "$vb"
    fi
  done < <(awk '{print $2}' <<<"$torch" | sort -u | sort -rV)
}

# Install the candidate triple in a throwaway GPU container and smoke-test it.
# PIP_NO_CACHE_DIR=1 + --rm means nothing survives the test, pass or fail.
test_candidate() {
  local suffix="$1" tb="$2" ab="$3" vb="$4"
  echo "==> Testing rocm${suffix} (torch ${tb}, torchaudio ${ab}, torchvision ${vb})"
  podman run --rm -i \
    --ipc host \
    --device /dev/dri --device /dev/kfd \
    --security-opt seccomp=unconfined \
    -e PIP_NO_CACHE_DIR=1 \
    -e INDEX_BASE="$INDEX_BASE" \
    -e SMOKE_TIMEOUT="$SMOKE_TIMEOUT" \
    -e TORCH_PIN="torch==${tb}+rocm${suffix}" \
    -e TA_PIN="torchaudio==${ab}+rocm${suffix}" \
    -e TV_PIN="torchvision==${vb}+rocm${suffix}" \
    "$BASE_IMAGE" bash -s <<'INNER'
set -euo pipefail
dnf -y -q install --setopt=install_weak_deps=False --nodocs python3.13 libatomic libdrm >/dev/null
python3.13 -m venv /venv
echo "  installing wheels (several GB, be patient)..."
/venv/bin/pip install -q --index-url "$INDEX_BASE" --pre "$TORCH_PIN" "$TA_PIN" "$TV_PIN"
timeout "$SMOKE_TIMEOUT" /venv/bin/rocminfo | grep -q gfx1151
echo "  rocminfo: gfx1151 detected"
timeout "$SMOKE_TIMEOUT" /venv/bin/python - <<'PY'
import torch
assert torch.cuda.is_available(), "torch.cuda.is_available() is False"
x = torch.rand(64, 64, device="cuda")
print("  matmul ok:", (x @ x).sum().item())
PY
INNER
}

print_build_args() {
  local suffix="$1" tb="$2" ab="$3" vb="$4"
  echo
  echo "GOOD nightly: rocm${suffix}"
  echo
  echo "Build with:"
  echo "  podman build \\"
  echo "    --build-arg TORCH_VERSION=${tb}+rocm${suffix} \\"
  echo "    --build-arg TORCHAUDIO_VERSION=${ab}+rocm${suffix} \\"
  echo "    --build-arg TORCHVISION_VERSION=${vb}+rocm${suffix} \\"
  echo "    -t docker.io/kyuz0/amd-strix-halo-comfyui:latest ."
}

main() {
  local list_only=0 single=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max) MAX_CANDIDATES="${2:?--max needs a number}"; shift 2 ;;
      --list) list_only=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; exit 1 ;;
      *) single="$1"; shift ;;
    esac
  done

  command -v curl >/dev/null 2>&1 || die "curl is required"
  local all
  all="$(candidates)"
  [[ -n "$all" ]] || die "no complete torch/torchaudio/torchvision candidates found"

  if (( list_only )); then
    printf '%-22s %-12s %-12s %s\n' SUFFIX TORCH TORCHAUDIO TORCHVISION
    awk '{printf "%-22s %-12s %-12s %s\n", $1, $2, $3, $4}' <<<"$all"
    exit 0
  fi

  preflight

  local pool="$all"
  if [[ -n "$single" ]]; then
    pool="$(awk -v s="$single" '$1==s' <<<"$all")"
    [[ -n "$pool" ]] || die "no complete candidate for suffix '$single' (see --list)"
    MAX_CANDIDATES=1
  fi

  local n=0 suffix tb ab vb
  while read -r suffix tb ab vb; do
    if (( n >= MAX_CANDIDATES )); then break; fi
    n=$((n+1))
    if test_candidate "$suffix" "$tb" "$ab" "$vb"; then
      print_build_args "$suffix" "$tb" "$ab" "$vb"
      exit 0
    fi
    echo "BAD: rocm${suffix}"
  done <<<"$pool"

  die "no good nightly in the ${n} candidate(s) tested; try --max $((MAX_CANDIDATES * 2)) or an explicit SUFFIX"
}

main "$@"
