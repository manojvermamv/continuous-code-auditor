#!/usr/bin/env bash
# scripts/commands/reset.sh — /continuous-code-auditor-reset
#
# Full reset of the CURRENT audit session: every file directly in work/
# (findings register, closure report, execution log, governance notes,
# mistake ledger, negative-knowledge registry, metrics, heartbeat, candidate
# fixes) plus the wrapper's operational logs (auditor.log, failure counters,
# held/paused flags, session id files) get MOVED — not deleted — into a new
# timestamped folder under work/archives/, and work/ is reinitialized with
# fresh, minimal, valid stub files so the next execution starts a genuinely
# new session rather than tripping the corruption-recovery path.
#
# work/archives/ ITSELF IS NEVER RESET, MOVED, OR DELETED — every past
# reset's snapshot stays there permanently. This is deliberate: it's the one
# thing this command is not allowed to touch, no matter what.
#
# Scope: this only affects work/ and the wrapper's own log directory.
# It does NOT touch the top-level archives/ (source-code version history)
# or backups/ (full disaster-recovery snapshots) — those are separate
# concerns with their own retention. See references/workspace-and-execution.md.
#
# Because this is destructive to the active session, it refuses to run
# without explicit confirmation: either the --confirm flag, or (if running
# interactively) typing RESET when prompted.
#
# Usage: reset.sh --confirm

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CONFIRMED=false
[[ "${1:-}" == "--confirm" ]] && CONFIRMED=true

if [[ "$CONFIRMED" != true ]]; then
  if [[ -t 0 ]]; then
    read -r -p "This will archive and clear ALL current findings, state, and logs (work/archives/ is preserved). Type RESET to confirm: " answer
    [[ "$answer" == "RESET" ]] && CONFIRMED=true
  fi
fi

if [[ "$CONFIRMED" != true ]]; then
  echo "Not confirmed — nothing was changed. Re-run with --confirm, or interactively and type RESET." >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT_DIR="$PROJECT/work/archives/$TIMESTAMP"
mkdir -p "$SNAPSHOT_DIR/work" "$SNAPSHOT_DIR/logs"

echo "== resetting continuous-code-auditor session =="
echo "archiving current state to: $SNAPSHOT_DIR"

# Move everything directly inside work/ EXCEPT archives/ itself — this
# directory is never the thing being archived, only ever the destination.
shopt -s nullglob dotglob
for entry in "$PROJECT"/work/*; do
  base="$(basename "$entry")"
  [[ "$base" == "archives" ]] && continue
  mv "$entry" "$SNAPSHOT_DIR/work/"
done
shopt -u nullglob dotglob

# Move the wrapper's own operational state — but not the lock file, which is
# an active concurrency primitive, not session history.
for f in auditor.log cron.log last_failure.txt consecutive_failures.txt held.flag paused.flag; do
  [[ -f "$LOG_DIR/$f" ]] && mv "$LOG_DIR/$f" "$SNAPSHOT_DIR/logs/"
done
for f in "$LOG_DIR"/*_session_id.txt; do
  [[ -e "$f" ]] && mv "$f" "$SNAPSHOT_DIR/logs/"
done

# Reinitialize work/ with minimal, valid, unambiguous "fresh session" stubs —
# so the next execution sees a clean start, not something that looks like
# corruption needing the recovery hierarchy in references/workspace-and-execution.md.
cat > "$PROJECT/work/audit_state.json" <<JSON
{
  "schema_version": 3,
  "active_task": null,
  "pending_tasks": [],
  "verification_queue": [],
  "deferred_queue": []
}
JSON

cat > "$PROJECT/work/continuous_code_audit_findings.md" <<'MD'
# Continuous Code Audit — Findings Register

(reset — no findings recorded yet this session)
MD

cat > "$PROJECT/work/continuous_code_audit_closure_report.md" <<'MD'
# Continuous Code Audit — Consolidated Closure Report

(reset — no conclusions recorded yet this session)
MD

: > "$PROJECT/work/execution_log.md"

cat > "$PROJECT/work/auditor_governance.md" <<'MD'
# Auditor Governance

(reset — no process lessons recorded yet this session)
MD

echo '{"mistakes": []}' > "$PROJECT/work/mistake_ledger.json"
echo '{"rejected": []}' > "$PROJECT/work/negative_knowledge.json"
cat > "$PROJECT/work/metrics.json" <<'JSON'
{
  "executions": 0,
  "findings_open": 0,
  "findings_verified": 0,
  "false_positives": 0,
  "average_runtime_sec": 0,
  "last_success": null,
  "last_failure": null
}
JSON
rm -f "$PROJECT/work/heartbeat.json"
: > "$PROJECT/work/candidate_fixes.md"

echo
echo "done. Previous session archived under: $SNAPSHOT_DIR"
echo "work/ reinitialized with fresh stubs. work/archives/ was not touched"
echo "beyond adding this one new snapshot — every prior reset is still there."
echo "Not affected by this command: archives/ (source history) and backups/."
