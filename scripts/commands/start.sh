#!/usr/bin/env bash
# scripts/commands/start.sh — /continuous-code-auditor-start
#
# Resumes scheduled execution: clears the pause flag that scripts/run_auditor.sh
# checks on every tick (see scripts/lib/reliability.sh), and best-effort
# resumes a systemd timer if one is installed and permissions allow it. Does
# NOT touch the circuit breaker (held.flag) — if the auditor is held due to
# repeated failures, clear that separately once you've confirmed the
# underlying cause is fixed (see references/workspace-and-execution.md
# "Exit code contract").

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [[ -f "$PAUSED_FLAG" ]]; then
  rm -f "$PAUSED_FLAG"
  echo "cleared pause flag — scheduled executions will run again on the next tick"
else
  echo "not currently paused (nothing to clear)"
fi

if [[ -f "$HELD_FLAG" ]]; then
  echo "note: the circuit breaker is still HELD ($(cat "$HELD_FLAG"))."
  echo "      /continuous-code-auditor-start does not clear this — confirm the underlying"
  echo "      cause is fixed, then remove $HELD_FLAG yourself."
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^continuous-code-auditor.timer"; then
  if systemctl start continuous-code-auditor.timer 2>/dev/null; then
    echo "started continuous-code-auditor.timer"
  else
    echo "note: continuous-code-auditor.timer is installed but could not be started (permissions? run with sudo, or start it yourself: systemctl start continuous-code-auditor.timer)"
  fi
fi

echo "done."
