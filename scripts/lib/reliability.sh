#!/usr/bin/env bash
# scripts/lib/reliability.sh
#
# CLI-agnostic reliability engine for the continuous-code-auditor scheduled
# execution. This file has NO knowledge of any specific agent CLI (opencode,
# Claude Code, Gemini CLI, Codex CLI, Hermes, or anything added later) — it
# only knows about: locking, lock metadata, the circuit breaker, structured
# exit codes, and prior-failure carry-forward.
#
# A runner script (scripts/runners/run_with_<cli>.sh) sources this file, sets
# the config variables below, defines two functions of its own —
# invoke_agent() and (optionally) extract_session_id() — and then calls
# reliability_main "$@" to run the whole reliability loop. See
# scripts/runners/run_with_opencode.sh for a complete example, and
# adapters/README.md for the contract every runner must satisfy.
#
# Config variables a runner must set before calling reliability_main:
#   PROJECT              - path to the audited project root
#   SKILL_DIR             - path to this skill's root directory
#   LOG_DIR               - path for logs and wrapper-internal state
#   MODEL_NAME            - model identifier to pass to the agent CLI
#   AGENT_NAME            - human-readable name, for log messages (e.g. "opencode")
#   AGENT_BIN             - binary name to check for on PATH during preflight
#   TIMEOUT_SECONDS       - wall-clock timeout per execution (default: 240)
#   FAILURE_THRESHOLD     - consecutive failures before the circuit breaker trips (default: 3)
#
# Functions a runner must define before calling reliability_main:
#   invoke_agent          - runs the actual CLI invocation. Must write stdout
#                           to "$RUN_OUTPUT" and stderr to "$ERROR_LOG" (both
#                           paths are set by this library before calling it),
#                           and must return the CLI's real exit status.
#
# Functions a runner may optionally define (sensible no-op defaults provided):
#   extract_session_id    - best-effort: read $RUN_OUTPUT and echo a session
#                           id to persist for the next run's session
#                           continuity, or echo nothing if unavailable/unsupported.
#   classify_failure      - given $STATUS and $ERROR_LOG, decide whether this
#                           run should be treated as a failure even if $STATUS
#                           was 0 (or vice versa, in principle). Default: trust
#                           $STATUS alone. Override this per-CLI — e.g. some
#                           CLIs are documented to always write progress to
#                           stderr even on success (non-empty stderr is NORMAL
#                           there), while others have a documented "false
#                           success" exit-0-on-real-failure bug (non-empty
#                           stderr should count as failure there). Do not copy
#                           one CLI's heuristic onto another without checking.
#   agent_specific_preflight - additional preflight checks beyond the generic
#                           ones (binary on PATH, model configured, project
#                           exists). Should set PREFLIGHT_FAILED="<reason>" and
#                           return; leave it empty/unset to pass.

set -euo pipefail

: "${TIMEOUT_SECONDS:=240}"
: "${FAILURE_THRESHOLD:=3}"

LOCK="${LOCK:-/tmp/continuous_code_auditor.lock}"
LOCK_META="$LOCK.meta"
LAST_FAILURE_FILE="$LOG_DIR/last_failure.txt"
FAILURE_COUNT_FILE="$LOG_DIR/consecutive_failures.txt"
HELD_FLAG="$LOG_DIR/held.flag"
PAUSED_FLAG="$LOG_DIR/paused.flag"
SESSION_ID_FILE="$LOG_DIR/${AGENT_NAME:-agent}_session_id.txt"

# Structured exit codes — keep in sync with the table in
# references/workspace-and-execution.md "Exit code contract". These are
# identical across every CLI adapter; only how code 20/30/50 get *detected*
# varies (via the AUDITOR_EXIT_REASON sentinel, CLI-agnostic by design).
EXIT_SUCCESS=0
EXIT_LOCK_HELD=10
EXIT_CIRCUIT_BREAKER_HELD=12
EXIT_PAUSED=13
EXIT_PREFLIGHT_FAILED=15
EXIT_COMPILE_FAILED=20
EXIT_SOURCE_UNAVAILABLE=30
EXIT_PROMPT_FAILURE=40
EXIT_STATE_RECOVERY_INVOKED=50

_CLEANUP_PATHS=()

reliability_register_cleanup() {
  _CLEANUP_PATHS+=("$1")
}

_reliability_cleanup() {
  local p
  for p in "${_CLEANUP_PATHS[@]+"${_CLEANUP_PATHS[@]}"}"; do
    rm -f "$p"
  done
  rm -f "$LOCK_META"
}
trap _reliability_cleanup EXIT

log() {
  mkdir -p "$LOG_DIR"
  echo "$(date -Iseconds) [$AGENT_NAME] $1" >> "$LOG_DIR/auditor.log"
}

alert() {
  # --- replace with your actual notification channel (mail, webhook, etc.) ---
  # A held circuit breaker (or a preflight failure) with no alert defeats the
  # point of having one.
  log "ALERT: $1"
}

record_failure() {
  local reason="$1"
  log "FAILURE: $reason"
  echo "Previous execution ($AGENT_NAME) failed ($reason) at $(date -Iseconds)." > "$LAST_FAILURE_FILE"

  local prev=0
  [[ -s "$FAILURE_COUNT_FILE" ]] && prev="$(cat "$FAILURE_COUNT_FILE")"
  local new=$((prev + 1))
  echo "$new" > "$FAILURE_COUNT_FILE"

  if [[ "$new" -ge "$FAILURE_THRESHOLD" ]]; then
    echo "$new consecutive failures as of $(date -Iseconds): $reason" > "$HELD_FLAG"
    alert "circuit breaker tripped after $new consecutive failures ($reason)"
  fi
}

