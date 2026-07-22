# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versioning follows [Semantic Versioning](https://semver.org/).

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
