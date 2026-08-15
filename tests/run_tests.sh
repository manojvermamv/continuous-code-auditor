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
echo "-- AUDIT_CONTEXT actually reaches the agent (v1.1.2: it previously did not) --"
CAPTURE="$TMP_ROOT/captured_msg.txt"
cat > "$BINDIR/opencode" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do echo "ARG: \$a"; done > "$CAPTURE"
echo 'AUDITOR_EXIT_REASON: success'
exit 0
EOF
chmod +x "$BINDIR/opencode"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "opencode"
sed -i 's|^AUDIT_TARGET=.*|AUDIT_TARGET="src/a.py src/b.py"|' "$CONFIG"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "AUDIT_TARGET reaches the agent" "0" "$(grep -q 'AUDIT_TARGET=src/a.py src/b.py' "$CAPTURE"; echo $?)"
check "PROJECT reaches the agent" "0" "$(grep -q "PROJECT=$PROJECT" "$CAPTURE"; echo $?)"
sed -i "s|^AUDIT_TARGET=.*|AUDIT_TARGET=\"target.py\"|" "$CONFIG"

echo "-- prior-failure note still carried into the next run's message --"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_failure_mocks "$BINDIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
cat > "$BINDIR/opencode" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do echo "ARG: \$a"; done > "$CAPTURE"
echo 'AUDITOR_EXIT_REASON: success'
exit 0
EOF
chmod +x "$BINDIR/opencode"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "PRIOR_RUN_FAILURE_NOTE reaches the agent" "0" "$(grep -q 'PRIOR_RUN_FAILURE_NOTE' "$CAPTURE"; echo $?)"
rm -f "$LOG_DIR/held.flag" "$LOG_DIR/consecutive_failures.txt"
write_success_mocks "$BINDIR"

echo
echo "-- load gate: resource pressure defers (exit 14) rather than failing (v1.3.0) --"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "opencode"
write_success_mocks "$BINDIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "load gate: normal load runs fine" "0" "$?"

cp "$CONFIG" "$TMP_ROOT/conf.noload"
echo 'MAX_LOAD_PER_CPU="-1"' >> "$CONFIG"   # impossible to satisfy -> always defers
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "load gate: over threshold defers with exit 14" "14" "$?"

# The core property: a deferral is self-clearing, so it must never advance
# the circuit breaker. Three deferrals in a row must still leave it untripped.
for _ in 1 2 3; do PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1; done
check "load gate: repeated deferrals do NOT trip the circuit breaker" "0" "$([[ ! -f "$LOG_DIR/held.flag" ]]; echo $?)"
check "load gate: deferrals do NOT increment consecutive failures" "0" "$([[ ! -s "$LOG_DIR/consecutive_failures.txt" ]] || [[ "$(cat "$LOG_DIR/consecutive_failures.txt")" == "0" ]]; echo $?)"

cp "$TMP_ROOT/conf.noload" "$CONFIG"
echo 'MIN_FREE_MEM_MB="99999999"' >> "$CONFIG"   # impossible -> always defers
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "memory gate: below minimum defers with exit 14" "14" "$?"

cp "$TMP_ROOT/conf.noload" "$CONFIG"
echo 'MAX_LOAD_PER_CPU=""' >> "$CONFIG"          # explicitly disabled
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "load gate: can be disabled with an empty MAX_LOAD_PER_CPU" "0" "$?"
cp "$TMP_ROOT/conf.noload" "$CONFIG"

echo
echo "-- adapter capability matrix is verified against real behavior (v1.7.0) --"
bash "$SKILL_DIR/tests/verify_capabilities.sh" "$SKILL_DIR" >"$TMP_ROOT/cap.txt" 2>&1
check "capabilities.json matches observed adapter behavior" "0" "$?"
check "every adapter has a matrix entry (none missing)" "0" "$(grep -c 'MISSING from capabilities.json' "$TMP_ROOT/cap.txt" || true)"