record_success() {
  local note="${1:-success}"
  log "$note"
  : > "$LAST_FAILURE_FILE"
  echo 0 > "$FAILURE_COUNT_FILE"
}

# Default no-op hooks — a runner overrides these by defining a function of
# the same name *before* sourcing this library, or after sourcing it but
# before calling reliability_main (function redefinition in bash just wins
# with whichever definition is in effect last).
extract_session_id() { :; }
classify_failure() { :; }
agent_specific_preflight() { :; }

reliability_main() {
  mkdir -p "$LOG_DIR"

  if [[ -f "$HELD_FLAG" ]]; then
    log "skip: circuit breaker is held ($(cat "$HELD_FLAG"))"
    exit "$EXIT_CIRCUIT_BREAKER_HELD"
  fi

  if [[ -f "$PAUSED_FLAG" ]]; then
    log "skip: paused ($(cat "$PAUSED_FLAG")) — run scripts/commands/start.sh (or the /continuous-code-auditor-start command) to resume"
    exit "$EXIT_PAUSED"
  fi

  PREFLIGHT_FAILED=""
  if [[ -z "${MODEL_NAME:-}" || "$MODEL_NAME" == CHANGE_ME* ]]; then
    PREFLIGHT_FAILED="MODEL_NAME was never configured (still a CHANGE_ME placeholder)"
  elif ! command -v "$AGENT_BIN" >/dev/null 2>&1; then
    PREFLIGHT_FAILED="$AGENT_BIN CLI not found on PATH"
  elif [[ ! -d "$PROJECT" ]]; then
    PREFLIGHT_FAILED="PROJECT directory not found at $PROJECT"
  elif [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    PREFLIGHT_FAILED="SKILL.md not found under SKILL_DIR ($SKILL_DIR)"
  fi

  if [[ -z "$PREFLIGHT_FAILED" ]]; then
    agent_specific_preflight
  fi

  if [[ -n "$PREFLIGHT_FAILED" ]]; then
    record_failure "preflight: $PREFLIGHT_FAILED"
    exit "$EXIT_PREFLIGHT_FAILED"
  fi

  cd "$PROJECT"

  PRIOR_FAILURE_NOTE=""
  if [[ -s "$LAST_FAILURE_FILE" ]]; then
    PRIOR_FAILURE_NOTE="$(cat "$LAST_FAILURE_FILE")"
  fi

  RUN_OUTPUT="$(mktemp)"
  ERROR_LOG="$(mktemp)"
  reliability_register_cleanup "$RUN_OUTPUT"
  reliability_register_cleanup "$ERROR_LOG"

  # Step 1: acquire lock.
  exec 200>"$LOCK"
  if ! flock -n 200; then
    if [[ -s "$LOCK_META" ]]; then
      log "skip: lock held by $(cat "$LOCK_META")"
    else
      log "skip: another audit instance already holds the lock (no metadata found)"
    fi
    exit "$EXIT_LOCK_HELD"
  fi
  printf 'pid=%s host=%s started_at=%s\n' "$$" "$(hostname)" "$(date -Iseconds)" > "$LOCK_META"

  # Step 2: execute the prompt. Step 3: capture the exit code.
  set +e
  invoke_agent
  STATUS=$?
  set -e

  local sid
  sid="$(extract_session_id 2>/dev/null || true)"
  if [[ -n "$sid" && "$sid" != "null" ]]; then
    local tmp
    tmp="$(mktemp "${SESSION_ID_FILE}.tmp.XXXXXX")"
    printf '%s' "$sid" > "$tmp"
    mv -f "$tmp" "$SESSION_ID_FILE"
  else
    log "note: no session id captured this run — either this adapter doesn't track an explicit id (e.g. gemini-cli uses its own resume mechanism instead, see adapters/gemini-cli.md) or extraction didn't find one this time (see the $AGENT_NAME adapter's extract_session_id). Either way, next run just starts fresh rather than continuing a prior conversation — not a failure."
  fi

  # Let the runner apply any CLI-specific failure classification (e.g. a
  # documented false-success bug) before we trust $STATUS.
  classify_failure

  REASON="$(grep -oE 'AUDITOR_EXIT_REASON: *[a-z_]+' "$RUN_OUTPUT" 2>/dev/null | tail -n1 | awk -F': *' '{print $2}' || true)"

  # Step 4: log success/failure and pick the final structured exit code. On
  # failure this also completes step 5 by writing the note the *next* run's
  # prior-failure read (above) will pick up.
  local final_code
  if [[ $STATUS -eq 0 ]]; then
    if [[ "$REASON" == "state_recovery_invoked" ]]; then
      final_code=$EXIT_STATE_RECOVERY_INVOKED
      record_success "success (state recovery invoked this run — see execution_log.md)"
    else
      final_code=$EXIT_SUCCESS
      record_success
    fi
  else
    case "$REASON" in
      compile_failed)      final_code=$EXIT_COMPILE_FAILED ;;
      source_unavailable)  final_code=$EXIT_SOURCE_UNAVAILABLE ;;
      *)                   final_code=$EXIT_PROMPT_FAILURE ;;
    esac
    record_failure "run exited with status $STATUS${REASON:+ (reason: $REASON)}"
  fi

  exit "$final_code"
}
