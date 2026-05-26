---
description: Run the Ralph fallow code-quality gate on the active story (dead code, duplicates, lint, complexity)
argument-hint: [--story PATH] [--dry-run] [--no-autofix] [--quiet]
---

Run the fallow code-quality gate for the current story.

## Steps
1. Validate: `scripts/ralph/ralph-fallow.sh` exists and is executable.
2. Run:
   - `./scripts/ralph/ralph-fallow.sh {{args}}`
3. Report:
   - Issues found (by category: dead code, duplicates, complexity, lint).
   - Whether auto-fix was applied.
   - Final verdict: PASS or FAIL with remaining issue count.

## Guardrails
- Do not mark a story done if fallow exits non-zero.
- Use `--dry-run` to inspect issues without blocking the story.
- Use `--no-autofix` to see issues without attempting to fix them.
- Scope is limited to the story's declared file scope — fallow does not scan the whole codebase at story level.
- If `ralph-fallow.sh` is missing, re-run `install.sh` to deploy it.
- On precondition failure, explain and stop.
