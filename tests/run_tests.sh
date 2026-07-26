#!/usr/bin/env bash
# tests/run_tests.sh
#
# Integration test suite for continuous-code-auditor. Exercises the
# reliability engine, all five adapters, and the seven operational commands
# against mocked CLI binaries — offline, fast, and repeatable. Exit 0 if
# every check passes, 1 otherwise (so CI can gate on it).
#
# Does NOT touch the repo's own config/ directory — every test run uses its
# own AUDITOR_CONFIG pointed at a throwaway temp file, and its own $HOME and
# workspace under a temp directory, all cleaned up on exit regardless of
# pass/fail.
#
# Usage: tests/run_tests.sh

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/tests/lib/mock_bins.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected [$expected], got [$actual])"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$desc")
  fi
}

TMP_ROOT="$(mktemp -d)"
export HOME="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
LOG_DIR="$TMP_ROOT/logs"
BINDIR="$TMP_ROOT/bin"
CONFIG="$TMP_ROOT/auditor.conf"
export AUDITOR_CONFIG="$CONFIG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$HOME"
touch "$PROJECT/target.py"

write_config() {
  local agent_cli="$1"
  cat > "$CONFIG" <<EOF
AGENT_CLI="$agent_cli"
MODEL_NAME="test/model"
PROJECT="$PROJECT"
AUDIT_TARGET="target.py"
LOG_DIR="$LOG_DIR"
TIMEOUT_SECONDS=30
FAILURE_THRESHOLD=3
LOCK="$TMP_ROOT/test.lock"
EOF
}

install_skill_for() {
  local dirname="$1"
  mkdir -p "$HOME/.$dirname/skills/continuous-code-auditor"
  cp "$SKILL_DIR/SKILL.md" "$HOME/.$dirname/skills/continuous-code-auditor/SKILL.md"
}
install_skill_for claude
install_skill_for gemini
install_skill_for codex
install_skill_for hermes

echo "== continuous-code-auditor integration tests =="
echo "(scratch dir: $TMP_ROOT)"
echo

echo "-- adapters: clean success --"
write_success_mocks "$BINDIR"
for cli in opencode claude-code gemini-cli codex-cli hermes; do
  rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
  write_config "$cli"
  PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
  check "adapter $cli: clean run exits 0" "0" "$?"
done

echo
echo "-- codex-cli: session-id extraction and turn.failed detection (needs a real filter, not the no-match stub) --"
write_success_mocks "$BINDIR"
write_mock_jq_matching "$BINDIR"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "codex-cli"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "codex-cli: succeeds with matching jq" "0" "$?"
check "codex-cli: session id extracted" "mock-session-1" "$(cat "$LOG_DIR/codex-cli_session_id.txt" 2>/dev/null || echo MISSING)"

cat > "$BINDIR/codex" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"thread.started","id":"s2"}'
echo '{"type":"turn.failed","error":"simulated"}'
exit 0
EOF
chmod +x "$BINDIR/codex"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "codex-cli: turn.failed overrides exit 0 to a failure" "40" "$?"
write_success_mocks "$BINDIR"

echo
echo "-- opencode / claude-code: session-id extraction (has(\"session_id\") shape, distinct from codex's .type shape) --"
write_mock_jq_matching "$BINDIR"
cat > "$BINDIR/opencode" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"message","session_id":"oc-session-9","content":"AUDITOR_EXIT_REASON: success"}'
exit 0
EOF
chmod +x "$BINDIR/opencode"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "opencode"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "opencode: session id extracted via has(session_id)" "oc-session-9" "$(cat "$LOG_DIR/opencode_session_id.txt" 2>/dev/null || echo MISSING)"

cat > "$BINDIR/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"result","session_id":"cc-session-7","total_cost_usd":0.05,"content":"AUDITOR_EXIT_REASON: success"}'
exit 0
EOF
chmod +x "$BINDIR/claude"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "claude-code"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "claude-code: session id extracted via has(session_id)" "cc-session-7" "$(cat "$LOG_DIR/claude-code_session_id.txt" 2>/dev/null || echo MISSING)"

