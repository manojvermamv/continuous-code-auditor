# Workspace layout, state machine, and scheduling architecture

This file covers everything needed to understand *where things live* and *how one execution flows from start to exit* — plus how to wire this skill into a scheduler so it runs continuously without conversational memory.

## Directory layout

```
<project-root>/
    <AUDIT_TARGET>                                           (one file, several files, or this whole tree —
                                                                see config/auditor.conf's AUDIT_TARGET)

    work/
        audit_state.json                                        (authoritative)
        continuous_code_audit_findings.md
        continuous_code_audit_closure_report.md
        execution_log.md                                        (append-only)
        auditor_governance.md
        mistake_ledger.json
        negative_knowledge.json
        metrics.json
        heartbeat.json
        candidate_fixes.md
        archives/                                               (reset-time snapshots only — see
                                                                    "The /reset command" below. Never the
                                                                    same thing as the source archives/ below.
                                                                    This directory is itself never reset.)

    archives/
        source_<timestamp>.py                                   (single-file target: one file per refresh)
        source_<timestamp>.tar.gz                               (multi-file or directory target: one tarball
                                                                    per refresh instead)

    logs/
        cron.log
        auditor.log
        watchdog.log                                            (scheduler-liveness checks — separate from auditor.log)
        last_failure.txt                                        (wrapper-internal, feeds SKILL.md's step-5 prep)
        consecutive_failures.txt                                (wrapper-internal, circuit breaker counter)
        cumulative_cost_usd.txt                                 (wrapper-internal, running total vs CUMULATIVE_BUDGET_USD)
        held.flag                                               (present only while the circuit breaker is tripped)
        paused.flag                                             (present only after /continuous-code-auditor-stop, or on budget exhaustion)
        <agent>_session_id.txt                                  (wrapper-internal, for session continuity — optional, per-adapter, see adapters/<cli>.md)
        execution_log_archive/                                  (rotated-out execution_log.md entries)

    backups/
        continuous-code-auditor-backup-<timestamp>.tar.gz        (full disaster-recovery snapshots — see
                                                                    "The /backup-everything command" below)
```

`work/` is the model's own authoritative record — everything in it is something the model itself reasons from and writes, per the atomic-write requirement below, **except `work/archives/`**, which is written only by the `/continuous-code-auditor-reset` command (a deterministic script, not the model) and must never be touched by the model's own audit reasoning. `logs/` (besides the plain text logs) holds the *wrapper's* own operational bookkeeping — lock state, failure counters, pause/hold flags, session id — which the shell scripts read and write directly and the model never needs to touch. `backups/` holds complete disaster-recovery snapshots (skill package + workspace + logs together) made on request — see the operational commands section below.

Three genuinely different "archive" concepts live in this layout, and it matters that you don't conflate them: `archives/` (project root) holds source-code version history; `work/archives/` holds snapshots of the *audit's own findings and state* made at reset time; `backups/` holds full disaster-recovery bundles of everything at once. Each has a different owner, a different trigger, and a different retention story — see their respective sections below.

## Atomic state writes

This applies to every file you write in `work/` — `audit_state.json`, `mistake_ledger.json`, `negative_knowledge.json`, `metrics.json`, `heartbeat.json`, and the two reports — not just the ones called out by name below.

**Never write a new version of a state file directly onto its final path.** Write the complete new content to a temp file in the same directory (e.g. `audit_state.json.tmp.<pid-or-random>`), flush it fully, then rename the temp file over the target. A rename onto an existing path within the same filesystem is atomic — the file at that path is either the old complete version or the new complete version, never a partial write caught mid-flush. This is the actual prevention for the corruption case the "Recovery" section below describes reactively: if every write is atomic, a run getting killed mid-save should leave the *previous* complete state intact rather than a torn file.

If your execution environment doesn't expose a raw temp-file-plus-rename primitive directly, approximate the same guarantee however it does expose one (e.g. a tool-provided atomic write, or write-to-new-path-then-move) — the requirement is "the file on disk is always fully one version or fully another," not the specific syscalls.

