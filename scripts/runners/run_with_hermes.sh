#!/usr/bin/env bash
# scripts/runners/run_with_hermes.sh
#
# Runs the continuous-code-auditor skill via the `hermes` CLI (Nous
# Research's Hermes Agent), using single-query non-interactive mode.
#
# UNLIKE Claude Code / Gemini CLI / Codex CLI, Hermes lets you explicitly
# preload a named skill with -s/--skills instead of relying purely on
# description-matching — this runner uses that, which is more deterministic.
# The skill still needs to be installed under ~/.hermes/skills/<category>/
# continuous-code-auditor/ (or the shared ~/.agents/skills/ directory) —
# installer/install.sh does this.
#
# HONESTY NOTE: no confirmed --output-format json (or equivalent) flag was
# found for `hermes chat` in the documentation available when this adapter
# was written. Run `hermes chat --help` on your installed version and check
# for a structured-output flag; if one exists, wire it into invoke_agent()
# below and update extract_session_id() to parse it — until then, this
# runner captures plain text and does not attempt session-id extraction.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
MODEL_NAME="${MODEL_NAME:-CHANGE_ME-set-your-provider/model-id}"
AGENT_NAME="hermes"
AGENT_BIN="hermes"

# shellcheck source=../lib/reliability.sh
source "$SKILL_DIR/scripts/lib/reliability.sh"

agent_specific_preflight() {
  # Only search directories that actually exist — passing a nonexistent path
  # to `find` makes it exit non-zero (a traversal error) even when it finds
  # and prints a real match from another, valid path in the same invocation.
  # Under `set -o pipefail` that false failure would propagate through the
  # `| grep -q .` check and fail preflight despite the skill actually being
  # installed. (Caught by actually running this against a real directory
  # layout, not by reading the find(1) man page.)
  local search_dirs=()
  [[ -d "$HOME/.hermes/skills" ]] && search_dirs+=("$HOME/.hermes/skills")
  [[ -d "$PROJECT/.agents/skills" ]] && search_dirs+=("$PROJECT/.agents/skills")

  if [[ ${#search_dirs[@]} -eq 0 ]]; then
    PREFLIGHT_FAILED="neither ~/.hermes/skills/ nor \$PROJECT/.agents/skills/ exist — run installer/install.sh, or create one and copy/symlink the skill folder there manually"
    return
  fi

  if ! find "${search_dirs[@]}" -maxdepth 3 -name "SKILL.md" -path "*continuous-code-auditor*" 2>/dev/null | grep -q .; then
    PREFLIGHT_FAILED="skill not found under ~/.hermes/skills/ (any category subdirectory) or \$PROJECT/.agents/skills/ — run installer/install.sh, or copy/symlink the skill folder there manually"
  fi
}

build_message() {
  local msg="Continue the continuous-code-auditor audit. This is a non-interactive scheduled execution — no conversational memory is assumed; reconstruct everything from the workspace on disk as SKILL.md instructs."
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

  timeout "$TIMEOUT_SECONDS" hermes chat \
    -s continuous-code-auditor \
    --model "$MODEL_NAME" \
    "${resume_args[@]+"${resume_args[@]}"}" \
    -q "$(build_message)" \
    > "$RUN_OUTPUT" 2> "$ERROR_LOG"
}

extract_session_id() {
  # See the HONESTY NOTE at the top of this file — left as a no-op until a
  # structured-output flag is confirmed for your installed version.
  :
}

# No documented "false success" or "stderr is always noisy" quirk found for
# this CLI at time of writing — trust the exit code (the library default).

reliability_main "$@"
