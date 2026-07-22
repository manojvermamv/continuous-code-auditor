# Operational commands

Seven deterministic, non-model operations live in `scripts/commands/` — deliberately implemented as plain bash, not left to model judgment, because things like "reset" and "uninstall" should behave identically every time regardless of which agent CLI or model is running the skill:

| Command | Script | What it does |
|---|---|---|
| `/continuous-code-auditor-status` | `scripts/commands/status.sh` | Read-only summary: paused/held state, lock state, last execution, findings counts. |
| `/continuous-code-auditor-start` | `scripts/commands/start.sh` | Clears the pause flag; best-effort resumes a systemd timer. |
| `/continuous-code-auditor-stop` | `scripts/commands/stop.sh` | Sets the pause flag so new scheduled runs skip immediately; doesn't interrupt one already in progress. |
| `/continuous-code-auditor-archive` | `scripts/commands/archive.sh` | Non-destructive: copies current `work/` into a timestamped `work/archives/` snapshot. Nothing is cleared. |
| `/continuous-code-auditor-backup-everything` | `scripts/commands/backup-everything.sh` | Full disaster-recovery tarball: the skill package + entire workspace, under `backups/`. |
| `/continuous-code-auditor-uninstall` | `scripts/commands/uninstall.sh` | Removes scheduling and skill-directory registration. Leaves audit data alone unless `--purge-data` is given. |
| `/continuous-code-auditor-reset` | `scripts/commands/reset.sh` | **Destructive** (to the current session, not to history): archives everything in `work/` and the wrapper logs into a timestamped `work/archives/<ts>/` snapshot, then reinitializes `work/` fresh. Requires `--confirm`. `work/archives/` itself is never touched beyond adding that one new snapshot. |

Every script can be run directly from a shell (`scripts/commands/status.sh`, etc.) regardless of which agent CLI you use — that always works. The tables below are about getting a real `/command-name` invocation in your CLI's own interface.

## How each CLI gets the `/name` invocation

| CLI | Mechanism | Files |
|---|---|---|
| **Claude Code** | Confirmed: custom slash commands, `.claude/commands/<name>.md` | `commands/claude-code/*.md` |
| **Gemini CLI** | Confirmed: custom commands, `.gemini/commands/<name>.toml` | `commands/gemini-cli/*.toml` |
| **Codex CLI** | Has a custom-prompts mechanism (`~/.codex/prompts/`), but it's marked deprecated in OpenAI's own docs in favor of skills, and the exact invocation syntax was inconsistent across sources at the time this was written (some describe direct `/name`, others a namespaced `/prompts:name`) — not built here. Use the universal fallback (below) instead. | none shipped |
| **Hermes Agent** | No confirmed custom-command mechanism found. | none shipped |
| **opencode** | No confirmed custom-command mechanism found. | none shipped |

`installer/install.sh` copies `commands/claude-code/*.md` into your chosen Claude Code commands directory and `commands/gemini-cli/*.toml` into your chosen Gemini CLI commands directory, at the same personal/project scope you chose for the skill itself.

## Universal fallback — works regardless of CLI

`SKILL.md`'s "Operational commands" section teaches the model itself to recognize these seven names — as a literal `/continuous-code-auditor-status`-style message, or as a natural-language equivalent ("what's the audit status", "pause the auditor", "reset the audit session") — and run the matching script, on *any* CLI, including ones with no native slash-command mechanism at all. This is what makes the command surface actually universal rather than dependent on which of the five adapters happens to support custom commands. Native registration (Claude Code, Gemini CLI) is a nicer experience — real tab-completion, a real `/` menu entry — not a requirement for the commands to work at all.

## Adding registration for a new CLI

If a CLI you're adding an adapter for (see `adapters/README.md`) turns out to have a confirmed custom-command mechanism, add a `commands/<cli>/` directory following the same pattern: one file per command, each instructing the model to locate the installed skill directory and run the corresponding `scripts/commands/<name>.sh` via its own shell tool, relaying output verbatim. Keep the `reset` command's confirmation-gating logic (see `commands/claude-code/continuous-code-auditor-reset.md` for the exact wording) — never let a command file pass `--confirm` on a first, unconfirmed invocation.
