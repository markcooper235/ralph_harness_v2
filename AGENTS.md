# Ralph Agent Instructions

## Overview

Ralph is an autonomous Codex loop that executes sprint stories as focused story-level Codex cycles. Each story gets one primary `codex exec` context; acceptance checks are validated by shell, not AI.

Keep this file focused on the broad operating model. Deeper framework notes, edge cases, and maintainer guidance live in [`docs/maintainer-notes.md`](docs/maintainer-notes.md).

## Architecture: Story-Task Model

Ralph's primary execution unit is the **story**. Each story contains ordered **tasks** — narrow, binary-checkable pieces of work that Codex completes inside the same story cycle. Stories are sprint-level containers; sprints are the deployment unit.

```
roadmap → stories.json (per sprint)
       → .specify/{spec.md, plan.md, tasks.md} (per story)
       → story.json (task container with checks[])
       → story branch execution (one primary Codex session per story)
       → merge to sprint branch
       → sprint commit → main
```

## Core Commands

```bash
# Install Ralph into a target project
./install.sh --project /path/to/project [--install-speckit]

# Optional global Codex assets
./install.sh --install-skills
./install.sh --install-prompts

# Validate a Ralph-enabled repo
./scripts/ralph/doctor.sh

# Roadmap / sprint planning
./scripts/ralph/ralph-roadmap.sh --vision "Roadmap from baseline to target state"
./scripts/ralph/ralph-sprint.sh status
./scripts/ralph/ralph-sprint.sh next [--activate]

# Story preparation
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-1   # specify + generate + health + promote
./scripts/ralph/ralph-story.sh specify S-001                   # SpecKit analysis only
./scripts/ralph/ralph-story.sh generate S-001                  # generate story.json from .specify/ artifacts
./scripts/ralph/ralph-story.sh health [S-001]                  # validate story task containers

# Loop execution
./scripts/ralph/ralph.sh [--max-stories N] [--max-retries N] [--continue-on-failure] [--skip-fallow] [--dry-run]

# Status
./scripts/ralph/ralph-status.sh

# Verification
./scripts/ralph/ralph-verify.sh [--targeted|--task|--story-scope|--sprint|--full-regression]

# Closeout
./scripts/ralph/ralph-sprint-commit.sh [--target BRANCH] [--dry-run] [--keep] [--skip-regression] [--full-regression]

# Advanced / recovery helpers
./scripts/ralph/ralph-story.sh add --title "..." --goal "..." --prompt-context "..."
./scripts/ralph/ralph-story.sh set-status S-001 planned
./scripts/ralph/ralph-story.sh import-prd scripts/ralph/prd.json
./scripts/ralph/ralph-sprint-migrate.sh [--sprint NAME]
./scripts/ralph/ralph-cleanup.sh --force
```

## Recommended Flow

Sprint:

1. Run `./scripts/ralph/doctor.sh`
2. Plan backlog with `./scripts/ralph/ralph-roadmap.sh --vision "..."`
3. Check readiness with `./scripts/ralph/ralph-sprint.sh status`
4. Run `./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-1` to generate task containers
5. Run `./scripts/ralph/ralph-sprint.sh mark-ready sprint-1`
6. Run `./scripts/ralph/ralph-sprint.sh use sprint-1`
7. Run `./scripts/ralph/ralph.sh` — stories execute automatically
8. Run `./scripts/ralph/ralph-sprint-commit.sh`

Repeat for the next sprint:

```bash
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-2
./scripts/ralph/ralph-sprint.sh mark-ready sprint-2
./scripts/ralph/ralph-sprint.sh next --activate
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

Importing an existing `prd.json`:

```bash
./scripts/ralph/ralph-story.sh import-prd scripts/ralph/prd.json
./scripts/ralph/ralph-story.sh prepare-all
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

## Key Files

