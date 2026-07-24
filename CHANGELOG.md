# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versioning follows [Semantic Versioning](https://semver.org/).

## [1.1.0] — long-running reliability upgrades

Prompted by a direct question: given this is meant to run unattended for months, what's actually still missing? Five gaps were verified against the code (not assumed) and closed. All additive — nothing in the frozen `v1.0.0` contract (adapter hook signatures, exit codes, operational commands) changed shape; one new optional hook was added.

### Added
- **Scheduler-liveness watchdog** (`scripts/watchdog.sh` + its own systemd timer/cron entry) — detects a dead *scheduler*, a failure mode the circuit breaker structurally cannot see, since it only reacts to executions that actually happen. Runs independently, on its own schedule, so a dead main timer doesn't take the watchdog down with it.
- **Stale-session self-healing** — `scripts/lib/reliability.sh` now drops a stored session id one failure before the circuit breaker would trip, so a session gone stale over a long deployment doesn't masquerade as a persistent failure needing operator intervention.
- **Disk-space preflight check** — refuses to start below `MIN_FREE_DISK_MB` (default 100) free on the filesystem holding `PROJECT`.
- **Cumulative cost ceiling** — new optional `extract_cost_usd` adapter hook (implemented for Claude Code, whose `--output-format json` reports `total_cost_usd`; a documented no-op for the others) plus `CUMULATIVE_BUDGET_USD` in config — auto-pauses (via the existing pause mechanism) when lifetime spend reaches the configured budget.
- **Deterministic maintenance cadence** — `audit_state.json` schema bumped 3→4, adding a `maintenance` object (`executions_since_periodic_check`, `last_periodic_check_at`) so the periodic spot-check/governance-consolidation/reconciliation cadence in `references/consistency-and-safeguards.md` is two counters the model checks, not something it has to recall across months of stateless executions.
- Expanded `tests/lib/mock_bins.sh`'s mock `jq` to actually evaluate `select(has("field"))`-style filters, not just `select(.type == "X")` — the previous version silently never exercised opencode/Claude Code's session-id extraction or the new cost-extraction hook at all, despite tests reporting green. `tests/run_tests.sh` now asserts real values for both.

### Changed
- `audit_state.json`'s `schema_version` is 4. Old field additive, no migration needed — see `ROADMAP.md` item 4.

## [1.0.0] — stabilization baseline

This is the first version treated as a frozen, stable contract rather than an evolving prototype. Everything below existed before this tag; tagging it 1.0.0 marks the point where the adapter contract (`scripts/lib/reliability.sh`'s hooks: `invoke_agent`, `extract_session_id`, `classify_failure`, `agent_specific_preflight`), the exit-code contract, and the operational-commands interface are considered stable — changes to any of them going forward are breaking changes and should bump the major version.

### Added
- Core continuous audit skill: resumable state machine, evidence discipline, contradiction detection, mistake ledger, negative-knowledge registry, circuit breaker, atomic writes.
- Multi-agent architecture: a CLI-agnostic reliability engine (`scripts/lib/reliability.sh`) plus five adapters — opencode, Claude Code, Gemini CLI, Codex CLI, Hermes Agent — each documented and tested against a mocked binary.
- Generalized audit targets: a single file, several named files, or a whole project directory, configured via `AUDIT_TARGET`.
- Operational command layer: `status`, `start`, `stop`, `archive`, `backup-everything`, `uninstall`, `reset` — deterministic scripts, with native slash-command registration for Claude Code and Gemini CLI and a universal natural-language/literal-text fallback in `SKILL.md` for every other CLI.
- `installer/install.sh` — interactive and flag-driven installation, including scheduler (systemd/cron) setup and slash-command registration.
- `tests/` — a mocked-CLI integration test suite (`tests/run_tests.sh`) and a standalone frontmatter/spec validator, both runnable locally and in CI.
- `.github/workflows/ci.yml` — shellcheck, markdown-link validation, frontmatter validation, and the integration test suite, run on every push/PR.
- `LICENSE` (MIT), author/repository metadata.

### Known limitations (tracked, not regressions)
- Session-id extraction for opencode, Claude Code, and Hermes is best-effort against an unconfirmed JSON field name — see the relevant `adapters/<cli>.md` for how to verify it against your installed version. Codex CLI's is confirmed; Gemini CLI doesn't need one (uses its own `--resume latest`).
- No native slash-command mechanism was confirmed for opencode, Codex CLI, or Hermes at the time of writing; those rely on `SKILL.md`'s universal fallback rather than a registered `/name` command.

See [`ROADMAP.md`](ROADMAP.md) for what's deliberately deferred past this release.