`execution_log.md` is the one exception, by design — it's append-only, and an append that gets cut off mid-line is a different, more recoverable failure mode (see "Recovery" below) than a full-file rewrite landing half-written.

## `audit_state.json` — the authoritative record

Load this first on every execution; save it last before exit. At minimum it holds:

- `schema_version` — an integer, bumped whenever this file's structure changes. If a future execution encounters a `schema_version` it doesn't recognize (too old or too new relative to what its own instructions describe), don't guess at the structure — read what fields you can, record the mismatch in the execution log, and migrate conservatively (add new fields, don't delete unrecognized ones you can't yet interpret) rather than assuming compatibility.
- current source metadata (`type`, target path(s), a hash, size, compile result, timestamp — see the `source` field below)
- current audit progress: completed areas, pending areas
- finding IDs and their statuses
- an explicit task queue model (below) rather than an implicit one
- execution history (or a pointer into `execution_log.md`)
- active priorities
- any interrupted task, recorded precisely enough to resume mid-task

### Task queue model

Making the queues explicit is what makes each execution's behavior deterministic instead of relying on the model to reconstruct "what should I be doing" from prose:

```json
{
  "schema_version": 4,
  "active_task": null,
  "pending_tasks": [],
  "verification_queue": ["F-0012", "F-0019"],
  "deferred_queue": ["F-0031"],
  "maintenance": {
    "executions_since_periodic_check": 12,
    "last_periodic_check_at": "2026-07-18T04:00:00Z"
  },
  "source": {
    "type": "file",
    "targets": ["BuyerEdgeStrategy.py"],
    "combined_sha256": "…",
    "file_count": 1,
    "compiles": true,
    "last_refreshed": "2026-07-18T04:00:00Z",
    "archive_path": "archives/source_20260718T040000Z.py"
  }
}
```

`maintenance` is what turns "every 50 executions or 24 hours" (§6/§8/§11 in `references/consistency-and-safeguards.md`) from something you'd otherwise have to recall across dozens of stateless executions into two numbers you check and update anyway. Increment `executions_since_periodic_check` every run; when it reaches 50, or `last_periodic_check_at` is more than 24 hours in the past, run the periodic checks and reset both fields. Don't estimate or round — this is exactly the kind of arithmetic a long-running, memoryless process should never trust to recollection.

`source.type` is one of `file`, `files`, or `directory`, matching whatever `AUDIT_TARGET` resolved to (see `config/auditor.conf`). `targets` lists the actual path(s) — one entry for `file`, several for `files`, the directory root for `directory`. `combined_sha256` is that file's hash for a single file, or a hash of a sorted manifest (path + per-file hash, one line each) for `files`/`directory` — the point is that any change anywhere in scope changes this value, not that it's individually reversible. `compiles` may be a single boolean or, for `files`/`directory` targets where some files have a checker and others don't, a short per-file map — record what's actually true rather than forcing a single boolean that hides which files were skipped. `archive_path` points at a single-file copy for `file` targets or a tarball for `files`/`directory` targets, in the project's top-level `archives/` (not `work/archives/` — see the directory layout above).

- `active_task` — the one task currently in progress, or `null`. If non-null on load, that's the interrupted task from the previous run — resume it before anything else.
- `pending_tasks` — work that's been identified but not started.
- `verification_queue` — finding IDs awaiting re-verification (populated by a diff that affects them, or a periodic spot-check).
- `deferred_queue` — items parked per `references/consistency-and-safeguards.md` §7 (`Unresolved-Insufficient-Evidence` / `Deferred-Human-Review`) — only revisited on a relevant source change or explicit user request, never on a plain schedule tick.

Each execution drains these in a fixed order, matching `SKILL.md`'s priority list exactly: `active_task` → `verification_queue` → `deferred_queue` (only entries whose relevant source actually changed) → discover new work → persist. Never reorder this, and never let a later stage start while an earlier one has actionable work left.

If this file is missing or corrupted, recover as much as possible from `execution_log.md` and the two reports before falling back to a fresh state file — and if you do fall back, record the recovery event and preserve the existing reports rather than overwriting them. See "Recovery" below for the full ordered fallback.

