# Ralph Agent Instructions

## Overview

Ralph is an autonomous Codex loop that executes sprint stories as focused story-level Codex cycles. Each story gets one primary `codex exec` context; acceptance checks are validated by shell, not AI.

Keep this file focused on the broad operating model. Deeper framework notes, edge cases, and maintainer guidance live in [`docs/maintainer-notes.md`](docs/maintainer-notes.md).

## Context Discipline

- Start from the task at hand and discover only the context needed to complete it.
- Do not preload broad framework docs, sprint artifacts, or story files unless the current task depends on them.
- Open `docs/maintainer-notes.md` only for maintainer-level questions, edge cases, migration work, or when this file does not answer the question.
- Open `.specify/` artifacts, `story.json`, `stories.json`, or `scripts/ralph/execution-baseline.md` only when working on a specific story flow, verification path, or execution behavior that requires them.
- Prefer targeted discovery (`rg`, direct file reads, command help, or the relevant script) over loading multiple reference files up front.
- Prefer deferred-load skills for deeper workflow detail when available.

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

## Deferred Skills

When installed, prefer these skills over loading broad reference context into every task:

- `ralph-runtime` — detailed sprint/story flow, verification, runtime state, and recovery helpers
- `story-specify` — convert `.specify/` artifacts into `story.json`
- `story-generate` — generate `story.json` when no `.specify/` artifacts exist
- `fallow` — code-quality gate behavior and manual fallow workflows
- `prd` and `ralph` — PRD creation and PRD-to-`prd.json` conversion

Use the skill only when the current task matches it; otherwise stay with targeted local discovery.

## Broad Rules

- Each story runs in one primary Codex session with a deterministic execution bundle plus minimal focused repo context.
- Acceptance checks (`checks[]`) are binary shell expressions — exit 0 = pass, non-zero = fail.
- Durable planning artifacts belong in git; transient execution state does not.
- SpecKit artifacts (`.specify/`) are durable and should be committed.
- `scripts/ralph/ralph-sprint-test.sh` is only needed when a repo opts into explicit full-regression sprint closeout.
- `scripts/ralph/ralph-cleanup.sh --force` removes workflow locks and transient state.

## More Detail

For maintainer-level notes on roadmap policy, SpecKit integration, scope enforcement, migration behavior, health validation, smoke harness behavior, and documentation guidance, see [`docs/maintainer-notes.md`](docs/maintainer-notes.md).
