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
# A minimal fake jq that actually evaluates the two filter shapes this
# project's runners use against JSONL/JSON input:
#   select(.type == "X")              [ | .field ]
#   select(has("field"))              [ | .field ]
# with recursive descent through nested objects, closely enough to properly
# exercise scripts/runners/run_with_codex-cli.sh's session-id extraction and
# turn.failed detection, and run_with_opencode.sh / run_with_claude-code.sh's
# has("session_id")-style extraction and Claude Code's cost extraction. An
# earlier version of this mock only handled the .type== shape — it silently
# never exercised the has(...) shape at all, which looked like passing tests
# but wasn't actually testing that code path. Still not real jq; still not a
# substitute for testing against the real CLIs (see adapters/README.md point 7).
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

def walk_objects(obj):
    """Mimics `.. | objects` — every object at any depth, self included."""
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from walk_objects(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_objects(v)

def parse_json_stream(text):
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue

# Each `//`-separated alternative is tried in order, first match wins —
# mimics jq's // operator well enough for the filters this project uses.
alternatives = [a.strip() for a in filter_str.split("//")]

type_re = re.compile(r'select\(\.type\??\s*==\s*"([^"]+)"\)(?:\s*\|\s*\.(\w+))?')
has_re = re.compile(r'select\(has\("([^"]+)"\)\)(?:\s*\|\s*\.(\w+))?')

result = None
for alt in alternatives:
    if alt == "empty":
        continue
    m = type_re.search(alt)
    if m:
        want_type, field = m.group(1), m.group(2)
        for doc in parse_json_stream(text):
            for obj in walk_objects(doc):
                if obj.get("type") == want_type:
                    result = obj.get(field) if field else obj
                    break
            if result is not None:
                break
    else:
        m = has_re.search(alt)
        if m:
            want_key, field = m.group(1), m.group(2)
            for doc in parse_json_stream(text):
                for obj in walk_objects(doc):
                    if want_key in obj:
                        result = obj.get(field if field else want_key)
                        break
                if result is not None:
                    break
    if result is not None:
        break

if result is not None:
    print(result if isinstance(result, str) else json.dumps(result))

if exit_status_mode:
    sys.exit(0 if result is not None else 1)
PYEOF
  chmod +x "$bindir/jq"
}
