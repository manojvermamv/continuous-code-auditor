#!/usr/bin/env bash
# scripts/commands/_common.sh
#
# Sourced by every script in this directory — not meant to be run directly
# (hence the leading underscore, so it doesn't look like one of the seven
# operational commands). Loads config/auditor.conf the same way the runners
# do, and defines the paths every command needs.

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL_NAME="continuous-code-auditor"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "No config file at $CONFIG_FILE — copy config/auditor.conf.example to config/auditor.conf and edit it, or run installer/install.sh first." >&2
  exit 1
fi
# shellcheck source=../../config/auditor.conf.example
source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
AUDIT_TARGET="${AUDIT_TARGET:-.}"
AGENT_CLI="${AGENT_CLI:-unknown}"
LOCK="${LOCK:-/tmp/continuous_code_auditor.lock}"

HELD_FLAG="$LOG_DIR/held.flag"
PAUSED_FLAG="$LOG_DIR/paused.flag"

mkdir -p "$LOG_DIR" "$PROJECT/work" "$PROJECT/archives" "$PROJECT/backups"
