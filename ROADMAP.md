# Roadmap

Current release: **v1.7.0** — see [`CHANGELOG.md`](CHANGELOG.md). The core contract (adapter hooks, exit codes, operational commands) is frozen as of `v1.0.0`; items below that would break it are major-version work.

## Status at a glance

Verified against the codebase as of v1.7.0, not from recollection:

| # | Item | Status |
|---|---|---|
| 1 | Adapter capability matrix (`adapters/capabilities.json`) | **Done** (v1.7.0) — behaviorally verified, not hand-maintained |
| 2 | Feature flags (`ENABLE_*`) | Not started |
| 3 | Finding schema normalization | Not started |
| 4 | State migration framework | **Partly resolved** — the first bump (3→4) landed additively in v1.1.0 and needed no migration script; still open for the first bump that requires an actual transformation |
| 5 | Core engine extraction (split `SKILL.md`) | Not started — and arguably not needed: `SKILL.md` is 133 lines and already delegates to `references/` |
| 6 | Domain-agnostic framework (`continuous-auditor-framework`) | **Deferred by explicit decision** — v2.0.0-scale identity change, parked intentionally |
| 7 | Event bus | Not started |
| 8 | Notification hooks (`hooks/*.sh`) | Not started — `alert()` in `scripts/lib/reliability.sh` is still a log-only stub |
| 9 | Test suite | **Done** (v1.0.0) — `tests/`, 40 checks, wired into CI |
| 10 | Task scheduler / parallel workers | Not started |
| 11 | `doctor` command + `TROUBLESHOOTING.md` | **Done** (v1.2.0) — `scripts/commands/doctor.sh`, 8 tests |
| 12 | `SECURITY.md` + incident log | **Done** (v1.2.0) — reporting policy, threat model, numbered incident record |
| 13 | Secret/credential redaction in findings evidence | **Done** (v1.4.0) — §12 rule + `secret_patterns.sh` scanner wired into doctor |
| 14 | Generalize disk preflight into a load gate | **Done** (v1.3.0) — load + memory gates as self-clearing deferrals (exit 14), disk stays a hard failure |
| 15 | Marketplace/plugin manifests | Not started |

Shipped since the roadmap was written, and *not* from this list — they came out of reviews and audits along the way: the scheduler-liveness watchdog, stale-session self-healing, cumulative cost ceiling, deterministic maintenance counters (all v1.1.0), the path-traversal security fix (v1.1.1), and the cross-component consistency audit (v1.1.2).

