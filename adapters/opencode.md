# Adapter: opencode

Runner: `scripts/runners/run_with_opencode.sh`. `AGENT_CLI="opencode"` in `config/auditor.conf`.

**Verified against:** a real `opencode run --help` output supplied directly by the operator during development of this skill (not secondhand docs). Re-verify against your own installed version before deploying — flags do change between releases, and this is exactly the CLI where an earlier, unverified draft of this skill got two flags wrong (`--context`, `--input-file` — neither exists).

## How the skill reaches the model

No confirmed native skill-auto-discovery directory was found for opencode at the time this was written. This runner instead attaches `SKILL.md` directly on every invocation with `-f/--file`, and phrases the message to instruct the model to follow it:

```
opencode run --model <MODEL_NAME> --format json --file <SKILL_DIR>/SKILL.md [--session <id>] "<message>"
```

If your opencode installation does support a native skill/agent directory convention (check `--agent` in your `--help` output and your opencode docs), that may be a more idiomatic alternative to file-attachment — this adapter doesn't assume it exists, since it wasn't confirmed.

## Session continuity

opencode keeps no state between separate `opencode run` invocations by default. This runner captures a session id from the first run's `--format json` output (`extract_session_id()` in the runner script) and passes it back with `-s/--session <id>` on subsequent runs.

**This is a best-effort extraction, not a confirmed one.** The exact JSON field name for the session id wasn't confirmed from available `--help` output alone. Before relying on this in production:

```bash
opencode run --format json "hello" | jq .
```

and check where the session id actually appears in your version's output; adjust the `jq` filter in `extract_session_id()` if it's not one of the paths already tried.

Deliberately **not** using `-c/--continue` ("continue the last session"): that's host-wide, and could pick up an unrelated session if anything else invokes `opencode` under the same account. Explicit `--session <id>` is more deterministic. If your `auditor` service account is truly dedicated to only this script, `--continue` would also work and is simpler — swap it in if you prefer, but the explicit approach is what's implemented by default.

Either way: this is a cost/context optimization only. If session-id extraction ever breaks, the audit stays correct (SKILL.md assumes no conversational memory regardless) — you just lose conversational continuity and pay for re-establishing context each run until it's fixed. The runner logs a note when extraction fails rather than failing the run.

## Failure detection

Two documented reliability issues shaped this adapter:

1. **Indefinite hangs** (e.g. an upstream rate-limit error that never returns) — bounded by the wall-clock `timeout` wrapper in the runner. Without it, a hung run would block the lock forever.
2. **False success** — some versions/conditions have been reported to exit `0` even on a real failure. This runner's `classify_failure()` treats a `0` exit status alongside non-empty stderr as a failure anyway, rather than trusting the exit code alone.

This second heuristic **depends on stderr staying quiet on a healthy run** — which is why this runner deliberately does **not** pass `--print-logs` (that flag sends opencode's own internal logs to stderr by design, which would make every healthy run look like a failure under this heuristic). This exact mistake was made and caught during development by actually running the script against a mocked CLI, not by reading it — see `adapters/README.md` point 7.

## Known-good invocation shape (confirmed via real `--help`)

```
opencode run [message..]
  -m, --model <provider/model>
  --format json|default
  -f, --file <path>          # attach SKILL.md
  -s, --session <id>         # explicit session continuation
  -c, --continue             # continue last session (host-wide — not used by default here)
  --print-logs               # NOT used — see "Failure detection" above
  --log-level DEBUG|INFO|WARN|ERROR
```

There is no `--context` flag and no `--input-file` flag on this CLI — both were invented in an earlier draft. If you find yourself wanting to pass extra out-of-band context, fold it into the message text instead (see `build_message()` in the runner).

## Operational commands (/status, /start, /stop, /archive, /backup-everything, /uninstall, /reset)

No confirmed native custom-command mechanism was found for opencode at the time this was written (see the `--command` flag in its `--help` output — that runs an arbitrary command, not a registered named one, so it doesn't map cleanly to this). `SKILL.md`'s "Operational commands" section teaches the model to recognize a literal `/continuous-code-auditor-<name>` message (or the natural-language equivalent) and run the matching `scripts/commands/<name>.sh` itself, which works regardless. You can also just run any `scripts/commands/<name>.sh` directly from a shell at any time.
