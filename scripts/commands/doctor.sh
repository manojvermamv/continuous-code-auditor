#!/usr/bin/env bash
# scripts/commands/doctor.sh — /continuous-code-auditor-doctor
#
# Diagnoses a broken or not-yet-working installation and tells you which
# specific thing is wrong and how to fix it, rather than making you read
# logs and cross-reference the exit-code contract yourself.
#
# Read-only: never modifies config, workspace, flags, or scheduling. Safe to
# run at any time, including mid-audit.
#
# Deliberately does NOT source _common.sh: that hard-exits when
# config/auditor.conf is missing, which is precisely the first thing this
# command needs to be able to diagnose. It loads config itself, degrading
# gracefully instead of dying.
#
# Exit codes (its own contract — see references/workspace-and-execution.md):
#   0  no FAILs (WARNs may still be present)
#   1  at least one FAIL — the installation will not work until it's fixed

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL_NAME="continuous-code-auditor"
CONFIG_FILE="${AUDITOR_CONFIG:-$SKILL_DIR/config/auditor.conf}"

FAILS=0
WARNS=0
PASSES=0

pass() { printf '  [ OK ] %s\n' "$1"; PASSES=$((PASSES + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         fix: %s\n' "$2"; WARNS=$((WARNS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         fix: %s\n' "$2"; FAILS=$((FAILS + 1)); }
section() { printf '\n%s\n' "$1"; }

echo "== continuous-code-auditor doctor =="
echo "skill dir: $SKILL_DIR"

# ---------------------------------------------------------------- config --
section "Configuration"
if [[ ! -f "$CONFIG_FILE" ]]; then
  fail "no config file at $CONFIG_FILE" \
       "cp config/auditor.conf.example config/auditor.conf && edit it, or run installer/install.sh"
  echo
  echo "Cannot check anything further without a config. Fix the above and re-run."
  exit 1
fi
pass "config file found ($CONFIG_FILE)"

# shellcheck source=../../config/auditor.conf.example
source "$CONFIG_FILE"
PROJECT="${PROJECT:-}"
LOG_DIR="${LOG_DIR:-/opt/auditor/logs}"
AUDIT_TARGET="${AUDIT_TARGET:-.}"
AGENT_CLI="${AGENT_CLI:-}"
MODEL_NAME="${MODEL_NAME:-}"
LOCK="${LOCK:-/tmp/continuous_code_auditor.lock}"

if [[ -z "$AGENT_CLI" ]]; then
  fail "AGENT_CLI is not set" "set AGENT_CLI in $CONFIG_FILE (opencode | claude-code | gemini-cli | codex-cli | hermes)"
elif [[ ! -f "$SKILL_DIR/scripts/runners/run_with_${AGENT_CLI}.sh" ]]; then
  fail "AGENT_CLI=\"$AGENT_CLI\" has no matching runner" \
       "valid values: opencode, claude-code, gemini-cli, codex-cli, hermes — or add a runner, see adapters/README.md"
else
  pass "AGENT_CLI=$AGENT_CLI (runner present)"
fi

if [[ -z "$MODEL_NAME" || "$MODEL_NAME" == CHANGE_ME* ]]; then
  fail "MODEL_NAME is unset or still the placeholder" \
       "set a real model id in $CONFIG_FILE — format varies per CLI, see adapters/$AGENT_CLI.md"
else
  pass "MODEL_NAME=$MODEL_NAME"
fi

# --------------------------------------------------------- dependencies --
section "Dependencies"
for bin in bash flock date awk; do
  if command -v "$bin" >/dev/null 2>&1; then pass "$bin present"
  else fail "$bin not found on PATH" "install it — required by scripts/lib/reliability.sh"; fi
done

if command -v jq >/dev/null 2>&1; then
  pass "jq present"
else
  case "$AGENT_CLI" in
    opencode|claude-code|codex-cli)
      fail "jq not found, but the $AGENT_CLI adapter requires it" "install jq (session-id / structured-output parsing)" ;;
    *)
      warn "jq not found (not required by the $AGENT_CLI adapter, but preflight checks for it)" "install jq to be safe" ;;
  esac
fi

