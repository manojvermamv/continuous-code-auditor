# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versioning follows [Semantic Versioning](https://semver.org/).

## [1.7.0] — verified adapter capability matrix

Implements ROADMAP item #1, the last low-risk item. Built with behavioral verification rather than as documentation, because a hand-maintained matrix describing code is accurate exactly once.

### Added
- **`adapters/capabilities.json`** — machine-readable capabilities per adapter: session continuity, cost reporting, failure-detection strategy, jq dependency, skill discovery, native slash commands.
- **`tests/lib/adapter_harness.sh`** — behavioral probe. Extracts each adapter's hook functions without executing a real run, feeds them realistic mock CLI output, and observes what actually happens. Probes hooks in isolation deliberately: in a full execution a failure anywhere would be indistinguishable from the capability under test.
- **`tests/verify_capabilities.sh`** — asserts declared matches observed, plus completeness in both directions (every adapter has an entry; every entry has an adapter). Wired into CI and the integration suite.
- **Capabilities surfaced in `doctor`**, including two warnings that catch silent misconfiguration: an adapter with no working session continuity, and `CUMULATIVE_BUDGET_USD` set on an adapter that cannot report cost (the budget is inert — previously undiscoverable).

### Fixed
- **The harness caught a real inaccuracy on its first run.** The Hermes adapter declared `session_continuity: explicit_id` and has a `--resume` code path — but `extract_session_id` is a deliberate no-op, so the id file is never written and `--resume` is never passed. Functionally it was `none`. Static review had missed this through several releases; the behavioral probe found it immediately. Matrix and adapter doc corrected.

### Notes
The harness supplies its own working `jq` when the host lacks one. Without that, every jq-based extraction returns nothing and the probe reports "capability absent" for capabilities that are present and working — a failure mode that is particularly dangerous because it looks exactly like a real finding. That was observed during development: 5 of 6 initial mismatches were this artifact, and only 1 was genuine.

## [1.6.0] — observability: version stamping, structured logs, dry-run

The three remaining minor gaps from the v1.5.0 architecture review. All additive; nothing in the frozen contract changed.

### Added
- **Version stamping.** `AUDITOR_VERSION` is read from `SKILL.md`'s frontmatter (single source of truth, so it can't drift from what's released) and appears on every log line, in every structured record, and in the `AUDIT_CONTEXT` block passed to the model — so `audit_state.json` can record which version produced a finding. When a months-old deployment behaves oddly, "which version wrote this line" should not require reconstructing it from timestamps against a changelog.
- **Structured logging.** `LOG_FORMAT="text,json"` additionally writes `logs/auditor.jsonl` — one JSON object per line with `ts`/`version`/`agent`/`event`/`project`/`message`, and typed events (`info`, `success`, `failure`, `alert`, `paused`, `breaker_held`, `lock_held`, `resource_deferred`). Additive by design: `auditor.log` is always written, so anything already tailing it is unaffected. Default stays `text`, so no existing deployment changes behavior.
- **`--help`, `--version`, `--dry-run` on the dispatcher.** `--dry-run` runs every check a real execution would and reports what *would* happen — without invoking the agent, taking the lock, or writing anything. It delegates the checking to `doctor.sh` rather than reimplementing it, because two copies of "is this deployment healthy?" would inevitably drift.

### Notes
JSON escaping is tested against hostile content specifically — a failure message containing quotes and backslashes is exactly how malformed JSON gets produced in practice, and it's the kind of thing that only surfaces once a log pipeline is already ingesting.

## [1.5.0] — retention enforcement (documented policy that was never implemented)

Found during an architecture review asking whether the project is genuinely production-ready for long unattended operation. It wasn't, for one specific and guaranteed reason.

