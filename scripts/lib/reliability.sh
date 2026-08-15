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
#   extract_cost_usd       - best-effort: read $RUN_OUTPUT and echo this run's
#                           cost in USD (a bare number, e.g. "0.0142") if the
#                           CLI reports one, or echo nothing if it doesn't.
#                           Accumulates into a cumulative spend total this
#                           library checks against CUMULATIVE_BUDGET_USD (see
#                           config/auditor.conf.example) — only meaningful for
#                           adapters that implement it; degrades to "cost
#                           tracking simply doesn't happen" for the rest,
#                           which is a documented limitation, not a bug.

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
COST_TOTAL_FILE="$LOG_DIR/cumulative_cost_usd.txt"

# Default here rather than in each runner, so every adapter gets the same
# fallback and none can forget it (it's referenced under `set -u`).
AUDIT_TARGET="${AUDIT_TARGET:-.}"

# Shared context block appended to every adapter's message.
#
# SKILL.md instructs the model to determine the audit target before doing
# anything — but it cannot reliably locate config/auditor.conf on its own:
# the runners cd into $PROJECT, while the config lives under $SKILL_DIR, and
# for adapters that attach SKILL.md directly (opencode) the model never sees
# the surrounding skill directory at all. Passing these explicitly in the
# message is the only mechanism that works identically across all five
# adapters. Centralized here rather than copy-pasted into five build_message()
# functions specifically so it can't drift between them.
auditor_context_block() {
  local block
  block="AUDIT_CONTEXT (authoritative for this run — use these, don't infer them):
  PROJECT=$PROJECT
  AUDIT_TARGET=$AUDIT_TARGET
  SKILL_DIR=$SKILL_DIR
  AUDITOR_VERSION=$AUDITOR_VERSION"
  if [[ -n "${PRIOR_FAILURE_NOTE:-}" ]]; then
    block="$block
  PRIOR_RUN_FAILURE_NOTE: $PRIOR_FAILURE_NOTE"
  fi
  printf '%s' "$block"
}

# Structured exit codes — keep in sync with the table in
# references/workspace-and-execution.md "Exit code contract". These are
# identical across every CLI adapter; only how code 20/30/50 get *detected*
# varies (via the AUDITOR_EXIT_REASON sentinel, CLI-agnostic by design).
EXIT_SUCCESS=0
EXIT_LOCK_HELD=10
EXIT_CIRCUIT_BREAKER_HELD=12
EXIT_PAUSED=13
EXIT_RESOURCE_DEFERRED=14
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

# Skill version, read from SKILL.md's frontmatter — single source of truth,
# so a version bump can't drift out of sync with what the logs and workspace
# record. Falls back to "unknown" rather than failing: an unreadable version
# is a cosmetic problem, never a reason to block an audit.
AUDITOR_VERSION="$(grep -m1 -oE '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$SKILL_DIR/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
AUDITOR_VERSION="${AUDITOR_VERSION:-unknown}"

# _json_escape <string> — minimal escaping for JSON string values.
_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'
}

# log <message> [event-type]
#
# Writes the human-readable line as before, and — when LOG_FORMAT includes
# json — a matching JSON Lines record to auditor.jsonl. Both are written;
# the structured file is additive, never a replacement, so anything already
# tailing auditor.log keeps working unchanged.
#
# The version stamp is on every record deliberately: when a months-old
# deployment behaves oddly, the first question is which version produced
# that line, and reconstructing it from timestamps against a changelog is
# exactly the kind of forensics an audit trail should make unnecessary.
log() {
  local msg="$1" event="${2:-info}"
  mkdir -p "$LOG_DIR"
  echo "$(date -Iseconds) [$AGENT_NAME] ($AUDITOR_VERSION) $msg" >> "$LOG_DIR/auditor.log"

  case "${LOG_FORMAT:-text}" in
    *json*)
      printf '{"ts":"%s","version":"%s","agent":"%s","event":"%s","project":"%s","message":"%s"}\n' \
        "$(date -Iseconds)" \
        "$(_json_escape "$AUDITOR_VERSION")" \
        "$(_json_escape "$AGENT_NAME")" \
        "$(_json_escape "$event")" \
        "$(_json_escape "${PROJECT:-}")" \
        "$(_json_escape "$msg")" \
        >> "$LOG_DIR/auditor.jsonl"
      ;;
  esac
}

