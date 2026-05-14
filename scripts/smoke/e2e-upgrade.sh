#!/bin/bash
# e2e-upgrade.sh — Legacy install upgrade and sprint migration smoke test
#
# Exercises the paths:
#   1. old main install -> seed legacy epic/PRD data -> upgrade to current branch
#      -> auto-migrate legacy sprint -> verify distinct story/task recovery
#   2. markdown-only legacy epic fallback -> blocked placeholder story
#   3. deterministic recovery from a valid legacy PRD markdown without Codex
#   4. deprecated legacy commands become explicit upgrade stubs
#
# Usage:
#   ./scripts/smoke/e2e-upgrade.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"

KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log()  { echo "[upgrade-smoke] $*"; }
fail() { echo "[upgrade-smoke] FAIL: $*" >&2; exit 1; }

resolve_legacy_ref() {
  local ref
  for ref in main origin/main master origin/master; do
    if git -C "$REPO_ROOT" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

WORK_DIR="$(mktemp -d /tmp/ralph-upgrade-smoke.XXXXXX)"
LEGACY_SRC="$WORK_DIR/legacy-src"
TEST_REPO="$WORK_DIR/project"
MAIN_REF="$(resolve_legacy_ref || true)"

cleanup() {
  local code=$?
  if [ "$KEEP" -eq 1 ] || [ "$code" -ne 0 ]; then
    echo "[upgrade-smoke] work dir retained: $WORK_DIR"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[ -n "$MAIN_REF" ] || fail "Could not resolve a legacy base ref (tried main/origin/main/master/origin/master)."

log "using legacy ref: $MAIN_REF"
mkdir -p "$LEGACY_SRC" "$TEST_REPO"
git -C "$REPO_ROOT" archive --format=tar "$MAIN_REF" | tar -xf - -C "$LEGACY_SRC"

git -C "$TEST_REPO" init -b main >/dev/null
git -C "$TEST_REPO" config user.name "Ralph Upgrade Smoke"
git -C "$TEST_REPO" config user.email "ralph-upgrade-smoke@example.com"
printf '# upgrade smoke\n' > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -m "init" >/dev/null

log "installing legacy framework snapshot"
bash "$LEGACY_SRC/install.sh" --project "$TEST_REPO" > "$WORK_DIR/install-legacy.log" 2>&1

RALPH_DIR="$TEST_REPO/scripts/ralph"
mkdir -p \
  "$RALPH_DIR/tasks/prds" \
  "$RALPH_DIR/tasks/archive/sprint-1/2026-01-15-epic-001" \
  "$RALPH_DIR/tasks/archive/sprint-1/2026-01-16-epic-002"

cat > "$RALPH_DIR/sprints/sprint-1/epics.json" <<'JSON'
{
  "version": 1,
  "project": "upgrade-smoke",
  "sprint": "sprint-1",
  "capacityTarget": 8,
  "capacityCeiling": 10,
  "activeEpicId": "EPIC-001",
  "epics": [
    {
      "id": "EPIC-001",
      "title": "Current active epic",
      "priority": 1,
      "effort": 3,
      "status": "active",
      "planningSource": "local",
      "dependsOn": [],
      "prdPaths": ["scripts/ralph/tasks/prds/prd-epic-001.md"],
      "goal": "Migrate the current active epic",
      "openQuestions": [],
      "promptContext": "active context"
    },
    {
      "id": "EPIC-002",
      "title": "Archived completed epic",
      "priority": 2,
      "effort": 2,
      "status": "done",
      "planningSource": "local",
      "dependsOn": ["EPIC-001"],
      "prdPaths": ["scripts/ralph/tasks/prds/prd-epic-002.md"],
      "goal": "Migrate an archived legacy epic",
      "openQuestions": [],
      "promptContext": "archived context"
    },
    {
      "id": "EPIC-003",
      "title": "Markdown-only epic",
      "priority": 3,
      "effort": 1,
      "status": "planned",
      "planningSource": "local",
      "dependsOn": ["EPIC-002"],
      "prdPaths": ["scripts/ralph/tasks/prds/prd-epic-003.md"],
      "goal": "Migrate a markdown-only legacy epic safely",
      "openQuestions": [],
      "promptContext": "markdown-only context"
    }
  ]
}
JSON

cat > "$RALPH_DIR/tasks/prds/prd-epic-001.md" <<'MD'
# Active Epic PRD
MD

cat > "$RALPH_DIR/tasks/prds/prd-epic-002.md" <<'MD'
# Archived Epic PRD
MD

cat > "$RALPH_DIR/tasks/prds/prd-epic-003.md" <<'MD'
# Markdown-only Epic PRD
MD

cat > "$RALPH_DIR/.active-prd" <<'JSON'
{
  "mode": "epic",
  "epicId": "EPIC-001",
  "baseBranch": "ralph/sprint/sprint-1",
  "sourcePath": "scripts/ralph/tasks/prds/prd-epic-001.md"
}
JSON

cat > "$RALPH_DIR/prd.json" <<'JSON'
{
  "project": "upgrade-smoke",
  "branchName": "ralph/sprint-1/epic-001",
  "description": "Live PRD for EPIC-001",
  "userStories": [
    {
      "id": "US-001",
      "title": "Active task",
      "description": "Implement the active task",
      "acceptanceCriteria": ["Typecheck passes", "Tests pass"],
      "scopePaths": ["src/active.ts"],
      "passes": false
    }
  ]
}
JSON

cat > "$RALPH_DIR/tasks/archive/sprint-1/2026-01-15-epic-001/prd.json" <<'JSON'
{
  "project": "upgrade-smoke",
  "branchName": "ralph/sprint-1/epic-001",
  "description": "Archived PRD for EPIC-001",
  "userStories": [
    {
      "id": "US-001",
      "title": "Old active task",
      "description": "Outdated archived task",
      "acceptanceCriteria": ["Typecheck passes"],
      "scopePaths": ["src/old-active.ts"],
      "passes": true
    }
  ]
}
JSON

cat > "$RALPH_DIR/tasks/archive/sprint-1/2026-01-16-epic-002/prd.json" <<'JSON'
{
  "project": "upgrade-smoke",
  "branchName": "ralph/sprint-1/epic-002",
  "description": "Archived PRD for EPIC-002",
  "userStories": [
    {
      "id": "US-002",
      "title": "Archived task",
      "description": "Implement the archived task",
      "acceptanceCriteria": ["Lint passes", "Tests pass"],
      "scopePaths": ["src/archived.ts"],
      "passes": true
    }
  ]
}
JSON

git -C "$TEST_REPO" add scripts/ralph
git -C "$TEST_REPO" commit -m "seed legacy sprint state" >/dev/null

log "upgrading framework to current branch"
bash "$REPO_ROOT/install.sh" --project "$TEST_REPO" > "$WORK_DIR/install-upgrade.log" 2>&1

STORIES_FILE="$RALPH_DIR/sprints/sprint-1/stories.json"
STORY_ONE="$RALPH_DIR/sprints/sprint-1/stories/S-001/story.json"
STORY_TWO="$RALPH_DIR/sprints/sprint-1/stories/S-002/story.json"
STORY_THREE="$RALPH_DIR/sprints/sprint-1/stories/S-003/story.json"

assert_file_exists "$STORIES_FILE"
assert_file_exists "$STORY_ONE"
assert_file_exists "$STORY_TWO"
assert_file_exists "$STORY_THREE"

assert_json_expr "$STORIES_FILE" '.status == "active"'
assert_json_expr "$STORIES_FILE" '.activeStoryId == "S-001"'
assert_json_expr "$STORIES_FILE" '.stories | length == 3'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-002") | .depends_on == ["S-001"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-003") | .depends_on == ["S-002"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-003") | .status == "blocked"'

assert_json_expr "$STORY_ONE" '.branchName == "ralph/sprint-1/epic-001"'
assert_json_expr "$STORY_ONE" '.tasks | length == 1'
assert_json_expr "$STORY_ONE" '.tasks[0].title == "Active task"'
assert_json_expr "$STORY_ONE" '.tasks[0].scope == ["src/active.ts"]'
assert_json_expr "$STORY_ONE" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-001.md"'
assert_json_expr "$STORY_ONE" '(.tasks[0].checks | sort) == (["npm run typecheck", "npm test"] | sort)'

assert_json_expr "$STORY_TWO" '.branchName == "ralph/sprint-1/epic-002"'
assert_json_expr "$STORY_TWO" '.tasks | length == 1'
assert_json_expr "$STORY_TWO" '.tasks[0].title == "Archived task"'
assert_json_expr "$STORY_TWO" '.tasks[0].scope == ["src/archived.ts"]'
assert_json_expr "$STORY_TWO" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-002.md"'
assert_json_expr "$STORY_TWO" '.migration.tasks_recovered == true'
assert_json_expr "$STORY_TWO" '(.tasks[0].checks | sort) == (["npm run lint", "npm test"] | sort)'

assert_json_expr "$STORY_THREE" '.status == "blocked"'
assert_json_expr "$STORY_THREE" '.tasks | length == 1'
assert_json_expr "$STORY_THREE" '.tasks[0].title == "Recover legacy story plan"'
assert_json_expr "$STORY_THREE" '.migration.tasks_recovered == false'
assert_json_expr "$STORY_THREE" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-003.md"'
assert_json_expr "$STORY_THREE" '.tasks[0].context | test("generate S-003 --force")'

cat > "$TEST_REPO/mock-codex-fallback.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "--yolo" ] && [ "${2:-}" = "exec" ] && [ "${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "version": 1,
  "project": "upgrade-smoke",
  "storyId": "S-003",
  "title": "Markdown-only epic",
  "description": "Recovered from guided fallback",
  "branchName": "ralph/sprint-1/epic-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": ["S-002"],
  "status": "planned",
  "spec": {
    "scope": "Recovered from markdown-only legacy context",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": []
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Guided migration recovery task",
      "context": "Recover from preserved goal and prompt context",
      "scope": ["src/markdown-fallback.ts"],
      "acceptance": "Tests pass.",
      "checks": ["npm test"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
EOF
chmod +x "$TEST_REPO/mock-codex-fallback.sh"

(
  cd "$TEST_REPO"
  CODEX_BIN="$TEST_REPO/mock-codex-fallback.sh" ./scripts/ralph/ralph-story.sh generate S-003 --force > "$WORK_DIR/generate-fallback.log" 2>&1
)

assert_json_expr "$STORY_THREE" '.migration.source == "legacy-placeholder-guided-recovery"'
assert_json_expr "$STORY_THREE" '.migration.tasks_recovered == true'
assert_json_expr "$STORY_THREE" '.migration.recoveryMode == "guided-codex-fallback"'
assert_json_expr "$STORY_THREE" '.migration.recoveryWarnings | length >= 2'
assert_json_expr "$STORY_THREE" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-003.md"'
assert_json_expr "$STORY_THREE" '.spec.verification | any(. == "Legacy migration fallback recovery used guided generation; review task scope and acceptance checks before execution.")'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-003") | .status == "planned"'
if ! grep -q "Annotated S-003 with guided migration recovery provenance" "$WORK_DIR/generate-fallback.log"; then
  fail "expected guided fallback provenance annotation during markdown-only recovery"
fi

STORY_FOUR="$RALPH_DIR/sprints/sprint-1/stories/S-004/story.json"
PRD_FOUR_REL="scripts/ralph/tasks/prds/prd-epic-004.md"
PRD_FOUR_ABS="$TEST_REPO/$PRD_FOUR_REL"

cat > "$PRD_FOUR_ABS" <<'MD'
# Legacy PRD

## Scope
Recover a valid legacy PRD deterministically during upgrade smoke.

## Out of Scope
- changing non-placeholder stories

## First Slice Expectations
- exact source: scripts/ralph/tasks/prds/prd-epic-004.md
- destination: scripts/ralph/sprints/sprint-1/stories/S-004/story.json
- entrypoint: ./scripts/ralph/ralph-story.sh generate S-004 --force

## Allowed Supporting Files
- scripts/ralph/ralph-story.sh
- __tests__/ralph-run-state.test.js

## Preserved Invariants
- Keep branch names stable
- Keep migration placeholder recovery isolated

## Definition of Done
- npm run typecheck succeeds
- npm test succeeds
- npm run lint succeeds

## User Stories
### Story 1: Rebuild the task container
Create a deterministic story plan from the preserved markdown and write scripts/ralph/sprints/sprint-1/stories/S-004/story.json.
Acceptance Criteria
- story.json includes migration metadata
- npm run typecheck succeeds

Proof Obligations
- npm test succeeds

### Story 2: Preserve verification context
Keep preserved verification context accurate in scripts/ralph/ralph-story.sh.
Acceptance Criteria
- npm run lint succeeds

### Story 3: Protect the normal framework flow
Ensure non-placeholder generation behavior remains unchanged in __tests__/ralph-run-state.test.js.
Acceptance Criteria
- npm test succeeds
MD

tmp_json="$(mktemp)"
jq '
  .stories += [{
    "id": "S-004",
    "title": "Deterministic markdown recovery epic",
    "priority": 4,
    "effort": 2,
    "planningSource": "local",
    "status": "blocked",
    "depends_on": ["S-003"],
    "story_path": "scripts/ralph/sprints/sprint-1/stories/S-004/story.json",
    "goal": "Recover deterministically from a valid legacy PRD markdown",
    "promptContext": "Use the preserved PRD markdown directly and do not invoke guided fallback."
  }]
' "$STORIES_FILE" > "$tmp_json"
mv "$tmp_json" "$STORIES_FILE"

mkdir -p "$(dirname "$STORY_FOUR")"
cat > "$STORY_FOUR" <<JSON
{
  "version": 1,
  "project": "upgrade-smoke",
  "storyId": "S-004",
  "title": "Deterministic markdown recovery epic",
  "description": "Recover deterministically from a valid legacy PRD markdown",
  "branchName": "ralph/sprint-1/epic-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-003"],
  "status": "blocked",
  "spec": {
    "scope": "Recover deterministically from a valid legacy PRD markdown",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": ["Migration placeholder only; regenerate story plan before running this story."],
    "prdRef": "$PRD_FOUR_REL"
  },
  "migration": {
    "source": "legacy-epic",
    "tasks_recovered": false
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Recover legacy story plan",
      "context": "Legacy migration could not recover task-level data.",
      "scope": [],
      "acceptance": "Regenerate before execution.",
      "checks": ["test -n \"legacy-migration-placeholder\""],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON

cat > "$TEST_REPO/mock-codex-deterministic.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Codex should not run for deterministic markdown recovery" >&2
exit 91
EOF
chmod +x "$TEST_REPO/mock-codex-deterministic.sh"

(
  cd "$TEST_REPO"
  CODEX_BIN="$TEST_REPO/mock-codex-deterministic.sh" ./scripts/ralph/ralph-story.sh generate S-004 --force > "$WORK_DIR/generate-deterministic.log" 2>&1
)

assert_file_exists "$STORY_FOUR"
assert_json_expr "$STORY_FOUR" '.migration.source == "legacy-prd-markdown"'
assert_json_expr "$STORY_FOUR" '.migration.tasks_recovered == true'
assert_json_expr "$STORY_FOUR" '.branchName == "ralph/sprint-1/epic-004"'
assert_json_expr "$STORY_FOUR" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-004.md"'
assert_json_expr "$STORY_FOUR" '.tasks | length == 3'
assert_json_expr "$STORY_FOUR" '.tasks[0].title == "Rebuild the task container"'
assert_json_expr "$STORY_FOUR" '.tasks[1].depends_on == ["T-01"]'
assert_json_expr "$STORY_FOUR" '.tasks[2].depends_on == ["T-02"]'
assert_json_expr "$STORY_FOUR" '(.tasks[0].checks | sort) == (["npm run typecheck", "npm test"] | sort)'
assert_json_expr "$STORY_FOUR" '.tasks[1].checks == ["npm run lint"]'
assert_json_expr "$STORY_FOUR" '.tasks[2].checks == ["npm test"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-004") | .status == "planned"'
if ! grep -q "Recovered migration placeholder for S-004 from legacy PRD markdown" "$WORK_DIR/generate-deterministic.log"; then
  fail "expected deterministic markdown recovery log for S-004"
fi
if grep -q "guided generation" "$WORK_DIR/generate-deterministic.log"; then
  fail "did not expect guided fallback during deterministic markdown recovery"
fi

assert_file_exists "$RALPH_DIR/ralph-prd.sh"
assert_file_exists "$RALPH_DIR/ralph-prime.sh"
assert_file_exists "$RALPH_DIR/ralph-epic.sh"
if ! grep -q "This legacy Ralph command has been removed" "$RALPH_DIR/ralph-prd.sh"; then
  fail "expected deprecated legacy command stub at scripts/ralph/ralph-prd.sh"
fi
if ! grep -q "Migrating legacy sprint: sprint-1" "$WORK_DIR/install-upgrade.log"; then
  fail "expected install --migrate-legacy to run migration automatically"
fi

log "PASS: legacy upgrade migration recovered distinct data and safe fallbacks"
