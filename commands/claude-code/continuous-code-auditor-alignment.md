---
description: Show the project's alignment trajectory — baseline checkpoint to latest — with drift indicators measured against the project charter.
allowed-tools: Bash
---

Locate the installed continuous-code-auditor skill directory — check `.claude/skills/continuous-code-auditor/` in this project first, then `~/.claude/skills/continuous-code-auditor/` — then run, via Bash:

```
<that-directory>/scripts/commands/alignment.sh
```

Show its raw output verbatim first — it is a deterministic measurement, not something to reinterpret.

Then, if `config/charter.md` exists, read it and add a judged assessment per the "Alignment review" section of SKILL.md: do the open findings concentrate on what the charter says must never break, or on things it lists as acceptable trade-offs? Has the project moved in the direction the charter states?

**Never edit the charter.** If you think the charter itself is stale, say so as a recommendation to the human, with reasons. A model that can revise its own alignment target cannot measure its own drift.
