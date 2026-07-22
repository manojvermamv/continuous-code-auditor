#!/usr/bin/env bash
# scripts/commands/status.sh — /continuous-code-auditor-status
#
# Read-only. Prints a summary of current state: pause/hold state, lock
# state, last execution outcome, consecutive failures, and a findings
# summary if metrics.json exists. Safe to run any time, changes nothing.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo "== continuous-code-auditor status =="
echo "agent CLI:      $AGENT_CLI"
echo "project:        $PROJECT"
echo "audit target:   $AUDIT_TARGET"
echo

if [[ -f "$HELD_FLAG" ]]; then
  echo "circuit breaker: HELD — $(cat "$HELD_FLAG")"
elif [[ -f "$PAUSED_FLAG" ]]; then
  echo "schedule:       PAUSED — $(cat "$PAUSED_FLAG")"
else
  echo "schedule:       active (not paused, breaker not held)"
fi

if [[ -f "$LOCK" ]]; then
  if command -v flock >/dev/null 2>&1 && flock -n "$LOCK" true 2>/dev/null; then
    echo "lock:           free"
  else
    if [[ -s "$LOCK.meta" ]]; then
      echo "lock:           HELD by $(cat "$LOCK.meta")"
    else
      echo "lock:           HELD (no metadata found)"
    fi
  fi
else
  echo "lock:           not yet created (no execution has run)"
fi

if [[ -s "$LOG_DIR/consecutive_failures.txt" ]]; then
  echo "consecutive failures: $(cat "$LOG_DIR/consecutive_failures.txt")"
fi

echo
echo "-- last few log lines (logs/auditor.log) --"
if [[ -f "$LOG_DIR/auditor.log" ]]; then
  tail -n 5 "$LOG_DIR/auditor.log"
else
  echo "(no executions logged yet)"
fi

if [[ -f "$PROJECT/work/heartbeat.json" ]]; then
  echo
  echo "-- work/heartbeat.json --"
  cat "$PROJECT/work/heartbeat.json"
fi

if [[ -f "$PROJECT/work/metrics.json" ]]; then
  echo
  echo "-- work/metrics.json --"
  cat "$PROJECT/work/metrics.json"
fi

echo
echo "(This is mechanical status only — file counts and log tails. For an actual"
echo " findings summary in prose, ask your agent to read work/continuous_code_audit_closure_report.md.)"