**All low-risk items are now shipped** — 11 and 12 (v1.2.0), 14 (v1.3.0), 13 (v1.4.0), 1 (v1.7.0), plus retention (v1.5.0) and observability (v1.6.0) found by architecture review rather than this list. Everything remaining is either larger design work (3, 6, 7, 10), genuinely optional (2, 15), or arguably unnecessary (5). The next meaningful step is a deliberate decision, not a backlog item: whether this stays an observation loop or becomes a closed one (see #6 and the README's stability section).

Detail on each item follows, roughly ordered by how independent each is from the others (earlier items don't require later ones):

## 1. Adapter capability matrix (`adapters/capabilities.json`) — DONE (v1.7.0)

A structured file describing what each CLI adapter actually supports (`supports_json_output`, `supports_session_resume`, `supports_native_slash_commands`, …), so the framework can make runtime decisions instead of every fact living only in prose inside `adapters/<cli>.md`. Low risk, genuinely useful, good first pick once `v1.0.0` has some real-world mileage on it.

## 2. Feature flags in `config/auditor.conf` — Not started

`ENABLE_METRICS`, `ENABLE_HEARTBEAT`, `ENABLE_RUNTIME_VERIFY`, `ENABLE_SELF_AUDIT`, and similar — lets a deployment turn off pieces it doesn't want rather than all-or-nothing. Needs care: every flag is a combinatorial testing burden, so this should land with test coverage for each on/off combination that matters, not just the flag itself.

## 3. Finding schema normalization — Not started

Structured `category` / `subcategory` / `severity` / `confidence` fields on every finding, instead of prose-embedded severity. Would improve `metrics.json` and any future reporting/dashboard work. Should be additive — don't break the existing findings-register format for a `v1.x` release; this is a `v2` schema-version bump territory per `references/workspace-and-execution.md`'s migration guidance.

## 4. State migration framework (`migrations/v1_to_v2.sh`, …) — Partly resolved

`schema_version` bumped for the first time in `v1.1.0` (3→4, adding the `maintenance` counter — see `CHANGELOG.md`), handled as a documented additive change per `references/workspace-and-execution.md`'s migration guidance rather than a formal migration script, since old fields weren't renamed or removed. The next time a bump requires an actual transformation (not just new fields — see item 3 as the likely trigger for that), formalize it as a versioned script instead of ad hoc instructions in `SKILL.md`.

## 5. Core engine extraction (split `SKILL.md` further) — Not started (and possibly unnecessary)

`SKILL.md` already delegates heavily to `references/` — mission, guardrails, and orchestration stay in `SKILL.md`, methodology/safeguards/workspace design are separate files. Whether it's worth splitting further (e.g. hiving off "resume logic" or "execution flow" into their own reference files) should be judged against real signal that the file is actually hard to work with, not against a fixed target size — see `references/audit-methodology.md`'s own principle of letting real complexity decide, applied here to the skill's own structure.

## 6. Domain-agnostic framework (supersedes the earlier "plugin system" framing) — Deferred by explicit decision

`continuous-code-auditor` → `continuous-auditor-framework`, with code auditing as one pluggable methodology alongside security, documentation, infrastructure, configuration, and compliance auditing. Checked this against the actual code rather than assessing it in the abstract, since "how coupled is X to Y" is exactly the kind of claim that deserves evidence: `scripts/lib/reliability.sh` (locking, circuit breaker, exit codes, pause/resume, cost tracking, disk checks) has essentially zero code-specific coupling — two hits, both just the name of the `EXIT_COMPILE_FAILED` constant. `scripts/commands/*.sh` is the same story. The domain-specific language — "code," "compile," file-and-line evidence, the finding/report filenames — is concentrated almost entirely in `SKILL.md` and the three `references/` files. That's the good news: the engine and the methodology were already separated by the existing layering (`scripts/` vs `references/`), as a side effect of clean design rather than deliberate planning for this. The pivot is "extract and parameterize the methodology layer," not "rewrite the reliability engine."

Concretely, this would mean a `methodologies/<domain>/` directory (mirroring `adapters/<cli>/`'s existing pattern) — `methodologies/code/` holding what's currently baked into `SKILL.md` and `references/`, with a `DOMAIN` selector in `config/auditor.conf` alongside `AGENT_CLI` and `AUDIT_TARGET` — each domain module supplying its own evidence rubric (file-and-line citation makes sense for code; a documentation audit's evidence looks different; a compliance audit's looks different again), its own risk-tiering, and its own finding-register naming, while every adapter, every operational command, and the entire reliability engine stay exactly as they are.

This is genuinely the single biggest architectural step on this whole list, bigger in scope than the narrower "language plugins" idea it replaces here — it touches the project's name, `SKILL.md`'s mission and capability boundary, the finding-register filenames, and the frontmatter description, none of which are covered by the "frozen v1.0.0 contract" (see `CHANGELOG.md`) but all of which are exactly what makes this project recognizable as itself. That's the actual reason to defer it rather than start immediately: not effort, but that it's a v2.0.0-scale identity decision that deserves a deliberate yes, not a reflexive one the day after committing to stabilize.

## 7. Event bus (Audit → Events → Reporter/Metrics/Notifications) — Not started

Decouples "an interesting thing happened" from "what to do about it," which is what makes item 8 (notification hooks) composable instead of another special case bolted onto the reliability engine. Worth doing together with item 8, not before it.

## 8. Notification hooks (`hooks/slack.sh`, `hooks/discord.sh`, `hooks/webhook.sh`, …) — Not started

Right now, `alert()` in `scripts/lib/reliability.sh` is a single stub that just logs — see its comment. Real hook scripts (fired on circuit-breaker trips, and optionally on high-severity findings once item 3 exists) are a natural extension of that same function, not a new subsystem — implement this before item 7 if notifications alone are the actual goal; implement it after item 7 if the broader event model is the actual goal.

## 9. Test suite — DONE (v1.0.0)

**Done as of `v1.0.0`** — see `tests/`. Listed here because it was on the original list and it's worth noting explicitly that it's no longer deferred.

## 10. Task scheduler / execution queue / parallel workers — Not started

Splitting finding-discovery, verification, runtime-validation, report-generation, and governance-update into independently schedulable queue items instead of one sequential pass. This is the largest architectural change on this list — it would touch the task queue model in `references/workspace-and-execution.md`, the priority order in `SKILL.md`, and every adapter's timeout assumptions. Not worth attempting until the sequential model has demonstrably become the actual bottleneck in a real deployment; premature parallelism here risks reintroducing exactly the consistency problems (contradiction detection, duplicate findings) `references/consistency-and-safeguards.md` exists to prevent.

## 11. `doctor`/diagnose command + `TROUBLESHOOTING.md` — DONE (v1.2.0)

Raised after studying claude-mem and agentmemory; now the single most evidence-backed item on this list. Five independent confirmations of the same pattern: claude-mem ships a dedicated `troubleshoot` skill; agentmemory has `agentmemory doctor`, a `memory_diagnose`/`memory_heal` tool pair, an entire `src/cli/doctor-diagnostics.ts` module with its own test suite (`test/cli-doctor-fixes.test.ts`, `test/diagnostic-followup-rate.test.ts`), *and* a literal `plugin/skills/_shared/TROUBLESHOOTING.md`. This should probably be the next thing built, not just documented — a mapping from our own exit codes / log patterns (`references/workspace-and-execution.md`'s exit-code contract) to fixes, plus an eighth operational command (`/continuous-code-auditor-doctor`) that runs the checks and reports which one is actually broken, the same deterministic-script philosophy as the existing seven commands.

## 12. `SECURITY.md` + a transparent incident log — DONE (v1.2.0)

Letta ships `SECURITY.md`/`PRIVACY.md`/`AI_POLICY.md`; agentmemory keeps a numbered, public `.github/security-advisories/NN-description.md` history (six entries, including — found and fixed here — the same path-traversal bug class we just patched in `CHANGELOG.md` 1.1.1). We don't have a vulnerability-reporting policy or any equivalent history. Given this project executes shell commands and reads/writes files autonomously, a `SECURITY.md` (how to report) is a real gap, not a nice-to-have; a running incident log is a smaller, optional addition on top of that.

## 13. Secret/credential redaction in findings evidence — DONE (v1.4.0)

Reinforces the item raised in the claude-mem/agentmemory/ponytail research round: agentmemory's own security-advisory #6 is literally "privacy redaction incomplete," and Letta has a dedicated `letta/schemas/secret.py` type specifically so secret values are never naively serialized or logged. Our evidence-citation discipline (`references/consistency-and-safeguards.md`) has no equivalent rule yet — a finding citing `API_KEY = "sk-..."` as evidence could write the literal secret into a long-lived, possibly-shared findings register. Two independent real projects have hit this specific failure mode; worth fixing before we hit it too.

## 14. Generalize the disk-space preflight into a load gate — DONE (v1.3.0)

Letta's `letta/monitoring/load_gate.py` (alongside `event_loop_watchdog.py` and `readiness_state.py`) refuses new work under system load, not just low disk. Our `MIN_FREE_DISK_MB` check in `scripts/lib/reliability.sh` is the same idea applied to one resource; extending it to check load average / available memory before starting a run is a natural, small generalization once there's a concrete reason to (a real deployment actually contending for CPU/memory, not a speculative one).

## 15. Marketplace/plugin manifests for proper discovery — Not started

mem0 ships `.claude-plugin/marketplace.json`, `.codex-plugin/marketplace.json`, `.cursor-plugin/marketplace.json`, and `.agents/plugins/marketplace.json` — real per-CLI manifests that let their skill be installed through each CLI's own marketplace/plugin command, not just symlinked by a custom installer the way ours is. Worth investigating once we're ready to prioritize discoverability over `installer/install.sh`'s current manual-but-portable approach — this is real research work per marketplace format, not a quick add.

---

None of the above should be started by rewriting the frozen `v1.0.0` contract out from under existing deployments. If an item requires a breaking change to the adapter hook signatures, the exit-code table, or the operational-command scripts' CLI surface, it's a major version bump, documented in `CHANGELOG.md` like any other breaking change.
