---
name: story-generate
description: "Generate a story.json task container from a story backlog entry. Use when a story exists in stories.json but needs its task container created. Triggers on: generate story tasks, create story json, build task container, story generate, generate story."
---

# Story Task Container Generator

Generate a `story.json` task container for a story backlog entry. Called by `ralph-story.sh generate <ID>`.

## Non-Negotiables

- Write the file to the exact absolute path given in the prompt — do not guess or alter the path.
- Every task must have at least one binary-checkable `checks[]` entry.
- `checks[]` entries must be shell expressions that exit 0 on pass, non-zero on fail — no interactive or subjective checks.
- T-03 is always a full-regression task (build + lint + full test suite) and is always last.
- `scope[]` must list real, specific file paths relative to the repo root — no glob patterns.
- `context` must be self-contained: a fresh Codex session reading only that task object must be able to complete the work.
- Do not commit the file — just write it.
- Do not invent file paths that do not exist; read the repo to discover real paths first.

## Story.json Schema

```json
{
  "version": 1,
  "project": "<infer from package.json name field or repo root dir name>",
  "storyId": "<from prompt>",
  "title": "<from prompt>",
  "description": "<1-2 sentence description of what gets delivered>",
  "branchName": "<from prompt>",
  "sprint": "<from prompt>",
  "priority": "<integer — copy from backlog entry>",
  "depends_on": "<copy from backlog entry>",
  "status": "active",
  "spec": {
    "scope": "<1 sentence: which files/areas change>",
    "preserved_invariants": ["<things that must not break>"],
    "out_of_scope": ["<explicit non-goals>"]
  },
  "tasks": [ ... ],
  "passes": false
}
```

## Standard Task Structure

Most stories need exactly three tasks:

**T-01 — Core implementation**
- Implements the source code change
- `scope`: implementation source files only (not test files)
- `checks`: typecheck + lint
- `depends_on`: []

**T-02 — Tests**
- Writes or updates tests for the implementation in T-01
- `scope`: test files only
- `checks`: lint + scoped test runner (e.g., `npm test -- --testPathPattern=MyComponent`)
- `depends_on`: ["T-01"]

**T-03 — Full regression**
- Verifies the whole suite still passes
- `context`: "Run the full build, lint, and test suite. If everything passes, nothing needs to be committed. If issues are found, fix them and commit."
- `scope`: all files changed by T-01 and T-02 combined
- `checks`: build + lint + full test suite
- `depends_on`: ["T-02"]

Add tasks between T-02 and T-03 only when the story has genuinely independent sub-concerns (e.g., API changes and UI changes that need separate sessions).

## Task Context Rules

Each task's `context` field must include:
1. What to change and where (specific file paths and what to add/modify)
2. What behavior to implement (brief, precise spec)
3. Any constraints or invariants to preserve
4. How to verify it worked (correlates to `acceptance`)

Never write "see story description" — context must be fully standalone for an isolated Codex session.

## Checks: Good vs Bad

Good:
```
"grep -q 'priority' src/db/schema.sql"
"test -f migrations/001_add_priority.sql"
"npm run typecheck"
"npm run lint"
"npm test -- --testPathPattern=TaskCard"
"npm run build"
"cargo build"
"go test ./..."
```

Bad:
```
"verify in browser"          — not binary shell
"check that badge is visible" — subjective
"npm test" in T-01            — full suite too broad for an impl task
```

## File Discovery Step

Before writing tasks, read:
1. `package.json` — find the actual script names for typecheck, lint, test, build
2. Source files relevant to the story goal — understand existing structure and naming
3. Existing test file patterns — match the project's test file naming convention

If no `package.json`, adapt checks to the actual build system (Makefile, cargo, go test, etc.).

## Priority

Copy the priority integer from the backlog entry. If not present, use the story's position (1 = highest).
