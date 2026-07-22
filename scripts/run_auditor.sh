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

exec "$RUNNER" "$@"
