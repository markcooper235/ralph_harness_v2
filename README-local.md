# Ralph

Ralph is a Codex-native autonomous loop that executes sprint stories as sequences of focused, task-level Codex sessions.

This document is the installed reference for a Ralph-enabled project. For framework development notes, see the Ralph source repo.

## Table of Contents

- [Sprint Workflow](#sprint-workflow)
- [Multi-Sprint Workflow](#multi-sprint-workflow)
- [Story Format](#story-format)
- [Task Format](#task-format)
- [Command Reference](#command-reference)
- [Local Extensions](#local-extensions)

---

## Sprint Workflow

```bash
# 1. Validate environment
./scripts/ralph/doctor.sh

# 2. Plan a roadmap (creates sprints and stories.json)
./scripts/ralph/ralph-roadmap.sh --vision "Describe the target state"

# 3. Check sprint status
./scripts/ralph/ralph-sprint.sh status

# 4. Prepare story task containers (SpecKit analysis + generate + health)
./scripts/ralph/ralph-story.sh prepare-all

# 5. Execute the sprint
./scripts/ralph/ralph.sh

# 6. Close the sprint (merges sprint branch to main)
./scripts/ralph/ralph-sprint-commit.sh
```

What happens during execution:

- `ralph-story.sh prepare-all` runs SpecKit analysis for each story (`specify → plan → tasks`), generates `story.json` task containers, validates health, and promotes healthy stories to `ready`
- `ralph.sh` picks up the next eligible story, runs each task in a fresh Codex session via `ralph-task.sh`, evaluates binary `checks[]`, retries on failure, and merges each story branch back to the sprint branch when done
- `ralph-sprint-commit.sh` requires `ralph-sprint-test.sh` to pass, archives sprint artifacts, merges the sprint branch, and deletes it

---

## Multi-Sprint Workflow

A sprint must be closed before the next one is activated.

```bash
# Sprint 1 (after planning with ralph-roadmap.sh)
./scripts/ralph/ralph-story.sh prepare-all
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh          # closes sprint-1, merges to main

# Sprint 2
./scripts/ralph/ralph-sprint.sh use sprint-2    # activate sprint-2
./scripts/ralph/ralph-story.sh prepare-all      # prepare sprint-2 stories
./scripts/ralph/ralph.sh                        # execute sprint-2
./scripts/ralph/ralph-sprint-commit.sh          # closes sprint-2, merges to main
```

Or let `next --activate` select the next ready sprint automatically:

```bash
./scripts/ralph/ralph-sprint.sh next --activate
./scripts/ralph/ralph-story.sh prepare-all
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

---

## Story Format

Stories live in `scripts/ralph/sprints/<sprint-name>/stories.json`. Each entry is a backlog item; the full task container lives in `scripts/ralph/sprints/<sprint-name>/stories/<ID>/story.json`.

### stories.json entry

```json
{
  "id": "S-001",
  "title": "Add priority field to tasks",
  "goal": "Surface priority on task cards, edit modal, and filter bar.",
  "promptContext": "Domain model is in db/schema.sql. UI in src/components/.",
  "priority": 1,
  "effort": 3,
  "status": "planned",
  "depends_on": [],
  "story_path": "sprints/sprint-1/stories/S-001/story.json"
}
```

Status progression: `planned → ready → active → done` (or `abandoned`/`blocked`).

### story.json structure

```json
{
  "version": 1,
  "project": "MyApp",
  "storyId": "S-001",
  "title": "Add priority field to tasks",
  "description": "Deliver a complete priority system.",
  "branchName": "ralph/sprint-1/task-priority",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "active",
  "spec": {
    "scope": "Add priority column to tasks table and surface it in UI.",
    "preserved_invariants": ["Existing tasks default to 'medium' priority"],
    "out_of_scope": ["Priority-based sorting algorithms"]
  },
  "tasks": [ ... ],
  "passes": false
}
```

---

## Task Format

Each task in `story.json` has:

```json
{
  "id": "T-01",
  "title": "Add priority column to database schema",
  "context": "Self-contained description of what to do, where, and how to verify. A fresh Codex session reads only this field.",
  "scope": [
    "db/schema.sql",
    "migrations/001_add_priority.sql"
  ],
  "acceptance": "Migration file exists, schema reflects priority column, typecheck passes.",
  "checks": [
    "test -f migrations/001_add_priority.sql",
    "grep -q 'priority' db/schema.sql",
    "npm run typecheck"
  ],
  "depends_on": [],
  "status": "pending",
  "passes": false
}
```

Rules:

- `checks[]` are binary shell expressions — exit 0 = pass, non-zero = fail
- `context` must be fully self-contained; no references to external files
- `scope[]` lists real file paths relative to repo root (no globs)
- tasks run sequentially; `depends_on` lists task IDs that must pass first
- T-final is always a full regression task (build + lint + full test suite)

Typical story task structure:

- **T-01** — Core implementation: `scope` = source files, `checks` = typecheck + lint
- **T-02** — Tests: `scope` = test files, `checks` = lint + scoped test runner
- **T-03** — Full regression: `checks` = build + lint + full test suite

---

## Command Reference

### Install and validate

```bash
bash /path/to/ralph/install.sh [--project PATH] [--dest RELDIR] [--force] \
  [--install-skills] [--install-prompts] [--install-speckit] [--skip-git-check]
./scripts/ralph/doctor.sh
```

`install.sh` flags:
- `--project DIR` — target project directory (default: current directory)
- `--dest RELDIR` — install path relative to project (default: `scripts/ralph`)
- `--force` — overwrite existing files
- `--install-skills` — copy skills to `~/.codex/skills`
- `--install-prompts` — copy prompts to `~/.codex/prompts`
- `--install-speckit` — compatibility flag; install already ensures repo-local SpecKit by default
- `--skip-git-check` — allow installing outside a git repo

### Roadmap and sprint planning

```bash
./scripts/ralph/ralph-roadmap.sh --vision "..."
./scripts/ralph/ralph-roadmap.sh --refine --revision-note "..."

./scripts/ralph/ralph-sprint.sh list
./scripts/ralph/ralph-sprint.sh create <sprint-name>
./scripts/ralph/ralph-sprint.sh use <sprint-name>
./scripts/ralph/ralph-sprint.sh mark-ready <sprint-name>
./scripts/ralph/ralph-sprint.sh next [--activate]
./scripts/ralph/ralph-sprint.sh branch <sprint-name>
./scripts/ralph/ralph-sprint.sh status
```

### Story management

```bash
./scripts/ralph/ralph-story.sh list
./scripts/ralph/ralph-story.sh show <ID>
./scripts/ralph/ralph-story.sh add --title "..." --goal "..." --prompt-context "..."
./scripts/ralph/ralph-story.sh specify <ID>
./scripts/ralph/ralph-story.sh specify-all [--force] [--jobs N]
./scripts/ralph/ralph-story.sh generate <ID>
./scripts/ralph/ralph-story.sh generate-all [--force] [--jobs N]
./scripts/ralph/ralph-story.sh prepare-all [--force] [--jobs N]
./scripts/ralph/ralph-story.sh health [<ID>]
./scripts/ralph/ralph-story.sh health-all
./scripts/ralph/ralph-story.sh tasks <ID>
./scripts/ralph/ralph-story.sh set-status <ID> <STATUS>
./scripts/ralph/ralph-story.sh abandon <ID> [reason]
./scripts/ralph/ralph-story.sh import-prd [PATH]
./scripts/ralph/ralph-story.sh start-next
```

### Execution and status

```bash
./scripts/ralph/ralph.sh [--max-stories N] [--max-retries N] [--continue-on-failure] [--skip-fallow] [--dry-run]
./scripts/ralph/ralph-task.sh [--story PATH] [--task-id ID] [--max-retries N] [--dry-run]
./scripts/ralph/ralph-status.sh
```

`ralph.sh` flags:
- `--max-stories N` — safety ceiling on stories per run (default: 50)
- `--max-retries N` — per-task Codex retry count (default: 2)
- `--continue-on-failure` — continue to next story when a story fails (default: stop)
- `--skip-fallow` — deprecated compatibility flag; no effect
- `--dry-run` — print plan without executing

### Verification and quality

```bash
./scripts/ralph/ralph-verify.sh [--targeted|--full]
./scripts/ralph/ralph-fallow.sh [--story PATH] [--dry-run] [--no-autofix]
```

`ralph-verify.sh` modes:
- `--targeted` — typecheck, lint, and tests scoped to changed files (default)
- `--full` — full suite with known baseline failures filtered out

### Sprint closeout

```bash
./scripts/ralph/ralph-sprint-commit.sh [--target BRANCH] [--dry-run] [--keep] [--skip-regression] [--run-fallow] [--fallow-autofix]
```

### Recovery and migration

```bash
./scripts/ralph/ralph-cleanup.sh --force
./scripts/ralph/ralph-sprint-migrate.sh [--sprint NAME] [--dry-run] [--force]
```

---

## Local Extensions

### prompt.local.md

Keep repo-specific Ralph behavior in `scripts/ralph/prompt.local.md`. The framework installer does not overwrite this file.

`ralph.sh` supports marker-based injection:

```
# In prompt.md:
<!-- RALPH:LOCAL:ROLE:HELPER -->

# In prompt.local.md:
<!-- RALPH:LOCAL:ROLE:HELPER -->
...content injected at the marker location...
<!-- /RALPH:LOCAL:ROLE:HELPER -->
```

If no matching marker blocks are found, a non-empty `prompt.local.md` is appended as `## Local Prompt Extensions`.

### Adding a new local capability

1. Add or update a helper script under `scripts/ralph/`.
   Use `scripts/ralph/new-local-extension.sh.example` as the starting point.
2. Add usage instructions to `scripts/ralph/prompt.local.md`.
3. Add a one-line note in `AGENTS.md` if policy or process changed.
4. Run `./scripts/ralph/doctor.sh` and a small Ralph story sanity check.

### Update-safe rules

- Do not edit `scripts/ralph/prompt.md` for repo-only behavior.
- Put repo-only instructions in `scripts/ralph/prompt.local.md`.
- Reference all local helper scripts from `prompt.local.md` so they remain discoverable.
- Keep helper scripts idempotent and safe to run repeatedly.
- Prefer additive changes; avoid modifying core framework scripts unless needed.

### Upgrade checklist (framework reinstall)

1. Re-run framework installer.
2. Confirm `scripts/ralph/prompt.local.md` still exists and marker blocks still inject.
3. Confirm local helper scripts still exist and are executable.
4. Re-run one targeted Ralph story workflow to validate behavior.