echo
echo "-- observability: version stamp, structured logs, --help/--dry-run (v1.6.0) --"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "opencode"
echo 'LOG_FORMAT="text,json"' >> "$CONFIG"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "human log carries the version stamp" "0" "$(grep -qE '\([0-9]+\.[0-9]+\.[0-9]+\)' "$LOG_DIR/auditor.log"; echo $?)"
check "structured auditor.jsonl is written when LOG_FORMAT includes json" "0" "$([[ -s "$LOG_DIR/auditor.jsonl" ]]; echo $?)"
check "every jsonl line is valid JSON with the expected fields" "0" "$(python3 -c "
import json,sys
for l in open('$LOG_DIR/auditor.jsonl'):
    l=l.strip()
    if not l: continue
    d=json.loads(l)
    assert all(k in d for k in ('ts','version','agent','event','project','message'))
" >/dev/null 2>&1; echo $?)"

# JSON must survive hostile content — quotes and backslashes in a failure message
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
printf '#!/usr/bin/env bash\necho %s >&2\nexit 1\n' "'he said \"boom\" \\ C:\\temp'" > "$BINDIR/opencode"
chmod +x "$BINDIR/opencode"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "jsonl stays valid when messages contain quotes and backslashes" "0" "$(python3 -c "
import json
for l in open('$LOG_DIR/auditor.jsonl'):
    l=l.strip()
    if l: json.loads(l)
" >/dev/null 2>&1; echo $?)"
rm -f "$LOG_DIR/held.flag" "$LOG_DIR/consecutive_failures.txt"
write_success_mocks "$BINDIR"

# text-only (the default) must not create the jsonl file
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"; write_config "opencode"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "default LOG_FORMAT does not create auditor.jsonl" "0" "$([[ ! -e "$LOG_DIR/auditor.jsonl" ]]; echo $?)"

check "--help exits 0" "0" "$(bash "$SKILL_DIR/scripts/run_auditor.sh" --help >/dev/null 2>&1; echo $?)"
check "--version prints a semver" "0" "$(bash "$SKILL_DIR/scripts/run_auditor.sh" --version 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; echo $?)"

# --dry-run must report without invoking, locking, or writing
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" --dry-run >"$TMP_ROOT/dry.txt" 2>&1
check "--dry-run exits 0 on a healthy install" "0" "$?"
check "--dry-run says what would happen" "0" "$(grep -q 'a real run would' "$TMP_ROOT/dry.txt"; echo $?)"
check "--dry-run writes nothing to LOG_DIR" "0" "$([[ -z "$(ls -A "$LOG_DIR" 2>/dev/null)" ]]; echo $?)"

echo
echo "-- retention: archives and logs are actually pruned, not just documented (v1.5.0) --"
rm -rf "$LOG_DIR" "$PROJECT/archives"; mkdir -p "$LOG_DIR" "$PROJECT/archives" "$PROJECT/work"
write_config "opencode"
echo 'ARCHIVE_RETENTION_COUNT=5' >> "$CONFIG"
for i in $(seq -w 1 20); do touch "$PROJECT/archives/source_ret$i.py"; sleep 0.01; done
printf 'F-0001 evidence: archives/source_ret01.py line 42\n' > "$PROJECT/work/continuous_code_audit_findings.md"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
ARC_LEFT="$(find "$PROJECT/archives" -name 'source_ret*' | wc -l | tr -d ' ')"
check "retention: prunes old archives (20 -> 6: newest 5 + 1 cited)" "6" "$ARC_LEFT"
check "retention: never prunes an archive cited by the findings register" "0" "$([[ -f "$PROJECT/archives/source_ret01.py" ]]; echo $?)"
rm -f "$PROJECT/work/continuous_code_audit_findings.md"

