# continuous-code-auditor

[![CI](https://github.com/manojvermamv/continuous-code-auditor/actions/workflows/ci.yml/badge.svg)](https://github.com/manojvermamv/continuous-code-auditor/actions/workflows/ci.yml)
**v1.1.1** · **by [Manoj Verma](https://github.com/manojvermamv)** · [github.com/manojvermamv/continuous-code-auditor](https://github.com/manojvermamv/continuous-code-auditor) · [MIT license](LICENSE) · [CHANGELOG](CHANGELOG.md) · [ROADMAP](ROADMAP.md)

A continuous, resumable code-audit **Agent Skill**. Conforms to the open [Agent Skills specification](https://agentskills.io/specification), works with several different agent CLIs through a small adapter layer, and audits whatever you point it at — a single file, a set of files, or an entire project directory.

This is not a one-off "review my code" prompt. It's a persistent audit *lifecycle*: an unattended process that keeps re-checking a codebase over months of scheduled executions, without conversational memory between runs and without losing progress, evidence, or process discipline along the way.

## Why this exists

Point-in-time code reviews go stale the moment the code changes again. This skill is built for the alternative: something continuously watching, not something you ran once.

- **The workspace is the memory, not the conversation.** Every execution can be a fresh process with zero context and still pick up exactly where the last one left off, because state lives on disk (`work/audit_state.json` and friends), not in a chat session.
- **No finding without evidence, no evidence without file-and-line citations.** A speculative "this might be a race condition" never becomes a filed finding — it gets parked until there's something to actually cite.
- **Contradictions get flagged, not silently overwritten.** If a later run reaches a different conclusion than an earlier one about unchanged code, that's a signal for human review, not a status update.
- **It tracks its own mistakes.** Duplicate findings, false positives, and unnecessary re-audits get logged to a structured mistake ledger and checked against before repeating.
- **It audits whatever you point it at.** One file, several named files, or a whole project tree — configured once in `config/auditor.conf`, not hardcoded to a specific project.
- **It isn't married to one AI product.** The reliability engine (locking, circuit breaker, structured exit codes) is completely agent-agnostic; only a thin per-CLI adapter differs. Today: opencode, Claude Code, Gemini CLI, Codex CLI, and Hermes Agent. Adding another is one new file, documented in [`adapters/README.md`](adapters/README.md).
- **It has an operational control surface, not just an audit loop.** `status`, `start`, `stop`, `archive`, `backup-everything`, `uninstall`, and `reset` are real commands — native slash commands where the CLI supports it, and always available as plain scripts otherwise.

## Architecture at a glance

The simplest way to see it, top to bottom:

```
Scheduler (systemd timer / cron)
        │
        ▼
scripts/run_auditor.sh        (dispatcher — reads config/auditor.conf)
        │
        ▼
scripts/runners/run_with_<cli>.sh   (the adapter — CLI-specific invocation)
        │
        ▼
Your configured agent CLI      (opencode / Claude Code / Gemini CLI / Codex CLI / Hermes)
        │
        ▼
SKILL.md                       (the instructions the agent follows)
        │
        ▼
Workspace (work/, archives/)   (state, findings, reports — read and written each run)
```

Two things that are easy to conflate but aren't the same thing:

```
THE SKILL PACKAGE (this repo — versioned, distributed, the same on every deployment)
continuous-code-auditor/
├── SKILL.md                  ← the core prompt: mission, guardrails, capability boundary
├── references/               ← methodology, safeguards, workspace/execution design (loaded on demand)
├── scripts/
│   ├── lib/reliability.sh        ← CLI-agnostic engine: lock, circuit breaker, exit codes, pause/hold
│   ├── runners/                  ← one adapter script per supported agent CLI
│   ├── commands/                 ← the seven operational commands (status/start/stop/archive/…)
│   └── run_auditor.sh            ← thin dispatcher
├── commands/                 ← native slash-command files per CLI (Claude Code, Gemini CLI)
├── config/                   ← auditor.conf.example — copy & fill in per deployment
├── adapters/                 ← one doc per supported agent CLI: flags, quirks, verification steps
├── installer/                ← install.sh
└── README.md                 ← this file

THE RUNTIME WORKSPACE (created per-deployment, lives with the audited project — NOT part of this repo)
<your-project>/
├── <AUDIT_TARGET>              ← one file, several files, or this whole tree (config/auditor.conf)
├── work/                        ← the model's own authoritative state (atomic writes required)
│   ├── audit_state.json             (schema_version, active_task, queues, source metadata)
│   ├── continuous_code_audit_findings.md
│   ├── continuous_code_audit_closure_report.md
│   ├── execution_log.md             (append-only, rotated)
│   ├── auditor_governance.md        (narrative lessons about its own process)
│   ├── mistake_ledger.json          (the same lessons, structured & checkable)
│   ├── negative_knowledge.json      (specific rejected findings, so they aren't re-raised)
│   ├── metrics.json / heartbeat.json
│   ├── candidate_fixes.md
│   └── archives/                    ← reset-time snapshots ONLY — see /reset below. Protected: this
│                                        directory is never itself reset or deleted.
├── archives/                    ← one archived source snapshot per refresh (file copy or tarball)
└── backups/                     ← full disaster-recovery bundles — see /backup-everything below

WRAPPER-INTERNAL STATE (owned by the shell scripts, not the model)
<your log dir>/
├── auditor.log, cron.log
├── last_failure.txt, consecutive_failures.txt, held.flag, paused.flag
└── <agent>_session_id.txt
```

Execution flow, end to end:

```
cron / systemd timer
        │
        ▼
scripts/run_auditor.sh            (thin dispatcher — reads config/auditor.conf)
        │
        ▼
scripts/runners/run_with_<cli>.sh (CLI-specific: the real invocation, session handling)
        │
        ▼
scripts/lib/reliability.sh        (CLI-agnostic: lock, circuit breaker, pause/hold, exit codes)
        │
        ▼
Your agent CLI runs SKILL.md's instructions against the workspace above
        │
        ▼
Updates to work/*, metrics.json, heartbeat.json → exit + log
```

Full detail on the state machine, atomic-write requirements, the three distinct "archive" concepts, recovery hierarchy, and deployment hardening lives in [`references/workspace-and-execution.md`](references/workspace-and-execution.md). Anti-hallucination and consistency mechanics (evidence rubric, contradiction detection, the mistake ledger, the circuit breaker) live in [`references/consistency-and-safeguards.md`](references/consistency-and-safeguards.md).

## What it audits

`config/auditor.conf`'s `AUDIT_TARGET` is one of three shapes, relative to `PROJECT`:

```bash
AUDIT_TARGET="BuyerEdgeStrategy.py"                    # a single file
AUDIT_TARGET="src/orders.py src/risk.py src/broker.py" # several named files, treated as one logical source
AUDIT_TARGET="."                                        # the whole project tree
```

All three are hashed, archived, and (where a checker exists for the language involved) compile/lint-checked the same way — see `SKILL.md`'s "Source loading and versioning". The core risk categories (concurrency, security boundaries, data integrity, error handling, external I/O) are generic; if you want deployment-specific risk areas weighted just as heavily (e.g. a trading system's order lifecycle and position accounting), add them to `references/domain-focus.md` — `SKILL.md` reads that file, if present, as required additional focus.

## Supported agent CLIs

| CLI | Adapter doc | Skill discovery | Native `/` commands |
|---|---|---|---|
| [opencode](https://opencode.ai) | [adapters/opencode.md](adapters/opencode.md) | `--file` attachment (no confirmed auto-discovery convention) | no — universal fallback in `SKILL.md` |
| [Claude Code](https://code.claude.com) | [adapters/claude-code.md](adapters/claude-code.md) | `~/.claude/skills/` or `.claude/skills/` | yes — `commands/claude-code/` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | [adapters/gemini-cli.md](adapters/gemini-cli.md) | `~/.gemini/skills/` or `.gemini/skills/` (project scope needs `/trust`) | yes — `commands/gemini-cli/` |
| [Codex CLI](https://developers.openai.com/codex) | [adapters/codex-cli.md](adapters/codex-cli.md) | `~/.codex/skills/` or `.codex/skills/` | no (deprecated/uncertain mechanism) — universal fallback |
| [Hermes Agent](https://github.com/NousResearch/hermes-agent) | [adapters/hermes.md](adapters/hermes.md) | `~/.hermes/skills/<category>/`, explicit `-s` preload | no — universal fallback |

Every adapter's flags were checked against real `--help` output or official docs at the time it was written, and every one was actually run against a mocked CLI binary before being trusted — see [`adapters/README.md`](adapters/README.md) for the contract if you want to add a sixth.

## Operational commands

| Command | What it does |
|---|---|
| `/continuous-code-auditor-status` | Read-only: paused/held state, lock state, last run, findings summary. |
| `/continuous-code-auditor-start` | Resume scheduled execution (clears the pause flag). |
| `/continuous-code-auditor-stop` | Pause scheduled execution (doesn't interrupt a run already in progress). |
| `/continuous-code-auditor-archive` | Non-destructive checkpoint: copies current `work/` into `work/archives/`. |
| `/continuous-code-auditor-backup-everything` | Full disaster-recovery tarball: the skill + entire workspace, under `backups/`. |
| `/continuous-code-auditor-uninstall` | Removes scheduling and skill registration. Leaves audit data alone unless `--purge-data`. |
| `/continuous-code-auditor-reset` | **Destructive to the session, not to history**: archives everything into a timestamped `work/archives/<ts>/` snapshot, then reinitializes `work/` fresh. Requires explicit confirmation. `work/archives/` itself is never touched beyond adding that snapshot. |

Claude Code and Gemini CLI get these as real, tab-completing slash commands (installed by `installer/install.sh`). Every other CLI — and a plain terminal, any time — gets the same seven operations via `scripts/commands/<name>.sh` directly, or by asking your agent in plain language ("what's the audit status", "pause the auditor"); `SKILL.md`'s universal fallback recognizes both. See [`commands/README.md`](commands/README.md) for the full mechanism per CLI.

## Installation

### Option A — clone and run the installer

```bash
git clone https://github.com/manojvermamv/continuous-code-auditor.git continuous-code-auditor
cd continuous-code-auditor
./installer/install.sh
```

Answer the prompts (agent CLI, project path, audit target, model id, install scope, scheduling), or pass them as flags:

```bash
./installer/install.sh \
  --agent-cli codex-cli \
  --project /srv/your-project \
  --audit-target "." \
  --model gpt-5-codex \
  --scope personal \
  --schedule systemd
```

The installer writes `config/auditor.conf`, creates the runtime workspace directories (including `backups/`), symlinks the skill into your chosen CLI's skill directory (skipped for opencode), installs native slash commands where supported, and optionally wires up systemd or cron. It will tell you to run `scripts/run_auditor.sh` once manually before trusting the schedule — do that; it's a five-second check that's caught real bugs during this skill's own development.

### Option B — point your agent at this repo directly

If your agent CLI can fetch URLs and write files, you can skip the installer and just tell it to install itself:

```
Please fetch:
  https://raw.githubusercontent.com/manojvermamv/continuous-code-auditor/main/README.md
  https://raw.githubusercontent.com/manojvermamv/continuous-code-auditor/main/SKILL.md

Then, following the README's installation instructions for <your agent CLI>,
install this skill for yourself (copy or clone the full continuous-code-auditor/
folder — not just SKILL.md — into the skill directory your CLI uses), configure
config/auditor.conf for project path /srv/your-project and audit target <file,
files, or "."> with model <your-model>, and confirm the skill is active before
I rely on it.
```

This repo's actual path is `manojvermamv/continuous-code-auditor` — the URLs above already point at it. And note: an agent fetching only `SKILL.md` in isolation gets the core instructions but none of the reference docs, adapters, commands, or scripts it points to — for anything beyond a quick read, it needs the whole folder, which is why the prompt above asks for that explicitly.

## Configuration

Everything is one file: `config/auditor.conf` (copy from `config/auditor.conf.example`).

```bash
AGENT_CLI="codex-cli"           # opencode | claude-code | gemini-cli | codex-cli | hermes
MODEL_NAME="gpt-5-codex"         # format depends on the CLI — see adapters/<cli>.md
PROJECT="/srv/your-project"
AUDIT_TARGET="."                 # a file, "several files", or "." for the whole tree
LOG_DIR="/opt/auditor/logs"
TIMEOUT_SECONDS=240
FAILURE_THRESHOLD=3
```

Switching agent CLIs later is a one-line change to `AGENT_CLI`; switching what's audited is a one-line change to `AUDIT_TARGET`. Neither touches the findings, workspace, or methodology, because none of it lives in the CLI-specific or target-specific layer.

## Scheduling

Either works; systemd is recommended for a permanent 24×7 install (native overlap protection on top of `flock`, resource ceilings, `journalctl` logging):

```bash
# systemd (see scripts/systemd/ for the unit files, and the installer does this for you)
sudo systemctl enable --now continuous-code-auditor.timer

# cron
*/5 * * * * /opt/auditor/continuous-code-auditor/scripts/run_auditor.sh >> /opt/auditor/logs/cron.log 2>&1
```

Both call the same dispatcher, so the reliability behavior (locking, circuit breaker, pause/hold, structured exit codes) is identical either way. See the "Deployment hardening" section of [`references/workspace-and-execution.md`](references/workspace-and-execution.md) for least-privilege systemd sandboxing, log/archive retention, and the full exit-code contract.

## Safety: what this skill will and won't do

`SKILL.md` has an explicit, hard capability boundary:

> This skill may audit, verify, compile, diff, archive, and maintain workspace state. It must not deploy code, execute trades, modify production infrastructure, or apply source patches unless explicitly instructed.

It never modifies the audit target on its own initiative — it produces findings and candidate fixes, stored in the workspace, for a human (or an explicit follow-up instruction) to act on. Reliability features like the circuit breaker, atomic writes, and the concurrency safeguard exist to keep an unattended process from compounding a problem while nobody's watching, not to give it more autonomy over the live system. The `reset` command follows the same philosophy: it archives before it clears, and `work/archives/` itself is permanently exempt from being reset.

## Reliability features (short version)

- **Locking with metadata** — `flock` plus a companion file recording who holds it (PID, host, start time), so a stuck run is diagnosable, not a mystery.
- **Circuit breaker** — after 3 consecutive operational failures, the auditor stops and holds rather than retrying forever.
- **Scheduler-liveness watchdog** — a structurally separate check (`scripts/watchdog.sh`, its own systemd timer) for the failure mode the circuit breaker *can't* see: the scheduler itself dying silently, so no execution — and therefore no failure, and therefore no alert — ever happens at all.
- **Stale-session self-healing** — a session id that's gone stale over a long deployment gets dropped one failure before the circuit breaker would trip, rather than treated as a persistent failure needing operator intervention.
- **Disk-space preflight** — refuses to start a run if the filesystem holding `PROJECT` is critically low, rather than failing partway through an archive or lock.
- **Cumulative cost ceiling** — an optional lifetime spend cap (`CUMULATIVE_BUDGET_USD`), distinct from any adapter's per-invocation cap, for CLIs that report cost.
- **Pause/resume** — `/continuous-code-auditor-stop` and `/continuous-code-auditor-start` (or the underlying scripts) let a human intentionally halt scheduled runs, independent of the circuit breaker.
- **Structured exit codes** (`0`/`10`/`12`/`13`/`15`/`20`/`30`/`40`/`50`/`1`) — so external monitoring can tell success from a lock conflict from a pause from a held breaker from a compile failure, without parsing logs. Full table in `references/workspace-and-execution.md`.
- **Atomic writes** — every workspace state file is written via temp-file-then-rename, so a mid-write kill leaves the previous complete version intact, never a torn file.
- **Deterministic maintenance cadence** — periodic upkeep (log rotation, governance consolidation, spot-checks) is keyed off real counters in `audit_state.json`, not the model's recollection of "roughly every 50 runs" across months of stateless executions.
- **Prior-failure carry-forward** — a failed run's error is fed into the next run's context.
- **Evidence rubric, speculation trip-wire, contradiction detection, mistake ledger, negative-knowledge registry** — the actual anti-hallucination mechanics, detailed in `references/consistency-and-safeguards.md`.

## Adding support for another agent CLI

See [`adapters/README.md`](adapters/README.md) for the full contract. Short version: verify the CLI's real flags yourself, find out how it discovers skills, work out (or rule out) session continuity, write one runner script against `scripts/lib/reliability.sh`'s hooks, document it in `adapters/<cli>.md`, and test it against a mocked binary before trusting it. If it also has a confirmed custom-command mechanism, add `commands/<cli>/` following `commands/README.md`'s pattern.

## Testing & CI

```bash
bash tests/run_tests.sh                          # integration tests against mocked CLI binaries
python3 tests/validate_frontmatter.py .           # SKILL.md frontmatter vs. the agentskills.io spec
python3 tests/check_markdown_links.py .           # internal markdown link check
shellcheck scripts/**/*.sh installer/install.sh   # if you have shellcheck installed
```

All four run in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) on every push and PR. `tests/run_tests.sh` never touches the repo's own `config/`, `work/`, or `logs/` — every run uses a throwaway scratch directory and `AUDITOR_CONFIG` (which every script in this repo respects as a config-path override), cleaned up automatically on exit. See [`tests/README.md`](tests/README.md) for what the mocked tests do and don't prove.

## Stability & versioning

`v1.0.0`/`v1.1.0` mark this as a frozen, stable contract rather than an evolving prototype — see [`CHANGELOG.md`](CHANGELOG.md). Specifically frozen: the adapter hook interface in `scripts/lib/reliability.sh` (`invoke_agent`, `extract_session_id`, `classify_failure`, `agent_specific_preflight`, `extract_cost_usd`), the structured exit-code table, and the seven operational commands' CLI surface. Breaking changes to any of those bump the major version. The biggest deferred idea — generalizing beyond code auditing into a domain-agnostic auditing framework (security, docs, infra, compliance, …) — turns out to need less engine rework than it sounds like, since the reliability engine already has almost zero code-specific coupling; it's still a deliberate v2.0.0-scale identity decision, not a quick add. That and everything else deferred to keep this release stable are tracked in [`ROADMAP.md`](ROADMAP.md) rather than half-built into this one.

## License

MIT (see [`LICENSE`](LICENSE)) for the skill/tooling in this repository (`SKILL.md`, scripts, adapters, commands, docs). This does not apply to whatever code this skill audits — that remains under whatever license/ownership already governs it. Change the `license` field in `SKILL.md`'s frontmatter and `LICENSE` if MIT isn't the right choice for how you're distributing this.

## Author

[Manoj Verma](https://github.com/manojvermamv) — [github.com/manojvermamv/continuous-code-auditor](https://github.com/manojvermamv/continuous-code-auditor)

## Disclaimer

This is an audit tool, not a safety mechanism for whatever it's pointed at. It reports findings for human review; it does not validate, approve, or block anything, and — especially for a system like a live trading strategy — it should never be the only check between a code change and production impact. See the Capability Boundary above and in `SKILL.md`.
