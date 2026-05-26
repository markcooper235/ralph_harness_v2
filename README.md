# Ralph

![Ralph](ralph.webp)

Ralph is a Codex-native autonomous loop that executes sprint stories as focused story-level Codex cycles. Planning artifacts are durable and committed; execution state stays transient.

Ralph uses story-local SpecKit artifacts under each story directory's `.specify/` folder. A repo-wide `specify init` step is optional and not required for normal Ralph workflows.

Framework source of truth:

- `scripts/ralph/` is the canonical runtime payload that gets installed into target repos
- `install.sh` copies from `scripts/ralph/` into the target project's `scripts/ralph/`
- repo-root files are installer, tests, skills, and maintainer assets only

This repo is the Ralph-for-Codex framework — **story-task architecture**:

- stories replace epics as the sprint-level planning unit
- each story is a self-contained task container (`story.json`) with binary acceptance checks
- SpecKit integration produces specifications and implementation plans before execution
- each story runs in one primary Codex session, with shell verification after the cycle
- acceptance checks are validated by shell, not AI
- merged story branches are cleaned up automatically after each story passes

## Table of Contents

- [Current Process](#current-process)
  - [Sprint Workflow](#sprint-workflow)
  - [Multi-Sprint Workflow](#multi-sprint-workflow)
  - [Standalone (PRD Import)](#standalone-prd-import)
- [Quick Start](#quick-start)
- [Core Capabilities](#core-capabilities)
- [Command Surface](#command-surface)
- [Runtime Model](#runtime-model)
- [Smoke Testing](#smoke-testing-the-framework)
- [Key Files](#key-files)
- [Notes](#notes)
- [References](#references)

---

## Current Process

Ralph has one primary workflow: **sprint mode**. A standalone PRD can be imported into sprint format when needed.

### Sprint Workflow

```bash
# 1. Install and validate
bash /path/to/ralph/install.sh
./scripts/ralph/doctor.sh

# 2. Plan a roadmap (creates sprints and stories.json backlog)
./scripts/ralph/ralph-roadmap.sh --vision "Describe the target state"

# 3. Check sprint readiness
./scripts/ralph/ralph-sprint.sh status

# 4. Prepare story task containers
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-1

# 5. Mark the sprint ready, then activate it
./scripts/ralph/ralph-sprint.sh mark-ready sprint-1
./scripts/ralph/ralph-sprint.sh use sprint-1

# 6. Execute the sprint
./scripts/ralph/ralph.sh

# 7. Close the sprint
./scripts/ralph/ralph-sprint-commit.sh
```

What happens:

- `ralph-roadmap.sh` decomposes a vision into sprint backlogs (`stories.json`)
- `ralph-story.sh prepare-all --sprint <name>` runs SpecKit analysis and generates `story.json` task containers
- `ralph-story.sh prep-status [--details] [--story <ID>]` inspects the latest prep journal and per-story prep stages
- `ralph.sh` picks up the next eligible story, runs it via `ralph-story-run.sh`, validates binary checks, and merges the story branch back to the sprint branch
- `ralph-sprint-commit.sh` runs sprint-scoped verification by default, archives sprint artifacts, and merges to `main`/`master`

### Multi-Sprint Workflow

After sprint 1 completes, activate and run subsequent sprints:

```bash
# Sprint 1
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-1
./scripts/ralph/ralph-sprint.sh mark-ready sprint-1
./scripts/ralph/ralph-sprint.sh use sprint-1
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh          # merges sprint-1 branch to main

# Sprint 2
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-2
./scripts/ralph/ralph-sprint.sh mark-ready sprint-2
./scripts/ralph/ralph-sprint.sh use sprint-2    # activate the next sprint
./scripts/ralph/ralph.sh                        # execute sprint-2
./scripts/ralph/ralph-sprint-commit.sh          # merges sprint-2 branch to main
```

Or use `next --activate` to automatically select the next ready sprint:

```bash
./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-3
./scripts/ralph/ralph-sprint.sh mark-ready sprint-3
./scripts/ralph/ralph-sprint.sh next --activate
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

`ralph-sprint-commit.sh` closes the sprint branch and merges it to `main`/`master`. The previous sprint must be closed before a new one can be activated.

### Standalone (PRD Import)

For single-feature work using an existing `prd.json`:

```bash
./scripts/ralph/ralph-story.sh import-prd scripts/ralph/prd.json
./scripts/ralph/ralph-story.sh prepare-all
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

---

## Quick Start

### Install into a project

From the target repo root:

```bash
bash /path/to/ralph/install.sh
./scripts/ralph/doctor.sh
```

Optional global installs:

```bash
bash /path/to/ralph/install.sh --install-skills
bash /path/to/ralph/install.sh --install-prompts
bash /path/to/ralph/install.sh
```

Prerequisites:

- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`
- a git repository
- SpecKit CLI (`specify`) — required for story preparation (bootstrapped repo-locally during install)

---

## Core Capabilities

### Planning

- `ralph-roadmap.sh` creates or refines a durable roadmap and seeds sprint `stories.json` backlogs
- roadmap planning decomposes work into sprint-safe stories with effort scores `1`, `2`, `3`, or `5`
- sprint backlogs carry `capacityTarget` and `capacityCeiling`
- roadmap-managed stories and local ad hoc stories are tracked separately so refinement is additive

### Story Preparation

- `ralph-story.sh specify <ID>` runs three-phase SpecKit analysis (`specify → plan → tasks`) and writes artifacts to `.specify/`
- `ralph-story.sh generate <ID>` converts SpecKit artifacts to a `story.json` task container
- `ralph-story.sh prepare-all` runs both phases for all pending stories, validates health, and promotes healthy stories to `ready`
- `ralph-story.sh prep-status` surfaces the latest prep journal, stage status, durations, and skip reasons for operators
- `ralph-story.sh health [ID]` validates task counts, acceptance checks, dependency integrity, and check syntax

### Execution

- `ralph.sh` loops over eligible stories: `start-next → ralph-story-run.sh → repeat`
- `ralph-story-run.sh` runs one primary Codex cycle per story; acceptance `checks[]` are evaluated by shell after the cycle
- `ralph-story-run.sh` builds a deterministic execution bundle per story and uses it as the primary model context instead of broad repo rediscovery
- sprint and story runtime journals are recorded under `scripts/ralph/runtime/`, kept out of model context by default, and pruned to the most recent 3 run directories
- targeted remediation retries up to `--max-retries` times only when the primary cycle leaves correctable check failures
- remediation prompts include compact failed-check summaries only when checks fail; full logs stay on disk
- when all tasks pass, the story branch is merged to the sprint branch and deleted automatically
- `ralph-fallow.sh` provides a scoped code-quality gate (dead code, duplication, lint) that can be run explicitly or during sprint closeout

### Verification

- each task's `checks[]` are binary shell expressions (exit 0 = pass)
- the fallow gate is available as an explicit quality pass and can be run during sprint closeout
- `ralph-sprint-commit.sh` uses sprint-scoped verification by default and supports `--full-regression` for repo-wide closeout
- `ralph-verify.sh --task`, `--story-scope`, and `--sprint` scope verification to the current Ralph surface
- `ralph-verify.sh --full-regression` runs the full suite with known baseline failures filtered out

### Sprint Management

- `ralph-sprint.sh create <name>` creates a new sprint scaffold
- `ralph-sprint.sh status` shows active sprint, story readiness, and active story
- `ralph-sprint.sh mark-ready <name>` promotes a sprint once all stories are ready
- `ralph-sprint.sh use <name>` activates a sprint (previous sprint must be closed)
- `ralph-sprint.sh next [--activate]` selects and optionally activates the next ready sprint

### Closeout

- `ralph-sprint-commit.sh` validates all stories are terminal, archives sprint artifacts, and merges the sprint branch
- merged sprint branches are deleted by default; pass `--keep` to retain

### Execution Baseline

- keep shared per-story execution guidance in `scripts/ralph/execution-baseline.md`
- Ralph builds the story-specific execution prompt in `ralph-story-run.sh`
- repo-specific behavior should live in durable scripts and checked-in docs, not prompt overlay files

See [scripts/ralph/README-local.md](scripts/ralph/README-local.md).

---

## Command Surface

```bash
# Install / validate
./install.sh [--project PATH] [--dest RELDIR] [--force] [--install-skills] [--install-prompts] [--install-speckit] [--skip-git-check]
./scripts/ralph/doctor.sh

# Roadmap / sprint planning
./scripts/ralph/ralph-roadmap.sh --vision "Roadmap from current state to target state"
./scripts/ralph/ralph-roadmap.sh --refine --revision-note "Adjust after new findings"
./scripts/ralph/ralph-sprint.sh list
./scripts/ralph/ralph-sprint.sh create sprint-2
./scripts/ralph/ralph-sprint.sh status
./scripts/ralph/ralph-sprint.sh use sprint-1
./scripts/ralph/ralph-sprint.sh mark-ready sprint-1
./scripts/ralph/ralph-sprint.sh next [--activate]
./scripts/ralph/ralph-sprint.sh branch sprint-1

# Story management
./scripts/ralph/ralph-story.sh list
./scripts/ralph/ralph-story.sh add --title "My Story" --goal "..." --prompt-context "..."
./scripts/ralph/ralph-story.sh specify S-001
./scripts/ralph/ralph-story.sh specify-all [--force] [--jobs N]
./scripts/ralph/ralph-story.sh generate S-001
./scripts/ralph/ralph-story.sh generate-all [--force] [--jobs N]
./scripts/ralph/ralph-story.sh prepare-all [--sprint NAME] [--force] [--jobs N]
./scripts/ralph/ralph-story.sh prep-status [--details] [--story ID]
./scripts/ralph/ralph-story.sh health [S-001]
./scripts/ralph/ralph-story.sh health-all
./scripts/ralph/ralph-story.sh show S-001
./scripts/ralph/ralph-story.sh tasks S-001
./scripts/ralph/ralph-story.sh set-status S-001 planned
./scripts/ralph/ralph-story.sh abandon S-001 [reason]
./scripts/ralph/ralph-story.sh import-prd [PATH]
./scripts/ralph/ralph-story.sh start-next

# Loop / execution
./scripts/ralph/ralph.sh [--max-stories N] [--max-retries N] [--continue-on-failure] [--skip-fallow] [--dry-run]
./scripts/ralph/ralph-story-run.sh [--story PATH] [--task-id ID] [--max-retries N] [--dry-run]
./scripts/ralph/ralph-status.sh

# Verification
./scripts/ralph/ralph-verify.sh [--targeted|--task|--story-scope|--sprint|--full-regression]

# Code quality
./scripts/ralph/ralph-fallow.sh [--story PATH] [--dry-run] [--no-autofix]

# Sprint closeout
./scripts/ralph/ralph-sprint-commit.sh [--target BRANCH] [--dry-run] [--keep] [--skip-regression] [--run-fallow] [--fallow-autofix] [--full-regression]

# Recovery
./scripts/ralph/ralph-cleanup.sh --force
```

---

## Runtime Model

### File structure

```
scripts/ralph/
├── sprints/
│   └── sprint-1/
│       ├── stories.json                   # Sprint story backlog
│       └── stories/
│           └── S-001/
│               ├── story.json             # Task container (committed)
│               └── .specify/              # SpecKit artifacts (committed)
│                   ├── input.md
│                   ├── spec.md
│                   ├── plan.md
│                   └── tasks.md
├── .cache/
│   └── specify/
│       └── repo-briefing.md               # Cached project briefing for SpecKit prep (untracked in the framework repo)
├── roadmap.json                           # Structured roadmap data
├── roadmap.md                             # Rendered roadmap
├── roadmap-source.md                      # Durable roadmap input (committed)
├── runtime/                               # Untracked sprint/story execution journals
│   ├── prep-runs/
│   │   └── <timestamp>-<sprint>/
│   │       ├── prepare-run.json
│   │       └── S-001-specify.log
│   └── sprint-runs/
│       └── <timestamp>-<sprint>/
│           ├── sprint.log
│           ├── sprint-run.json
│           └── stories/
│               └── S-001/
│                   ├── .exec/
│                   │   ├── summary.md
│                   │   ├── files.json
│                   │   └── commands.json
│                   ├── primary.log
│                   ├── remediation-1.log
│                   ├── story-summary.json
│                   └── checks/
│                       ├── T-01-check-1.stderr.txt
│                       ├── T-01-check-1.stdout.txt
│                       └── T-01-failing-checks.json
├── tasks/
│   └── archive/
│       └── sprints/                       # Archived sprint metadata
├── execution-baseline.md                  # Base execution guidance used every story run
└── ralph-sprint-test.sh                   # Optional project regression gate
```

### Durable artifacts (committed)

- `stories.json` — sprint story backlog
- `story.json` — task container with acceptance checks
- `.specify/` — SpecKit artifacts (spec.md, plan.md, tasks.md)
- `roadmap-source.md`, `roadmap.json`, `roadmap.md`
- git history
- archived sprint artifacts under `tasks/archive/sprints/`

### Transient artifacts (untracked)

- `scripts/ralph/.active-sprint`
- `scripts/ralph/.workflow-lock`
- `scripts/ralph/prd.json` (when used via import-prd)
- `scripts/ralph/progress.txt`
- `scripts/ralph/.active-prd`
- `scripts/ralph/.cache/` cached SpecKit preparation briefings in installed repos
- `.cache/specify/` cached SpecKit preparation briefings in the framework repo
- `scripts/ralph/runtime/` sprint and story journals (retained for the most recent 3 runs)
- per-story `.task-log-*.txt`, `.fallow-report.json`, `.fallow-autofix.txt`

Transient files must stay untracked. Ralph will fail or clean up when they drift into git.

### Branch model

- sprint branches: `ralph/sprint/<sprint-name>` — lives until `ralph-sprint-commit.sh`
- story branches: `ralph/<sprint>/story-<S-XXX>` — merged and deleted after each story completes

---

## Smoke Testing The Framework

The primary end-to-end smoke test is `scripts/smoke/e2e-calendar.sh`. It exercises a complete two-sprint lifecycle across two real framework projects (NextJS and Angular), validating multi-sprint operation end-to-end.

### e2e-calendar.sh

Runs a Calendar + Todo app across two sprints and two project types:

- **nextjs-calendar** — Real Next.js project scaffolded with `create-next-app` + Jest
  - Sprint 1: domain layer (types, calendar service, todo service, barrel/module + integration test)
  - Sprint 2: React components (CalendarView, TodoList, EventForm, AppComponent)
- **angular-calendar** — Real Angular project scaffolded with `ng new` + Jest via ts-jest
  - Sprint 1: domain services in `src/app/services/`, tested as `*.spec.ts`
  - Sprint 2: standalone Angular components in `src/app/components/`

Each project runs the full lifecycle:

```
install.sh → doctor.sh → ralph-sprint.sh create → ralph-story.sh add →
story.json (framework-imported or --generated) → ralph-story.sh prepare-all →
ralph-sprint.sh use → ralph.sh → ralph-status.sh → ralph-sprint-commit.sh →
[sprint 2 setup] → ralph.sh → ralph-sprint-commit.sh → ralph-verify.sh
```

Sprint 2 is skipped for a project if sprint 1 did not commit successfully.

```bash
# Basic run (framework-imported story.json files, uses real Codex)
bash scripts/smoke/e2e-calendar.sh

# Keep work directory after run (always kept on failure)
bash scripts/smoke/e2e-calendar.sh --keep

# Override targeted remediation cycle count
bash scripts/smoke/e2e-calendar.sh --max-retries 3

# Use ralph-story.sh generate for story.json instead of framework-imported files
# Exercises the full story generation pipeline; adds ~8 Codex sessions
bash scripts/smoke/e2e-calendar.sh --generated
```

Notes:

- smoke tests run against real Codex by default; a `CODEX_BIN` override or mock harness can be used for CI
- smoke telemetry reports token totals and iteration counts
- benchmark history is stored under `scripts/smoke/.benchmarks/`

---

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Install Ralph into a target repo |
| `doctor.sh` | Sanity-check a Ralph-enabled repo |
| `ralph-roadmap.sh` | Create or refine the durable roadmap and seed sprint backlogs |
| `ralph-sprint.sh` | Manage sprint containers and sprint readiness |
| `ralph-story.sh` | Manage stories: specify, generate, health, start-next, and more |
| `ralph-story-run.sh` | Execute the active story in one primary Codex cycle with shell verification |
| `ralph.sh` | Sprint execution loop: start-next → ralph-story-run.sh → repeat |
| `ralph-status.sh` | Show current sprint, story, branch, and loop state |
| `ralph-verify.sh` | Run typecheck + lint + tests (--targeted or --full) |
| `ralph-fallow.sh` | Code-quality gate: dead code, duplication, lint |
| `ralph-sprint-commit.sh` | Archive and merge the completed sprint |
| `ralph-cleanup.sh` | Reset local Ralph runtime state without archiving |
| `ralph-sprint-test.sh` | Optional project-specific regression gate for explicit sprint closeout |
| `execution-baseline.md` | Base execution guidance used every story run |
| `story.json.example` | Example task container format |
| `stories.json.example` | Example sprint story backlog format |

---

## Notes

- Fresh installs seed `sprint-1`; create more sprints only when needed.
- `ralph-sprint.sh status` reports both `Active story` and `Next story`.
- `doctor.sh` checks that SpecKit (`specify` CLI) is installed and reachable.
- SpecKit artifacts (`.specify/`) are committed — they are durable planning outputs, not transient state.
- `ralph-sprint-test.sh` is optional. Copy from `ralph-sprint-test.sh.example` only when your repo wants an explicit project-specific sprint closeout gate.
- `ralph-cleanup.sh --force` removes the workflow lock and transient state without archiving.
- Keep `execution-baseline.md` terse because every story run includes it.

---

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Upstream Ralph (Amp-based)](https://github.com/snarktank/ralph)
- [Codex CLI](https://github.com/openai/codex)
