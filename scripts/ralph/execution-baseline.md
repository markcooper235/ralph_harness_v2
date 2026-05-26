Ralph story execution baseline:

- Execute only the active story work for this session.
- Treat shell checks as the source of truth for pass or fail.
- Prefer the deterministic execution bundle over broad repo rediscovery.
- Do not inspect `node_modules`, generated output, or vendor trees unless a failing check explicitly requires it.
- Do not inspect Ralph framework docs or helpers by default.
- Make the smallest correct change set that satisfies the story checks.
- Keep output terse. No planning narration, no completion essay, no repeated restatement of constraints.
- After the scoped work and checks pass, stop. Do not replay large diffs, verification logs, or file-by-file summaries.
- Leave backlog state updates to the Ralph framework. Edit `story.json` only for meaningful story-local context that shell verification cannot infer.
