#!/usr/bin/env bash
# tests/lib/mock_bins.sh
#
# Reusable mock agent-CLI binaries for the integration test suite. Sourced
# by tests/run_tests.sh, not run directly. These are NOT a substitute for
# testing against the real CLIs — see adapters/README.md point 7 — they
# exist to test this repo's own bash logic (dispatch, locking, circuit
# breaker, pause/resume, exit-code mapping) in isolation from any real
# agent CLI, quickly and offline.

# write_success_mocks <bindir>
# Every supported CLI's binary succeeds and reports AUDITOR_EXIT_REASON: success.
write_success_mocks() {
  local bindir="$1"
  mkdir -p "$bindir"
  for bin in opencode claude gemini codex hermes; do
    cat > "$bindir/$bin" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"thread.started","id":"mock-session-1"}'
echo 'AUDITOR_EXIT_REASON: success'
exit 0
EOF
    chmod +x "$bindir/$bin"
  done
  write_mock_jq_no_match "$bindir"
}

# write_failure_mocks <bindir>
# Every supported CLI's binary exits non-zero, no sentinel.
write_failure_mocks() {
  local bindir="$1"
  mkdir -p "$bindir"
  for bin in opencode claude gemini codex hermes; do
    cat > "$bindir/$bin" <<'EOF'
#!/usr/bin/env bash
echo "mock: simulated failure" >&2
exit 1
EOF
    chmod +x "$bindir/$bin"
  done
  write_mock_jq_no_match "$bindir"
}

# write_mock_jq_no_match <bindir>
# A jq stand-in that never matches anything (exit 1, no output) — enough to
# exercise "extraction found nothing" and "no turn.failed event" code paths
# without needing real jq installed.
write_mock_jq_no_match() {
  local bindir="$1"
  cat > "$bindir/jq" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bindir/jq"
}

# write_mock_jq_matching <bindir>
# A minimal fake jq that actually evaluates `select(.type == "X")` and
# `select(.type == "X") | .id` against JSONL input — enough to properly
# exercise scripts/runners/run_with_codex-cli.sh's session-id extraction
# and turn.failed detection, which write_mock_jq_no_match can't.
write_mock_jq_matching() {
  local bindir="$1"
  cat > "$bindir/jq" <<'PYEOF'
#!/usr/bin/env python3
import sys, json, re
args = sys.argv[1:]
exit_status_mode = "-e" in args
args = [a for a in args if a not in ("-e", "-r", "-n", "-c")]
filter_str = args[0] if args else ""
input_path = args[1] if len(args) > 1 else None
text = open(input_path).read() if input_path else sys.stdin.read()
m = re.search(r'select\(\.type\s*==\s*"([^"]+)"\)(?:\s*\|\s*\.(\w+))?', filter_str)
matched_any = False
if m:
    want_type, field = m.group(1), m.group(2)
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == want_type:
            matched_any = True
            print(obj.get(field, "") if field else json.dumps(obj))
if exit_status_mode:
    sys.exit(0 if matched_any else 1)
PYEOF
  chmod +x "$bindir/jq"
}
