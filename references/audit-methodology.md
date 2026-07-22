# Audit methodology: findings, verification, and self-checks

## What to look at

Don't work from a fixed checklist. Read the code, understand its architecture, execution flow, state transitions, and let genuine complexity and risk decide where you spend effort:

concurrency and shared state · security and trust boundaries (auth, input validation, injection surfaces) · data integrity (persistence, transactions, idempotency) · configuration and validation · error handling and resource cleanup · reliability of external I/O (timeouts, retries, partial failures).

If `references/domain-focus.md` exists, add its categories to this list with equal weight — that's where deployment-specific risk areas live (a trading system's order lifecycle and position accounting, a web app's session handling, a data pipeline's exactly-once guarantees), rather than baked into this generic file.

Skip categories that plainly don't apply. Go deeper only where the code creates material risk.

## Risk-tiered depth of review

Not every path deserves the same depth of scrutiny — this is about *how hard* to look, not *whether* to look, and it doesn't relax the evidence rules above:

- **High-risk paths** (anything touching money, security boundaries, or shared mutable state under concurrency, plus whatever `references/domain-focus.md` calls out as high-risk for this deployment): exhaustive review. Trace the full path, all callers, and the edge cases.
- **Medium-risk paths** (configuration handling, integration plumbing that isn't itself on a high-risk path, persistence/recovery logic): caller tracing — follow it one or two levels in each direction, enough to be confident, without exhaustively enumerating every edge case.
- **Low-risk paths** (logging, formatting, CLI/reporting glue, anything with no path to money, security, or shared state): sampled verification — spot-check rather than exhaustively trace.

This keeps effort proportional on a large codebase instead of spending the same exhaustive pass on a log formatter as on the highest-risk logic in the system. If you're not sure which tier a piece of code falls in, treat it as the higher tier until you know enough to downgrade it — never the reverse.

## Finding rules

Every finding needs: evidence, the exact file, the exact lines, an explanation, and the impact. No evidence, no finding — never speculate or invent behavior the source doesn't support.

**Statuses, in order — never skip a transition:**
`Open` → `Investigating` → `Candidate Fix Prepared` → `Fixed-but-unverified` → `Verified-in-code` → `Verified-runtime`, with `Closed-as-intentional` available once the user confirms a behavior is deliberate.

- Compilation and static review can only ever produce `Verified-in-code` — neither one proves runtime/broker behavior.
- Never mark a fix correct because it was *described*; re-check it in the current source.
- Once the user closes an item as intentional, don't re-raise it — unless a later diff touches the behavior it was closed against, in which case flag that the underlying code changed and ask whether the closure still holds, rather than silently reopening or silently leaving it closed.
- Don't re-audit anything already verified unless asked to recheck, or unless a refreshed diff affects its relevant behavior.

## Candidate fix generation

For every `Open` finding, produce the safest reasonable candidate fix — the goal is to solve the issue, not just describe it. Store the candidate in the workspace (e.g. `candidate_fixes.md`) rather than touching the source: **never modify the audit target itself unless the user explicitly asks for an implementation or patch.** Auditing, compiling, fetching, archiving, diffing, and maintaining the workspace records are all authorized on their own; changing the audited source is not.

When a future execution revisits an `Open` finding, improve the stored candidate fix rather than discarding prior reasoning.

## Continuous discovery

Once resumed work, verification, and regression checks are done, keep looking rather than assuming the audit is finished: new bugs, edge cases, logic errors, race conditions, incorrect assumptions, missing validation, dead code, unreachable paths, state corruption, resource leaks, duplicate logic, risk violations. Stop only when execution time/budget ends.

## Anti-speculation rules

Evidence overrides intuition, always:

- Never infer behavior the active source doesn't support, and never invent an execution path or broker outcome.
- Never infer user intent as a substitute for evidence.
- If evidence is insufficient: note the uncertainty internally, gather more evidence, and hold off on filing a finding until it's sufficient — don't file on a hunch and plan to firm it up later.

## Confidence check (run before finalizing any finding)

- Is this backed by the active source, with exact lines I can point to?
- Could this be a false positive?
- Have I already reported this, or already verified it?
- Am I assuming anything I haven't actually confirmed?

Any "yes" to uncertainty (or "no" to being able to cite lines) means: keep investigating instead of filing.

## Duplicate prevention

Before creating any new finding, search the register for an equivalent one. If it exists, update that finding instead of creating a duplicate.

## Auditor governance

Maintain `auditor_governance.md` as a log of lessons about your *own* process — not a findings register. Whenever you notice your own prior reasoning was incomplete, incorrect, duplicated, speculative, inconsistent, or needlessly repeated: record what happened, why, the rule that prevents a repeat, and apply that rule going forward. Never delete a governance rule — only supersede it with a better one, keeping the history.

## Self-consistency check (run before every exit)

- Findings register and closure report agree.
- Finding statuses are internally consistent.
- Every finding's evidence matches the *active* source (not an archive).
- No contradictory conclusions and no duplicate findings.
- No finding relies on archived-source evidence.
- Governance rules have been followed.

Fix anything that fails this check before exiting — don't carry an inconsistency into the next execution.
