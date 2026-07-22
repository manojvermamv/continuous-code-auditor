#!/usr/bin/env bash
# scripts/runners/run_with_opencode.sh
#
# Runs the continuous-code-auditor skill via the `opencode` CLI.
# Verified against a real `opencode run --help` output (see
# adapters/opencode.md for the specifics and the known-issue notes this
# runner defends against). Re-verify if you upgrade the CLI — flags change.
#
# This script is normally invoked by scripts/run_auditor.sh (which reads
# config/auditor.conf and dispatches to the runner matching AGENT_CLI). It
# can also be run directly for testing.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
MODEL_NAME="${MODEL_NAME:-CHANGE_ME-set-your-provider/model-id}"
AGENT_NAME="opencode"
AGENT_BIN="opencode"

# shellcheck source=../lib/reliability.sh
source "$SKILL_DIR/scripts/lib/reliability.sh"

agent_specific_preflight() {
  if ! command -v jq >/dev/null 2>&1; then
    PREFLIGHT_FAILED="jq not found on PATH (required to parse --format json output)"
  fi
}

build_message() {
  local msg="Continue the continuous-code-auditor audit per the attached SKILL.md. This is a non-interactive scheduled execution — no conversational memory is assumed; reconstruct everything from the workspace on disk as SKILL.md instructs."
  if [[ -n "${PRIOR_FAILURE_NOTE:-}" ]]; then
    msg="$msg

PRIOR_RUN_FAILURE_NOTE: $PRIOR_FAILURE_NOTE"
  fi
  printf '%s' "$msg"
}

invoke_agent() {
  local session_args=()
  if [[ -s "$SESSION_ID_FILE" ]]; then
    session_args=(--session "$(cat "$SESSION_ID_FILE")")
  fi

  # --format json: structured output is what makes session-id extraction and
  # error detection reliable — the human-readable default format is fine to
  # look at, not to parse.
  #
  # Deliberately NOT using --print-logs: it sends the CLI's own verbose
  # internal logs to stderr, which would make stderr non-empty on every
  # healthy run and defeat classify_failure() below (opencode-specific —
  # stderr is expected to stay quiet unless something's actually wrong).
  timeout "$TIMEOUT_SECONDS" opencode run \
    --model "$MODEL_NAME" \
    --format json \
    --file "$SKILL_DIR/SKILL.md" \
    "${session_args[@]+"${session_args[@]}"}" \
    "$(build_message)" \
    > "$RUN_OUTPUT" 2> "$ERROR_LOG"
}

extract_session_id() {
  # ASSUMPTION TO VERIFY: best guess at where a session id shows up in this
  # CLI's --format json output, based on the documented -s/--session flag
  # existing. Before relying on this in production, run once:
  #   opencode run --format json "hello" | jq .
  # and check where the session id actually appears; adjust below if it's
  # not one of these paths.
  jq -r '
    (.. | objects | select(has("session_id")) | .session_id) //
    (.. | objects | select(has("sessionId")) | .sessionId) //
    (.. | objects | select(.type? == "session") | .id) //
    empty
  ' "$RUN_OUTPUT" 2>/dev/null | head -n1
}

classify_failure() {
  # "False success" defense: some opencode versions/conditions are documented
  # to report exit 0 even on a real failure. A non-empty stderr capture
  # counts as a failure too, rather than trusting the exit code alone. This
  # is opencode-specific — see adapters/opencode.md; do not assume this
  # applies to other CLIs (some stream normal progress to stderr).
  if [[ $STATUS -eq 0 && -s "$ERROR_LOG" ]]; then
    log "note: exit code was 0 but stderr was non-empty — treating as a failure (see error log excerpt below)"
    log "stderr excerpt: $(tail -c 500 "$ERROR_LOG")"
    STATUS=1
  fi
}

reliability_main "$@"
