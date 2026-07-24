# Tests

Three independent checks, all offline, all runnable locally exactly as CI runs them (see `.github/workflows/ci.yml`):

| Check | Command | What it catches |
|---|---|---|
| Integration tests | `tests/run_tests.sh` | Real behavior: all five adapters, locking, the circuit breaker, pause/resume, and all seven operational commands, against mocked CLI binaries. |
| Frontmatter validation | `tests/validate_frontmatter.py` | `SKILL.md`'s frontmatter against the [agentskills.io spec](https://agentskills.io/specification) — required fields, length limits, name/directory match, and backtick-referenced files that don't exist. |
| Markdown link check | `tests/check_markdown_links.py` | Broken relative links across every `.md` file in the repo. |

Shellcheck runs in CI directly (`shellcheck scripts/**/*.sh tests/*.sh installer/install.sh`) rather than through a wrapper here — it needs no repo-specific logic.

## Running locally

```bash
cd continuous-code-auditor
bash tests/run_tests.sh
python3 tests/validate_frontmatter.py .
python3 tests/check_markdown_links.py .
shellcheck scripts/lib/*.sh scripts/runners/*.sh scripts/commands/*.sh scripts/*.sh installer/install.sh tests/run_tests.sh   # if you have shellcheck installed
```

## What the integration tests do and don't prove

`tests/lib/mock_bins.sh` provides fake `opencode`/`claude`/`gemini`/`codex`/`hermes`/`jq` binaries — enough to exercise this repo's own bash logic (dispatch, config loading, locking, the circuit breaker, exit-code mapping, the operational commands) in complete isolation from any real agent CLI or model. **This is not a substitute for testing against the real CLIs** — see `adapters/README.md` point 7. Every adapter's actual flags were checked against real `--help` output or official docs when written; the mocked tests only prove this repo's side of the contract holds, not that a given CLI version still honors the flags an adapter assumes.

The mock `jq` (`write_mock_jq_matching`) evaluates both filter shapes this project's adapters actually use — `select(.type == "X")` (Codex CLI) and `select(has("field"))` (opencode, Claude Code, and the cost-extraction hook) — with recursive descent through nested JSON. An earlier version only handled the first shape, which meant the has(...) code paths were silently never exercised at all despite the suite reporting green; if you add a filter shape no adapter has used yet, extend the mock rather than assuming it'll "probably still work" — that exact assumption was wrong once already in this project's own history.

`tests/run_tests.sh` uses `AUDITOR_CONFIG` (every script in this repo respects this env var as an override for `config/auditor.conf`'s path) plus a throwaway `$HOME` and workspace under `mktemp -d`, cleaned up on exit regardless of pass/fail — it never touches the repo's own `config/auditor.conf` or reads/writes outside its own scratch directory.

## Adding a test for a new adapter

If you add a sixth CLI adapter (see `adapters/README.md`), add its mock binary to `tests/lib/mock_bins.sh`'s `write_success_mocks`/`write_failure_mocks`, add it to the `for cli in ...` loop near the top of `tests/run_tests.sh`, and — if it has a confirmed structured-output format worth testing (like Codex CLI's `turn.failed` handling) — add a dedicated block the same way the Codex CLI section does, rather than trying to force every CLI's quirks through one generic loop.
