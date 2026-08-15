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

if [[ -s "$LOG_DIR/cumulative_cost_usd.txt" ]]; then
  if [[ -n "${CUMULATIVE_BUDGET_USD:-}" ]]; then
    echo "cumulative spend: \$$(cat "$LOG_DIR/cumulative_cost_usd.txt") of \$$CUMULATIVE_BUDGET_USD budget"
  else
    echo "cumulative spend: \$$(cat "$LOG_DIR/cumulative_cost_usd.txt") (no CUMULATIVE_BUDGET_USD set)"
  fi
fi

if command -v df >/dev/null 2>&1; then
  AVAIL_MB="$(df -Pm "$PROJECT" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$AVAIL_MB" ]] && echo "disk free:      ${AVAIL_MB}MB (minimum: ${MIN_FREE_DISK_MB:-100}MB)"
fi

if [[ -r /proc/loadavg && -n "${MAX_LOAD_PER_CPU:-4.0}" ]]; then
  L1="$(awk '{print $1}' /proc/loadavg)"
  NCPU="$(nproc 2>/dev/null || echo 1)"
  THR="$(awk -v m="${MAX_LOAD_PER_CPU:-4.0}" -v c="$NCPU" 'BEGIN{printf "%.2f", m*c}')"
  echo "load:           $L1 (defer above: $THR)"
fi

if [[ -f "$LOG_DIR/watchdog.log" ]]; then
  echo "watchdog:       last check — $(tail -n 1 "$LOG_DIR/watchdog.log")"
else
  echo "watchdog:       no checks logged yet (is continuous-code-auditor-watchdog.timer enabled, or a watchdog cron entry installed?)"
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
