# Adapter: Gemini CLI

Runner: `scripts/runners/run_with_gemini-cli.sh`. `AGENT_CLI="gemini-cli"` in `config/auditor.conf`.

**Verified against:** Google's official Gemini CLI documentation (`geminicli.com`/`github.com/google-gemini/gemini-cli`) at the time this was written. Re-check `gemini --help` before deploying — some secondary sources described a `--non-interactive` flag where the official docs show `-p/--prompt`; these may be version-dependent or one may be older/deprecated. Confirm which applies to your installed version.

## How the skill reaches the model

Gemini CLI has its own native Agent Skills mechanism, explicitly built on the same open standard this project uses. Skills are discovered from (in order of precedence, lowest to highest): built-in skills, extension skills, then:

- `~/.gemini/skills/continuous-code-auditor/` (or the alias `~/.agents/skills/...`) — personal, all projects
- `.gemini/skills/continuous-code-auditor/` (inside `$PROJECT`, or the alias `.agents/skills/...`) — project-scoped

**Project-scoped skills require the workspace to be marked "trusted"** (run `/trust` once, interactively, before relying on the unattended loop) — an untrusted workspace silently won't load `.gemini/skills/` content. This is the single most likely reason a project-scoped install "doesn't work" for this CLI specifically; the personal (`~/.gemini/skills/`) path isn't affected by this.

This runner does not attach `SKILL.md` as a file — it relies on Gemini's activation matching the message against the skill's `description`, same caveat as the Claude Code adapter: keep `build_message()`'s phrasing aligned with the skill's description, and verify activation manually once before trusting the unattended loop.

## Non-interactive invocation

```
gemini -p "<message>" -m <MODEL_NAME> -o json --approval-mode <mode> [--resume latest]
```

- `-p/--prompt`: headless entry point, single turn, exits. (See the version caveat above re: `--non-interactive`.)
- `-o/--output-format json`: structured output.
- `--approval-mode`: **required** for a non-interactive run to complete without hanging on a tool-approval prompt. Documented values: `default`, `auto_edit`, `yolo`, `plan`. This adapter defaults to `auto_edit`; `yolo` auto-approves everything including arbitrary shell commands and should only be used if you trust the sandboxing around this process (see the systemd hardening in `references/workspace-and-execution.md`) — review this setting for your environment rather than trusting the default blindly.

## Session continuity — genuinely different from the other adapters

Gemini CLI tracks session history itself, per project directory (`~/.gemini/tmp/<project_hash>/chats/`), and exposes a `--resume latest` selector. **This adapter does not capture or store an explicit session id at all** — `extract_session_id()` is a deliberate no-op. Instead, the runner tracks a simple "has this ever run before" marker file and passes `--resume latest` on every run except the first (to sidestep an undocumented edge case around resuming when no session exists yet).

If you'd rather have explicit, auditable session-id tracking consistent with the other adapters, Gemini CLI does support `--list-sessions` and resuming by index or explicit id — that's a viable alternative to `latest` if you want to adapt this runner, just note the extra bookkeeping it would require.

## Failure detection

No documented "false success" or "stderr is always noisy" quirk was found for this CLI at the time of writing — the runner trusts the exit code (the library's default). If you find a specific quirk for your version, add a `classify_failure()` override the same way the opencode and Codex CLI adapters do.

## Operational commands (/status, /start, /stop, /archive, /backup-everything, /uninstall, /reset)

Native support: `commands/gemini-cli/*.toml` installs as real `.gemini/commands/continuous-code-auditor-<name>.toml` custom commands (installer/install.sh does this at the same scope you chose for the skill). Each tells Gemini to locate the installed skill and run the matching `scripts/commands/<name>.sh`, relaying output verbatim — see `commands/README.md` for the full table and the `reset` confirmation-gating rule.
