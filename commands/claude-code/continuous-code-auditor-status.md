---
description: Show the current status of the continuous-code-auditor (paused/held state, lock, last run, findings summary).
allowed-tools: Bash
---

Locate the installed continuous-code-auditor skill directory — check `.claude/skills/continuous-code-auditor/` in this project first, then `~/.claude/skills/continuous-code-auditor/` — then run, via Bash:

```
<that-directory>/scripts/commands/status.sh $ARGUMENTS
```

and show me its raw output verbatim. Do not interpret, summarize, paraphrase, or modify what the script prints — this is a deterministic operational command, not something for you to reason about.