## Metrics and heartbeat (for external monitoring)

Two lightweight files exist purely so external tooling can check on the auditor without parsing `audit_state.json` or the full reports:

`work/metrics.json` — aggregate trend stats, updated at the end of every execution:
```json
{
  "executions": 148,
  "findings_open": 3,
  "findings_verified": 42,
  "false_positives": 1,
  "average_runtime_sec": 81,
  "last_success": "2026-07-18T04:05:00Z",
  "last_failure": null
}
```

`work/heartbeat.json` — a snapshot of just the most recent execution, small enough to poll cheaply and frequently:
```json
{
  "started_at": "2026-07-18T04:00:00Z",
  "completed_at": "2026-07-18T04:05:00Z",
  "status": "success",
  "source_hash": "…",
  "schema_version": 4
}
```

Neither file is authoritative — `audit_state.json` remains the single source of truth for anything the model itself reasons from. These two exist only to give an external health-check or dashboard something cheap to read.

## Execution flow (one run, start to exit)

```
START
  │
  ▼
Load audit_state.json
  │
  ▼
"What was I doing previously?" — resume unfinished work first
  │
  ▼
Check active source hash against last-known hash
  │
  ├── changed → archive previous version, diff, determine which
  │              findings are affected, re-verify only those
  │
  └── unchanged → continue
  │
  ▼
Any finding still needing verification? ──yes──▶ verify it
  │no
  ▼
Time/budget remaining? ──yes──▶ search for new findings,
  │                              generate candidate fixes for Open items,
  │                              strengthen weak evidence
  │no
  ▼
Update findings register + closure report (must agree)
  │
  ▼
Append to execution_log.md (never rewrite history)
  │
  ▼
Update auditor_governance.md if a process lesson was learned
  │
  ▼
Run self-consistency check (see audit-methodology.md)
  │
  ▼
Save audit_state.json
  │
  ▼
EXIT
```

Unrelated findings are left untouched on every pass — only touch what the current diff or verification pass actually affects. This flow is the queue model above expressed as a diagram — "resume unfinished work" is draining `active_task`, "any finding still needing verification" is the `verification_queue`, and the diff-affected re-verification step feeds items into that same queue rather than handling them ad hoc.

## Scheduling architecture (cron/systemd + lock, any agent CLI)

The intended deployment is: a scheduler triggers `scripts/run_auditor.sh` every few minutes; it acquires an exclusive lock before invoking whichever agent CLI is configured, so overlapping runs can't write the workspace concurrently.

```
cron / systemd timer (every N minutes)
        │
        ▼
scripts/run_auditor.sh          (thin dispatcher — reads config/auditor.conf)
        │
        ▼
scripts/runners/run_with_<AGENT_CLI>.sh   (CLI-specific: builds the real invocation)
        │
        ▼
scripts/lib/reliability.sh       (CLI-agnostic: lock, circuit breaker, exit codes)
        │
        ▼
Skill execution (this file's flow, above) — same regardless of which CLI ran it
        │
        ▼
Updates to work/*.md, audit_state.json, metrics.json, heartbeat.json
        │
        ▼
Exit + log
```

This skill is not tied to one agent CLI. `scripts/run_auditor.sh` is a thin dispatcher: it reads `AGENT_CLI` from `config/auditor.conf` and hands off to the matching `scripts/runners/run_with_<AGENT_CLI>.sh`. All the reliability logic — locking, lock metadata, the circuit breaker, structured exit codes, prior-failure carry-forward — lives once in `scripts/lib/reliability.sh` and is shared by every runner; a runner only supplies the handful of things that genuinely differ per CLI (the actual invocation, session-id extraction, and any CLI-specific failure-detection quirk). See `adapters/README.md` for the exact contract, and `adapters/<cli>.md` for what's true of each currently-supported CLI (opencode, Claude Code, Gemini CLI, Codex CLI, Hermes) — flags, skill-install location, session continuity, and any documented reliability quirks specific to that CLI. Adding support for a new agent CLI later means writing one new runner file against that contract, not touching this file or SKILL.md.