### Fixed
- **Retention was documented since v1.0.0 and enforced by nothing.** `references/workspace-and-execution.md` described archive and log retention in detail; no code ever pruned anything. The only thing that deleted an archive was `uninstall --purge-data`. Over months of 5-minute runs, `archives/` and `execution_log.md` grow without bound until `MIN_FREE_DISK_MB` trips a hard preflight failure, three of those trip the circuit breaker, and the deployment halts pending manual intervention — on a system whose entire premise is running unattended for months. A documented policy nobody enforces is worse than no policy, because it reads as handled.
- `enforce_retention()` in `scripts/lib/reliability.sh` now prunes source archives (`ARCHIVE_RETENTION_COUNT`, default 50) and rotates `execution_log.md` (`EXECUTION_LOG_MAX_LINES`, default 5000). Runs before preflight, so pruning frees space *ahead of* the disk gate rather than after it has already failed the run.
- **Evidence guard:** an archive still cited by the findings register is never pruned, whatever its age. An unverifiable finding is worse than a large disk — this enforces the rule the docs already stated.
- **Rotation, not truncation:** append-only history is a correctness property, so the full log is copied to `logs/execution_log_archive/` before the active file is trimmed to its most recent half.

### Fixed during implementation
- An early `return` when `archives/` didn't exist skipped log rotation entirely, coupling two independent concerns — and silently disabling rotation on exactly the fresh deployments that run longest before anyone inspects them. Split into two independent functions.

### Added
- Seven retention tests, including the evidence guard, the independence of the two mechanisms, and that retention can be disabled.

## [1.4.0] — secret redaction in findings evidence

Implements ROADMAP item #13, the last of the small, evidence-backed, contract-safe items. Two independent projects studied earlier had hit this exact failure mode (one shipped a "privacy redaction incomplete" advisory; another added a dedicated secret type specifically so credentials couldn't be naively serialized), which is why it was on the list.

### The problem
The auditor cites file-and-line evidence from the audited source. When a finding is *about* a hardcoded credential, the natural way to cite it is to quote the line — which copies a live secret out of one system and into `work/`: a long-lived, often version-controlled, often widely-shared artifact. A contained problem becomes a distributed one, in the document meant to report it.

### Added
- **`references/consistency-and-safeguards.md` §12** — the citation rule: cite the location, describe the shape, never reproduce the value. Covers candidate fixes, reasoning fingerprints, the execution log, and stdout (which some adapters persist across sessions), plus what to do about a secret already written (redact in place, log the redaction, and say plainly that it now needs rotating — silently deleting it hides that).
- **`scripts/lib/secret_patterns.sh`** — mechanical backstop scanning `work/` for credential-shaped strings across 11 high-signal patterns (provider tokens, cloud key ids, PEM private keys, explicit credential assignments). Anchored on known prefixes rather than entropy heuristics: a detector that cries wolf gets ignored, which is worse than none.
- **`doctor.sh` integration** — a leak is a blocking `[FAIL]`, not a warning. Reports locations only; never prints the matched value, since printing a secret to diagnose a leaked secret just leaks it somewhere new.
- A guardrail line in `SKILL.md` so the model sees the rule before filing, without opening the reference.
- Eight tests, including that the scanner itself never echoes a secret and that doctor's report doesn't either.

### Fixed during implementation
- The PEM private key pattern silently never matched: its leading `-----` was being parsed by `grep` as options. Adding `--` fixed it. Worth noting because the failure mode was invisible — the highest-severity pattern in the set was disabled while every other check passed and the scanner looked healthy.

## [1.3.1] — end-to-end reconciliation

A full pass reconciling every declared contract, document, and script against actual behavior after three consecutive feature releases. Four real inconsistencies found; all fixed. No behavior changes to the audit loop itself.

