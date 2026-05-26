---
name: story-specify
description: "Convert SpecKit artifacts (spec.md, plan.md, tasks.md) into a Ralph story.json task container. Use when .specify/ artifacts exist for a story. Triggers on: convert speckit to story, speckit to json, story-specify, build story from spec."
---

# SpecKit → story.json Converter

Convert SpecKit specification artifacts into a Ralph story.json task container.
Called by `ralph-story.sh generate <ID>` when `.specify/` artifacts are present.

## Non-Negotiables

- Read ALL three artifacts before writing anything: spec.md, plan.md, tasks.md.
- Every task `checks[]` entry must be a binary shell expression (exit 0 = pass).
- `scope[]` must contain real file paths relative to repo root — read the repo to verify.
- `context` must be fully self-contained — no references to spec.md or plan.md (those won't be available when the task runs in an isolated Codex session).
- T-final is always a full regression task (build + lint + full test suite). Always last.
- Do not commit. Do not create more than 5 tasks unless the story genuinely requires it.

## Reading the Artifacts

### spec.md → story fields

| spec.md content | story.json field |
|---|---|
| Feature title / overview | `title`, `description` |
| User scenarios / scope statement | `spec.scope` |
| Success criteria | `spec.preserved_invariants` |
| Non-goals / out of scope | `spec.out_of_scope` |
| Acceptance scenarios (Given/When/Then) | basis for `tasks[].acceptance` and `checks[]` |

### plan.md → task fields

| plan.md content | story.json field |
|---|---|
| Data models, file decisions | `tasks[].scope[]` |
| Technical decisions per feature area | `tasks[].context` |
| Phase / implementation order | task ordering (T-01, T-02, …) |

### tasks.md → task structure

| tasks.md phase | Ralph task |
|---|---|
| Phase 0 – Research | Do not create a task. Fold findings into spec fields and T-01 context. |
| Phase 1 – Foundational (data models, schema, contracts) | T-01 |
| Phase 2 – User Stories P1 (first user-facing slice) | T-02 |
| Phase 2 – User Stories P2+ (additional stories, if substantial) | T-03, T-04 (optional) |
| Phase 3 – Polish / edge cases | Fold into the last implementation task |
| Final | T-final: full regression (build + lint + test suite) |

Group multiple small SpecKit sub-tasks into a single Ralph task if they share the same files and can be completed in one Codex session.

## Standard Task Structure

**T-01 — Foundation / Core Implementation**
- `scope`: data model files, schema, shared contracts
- `checks`: typecheck + lint
- `depends_on`: []

**T-02 — Primary User-Facing Implementation**
- `scope`: feature source files
- `checks`: typecheck + lint + scoped tests
- `depends_on`: ["T-01"]

**T-final — Full Regression**
- `context`: "Run the full build, lint, and test suite. If everything passes, nothing needs to be committed. Fix any issues found and commit."
- `scope`: all files changed across T-01 through T-penultimate
- `checks`: build + lint + full test suite
- `depends_on`: ["T-penultimate"]

## Acceptance Criteria → checks[] Conversion

Read spec.md acceptance scenarios and plan.md to produce binary shell checks.
First read `package.json` to discover the actual script names.

| Acceptance criterion | Shell check |
|---|---|
| File X must exist | `test -f X` |
| File X must contain Y | `grep -q 'Y' X` |
| Typecheck must pass | `npm run typecheck` (or equivalent) |
| Lint must pass | `npm run lint` |
| Tests must pass (scoped) | `npm test -- --testPathPattern=X` |
| Full test suite must pass | `npm test` |
| Build must succeed | `npm run build` |
| Given X / When Y / **Then Z exists** | `test -f Z` |
| Given X / When Y / **Then output contains Z** | `grep -q 'Z' output-file` |

Never write subjective checks ("verify in browser", "confirm user sees…").
If an acceptance scenario cannot be expressed as a binary shell command, write the closest proxy (e.g., `npm test -- --testPathPattern=ComponentName`).

## Task Context Rules

Each task's `context` must include — inline, not by reference:
1. Which files to change and what to add/modify in each
2. The specific behavior to implement (derived from spec.md user scenario + plan.md decisions)
3. Any invariants from spec.md that must not be broken
4. How to verify completion (correlates to `acceptance`)

Do not write "see spec.md" or "as described in plan.md" — the context is the only input the executing Codex session will have.

## Output Schema

```json
{
  "version": 1,
  "project": "<from package.json name or repo dir>",
  "storyId": "<from prompt>",
  "title": "<from spec.md>",
  "description": "<1-2 sentences from spec.md overview>",
  "branchName": "<from prompt>",
  "sprint": "<from prompt>",
  "priority": "<integer from backlog>",
  "depends_on": "<from backlog entry>",
  "status": "active",
  "spec": {
    "scope": "<from spec.md scope statement>",
    "preserved_invariants": ["<from spec.md success criteria / constraints>"],
    "out_of_scope": ["<from spec.md non-goals>"]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "<imperative title>",
      "context": "<self-contained — 3-6 sentences>",
      "scope": ["<real file paths>"],
      "acceptance": "<single sentence>",
      "checks": ["<binary shell expressions>"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
```
