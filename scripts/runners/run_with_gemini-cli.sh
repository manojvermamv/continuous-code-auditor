#!/usr/bin/env bash
# scripts/runners/run_with_gemini-cli.sh
#
# Runs the continuous-code-auditor skill via the `gemini` CLI (Gemini
# CLI), in headless mode.
#
# Like Claude Code, Gemini CLI has its own native Agent Skills mechanism —
# skills are discovered from ~/.gemini/skills/<name>/ (personal) or
# .gemini/skills/<name>/ (project, requires the workspace folder to be
# "trusted" — see adapters/gemini-cli.md) and activated when Gemini matches
# the request against the skill's `description`. This runner does not
# attach SKILL.md as a file.
#
# Session continuity here works differently from the other adapters: Gemini
# CLI tracks session history itself, per project directory, and exposes a
# `latest` selector — so instead of capturing and storing an explicit
# session id, this runner just passes `--resume latest` on every run after
# the first (tracked with a simple marker file, to avoid an undocumented
# edge case on the very first run where no session exists yet).

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PROJECT="${PROJECT:-CHANGE_ME-set-project-path}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
MODEL_NAME="${MODEL_NAME:-CHANGE_ME-set-your-model-id}"
AGENT_NAME="gemini-cli"
AGENT_BIN="gemini"

# ASSUMPTION TO VERIFY: --approval-mode values seen in documentation are
# default/auto_edit/yolo/plan. "yolo" auto-approves everything including
# shell commands — only use it if you trust the sandboxing around this
# process (see the systemd hardening in references/workspace-and-execution.md).
# Prefer the most restrictive mode that still completes non-interactively;
# test manually before relying on this in a 24/7 loop. See adapters/gemini-cli.md.
GEMINI_APPROVAL_MODE="${GEMINI_APPROVAL_MODE:-auto_edit}"

HAS_RUN_MARKER="$LOG_DIR/.gemini_has_run_before"

# shellcheck source=../lib/reliability.sh
source "$SKILL_DIR/scripts/lib/reliability.sh"

agent_specific_preflight() {
  if [[ ! -f "$HOME/.gemini/skills/continuous-code-auditor/SKILL.md" && \
        ! -f "$PROJECT/.gemini/skills/continuous-code-auditor/SKILL.md" ]]; then
    PREFLIGHT_FAILED="skill not found in ~/.gemini/skills/continuous-code-auditor/ or \$PROJECT/.gemini/skills/continuous-code-auditor/ — run installer/install.sh, or copy/symlink the skill folder there manually. If it's project-scoped, also make sure the workspace is marked trusted (run /trust once interactively)."
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
  local resume_args=()
  if [[ -f "$HAS_RUN_MARKER" ]]; then
    resume_args=(--resume latest)
  fi

  # -p/--prompt is the documented headless entry point as of this writing;
  # some sources also show --non-interactive as an alternate/older flag —
  # verify against `gemini --help` on your installed version if -p doesn't
  # behave as expected. -o/--output-format json for parseable output.
  timeout "$TIMEOUT_SECONDS" gemini \
    -p "$(build_message)" \
    -m "$MODEL_NAME" \
    -o json \
    --approval-mode "$GEMINI_APPROVAL_MODE" \
    "${resume_args[@]+"${resume_args[@]}"}" \
    > "$RUN_OUTPUT" 2> "$ERROR_LOG"

  local status=$?
  touch "$HAS_RUN_MARKER"
  return "$status"
}

extract_session_id() {
  # Deliberately a no-op: this adapter uses Gemini CLI's own `--resume latest`
  # selector (see header) rather than capturing an explicit session id, so
  # there's nothing to extract. Left in place (rather than removed) so the
  # contract stays consistent with the other adapters — see
  # adapters/README.md.
  :
}

# No documented "false success" or "stderr is always noisy" quirk found for
# this CLI at time of writing — trust the exit code (the library default).

reliability_main "$@"
