#!/usr/bin/env bash
# scripts/runners/run_with_claude-code.sh
#
# Runs the continuous-code-auditor skill via the `claude` CLI (Claude
# Code), in headless/print mode.
#
# UNLIKE the opencode runner, this one does NOT attach SKILL.md as a file on
# every invocation. Claude Code has its own native Agent Skills mechanism —
# skills are discovered from ~/.claude/skills/<name>/ (personal) or
# .claude/skills/<name>/ (project) and activated automatically when Claude
# matches the request against the skill's `description`. The installer
# (installer/install.sh) is what actually puts this skill there; this
# runner just needs to phrase its message so it clearly matches the
# skill's description ("continue the continuous-code-auditor audit...").
# See adapters/claude-code.md for verification steps and caveats.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
MODEL_NAME="${MODEL_NAME:-CHANGE_ME-set-your-model-id}"
AGENT_NAME="claude-code"
AGENT_BIN="claude"

# Recommended default tool scope for a fully non-interactive run — see
# adapters/claude-code.md before deploying. Narrow this further if you can;
# the Bash() sub-scoping syntax lets you allow only specific commands.
CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Read,Write,Bash(python3:*),Bash(diff:*),Bash(sha256sum:*),Bash(wc:*),Bash(curl:*)}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-40}"
CLAUDE_MAX_BUDGET_USD="${CLAUDE_MAX_BUDGET_USD:-2.00}"

# shellcheck source=../lib/reliability.sh
source "$SKILL_DIR/scripts/lib/reliability.sh"

agent_specific_preflight() {
  if ! command -v jq >/dev/null 2>&1; then
    PREFLIGHT_FAILED="jq not found on PATH (required to parse --output-format json output)"
  elif [[ ! -f "$HOME/.claude/skills/continuous-code-auditor/SKILL.md" && \
          ! -f "$PROJECT/.claude/skills/continuous-code-auditor/SKILL.md" ]]; then
    PREFLIGHT_FAILED="skill not found in ~/.claude/skills/continuous-code-auditor/ or \$PROJECT/.claude/skills/continuous-code-auditor/ — run installer/install.sh, or copy/symlink the skill folder there manually"
  fi
}

build_message() {
  local msg="Continue the continuous-code-auditor audit. This is a non-interactive scheduled execution — no conversational memory is assumed; reconstruct everything from the workspace on disk as SKILL.md instructs. (If the continuous-code-auditor skill did not auto-activate for this message, that's a configuration problem — stop and report it rather than improvising an audit process.)"
  if [[ -n "${PRIOR_FAILURE_NOTE:-}" ]]; then
    msg="$msg

PRIOR_RUN_FAILURE_NOTE: $PRIOR_FAILURE_NOTE"
  fi
  printf '%s' "$msg"
}

invoke_agent() {
  local resume_args=()
  if [[ -s "$SESSION_ID_FILE" ]]; then
    resume_args=(--resume "$(cat "$SESSION_ID_FILE")")
  fi

  timeout "$TIMEOUT_SECONDS" claude --print \
    --model "$MODEL_NAME" \
    --output-format json \
    --permission-mode "$CLAUDE_PERMISSION_MODE" \
    --allowedTools "$CLAUDE_ALLOWED_TOOLS" \
    --max-turns "$CLAUDE_MAX_TURNS" \
    --max-budget-usd "$CLAUDE_MAX_BUDGET_USD" \
    "${resume_args[@]+"${resume_args[@]}"}" \
    "$(build_message)" \
    > "$RUN_OUTPUT" 2> "$ERROR_LOG"
}

extract_session_id() {
  # ASSUMPTION TO VERIFY: exact JSON field name for the session id in
  # --output-format json wasn't confirmed from available documentation at
  # the time this was written. Run once and inspect the real shape:
  #   claude -p "hello" --output-format json | jq .
  # and adjust the filter below to match if needed.
  jq -r '
    (.. | objects | select(has("session_id")) | .session_id) //
    (.. | objects | select(has("sessionId")) | .sessionId) //
    empty
  ' "$RUN_OUTPUT" 2>/dev/null | head -n1
}

extract_cost_usd() {
  # total_cost_usd is documented as part of Claude Code's --output-format
  # json envelope. Confirmed field name (unlike the session id above) — if
  # your version's output differs, this just fails to match and cost
  # tracking degrades to "not tracked" for this run, same as any adapter
  # that hasn't implemented this hook at all.
  jq -r '.. | objects | select(has("total_cost_usd")) | .total_cost_usd' "$RUN_OUTPUT" 2>/dev/null | head -n1
}

# No documented "false success" or "stderr is always noisy" quirk found for
# this CLI at time of writing — trust the exit code (the library default).
# If you find otherwise for your version, override classify_failure() here.

reliability_main "$@"
