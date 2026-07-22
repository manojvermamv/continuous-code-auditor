# Adapters — the contract for supporting an agent CLI

This skill's reliability engine (`scripts/lib/reliability.sh`) is completely CLI-agnostic. Everything that differs between agent CLIs — the actual invocation, how to attach or auto-discover the skill, session continuity, and how to detect a real failure — is isolated in one runner script per CLI under `scripts/runners/`, documented here in one `adapters/<cli>.md` file per CLI. This is what makes "support more agent CLIs later" a matter of adding a file, not rewriting the skill.

Currently supported, each verified against real `--help` output or official documentation at the time it was written (see the individual files for sources and version caveats):

| CLI | Runner | Adapter doc |
|---|---|---|
| opencode | `scripts/runners/run_with_opencode.sh` | [opencode.md](opencode.md) |
| Claude Code | `scripts/runners/run_with_claude-code.sh` | [claude-code.md](claude-code.md) |
| Gemini CLI | `scripts/runners/run_with_gemini-cli.sh` | [gemini-cli.md](gemini-cli.md) |
| Codex CLI | `scripts/runners/run_with_codex-cli.sh` | [codex-cli.md](codex-cli.md) |
| Hermes Agent | `scripts/runners/run_with_hermes.sh` | [hermes.md](hermes.md) |

## Adding a new adapter

1. **Verify the CLI's real flags first.** Run `<cli> --help` (and skim its official docs) yourself. Do not assume a flag exists because a similar CLI has it — the opencode adapter exists in its current form specifically because an earlier draft assumed `--context` and `--input-file` flags that turned out not to exist.
2. **Find out how it discovers skills.** Most modern agent CLIs auto-discover `SKILL.md` from a personal directory (`~/.<cli>/skills/<name>/`) and/or a project directory (`.<cli>/skills/<name>/`), and activate a skill by matching the request against its `description`. If the CLI has no such mechanism, fall back to attaching `SKILL.md` as a file per invocation (see the opencode adapter) or check for an explicit "load this file as context" flag.
3. **Work out session continuity, or decide it doesn't have one.** Some CLIs need you to capture and pass back an explicit session/thread id; some track their own history per project directory with a "resume latest" selector; some don't document it well enough to rely on. Whatever you find, remember: this is a cost/context optimization only. SKILL.md's "no conversational memory assumed" design means audit correctness never depends on session continuity working — a broken or absent session mechanism should degrade to "slightly more expensive," never to "wrong."
4. **Work out real failure detection — don't reuse another adapter's heuristic.** Trusting the exit code alone is the default (`classify_failure()` as a no-op). Only override it if you have a *documented* reason to distrust the exit code for this specific CLI (a known false-success bug, an explicit `turn.failed`-style event you can check instead, etc.) — and if you do override it, make sure you're not flagging *normal* behavior as a failure (e.g. a CLI that streams normal progress to stderr).
5. **Write `scripts/runners/run_with_<cli>.sh`**, following the shape of an existing runner: set config defaults, `source scripts/lib/reliability.sh`, define `invoke_agent()` (required), and any of `extract_session_id()`, `classify_failure()`, `agent_specific_preflight()` you need (all default to safe no-ops if you don't define them). End with `reliability_main "$@"`.
6. **Write `adapters/<cli>.md`** covering: the invocation this runner builds and why, where the skill needs to be installed for this CLI, how session continuity works (or why it doesn't), any documented reliability quirks, and — explicitly — anything you couldn't verify and are flagging for the operator to check themselves before relying on it in production.
7. **Test it before trusting it, the same way this repo's own adapters were tested**: mock the CLI binary (a tiny script that logs the args it received and returns a controlled exit code / stdout / stderr), then run the new runner script directly against the mock and confirm: a clean success reports exit `0`; a simulated failure reports the right structured code and gets recorded for the next run's prior-failure note; three consecutive simulated failures trip the circuit breaker; a held lock is detected and reported with its metadata. Static review is not enough — the opencode runner's original `--print-logs` bug (silently defeating its own false-success check) was only caught by actually running it against a mock, not by reading it.
8. **Add a row to the table above** and to `config/auditor.conf.example`'s `AGENT_CLI` comment.

## What `scripts/lib/reliability.sh` gives every adapter for free

Locking (with metadata) and the circuit breaker; structured exit codes and the `AUDITOR_EXIT_REASON` sentinel bridge (CLI-agnostic — it's just text in the model's own reply, not something any particular CLI needs to support specially); prior-failure capture and carry-forward; the cleanup trap for temp files. A runner should never need to reimplement any of this — if you find yourself doing so, the contract above is probably missing something and worth raising rather than working around.

## Contributing an adapter upstream

If you build a new adapter following the contract above, consider opening a pull request against [github.com/manojvermamv/continuous-code-auditor](https://github.com/manojvermamv/continuous-code-auditor) so other users get it too.
