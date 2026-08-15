# Troubleshooting

**Start here:** run the doctor. It checks everything below automatically and tells you which specific thing is broken:

```bash
scripts/commands/doctor.sh
# or, in Claude Code / Gemini CLI:  /continuous-code-auditor-doctor
```

It's read-only — safe to run any time, including mid-audit. Exit `0` means no blocking problems; exit `1` means at least one `[FAIL]` that must be fixed before the auditor will work.

This document is the longer-form reference behind those checks.

---

## By exit code

Every scheduled run returns a structured exit code (full table in [`references/workspace-and-execution.md`](references/workspace-and-execution.md)). If you know the code, start here:

| Code | Meaning | Most likely cause | Fix |
|---|---|---|---|
| `0` | Success | — | — |
| `10` | Skipped, lock held | A previous run is still going, or one died without releasing | Normal if a run is in progress. Check `cat /tmp/continuous_code_auditor.lock.meta` for PID/host/start time. `flock` releases automatically when the process dies, so a genuinely stale lock is rare — a held lock usually means a real hung run; see `TIMEOUT_SECONDS` |
| `12` | Skipped, circuit breaker held | 3+ consecutive failures | Fix the underlying failure (see `logs/last_failure.txt`), then `rm $LOG_DIR/held.flag` |
| `13` | Skipped, paused | Someone ran `stop.sh`, **or** the cumulative cost budget was reached | `cat $LOG_DIR/paused.flag` tells you which. Resume with `scripts/commands/start.sh` |
| `14` | Deferred, host under resource pressure | Load average or available memory crossed the configured gate | **Self-clearing — no action needed.** Retried next tick, and never counts toward the circuit breaker. Frequent `14`s mean the host is genuinely contended: either the schedule is too aggressive for the box, or something else on it is. Tune `MAX_LOAD_PER_CPU` / `MIN_FREE_MEM_MB`, or set `MAX_LOAD_PER_CPU=""` to disable |
| `15` | Preflight/config failure | Unconfigured `MODEL_NAME`, CLI binary not on `PATH`, skill not installed, bad paths, or low disk | Run the doctor — this is exactly what it diagnoses. **The most common cause in production is `PATH`**: cron and systemd run with a minimal environment, so a CLI that works in your shell may not be found by the scheduler |
| `20` | Source failed to compile | The audited code doesn't compile | Not an auditor bug — the audit continues and records the failure |
| `30` | Source fetch failed | A configured remote source was unreachable | Check network/credentials for that source |
| `40` | Prompt/model-side failure | Model error, timeout, token limit, or an adapter-specific failure signal | See `logs/auditor.log` and the model's own output |
| `50` | State recovery invoked | `audit_state.json` was unreadable and had to be rebuilt | Informational, but worth investigating — usually means a previous run was killed mid-write |
| `1` | Unrecognized failure | A shell-level error in the wrapper itself | Check `logs/auditor.log` |

The watchdog (`scripts/watchdog.sh`) has its **own** two-code contract — `0` healthy or intentionally-not-checking, `1` stale. Its `1` means something different from the dispatcher's `1`; don't conflate them.

---

## By symptom

### "Nothing is happening at all — no logs, no runs"

Most likely the scheduler was never installed, or died. This is precisely the failure the circuit breaker **cannot** see: it only reacts to runs that actually happen, and here nothing runs at all.

1. `scripts/commands/status.sh` — does it show a recent execution?
2. `systemctl status continuous-code-auditor.timer` or `crontab -l`
3. If neither exists, run `installer/install.sh` and pick a scheduler.
4. Install the watchdog too (`continuous-code-auditor-watchdog.timer`) so this specific failure alerts next time instead of going unnoticed.

### "Runs keep getting skipped with exit 14"

That's the load gate deferring, not failing — the host was over the configured load or memory threshold when the tick fired. It's self-clearing by design and never trips the circuit breaker. Check `scripts/commands/status.sh` for the current load against the limit. If it happens constantly, the box is over-subscribed relative to the audit schedule; lengthen the schedule interval, raise `MAX_LOAD_PER_CPU`, or disable the gate with `MAX_LOAD_PER_CPU=""`.

### "It ran once and now never again"

