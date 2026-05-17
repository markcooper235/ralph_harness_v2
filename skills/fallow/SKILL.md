---
name: fallow
description: "Run the Ralph fallow code-quality gate on the active or named story. Checks dead code, unused exports, duplicates, and complexity. Triggers on: run fallow, fallow check, fallow gate, code quality gate, fallow audit, clean up dead code."
---

# Fallow Code-Quality Gate

Run `ralph-fallow.sh` to audit and auto-fix code quality issues for a story's changed files.

## Non-Negotiables

- Fallow runs automatically after all tasks pass in `ralph-story-run.sh`. Only invoke manually to debug or re-run.
- Scope is limited to the story's `spec.scope` files — not the whole codebase.
- Do not mark a story done if fallow exits non-zero.
- Never skip fallow silently; use `--dry-run` to inspect issues without failing.

## When Fallow Fires

### Automatic (normal flow)
`ralph-story-run.sh` calls fallow after all story tasks pass, before marking the story done.
If fallow fails, the story is blocked — `ralph-story-run.sh` exits 1.

### Manual (debug / re-run)
```bash
./scripts/ralph/ralph-fallow.sh
./scripts/ralph/ralph-fallow.sh --story scripts/ralph/sprints/sprint-1/stories/S-001/story.json
./scripts/ralph/ralph-fallow.sh --dry-run
./scripts/ralph/ralph-fallow.sh --no-autofix
```

## Three-Phase Flow

```
Phase 1 — Audit
  └── fallow audit --format json  (JS/TS projects with fallow installed)
  └── eslint / flake8 / go vet / rubocop / cargo clippy  (language fallbacks)
  └── grep heuristics  (last resort: unused imports, console.log, TODOs)
  └── Scope: files listed in story.json spec.scope + task scope arrays

Phase 2 — Auto-fix  (skipped with --no-autofix)
  └── fallow fix --yes  (removes unused exports, dead deps)
  └── Codex session: fixes remaining lint, dead code, complexity issues

Phase 3 — Re-validate
  └── Re-runs Phase 1 audit
  └── Exit 0 = clean   Exit 1 = issues remain → manual correction required
```

## Scope Resolution

Fallow reads the story file to determine which files to analyze:

1. `story.json tasks[].scope[]` — per-task file lists
2. `story.json spec.scope_paths[]` — explicit story-level paths

If no scope is declared, fallow falls back to files changed vs `main`.

## Options

| Flag | Effect |
|------|--------|
| `--story PATH` | Target a specific story.json (default: active story) |
| `--dry-run` | Report issues without auto-fixing or failing |
| `--no-autofix` | Report and fail immediately without attempting fixes |
| `--quiet` | Suppress verbose output |

## Skip in ralph-story-run.sh (debug only)

```bash
./scripts/ralph/ralph-story-run.sh --skip-fallow
```

## Fallow CLI (fallow.tools)

For JS/TS projects, install once for faster analysis:

```bash
npm install -g fallow
```

Without it, language-specific fallbacks (eslint, flake8, etc.) or grep heuristics are used automatically.

## Categories Checked

- **Dead code** — unused files, exports, types, dependencies, circular deps
- **Duplication** — clone groups with 2+ instances
- **Complexity** — high cyclomatic complexity functions
- **Lint** — eslint errors/warnings (JS/TS fallback)
- **Heuristics** — `console.log`, `TODO/FIXME`, unused imports (grep fallback)
