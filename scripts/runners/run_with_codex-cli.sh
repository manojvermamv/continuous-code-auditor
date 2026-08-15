#!/usr/bin/env bash
# scripts/runners/run_with_codex-cli.sh
#
# Runs the continuous-code-auditor skill via the `codex` CLI (OpenAI
# Codex CLI), using `codex exec` headless mode.
#
# Skill discovery: Codex CLI supports the same SKILL.md convention, from
# ~/.codex/skills/<name>/ (personal) or .codex/skills/<name>/ (project) —
# this runner relies on that auto-discovery rather than attaching a file.
#
# IMPORTANT (documented, not a guess): `codex exec` streams turn progress to
# stderr and prints only the final agent message to stdout. Non-empty
# stderr is therefore NORMAL here, not a failure signal — do not reuse the
# opencode runner's "non-empty stderr = failure" heuristic for this CLI (see
# classify_failure() below, which deliberately does NOT do that). Instead,
# this runner checks the JSONL stream for an explicit `turn.failed` event,
# which is a real documented failure signal rather than a heuristic.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
MODEL_NAME="${MODEL_NAME:-CHANGE_ME-set-your-model-id}"
AGENT_NAME="codex-cli"
AGENT_BIN="codex"

# Default sandbox is read-only; this audit workflow needs to write to
# work/, archives/, and logs/ (and the project root, on a source refresh),
# so workspace-write is the minimum that works. See adapters/codex-cli.md
# before widening this to danger-full-access.
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"

# shellcheck source=../lib/reliability.sh
source "$SKILL_DIR/scripts/lib/reliability.sh"

agent_specific_preflight() {
  if ! command -v jq >/dev/null 2>&1; then
    PREFLIGHT_FAILED="jq not found on PATH (required to parse --json output)"
  elif [[ ! -f "$HOME/.codex/skills/continuous-code-auditor/SKILL.md" && \
          ! -f "$PROJECT/.codex/skills/continuous-code-auditor/SKILL.md" ]]; then
    PREFLIGHT_FAILED="skill not found in ~/.codex/skills/continuous-code-auditor/ or \$PROJECT/.codex/skills/continuous-code-auditor/ — run installer/install.sh, or copy/symlink the skill folder there manually"
  fi
}

build_message() {
  # The prior-failure note and the audit-target context both come from
  # auditor_context_block() in scripts/lib/reliability.sh — shared across
  # every adapter so the two can't drift apart between runners.
  printf '%s

%s' "Continue the continuous-code-auditor audit. This is a non-interactive scheduled execution — no conversational memory is assumed; reconstruct everything from the workspace on disk as SKILL.md instructs." "$(auditor_context_block)"
}

invoke_agent() {
  # --skip-git-repo-check: codex exec normally requires a git repo; drop
  # this flag if $PROJECT is a real git repo and you want that safety check
  # active.
  if [[ -s "$SESSION_ID_FILE" ]]; then
    timeout "$TIMEOUT_SECONDS" codex exec resume "$(cat "$SESSION_ID_FILE")" \
      --json \
      --full-auto \
      --sandbox "$CODEX_SANDBOX" \
      --skip-git-repo-check \
      "$(build_message)" \
      > "$RUN_OUTPUT" 2> "$ERROR_LOG"
  else
    timeout "$TIMEOUT_SECONDS" codex exec \
      --json \
      --full-auto \
      --sandbox "$CODEX_SANDBOX" \
      --skip-git-repo-check \
      "$(build_message)" \
      > "$RUN_OUTPUT" 2> "$ERROR_LOG"
  fi
}

extract_session_id() {
  # Confirmed convention (documented, not a guess): codex exec --json emits
  # a `thread.started` event carrying the session id in `.id`.
  jq -r 'select(.type == "thread.started") | .id' "$RUN_OUTPUT" 2>/dev/null | head -n1
}

classify_failure() {
  # Real documented failure signal, not a heuristic: a `turn.failed` event
  # in the JSONL stream means the turn failed even if the process exit
  # status doesn't clearly reflect it. Deliberately does NOT treat non-empty
  # stderr as a failure signal (see header) — that's normal progress output
  # for this CLI, unlike opencode.
  if command -v jq >/dev/null 2>&1 && \
     jq -e 'select(.type == "turn.failed")' "$RUN_OUTPUT" >/dev/null 2>&1; then
    log "note: found a turn.failed event in the JSONL stream — treating as a failure regardless of exit status $STATUS"
    STATUS=1
  fi
}

reliability_main "$@"
