---
description: Diagnose a broken or not-yet-working continuous-code-auditor installation — checks config, dependencies, skill install, paths, disk, run state, and scheduling, and reports exactly what to fix.
allowed-tools: Bash
---

Locate the installed continuous-code-auditor skill directory — check `.claude/skills/continuous-code-auditor/` in this project first, then `~/.claude/skills/continuous-code-auditor/` — then run, via Bash:

```
<that-directory>/scripts/commands/doctor.sh
```

and show me its raw output verbatim. Do not interpret, summarize, paraphrase, or modify what the script prints — this is a deterministic diagnostic, not something for you to reason about.

If it reports any `[FAIL]` items, you may afterwards offer to help fix them, but show the unmodified output first.
