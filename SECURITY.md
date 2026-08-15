# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

Use GitHub's private vulnerability reporting on this repository ([Security → Report a vulnerability](https://github.com/manojvermamv/continuous-code-auditor/security/advisories/new)), or contact the maintainer through the profile at [github.com/manojvermamv](https://github.com/manojvermamv).

Please include: what you found, how to reproduce it, and what an attacker could do with it. A proof of concept helps enormously — the one confirmed vulnerability in this project's history (below) was fixed the same day precisely because it came with a reproducible demonstration rather than a theoretical description.

## Why this project warrants a security policy

This is not a passive library. A deployed installation:

- executes an agent CLI autonomously, unattended, on a schedule
- reads and writes files in the audited project, its workspace, and its log directory
- runs shell commands as whatever user the scheduler is configured with
- may run indefinitely with nobody watching it

That combination means an input-handling bug here has real blast radius. Threat model, in short: the audited source code and any user-supplied arguments are **untrusted input**; the workspace and log directory are **trusted state**; the boundary between them is where bugs matter most.

## Hardening recommendations for deployments

These are documented in full in [`references/workspace-and-execution.md`](references/workspace-and-execution.md); briefly:

- Run as a **dedicated non-root user** (`User=auditor` in the shipped systemd unit), even on a root-administered host.
- Keep `ProtectSystem=strict` with a minimal `ReadWritePaths=` — the shipped unit grants write access only to the project and log directories.
- Narrow the agent CLI's own tool permissions to what the audit actually needs (see each `adapters/<cli>.md`; the Claude Code adapter's `CLAUDE_ALLOWED_TOOLS` is a starting point to *narrow*, not to accept as-is).
- Set `MemoryMax=`/`CPUQuota=` ceilings and a wall-clock `TIMEOUT_SECONDS`.
- Set `CUMULATIVE_BUDGET_USD` if your adapter supports cost reporting, so an unattended loop can't run up an unbounded bill.

The skill's own [capability boundary](SKILL.md) also forbids it from deploying code, modifying production infrastructure, or patching the audited source without an explicit instruction — defense in depth alongside the OS-level controls above, not a replacement for them.

## Incident record

Kept publicly and numbered, so the project's actual security history is inspectable rather than implied.

| # | Date | Severity | Issue | Status |
|---|---|---|---|---|
| 01 | v1.1.1 | Moderate | **Path traversal via command label.** `scripts/commands/archive.sh` and `scripts/commands/backup-everything.sh` accepted an optional label argument and used it unsanitized to build a filesystem path. Confirmed exploitable: a label of `../../../../tmp/x` caused an archive to be written outside `work/archives/` entirely. Found during a comparative architecture review after noticing a similar bug class documented by another project. | **Fixed** in v1.1.1 — labels are now sanitized to `[A-Za-z0-9_-]` in `sanitize_label()` (`scripts/commands/_common.sh`), with a permanent regression test in `tests/run_tests.sh`. All other commands were audited for the same bug class; none were affected. |

## Supported versions

This project follows semantic versioning. Security fixes land on the latest released version; there are no maintained long-term-support branches at this time.