Key points that apply regardless of which CLI is configured:

- **Configure `config/auditor.conf` before first use** (copy it from `config/auditor.conf.example`, or let `installer/install.sh` do it interactively). Every runner's preflight check refuses to run — with a clear logged reason — if `MODEL_NAME` is still a placeholder, the CLI binary isn't on `PATH`, the skill isn't installed where that CLI expects to find it, or the project path doesn't exist. A misconfigured 24×7 deployment should fail loudly on the first tick, not fail silently and confusingly until the circuit breaker happens to catch it three ticks later.
- **Verify your CLI's actual flags before deploying, on every upgrade.** Every runner in this repo was written against a real `--help` output or official docs at the time — flags still change between versions. A runner assuming a flag that doesn't exist is exactly the kind of bug covered in `adapters/README.md`'s testing note.
- **Session continuity is explicit per-adapter, never assumed to be free.** Each CLI handles multi-turn continuity differently (some need an explicit captured id, some have their own "resume latest" concept, some barely document it) — see the specific adapter. In every case this is a cost/context optimization only: SKILL.md's "no conversational memory assumed" design means audit correctness never depends on it working.
- **Don't copy one CLI's failure-detection heuristic onto another.** For example, treating non-empty stderr as a failure is correct and documented for opencode, but would misfire constantly on a CLI that streams normal progress to stderr by design (Codex CLI does this) — each runner's `classify_failure()` is CLI-specific for exactly this reason.
- **Lock first.** A run that takes longer than the schedule interval must not overlap with the next trigger. `flock -n <lockfile>` in `scripts/lib/reliability.sh` is the standard mechanism — if the lock is already held, the new invocation exits immediately without touching anything.
- **Lock metadata, not just the lock itself.** The library writes a small companion file (`<lockfile>.meta`) with the holder's PID, hostname, and start time the moment it acquires the lock, and cleans it up on exit. A bare `flock` tells you *that* something else holds it; the metadata tells you *what* — which is what you actually want when deciding whether a long-running execution is legitimately still working or actually stuck.
- **Enforce it twice.** The lock file is a mechanical safeguard, not a substitute for the model-level rule in `SKILL.md` ("never execute more than one audit instance against the same workspace... terminate immediately without modifying any state files") — either one failing shouldn't corrupt state.
- **Capture failure, don't just log it.** On a non-zero exit (model timeout, token limit, interrupted run), the library records that in the workspace *before* the process exits, so the next execution's "what was I doing previously?" step sees the failure and can factor it in rather than repeating it blindly.
- A minimal crontab entry (works with any configured `AGENT_CLI`):
  ```cron
  */5 * * * * /opt/auditor/continuous-code-auditor/scripts/run_auditor.sh >> /opt/auditor/logs/cron.log 2>&1
  ```

## Exit code contract

`scripts/lib/reliability.sh` returns structured exit codes rather than a plain 0/1, so external monitoring (a healthcheck script, `systemctl show -p ExecMainStatus`, a textfile collector) can tell *what kind* of outcome happened without parsing logs — and these codes are identical no matter which agent CLI is configured:

| Code | Meaning | Set by |
|---|---|---|
| `0` | Success | library |
| `10` | Skipped — another instance already held the lock | library |
| `12` | Skipped — circuit breaker is held (see §9 in consistency-and-safeguards.md) | library |
| `13` | Skipped — paused via `/continuous-code-auditor-stop` (or `scripts/commands/stop.sh`) | library |
| `14` | Deferred — host under resource pressure (load/memory); self-clearing, retried next tick | library |
| `15` | Preflight/config failure (CLI missing, `MODEL_NAME` never configured, skill not installed where the CLI expects, bad paths) | library / adapter preflight |
| `20` | Active source failed to compile | model, via sentinel below |
| `30` | A configured source fetch failed | model, via sentinel below |
| `40` | Generic prompt/model-side failure not covered by the above | library (fallback) |
| `50` | State recovery was invoked this run (may co-occur with an otherwise-successful run — still worth flagging to monitoring) | model, via sentinel below |
| `1` | Unrecognized non-zero failure (e.g. an unrelated shell error inside the wrapper itself) | library (fallback) |