AGENT_BIN=""
case "$AGENT_CLI" in
  opencode)    AGENT_BIN="opencode" ;;
  claude-code) AGENT_BIN="claude" ;;
  gemini-cli)  AGENT_BIN="gemini" ;;
  codex-cli)   AGENT_BIN="codex" ;;
  hermes)      AGENT_BIN="hermes" ;;
esac
if [[ -n "$AGENT_BIN" ]]; then
  if command -v "$AGENT_BIN" >/dev/null 2>&1; then
    pass "agent CLI binary '$AGENT_BIN' on PATH"
  else
    fail "agent CLI binary '$AGENT_BIN' not found on PATH" \
         "install it, or make sure PATH is set for the user the scheduler runs as (cron/systemd have a minimal PATH — this is a very common cause of exit 15)"
  fi
fi

# --------------------------------------------------------- skill install --
section "Adapter capabilities"
CAPS="$SKILL_DIR/adapters/capabilities.json"
if [[ -f "$CAPS" ]] && command -v python3 >/dev/null 2>&1; then
  CAP_OUT="$(python3 -c "
import json, sys
try:
    a = json.load(open('$CAPS'))['adapters']['$AGENT_CLI']
except Exception:
    sys.exit(1)
print('session continuity: ' + str(a.get('session_continuity')))
print('cost reporting:     ' + ('yes' if a.get('cost_reporting') else 'no'))
print('failure detection:  ' + str(a.get('failure_detection')))
print('native / commands:  ' + ('yes' if a.get('native_slash_commands') else 'no (universal fallback in SKILL.md)'))
" 2>/dev/null)"
  if [[ -n "$CAP_OUT" ]]; then
    pass "capability matrix entry found for $AGENT_CLI"
    printf '%s\n' "$CAP_OUT" | sed 's/^/         /'
    # Flag capabilities the operator may be assuming they have.
    if [[ "$CAP_OUT" == *"session continuity: none"* ]]; then
      warn "this adapter has no working session continuity" \
           "not a fault — every run reconstructs from the workspace regardless (see SKILL.md). It only means each run re-establishes context, so runs cost a little more."
    fi
    if [[ -n "${CUMULATIVE_BUDGET_USD:-}" && "$CAP_OUT" == *"cost reporting:     no"* ]]; then
      warn "CUMULATIVE_BUDGET_USD is set but $AGENT_CLI does not report cost — the budget is inert" \
           "only adapters with cost_reporting=yes can enforce it; see adapters/capabilities.json"
    fi
  else
    warn "no capability matrix entry for $AGENT_CLI" "run tests/verify_capabilities.sh — the matrix may be out of date"
  fi
else
  warn "capability matrix unavailable (missing file or python3)" "informational only; does not affect audit runs"
fi

section "Skill installation"
case "$AGENT_CLI" in
  claude-code|gemini-cli|codex-cli|hermes)
    case "$AGENT_CLI" in
      claude-code) sd=".claude/skills" ;;
      gemini-cli)  sd=".gemini/skills" ;;
      codex-cli)   sd=".codex/skills" ;;
      hermes)      sd=".hermes/skills" ;;
    esac
    if [[ -e "$HOME/$sd/$SKILL_NAME" ]]; then
      pass "skill installed at ~/$sd/$SKILL_NAME (personal scope)"
    elif [[ -n "$PROJECT" && -e "$PROJECT/$sd/$SKILL_NAME" ]]; then
      pass "skill installed at \$PROJECT/$sd/$SKILL_NAME (project scope)"
      [[ "$AGENT_CLI" == "gemini-cli" ]] && warn "Gemini CLI project-scope skills require a trusted workspace" "run /trust once interactively in $PROJECT — see adapters/gemini-cli.md"
    elif find "$HOME/$sd" -maxdepth 3 -path "*$SKILL_NAME*" -name SKILL.md 2>/dev/null | grep -q .; then
      pass "skill found under ~/$sd (in a category subdirectory)"
    else
      fail "skill not installed where $AGENT_CLI looks for it" \
           "run installer/install.sh, or symlink this directory into ~/$sd/$SKILL_NAME"
    fi
    ;;
  opencode)
    pass "opencode attaches SKILL.md directly — no skill-directory install needed"
    ;;
esac

# -------------------------------------------------------------- project --
section "Project and audit target"
if [[ -z "$PROJECT" ]]; then
  fail "PROJECT is not set" "set PROJECT in $CONFIG_FILE"
