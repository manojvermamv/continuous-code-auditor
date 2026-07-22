#!/usr/bin/env bash
# scripts/commands/backup-everything.sh — /continuous-code-auditor-backup-everything
#
# Complete backup: bundles the skill package itself (SKILL.md, scripts,
# config, adapters, references, README, installer) together with the entire
# runtime workspace (work/, archives/) and the wrapper's operational logs
# into one timestamped tarball under PROJECT/backups/. This is the "start
# over on a new machine" or "before a major change" snapshot — broader than
# scripts/commands/archive.sh (which only checkpoints work/) and completely
# separate from scripts/commands/reset.sh (which clears state, this command
# never clears anything).
#
# Usage: backup-everything.sh [label]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

LABEL="${1:-}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="continuous-code-auditor-backup-${TIMESTAMP}"
[[ -n "$LABEL" ]] && NAME="${NAME}-${LABEL}"
DEST="$PROJECT/backups/${NAME}.tar.gz"

mkdir -p "$PROJECT/backups"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/skill" "$STAGE/workspace"
cp -r "$SKILL_DIR"/. "$STAGE/skill/" 2>/dev/null || true
# Exclude any local, machine-specific config from the portable skill copy —
# the backup still captures it separately below, under workspace/config, so
# nothing is lost, it's just not implied to be reusable as-is elsewhere.
rm -f "$STAGE/skill/config/auditor.conf"

[[ -d "$PROJECT/work" ]] && cp -r "$PROJECT/work" "$STAGE/workspace/work"
[[ -d "$PROJECT/archives" ]] && cp -r "$PROJECT/archives" "$STAGE/workspace/archives"
[[ -f "$SKILL_DIR/config/auditor.conf" ]] && mkdir -p "$STAGE/workspace/config" && cp "$SKILL_DIR/config/auditor.conf" "$STAGE/workspace/config/"
[[ -d "$LOG_DIR" ]] && cp -r "$LOG_DIR" "$STAGE/workspace/logs"

tar -czf "$DEST" -C "$STAGE" .

SIZE="$(du -h "$DEST" 2>/dev/null | cut -f1)"
echo "backup written: $DEST ($SIZE)"
echo "contains: the skill package (minus your local config/auditor.conf, included separately"
echo "under workspace/config/ instead), plus work/, archives/, and the wrapper logs directory."