# Retention enforcement.
#
# references/workspace-and-execution.md has documented a retention policy
# since v1.0.0, but nothing ever implemented it — archives/ and
# execution_log.md grew without bound. On a system whose entire premise is
# running unattended for months, that is a *guaranteed* eventual outage:
# disk fills, MIN_FREE_DISK_MB trips a hard preflight failure (15), three of
# those trip the circuit breaker, and the deployment stops until a human
# intervenes. Documenting a policy nobody enforces is worse than having none,
# because it reads as handled.
#
# Runs before preflight so it can free space *before* the disk gate is
# evaluated. Deliberately conservative — see the evidence guard below.
enforce_retention() {
  # Two independent concerns. An early `return` for one must never skip the
  # other — an earlier draft of this function returned when archives/ didn't
  # exist yet, which silently disabled log rotation on exactly the fresh
  # deployments that run longest before anyone looks.
  _prune_source_archives
  _rotate_execution_log
}

_prune_source_archives() {
  local keep="${ARCHIVE_RETENTION_COUNT:-50}"
  [[ "$keep" -le 0 ]] && return 0          # 0 or negative disables retention
  local archive_dir="$PROJECT/archives"
  [[ -d "$archive_dir" ]] || return 0

  local register="$PROJECT/work/continuous_code_audit_findings.md"
  local pruned=0 candidate base

  # Oldest first, skipping the newest $keep.
  while IFS= read -r candidate; do
    base="$(basename "$candidate")"

    # Evidence guard: never delete an archive the findings register still
    # cites. A finding whose evidence has been deleted is unverifiable, and
    # an unverifiable finding is worse than a large disk — this is exactly
    # the "never delete an archive still cited by an unresolved finding"
    # rule from references/workspace-and-execution.md, enforced rather than
    # merely stated.
    if [[ -f "$register" ]] && grep -qF "$base" "$register" 2>/dev/null; then
      continue
    fi

    rm -f "$candidate" && pruned=$((pruned + 1))
  done < <(find "$archive_dir" -maxdepth 1 -type f -name 'source_*' -printf '%T@ %p\n' 2>/dev/null \
             | sort -n | head -n -"$keep" | cut -d' ' -f2-)

  [[ "$pruned" -gt 0 ]] && log "retention: pruned $pruned old source archive(s), keeping the newest $keep (archives cited by the findings register are never pruned)"
  return 0
}

_rotate_execution_log() {
  # execution_log.md rotation. Append-only is a correctness property (never
  # rewrite history), so this ROTATES rather than truncates: the old content
  # moves to logs/execution_log_archive/ intact.
  local exec_log="$PROJECT/work/execution_log.md"
  local max_lines="${EXECUTION_LOG_MAX_LINES:-5000}"
  if [[ "$max_lines" -gt 0 && -f "$exec_log" ]]; then
    local lines
    lines="$(wc -l < "$exec_log" 2>/dev/null || echo 0)"
    if [[ "$lines" -gt "$max_lines" ]]; then
      local arc_dir="$LOG_DIR/execution_log_archive"
      mkdir -p "$arc_dir"
      local stamp keep_lines tmp
      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      keep_lines=$((max_lines / 2))
      # Archive everything, then keep the most recent half — so the active
      # log stays useful for "what was I doing previously?" while the full
      # history survives on disk.
      cp "$exec_log" "$arc_dir/execution_log_$stamp.md"
      tmp="$(mktemp)"
      tail -n "$keep_lines" "$exec_log" > "$tmp"
      mv -f "$tmp" "$exec_log"
      log "retention: rotated execution_log.md ($lines lines) to $arc_dir/execution_log_$stamp.md, kept the most recent $keep_lines"
    fi
  fi
  return 0
}

alert() {
  # --- replace with your actual notification channel (mail, webhook, etc.) ---
  # A held circuit breaker (or a preflight failure) with no alert defeats the
  # point of having one.
  log "ALERT: $1" "alert"
}