elif [[ ! -d "$PROJECT" ]]; then
  fail "PROJECT directory does not exist: $PROJECT" "create it, or correct PROJECT in $CONFIG_FILE"
else
  pass "PROJECT exists ($PROJECT)"
  [[ -w "$PROJECT" ]] && pass "PROJECT is writable" \
    || fail "PROJECT is not writable by $(id -un)" "chown/chmod it, or check systemd ReadWritePaths= — see references/workspace-and-execution.md"

  # AUDIT_TARGET may be "." , one path, or several space-separated paths.
  missing_targets=""
  for t in $AUDIT_TARGET; do
    case "$t" in
      /*) resolved="$t" ;;
      *)  resolved="$PROJECT/$t" ;;
    esac
    [[ -e "$resolved" ]] || missing_targets="$missing_targets $t"
  done
  if [[ -n "$missing_targets" ]]; then
    fail "AUDIT_TARGET references paths that don't exist:$missing_targets" \
         "correct AUDIT_TARGET in $CONFIG_FILE (paths are relative to PROJECT unless absolute)"
  else
    pass "AUDIT_TARGET resolves ($AUDIT_TARGET)"
  fi
fi

# ------------------------------------------------------------- log dir ---
section "Log directory and disk"
if [[ ! -d "$LOG_DIR" ]]; then
  warn "LOG_DIR does not exist yet: $LOG_DIR" "it's created on first run; mkdir -p it now if you prefer"
elif [[ ! -w "$LOG_DIR" ]]; then
  fail "LOG_DIR is not writable by $(id -un): $LOG_DIR" "chown/chmod it, or check systemd ReadWritePaths="
else
  pass "LOG_DIR writable ($LOG_DIR)"
fi

if command -v df >/dev/null 2>&1 && [[ -d "${PROJECT:-/nonexistent}" ]]; then
  avail="$(df -Pm "$PROJECT" 2>/dev/null | awk 'NR==2 {print $4}')"
  minfree="${MIN_FREE_DISK_MB:-100}"
  if [[ -n "$avail" ]]; then
    if [[ "$avail" -lt "$minfree" ]]; then
      fail "only ${avail}MB free, below MIN_FREE_DISK_MB (${minfree}MB) — preflight will refuse to run (exit 15)" \
           "free space, prune archives/ and backups/, or raise MIN_FREE_DISK_MB"
    elif [[ "$avail" -lt $((minfree * 3)) ]]; then
      warn "${avail}MB free — within 3x of the ${minfree}MB minimum" "consider pruning archives/ and backups/, see references/workspace-and-execution.md retention"
    else
      pass "disk headroom ${avail}MB (minimum ${minfree}MB)"
    fi
  fi
fi

# Load gate — a deferral, not a failure, so report it as a WARN at worst.
maxload="${MAX_LOAD_PER_CPU:-4.0}"
if [[ -z "$maxload" ]]; then
  pass "load gate disabled (MAX_LOAD_PER_CPU is empty)"
elif [[ -r /proc/loadavg ]]; then
  l1="$(awk '{print $1}' /proc/loadavg)"
  ncpu="$(nproc 2>/dev/null || echo 1)"
  thr="$(awk -v m="$maxload" -v c="$ncpu" 'BEGIN{printf "%.2f", m*c}')"
  if awk -v l="$l1" -v t="$thr" 'BEGIN{exit !(l>t)}'; then
    warn "load average $l1 currently exceeds $thr — runs are being deferred (exit 14, self-clearing)" \
         "normal under load; if persistent, the host is over-subscribed or the schedule is too aggressive"
  else
    pass "load $l1 of $thr limit (${maxload}/cpu x ${ncpu} cpu)"
  fi
else
  pass "load gate configured but /proc/loadavg unavailable — gate simply won't engage on this host"
fi

if [[ -n "${MIN_FREE_MEM_MB:-}" ]]; then
  if [[ -r /proc/meminfo ]]; then
    memavail="$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)"
    if [[ -n "$memavail" && "$memavail" -lt "$MIN_FREE_MEM_MB" ]]; then
      warn "${memavail}MB memory available, below MIN_FREE_MEM_MB (${MIN_FREE_MEM_MB}MB) — runs deferred (exit 14)" \
           "normal under pressure; self-clears"
    else
      pass "memory available ${memavail}MB (minimum ${MIN_FREE_MEM_MB}MB)"
    fi
  else
    pass "memory gate configured but /proc/meminfo unavailable — gate simply won't engage on this host"
  fi
fi

# ---------------------------------------------------------- run state ----
section "Run state"
if [[ -f "$LOG_DIR/held.flag" ]]; then
  fail "circuit breaker is HELD — no runs will happen (exit 12): $(cat "$LOG_DIR/held.flag")" \
       "fix the underlying cause, then: rm $LOG_DIR/held.flag"
else
  pass "circuit breaker not tripped"
fi

if [[ -f "$LOG_DIR/paused.flag" ]]; then
  warn "auditor is PAUSED — no runs will happen (exit 13): $(cat "$LOG_DIR/paused.flag")" \
       "resume with: scripts/commands/start.sh (or /continuous-code-auditor-start)"
else
  pass "not paused"
fi

if [[ -e "$LOCK" ]]; then
  if command -v flock >/dev/null 2>&1 && flock -n "$LOCK" true 2>/dev/null; then
    pass "lock is free"
  else
    holder="(no metadata)"
    [[ -s "$LOCK.meta" ]] && holder="$(cat "$LOCK.meta")"
    warn "lock is currently HELD by $holder" \
         "normal if a run is in progress; if it's stuck, check that PID and see the wall-clock TIMEOUT_SECONDS setting"
  fi
else
  pass "no stale lock file"
fi

if [[ -s "$LOG_DIR/consecutive_failures.txt" ]]; then
  cf="$(cat "$LOG_DIR/consecutive_failures.txt")"
  if [[ "$cf" -gt 0 ]]; then
    warn "$cf consecutive failure(s) recorded (breaker trips at ${FAILURE_THRESHOLD:-3})" \
         "see the tail of $LOG_DIR/auditor.log, and $LOG_DIR/last_failure.txt"
  else
    pass "no consecutive failures"
  fi
fi

if [[ -n "${CUMULATIVE_BUDGET_USD:-}" && -s "$LOG_DIR/cumulative_cost_usd.txt" ]]; then
  spent="$(cat "$LOG_DIR/cumulative_cost_usd.txt")"
  if awk -v s="$spent" -v b="$CUMULATIVE_BUDGET_USD" 'BEGIN{exit !(s>=b)}'; then
    warn "cumulative spend \$$spent has reached the \$$CUMULATIVE_BUDGET_USD budget (auto-paused)" \
         "review spend, then raise CUMULATIVE_BUDGET_USD and/or clear $LOG_DIR/cumulative_cost_usd.txt, then start.sh"
  else
    pass "cumulative spend \$$spent of \$$CUMULATIVE_BUDGET_USD budget"
  fi
fi

# ---------------------------------------------------------- workspace ----
section "Workspace"
if [[ -n "$PROJECT" && -d "$PROJECT/work" ]]; then
  pass "work/ exists"
  if [[ -f "$PROJECT/work/audit_state.json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      if jq -e . "$PROJECT/work/audit_state.json" >/dev/null 2>&1; then
        sv="$(jq -r '.schema_version // "missing"' "$PROJECT/work/audit_state.json" 2>/dev/null)"
        pass "audit_state.json is valid JSON (schema_version: $sv)"
      else
        fail "audit_state.json is not valid JSON — the next run will hit the recovery path" \
             "see the recovery hierarchy in references/workspace-and-execution.md, or reset.sh --confirm to archive and start fresh"
      fi
    else
      warn "audit_state.json present but jq is unavailable to validate it" "install jq"
    fi
  else
    warn "no audit_state.json yet" "normal before the first successful run"
  fi
  [[ -d "$PROJECT/work/archives" ]] && pass "work/archives/ present (reset snapshots preserved here)" \
    || warn "work/archives/ missing" "created on first archive/reset; harmless"

  # Credential-leak backstop. The audited source is untrusted input; work/ is
  # durable, often-shared output. See references/consistency-and-safeguards.md §12.
  if [[ -f "$SKILL_DIR/scripts/lib/secret_patterns.sh" ]]; then
    # shellcheck source=../lib/secret_patterns.sh
    source "$SKILL_DIR/scripts/lib/secret_patterns.sh"
    leak_out="$(scan_for_secrets "$PROJECT/work")"
    if [[ -n "$leak_out" ]]; then
      leak_count="$(printf '%s\n' "$leak_out" | wc -l | tr -d ' ')"
      fail "$leak_count credential-shaped string(s) found in work/ — a secret from the audited source may have been copied into the findings register" \
           "review the locations below and replace the literal values with redacted citations (file:line + a description). Locations only; values are deliberately not printed here."
      printf '%s\n' "$leak_out" | sed 's/^/         /'
    else
      pass "no credential-shaped strings in work/"
    fi
  fi
else
  warn "work/ does not exist yet" "created on first run, or by installer/install.sh"
fi

# ---------------------------------------------------------- scheduling ---
section "Scheduling"
sched_found=false
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${SKILL_NAME}.timer"; then
  sched_found=true
  if systemctl is-active --quiet "${SKILL_NAME}.timer" 2>/dev/null; then
    pass "systemd timer ${SKILL_NAME}.timer is active"
  else
    fail "systemd timer ${SKILL_NAME}.timer is installed but NOT active — nothing is scheduling runs" \
         "sudo systemctl enable --now ${SKILL_NAME}.timer"
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SKILL_NAME}-watchdog.timer"; then
    systemctl is-active --quiet "${SKILL_NAME}-watchdog.timer" 2>/dev/null \
      && pass "watchdog timer is active" \
      || warn "watchdog timer installed but not active" "sudo systemctl enable --now ${SKILL_NAME}-watchdog.timer"
  else
    warn "no watchdog timer installed" "the watchdog detects a dead scheduler, which the circuit breaker cannot — see references/workspace-and-execution.md"
  fi
fi
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$SKILL_DIR/scripts/run_auditor.sh"; then
  sched_found=true
  pass "cron entry found for run_auditor.sh"
  crontab -l 2>/dev/null | grep -q "$SKILL_DIR/scripts/watchdog.sh" \
    && pass "cron entry found for watchdog.sh" \
    || warn "no watchdog cron entry" "add: */10 * * * * $SKILL_DIR/scripts/watchdog.sh"