- `scripts/ralph/ralph-roadmap.sh` — Plan or refine roadmap-driven sprint backlogs
- `scripts/ralph/ralph-sprint.sh` — Manage sprint containers and sprint readiness
- `scripts/ralph/ralph-story.sh` — Manage stories: specify, generate, health, start-next, add, import
- `scripts/ralph/ralph-story-run.sh` — Execute the active story in one primary Codex cycle with shell verification
- `scripts/ralph/ralph.sh` — Sprint execution loop: start-next → ralph-story-run.sh → repeat
- `scripts/ralph/ralph-status.sh` — Show sprint, story, branch, and loop state
- `scripts/ralph/ralph-verify.sh` — Run scoped task, story, sprint, or explicit full-regression verification
- `scripts/ralph/ralph-fallow.sh` — Code-quality gate (dead code, duplication, lint)
- `scripts/ralph/ralph-sprint-commit.sh` — Archive and merge the completed sprint
- `scripts/ralph/ralph-sprint-migrate.sh` — Convert sprint from legacy epic/PRD format
- `scripts/ralph/ralph-cleanup.sh` — Reset local Ralph runtime state without archiving
- `scripts/ralph/ralph-sprint-test.sh` — Optional project-specific full-regression gate for explicit sprint closeout
- `scripts/ralph/prompt.md` — Base loop prompt
- `scripts/ralph/prompt.local.md` — Repo-local prompt extensions (survives framework reinstalls)
- `scripts/ralph/story.json` — Task container: title, description, spec, tasks[], checks[], depends_on
- `scripts/ralph/stories.json` — Sprint story backlog with status and story_path pointers

## Broad Rules

- Each story runs in one primary Codex session with a deterministic execution bundle plus minimal focused repo context.
- Acceptance checks (`checks[]`) are binary shell expressions — exit 0 = pass, non-zero = fail.
- Durable planning artifacts belong in git; transient execution state does not.
- SpecKit artifacts (`.specify/`) are durable and should be committed.
- `scripts/ralph/ralph-sprint-test.sh` is only needed when a repo opts into explicit full-regression sprint closeout.
- `scripts/ralph/ralph-cleanup.sh --force` removes workflow locks and transient state.

## Artifact Rules

Durable (committed):

- `stories.json` — sprint story backlog
- `story.json` — task container with acceptance checks
- `.specify/` — SpecKit artifacts (spec.md, plan.md, tasks.md)
- `roadmap-source.md`, `roadmap.json`, `roadmap.md`
- git history
- archived sprint artifacts under `tasks/archive/sprints/`

Transient (untracked):

- `scripts/ralph/.active-sprint`
- `scripts/ralph/.workflow-lock`
- `scripts/ralph/prd.json`
- `scripts/ralph/progress.txt`
- `scripts/ralph/.active-prd`
- per-story `.task-log-*.txt`, `.fallow-report.json`, `.fallow-autofix.txt`

## Current Framework Behaviors

- `ralph.sh` loops: `start-next → ralph-story-run.sh → repeat` until no eligible stories remain.
- `ralph-story-run.sh` builds a deterministic execution bundle under `scripts/ralph/runtime/`, runs one primary Codex cycle per story, then evaluates `checks[]` via shell. Failed checks may trigger targeted remediation up to `--max-retries`.
- After all tasks pass, `ralph-story-run.sh` writes compact handoff state, then merges the story branch to the sprint branch and deletes it.
- `ralph-story.sh start-next` activates the next eligible story (status = ready or planned, all `depends_on` done).
- Story health checks in `ralph-story.sh health` validate task count, check syntax, context completeness, dependency integrity, and duplicate detection.
- `ralph-story.sh prep-status [--details] [--story ID]` inspects the latest prep journal for a sprint without opening raw JSON.
- `ralph-sprint.sh next` ignores sprints whose remaining stories are all `blocked`.
- `prompt.local.md` is the right place for repo-specific behavior; marker-based injection is supported.
- `ralph-sprint-commit.sh` deletes the merged sprint branch by default; pass `--keep` to retain it.

## When To Use Advanced Helpers

- Use `ralph-story.sh add` when you need to add a story non-interactively (e.g., from automation).
- Use `ralph-story.sh set-status` to reset a stuck story back to `planned` after debugging.
- Use `ralph-sprint-migrate.sh` when migrating a sprint from the old epic/PRD format.
- Use `ralph-cleanup.sh --force` when a stale workflow lock blocks execution.

## More Detail

For maintainer-level notes on roadmap policy, SpecKit integration, scope enforcement, health validation, smoke harness behavior, and documentation guidance, see [`docs/maintainer-notes.md`](docs/maintainer-notes.md).