# Load gate — refuses to start a run while the host is under genuine
# resource pressure.
#
# Deliberately a DEFERRAL, not a failure, and this distinction is the whole
# point of the design: a full disk needs a human, but high load clears
# itself. If overload were treated as a failure, three busy scheduler ticks
# would trip the circuit breaker and require manual intervention for a
# condition that would have resolved on its own within minutes. So this
# returns EXIT_RESOURCE_DEFERRED (14) and never calls record_failure —
# grouped with lock-held (10) and paused (13) as an informational skip, not
# with the 15+ failures. The disk check stays in preflight as a hard failure
# for exactly the opposite reason.
#
# Both thresholds are optional. Set MAX_LOAD_PER_CPU="" to disable the load
# gate; MIN_FREE_MEM_MB is unset (disabled) by default, since what counts as
# "low" memory varies far more between deployments than load does.
#
# Sets RESOURCE_DEFER_REASON when the run should be skipped.
resource_gate() {
  RESOURCE_DEFER_REASON=""

  local max_load="${MAX_LOAD_PER_CPU:-4.0}"
  if [[ -n "$max_load" && -r /proc/loadavg ]]; then
    local load1 cpus threshold
    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
    cpus="$(nproc 2>/dev/null || echo 1)"
    [[ "$cpus" -lt 1 ]] && cpus=1
    threshold="$(awk -v m="$max_load" -v c="$cpus" 'BEGIN{printf "%.2f", m*c}')"
    if [[ -n "$load1" ]] && awk -v l="$load1" -v t="$threshold" 'BEGIN{exit !(l>t)}'; then
      RESOURCE_DEFER_REASON="1-minute load average $load1 exceeds ${threshold} (MAX_LOAD_PER_CPU=${max_load} x ${cpus} cpu(s))"
      return
    fi
  fi

  if [[ -n "${MIN_FREE_MEM_MB:-}" && -r /proc/meminfo ]]; then
    local avail_mem_mb
    # MemAvailable is the right field here, not MemFree — it accounts for
    # reclaimable page cache, so MemFree would defer constantly on any host
    # with a warm cache, which is most of them.
    avail_mem_mb="$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
    if [[ -n "$avail_mem_mb" && "$avail_mem_mb" -lt "$MIN_FREE_MEM_MB" ]]; then
      RESOURCE_DEFER_REASON="only ${avail_mem_mb}MB memory available, below MIN_FREE_MEM_MB (${MIN_FREE_MEM_MB}MB)"
      return
    fi
  fi
}

record_failure() {
  local reason="$1"
  log "FAILURE: $reason" "failure"
  echo "Previous execution ($AGENT_NAME) failed ($reason) at $(date -Iseconds)." > "$LAST_FAILURE_FILE"

  local prev=0
  [[ -s "$FAILURE_COUNT_FILE" ]] && prev="$(cat "$FAILURE_COUNT_FILE")"
  local new=$((prev + 1))
  echo "$new" > "$FAILURE_COUNT_FILE"

  # Stale-session self-healing: a session id that's gone stale or expired
  # over a long-running deployment can otherwise look identical to a real,
  # persistent failure — every retry keeps failing the same way, and
  # eventually trips the circuit breaker for something that a fresh session
  # would have silently fixed. One failure before that trip, drop the stored
  # session id (if any) and give a plain, no-session retry a chance first.
  # Cheap and safe either way: session continuity is a cost optimization
  # only (see adapters/README.md), never a correctness dependency.
  if [[ "$new" -eq $((FAILURE_THRESHOLD - 1)) && -s "$SESSION_ID_FILE" ]]; then
    log "note: dropping stored session id before the circuit breaker trips, in case a stale/expired session (not a real failure) is the actual cause — next run starts fresh"
    rm -f "$SESSION_ID_FILE"
  fi

  if [[ "$new" -ge "$FAILURE_THRESHOLD" ]]; then
    echo "$new consecutive failures as of $(date -Iseconds): $reason" > "$HELD_FLAG"
    alert "circuit breaker tripped after $new consecutive failures ($reason)"
  fi
}

