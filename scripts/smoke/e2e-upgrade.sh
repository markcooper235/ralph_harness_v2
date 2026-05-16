#!/bin/bash
# e2e-upgrade.sh — Legacy install upgrade and sprint migration smoke test
#
# Exercises the paths:
#   1. old main install -> seed legacy epic/PRD data -> upgrade to current branch
#      -> auto-migrate legacy sprint -> auto-recover every recoverable epic
#   2. direct task recovery from live/archived legacy prd.json
#   3. deterministic recovery from a valid legacy PRD markdown without Codex
#   4. temporary prd.json bridge recovery for valid markdown-only legacy PRDs
#   5. guided recovery from preserved markdown when deterministic + bridge fail
#   6. guided recovery from backlog metadata when preserved markdown is missing
#   7. deprecated legacy commands become explicit upgrade stubs
#
# Usage:
#   ./scripts/smoke/e2e-upgrade.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

KEEP=0
BENCH_FILE="$SCRIPT_DIR/.benchmarks/e2e-upgrade.tsv"

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

benchmark_init "upgrade" "migration" "$BENCH_FILE"

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
  local status="pass"
  [ "$code" -eq 0 ] || status="fail"
  benchmark_append_row "$status"
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
    },
    {
      "id": "EPIC-004",
      "title": "Deterministic markdown recovery epic",
      "priority": 4,
      "effort": 2,
      "status": "planned",
      "planningSource": "local",
      "dependsOn": ["EPIC-003"],
      "prdPaths": ["scripts/ralph/tasks/prds/prd-epic-004.md"],
      "goal": "Recover deterministically from a valid legacy PRD markdown",
      "openQuestions": [],
      "promptContext": "Use the preserved PRD markdown directly and do not invoke guided fallback."
    },
    {
      "id": "EPIC-005",
      "title": "Bridge markdown recovery epic",
      "priority": 5,
      "effort": 3,
      "status": "planned",
      "planningSource": "local",
      "dependsOn": ["EPIC-004"],
      "prdPaths": ["scripts/ralph/tasks/prds/prd-epic-005.md"],
      "goal": "Recover a valid markdown-only legacy PRD by bridging through temporary prd.json",
      "openQuestions": [],
      "promptContext": "Prefer prd.json bridge recovery before direct guided story generation."
    },
    {
      "id": "EPIC-006",
      "title": "Missing markdown recovery epic",
      "priority": 6,
      "effort": 1,
      "status": "planned",
      "planningSource": "local",
      "dependsOn": ["EPIC-005"],
      "prdPaths": ["scripts/ralph/tasks/prds/missing-epic-006.md"],
      "goal": "Recover safely when preserved markdown is missing",
      "openQuestions": [],
      "promptContext": "Use backlog metadata when no preserved markdown file is available."
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

cat > "$RALPH_DIR/tasks/prds/prd-epic-004.md" <<'MD'
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

cat > "$RALPH_DIR/tasks/prds/prd-epic-005.md" <<'MD'
# Legacy PRD

## Scope
Recover a valid markdown-only legacy PRD through a temporary prd.json bridge during upgrade smoke.

## Out of Scope
- rewriting the main framework flow

## First Slice Expectations
- exact source: scripts/ralph/tasks/prds/prd-epic-005.md
- destination: scripts/ralph/sprints/sprint-1/stories/S-005/story.json
- entrypoint: ./scripts/ralph/ralph-story.sh generate S-005 --force

## Allowed Supporting Files
- src/bridge-helper.ts
- scripts/ralph/ralph-story.sh

## Preserved Invariants
- Preserve branch naming
- Preserve placeholder-only recovery behavior

## Definition of Done
- npm run typecheck succeeds
- npm test succeeds

## User Stories
#### Story Alpha
**Description:** Rebuild the first portion of the plan from markdown-only legacy content.
**Acceptance Criteria:**
- Typecheck passes
- Tests pass

#### Story Beta
**Description:** Preserve verification context and scope decisions.
**Acceptance Criteria:**
- Lint passes

#### Story Gamma
**Description:** Keep the normal framework path unchanged.
**Acceptance Criteria:**
- Tests pass
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

cat > "$TEST_REPO/mock-codex-auto-recovery.sh" <<'EOF'
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
log_path="$(cd "$(dirname "$0")" && pwd)/mock-codex-auto-recovery.log"
printf '%s' "$prompt" >> "$log_path"
printf '\n---\n' >> "$log_path"

bridge_target="$(printf '%s' "$prompt" | sed -n 's|^Write the temporary prd.json to: ||p' | head -n 1)"
story_target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"

if [[ "$bridge_target" == *"/S-004/"* ]] || [[ "$story_target" == *"/S-004/"* ]]; then
  echo "Codex should not run for deterministic markdown recovery" >&2
  exit 91
fi

if [ -n "$bridge_target" ]; then
  if printf '%s' "$prompt" | grep -q 'ralph/sprint-1/epic-005'; then
    mkdir -p "$(dirname "$bridge_target")"
    cat > "$bridge_target" <<'JSON'
{
  "project": "upgrade-smoke",
  "branchName": "ralph/sprint-1/epic-005",
  "description": "Recovered through temporary prd.json bridge",
  "userStories": [
    {
      "id": "US-001",
      "title": "Bridge task one",
      "description": "Recover the first portion of the plan",
      "acceptanceCriteria": ["Typecheck passes", "Tests pass"],
      "scopePaths": ["src/bridge-helper.ts"],
      "priority": 1,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Bridge task two",
      "description": "Preserve verification context",
      "acceptanceCriteria": ["Lint passes", "Typecheck passes"],
      "scopePaths": ["scripts/ralph/ralph-story.sh"],
      "priority": 2,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Bridge task three",
      "description": "Keep the normal framework path unchanged",
      "acceptanceCriteria": ["Tests pass", "Typecheck passes"],
      "scopePaths": ["scripts/ralph/ralph-status.sh"],
      "priority": 3,
      "passes": false,
      "notes": ""
    }
  ]
}
JSON
    exit 0
  fi
  echo "temporary prd.json bridge intentionally unsupported for this story" >&2
  exit 95
fi

[ -n "$story_target" ] || { echo "Expected recovery target in prompt" >&2; exit 94; }
mkdir -p "$(dirname "$story_target")"

if [[ "$story_target" == *"/S-003/"* ]]; then
  cat > "$story_target" <<'JSON'
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
  exit 0
fi

if [[ "$story_target" == *"/S-006/"* ]]; then
  printf '%s' "$prompt" > "$(cd "$(dirname "$0")" && pwd)/mock-codex-missing-markdown.prompt"
  cat > "$story_target" <<'JSON'
{
  "version": 1,
  "project": "upgrade-smoke",
  "storyId": "S-006",
  "title": "Missing markdown recovery epic",
  "description": "Recovered from backlog metadata",
  "branchName": "ralph/sprint-1/epic-006",
  "sprint": "sprint-1",
  "priority": 6,
  "depends_on": ["S-005"],
  "status": "planned",
  "spec": {
    "scope": "Recovered when markdown was unavailable",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": []
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Backlog metadata recovery task",
      "context": "Use goal and prompt context to recover the plan",
      "scope": ["src/missing-markdown.ts"],
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
  exit 0
fi

echo "Unexpected automatic recovery prompt" >&2
exit 96
EOF
chmod +x "$TEST_REPO/mock-codex-auto-recovery.sh"

log "upgrading framework to current branch"
CODEX_BIN="$TEST_REPO/mock-codex-auto-recovery.sh" bash "$REPO_ROOT/install.sh" --project "$TEST_REPO" > "$WORK_DIR/install-upgrade.log" 2>&1

STORIES_FILE="$RALPH_DIR/sprints/sprint-1/stories.json"
STORY_ONE="$RALPH_DIR/sprints/sprint-1/stories/S-001/story.json"
STORY_TWO="$RALPH_DIR/sprints/sprint-1/stories/S-002/story.json"
STORY_THREE="$RALPH_DIR/sprints/sprint-1/stories/S-003/story.json"
STORY_FOUR="$RALPH_DIR/sprints/sprint-1/stories/S-004/story.json"
STORY_FIVE="$RALPH_DIR/sprints/sprint-1/stories/S-005/story.json"
STORY_SIX="$RALPH_DIR/sprints/sprint-1/stories/S-006/story.json"

assert_file_exists "$STORIES_FILE"
assert_file_exists "$STORY_ONE"
assert_file_exists "$STORY_TWO"
assert_file_exists "$STORY_THREE"
assert_file_exists "$STORY_FOUR"
assert_file_exists "$STORY_FIVE"
assert_file_exists "$STORY_SIX"

assert_json_expr "$STORIES_FILE" '.status == "active"'
assert_json_expr "$STORIES_FILE" '.activeStoryId == "S-001"'
assert_json_expr "$STORIES_FILE" '.stories | length == 6'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-002") | .depends_on == ["S-001"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-003") | .depends_on == ["S-002"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-004") | .depends_on == ["S-003"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-005") | .depends_on == ["S-004"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-006") | .depends_on == ["S-005"]'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-003") | .status == "planned"'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-004") | .status == "planned"'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-005") | .status == "planned"'
assert_json_expr "$STORIES_FILE" '.stories[] | select(.id == "S-006") | .status == "planned"'

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

assert_json_expr "$STORY_THREE" '.migration.source == "legacy-placeholder-guided-recovery"'
assert_json_expr "$STORY_THREE" '.migration.tasks_recovered == true'
assert_json_expr "$STORY_THREE" '.migration.recoveryMode == "guided-codex-fallback"'
assert_json_expr "$STORY_THREE" '.migration.recoveryWarnings | length >= 2'
assert_json_expr "$STORY_THREE" '.status == "planned"'
assert_json_expr "$STORY_THREE" '.tasks | length == 1'
assert_json_expr "$STORY_THREE" '.tasks[0].title == "Guided migration recovery task"'
assert_json_expr "$STORY_THREE" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-003.md"'
assert_json_expr "$STORY_THREE" '.spec.verification | any(. == "Legacy migration fallback recovery used guided generation; review task scope and acceptance checks before execution.")'
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
assert_file_exists "$STORY_FIVE"
assert_json_expr "$STORY_FIVE" '.migration.source == "legacy-prd-json-bridge"'
assert_json_expr "$STORY_FIVE" '.migration.tasks_recovered == true'
assert_json_expr "$STORY_FIVE" '.migration.recoveryMode == "guided-prd-json-bridge"'
assert_json_expr "$STORY_FIVE" '.branchName == "ralph/sprint-1/epic-005"'
assert_json_expr "$STORY_FIVE" '.spec.prdRef == "scripts/ralph/tasks/prds/prd-epic-005.md"'
assert_json_expr "$STORY_FIVE" '.tasks | length == 3'
assert_json_expr "$STORY_FIVE" '.tasks[0].title == "Bridge task one"'
assert_json_expr "$STORY_FIVE" '.tasks[1].depends_on == ["T-01"]'
assert_json_expr "$STORY_FIVE" '.tasks[2].depends_on == ["T-02"]'
assert_json_expr "$STORY_FIVE" '(.tasks[0].checks | sort) == (["npm run typecheck", "npm test"] | sort)'
assert_json_expr "$STORY_FIVE" '(.tasks[1].checks | sort) == (["npm run lint", "npm run typecheck"] | sort)'
assert_json_expr "$STORY_FIVE" '(.tasks[2].checks | sort) == (["npm run typecheck", "npm test"] | sort)'
assert_json_expr "$STORY_FIVE" '.spec.verification | any(. == "Legacy migration used a temporary prd.json bridge; review generated tasks and acceptance checks before execution.")'
assert_file_exists "$STORY_SIX"
assert_json_expr "$STORY_SIX" '.migration.source == "legacy-placeholder-guided-recovery"'
assert_json_expr "$STORY_SIX" '.migration.tasks_recovered == true'
assert_json_expr "$STORY_SIX" '.migration.recoveryMode == "guided-codex-fallback"'
assert_json_expr "$STORY_SIX" '.branchName == "ralph/sprint-1/epic-006"'
assert_json_expr "$STORY_SIX" '.spec.prdRef == "scripts/ralph/tasks/prds/missing-epic-006.md"'
assert_json_expr "$STORY_SIX" '.tasks | length == 1'
assert_json_expr "$STORY_SIX" '.tasks[0].title == "Backlog metadata recovery task"'
assert_json_expr "$STORY_SIX" '.spec.verification | any(. == "Legacy migration fallback recovery used guided generation; review task scope and acceptance checks before execution.")'
assert_json_expr "$STORY_SIX" '.migration.recoveryWarnings | any(test("markdown was unavailable"))'
if ! grep -q "Primary source markdown unavailable" "$TEST_REPO/mock-codex-missing-markdown.prompt"; then
  fail "expected missing-markdown guidance in S-006 recovery prompt"
fi

if grep -q 'S-004' "$TEST_REPO/mock-codex-auto-recovery.log"; then
  fail "did not expect Codex to run during deterministic recovery for S-004"
fi
if ! grep -q "Auto-recovering 4 migrated placeholder stories" "$WORK_DIR/install-upgrade.log"; then
  fail "expected install-time migration to auto-recover all placeholder stories"
fi
if ! grep -q "Recovered migration placeholder for S-003; story status reset to planned" "$WORK_DIR/install-upgrade.log"; then
  fail "expected automatic guided recovery for S-003 during migration"
fi
if ! grep -q "Recovered migration placeholder for S-004 from legacy PRD markdown" "$WORK_DIR/install-upgrade.log"; then
  fail "expected automatic deterministic recovery for S-004 during migration"
fi
if ! grep -q "Recovered migration placeholder for S-005 through temporary prd.json bridge" "$WORK_DIR/install-upgrade.log"; then
  fail "expected automatic prd.json bridge recovery for S-005 during migration"
fi
if ! grep -q "Recovered migration placeholder for S-006; story status reset to planned" "$WORK_DIR/install-upgrade.log"; then
  fail "expected automatic missing-markdown recovery for S-006 during migration"
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

benchmark_set_tokens 0
benchmark_set_stories 0
benchmark_set_notes "migration-validation"
log "PASS: legacy upgrade migration auto-recovered every recovery path"