Codes `20`, `30`, and `50` depend on the model itself, not the shell wrapper — the wrapper can only see the final exit status of the CLI invocation, which most runners don't let the model set directly. The bridge is a simple text convention, and it's the same across every adapter: `SKILL.md` instructs the model to print exactly one line, `AUDITOR_EXIT_REASON: <reason>`, near the end of its output whenever one of these conditions applies. The library captures the run's output, looks for that line, and maps it to the corresponding code — falling back to a generic success/failure split on the raw process exit status if the model never printed one (e.g. an older skill version, or a runner that swallows output).

Before that mapping runs, each runner gets a chance (via its `classify_failure()` hook) to override `$STATUS` based on anything CLI-specific it knows how to check — for example, the opencode adapter treats a `0` exit status alongside non-empty stderr as a failure anyway (a documented false-success quirk for that CLI specifically), while the Codex CLI adapter instead scans the JSONL stream for an explicit `turn.failed` event, because for that CLI non-empty stderr is normal progress output, not a failure signal. See `adapters/<cli>.md` for what each adapter actually checks and why — do not assume one CLI's heuristic transfers to another.

Treat `10`, `12`, `13`, and `14` as informational for alerting purposes (a lock conflict, an already-known held state, an intentional pause, or a self-clearing resource deferral isn't a *new* failure), `50` as informational-but-worth-a-look, and `15`/`20`/`30`/`40`/`1` as the set that should count toward the circuit breaker and trigger a real alert. If your cron setup mails on any non-zero exit, you may want to adjust `MAILTO` handling or filter on these specific codes so a benign lock-skip or pause doesn't page anyone.

## Recovery

If workspace files are corrupted or unreadable: recover everything possible first. Never discard valid findings to make recovery easier. Only create fresh state as a last resort, and even then preserve the existing archived reports and record the recovery event in the execution log.

### If `audit_state.json` cannot be parsed completely

This is the specific, most likely corruption case — a run gets killed mid-write (timeout, OOM, power loss) partway through saving state — and it needs its own ordered fallback rather than jumping straight to "rebuild from scratch":

1. Attempt recovery from `execution_log.md` (it's append-only, so the last clean entry tells you what the state should reflect).
2. If that's insufficient, use the findings register (`continuous_code_audit_findings.md`) as the secondary source of truth for finding IDs and statuses.
3. If still insufficient, use the closure report as a tertiary source for overall conclusions.
4. Rebuild only the minimal `audit_state.json` fields you can't otherwise recover — don't regenerate fields you were able to recover from steps 1–3.
5. Record the recovery event (what was unreadable, what you reconstructed from where) in the execution log.
6. Do not overwrite either report during this process — reports are recovery *sources* here, not something to regenerate from a guess.

## Deployment hardening for a 24×7, root-level, always-on instance

Cron + `flock` (above) is enough to make executions safe to run repeatedly. Running this unattended, at root, essentially forever on a real server calls for a few things on top of that — none of which change the audit workflow itself.

### Prefer systemd (service + timer) over raw cron for a permanent install

A `systemd` timer gives you locking, restart policy, resource ceilings, and structured logs (`journalctl`) largely for free, with less custom shell script that can itself have bugs. Example units:

`/etc/systemd/system/continuous-code-auditor.service`:
```ini
[Unit]
Description=Continuous code auditor (single execution)

[Service]
Type=oneshot
ExecStart=/opt/auditor/continuous-code-auditor/scripts/run_auditor.sh
TimeoutStartSec=240
# --- least-privilege, even when the host is root-administered ---
User=auditor
Group=auditor
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
# Note: $PROJECT itself must be listed here, not just work/ and archives/ —
# "Source loading and versioning" in SKILL.md writes the freshly fetched
# source back into the project root on every refresh (whether AUDIT_TARGET
# is a file, several files, or the whole tree). Under ProtectSystem=strict,
# anything not listed in ReadWritePaths is mounted read-only: fine for
# reads, but a refresh's write would fail silently against policy if the
# project root were left out.
ReadWritePaths=/srv/your-project /opt/auditor/logs
# --- resource ceilings ---
MemoryMax=2G
CPUQuota=200%
```

`/etc/systemd/system/continuous-code-auditor.timer`:
```ini
[Unit]
Description=Run the continuous code auditor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30sec

[Install]
WantedBy=timers.target
```

`systemd` itself won't overlap a `oneshot` unit's next timer trigger with a still-running instance of the same unit, which gives you a second, independent layer of protection beyond `flock`.

### Least privilege, even at root

The box being root-administered doesn't mean the audit process itself needs to run as root. `User=auditor` above plus `ReadWritePaths=` scoped to just the source, workspace, and archive directories limits the blast radius if the model or a tool call misbehaves — without changing anything about what the auditor is allowed to *decide*. If your CLI/runner supports its own tool allowlisting (e.g. restricting shell/network access it can invoke), apply the same principle there: read/compile/diff access to the project, write access to `work/` and `archives/`, nothing broader by default.

### Resource ceilings and timeouts

- Wall-clock timeout per execution (`TimeoutStartSec=` above, or `timeout 240 ...` if staying on plain cron) so a single hung run can't block indefinitely — `flock -n` already keeps a hung run from blocking *new* executions, but the hung one should still be able to self-terminate.
- Memory/CPU ceilings (`MemoryMax=`, `CPUQuota=`) so a runaway execution can't degrade the rest of the server.

### Log and archive retention

Running every few minutes forever will otherwise grow `archives/` and log files without bound:

- Point `logs/` at `logrotate`, or rely on journald's own retention if fully on systemd.
- Define an archive retention policy for `archives/source_<timestamp>.py` (e.g. keep the last K, or last N days) — but never delete an archive that's still cited as evidence for an unresolved or `Contradiction-Flagged` finding.
**All of the below is enforced in code as of v1.5.0** (`enforce_retention()` in `scripts/lib/reliability.sh`, run before preflight so pruning can free space ahead of the disk gate). Prior to that it was documented policy that nothing implemented — which is worse than no policy, because it reads as handled.

- **`execution_log.md` needs its own rotation policy, distinct from the above.** It's append-only by design (never rewrite history), but "append-only forever" still means unbounded growth over months of 24×7 runs — and eventually the model ends up reading the whole thing every execution just to answer "what was I doing previously?", wasting tokens on ancient history. Rotate it: keep roughly the last 1000 executions in the active `execution_log.md`, move older entries into `logs/execution_log_archive/` (chunked by date or count, same as source archives), and keep a short running summary of the archived portion in `audit_state.json` so nothing is actually lost — just no longer re-read by default.

### Circuit breaker and alerting

Wire the circuit breaker's `held` state (see `references/consistency-and-safeguards.md` §9) and any `Contradiction-Flagged` finding to a real notification — mail, webhook, whatever's available in your environment. A fully autonomous 24×7 process should not fail silently for days before a person notices; a `held` state with no alert defeats the point of having one.

### Scheduler-liveness watchdog — a different failure mode than the circuit breaker

The circuit breaker only reacts to executions that actually *happen*. If the scheduler itself dies — `systemd` timer gets disabled, the cron daemon stops, the host reboots and the timer never re-enables — no execution ever runs, nothing ever fails, and the circuit breaker stays silent forever. This is a structurally different failure mode and needs a structurally separate check.

`scripts/watchdog.sh` is that check: it reads `work/heartbeat.json`'s age (falling back to `auditor.log`'s mtime) and alerts if it's older than `WATCHDOG_MAX_STALE_MINUTES` (default 30). It's deliberately independent of `scripts/lib/reliability.sh` — it must keep working even if everything else has silently stopped — and must run on its **own** schedule, separate from the main auditor timer, so a dead main scheduler doesn't take the thing watching it down too:

```bash
sudo systemctl enable --now continuous-code-auditor-watchdog.timer
```

(see `scripts/systemd/continuous-code-auditor-watchdog.service` / `.timer` — a 10-minute check interval against a 30-minute staleness threshold gives 2-3 missed main-timer ticks of slack before alerting). It correctly treats an intentional pause (`paused.flag`) or an already-alerting circuit breaker (`held.flag`) as expected staleness, not a scheduler failure — it only fires when the auditor should be running and simply isn't.

**The watchdog has its own, deliberately simple exit-code contract**, separate from the dispatcher's table above — don't conflate the two, since `1` means something different in each:

| Code | Meaning |
|---|---|
| `0` | Healthy, or intentionally not checking (paused, breaker held, no heartbeat yet) |
| `1` | Stale — no execution in longer than `WATCHDOG_MAX_STALE_MINUTES`; the scheduler itself may be dead |

It only ever reports; it never writes to `work/`, never touches the pause/hold flags, and never runs an audit itself.

### Resource gating: disk (hard failure) vs. load/memory (deferral)

Two different kinds of resource pressure, deliberately handled two different ways — the distinction matters more than either check individually.

**Disk is a hard failure.** A 24×7 process that archives and logs forever will eventually fill a disk if the retention above isn't actually enforced. Preflight (in `scripts/lib/reliability.sh`, shared by every adapter) checks available space on the filesystem holding `PROJECT` against `MIN_FREE_DISK_MB` (default 100) and refuses to run below it with exit `15`. Failing loudly here is much better than failing partway through an atomic write or lock creation — and a full disk does not resolve itself, so it *should* demand attention.

**Load and memory are deferrals.** `MAX_LOAD_PER_CPU` (default 4.0, per-CPU so the same value works on a 1-core VM and a 32-core server) and the optional `MIN_FREE_MEM_MB` are checked before preflight and before the lock is taken. Exceeding either returns exit `14` and skips that tick — it does **not** call `record_failure`, does **not** count toward the circuit breaker, and is retried on the next scheduler tick.

That asymmetry is the whole design. If overload were treated as a failure, three busy ticks in a row would trip the circuit breaker and require a human to clear `held.flag` — for a condition that would have resolved itself in minutes. Grouping `14` with the other informational skips (`10` lock-held, `12` breaker-held, `13` paused) rather than the `15`+ failures keeps self-clearing conditions self-clearing.

Practical notes: the memory check reads `MemAvailable`, not `MemFree`, so a warm page cache doesn't cause constant spurious deferrals. Both gates read `/proc`, so on a non-Linux host they simply don't engage — the auditor runs normally rather than erroring. Set `MAX_LOAD_PER_CPU=""` to disable load gating entirely; `MIN_FREE_MEM_MB` is unset (off) by default, since what counts as "low memory" varies far more between deployments than load does.

If you see frequent `14`s in `logs/auditor.log`, the host is genuinely contended — either the audit schedule is too aggressive for the box, or something else on it is. That's useful signal, not noise.

### Stale-session self-healing

Over a long enough deployment, a stored session id (see each adapter's session-continuity section) can go stale or expire — and every retry then fails the exact same way, indistinguishable from a real persistent failure, right up until it trips the circuit breaker for something a fresh session would have silently fixed. `scripts/lib/reliability.sh` drops the stored session id one failure before the breaker would trip (`FAILURE_THRESHOLD - 1` consecutive failures), giving a clean-slate retry a chance first. This is safe regardless of whether a stale session was actually the cause — session continuity is a cost optimization only, never a correctness dependency (see `adapters/README.md`).

### Cumulative cost ceiling

Distinct from any per-invocation cap an adapter already applies (e.g. Claude Code's own `--max-budget-usd` for a single run — see `adapters/claude-code.md`), `CUMULATIVE_BUDGET_USD` in `config/auditor.conf` caps *lifetime* spend across the whole deployment. Only meaningful for adapters that implement the optional `extract_cost_usd` hook (currently just Claude Code, via its `--output-format json` `total_cost_usd` field) — a no-op for the rest, which is a documented limitation, not a bug. When the running total (`logs/cumulative_cost_usd.txt`) reaches the budget, the auditor pauses itself exactly the way `/continuous-code-auditor-stop` does; clear it the same way, with `/continuous-code-auditor-start`, once you've reviewed spend.

