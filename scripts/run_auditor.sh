#!/usr/bin/env bash
# scripts/run_auditor.sh
#
# Thin dispatcher: reads config/auditor.conf, then hands off to the runner
# script matching AGENT_CLI. All the actual reliability logic lives in
# scripts/lib/reliability.sh (CLI-agnostic) and scripts/runners/run_with_*.sh
# (one per supported agent CLI). See adapters/README.md to add a new one.
#
# This is what cron / systemd should point at — not a runner script directly
# — so switching AGENT_CLI in config/auditor.conf is the only change needed
# to retarget the whole deployment at a different agent CLI.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
AUDITOR_VERSION="$(grep -m1 -oE '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$SKILL_DIR/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
AUDITOR_VERSION="${AUDITOR_VERSION:-unknown}"

usage() {
  cat <<EOF
continuous-code-auditor v$AUDITOR_VERSION — scheduled execution dispatcher

USAGE
  run_auditor.sh [options]

OPTIONS
  -h, --help       Show this help and exit.
  -V, --version    Print the version and exit.
  -n, --dry-run    Run every check a real execution would (config, runner
                   resolution, dependencies, skill install, paths, disk, load,
                   pause/breaker state) and report what WOULD happen — without
                   invoking the agent CLI, taking the lock, or writing to the
                   workspace. Safe to run at any time, including mid-audit.

CONFIGURATION
  Config file: $CONFIG_FILE
  Override the path with the AUDITOR_CONFIG environment variable.
  Every setting is documented in config/auditor.conf.example.

EXIT CODES
  0 success · 10 lock held · 12 breaker held · 13 paused · 14 resource
  deferred · 15 preflight/config failure · 20 compile failed · 30 source
  unavailable · 40 prompt failure · 50 state recovery · 1 unrecognized
  Full table: references/workspace-and-execution.md

SEE ALSO
  scripts/commands/doctor.sh   Diagnose a broken installation
  scripts/watchdog.sh          Detect a dead scheduler
  TROUBLESHOOTING.md           Symptom-to-fix reference
EOF
}

DRY_RUN=false
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "continuous-code-auditor $AUDITOR_VERSION"; exit 0 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    *)            PASSTHROUGH+=("$1"); shift ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "$(date -Iseconds) [dispatcher] FAILURE: no config file at $CONFIG_FILE (copy config/auditor.conf.example to config/auditor.conf and edit it, or run installer/install.sh)" >&2
  exit 15
fi

# shellcheck source=config/auditor.conf.example
source "$CONFIG_FILE"

if [[ -z "${AGENT_CLI:-}" ]]; then
  echo "$(date -Iseconds) [dispatcher] FAILURE: AGENT_CLI not set in $CONFIG_FILE" >&2
  exit 15
fi

RUNNER="$SKILL_DIR/scripts/runners/run_with_${AGENT_CLI}.sh"
if [[ ! -f "$RUNNER" ]]; then
  echo "$(date -Iseconds) [dispatcher] FAILURE: no runner for AGENT_CLI=\"$AGENT_CLI\" (looked for $RUNNER). Valid values: opencode, claude-code, gemini-cli, codex-cli, hermes — or add a new runner, see adapters/README.md" >&2
  exit 15
fi

if [[ "$DRY_RUN" == true ]]; then
  # Delegates the actual checking to doctor.sh rather than reimplementing it —
  # two copies of "is this deployment healthy?" would inevitably drift, and
  # doctor is already the tested, maintained answer. This wrapper adds only
  # what's specific to "what would THIS invocation do".
  echo "== dry run: continuous-code-auditor v$AUDITOR_VERSION =="
  echo "config:  $CONFIG_FILE"
  echo "agent:   $AGENT_CLI  ->  $RUNNER"
  echo "project: ${PROJECT:-<unset>}"
  echo "target:  ${AUDIT_TARGET:-.}"
  echo
  echo "-- checks a real run would perform (via doctor) --"
  DOCTOR_RC=0
  AUDITOR_CONFIG="$CONFIG_FILE" bash "$SKILL_DIR/scripts/commands/doctor.sh" || DOCTOR_RC=$?
  echo
  if [[ "$DOCTOR_RC" -ne 0 ]]; then
    echo "=> a real run would FAIL preflight. Fix the [FAIL] items above first."
    exit 15
  fi
  # Gate state the doctor reports but doesn't decide on.
  LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
  if [[ -f "$LOG_DIR/held.flag" ]]; then
    echo "=> a real run would SKIP (exit 12): circuit breaker held."
  elif [[ -f "$LOG_DIR/paused.flag" ]]; then
    echo "=> a real run would SKIP (exit 13): paused."
  else
    echo "=> a real run would PROCEED: invoke $AGENT_CLI against ${AUDIT_TARGET:-.} in ${PROJECT:-<unset>}."
  fi
  echo "(nothing was invoked, locked, or written)"
  exit 0
fi

exec "$RUNNER" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
