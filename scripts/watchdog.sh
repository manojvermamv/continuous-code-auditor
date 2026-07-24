#!/usr/bin/env bash
# scripts/watchdog.sh
#
# Detects a dead SCHEDULER — not a failed execution. The circuit breaker in
# scripts/lib/reliability.sh only reacts to executions that actually happen;
# if cron itself stops firing, systemd's timer gets disabled, or the host
# just never re-enables it after a reboot, no execution ever runs at all,
# nothing ever fails, and the circuit breaker stays silent forever. This
# script is deliberately separate from the main dispatcher and reliability
# engine — it must keep working even if everything else has silently
# stopped — and should be scheduled independently (see
# scripts/systemd/continuous-code-auditor-watchdog.timer), on its own timer,
# so a dead main scheduler doesn't also take the thing watching it down.
#
# Checks heartbeat.json's age (falling back to auditor.log's last line if
# heartbeat.json is missing or unreadable) against MAX_STALE_MINUTES. Alerts
# — does not touch the pause/hold state, and does not run an audit itself.
#
# Usage: watchdog.sh

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "$(date -Iseconds) [watchdog] no config file at $CONFIG_FILE — nothing to watch yet" >&2
  exit 0
fi
# shellcheck source=config/auditor.conf.example
source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
MAX_STALE_MINUTES="${WATCHDOG_MAX_STALE_MINUTES:-30}"

mkdir -p "$LOG_DIR"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"

wlog() {
  echo "$(date -Iseconds) [watchdog] $1" >> "$WATCHDOG_LOG"
}

wlog_alert() {
  # --- replace with your actual notification channel (mail, webhook, etc.) ---
  # Deliberately a separate function from scripts/lib/reliability.sh's
  # alert() — this script must not depend on sourcing the main reliability
  # engine, since the whole point is to keep working independently of it.
  wlog "ALERT: $1"
}

# If explicitly paused or held, a stale heartbeat is expected, not a scheduler
# failure — don't alert for either.
if [[ -f "$LOG_DIR/paused.flag" ]]; then
  wlog "skip: auditor is intentionally paused ($(cat "$LOG_DIR/paused.flag"))"
  exit 0
fi
if [[ -f "$LOG_DIR/held.flag" ]]; then
  wlog "skip: circuit breaker is held — that's the main reliability engine's problem to alert on, not the scheduler's"
  exit 0
fi

HEARTBEAT="$PROJECT/work/heartbeat.json"
LAST_TS=""

if [[ -f "$HEARTBEAT" ]]; then
  LAST_TS="$(date -r "$HEARTBEAT" +%s 2>/dev/null || true)"
fi
if [[ -z "$LAST_TS" && -f "$LOG_DIR/auditor.log" ]]; then
  wlog "note: heartbeat.json missing/unreadable, falling back to auditor.log's mtime"
  LAST_TS="$(date -r "$LOG_DIR/auditor.log" +%s 2>/dev/null || true)"
fi

if [[ -z "$LAST_TS" ]]; then
  wlog "note: no heartbeat.json and no auditor.log yet — nothing to check (first install, or scheduler has never fired even once)"
  exit 0
fi

NOW_TS="$(date +%s)"
AGE_MINUTES=$(( (NOW_TS - LAST_TS) / 60 ))

if [[ "$AGE_MINUTES" -gt "$MAX_STALE_MINUTES" ]]; then
  wlog_alert "no execution in ${AGE_MINUTES} minutes (threshold: ${MAX_STALE_MINUTES}) — the scheduler itself (cron/systemd timer) may have stopped firing, not just an individual run failing. Check: systemctl status continuous-code-auditor.timer, or crontab -l."
  exit 1
fi

wlog "ok: last execution ${AGE_MINUTES} minute(s) ago (threshold: ${MAX_STALE_MINUTES})"
exit 0