echo
echo "-- cumulative cost budget (claude-code reports total_cost_usd; other adapters don't implement this hook) --"
sed -i "s|^AGENT_CLI=.*|AGENT_CLI=\"claude-code\"|" "$CONFIG"
echo 'CUMULATIVE_BUDGET_USD=0.12' >> "$CONFIG"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
for i in 1 2 3; do
  PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
done
check "cumulative cost 0.15 >= budget 0.12 -> auto-paused" "0" "$([[ -f "$LOG_DIR/paused.flag" ]]; echo $?)"
check "pause reason mentions budget" "0" "$(grep -qi budget "$LOG_DIR/paused.flag" 2>/dev/null; echo $?)"
sed -i '/^CUMULATIVE_BUDGET_USD/d' "$CONFIG"
bash "$SKILL_DIR/scripts/commands/start.sh" >/dev/null 2>&1
write_success_mocks "$BINDIR"

echo
echo "-- disk-space preflight --"
sed -i "s|^AGENT_CLI=.*|AGENT_CLI=\"opencode\"|" "$CONFIG"
echo 'MIN_FREE_DISK_MB=999999999' >> "$CONFIG"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "impossible disk requirement fails preflight" "15" "$?"
check "disk failure reason logged" "0" "$(grep -q "MB free" "$LOG_DIR/auditor.log"; echo $?)"
sed -i '/^MIN_FREE_DISK_MB/d' "$CONFIG"

echo
echo "-- stale-session self-healing (drops a bad session id before the circuit breaker trips) --"
write_failure_mocks "$BINDIR"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
echo "some-stale-session-id" > "$LOG_DIR/opencode_session_id.txt"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "session id dropped one failure before the breaker trips" "0" "$([[ ! -f "$LOG_DIR/opencode_session_id.txt" ]]; echo $?)"
rm -f "$LOG_DIR/held.flag" "$LOG_DIR/consecutive_failures.txt"
write_success_mocks "$BINDIR"

echo
echo "-- watchdog: detects a dead scheduler independently of the circuit breaker --"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
bash "$SKILL_DIR/scripts/watchdog.sh"
check "watchdog: no heartbeat yet -> exit 0 (nothing to check)" "0" "$?"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
bash "$SKILL_DIR/scripts/watchdog.sh"
check "watchdog: recent execution -> exit 0" "0" "$?"
STALE_DATE="$(date -d '2 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-2H +%Y%m%d%H%M 2>/dev/null)"
[[ -n "$STALE_DATE" ]] && touch -t "$STALE_DATE" "$LOG_DIR/auditor.log"
echo "WATCHDOG_MAX_STALE_MINUTES=30" >> "$CONFIG"
bash "$SKILL_DIR/scripts/watchdog.sh"
check "watchdog: stale execution -> exit 1 (alert)" "1" "$?"
check "watchdog: alert actually logged" "0" "$(grep -q ALERT "$LOG_DIR/watchdog.log" 2>/dev/null; echo $?)"
sed -i '/^WATCHDOG_MAX_STALE_MINUTES/d' "$CONFIG"
bash "$SKILL_DIR/scripts/commands/stop.sh" "test" >/dev/null 2>&1
bash "$SKILL_DIR/scripts/watchdog.sh"
check "watchdog: paused -> exit 0 (no false alarm)" "0" "$?"
bash "$SKILL_DIR/scripts/commands/start.sh" >/dev/null 2>&1
write_success_mocks "$BINDIR"

echo
echo "-- preflight, locking, circuit breaker --"
write_config "opencode"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
cp "$CONFIG" "$TMP_ROOT/conf.bak"
sed -i 's|^MODEL_NAME=.*|MODEL_NAME="CHANGE_ME-x"|' "$CONFIG"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "preflight failure on unconfigured model" "15" "$?"
cp "$TMP_ROOT/conf.bak" "$CONFIG"

rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
cat > "$TMP_ROOT/hold_lock.sh" <<EOF
#!/usr/bin/env bash
exec 200>"$TMP_ROOT/test.lock"
flock 200
sleep 3
EOF
bash "$TMP_ROOT/hold_lock.sh" &
BGPID=$!
sleep 0.5
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "lock contention" "10" "$?"
wait "$BGPID" 2>/dev/null