fi
if [[ "$sched_found" == false ]]; then
  warn "no scheduler found (no systemd timer, no cron entry)" \
       "runs will only happen when you invoke scripts/run_auditor.sh manually — run installer/install.sh to wire one up"
fi

# --------------------------------------------------------- last run ------
section "Last execution"
if [[ -f "$LOG_DIR/auditor.log" ]]; then
  last_ts="$(date -r "$LOG_DIR/auditor.log" +%s 2>/dev/null || echo "")"
  if [[ -n "$last_ts" ]]; then
    age_min=$(( ($(date +%s) - last_ts) / 60 ))
    if [[ "$age_min" -gt "${WATCHDOG_MAX_STALE_MINUTES:-30}" ]]; then
      warn "last execution was ${age_min} minute(s) ago (watchdog threshold: ${WATCHDOG_MAX_STALE_MINUTES:-30})" \
           "expected if paused/held; otherwise check the scheduler"
    else
      pass "last execution ${age_min} minute(s) ago"
    fi
  fi
  echo "  last log line: $(tail -n 1 "$LOG_DIR/auditor.log")"
else
  warn "no auditor.log yet — no execution has ever run" \
       "run it once manually to verify: $SKILL_DIR/scripts/run_auditor.sh; echo \"exit: \$?\""
fi

# ------------------------------------------------------------- summary ---
echo
echo "===================="
echo "PASS: $PASSES   WARN: $WARNS   FAIL: $FAILS"
if [[ "$FAILS" -gt 0 ]]; then
  echo "Installation will NOT work until the [FAIL] items above are fixed."
  echo "More detail: $SKILL_DIR/TROUBLESHOOTING.md"
  echo "===================="
  exit 1
fi
if [[ "$WARNS" -gt 0 ]]; then
  echo "No blocking problems. Review [WARN] items above if behavior seems off."
else
  echo "Everything checks out."
fi
echo "More detail: $SKILL_DIR/TROUBLESHOOTING.md"
echo "===================="
exit 0
