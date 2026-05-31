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

## Command Discovery

- Use `./scripts/ralph/doctor.sh` as the first validation entry point in a Ralph-enabled repo.
- Use the `setup` skill for install/bootstrap workflows.
- Use the `ralph-runtime` skill for sprint/story execution flow, verification, runtime state, and recovery helpers.
- For exact flags or subcommands, prefer `--help` on the specific script you are about to use instead of loading broad command reference context.

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
