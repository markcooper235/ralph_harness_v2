---
name: setup
description: "Install Ralph (Codex port) as Codex skills and configure a target project to run the Ralph loop. Triggers on: install ralph, setup ralph, configure ralph for project, ralph for codex setup, ralph install."
---

# Setup Ralph for Codex

Install Ralph skills, install Ralph runtime into a project, and verify it is ready to run.

## Non-Negotiables

- Install/refresh global skills before skill-driven story workflows.
- Run `install.sh` from this repo.
- Use an absolute target path for `--project`.
- Verify with `./scripts/ralph/doctor.sh` after install — it checks for SpecKit, sprint state, and gitignore rules.
- Prepare story task containers with `ralph-story.sh prepare-all` before the first `ralph.sh` run.
- Keep project-specific regression commands in `scripts/ralph/ralph-sprint-test.sh`.

## Ask Only If Missing

1. Target project root path?
2. Install skills globally (`~/.codex/skills`) or project-local only?
3. Start with a smoke test or convert an existing PRD?

## Steps

### A) Install skills globally (recommended)

Run from this repo (where `install.sh` exists):

```bash
bash ./install.sh --install-skills
```

Copies all `skills/*` folders to `~/.codex/skills/`.
Re-run this after local skill edits so runtime behavior matches repo changes.

### B) Install Ralph into target project

```bash
bash ./install.sh --project /absolute/path/to/target-project [--install-speckit] [--force]
```

Installs `scripts/ralph/` with loop scripts, helpers, templates, and a sprint scaffold.

Additional flags:
- `--install-speckit` — install the SpecKit `specify` CLI, required for story preparation
- `--force` — overwrite existing files on reinstall
- `--dest RELDIR` — install to a different relative path (default: `scripts/ralph`)
- `--skip-git-check` — allow installing outside a git repo

### C) Verify install

From target project root:

```bash
./scripts/ralph/doctor.sh
```

Doctor checks: git, jq, codex, SpecKit CLI, sprint structure, gitignore rules.

### D) Plan, prepare, and run

```bash
# Plan a roadmap (creates sprint-1 and stories.json)
./scripts/ralph/ralph-roadmap.sh --vision "Describe the target state"

# Prepare story task containers (SpecKit analysis + generate + health)
./scripts/ralph/ralph-story.sh prepare-all

# Execute the sprint
./scripts/ralph/ralph.sh

# Close the sprint when all stories are done
./scripts/ralph/ralph-sprint-commit.sh
```

### E) Full sprint story sequencing

```bash
# Check sprint status
./scripts/ralph/ralph-sprint.sh status

# Add a story manually if needed (or use ralph-roadmap.sh to plan automatically)
./scripts/ralph/ralph-story.sh add --title "My Story" --goal "..." --prompt-context "..."

# Generate task containers for each story via SpecKit analysis (primary path)
./scripts/ralph/ralph-story.sh specify S-001       # SpecKit analysis → .specify/ artifacts
./scripts/ralph/ralph-story.sh generate S-001      # .specify/ → story.json
./scripts/ralph/ralph-story.sh health S-001        # validate tasks, checks, deps

# Or use prepare-all for all pending stories at once
./scripts/ralph/ralph-story.sh prepare-all [--jobs 2]

# Execute stories
./scripts/ralph/ralph.sh [--max-stories N] [--max-retries N]

# Check status at any point
./scripts/ralph/ralph-status.sh

# Close sprint
./scripts/ralph/ralph-sprint-commit.sh
# use --keep to retain merged sprint branch
# use --skip-regression to bypass pre-merge regression gate
```

### Importing an existing prd.json into sprint format

```bash
# Convert prd.json userStories → stories.json entries
./scripts/ralph/ralph-story.sh import-prd scripts/ralph/prd.json

# Then prepare task containers for each imported story
./scripts/ralph/ralph-story.sh prepare-all
./scripts/ralph/ralph.sh
```

## Notes

- Copy `scripts/ralph/ralph-sprint-test.sh.example` to `ralph-sprint-test.sh` and add project-specific typecheck, lint, and test commands — `ralph-sprint-commit.sh` requires this file.
- `.specify/` artifacts are durable and should be committed alongside `story.json`.
- Migrating from the old epic/PRD format? Run `ralph-sprint-migrate.sh`.
- To reset a stuck story: `./scripts/ralph/ralph-story.sh set-status S-001 planned`
- To clear a stale workflow lock: `./scripts/ralph/ralph-cleanup.sh --force`
