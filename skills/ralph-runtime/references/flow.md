# Sprint And Story Flow

Primary execution unit: the story.

Execution model:

```text
roadmap -> stories.json
        -> .specify/{spec.md, plan.md, tasks.md}
        -> story.json
        -> story branch execution
        -> merge to sprint branch
        -> sprint commit -> main
```

Core loop behavior:

- `ralph.sh` runs `start-next -> ralph-story-run.sh -> repeat` until no eligible stories remain.
- `ralph-story.sh start-next` activates the next eligible story whose dependencies are done.
- `ralph-story-run.sh` builds a deterministic execution bundle under `scripts/ralph/runtime/`, runs one primary Codex cycle, and then evaluates `checks[]` in shell.
- Failed checks can trigger targeted remediation up to `--max-retries`.
- After all tasks pass, the story branch is merged back to the sprint branch and deleted.
- `ralph-sprint.sh next` skips sprints whose remaining stories are all `blocked`.

Common command flow:

```bash
./scripts/ralph/doctor.sh
./scripts/ralph/ralph-roadmap.sh --vision "..."
./scripts/ralph/ralph-sprint.sh status
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-1
./scripts/ralph/ralph-sprint.sh mark-ready sprint-1
./scripts/ralph/ralph-sprint.sh use sprint-1
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

Key entry points:

- `scripts/ralph/ralph-roadmap.sh`
- `scripts/ralph/ralph-sprint.sh`
- `scripts/ralph/ralph-story.sh`
- `scripts/ralph/ralph-story-run.sh`
- `scripts/ralph/ralph.sh`
- `scripts/ralph/ralph-status.sh`
