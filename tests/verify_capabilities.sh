#!/usr/bin/env bash
# tests/verify_capabilities.sh
#
# Asserts that adapters/capabilities.json matches what the adapters actually
# do — probed behaviorally by tests/lib/adapter_harness.sh, not read off the
# source.
#
# This is the mechanism that makes the capability matrix trustworthy. Without
# it the matrix is just prose in JSON clothing: it would describe reality on
# the day it was written and quietly diverge from then on, which is worse
# than no matrix at all because tooling would believe it.
#
# Also checks the inverse direction — every adapter has an entry, and every
# entry has an adapter — so neither adding nor removing an adapter can leave
# the matrix silently incomplete.
#
# Usage: tests/verify_capabilities.sh [skill-dir]
# Exit 0 if the matrix is accurate, 1 otherwise.

set -uo pipefail

SKILL_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MATRIX="$SKILL_DIR/adapters/capabilities.json"
# shellcheck source=lib/adapter_harness.sh
source "$SKILL_DIR/tests/lib/adapter_harness.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$MATRIX" ]]; then
  echo "FAIL: no capability matrix at $MATRIX"
  exit 1
fi
if ! python3 -c "import json,sys; json.load(open('$MATRIX'))" 2>/dev/null; then
  echo "FAIL: $MATRIX is not valid JSON"
  exit 1
fi

echo "== adapter capability verification =="
echo "matrix: $MATRIX"
echo

# --- completeness, both directions -------------------------------------
DECLARED="$(python3 -c "
import json
print(' '.join(sorted(json.load(open('$MATRIX'))['adapters'])))
")"
ACTUAL="$(for f in "$SKILL_DIR"/scripts/runners/run_with_*.sh; do
  basename "$f" .sh | sed 's/run_with_//'
done | sort | tr '\n' ' ')"

echo "-- completeness --"
for a in $ACTUAL; do
  case " $DECLARED " in
    *" $a "*) ok "adapter '$a' has a matrix entry" ;;
    *)        bad "adapter '$a' exists but is MISSING from capabilities.json" ;;
  esac
done
for d in $DECLARED; do
  case " $ACTUAL " in
    *" $d "*) : ;;
    *)        bad "capabilities.json declares '$d' but no such runner exists" ;;
  esac
done

# --- behavioral verification -------------------------------------------
echo
echo "-- declared vs. observed behavior --"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for adapter in $ACTUAL; do
  fixtures="$TMP/$adapter"
  make_fixtures "$fixtures" "$adapter"
  observed="$(probe_adapter "$SKILL_DIR" "$adapter" "$fixtures")"

  for field in session_continuity cost_reporting failure_detection requires_jq; do
    obs="$(printf '%s\n' "$observed" | grep "^${field}=" | cut -d= -f2-)"
    dec="$(python3 -c "
import json
v = json.load(open('$MATRIX'))['adapters']['$adapter'].get('$field')
print(str(v).lower() if isinstance(v, bool) else v)
" 2>/dev/null)"
    if [[ "$obs" == "$dec" ]]; then
      ok "$adapter.$field = $dec (observed matches declared)"
    else
      bad "$adapter.$field: declared '$dec' but observed '$obs' — capabilities.json is out of date, or the adapter changed behavior"
    fi
  done
done

echo
echo "===================="
echo "PASS: $PASS   FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "The capability matrix does not match reality. Fix whichever is wrong —"
  echo "the matrix is only useful if tooling can trust it."
fi
echo "===================="
[[ "$FAIL" -eq 0 ]]