record_success() {
  local note="${1:-success}"
  log "$note" "success"
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
extract_cost_usd() { :; }

reliability_main() {
  mkdir -p "$LOG_DIR"

  if [[ -f "$HELD_FLAG" ]]; then
    log "skip: circuit breaker is held ($(cat "$HELD_FLAG"))" "breaker_held"
    exit "$EXIT_CIRCUIT_BREAKER_HELD"
  fi

  if [[ -f "$PAUSED_FLAG" ]]; then
    log "skip: paused ($(cat "$PAUSED_FLAG")) — run scripts/commands/start.sh (or the /continuous-code-auditor-start command) to resume" "paused"
    exit "$EXIT_PAUSED"
  fi

  # Checked before preflight and before the lock is taken: a deferral should
  # cost as close to nothing as possible and must not hold the lock while the
  # host is already struggling.
  resource_gate
  if [[ -n "${RESOURCE_DEFER_REASON:-}" ]]; then
    log "defer: $RESOURCE_DEFER_REASON — skipping this tick, will retry on the next one (not a failure; does not count toward the circuit breaker)" "resource_deferred"
    exit "$EXIT_RESOURCE_DEFERRED"
  fi

  # Before preflight, so pruning can free space ahead of the disk gate rather
  # than after it has already hard-failed the run.
  enforce_retention

  PREFLIGHT_FAILED=""
  if [[ -z "${MODEL_NAME:-}" || "$MODEL_NAME" == CHANGE_ME* ]]; then
    PREFLIGHT_FAILED="MODEL_NAME was never configured (still a CHANGE_ME placeholder)"
  elif ! command -v "$AGENT_BIN" >/dev/null 2>&1; then
    PREFLIGHT_FAILED="$AGENT_BIN CLI not found on PATH"
  elif [[ ! -d "$PROJECT" ]]; then
    PREFLIGHT_FAILED="PROJECT directory not found at $PROJECT"
  elif [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    PREFLIGHT_FAILED="SKILL.md not found under SKILL_DIR ($SKILL_DIR)"
  elif command -v df >/dev/null 2>&1; then
    # Disk-space check: a 24/7 process that keeps archiving and logging
    # forever will eventually hit a full disk if retention (see "Log and
    # archive retention" in workspace-and-execution.md) isn't actually being
    # enforced. Fail loudly here rather than limping into a run that then
    # fails atomic writes or lock creation halfway through. Checks the
    # filesystem that holds PROJECT (work/archives/backups all live there);
    # LOG_DIR is often the same filesystem but check it separately if not.
    local avail_mb
    avail_mb="$(df -Pm "$PROJECT" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$avail_mb" && "$avail_mb" -lt "${MIN_FREE_DISK_MB:-100}" ]]; then
      PREFLIGHT_FAILED="only ${avail_mb}MB free on the filesystem holding PROJECT ($PROJECT) — below MIN_FREE_DISK_MB (${MIN_FREE_DISK_MB:-100}). Free up space or raise the threshold if this is expected."
    fi
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
      log "skip: lock held by $(cat "$LOCK_META")" "lock_held"
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

  # Cumulative cost tracking (best-effort — only meaningful for adapters that
  # implement extract_cost_usd; a no-op elsewhere). Checked against
  # CUMULATIVE_BUDGET_USD so a long-running deployment can't silently run up
  # an unbounded bill the way an unattended process otherwise could — this is
  # a lifetime total, distinct from any per-invocation cap an adapter (e.g.
  # Claude Code's --max-budget-usd) already applies to a single run.
  if [[ -n "${CUMULATIVE_BUDGET_USD:-}" ]]; then
    local run_cost total_cost
    run_cost="$(extract_cost_usd 2>/dev/null || true)"
    if [[ "$run_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      total_cost="0"
      [[ -s "$COST_TOTAL_FILE" ]] && total_cost="$(cat "$COST_TOTAL_FILE")"
      total_cost="$(awk -v a="$total_cost" -v b="$run_cost" 'BEGIN{printf "%.6f", a+b}')"
      echo "$total_cost" > "$COST_TOTAL_FILE"
      if awk -v t="$total_cost" -v b="$CUMULATIVE_BUDGET_USD" 'BEGIN{exit !(t>=b)}'; then
        echo "cumulative spend \$$total_cost reached/exceeded CUMULATIVE_BUDGET_USD (\$$CUMULATIVE_BUDGET_USD) as of $(date -Iseconds)" > "$PAUSED_FLAG"
        alert "paused: cumulative spend \$$total_cost reached the configured budget \$$CUMULATIVE_BUDGET_USD"
      fi
    fi
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