### Fixed
- **The installer wrote an incomplete config.** A fresh install omitted `MIN_FREE_DISK_MB`, `MAX_LOAD_PER_CPU`, `MIN_FREE_MEM_MB`, `WATCHDOG_MAX_STALE_MINUTES`, and `CUMULATIVE_BUDGET_USD` entirely. Code defaults meant nothing broke, but operators had no way to discover the knobs existed. The generated config is now complete and self-documenting.
- **`uninstall.sh` orphaned the slash-command files.** It removed the skill symlink but left all eight `/continuous-code-auditor-*` command files in `~/.claude/commands/` and `~/.gemini/commands/`, so the commands stayed visible in the CLI and failed when invoked. Now removed — scoped to this skill's own files, verified not to touch unrelated ones.
- **Stale version claims.** `ROADMAP.md` still said "current release v1.1.2" (two releases behind); `README.md` still framed the frozen contract as "v1.0.0/v1.1.0".
- **Two v1.1.0-era files were missing from the documented workspace layout** — `cumulative_cost_usd.txt` and `watchdog.log`.

### Added
- A repo-hygiene test asserting every `.sh` file carries the executable bit. Prompted by hitting it for real: a restored working copy lost its permission bits and produced 20 test failures with exit `126`, which reads like a logic bug but isn't.
- Tests for the uninstall command-file cleanup, including that unrelated files in the same directory are left alone.

### Verified consistent, no change needed
Exit codes across the library, contract table, `TROUBLESHOOTING.md`, and README · the frozen hook list vs. the five hooks actually defined · all 13 config variables both declared and consumed · every documented file reference resolving (the three intentional exceptions are the roadmap item, the per-deployment generated config, and the optional domain-focus file) · all 8 commands wired across both CLIs.

## [1.3.0] — resource gating (load + memory), generalizing the disk preflight

Implements ROADMAP item #14. The disk check from v1.1.0 was one resource; this generalizes the idea — but deliberately *not* by treating all resources the same way.

### Added
- **Load gate** (`MAX_LOAD_PER_CPU`, default 4.0) — checked before preflight and before the lock is taken. Per-CPU, so one threshold behaves sensibly on a 1-core VM and a 32-core server. Set to `""` to disable.
- **Memory gate** (`MIN_FREE_MEM_MB`, opt-in/unset by default) — uses `MemAvailable` rather than `MemFree`, so a warm page cache doesn't cause constant spurious deferrals. Off by default because "low memory" varies far more between deployments than load does.
- **New exit code `14`** — resource deferral. Grouped with the other informational skips (`10` lock-held, `12` breaker-held, `13` paused), not with the `15`+ failures.
- Load/memory headroom now reported by both `doctor.sh` and `status.sh`.
- Six tests, including the load gate's defining property: repeated deferrals must never trip the circuit breaker.

### Design note
Disk pressure and load pressure are handled deliberately differently, and the asymmetry is the point. A full disk stays a hard **failure** (exit 15) because it doesn't resolve itself and needs a human. Load and memory pressure are **deferrals** (exit 14): skipped this tick, retried next, never counted toward the circuit breaker. Had overload been treated as a failure, three busy scheduler ticks would trip the breaker and demand manual intervention to clear `held.flag` — for a condition that would have cleared on its own in minutes. Self-clearing conditions stay self-clearing.

Both gates read `/proc`, so on a non-Linux host they simply never engage rather than erroring.

## [1.2.0] — doctor command, troubleshooting guide, security policy

Implements ROADMAP item #11, the most evidence-backed remaining item (five independent confirmations of the same pattern across comparable projects), plus #12 which #11's documentation naturally depended on.