# Log rotation must work independently of archive pruning — an earlier draft
# coupled them via an early return, silently disabling rotation.
rm -rf "$LOG_DIR" "$PROJECT/archives"; mkdir -p "$LOG_DIR"
write_config "opencode"
echo 'EXECUTION_LOG_MAX_LINES=100' >> "$CONFIG"
seq 1 500 | sed 's/^/entry /' > "$PROJECT/work/execution_log.md"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "retention: rotates execution_log.md when oversized" "50" "$(wc -l < "$PROJECT/work/execution_log.md" | tr -d ' ')"
check "retention: rotation preserves full history in the archive" "500" "$(cat "$LOG_DIR/execution_log_archive/"*.md 2>/dev/null | wc -l | tr -d ' ')"
check "retention: rotation keeps the most recent entries" "0" "$(tail -1 "$PROJECT/work/execution_log.md" | grep -q 'entry 500'; echo $?)"
check "retention: log rotation runs even when archives/ does not exist" "0" "$([[ ! -d "$PROJECT/archives" ]]; echo $?)"

# Retention must be disableable
rm -rf "$LOG_DIR" "$PROJECT/archives"; mkdir -p "$LOG_DIR" "$PROJECT/archives"
write_config "opencode"
echo 'ARCHIVE_RETENTION_COUNT=0' >> "$CONFIG"
for i in $(seq -w 1 10); do touch "$PROJECT/archives/source_keep$i.py"; done
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/run_auditor.sh" >/dev/null 2>&1
check "retention: ARCHIVE_RETENTION_COUNT=0 disables pruning" "10" "$(find "$PROJECT/archives" -name 'source_keep*' | wc -l | tr -d ' ')"
rm -rf "$PROJECT/archives"; write_config "opencode"

echo
echo "-- secret redaction: credential leaks in work/ are detected (v1.4.0) --"
source "$SKILL_DIR/scripts/lib/secret_patterns.sh"
SECRET_TMP="$TMP_ROOT/secretscan"
mkdir -p "$SECRET_TMP"
printf 'F-0001 at config.py:42 — a static provider key, value redacted. See source.\n' > "$SECRET_TMP/clean.md"
scan_for_secrets "$SECRET_TMP" >/dev/null 2>&1
check "scanner: properly redacted findings are clean" "1" "$?"

printf 'Evidence: config.py:42 reads api_key = "sk-abcd1234efgh5678ijkl"\n' > "$SECRET_TMP/leaked.md"
scan_for_secrets "$SECRET_TMP" >/dev/null 2>&1
check "scanner: detects a leaked provider token" "0" "$?"

printf 'AWS_KEY = AKIAIOSFODNN7EXAMPLE\n' > "$SECRET_TMP/leaked_aws.md"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$SECRET_TMP/leaked_pem.md"
SCAN_OUT="$(scan_for_secrets "$SECRET_TMP")"
check "scanner: detects AWS key ids" "0" "$(printf '%s' "$SCAN_OUT" | grep -q leaked_aws; echo $?)"
check "scanner: detects PEM private keys" "0" "$(printf '%s' "$SCAN_OUT" | grep -q leaked_pem; echo $?)"
check "scanner: never echoes the secret value itself" "1" "$(printf '%s' "$SCAN_OUT" | grep -qE 'sk-abcd|AKIAIOSF'; echo $?)"
check "scanner: reports each location once (no duplicate lines)" "0" "$([[ "$(printf '%s\n' "$SCAN_OUT" | wc -l)" -eq "$(printf '%s\n' "$SCAN_OUT" | sort -u | wc -l)" ]]; echo $?)"

# doctor must escalate a leak to a blocking FAIL, not a warning
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"; write_config "opencode"
mkdir -p "$PROJECT/work"
printf 'Evidence: api_key = "sk-abcd1234efgh5678ijkl"\n' > "$PROJECT/work/continuous_code_audit_findings.md"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/commands/doctor.sh" >"$TMP_ROOT/doc_leak.txt" 2>&1
check "doctor: a credential leak is a blocking FAIL (exit 1)" "1" "$?"
check "doctor: does not print the leaked value in its report" "1" "$(grep -q 'sk-abcd1234efgh5678ijkl' "$TMP_ROOT/doc_leak.txt"; echo $?)"
rm -f "$PROJECT/work/continuous_code_audit_findings.md"