Check, in this order:
1. `cat $LOG_DIR/held.flag` — circuit breaker tripped (3+ consecutive failures)
2. `cat $LOG_DIR/paused.flag` — paused manually, or auto-paused by the cost budget
3. `cat $LOG_DIR/last_failure.txt` — what actually failed

The breaker and the pause are both deliberate stops. Neither clears itself; that's by design, so a failing deployment doesn't keep burning budget unattended.

### "Works when I run it by hand, fails under cron/systemd"

Almost always environment, not logic. In order of likelihood:
- **`PATH`** — cron's `PATH` is minimal. Use an absolute path to the CLI binary, or set `PATH` at the top of your crontab.
- **`HOME`** — adapters that use native skill discovery look in `~/.claude/skills/` etc. If `HOME` isn't set as expected for the scheduler's user, the skill won't be found.
- **User** — the systemd unit runs as `User=auditor` by default. That account needs read access to the skill directory and write access to `PROJECT` and `LOG_DIR`.
- **systemd sandboxing** — under `ProtectSystem=strict`, anything not in `ReadWritePaths=` is read-only. `PROJECT` itself must be listed, not just `work/` — the auditor writes the refreshed source back into the project root.

### "The model doesn't seem to know what to audit"

Each run is passed an `AUDIT_CONTEXT` block containing `PROJECT`, `AUDIT_TARGET`, and `SKILL_DIR`. If the model is auditing the wrong thing:
- Check `AUDIT_TARGET` in `config/auditor.conf` — it's relative to `PROJECT` unless absolute, and may be one file, several space-separated files, or `.` for the whole tree.
- The doctor verifies every path in `AUDIT_TARGET` actually exists.

### "The skill isn't activating"

For adapters using native skill discovery (Claude Code, Gemini CLI, Codex CLI, Hermes), the model matches the request against the skill's `description` in `SKILL.md`. If you've edited that description, activation may have broken. Verify once interactively before trusting the unattended loop. Gemini CLI additionally requires a **trusted workspace** for project-scoped skills — run `/trust` once in that directory.

opencode doesn't use skill discovery at all; it attaches `SKILL.md` directly on every invocation, so this class of problem doesn't apply there.

### "doctor reports credential-shaped strings in work/"

A secret from the audited source has been copied into the findings register or another `work/` file. Treat it as a real incident, not a false positive:

1. Open the reported locations (doctor prints file and line, never the value itself).
2. Replace the literal value with a redacted citation — location plus a description of what it is.
3. **Rotate the credential.** It reached a durable, likely-shared artifact; assume it's compromised.
4. Note the redaction in `work/execution_log.md` — silently deleting it hides the fact that rotation is needed.

If the workspace is under version control, the value is in the history too, and removing it from the working copy is not enough.

### "Findings/reports look wrong or contradictory"

This is audit-quality, not an operational failure. See [`references/consistency-and-safeguards.md`](references/consistency-and-safeguards.md) — particularly `Contradiction-Flagged` findings (a later run disagreeing with an earlier one on unchanged code, which is surfaced for human review rather than silently overwritten) and the mistake ledger.

### "Disk is filling up"

`archives/` (one snapshot per source refresh) and `backups/` grow without bound unless you enforce retention. See the retention section in [`references/workspace-and-execution.md`](references/workspace-and-execution.md). Never delete an archive still cited as evidence by an unresolved or `Contradiction-Flagged` finding.

### "I want to start over"

- `scripts/commands/archive.sh` — non-destructive checkpoint, nothing is cleared
- `scripts/commands/reset.sh --confirm` — archives everything into `work/archives/<timestamp>/`, then reinitializes. `work/archives/` itself is never deleted.
- `scripts/commands/backup-everything.sh` — full disaster-recovery tarball before doing anything risky

---

## Getting more detail

- `logs/auditor.log` — every run's outcome, one line each
- `logs/watchdog.log` — scheduler-liveness checks
- `work/execution_log.md` — the model's own append-only run history
- `work/heartbeat.json` — last execution's status snapshot
- `journalctl -u continuous-code-auditor.service` — if running under systemd

If you believe you've found a security issue rather than a configuration problem, see [`SECURITY.md`](SECURITY.md).
