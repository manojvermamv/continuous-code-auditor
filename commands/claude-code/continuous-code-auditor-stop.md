---
description: Pause scheduled continuous-code-auditor execution. Does not interrupt a run already in progress.
allowed-tools: Bash
---

Locate the installed continuous-code-auditor skill directory — check `.claude/skills/continuous-code-auditor/` in this project first, then `~/.claude/skills/continuous-code-auditor/` — then run, via Bash:

```
<that-directory>/scripts/commands/stop.sh $ARGUMENTS
```

and show me its raw output verbatim. Do not interpret, summarize, paraphrase, or modify what the script prints — this is a deterministic operational command, not something for you to reason about.