### Added
- **`/continuous-code-auditor-doctor`** (`scripts/commands/doctor.sh`) — an eighth operational command. Read-only diagnostics across config, dependencies, skill installation, project/audit-target paths, log directory, disk headroom, run state (breaker/pause/lock/failures/budget), workspace integrity, scheduling, and last-execution recency. Every `[FAIL]` carries a specific fix, and the summary exits `1` if anything is blocking. Deliberately does **not** source `_common.sh`, which hard-exits on a missing config — diagnosing exactly that case is the command's first job.
- **`TROUBLESHOOTING.md`** — the longer-form reference behind the doctor: a symptom-to-fix table keyed off the structured exit-code contract, plus the failure modes that recur in unattended deployments (minimal cron/systemd `PATH`, `HOME` not set for skill discovery, `ProtectSystem=strict` sandboxing, skill-activation drift after editing `description`).
- **`SECURITY.md`** — private vulnerability reporting, this project's threat model (untrusted audited source and user arguments vs. trusted workspace state), deployment hardening summary, and a public numbered incident record whose first entry is the v1.1.1 path-traversal fix.
- Native `doctor` slash commands for Claude Code and Gemini CLI; `SKILL.md`'s universal fallback recognizes it (including natural-language forms like "why isn't the auditor working") on every other CLI, and now instructs the model to run the diagnostic before theorizing about causes.
- Eight doctor tests (healthy, missing-config, broken-config, fix-hint completeness, read-only guarantee). Suite is now 48 checks.

## [1.1.2] — cross-component consistency audit

A full step-by-step audit of every declared contract against its actual usage across the codebase, after several rounds of incremental additions. Five real inconsistencies found; all fixed.

### Fixed
- **`AUDIT_TARGET` never actually reached the model.** `SKILL.md` instructed it to read `config/auditor.conf`, but the runners `cd` into `$PROJECT` while the config lives under `$SKILL_DIR` — and for opencode (which only gets `SKILL.md` attached) the model never sees the skill directory at all. The single most important piece of per-deployment configuration was effectively unreachable. Now passed explicitly in an `AUDIT_CONTEXT` block (`PROJECT`, `AUDIT_TARGET`, `SKILL_DIR`) via a new shared `auditor_context_block()` in `scripts/lib/reliability.sh` — centralized rather than copy-pasted into five `build_message()` functions so it can't drift. `SKILL.md` updated to match.
- **`scripts/commands/reset.sh` silently missed two state files** added in v1.1.0 — `cumulative_cost_usd.txt` and `watchdog.log` — leaving stale spend totals and watchdog history behind after a "start fresh" reset. Both now archived and cleared with everything else.
- **CI shellcheck used a hardcoded file list** that was never updated when `scripts/watchdog.sh` was added, so it went unchecked. Now discovers scripts via `find`, which can't drift the same way.
- **`scripts/commands/status.sh` reported none of the v1.1.0 additions.** Now surfaces cumulative spend against budget, disk headroom against the minimum, and the watchdog's last check.
- **The watchdog's exit codes were undocumented**, and its `1` means something different from the dispatcher's `1`. Now documented as its own explicit contract in `references/workspace-and-execution.md`.

### Added
- Regression tests asserting `AUDIT_CONTEXT` and the prior-failure note actually reach the agent — the first was a silent failure precisely because nothing tested the message's contents.

## [1.1.1] — security patch: path traversal in labeled commands

Found during architecture research on comparable open-source projects — one of them (agentmemory) has a public, numbered security-advisory history, and incident #5 in that history is a path-traversal bug in an export feature via an unsanitized user-supplied argument. That prompted checking our own commands for the same bug class. They had it.

### Fixed
- **`scripts/commands/archive.sh` and `scripts/commands/backup-everything.sh`** both took an optional `LABEL` argument and used it, unsanitized, to build a filesystem path. Confirmed exploitable before this fix: `archive.sh "../../../../tmp/x"` wrote outside `work/archives/` entirely, landing at `$PROJECT/tmp/x`. Both now sanitize the label (`scripts/commands/_common.sh`'s new `sanitize_label()`) to alphanumeric/hyphen/underscore only before it touches a path. Normal usage (a plain label like `"before-refactor"`) is unaffected. Added a permanent regression test (`tests/run_tests.sh`) so this can't silently reappear.

No other command takes a user-supplied argument that reaches a filesystem path (`reset.sh` and `uninstall.sh` only accept fixed flags), so this was confirmed to be the only place with this bug class.

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
