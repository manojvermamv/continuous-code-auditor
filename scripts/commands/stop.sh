#!/usr/bin/env bash
# scripts/commands/stop.sh — /continuous-code-auditor-stop
#
# Pauses scheduled execution: any new tick of scripts/run_auditor.sh will see
# the pause flag (via scripts/lib/reliability.sh) and exit immediately
# without touching the workspace. Does not interrupt a run already in
# progress — that one finishes naturally; this only prevents the *next* one
# from starting. Best-effort also stops a systemd timer if one is installed
# and permissions allow it — cron entries are not removed (they'll just keep
# firing and immediately no-op against the pause flag instead).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

REASON="${1:-paused via /continuous-code-auditor-stop at $(date -Iseconds)}"
echo "$REASON" > "$PAUSED_FLAG"
echo "wrote pause flag: $PAUSED_FLAG"
echo "($REASON)"

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^continuous-code-auditor.timer"; then
  if systemctl stop continuous-code-auditor.timer 2>/dev/null; then
    echo "stopped continuous-code-auditor.timer"
  else
    echo "note: continuous-code-auditor.timer is installed but could not be stopped (permissions? the pause flag above still prevents new runs regardless)"
  fi
fi

echo "done. Run scripts/commands/start.sh (or /continuous-code-auditor-start) to resume."
