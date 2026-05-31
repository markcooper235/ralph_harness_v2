# Verification And State

Verification rules:

- `checks[]` are binary shell expressions. Exit `0` means pass.
- Acceptance is validated by shell, not AI.
- `ralph-verify.sh` supports task, story-scope, sprint, and explicit full-regression verification.
- `ralph-fallow.sh` is the code-quality gate for dead code, duplication, and lint-like issues.
- `ralph-sprint-test.sh` is optional and used only when a repo opts into explicit full-regression sprint closeout.

Artifact rules:

Durable and committed:

- `stories.json`
- `story.json`
- `.specify/`
- `roadmap-source.md`, `roadmap.json`, `roadmap.md`
- archived sprint artifacts under `tasks/archive/sprints/`
- git history

Transient and untracked:

- `scripts/ralph/.active-sprint`
- `scripts/ralph/.workflow-lock`
- `scripts/ralph/prd.json`
- `scripts/ralph/progress.txt`
- `scripts/ralph/.active-prd`
- per-story `.task-log-*.txt`, `.fallow-report.json`, `.fallow-autofix.txt`

Useful status/verification entry points:

- `scripts/ralph/ralph-status.sh`
- `scripts/ralph/ralph-verify.sh`
- `scripts/ralph/ralph-fallow.sh`
- `scripts/ralph/ralph-sprint-commit.sh`