write_failure_mocks "$BINDIR"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
for i in 1 2 3; do PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1; done
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "circuit breaker: held on 4th consecutive failure" "12" "$?"
[[ -f "$LOG_DIR/held.flag" ]]; check "held.flag written" "0" "$?"
rm -f "$LOG_DIR/held.flag" "$LOG_DIR/consecutive_failures.txt"
write_success_mocks "$BINDIR"

echo
echo "-- pause / resume --"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
bash "$SKILL_DIR/scripts/commands/stop.sh" "test" >/dev/null
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "paused: skip exits 13" "13" "$?"
bash "$SKILL_DIR/scripts/commands/start.sh" >/dev/null
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "resumed: run succeeds" "0" "$?"

echo
echo "-- archive / backup-everything / reset / uninstall --"
BEFORE="$(cat "$PROJECT/work/continuous_code_audit_findings.md" 2>/dev/null || echo none)"
bash "$SKILL_DIR/scripts/commands/archive.sh" "test-checkpoint" >/dev/null
AFTER="$(cat "$PROJECT/work/continuous_code_audit_findings.md" 2>/dev/null || echo none)"
check "archive: does not modify active work/" "$BEFORE" "$AFTER"
find "$PROJECT/work/archives" -maxdepth 1 -name "*test-checkpoint*" 2>/dev/null | grep -q .
check "archive: snapshot created" "0" "$?"

bash "$SKILL_DIR/scripts/commands/backup-everything.sh" >/dev/null 2>&1
BACKUP_COUNT=$(find "$PROJECT/backups" -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
[[ "$BACKUP_COUNT" -ge 1 ]]; check "backup-everything: tarball created" "0" "$?"

echo
echo "-- path-traversal regression (CVE-class fix, v1.1.1): a malicious label must not escape its intended directory --"
rm -rf "$TMP_ROOT/escape-check"
bash "$SKILL_DIR/scripts/commands/archive.sh" "../../../../tmp/escape-check" >/dev/null 2>&1
[[ ! -e "$TMP_ROOT/escape-check" && ! -d "$PROJECT/tmp" ]]
check "archive.sh: path-traversal label is contained (does not escape work/archives/)" "0" "$?"

bash "$SKILL_DIR/scripts/commands/backup-everything.sh" "../../../../tmp/escape-check-2" >/dev/null 2>&1
[[ ! -e "$TMP_ROOT/escape-check-2" ]]
check "backup-everything.sh: path-traversal label is contained (does not escape backups/)" "0" "$?"

bash "$SKILL_DIR/scripts/commands/reset.sh" </dev/null >/dev/null 2>&1
check "reset: refuses without --confirm" "1" "$?"

PRE_COUNT=$(find "$PROJECT/work/archives" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
bash "$SKILL_DIR/scripts/commands/reset.sh" --confirm >/dev/null 2>&1
check "reset --confirm: succeeds" "0" "$?"
POST_COUNT=$(find "$PROJECT/work/archives" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
[[ "$POST_COUNT" -gt "$PRE_COUNT" ]]; check "reset: adds a snapshot without removing prior ones" "0" "$?"
grep -q "reset" "$PROJECT/work/continuous_code_audit_findings.md" 2>/dev/null
check "reset: work/ reinitialized with a fresh stub" "0" "$?"

bash "$SKILL_DIR/scripts/commands/uninstall.sh" >/dev/null 2>&1
[[ -d "$PROJECT/work" ]]; check "uninstall (no purge): preserves work/" "0" "$?"
bash "$SKILL_DIR/scripts/commands/uninstall.sh" --purge-data >/dev/null 2>&1
[[ ! -d "$PROJECT/work" ]]; check "uninstall --purge-data: removes work/" "0" "$?"

echo
echo "===================="
echo "PASS: $PASS   FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed checks:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
fi
echo "===================="

[[ "$FAIL" -eq 0 ]]