echo
echo "-- repo hygiene: every script is executable (exit 126 otherwise, which looks like a logic bug but isn't) --"
NONEXEC="$(find "$SKILL_DIR" -name "*.sh" ! -perm -u+x | wc -l | tr -d ' ')"
check "all .sh files carry the executable bit" "0" "$NONEXEC"

echo
echo "-- uninstall: removes installed slash-command files, not just the skill link (v1.3.1) --"
FAKE_CMD_DIR="$HOME/.claude/commands"
mkdir -p "$FAKE_CMD_DIR"
touch "$FAKE_CMD_DIR/continuous-code-auditor-doctor.md" "$FAKE_CMD_DIR/continuous-code-auditor-status.md"
touch "$FAKE_CMD_DIR/unrelated-other-tool.md"
bash "$SKILL_DIR/scripts/commands/uninstall.sh" >/dev/null 2>&1
check "uninstall removes this skill's command files" "0" "$([[ ! -e "$FAKE_CMD_DIR/continuous-code-auditor-doctor.md" && ! -e "$FAKE_CMD_DIR/continuous-code-auditor-status.md" ]]; echo $?)"
check "uninstall leaves unrelated command files alone" "0" "$([[ -e "$FAKE_CMD_DIR/unrelated-other-tool.md" ]]; echo $?)"
rm -rf "$FAKE_CMD_DIR"

echo
echo "-- doctor: diagnostics (v1.2.0) --"
# healthy config: exit 0
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
write_config "opencode"
write_success_mocks "$BINDIR"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/commands/doctor.sh" >/dev/null 2>&1
check "doctor: healthy install exits 0" "0" "$?"

# missing config must be DIAGNOSED, not crashed on
AUDITOR_CONFIG="$TMP_ROOT/definitely-not-here.conf" bash "$SKILL_DIR/scripts/commands/doctor.sh" >"$TMP_ROOT/doc_out.txt" 2>&1
check "doctor: missing config exits 1" "1" "$?"
check "doctor: missing config is reported, not a crash" "0" "$(grep -q 'no config file at' "$TMP_ROOT/doc_out.txt"; echo $?)"

# broken config: unset model + nonexistent project => FAILs, exit 1
cp "$CONFIG" "$TMP_ROOT/conf.good"
sed -i 's|^MODEL_NAME=.*|MODEL_NAME="CHANGE_ME-x"|' "$CONFIG"
sed -i "s|^PROJECT=.*|PROJECT=\"$TMP_ROOT/no-such-project\"|" "$CONFIG"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/commands/doctor.sh" >"$TMP_ROOT/doc_out2.txt" 2>&1
check "doctor: broken install exits 1" "1" "$?"
check "doctor: flags the placeholder MODEL_NAME" "0" "$(grep -q 'MODEL_NAME is unset or still the placeholder' "$TMP_ROOT/doc_out2.txt"; echo $?)"
check "doctor: flags the missing PROJECT" "0" "$(grep -q 'PROJECT directory does not exist' "$TMP_ROOT/doc_out2.txt"; echo $?)"
check "doctor: every FAIL carries a fix hint" "0" "$(awk '/^  \[FAIL\]/{getline nxt; if (nxt !~ /fix:/) bad=1} END{exit bad?1:0}' "$TMP_ROOT/doc_out2.txt"; echo $?)"
cp "$TMP_ROOT/conf.good" "$CONFIG"

# doctor must never mutate state
BEFORE_STATE="$(ls -A "$LOG_DIR" 2>/dev/null | sort | tr '\n' ' ')"
PATH="$BINDIR:$PATH" bash "$SKILL_DIR/scripts/commands/doctor.sh" >/dev/null 2>&1
AFTER_STATE="$(ls -A "$LOG_DIR" 2>/dev/null | sort | tr '\n' ' ')"
check "doctor: is read-only (does not change LOG_DIR contents)" "$BEFORE_STATE" "$AFTER_STATE"

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
