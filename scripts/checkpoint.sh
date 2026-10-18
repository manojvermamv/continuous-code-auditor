#!/usr/bin/env bash
# scripts/checkpoint.sh
#
# Captures one hourly alignment checkpoint: a deterministic snapshot of where
# the project and the audit stand, appended to work/checkpoints/timeline.jsonl.
#
# DELIBERATELY CONTAINS NO MODEL CALL. Three reasons, and they matter:
#
#   1. Cost. Hourly model invocations for a year is ~8,760 calls to answer a
#      question that changes slowly.
#   2. Determinism. A trajectory assembled from model judgements would itself
#      drift — you could not tell project drift from measurement drift, which
#      defeats the purpose.
#   3. Independence. These numbers are collected the same way regardless of
#      what the model believes about its own performance. The model reads the
#      trajectory; it does not produce it.
#
# The model's interpretation happens separately and less often — see
# SKILL.md "Alignment review" and scripts/commands/alignment.sh.
#
# Safe to run at any time, including mid-audit: read-only with respect to
# everything except its own checkpoint file.
#
# Usage: checkpoint.sh

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
[[ -f "$CONFIG_FILE" ]] || { echo "checkpoint: no config at $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=../config/auditor.conf.example
source "$CONFIG_FILE"

PROJECT="${PROJECT:-}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
AUDIT_TARGET="${AUDIT_TARGET:-.}"
[[ -n "$PROJECT" && -d "$PROJECT" ]] || { echo "checkpoint: PROJECT not set or missing" >&2; exit 1; }

CP_DIR="$PROJECT/work/checkpoints"
TIMELINE="$CP_DIR/timeline.jsonl"
BASELINE="$CP_DIR/baseline.json"
CHARTER="${CHARTER_FILE:-$SKILL_DIR/config/charter.md}"
mkdir -p "$CP_DIR"

REGISTER="$PROJECT/work/continuous_code_audit_findings.md"
STATE="$PROJECT/work/audit_state.json"

# --- signals ------------------------------------------------------------
# Everything here is a count or a hash: cheap, repeatable, and meaningful
# only in comparison to other checkpoints. A single checkpoint says almost
# nothing; the sequence is the artifact.

count_status() {
  [[ -f "$REGISTER" ]] || { echo 0; return; }
  # `grep -c` prints "0" AND exits non-zero when nothing matches. A trailing
  # `|| echo 0` therefore emits a SECOND zero, producing "0\n0" — which
  # silently corrupts every JSON record. Capture first, then default.
  local n
  n="$(grep -ciE "(^|[^a-z])$1([^a-z]|$)" "$REGISTER" 2>/dev/null)" || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

charter_hash="none"
charter_present=false
if [[ -f "$CHARTER" ]]; then
  charter_present=true
  charter_hash="$(sha256sum "$CHARTER" 2>/dev/null | cut -c1-16)"
fi

# Audit target identity — detects scope change (the target itself moving is
# a legitimate form of direction change, and one worth seeing on a timeline).
target_files=0
target_bytes=0
if [[ "$AUDIT_TARGET" == "." ]]; then
  target_files="$(find "$PROJECT" -type f -not -path '*/work/*' -not -path '*/archives/*' -not -path '*/backups/*' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
  target_bytes="$(find "$PROJECT" -type f -not -path '*/work/*' -not -path '*/archives/*' -not -path '*/backups/*' -not -path '*/.git/*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
else
  for t in $AUDIT_TARGET; do
    case "$t" in /*) p="$t" ;; *) p="$PROJECT/$t" ;; esac
    if [[ -f "$p" ]]; then
      target_files=$((target_files + 1))
      target_bytes=$((target_bytes + $(stat -c%s "$p" 2>/dev/null || echo 0)))
    fi
  done
fi

open_n="$(count_status 'Open')"
verified_n="$(count_status 'Verified-in-code')"
runtime_n="$(count_status 'Verified-runtime')"
intentional_n="$(count_status 'Closed-as-intentional')"
contradiction_n="$(count_status 'Contradiction-Flagged')"
deferred_n="$(count_status 'Deferred-Human-Review')"

executions=0
if [[ -f "$PROJECT/work/metrics.json" ]] && command -v python3 >/dev/null 2>&1; then
  executions="$(python3 -c "
import json
try: print(json.load(open('$PROJECT/work/metrics.json')).get('executions', 0))
except Exception: print(0)
" 2>/dev/null || echo 0)"
fi

schema_v=0
if [[ -f "$STATE" ]] && command -v python3 >/dev/null 2>&1; then
  schema_v="$(python3 -c "
import json
try: print(json.load(open('$STATE')).get('schema_version', 0))
except Exception: print(0)
" 2>/dev/null || echo 0)"
fi

AUDITOR_VERSION="$(grep -m1 -oE '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$SKILL_DIR/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo unknown)"

RECORD="$(printf '{"ts":"%s","auditor_version":"%s","charter_present":%s,"charter_hash":"%s","target_files":%s,"target_bytes":%s,"findings":{"open":%s,"verified_in_code":%s,"verified_runtime":%s,"closed_intentional":%s,"contradiction_flagged":%s,"deferred":%s},"executions":%s,"schema_version":%s}' \
  "$(date -Iseconds)" "$AUDITOR_VERSION" "$charter_present" "$charter_hash" \
  "$target_files" "$target_bytes" \
  "$open_n" "$verified_n" "$runtime_n" "$intentional_n" "$contradiction_n" "$deferred_n" \
  "$executions" "$schema_v")"

# The FIRST checkpoint is the baseline and is written once, separately, and
# never pruned. "Initial to latest" is the whole question this system exists
# to answer, so the initial point must be structurally impossible to lose —
# same reasoning as the evidence guard in archive retention.
if [[ ! -f "$BASELINE" ]]; then
  printf '%s\n' "$RECORD" > "$BASELINE"
fi

printf '%s\n' "$RECORD" >> "$TIMELINE"

# Retention: hourly forever is 8,760 records a year. Keep the most recent
# window; the baseline lives in its own file and is unaffected.
KEEP="${CHECKPOINT_RETENTION:-2000}"
if [[ "$KEEP" -gt 0 ]]; then
  lines="$(wc -l < "$TIMELINE" 2>/dev/null || echo 0)"
  if [[ "$lines" -gt "$KEEP" ]]; then
    tmp="$(mktemp)"
    tail -n "$KEEP" "$TIMELINE" > "$tmp"
    mv -f "$tmp" "$TIMELINE"
  fi
fi

echo "checkpoint recorded: $(date -Iseconds)"
[[ "$charter_present" == false ]] && \
  echo "note: no charter at $CHARTER — alignment can be tracked but not judged. See config/charter.md.example." >&2
exit 0
