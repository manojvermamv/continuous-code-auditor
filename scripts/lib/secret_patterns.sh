#!/usr/bin/env bash
# scripts/lib/secret_patterns.sh
#
# Detects credential-shaped strings that have leaked into the auditor's OWN
# outputs — the findings register, closure report, candidate fixes, and
# state files under work/.
#
# The risk this addresses is specific and easy to miss: the auditor cites
# file-and-line evidence from the audited source. If a finding is about a
# hardcoded credential, the natural way to cite it is to quote the line —
# which copies the live secret into a long-lived, often shared, often
# version-controlled report. The audited source is untrusted input; work/ is
# durable output. See references/consistency-and-safeguards.md §12 for the
# citation rule the model is supposed to follow; this file is the mechanical
# backstop for when it doesn't.
#
# NOT a secret scanner for the audited codebase — that's the audit's job,
# not the wrapper's. This only ever reads work/.
#
# Sourced by scripts/commands/doctor.sh and tests/run_tests.sh; not run
# directly.

# Patterns are deliberately anchored on well-known, high-signal prefixes and
# explicit assignment shapes rather than generic entropy heuristics. A noisy
# detector that cries wolf on every base64 blob in a report gets ignored,
# which is worse than not having one — so this errs toward precision.
_SECRET_PATTERNS=(
  'sk-[A-Za-z0-9]{16,}'                                  # OpenAI-style
  'sk-ant-[A-Za-z0-9_-]{16,}'                            # Anthropic
  'gh[pousr]_[A-Za-z0-9]{20,}'                           # GitHub tokens
  'github_pat_[A-Za-z0-9_]{20,}'                         # GitHub fine-grained PAT
  'AKIA[0-9A-Z]{16}'                                     # AWS access key id
  'ASIA[0-9A-Z]{16}'                                     # AWS temporary key id
  'AIza[0-9A-Za-z_-]{30,}'                               # Google API key
  'xox[baprs]-[A-Za-z0-9-]{10,}'                         # Slack
  'glpat-[A-Za-z0-9_-]{16,}'                             # GitLab PAT
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'                   # PEM private keys
  '(password|passwd|secret|api_key|apikey|access_token|auth_token|private_key)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{8,}["'"'"']'
)

# scan_for_secrets <dir>
# Echoes one "file:line: <pattern-name>" per hit; returns 0 if any hit was
# found, 1 if clean. Never prints the matched value itself — printing the
# secret to diagnose a leaked secret would just leak it somewhere new.
scan_for_secrets() {
  local dir="$1"
  local found=1
  [[ -d "$dir" ]] || return 1

  local file pattern raw
  raw="$(mktemp)"
  while IFS= read -r file; do
    for pattern in "${_SECRET_PATTERNS[@]}"; do
      # -I skips binary files; -n gives line numbers. Only the location is
      # ever captured — printing the matched value to diagnose a leaked
      # secret would just leak it somewhere new.
      # `--` is required: the PEM pattern starts with dashes, which grep
      # otherwise parses as options. Without it that pattern silently never
      # matches — i.e. private keys, the highest-severity thing here, go
      # undetected while everything looks fine.
      grep -InE -- "$pattern" "$file" 2>/dev/null | cut -d: -f1 | while IFS= read -r ln; do
        [[ -n "$ln" ]] && printf '%s:%s: credential-shaped string\n' "$file" "$ln"
      done >> "$raw"
    done
  done < <(find "$dir" -maxdepth 2 -type f \( -name '*.md' -o -name '*.json' -o -name '*.txt' \) 2>/dev/null)

  # A single line often matches several patterns at once (an assignment
  # containing a known-prefix token hits both). Report each location once.
  if [[ -s "$raw" ]]; then
    sort -u "$raw"
    found=0
  fi
  rm -f "$raw"
  return $found
}
