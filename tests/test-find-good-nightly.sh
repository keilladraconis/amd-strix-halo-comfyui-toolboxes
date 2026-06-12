#!/usr/bin/env bash
# Unit tests for find-good-nightly.sh's search logic. No podman, no network:
# test_candidate is replaced with a lookup into a fake verdict table.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); echo "ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got     : $3"
  fi
}

# scenario GOOD_FROM MAX
# Runs search over 100 fake candidates s000 (newest) .. s099 (oldest).
# Candidates with numeric index >= GOOD_FROM are good (-1 = all bad).
# Sets: OUT (combined output), RC (exit code), TESTED (space-joined suffixes
# in test order).
scenario() {
  local good_from="$1" max="$2" tlog
  tlog="$(mktemp)"
  OUT="$( (
    source ./find-good-nightly.sh
    FAKE_GOOD_FROM="$good_from"
    TESTED_LOG="$tlog"
    test_candidate() {
      echo "$1" >>"$TESTED_LOG"
      local n=$((10#${1#s}))
      (( FAKE_GOOD_FROM >= 0 && n >= FAKE_GOOD_FROM ))
    }
    MAX_CANDIDATES="$max"
    CAND=()
    local i
    for i in $(seq 0 99); do CAND+=("$(printf 's%03d 1.0 1.1 1.2' "$i")"); done
    search
  ) 2>&1 )"
  RC=$?
  TESTED="$(tr '\n' ' ' <"$tlog")"; TESTED="${TESTED% }"
  rm -f "$tlog"
}

# 1. Newest build already good: one test, immediate result.
scenario 0 0
check "newest-good rc" 0 "$RC"
check "newest-good tested sequence" "s000" "$TESTED"
check "newest-good result" 1 "$(grep -c 'GOOD nightly: rocms000' <<<"$OUT")"

# 2. Good from index 50: fib hops 0,1,2,4,7,12,20,33,54 then bisect to 50.
scenario 50 0
check "fib+bisect rc" 0 "$RC"
check "fib+bisect tested sequence" \
  "s000 s001 s002 s004 s007 s012 s020 s033 s054 s043 s048 s051 s049 s050" \
  "$TESTED"
check "fib+bisect result" 1 "$(grep -c 'GOOD nightly: rocms050' <<<"$OUT")"

# 3. All bad: hops clamp to the oldest (99), then fail with exit 1.
scenario -1 0
check "all-bad rc" 1 "$RC"
check "all-bad tested sequence" \
  "s000 s001 s002 s004 s007 s012 s020 s033 s054 s088 s099" "$TESTED"

# 3b. Good found at the clamped oldest index, then bisect inside (88,99).
scenario 95 0
check "clamp-good rc" 0 "$RC"
check "clamp-good tested sequence" \
  "s000 s001 s002 s004 s007 s012 s020 s033 s054 s088 s099 s093 s096 s094 s095" \
  "$TESTED"
check "clamp-good result" 1 "$(grep -c 'GOOD nightly: rocms095' <<<"$OUT")"

# 4. Budget exhausted AFTER a good build is known: report it, exit 0.
scenario 50 9
check "budget-good rc" 0 "$RC"
check "budget-good tested sequence" \
  "s000 s001 s002 s004 s007 s012 s020 s033 s054" "$TESTED"
check "budget-good reports best" 1 "$(grep -c 'GOOD nightly: rocms054' <<<"$OUT")"
check "budget-good notes newer may exist" 1 "$(grep -c 'newer good nightly may exist' <<<"$OUT")"

# 5. Budget exhausted with NO good known: exit 1.
scenario -1 3
check "budget-nogood rc" 1 "$RC"
check "budget-nogood tested sequence" "s000 s001 s002" "$TESTED"
check "budget-nogood message" 1 "$(grep -c 'No good nightly confirmed yet' <<<"$OUT")"

echo
echo "passed: $PASS, failed: $FAIL"
exit "$(( FAIL > 0 ))"
