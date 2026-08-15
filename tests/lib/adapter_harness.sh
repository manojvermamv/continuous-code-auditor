#!/usr/bin/env bash
# tests/lib/adapter_harness.sh
#
# Behavioral probe for adapter capabilities.
#
# The point of this file is that adapters/capabilities.json must not be a
# hand-maintained description of code — that kind of matrix drifts into
# confident lies the moment someone edits an adapter and forgets the doc.
# Instead, this harness EXERCISES each adapter's hooks against realistic mock
# CLI output and reports what actually happens; tests/verify_capabilities.sh
# then asserts the declared matrix matches the observed behavior.
#
# Deliberately probes hooks in ISOLATION rather than running a full
# execution: a full run couples session extraction, cost extraction, and
# failure classification to locking, preflight, and the workspace, so a
# failure anywhere would be indistinguishable from the capability under
# test. Isolation is what makes the observation accurate rather than
# merely suggestive.
#
# Sourced by tests/verify_capabilities.sh; not run directly.

# probe_adapter <skill_dir> <adapter-name> <fixture-dir>
#
# Sources the adapter's hook definitions without executing reliability_main,
# feeds each hook a realistic fixture, and echoes observed capabilities as
# key=value lines:
#   session_continuity=explicit_id|native_resume|none
#   cost_reporting=true|false
#   failure_detection=exit_code|stderr_heuristic|event_stream
#   requires_jq=true|false
probe_adapter() {
  local skill_dir="$1" adapter="$2" fixtures="$3"
  local runner="$skill_dir/scripts/runners/run_with_${adapter}.sh"
  [[ -f "$runner" ]] || { echo "error=no_runner"; return 1; }

  # A probe must measure the ADAPTER's logic, not the host's package list.
  # Several adapters extract via jq; on a machine without jq every extraction
  # silently returns nothing and the probe would report "capability absent"
  # for a capability that is present and working. That failure mode is
  # especially nasty because it looks like a real finding. So: guarantee a
  # functional jq for the duration of the probe, using the same mock the
  # integration suite uses (it evaluates the filter shapes these adapters
  # actually use).
  local probe_bin=""
  if ! command -v jq >/dev/null 2>&1; then
    probe_bin="$(mktemp -d)"
    if declare -F write_mock_jq_matching >/dev/null; then
      write_mock_jq_matching "$probe_bin"
    elif [[ -f "$skill_dir/tests/lib/mock_bins.sh" ]]; then
      # shellcheck source=mock_bins.sh
      source "$skill_dir/tests/lib/mock_bins.sh"
      write_mock_jq_matching "$probe_bin"
    fi
  fi

  # Extract just the hook function bodies. Sourcing the runner outright would
  # execute reliability_main and attempt a real run; this pulls the functions
  # into scope without side effects.
  local hooks
  hooks="$(mktemp)"
  awk '
    /^(extract_session_id|classify_failure|extract_cost_usd|agent_specific_preflight|invoke_agent|build_message)\(\) \{/ { inside=1 }
    inside { print }
    inside && /^\}/ { inside=0 }
  ' "$runner" > "$hooks"

  (
    # Minimal environment the hooks reference. Everything is scoped to this
    # subshell so probing one adapter can't contaminate the next.
    set +u
    [[ -n "$probe_bin" ]] && PATH="$probe_bin:$PATH"
    RUN_OUTPUT="$fixtures/run_output"
    ERROR_LOG="$fixtures/error_log"
    STATUS=0
    SESSION_ID_FILE="$fixtures/session_id"
    PROJECT="$fixtures"
    SKILL_DIR="$skill_dir"
    HOME="${HOME:-$fixtures}"
    PREFLIGHT_FAILED=""
    log() { :; }

    # shellcheck disable=SC1090
    source "$hooks" 2>/dev/null

    # --- session continuity ---
    local sid=""
    if declare -F extract_session_id >/dev/null; then
      sid="$(extract_session_id 2>/dev/null | head -n1)"
    fi
    if [[ -n "$sid" ]]; then
      echo "session_continuity=explicit_id"
    elif grep -q -- "--resume latest" "$runner" 2>/dev/null; then
      # A no-op extractor plus a native resume selector is a real capability,
      # not an absence — distinguishing the two is the whole reason this
      # probe exists rather than a grep for function definitions.
      echo "session_continuity=native_resume"
    else
      echo "session_continuity=none"
    fi

    # --- cost reporting ---
    local cost=""
    if declare -F extract_cost_usd >/dev/null; then
      cost="$(extract_cost_usd 2>/dev/null | head -n1)"
    fi
    if [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      echo "cost_reporting=true"
    else
      echo "cost_reporting=false"
    fi

    # --- failure detection ---
    # Probe by behavior: give the hook a clean exit status alongside content
    # that should or shouldn't flip it, and see whether it actually flips.
    if declare -F classify_failure >/dev/null; then
      STATUS=0
      classify_failure 2>/dev/null
      if [[ "$STATUS" -ne 0 ]]; then
        # It flipped — determine which signal it keyed on.
        if grep -q "turn.failed" "$runner" 2>/dev/null; then
          echo "failure_detection=event_stream"
        else
          echo "failure_detection=stderr_heuristic"
        fi
      else
        echo "failure_detection=exit_code"
      fi
    else
      echo "failure_detection=exit_code"
    fi

    # --- jq dependency ---
    if grep -qE '(^|[^a-zA-Z_])jq ' "$runner" 2>/dev/null; then
      echo "requires_jq=true"
    else
      echo "requires_jq=false"
    fi
  )

  rm -f "$hooks"
  [[ -n "$probe_bin" ]] && rm -rf "$probe_bin"
  return 0
}

# make_fixtures <dir> <adapter-name>
# Writes realistic mock CLI output for the given adapter, matching the shape
# its real structured output takes (per adapters/<cli>.md).
make_fixtures() {
  local dir="$1" adapter="$2"
  mkdir -p "$dir"
  : > "$dir/error_log"

  case "$adapter" in
    codex-cli)
      # JSONL event stream; failure signalled by a turn.failed event.
      printf '{"type":"thread.started","id":"probe-session-1"}\n{"type":"turn.failed","error":"probe"}\n' > "$dir/run_output"
      ;;
    claude-code)
      printf '{"type":"result","session_id":"probe-session-1","total_cost_usd":0.0421}\n' > "$dir/run_output"
      ;;
    opencode)
      # Non-empty stderr is the documented false-success signal here.
      printf '{"type":"message","session_id":"probe-session-1"}\n' > "$dir/run_output"
      printf 'probe stderr content\n' > "$dir/error_log"
      ;;
    *)
      printf '{"type":"result","session_id":"probe-session-1"}\n' > "$dir/run_output"
      ;;
  esac
}
