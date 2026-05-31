---
name: ralph-runtime
description: "Use when working on Ralph framework runtime behavior, sprint/story workflow, verification semantics, recovery helpers, or transient vs durable state. Triggers on: ralph loop, sprint workflow, story run, story execution, verification flow, recovery helper, cleanup, active sprint, workflow lock, artifact rules."
---

# Ralph Runtime

Use this skill for Ralph framework work that depends on execution-flow details rather than just the broad operating model.

## Use This Skill For

- `ralph.sh`, `ralph-story-run.sh`, `ralph-sprint.sh`, `ralph-story.sh`, `ralph-verify.sh`, or `ralph-sprint-commit.sh`
- Sprint activation, story execution order, closeout, and recovery behavior
- Durable vs transient artifact questions
- Verification, fallow, targeted remediation, and runtime-state handling

## Loading Discipline

- Do not read every reference file by default.
- Start from the specific script or behavior in the current task.
- Read only the matching reference below.

## References

- Sprint/story execution flow: [references/flow.md](references/flow.md)
- Verification and artifact/state rules: [references/verification-and-state.md](references/verification-and-state.md)
- Recovery helpers and maintainer escalations: [references/recovery.md](references/recovery.md)

## Escalate To Maintainer Notes Only When Needed

Open [`docs/maintainer-notes.md`](../../docs/maintainer-notes.md) only for edge cases, migration behavior, roadmap policy, or maintainer-level framework questions that the references above do not cover.
