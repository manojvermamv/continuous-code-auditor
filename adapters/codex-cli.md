# Adapter: Codex CLI

Runner: `scripts/runners/run_with_codex-cli.sh`. `AGENT_CLI="codex-cli"` in `config/auditor.conf`.

**Verified against:** OpenAI's official Codex CLI documentation (`developers.openai.com/codex`) and community references at the time this was written. This is the best-documented adapter of the five in terms of confirmed JSON event schema — see "Session continuity" and "Failure detection" below, both grounded in real documented behavior rather than best-effort guesses.

## How the skill reaches the model

Codex CLI supports the same `SKILL.md` convention. Skills are discovered from:

- `~/.codex/skills/continuous-code-auditor/` — personal
- `.codex/skills/continuous-code-auditor/` (inside `$PROJECT`) — project-scoped

This runner does not attach `SKILL.md` as a file — same activation-by-description caveat as the Claude Code and Gemini CLI adapters: keep `build_message()` aligned with the skill's description, and confirm activation manually once before trusting the unattended loop.

## Non-interactive invocation

```
codex exec --json --full-auto --sandbox workspace-write --skip-git-repo-check "<message>"
codex exec resume <session-id> --json --full-auto --sandbox workspace-write --skip-git-repo-check "<message>"
```

- `codex exec`: the documented headless mode — runs one session to completion without interaction, emits JSONL events, exits when done.
- `--sandbox workspace-write`: **required** unless you want a read-only run. Codex CLI's default sandbox is read-only, which would block every write this audit workflow needs (`work/`, `archives/`, and the project root on a source refresh). `workspace-write` is the minimum permissive setting that works — do not widen this to `danger-full-access` without a specific reason; that removes all sandboxing.
- `--full-auto`: the CI/CD auto-approval mode, needed because headless `exec` mode fails immediately on any approval request rather than hanging (a real, useful property: an unapproved action fails loudly instead of blocking forever — see "Failure detection" below for how this shows up).
- `--skip-git-repo-check`: `codex exec` requires a git repository by default; this flag disables that check. **Remove it if `$PROJECT` is a real git repository and you want that safety check active** — it's included here defensively for the common case of a live trading-system deployment that may not be one.

## Session continuity — the one adapter with a confirmed extraction path

`codex exec resume <SESSION_ID>` continues a previous session; `codex exec resume --last` (not used by this runner, for consistency with the other adapters' explicit-id approach) continues the most recent one. The session id is available directly in the JSONL stream's `thread.started` event:

```bash
jq -r 'select(.type == "thread.started") | .id'
```

This is documented behavior (confirmed via OpenAI's own CLI reference and multiple independent community references describing the exact same field), not a best-effort guess like the other adapters' session-id extraction — it's implemented directly in `extract_session_id()` with only a light defensive fallback.

## Failure detection — a real event, not a heuristic

Codex CLI's docs are explicit: **"Progress streams to stderr; the final agent message prints to stdout."** Non-empty stderr is therefore *normal* on a completely healthy run — the opencode adapter's "non-empty stderr means failure" heuristic would misfire constantly here and must not be reused.

Instead, the JSONL event stream includes a documented `turn.failed` event type ("when a turn fails; includes error details"). This adapter's `classify_failure()` checks for that event directly:

```bash
jq -e 'select(.type == "turn.failed")' "$RUN_OUTPUT"
```

and forces the run to be treated as a failure if found, regardless of the process's own exit status. This is the same spirit as the opencode adapter's defense-in-depth (don't trust the exit code alone) grounded in an actual documented signal instead of a heuristic.

## Operational commands (/status, /start, /stop, /archive, /backup-everything, /uninstall, /reset)

No native command files are shipped for Codex CLI: it has a custom-prompts mechanism (`~/.codex/prompts/`), but OpenAI's own docs mark it deprecated in favor of skills, and the exact invocation syntax was inconsistent across sources when this was written. Instead, `SKILL.md`'s "Operational commands" section teaches the model to recognize a literal `/continuous-code-auditor-<name>` message (or the natural-language equivalent) and run the matching `scripts/commands/<name>.sh` itself — this works today without depending on the deprecated mechanism. You can also just run any `scripts/commands/<name>.sh` directly from a shell at any time.
