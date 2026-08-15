# Adapter: Hermes Agent

Runner: `scripts/runners/run_with_hermes.sh`. `AGENT_CLI="hermes"` in `config/auditor.conf`.

**Verified against:** Nous Research's official Hermes Agent documentation (`hermes-agent.nousresearch.com`, `github.com/NousResearch/hermes-agent`) at the time this was written. This adapter has one genuine open question — see "Failure detection and output parsing" below — flagged rather than guessed at.

## How the skill reaches the model

Hermes discovers skills from `~/.hermes/skills/` (optionally organized into category subdirectories, e.g. `~/.hermes/skills/devops/continuous-code-auditor/`) and the shared external directory `~/.agents/skills/`.

**Unlike the Claude Code, Gemini CLI, and Codex CLI adapters, this one does not rely purely on description-matching.** Hermes supports explicitly preloading a named skill with `-s/--skills`, which this runner uses:

```
hermes chat -s continuous-code-auditor --model <MODEL_NAME> -q "<message>"
```

This is more deterministic than hoping the message text matches the skill's `description` closely enough to auto-activate — use it. `agent_specific_preflight()` in the runner checks that a `SKILL.md` matching this skill's name exists somewhere under `~/.hermes/skills/` or the project's `.agents/skills/` before running.

## Non-interactive invocation

```
hermes chat -s continuous-code-auditor --model <MODEL_NAME> [--resume <session-id>] -q "<message>"
```

`hermes chat -q "..."` is the documented single-query (non-interactive) mode.

## Session continuity

**Currently non-functional, and the capability matrix says so.** `invoke_agent` has a `--resume` code path, but `extract_session_id` is a deliberate no-op (no confirmed structured-output flag, below), so the session-id file is never written and `--resume` is never passed. The behavioral verification harness (`tests/verify_capabilities.sh`) caught this after it had sat undetected through several releases declared as working.

To enable it: confirm a structured-output flag on your installed version, implement `extract_session_id` against the confirmed schema, then update `session_continuity` to `explicit_id` in `adapters/capabilities.json` — the harness will verify the claim rather than take it on faith.

As with every adapter, this costs context re-establishment per run, never correctness: `SKILL.md` assumes no conversational memory regardless.

## Session continuity (original notes)

Two documented mechanisms: `hermes --continue` (`-c`, resume the most recent CLI session) and `hermes --resume <session_id>` (`-r`, resume a specific one). This adapter uses the explicit form, for consistency with the other adapters — though session-id **extraction is not implemented for this CLI**, see below.

## Failure detection and output parsing — the one open question in this skill

**No confirmed structured-output flag (a JSON mode equivalent to the other four CLIs' `--format json` / `--output-format json` / `-o json` / `--json`) was found for `hermes chat` in the documentation available when this adapter was written.** Rather than guess at a flag name and risk repeating the exact mistake this skill's opencode adapter made early on, this runner:

- Captures plain stdout/stderr rather than attempting to parse structured output.
- Leaves `extract_session_id()` as a deliberate no-op — there's nothing to reliably parse it out of yet.
- Leaves `classify_failure()` at the library default (trust the exit code) — no documented quirk to override with.

**Before relying on this adapter in production:**

```bash
hermes chat --help
```

and check for an output-format flag. If one exists, wire it into `invoke_agent()` in `scripts/runners/run_with_hermes.sh` (mirroring how the Codex CLI or opencode adapters use `--json`/`--format json`) and implement `extract_session_id()` properly against the confirmed schema. This adapter still works without it — the `AUDITOR_EXIT_REASON` sentinel detection (grep-based, works against plain text just as well as JSON) and the exit-code-based failure/circuit-breaker logic don't depend on structured output — you'd only be adding session-continuity as a cost optimization, consistent with every other adapter in this skill.

## Operational commands (/status, /start, /stop, /archive, /backup-everything, /uninstall, /reset)

No confirmed native custom-command mechanism was found for Hermes at the time this was written, so no command files are shipped for it. `SKILL.md`'s "Operational commands" section teaches the model to recognize a literal `/continuous-code-auditor-<name>` message (or the natural-language equivalent) and run the matching `scripts/commands/<name>.sh` itself, which works regardless. You can also just run any `scripts/commands/<name>.sh` directly from a shell at any time.
