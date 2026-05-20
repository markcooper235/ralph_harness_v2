# Ralph Maintainer Notes

This file holds framework-maintainer details that are intentionally too specific for `AGENTS.md`.

Use `AGENTS.md` for the broad operating model. Use this file when you need deeper policy, edge-case behavior, or the rationale behind current framework decisions.

## Table of Contents

- [Documentation Policy](#documentation-policy)
- [Sprint And Roadmap Policy](#sprint-and-roadmap-policy)
- [SpecKit Integration Policy](#speckit-integration-policy)
- [Story Health Policy](#story-health-policy)
- [Execution And Task Policy](#execution-and-task-policy)
- [Fallow Gate Policy](#fallow-gate-policy)
- [Completion And Branch Policy](#completion-and-branch-policy)
- [Prompt And Intake Policy](#prompt-and-intake-policy)
- [Archive And Merge Policy](#archive-and-merge-policy)
- [Story Sizing Policy](#story-sizing-policy)
- [Smoke Harness Notes](#smoke-harness-notes)

---

## Documentation Policy

- Repo docs should describe the framework in terms of the simple operator flow: install, plan, prepare, run, commit.
- Keep advanced helpers behind the main path instead of leading with internals.
- README-level documentation should emphasize the current capabilities: roadmap planning, SpecKit preparation, story-task execution model, binary acceptance checks, fallow gate, and sprint closeout.
- The story-task architecture is the canonical model; legacy PRD/epic terminology should not appear in new operator-facing documentation.

---

## Sprint And Roadmap Policy

- `ralph-story.sh` requires an active sprint for commands that resolve from `.active-sprint`; use `ralph-sprint.sh use <sprint-name>` first if needed.
- `ralph-story.sh add ...` provides a non-interactive story creation path and is the preferred automation path.
- Roadmap planning should keep sprint effort at or under the capacity ceiling and use only sprint-safe story effort scores: `1`, `2`, `3`, `5`.
- Overflow work belongs in later sprints, not the current one.
- Keep explicit story dependencies sprint-local; cross-sprint sequencing should be represented by sprint order.
- Roadmap refinement should be additive by default: preserve done or active work, update open or future work directly, and prefer follow-up stories or new sprints over reopening closed sprints.
- Stories should track planning provenance: roadmap-managed work may be reconciled by `ralph-roadmap.sh`, while local ad hoc stories should be left alone unless dependency validation fails.
- `ralph-sprint.sh status` should report both `Active story` and `Next story` to avoid confusion when a story is already active.
- `ralph-sprint.sh next` should ignore sprints when their remaining stories are all `blocked`.

---

## SpecKit Integration Policy

- SpecKit analysis runs three sequential phases via `ralph-story.sh specify <ID>`: specify → plan → tasks.
- Output artifacts are written to `<story-dir>/.specify/{spec.md, plan.md, tasks.md}`.
- `.specify/` artifacts are durable and should be committed alongside `story.json`.
- `ralph-story.sh specify` also maintains a transient cached repo briefing under Ralph's script directory at `.cache/specify/repo-briefing.md` so stories reuse a compact project summary instead of repeatedly rediscovering repo setup.
- `ralph-story.sh specify` should also prefer deterministic file-path hints derived from the story title, goal, and prompt context. Those hints belong in `input.md` as a first-pass map, not as expanded file contents.
- Dependency handoff and likely-file hints must exclude generated trees, runtime journals, package-manager/vendor paths, and framework documentation paths. Downstream specify context should mention source, test, and config files only.
- Ralph's canonical model is story-local SpecKit state. Project-level `specify init` is optional interoperability sugar, not a framework requirement.
- `ralph-story.sh generate <ID>` detects `.specify/` artifacts and uses the `story-specify` skill when present; it falls back to the `story-generate` skill when artifacts are absent.
- `ralph-story.sh specify-all` and `generate-all` support `--jobs N` for parallel execution.
- `ralph-story.sh prepare-all` = specify-all + generate-all + health + promote to ready. It is the recommended single-command story preparation path.
- SpecKit requires the `specify` CLI to be installed. `doctor.sh` checks for it and fails if missing. Install via `--install-speckit`, `uv tool install git+https://github.com/github/spec-kit.git`, or an `npx`-based fallback.
- When `specify` is absent and cannot be found via `npx`, `ralph-story.sh specify` fails with a clear message — there is no silent fallback for SpecKit phases.

---

## Story Health Policy

- `ralph-story.sh health [ID]` validates active (non-done, non-abandoned) stories; `health-all` covers all stories.
- Health checks cover: story.json existence, task count > 0, acceptance check count per task, context completeness, task `depends_on` integrity (no dead references, no self-referencing), duplicate checks within a task, tasks with identical check sets, and check syntax/command reachability.
- SpecKit artifact completeness is also validated when a `.specify/` directory exists for the story.
- `prepare-all` only promotes a story to `ready` when health passes and the story has a valid `story.json` with at least one task.
- A story with health warnings should not be executed by `ralph.sh` — fix issues first, then re-run `ralph-story.sh health`.

---

## Execution And Task Policy

- `ralph.sh` only operates when on the sprint branch (`ralph/sprint/<sprint-name>`); it fails with a clear message when the working tree is dirty or the branch is wrong.
- `ralph.sh` warns before the loop when stories have no `story.json`, prompting `prepare-all` first.
- `ralph-story-run.sh` locks execution via `.workflow-lock`; the lock is shared with `ralph.sh` via `RALPH_LOCK_HELD`.
- Each task's `checks[]` are evaluated by running each shell expression from the workspace root. All checks must exit 0 for the task to pass.
- The primary story cycle is where ordinary correction should happen. `--max-retries` controls only targeted remediation cycles after the main story cycle exits.
- `ralph.sh` writes a sprint runtime journal under `scripts/ralph/runtime/sprint-runs/<timestamp>-<sprint>/`, including `sprint.log` and `sprint-run.json`.
- `ralph-story-run.sh` writes story-cycle logs and failed-check bundles under that sprint runtime journal when available, or under `scripts/ralph/runtime/story-runs/` for standalone runs.
- Runtime journals are for audit and debugging, not default prompt context. Only compact failed-check summaries should be injected into remediation prompts.
- Runtime journal retention is capped at the most recent 3 run directories for both sprint runs and standalone story runs.
- Task `handoff` is written on success and passed as compact context to downstream dependent tasks and stories.
- `story_handoff` summarizes completed tasks, touched files, added contracts, and residual risks. It is used as context when dependent stories are prepared via `ralph-story.sh specify`.

---

## Fallow Gate Policy

- `ralph-fallow.sh` is an explicit quality pass and can also be run during sprint closeout with `ralph-sprint-commit.sh --run-fallow`.
- It uses `fallow audit` (fallow.tools) for JS/TS projects only when the branch diff stays within the story scope. Otherwise it falls back to exact-file analyzers to avoid broad cleanup drift.
- Broad auto-fix is disabled by default. Set `RALPH_FALLOW_EXACT_AUTOFIX=1` and `RALPH_FALLOW_CODEX_AUTOFIX=1` only when you intentionally want scoped fallback and Codex follow-up auto-fix.
- `--dry-run` reports issues without auto-fixing or failing the gate.
- `--no-autofix` reports and fails without attempting auto-fix.
- `--skip-fallow` in `ralph.sh` and `ralph-story-run.sh` is retained only as a deprecated compatibility flag.
- The fallow gate prefers branch-diff analysis only when every changed file is in-scope for the story; otherwise it reports against the exact in-scope file set.

---

## Completion And Branch Policy

- `ralph-story-run.sh` marks a story `done` when all task `passes` fields are `true`.
- On story completion, `ralph-story-run.sh` automatically merges the story branch into the sprint branch using `--no-ff` and deletes the story branch.
- If the merge has conflicts, the story branch is left intact for manual resolution.
- Sprint closeout via `ralph-sprint-commit.sh` requires all stories to be `done` or `abandoned`; it will not proceed with `active`, `planned`, or `ready` stories remaining.
- `ralph-sprint-commit.sh` archives sprint metadata to `tasks/archive/sprints/` before merging.
- Sprint branches are deleted after merge by default; pass `--keep` to retain.
- `ralph-sprint-commit.sh` requires `ralph-sprint-test.sh` to exist and pass before merging. This file is project-specific — copy from `ralph-sprint-test.sh.example`.

---

## Prompt And Intake Policy

- Keep repo-specific Ralph behavior in `scripts/ralph/prompt.local.md` and optional local helper scripts referenced there so framework updates can refresh core files safely.
- `ralph.sh` supports marker-based local prompt injection: place `<!-- RALPH:LOCAL:<NAME> -->` in `prompt.md` and matching start/end blocks in `prompt.local.md`.
- Empty local prompt files are ignored; non-matching legacy local content falls back to append mode.
- Keep interactive wrappers minimal by default; provide CLI flags for non-interactive runs.
- Keep `prompt.md` terse because every Ralph iteration pays for it.
- Keep specify prep context terse too: default to the cached repo briefing plus story-local input, and only inspect additional files when they are directly relevant to the story.
- Prefer path hints and repo briefing summaries over broad repo excerpts. The model should be pointed toward likely implementation files before it is invited to explore.

---

## Archive And Merge Policy

- Sprint-level archive is written to `tasks/archive/sprints/<sprint-name>/` by `ralph-sprint-commit.sh`.
- `.active-prd` includes explicit `baseBranch`; scripts should use it before fallback target inference when it exists.
- Transient per-story files (`.task-log-*.txt`, `.fallow-report.json`, `.fallow-autofix.txt`) are cleaned up automatically after a successful story merge.
- Runtime journals under `scripts/ralph/runtime/` are intentionally preserved across successful runs and normal cleanup, but pruned to the most recent 3 run directories.

---

## Story Sizing Policy

- Sprint backlogs should decompose into independently shippable stories.
- Use story effort scores that fit sprint capacity: `micro` 1, `small` 2-3, `medium` 4-5.
- Each story should have 2-5 tasks in `story.json`. If honest decomposition needs more, create a follow-up story.
- Tasks must be completable in a single focused Codex session.

---

## Smoke Harness Notes

### Primary E2E test: e2e-calendar.sh

`scripts/smoke/e2e-calendar.sh` is the primary framework smoke test. It exercises a complete two-sprint lifecycle across two real project types, validating multi-sprint operation end-to-end.

**Projects under test:**

- **nextjs-calendar** — Real Next.js project scaffolded with `create-next-app`, Jest for testing
  - Sprint 1: domain layer — types, CalendarService, TodoService, barrel/module + integration test
  - Sprint 2: React components — CalendarView, TodoList, EventForm, CalendarApp with @testing-library/react
- **angular-calendar** — Real Angular project scaffolded with `ng new`, Jest via ts-jest
  - Sprint 1: services in `src/app/services/`, tested as `*.spec.ts`
  - Sprint 2: standalone Angular components in `src/app/components/`, class-only tests

**Lifecycle covered per project:**

```
install.sh → doctor.sh → ralph-sprint.sh create → ralph-story.sh add →
story.json (hand-written or --generated) → ralph-story.sh health →
ralph.sh → ralph-status.sh → ralph-sprint-commit.sh →
[sprint 2 setup] → ralph.sh → ralph-sprint-commit.sh → ralph-verify.sh
```

Sprint 2 is skipped for a project if sprint 1 did not commit successfully.

**Flags:**

- `--keep` — retain work directory after run (always retained on failure)
- `--max-retries N` — targeted remediation cycle count after the primary story run (default: 2)
- `--generated` — use `ralph-story.sh generate` for story.json instead of hand-written files; exercises the full story generation pipeline and adds ~8 Codex sessions

**Running:**

```bash
bash scripts/smoke/e2e-calendar.sh
bash scripts/smoke/e2e-calendar.sh --keep
bash scripts/smoke/e2e-calendar.sh --generated
```

### Smoke harness guidelines

- Disposable smoke repos should configure a local git identity during setup so E2E runs do not depend on the developer having global `user.name` and `user.email` configured.
- When the smoke harness runs under a TTY, explicitly redirect stdin from `/dev/null` for intentionally interactive wrappers when they are used in automation-only setup steps.
- Smoke telemetry should report both token totals and loop iteration counts so efficiency regressions can be traced to planning cost or extra loop churn.
- Smoke runs should persist a lightweight local benchmark history under `scripts/smoke/.benchmarks/` for before/after efficiency comparison.
- Smoke retry handling should clear only provably stale workflow locks in disposable smoke repos; core Ralph lock semantics in `ralph.sh` and `ralph-story-run.sh` are not weakened.
- Smoke assertions should be behavior-led when equivalent implementations are acceptable — avoid asserting exact source spelling unless the spelling itself is part of the requirement.
