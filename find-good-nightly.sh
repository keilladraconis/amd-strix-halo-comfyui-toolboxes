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
MAX_CANDIDATES=0
SMOKE_TIMEOUT=120
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the result is written for refresh-toolbox.sh --local to consume.
# Env-overridable so unit tests write to a tempfile instead of the checkout.
OVERRIDES_FILE="${OVERRIDES_FILE:-$SCRIPT_DIR/nightly-overrides.conf}"

usage() {
  cat <<'USAGE'
Usage: find-good-nightly.sh [--max N] [--list] [SUFFIX]

Finds the newest ROCm nightly whose torch/torchaudio/torchvision wheels pass
a GPU smoke test in a throwaway container (downloads ~4-5 GB per candidate;
nothing is cached or left behind).

Search: Fibonacci hops backwards from the newest build until a good one is
found, then binary-searches the bad..good bracket for the newest good build.
Runs until a result is found; interrupt (Ctrl-C) at any time to get the best
result so far.

  --max N   Test at most N candidates in total (default: unlimited)
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

# Write the winning triple to OVERRIDES_FILE (gitignored) so the dumbest
# possible consumer just runs ./refresh-toolbox.sh --local. Called from both
# success paths: the full bisect result and report_partial's good-known branch.
write_overrides() {
  local suffix="$1" tb="$2" ab="$3" vb="$4"
  cat >"$OVERRIDES_FILE" <<EOF
# Written by find-good-nightly.sh — newest ROCm nightly that passed the GPU
# smoke test. Consumed by ./refresh-toolbox.sh --local. To revert to the
# Dockerfile defaults, delete this file. This file is gitignored.
TORCH_VERSION=${tb}+rocm${suffix}
TORCHAUDIO_VERSION=${ab}+rocm${suffix}
TORCHVISION_VERSION=${vb}+rocm${suffix}
EOF
  echo
  echo "Wrote ${OVERRIDES_FILE##*/} — apply it with: ./refresh-toolbox.sh --local"
}

# ── Search state ──────────────────────────────────────────────────────────
# CAND: "SUFFIX TORCH TORCHAUDIO TORCHVISION" lines, newest first (index 0
# = newest). BEST_GOOD is the smallest (newest) index confirmed good so far.
# No index is tested twice by construction: phase-1 indices strictly
# increase, and the bisect only probes strictly inside the (lo, g) interval.
declare -a CAND=()
TESTS_RUN=0
BEST_GOOD=-1

# Report the best-known result and exit. Used on SIGINT and when --max is
# exhausted mid-search.
report_partial() {
  echo
  if (( BEST_GOOD >= 0 )); then
    local suffix tb ab vb
    read -r suffix tb ab vb <<<"${CAND[$BEST_GOOD]}"
    echo "Search stopped early. Newest CONFIRMED good build so far:"
    print_build_args "$suffix" "$tb" "$ab" "$vb"
    write_overrides "$suffix" "$tb" "$ab" "$vb"
    echo
    echo "Note: a newer good nightly may exist (bracket not fully bisected);"
    echo "re-run with a higher --max or test an explicit SUFFIX."
    # Deliberate: a confirmed-good pin is a usable result, so exit 0 even though the bracket wasn't fully bisected.
    exit 0
  fi
  echo "Search stopped early. No good nightly confirmed yet."
  exit 1
}

# Budget-gated wrapper around test_candidate.
# Returns 0 (good) / 1 (bad). Exits via report_partial on budget exhaustion.
run_test() {
  local idx="$1" suffix tb ab vb
  if (( MAX_CANDIDATES > 0 && TESTS_RUN >= MAX_CANDIDATES )); then
    echo "Test budget (--max ${MAX_CANDIDATES}) exhausted."
    report_partial
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
  read -r suffix tb ab vb <<<"${CAND[$idx]}"
  if test_candidate "$suffix" "$tb" "$ab" "$vb"; then
    return 0
  fi
  echo "BAD: rocm${suffix}"
  return 1
}

# Phase 1: Fibonacci hops (offsets 1,1,2,3,5,8,... => indices 0,1,2,4,7,
# 12,20,...) until a good build is found, clamping the last hop to the
# oldest candidate. Phase 2: classic bisect of the (newest-bad, good)
# bracket down to the newest good index. Assumes monotonicity within the
# bracket (accepted trade-off: on patchy quality the result may be slightly
# older than the true newest good build).
search() {
  local total=${#CAND[@]} lo=-1 g=-1 idx=0 a=1 b=1 t suffix tb ab vb
  while :; do
    if run_test "$idx"; then
      g=$idx; BEST_GOOD=$idx
      break
    fi
    lo=$idx
    if (( idx >= total - 1 )); then
      die "all ${TESTS_RUN} tested candidates are bad, including the oldest available; the index may be entirely broken for gfx1151"
    fi
    idx=$((idx + a)); t=$((a + b)); a=$b; b=$t
    if (( idx > total - 1 )); then idx=$((total - 1)); fi
  done
  while (( g - lo > 1 )); do
    idx=$(( (lo + g) / 2 ))
    if run_test "$idx"; then g=$idx; BEST_GOOD=$idx; else lo=$idx; fi
  done
  read -r suffix tb ab vb <<<"${CAND[$g]}"
  print_build_args "$suffix" "$tb" "$ab" "$vb"
  write_overrides "$suffix" "$tb" "$ab" "$vb"
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

  mapfile -t CAND <<<"$all"

  if [[ -n "$single" ]]; then
    local line suffix tb ab vb
    line="$(awk -v s="$single" '$1==s' <<<"$all")"
    [[ -n "$line" ]] || die "no complete candidate for suffix '$single' (see --list)"
    read -r suffix tb ab vb <<<"$line"
    if test_candidate "$suffix" "$tb" "$ab" "$vb"; then
      print_build_args "$suffix" "$tb" "$ab" "$vb"
      exit 0
    fi
    echo "BAD: rocm${suffix}"
    exit 1
  fi

  trap report_partial INT
  search
}

# Source guard: running the script executes main; sourcing it (tests) only
# defines functions and state.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
