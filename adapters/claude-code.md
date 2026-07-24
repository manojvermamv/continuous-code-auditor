# Adapter: Claude Code

Runner: `scripts/runners/run_with_claude-code.sh`. `AGENT_CLI="claude-code"` in `config/auditor.conf`.

**Verified against:** Anthropic's official Claude Code documentation (`docs.claude.com`/`code.claude.com`) at the time this was written. Claude Code updates fairly often — re-check `claude --help` and the docs before deploying, especially around permission/tool flags.

## How the skill reaches the model

Claude Code has a native Agent Skills mechanism — this is in fact where the `SKILL.md` format this whole project uses originates. Skills are discovered from:

- `~/.claude/skills/continuous-code-auditor/` — personal, available in every project
- `.claude/skills/continuous-code-auditor/` (inside `$PROJECT`) — project-scoped, travels with the repo

`installer/install.sh` copies (or symlinks) this skill folder into whichever of those you choose. **This runner does not attach `SKILL.md` as a file.** It relies on Claude Code's own activation logic: at the start of a session Claude sees every installed skill's `name` + `description`, and loads the full `SKILL.md` body when it matches the current request. This is why `build_message()` in the runner explicitly says "Continue the continuous-code-auditor audit" — that phrasing needs to keep matching the skill's `description` field for auto-activation to keep working. If you edit the description in `SKILL.md`, sanity-check that activation still works (run once interactively and confirm Claude picks up the skill) before trusting it in the unattended loop.

`agent_specific_preflight()` in the runner checks that the skill is actually present in one of the two directories before running — if you see preflight failures here, the install step didn't complete.

## Non-interactive invocation

```
claude --print --model <MODEL_NAME> --output-format json \
  --permission-mode acceptEdits \
  --allowedTools "<scope>" \
  --max-turns <N> --max-budget-usd <amount> \
  [--resume <session-id>] \
  "<message>"
```

- `--print` (`-p`): the documented headless entry point — runs one turn, prints the result, exits.
- `--output-format json`: structured output, needed for reliable session-id extraction.
- **Permission mode and allowed tools are not optional in headless mode.** The interactive REPL prompts for tool approvals; `--print` cannot prompt, so an unattended run needs its permissions decided up front or it will simply fail on the first tool call requiring approval. The runner ships a starting scope:
  ```
  CLAUDE_ALLOWED_TOOLS="Read,Write,Bash(python3:*),Bash(diff:*),Bash(sha256sum:*),Bash(wc:*),Bash(curl:*)"
  CLAUDE_PERMISSION_MODE="acceptEdits"
  ```
  **Review and narrow this for your environment before deploying.** It's a starting point, not a recommendation to run unexamined — add or remove `Bash(...)` entries to match exactly what this audit workflow needs on your system (e.g. add `git` if source refresh uses it, drop `curl` if it doesn't fetch anything remotely). This is defense-in-depth alongside — not a replacement for — the Capability Boundary in `SKILL.md`, which already forbids source modification and any production/trading action regardless of what the tool scope technically permits.
- `--max-turns` / `--max-budget-usd`: hard caps on agentic turns and spend for this invocation — a second, CLI-native safety net on top of this skill's own circuit breaker. Tune the defaults (`40` turns, `$2.00`) to your actual workload.

## Session continuity

Two mechanisms exist: `-r/--resume <session-id>` (explicit) and `-c/--continue` (continue the most recent session **in the current working directory** — notably safer-scoped here than a fully global "last session," since this runner already `cd`s into `$PROJECT` first). This adapter uses the explicit form for determinism and consistency with the other adapters, capturing the session id from JSON output in `extract_session_id()`.

**The exact JSON field name for the session id was not confirmed** from the documentation available when this was written. Verify once:

```bash
claude -p "hello" --output-format json | jq .
```

and adjust the `jq` filter in `extract_session_id()` if the id isn't at one of the paths already tried. As with every adapter, this is a cost/context optimization only — a broken extraction just means a fresh session next run, not an incorrect audit.

## Failure detection

No documented "false success" or "stderr is always noisy" quirk was found for this CLI at the time of writing — the runner trusts the exit code (the library's default `classify_failure()`, i.e. no override). Claude Code's own docs note there's no single published global exit-code table, but the general pattern is non-zero on error (hitting `--max-turns`, a stdin overflow, etc.). If you find a specific documented quirk for your version, add a `classify_failure()` override the same way the opencode and Codex CLI adapters do.

## Cost tracking

This is currently the only adapter that implements `extract_cost_usd` — Claude Code's `--output-format json` envelope is documented to include a `total_cost_usd` field. Set `CUMULATIVE_BUDGET_USD` in `config/auditor.conf` to cap lifetime spend across the whole deployment (see `references/workspace-and-execution.md` "Cumulative cost ceiling"); leave it unset to disable tracking. If your version's JSON shape doesn't include this field, the extraction just returns nothing and cost simply isn't tracked — same graceful degradation as any adapter that hasn't implemented the hook at all.

## Operational commands (/status, /start, /stop, /archive, /backup-everything, /uninstall, /reset)

Native support: `commands/claude-code/*.md` installs as real `.claude/commands/continuous-code-auditor-<name>.md` slash commands (installer/install.sh does this at the same scope you chose for the skill). Each just tells Claude to locate the installed skill and run the matching `scripts/commands/<name>.sh`, relaying output verbatim — see `commands/README.md` for the full table and the `reset` confirmation-gating rule.
