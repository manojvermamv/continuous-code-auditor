# Roadmap

`v1.0.0` is a stabilization release, not a feature release — see [`CHANGELOG.md`](CHANGELOG.md). The items below are real ideas worth pursuing, deliberately **not** implemented yet, so the core contract (adapter hooks, exit codes, operational commands) stays frozen long enough to actually prove itself before it grows further. Each one is deferred on purpose, not forgotten.

Roughly ordered by how independent each is from the others (earlier items don't require later ones):

## 1. Adapter capability matrix (`adapters/capabilities.json`)

A structured file describing what each CLI adapter actually supports (`supports_json_output`, `supports_session_resume`, `supports_native_slash_commands`, …), so the framework can make runtime decisions instead of every fact living only in prose inside `adapters/<cli>.md`. Low risk, genuinely useful, good first pick once `v1.0.0` has some real-world mileage on it.

## 2. Feature flags in `config/auditor.conf`

`ENABLE_METRICS`, `ENABLE_HEARTBEAT`, `ENABLE_RUNTIME_VERIFY`, `ENABLE_SELF_AUDIT`, and similar — lets a deployment turn off pieces it doesn't want rather than all-or-nothing. Needs care: every flag is a combinatorial testing burden, so this should land with test coverage for each on/off combination that matters, not just the flag itself.

## 3. Finding schema normalization

Structured `category` / `subcategory` / `severity` / `confidence` fields on every finding, instead of prose-embedded severity. Would improve `metrics.json` and any future reporting/dashboard work. Should be additive — don't break the existing findings-register format for a `v1.x` release; this is a `v2` schema-version bump territory per `references/workspace-and-execution.md`'s migration guidance.

## 4. State migration framework (`migrations/v1_to_v2.sh`, …)

Once `schema_version` actually needs to bump for the first time (see item 3 as the likely trigger), formalize the migration as a versioned script rather than ad hoc instructions in `SKILL.md`.

## 5. Core engine extraction (split `SKILL.md` further)

`SKILL.md` already delegates heavily to `references/` — mission, guardrails, and orchestration stay in `SKILL.md`, methodology/safeguards/workspace design are separate files. Whether it's worth splitting further (e.g. hiving off "resume logic" or "execution flow" into their own reference files) should be judged against real signal that the file is actually hard to work with, not against a fixed target size — see `references/audit-methodology.md`'s own principle of letting real complexity decide, applied here to the skill's own structure.

## 6. Plugin system (`plugins/python/`, `plugins/rust/`, `plugins/docker/`, …)

Language- or domain-specific audit modules beyond the generic risk categories in `references/audit-methodology.md` and the optional `references/domain-focus.md`. This is the biggest item on this list — real design work, not a quick add — and should wait until there's a second or third concrete domain-focus file in real use to generalize from, rather than being designed speculatively.

## 7. Event bus (Audit → Events → Reporter/Metrics/Notifications)

Decouples "an interesting thing happened" from "what to do about it," which is what makes item 8 (notification hooks) composable instead of another special case bolted onto the reliability engine. Worth doing together with item 8, not before it.

## 8. Notification hooks (`hooks/slack.sh`, `hooks/discord.sh`, `hooks/webhook.sh`, …)

Right now, `alert()` in `scripts/lib/reliability.sh` is a single stub that just logs — see its comment. Real hook scripts (fired on circuit-breaker trips, and optionally on high-severity findings once item 3 exists) are a natural extension of that same function, not a new subsystem — implement this before item 7 if notifications alone are the actual goal; implement it after item 7 if the broader event model is the actual goal.

## 9. Test suite

**Done as of `v1.0.0`** — see `tests/`. Listed here because it was on the original list and it's worth noting explicitly that it's no longer deferred.

## 10. Task scheduler / execution queue / parallel workers

Splitting finding-discovery, verification, runtime-validation, report-generation, and governance-update into independently schedulable queue items instead of one sequential pass. This is the largest architectural change on this list — it would touch the task queue model in `references/workspace-and-execution.md`, the priority order in `SKILL.md`, and every adapter's timeout assumptions. Not worth attempting until the sequential model has demonstrably become the actual bottleneck in a real deployment; premature parallelism here risks reintroducing exactly the consistency problems (contradiction detection, duplicate findings) `references/consistency-and-safeguards.md` exists to prevent.

---

None of the above should be started by rewriting the frozen `v1.0.0` contract out from under existing deployments. If an item requires a breaking change to the adapter hook signatures, the exit-code table, or the operational-command scripts' CLI surface, it's a major version bump, documented in `CHANGELOG.md` like any other breaking change.
