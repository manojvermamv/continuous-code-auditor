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
