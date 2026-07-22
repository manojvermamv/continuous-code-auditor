# Consistency, self-correction, and drift safeguards

Read this before filing, verifying, or closing anything. Everything here exists to make sure quality holds steady — or improves — across hundreds or thousands of unattended executions, not just within one run.

## 1. Evidence strength rubric — gate before you file

Every piece of evidence is one of:

- **Strong** — exact lines you can cite, in the current active source, that directly show the behavior (not a related-but-different code path).
- **Moderate** — a clear, correctly-cited line, but the link to the claimed impact requires one reasonable inferential step (e.g. tracing one level into a caller).
- **Weak** — anything requiring more than one inferential step, evidence from comments/docstrings/naming rather than actual logic, or a claim about external (broker/exchange) behavior with no corroborating code path.

**Gate:** Weak evidence never produces a filed finding. Record it internally instead (see §7, `Unresolved-Insufficient-Evidence`) and either strengthen it on a later pass or drop it — don't file it "to be safe."

## 2. Confidence tag on every finding

Tag each finding `Low` / `Medium` / `High`, derived from the rubric above (Weak → Low, Moderate → Medium, Strong → High). A finding can only advance past `Investigating` at Medium or higher. A `Low`-confidence item stays an internal candidate, not a register entry, until new evidence raises it.

## 3. Speculation trip-wire

If your own reasoning — while investigating or drafting a finding — reaches for words like *likely, probably, should, presumably, I'd expect, seems to* about actual runtime or broker behavior the source doesn't show directly: **stop.** That phrasing is the signal, not a stylistic detail to clean up afterward. Treat it exactly like hitting a weak-evidence gate:

- Don't rewrite the sentence to sound more certain and proceed anyway.
- Don't file the finding "provisionally."
- Either go get the evidence that removes the hedge, or park it per §7 and move on.

## 4. Reasoning fingerprint & cross-run contradiction detection

For every finding, store a short fingerprint alongside its status in `audit_state.json`: 2–4 lines paraphrasing *why* this status was assigned, plus the exact evidence lines cited. This is what lets a later, contextless execution check itself against the past instead of only against the source.

On any run that revisits a finding (verification pass, spot-check, or an unrelated diff that happens to touch it):

1. Re-derive your conclusion from the current active source.
2. Compare it to the stored fingerprint.
3. If they agree (or the difference is fully explained by an intervening source change you can point to), proceed normally and refresh the fingerprint.
4. If they disagree **and nothing in the diff explains why** — do not silently overwrite. Mark the finding `Contradiction-Flagged`, keep both the old and new reasoning side by side in the register, and surface it prominently in the closure report as needing human review. Resolving a contradiction by picking whichever conclusion you currently find more convincing, without new evidence, is itself a speculation-trip-wire violation.

## 5. Mistake ledger (`work/mistake_ledger.json`)

`auditor_governance.md` stays as your narrative record of *why* — keep writing to it exactly as before. Alongside it, maintain a structured, machine-checkable ledger so lessons are actually consulted, not just archived prose:

```json
{
  "mistakes": [
    {
      "id": "M-0007",
      "pattern_type": "duplicate_finding",
      "description": "Filed a new finding for the same partial-fill race already open as F-0012.",
      "first_observed": "2026-06-02T04:05:00Z",
      "occurrences": 3,
      "mitigation_rule": "Before filing, grep the register for the affected function name, not just the finding title.",
      "last_triggered": "2026-07-10T04:05:00Z"
    }
  ]
}
```

`pattern_type` is one of: `duplicate_finding`, `false_positive`, `unnecessary_reaudit`, `contradiction`, `evidence_gap`, `other`.

**Before** any of: filing a new finding, marking something verified, or re-auditing an already-closed/verified item — check this ledger for a matching `mitigation_rule` and apply it. If you catch yourself about to repeat a logged mistake, that's `occurrences += 1` and a timestamp update — log the near-repeat even though you caught it, since the pattern recurring is itself useful signal.

## 6. Governance consolidation cadence

Every N executions (default: every 50 runs, or once every 24 hours of wall-clock time, whichever comes first — track the counter in `audit_state.json`):

- Review `auditor_governance.md` and `mistake_ledger.json` together.
- Merge duplicate or overlapping rules into one clearer rule.
- Fold superseded rules into the broader rule that now covers them — **never delete the substance**, note the fold (e.g. "M-0003 and M-0009 merged into M-0009 on 2026-07-15: both were instances of the same root cause").
- This is what keeps a 24×7 deployment's self-knowledge from becoming unreadable noise after months of runs — the goal is a ledger that stays *usable*, not just large.

## 7. Parking uncertain work: `Unresolved-Insufficient-Evidence`

This is not a finding status — it's an internal note (kept in `audit_state.json`, not the register) for anything the trip-wire or the weak-evidence gate stopped you from filing. Record: what you were investigating, what evidence exists so far, and specifically what additional evidence would resolve it. Future runs can pick this up and either close it out with real evidence or continue leaving it parked — but it never silently becomes a filed finding just because it's been sitting there a while.

