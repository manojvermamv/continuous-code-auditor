---
description: DESTRUCTIVE — archive and clear the entire current audit session (findings, state, logs) into work/archives/, then start fresh. Requires explicit confirmation.
allowed-tools: Bash
---

This is a destructive operation. Locate the installed continuous-code-auditor skill directory — check `.claude/skills/continuous-code-auditor/` in this project first, then `~/.claude/skills/continuous-code-auditor/`.

If the user has **not already explicitly confirmed** they want to reset in this conversation (a plain "/continuous-code-auditor-reset" invocation with no prior confirmation does not count as confirmation):

1. Run `<that-directory>/scripts/commands/reset.sh` **without** `--confirm`.
2. Relay its warning output to the user verbatim and stop — do not proceed further this turn.

If the user **has** already explicitly confirmed (e.g. `$ARGUMENTS` contains something like "confirm" or "yes", or they said so earlier in this conversation):

1. Run `<that-directory>/scripts/commands/reset.sh --confirm`.
2. Show the output verbatim.

Never pass `--confirm` on a first, unconfirmed invocation. This command archives everything into `work/archives/<timestamp>/` rather than deleting it outright, but it still ends the current session's active findings and state — treat the confirmation requirement as real, not a formality to route around.