**Escalation if it stays parked too long:** track how many executions a given parked item has survived. If it passes N consecutive executions (default 10) still unresolved, stop re-investigating it every run — re-derive the same "insufficient evidence" conclusion from the same unchanged source repeatedly and you're just spending cycles to learn nothing new. Instead, mark it `Deferred-Human-Review` (still internal, not a register finding) and only revisit it when the diff shows the relevant code actually changed, or when the user explicitly asks you to look again. This is different from giving up on it — it's refusing to burn every execution re-confirming the same open question.

## 8. Periodic spot re-verification

Independent of the diff-triggered verification in the main flow: every N executions (default 50), re-check a small sample (e.g. 3–5, oldest-verified-first) of already-`Verified-in-code`/`Verified-runtime` findings against the current source, even though nothing specifically prompted it. This catches silent drift — an unrelated later change that quietly invalidates a previously-correct fix. Keep the sample small enough that this never displaces the primary priority order in `SKILL.md`.

## 9. Circuit breaker for operational failure

Track consecutive failed executions (crash, timeout, or a failed self-consistency check with no clean resolution) in `audit_state.json`. If that count reaches a threshold (default 3):

- Stop attempting new audit work.
- Do not write further changes to the findings register or closure report.
- Record a clear `held` state with the reason and failure count.
- Wait for either the underlying cause to clear (e.g. the source starts compiling again) or explicit operator/user intervention.

Never keep compounding new work on top of an unresolved failure streak — that's how a small operational problem turns into a large accuracy problem.

## 10. Negative knowledge registry (`work/negative_knowledge.json`)

The mistake ledger (§5) tracks lessons about *your own process* (you duplicated a finding, you filed a false positive). This registry is different: it tracks specific *code-level conclusions* that were investigated and definitively rejected, so a later execution — with no memory of the earlier one — doesn't re-open the same question from scratch.

```json
{
  "rejected": [
    {
      "id": "N-0004",
      "subject": "OrderManager._retry_partial_fill",
      "claim": "possible race condition on partial-fill retry counter",
      "verdict": "not a race condition — retry counter is only touched inside the single-threaded event loop callback",
      "evidence": "OrderManager.py:212-238",
      "resolved_on": "2026-07-02T10:00:00Z"
    }
  ]
}
```

Before investigating any candidate issue, check this registry for a matching `subject`/`claim`. If found, and the diff since `resolved_on` doesn't touch the cited evidence lines, don't re-derive the conclusion from scratch — cite the existing entry and move on. If the diff *does* touch those lines, re-investigate properly; a source change can invalidate a prior "not an issue" verdict just as easily as it can invalidate an open finding.

This is also where `Closed-as-intentional` findings and confirmed false positives ultimately land once they leave the active register — the live register stays focused on what's actually open or being tracked, while this registry is the durable answer to "haven't we already looked at this?"

## 11. Periodic full state-integrity reconciliation

The self-consistency check in `references/audit-methodology.md` runs on **every** execution and is intentionally cheap: it checks that the two reports agree, statuses are internally consistent, and evidence points at the active source. This section is different — a deeper, cross-file reconciliation that only needs to run periodically (same cadence as §6 and §8: every 50 executions or every 24 hours, whichever comes first), because it's more expensive and because drift at this level accumulates slowly, not per-run.

On the executions where it's due, reconcile rather than trust:

- **Recompute `metrics.json` from the register**, don't just trust its running counters. Tally `findings_open`, `findings_verified`, etc. fresh from `continuous_code_audit_findings.md` and compare to what's stored — an incremental update missed somewhere along the way will drift silently otherwise. Overwrite with the recomputed values (atomically, per the write requirement above) and note any discrepancy found in the execution log.
- **Verify every finding ID referenced anywhere in `audit_state.json`'s queues** (`active_task`, `pending_tasks`, `verification_queue`, `deferred_queue`) actually exists in the register. An ID left over from an interrupted operation that no longer corresponds to a real finding is an orphaned reference — drop it from the queue and record why.
- **Verify `heartbeat.json` matches the tail of `execution_log.md`** — same timestamp, same outcome. A mismatch usually means a write didn't land where you'd expect; treat it like any other state inconsistency — fix it, and record the fix.
- **Scan `negative_knowledge.json` and `mistake_ledger.json` for contradictions** — e.g. the same subject marked both a rejected non-issue and, elsewhere, still open as a live finding, with no note explaining the change. Flag exactly like a cross-run contradiction (§4) rather than silently picking one.

Record what this pass checked, what it found, and what it corrected in the execution log — this is itself the kind of thing that should be auditable, not a silent background chore. If a reconciliation pass finds nothing to fix, that's worth one line in the log too ("reconciliation pass: no drift found"), not silence — silence and "checked, clean" should be distinguishable from the log alone.

