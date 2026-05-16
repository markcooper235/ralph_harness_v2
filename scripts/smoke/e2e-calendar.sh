#!/bin/bash
# e2e-calendar.sh — Full end-to-end Calendar + Todo app smoke test (multi-sprint)
#
# Exercises the complete Ralph lifecycle for two real framework projects across
# two consecutive sprints, validating multi-sprint operation end-to-end.
#
#   nextjs-calendar  — Real Next.js project (create-next-app) with Jest.
#                      Sprint 1: Domain services in lib/. Tests in __tests__/.
#                      Sprint 2: React components in components/. @testing-library/react.
#   angular-calendar — Real Angular project (ng new) with Jest via ts-jest.
#                      Sprint 1: Services in src/app/services/. Tests as *.spec.ts.
#                      Sprint 2: Standalone components in src/app/components/. Class-only tests.
#
# Full lifecycle under test:
#   install.sh → doctor.sh → ralph-sprint.sh create → ralph-story.sh add →
#   (story.json: framework-imported default | Codex-generated --generated) →
#   ralph-story.sh prepare-all → ralph-sprint.sh use → ralph.sh → ralph-status.sh →
#   ralph-sprint-commit.sh → [sprint 2 setup] → ralph.sh → ralph-sprint-commit.sh →
#   ralph-verify.sh
#
# Sprint 1 stories (domain layer — both projects):
#   S-001: Core types / data models
#   S-002: Calendar service                 (depends on S-001)
#   S-003: Todo service                     (depends on S-001)
#   S-004: Barrel/module wiring + integration test (depends on S-001, S-002, S-003)
#
# Sprint 2 stories (UI layer — both projects):
#   S-001: CalendarView / CalendarComponent  (depends on sprint-1 types)
#   S-002: TodoList / TodoListComponent      (depends on S-001)
#   S-003: EventForm / EventFormComponent    (depends on S-001)
#   S-004: App integration (CalendarApp / AppComponent with signals) (depends on S-001–S-003)
#
# Sprint 2 is skipped per-project if sprint 1 did not commit successfully.
#
# Usage:
#   ./scripts/smoke/e2e-calendar.sh [--keep] [--max-retries N] [--generated]
#
# Flags:
#   --keep          Keep work directory on success (always kept on failure)
#   --max-retries N Retry count per task (default: 2)
#   --generated     Use ralph-story.sh generate for story.json instead of
#                   hand-written files — exercises the full story generation
#                   pipeline (adds ~8 Codex sessions total)
#
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# macOS does not ship 'timeout'; provide a portable fallback
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { local t=$1; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$t" "$@"; }
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/assert.sh"
# shellcheck source=./lib/token-parser.sh
source "$SCRIPT_DIR/lib/token-parser.sh"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-calendar.tsv"
CODEX_BIN_VALUE="${CODEX_BIN:-codex}"

KEEP=0
MAX_RETRIES=2
GENERATED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)         KEEP=1; shift ;;
    --max-retries)  MAX_RETRIES="${2:-2}"; shift 2 ;;
    --generated)    GENERATED=1; shift ;;
    -h|--help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

BENCH_MODE="default"
[ "$GENERATED" -eq 1 ] && BENCH_MODE="generated"
benchmark_init "calendar" "$BENCH_MODE" "$BENCH_FILE"

WORK_DIR="$(mktemp -d /tmp/ralph-calendar-smoke.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

NEXTJS_DIR="$WORK_DIR/nextjs-calendar"
ANGULAR_DIR="$WORK_DIR/angular-calendar"

# ── Cleanup ────────────────────────────────────────────────────────────────────

cleanup() {
  local code=$?
  local status="pass"
  [ "$code" -eq 0 ] || status="fail"
  if [ "${BENCHMARK_TOKENS:-0}" -eq 0 ]; then
    benchmark_set_notes "tokens-unavailable"
  fi
  benchmark_append_row "$status"
  if [ "$KEEP" -eq 1 ] || [ "$code" -ne 0 ]; then
    echo ""
    echo "[smoke] work dir retained for inspection: $WORK_DIR"
    echo "  nextjs:   $NEXTJS_DIR"
    echo "  angular:  $ANGULAR_DIR"
    echo "  logs:     $LOG_DIR"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# Commit any staged or unstaged changes (used for framework baseline commits)
commit_baseline() {
  local repo="$1"
  local msg="$2"
  (
    cd "$repo"
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "$msg" >/dev/null
    fi
  )
}

# ── doctor_check ───────────────────────────────────────────────────────────────
# Run doctor.sh after install. Accepts a missing 'specify' CLI (not used in the
# smoke test), but fails on any other diagnostic error (missing codex, jq, etc).

doctor_check() {
  local proj_dir="$1"
  local proj_label="$2"
  local dlog="$LOG_DIR/${proj_label}-doctor.log"
  log "  Running doctor.sh..."
  if (cd "$proj_dir/scripts/ralph" && CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh) > "$dlog" 2>&1; then
    log "  doctor.sh PASS"
  elif grep -q "specify.*CLI not found\|specify.*not found" "$dlog" 2>/dev/null; then
    log "  doctor.sh WARN: specify CLI not available (expected — not used in smoke test)"
  else
    cat "$dlog" >&2
    fail "doctor.sh failed for $proj_label — see $dlog"
  fi
}

# ── generate_stories ───────────────────────────────────────────────────────────
# Call ralph-story.sh generate for all 4 stories in parallel.
# Codex generates story.json task plans from the story specs in stories.json.
# All 4 run in parallel since no done_notes exist yet (dep context is empty).

generate_stories() {
  local proj_dir="$1"
  local proj_label="$2"
  local ralph_dir="$proj_dir/scripts/ralph"

  log "  Generating story.json files via ralph-story.sh generate (parallel)..."

  local sids=(S-001 S-002 S-003 S-004)
  local pids=() glogs=()

  for sid in "${sids[@]}"; do
    local glog="$LOG_DIR/${proj_label}-generate-${sid}.log"
    glogs+=("$glog")
    ( cd "$ralph_dir" && CODEX_BIN="$CODEX_BIN_VALUE" ./ralph-story.sh generate "$sid" ) \
      > "$glog" 2>&1 &
    pids+=($!)
  done

  local failed=0 i=0
  for pid in "${pids[@]}"; do
    local sid="${sids[$i]}" glog="${glogs[$i]}"
    if wait "$pid"; then
      local story_path="$ralph_dir/sprints/sprint-1/stories/$sid/story.json"
      if [ ! -f "$story_path" ]; then
        log "  FAIL: generate $sid wrote no story.json"
        failed=$((failed + 1))
      elif ! jq -e '.tasks | length > 0' "$story_path" >/dev/null 2>&1; then
        log "  FAIL: generate $sid produced story.json with no tasks"
        failed=$((failed + 1))
      else
        log "  generated $sid ($(jq '.tasks | length' "$story_path") tasks)"
      fi
    else
      log "  FAIL: generate $sid — see $glog"
      failed=$((failed + 1))
    fi
    i=$((i + 1))
  done

  [ "$failed" -eq 0 ] \
    || fail "Story generation failed for $proj_label ($failed of ${#sids[@]} stories)"
}

# ── run_sprint_commit ──────────────────────────────────────────────────────────
# Run ralph-sprint-commit.sh for a project. Asserts sprint is closed and
# .active-sprint is cleared after the commit.

run_sprint_commit() {
  local proj_dir="$1"
  local proj_label="$2"
  local sprint="${3:-sprint-1}"
  local clog="$LOG_DIR/${proj_label}-${sprint}-commit.log"

  log "  Running ralph-sprint-commit.sh for $proj_label ($sprint)..."
  if ! (cd "$proj_dir/scripts/ralph" && ./ralph-sprint-commit.sh) > "$clog" 2>&1; then
    cat "$clog" >&2
    fail "ralph-sprint-commit.sh failed for $proj_label ($sprint) — see $clog"
  fi

  # Assert sprint is now closed in stories.json
  local stories_file="$proj_dir/scripts/ralph/sprints/$sprint/stories.json"
  local sprint_status
  sprint_status="$(jq -r '.status // "unknown"' "$stories_file" 2>/dev/null || echo "unknown")"
  [ "$sprint_status" = "closed" ] \
    || fail "$proj_label $sprint: expected stories.json status=closed, got '$sprint_status'"

  # Assert .active-sprint has been cleared
  local active_file="$proj_dir/scripts/ralph/.active-sprint"
  if [ -f "$active_file" ] && [ -n "$(cat "$active_file")" ]; then
    fail "$proj_label sprint-commit: .active-sprint was not cleared after commit"
  fi

  log "  sprint-commit PASS ($sprint status=closed, active-sprint cleared)"
}

# ── Validation helpers ─────────────────────────────────────────────────────────

validate_story() {
  local story_file="$1"
  local story_id
  story_id="$(jq -r '.storyId' "$story_file")"

  # Required top-level fields
  jq -e '.storyId and .title and .tasks and .sprint' "$story_file" > /dev/null \
    || fail "[$story_id] story.json missing required top-level fields"

  # Each task has checks
  local bad_tasks
  bad_tasks="$(jq -r '.tasks[] | select((.checks | length) == 0) | .id' "$story_file")"
  [ -z "$bad_tasks" ] || fail "[$story_id] tasks with no checks: $bad_tasks"

  # No empty check strings
  local empty_checks
  empty_checks="$(jq -r '.tasks[] | .id as $t | .checks[] | select(length == 0) | $t' "$story_file")"
  [ -z "$empty_checks" ] || fail "[$story_id] empty check strings in tasks: $empty_checks"

  # depends_on T-IDs exist in the same story
  local all_ids
  all_ids="$(jq -r '.tasks[].id' "$story_file")"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    echo "$all_ids" | grep -qxF "$dep" \
      || fail "[$story_id] task depends_on '$dep' which does not exist in story"
  done < <(jq -r '.tasks[].depends_on[]?' "$story_file")
}

validate_sprint() {
  local ralph_dir="$1"
  local sprint="$2"
  local stories_file="$ralph_dir/sprints/$sprint/stories.json"

  [ -f "$stories_file" ] || fail "stories.json not found: $stories_file"
  jq -e '.' "$stories_file" > /dev/null || fail "stories.json is invalid JSON"

  # Validate story-level depends_on references exist
  local all_story_ids
  all_story_ids="$(jq -r '.stories[].id' "$stories_file")"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    echo "$all_story_ids" | grep -qxF "$dep" \
      || fail "story depends_on '$dep' which is not in stories.json"
  done < <(jq -r '.stories[].depends_on[]?' "$stories_file" 2>/dev/null)

  # Validate each story.json
  while IFS= read -r story_path; do
    [ -z "$story_path" ] && continue
    local abs_path
    abs_path="$(git -C "$(dirname "$ralph_dir")" rev-parse --show-toplevel 2>/dev/null || dirname "$ralph_dir")"
    abs_path="$abs_path/$story_path"
    [ -f "$abs_path" ] || abs_path="$story_path"
    [ -f "$abs_path" ] || fail "story.json not found: $story_path"
    validate_story "$abs_path"
    log "  validated: $(basename "$(dirname "$abs_path")")/story.json"
  done < <(jq -r '.stories[].story_path' "$stories_file")
}

# ── prepare_and_activate ───────────────────────────────────────────────────────
# Reset the sprint and its stories to "planned", run ralph-story.sh prepare-all
# (specify-all + generate-all + health + promote), then activate via
# ralph-sprint.sh use. Exercises the full planned → ready → active lifecycle
# path that ralph-sprint.sh create bypasses.

prepare_and_activate() {
  local proj_dir="$1"
  local proj_label="$2"
  local sprint="${3:-sprint-1}"
  local ralph_dir="$proj_dir/scripts/ralph"
  local sf="$ralph_dir/sprints/$sprint/stories.json"

  log "  Resetting $proj_label $sprint to 'planned' for lifecycle coverage..."
  (
    cd "$proj_dir"
    "$ralph_dir/ralph-sprint.sh" restage "$sprint"
    git add "$sf"
    git diff --cached --quiet \
      || git commit -m "chore(ralph): reset $sprint to planned for lifecycle test" --quiet
  )

  local palog="$LOG_DIR/${proj_label}-${sprint}-prepare-all.log"
  log "  Running prepare-all for $proj_label $sprint..."
  if ! (cd "$ralph_dir" && ./ralph-story.sh prepare-all) > "$palog" 2>&1; then
    cat "$palog" >&2
    fail "prepare-all failed for $proj_label $sprint — see $palog"
  fi

  # Commit any prepare-all changes to stories.json before activating
  (
    cd "$proj_dir"
    git add -A "scripts/ralph/sprints/$sprint/"
    git diff --cached --quiet \
      || git commit -m "chore(ralph): prepare-all promote $proj_label $sprint" --quiet
  )

  local ulog="$LOG_DIR/${proj_label}-${sprint}-use.log"
  log "  Activating $proj_label $sprint via 'ralph-sprint.sh use'..."
  if ! (cd "$ralph_dir" && ./ralph-sprint.sh use "$sprint") > "$ulog" 2>&1; then
    cat "$ulog" >&2
    fail "ralph-sprint.sh use failed for $proj_label $sprint — see $ulog"
  fi

  local sprint_status
  sprint_status="$(jq -r '.status // "unknown"' "$sf" 2>/dev/null || echo "unknown")"
  [ "$sprint_status" = "active" ] \
    || fail "$proj_label $sprint: expected status=active after 'use', got '$sprint_status'"
  assert_file_exists "$ralph_dir/.active-sprint"
  log "  $proj_label $sprint: lifecycle PASS (planned → ready → active)"
}

# ── Execution helpers ──────────────────────────────────────────────────────────

run_sprint() {
  local proj_dir="$1"
  local proj_label="$2"
  local sprint="${3:-sprint-1}"
  local log_file="$LOG_DIR/${proj_label}-${sprint}.log"

  log "Running $sprint for $proj_label..."
  (
    cd "$proj_dir/scripts/ralph"
    timeout 2700 env CODEX_BIN="$CODEX_BIN_VALUE" \
      ./ralph.sh --max-retries "$MAX_RETRIES" --continue-on-failure \
      2>&1
  ) | tee "$log_file"
  return "${PIPESTATUS[0]}"
}

# ── Report helpers ─────────────────────────────────────────────────────────────

extract_story_status() {
  local log="$1"
  grep -E "=== Story S-[0-9]+ (COMPLETE|some tasks)" "$log" 2>/dev/null || true
}

extract_structural_failures() {
  local log="$1"
  grep "STRUCTURAL FAILURE" "$log" 2>/dev/null || true
}

extract_task_failures() {
  local log="$1"
  grep "FAILED after.*attempts" "$log" 2>/dev/null || true
}

count_stories_done() {
  local stories_file="$1"
  jq '[.stories[] | select(.status == "done")] | length' "$stories_file" 2>/dev/null || echo 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  PROJECT 1: nextjs-calendar
#  Real Next.js project via create-next-app. Domain services in lib/.
#  Tests in __tests__/ using Jest + ts-jest.
# ══════════════════════════════════════════════════════════════════════════════

log "=== Setting up nextjs-calendar ==="

cd "$WORK_DIR"
log "  Running create-next-app..."
npx create-next-app@latest nextjs-calendar \
  --typescript \
  --no-tailwind \
  --no-eslint \
  --app \
  --no-src-dir \
  --use-npm \
  --yes \
  --disable-git \
  > "$LOG_DIR/nextjs-create.log" 2>&1 \
  || fail "create-next-app failed — see $LOG_DIR/nextjs-create.log"

cd "$NEXTJS_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

log "  Adding Jest..."
npm install --save-dev jest @types/jest ts-jest jest-environment-node --silent \
  >> "$LOG_DIR/nextjs-create.log" 2>&1

npm pkg set scripts.test="jest"
npm pkg set scripts.typecheck="tsc --noEmit"
npm pkg set scripts.lint="tsc --noEmit"

cat > jest.config.ts <<'TS'
import type { Config } from 'jest'

const config: Config = {
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {
      tsconfig: {
        module: 'commonjs',
        moduleResolution: 'node',
      },
    }],
  },
  testEnvironment: 'node',
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/$1',
  },
  testMatch: ['**/__tests__/**/*.test.ts'],
  testPathIgnorePatterns: ['/node_modules/', '/.next/'],
}

export default config
TS

mkdir -p lib __tests__

cat > lib/index.ts <<'TS'
export const APP_NAME = "nextjs-calendar"
export const APP_VERSION = "0.1.0"
TS

cat > __tests__/baseline.test.ts <<'TS'
import { APP_NAME, APP_VERSION } from '../lib/index'

describe('baseline', () => {
  it('exports APP_NAME', () => {
    expect(APP_NAME).toBe('nextjs-calendar')
  })
  it('exports APP_VERSION', () => {
    expect(typeof APP_VERSION).toBe('string')
  })
})
TS

git add .
git reset -- .next >/dev/null 2>&1 || true
git commit -m "chore: init nextjs-calendar" >/dev/null

log "  installing ralph framework..."
HOME="$WORK_DIR/home-nextjs" "$REPO_ROOT/install.sh" \
  --project "$NEXTJS_DIR" > "$LOG_DIR/install-nextjs.log" 2>&1
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-task.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-story.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-sprint.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-sprint-commit.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/doctor.sh"

# ── NextJS sprint scaffold ─────────────────────────────────────────────────────

(
  cd "$NEXTJS_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-1 > "$LOG_DIR/nextjs-sprint-create.log" 2>&1
  assert_contains "$LOG_DIR/nextjs-sprint-create.log" "Created sprint: sprint-1"

  ./ralph-story.sh add --title "Core types and interfaces" \
    --goal "Define all TypeScript types for the calendar and todo domain." \
    --prompt-context "Create lib/types.ts with CalendarEvent, Todo, Category interfaces and a Priority type." \
    > "$LOG_DIR/nextjs-story-add-S-001.log" 2>&1

  ./ralph-story.sh add --title "Calendar service" --depends-on S-001 \
    --goal "Implement a CalendarStore class with add/remove/query operations." \
    --prompt-context "Create lib/calendarService.ts importing CalendarEvent from types." \
    > "$LOG_DIR/nextjs-story-add-S-002.log" 2>&1

  ./ralph-story.sh add --title "Todo service" --depends-on S-001 \
    --goal "Implement a TodoStore class with CRUD and priority filtering." \
    --prompt-context "Create lib/todoService.ts importing Todo, Priority from types." \
    > "$LOG_DIR/nextjs-story-add-S-003.log" 2>&1

  ./ralph-story.sh add --title "Barrel export and integration" --depends-on S-001 --depends-on S-002 --depends-on S-003 \
    --goal "Wire all modules through lib/index.ts and add cross-module integration test." \
    --prompt-context "Update lib/index.ts to re-export calendarService, todoService, types. Add __tests__/integration.test.ts." \
    > "$LOG_DIR/nextjs-story-add-S-004.log" 2>&1

)

# ── NextJS doctor check ────────────────────────────────────────────────────────

doctor_check "$NEXTJS_DIR" "nextjs"

# ── NextJS story.json definitions ─────────────────────────────────────────────
# --generated: let ralph-story.sh generate (Codex) produce story.json files
# default:     use hand-written task plans for deterministic fast execution

if [ "$GENERATED" -eq 1 ]; then
  generate_stories "$NEXTJS_DIR" "nextjs"
else

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-001"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-001 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-001",
  "title": "Core types and interfaces",
  "description": "Define all TypeScript types for the calendar and todo domain.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "lib/types.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create lib/types.ts with domain interfaces",
      "context": "Create lib/types.ts. Export:\n  - Priority: a type alias for the union 'low' | 'medium' | 'high'\n  - Category: interface with id: string, name: string, color: string\n  - CalendarEvent: interface with id: string, title: string, date: string (ISO), description?: string, categoryId?: string, linkedTodoIds: string[]\n  - Todo: interface with id: string, title: string, done: boolean, priority: Priority, categoryId?: string, dueDate?: string, linkedEventId?: string\nCommit the file.",
      "scope": ["lib/types.ts"],
      "acceptance": "lib/types.ts exists and exports CalendarEvent, Todo, Category, Priority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f lib/types.ts",
        "grep -q 'CalendarEvent' lib/types.ts",
        "grep -q 'Priority' lib/types.ts",
        "grep -q 'Todo' lib/types.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/types.test.ts — Jest type-shape tests",
      "context": "Create __tests__/types.test.ts. Import the TypeScript types from '../lib/types'. Write Jest tests using describe/it/expect:\n\n  import type { CalendarEvent, Todo, Category, Priority } from '../lib/types'\n\n  describe('types', () => {\n    it('CalendarEvent can be shaped', () => {\n      const event: CalendarEvent = { id: 'e1', title: 'Meeting', date: '2024-01-01', linkedTodoIds: [] }\n      expect(event.id).toBe('e1')\n      expect(event.linkedTodoIds).toEqual([])\n    })\n    it('Todo has done and priority fields', () => {\n      const todo: Todo = { id: 't1', title: 'Task', done: false, priority: 'high' }\n      expect(todo.done).toBe(false)\n      expect(todo.priority).toBe('high')\n    })\n    it('Priority accepts valid values', () => {\n      const priorities: Priority[] = ['low', 'medium', 'high']\n      expect(priorities).toHaveLength(3)\n    })\n    it('Category has id, name, color', () => {\n      const cat: Category = { id: 'c1', name: 'Work', color: '#ff0000' }\n      expect(cat.color).toBe('#ff0000')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/types.test.ts"],
      "acceptance": "__tests__/types.test.ts exists with passing Jest tests for all type shapes.",
      "checks": [
        "test -f __tests__/types.test.ts",
        "npm test -- --testPathPatterns=\"types\\.test\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. If any issues are found, fix them and commit. If everything already passes, no commit is needed.",
      "scope": ["lib/types.ts", "__tests__/types.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-002"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-002 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-002",
  "title": "Calendar service",
  "description": "Implement a CalendarStore class with event add, remove, and query operations.",
  "branchName": "ralph/sprint-1/story-S-002",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "lib/calendarService.ts and __tests__/calendarService.test.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create lib/calendarService.ts",
      "context": "Create lib/calendarService.ts. Import CalendarEvent from './types'.\nExport a CalendarStore class with:\n  - private events: CalendarEvent[] = []\n  - addEvent(event: CalendarEvent): void\n  - removeEvent(id: string): void  — filters out the matching id\n  - getEventsForDate(date: string): CalendarEvent[]  — returns events where event.date === date\n  - getAllEvents(): CalendarEvent[]  — returns a shallow copy of the array\nAlso export standalone functions that delegate to a store instance:\n  function addEvent(store: CalendarStore, event: CalendarEvent): void\n  function removeEvent(store: CalendarStore, id: string): void\n  function getEventsForDate(store: CalendarStore, date: string): CalendarEvent[]\nCommit the file.",
      "scope": ["lib/calendarService.ts"],
      "acceptance": "lib/calendarService.ts exists, exports CalendarStore and standalone functions. TypeScript strict typecheck passes.",
      "checks": [
        "test -f lib/calendarService.ts",
        "grep -q 'CalendarStore' lib/calendarService.ts",
        "grep -q 'addEvent' lib/calendarService.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/calendarService.test.ts — Jest runtime tests",
      "context": "Create __tests__/calendarService.test.ts. Import CalendarStore from '../lib/calendarService'. Write Jest tests:\n\n  import { CalendarStore } from '../lib/calendarService'\n\n  describe('CalendarStore', () => {\n    let store: CalendarStore\n    beforeEach(() => { store = new CalendarStore() })\n\n    it('adds events and queries by date', () => {\n      store.addEvent({ id: 'e1', title: 'A', date: '2024-03-15', linkedTodoIds: [] })\n      store.addEvent({ id: 'e2', title: 'B', date: '2024-03-15', linkedTodoIds: [] })\n      store.addEvent({ id: 'e3', title: 'C', date: '2024-03-16', linkedTodoIds: [] })\n      expect(store.getEventsForDate('2024-03-15')).toHaveLength(2)\n      expect(store.getEventsForDate('2024-03-16')).toHaveLength(1)\n    })\n\n    it('removes an event', () => {\n      store.addEvent({ id: 'e1', title: 'A', date: '2024-03-15', linkedTodoIds: [] })\n      store.removeEvent('e1')\n      expect(store.getAllEvents()).toHaveLength(0)\n    })\n\n    it('getAllEvents returns remaining events', () => {\n      store.addEvent({ id: 'e1', title: 'A', date: '2024-03-15', linkedTodoIds: [] })\n      store.addEvent({ id: 'e2', title: 'B', date: '2024-03-16', linkedTodoIds: [] })\n      store.removeEvent('e1')\n      expect(store.getAllEvents()).toHaveLength(1)\n      expect(store.getAllEvents()[0].id).toBe('e2')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/calendarService.test.ts"],
      "acceptance": "__tests__/calendarService.test.ts exists with passing Jest tests for CalendarStore.",
      "checks": [
        "test -f __tests__/calendarService.test.ts",
        "npm test -- --testPathPatterns=\"calendarService\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["lib/calendarService.ts", "__tests__/calendarService.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-003"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-003 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-003",
  "title": "Todo service",
  "description": "Implement a TodoStore class with todo CRUD and priority filtering.",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "lib/todoService.ts and __tests__/todoService.test.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create lib/todoService.ts",
      "context": "Create lib/todoService.ts. Import Todo and Priority from './types'.\nExport a TodoStore class with:\n  - private todos: Todo[] = []\n  - createTodo(todo: Todo): void\n  - completeTodo(id: string): void  — sets done = true for the matching id\n  - deleteTodo(id: string): void  — filters out the matching id\n  - filterByPriority(priority: Priority): Todo[]  — returns todos matching the priority\n  - getAllTodos(): Todo[]  — returns a shallow copy\nCommit the file.",
      "scope": ["lib/todoService.ts"],
      "acceptance": "lib/todoService.ts exists, exports TodoStore with createTodo, completeTodo, deleteTodo, filterByPriority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f lib/todoService.ts",
        "grep -q 'TodoStore' lib/todoService.ts",
        "grep -q 'createTodo' lib/todoService.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/todoService.test.ts — Jest runtime tests",
      "context": "Create __tests__/todoService.test.ts. Import TodoStore from '../lib/todoService'. Write Jest tests:\n\n  import { TodoStore } from '../lib/todoService'\n\n  describe('TodoStore', () => {\n    let store: TodoStore\n    beforeEach(() => { store = new TodoStore() })\n\n    it('filters by priority', () => {\n      store.createTodo({ id: 't1', title: 'High 1', done: false, priority: 'high' })\n      store.createTodo({ id: 't2', title: 'High 2', done: false, priority: 'high' })\n      store.createTodo({ id: 't3', title: 'Low', done: false, priority: 'low' })\n      expect(store.filterByPriority('high')).toHaveLength(2)\n      expect(store.filterByPriority('low')).toHaveLength(1)\n    })\n\n    it('completes a todo', () => {\n      store.createTodo({ id: 't1', title: 'Task', done: false, priority: 'medium' })\n      store.completeTodo('t1')\n      expect(store.getAllTodos()[0].done).toBe(true)\n    })\n\n    it('deletes a todo', () => {\n      store.createTodo({ id: 't1', title: 'A', done: false, priority: 'low' })\n      store.createTodo({ id: 't2', title: 'B', done: false, priority: 'high' })\n      store.deleteTodo('t1')\n      expect(store.getAllTodos()).toHaveLength(1)\n      expect(store.getAllTodos()[0].id).toBe('t2')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/todoService.test.ts"],
      "acceptance": "__tests__/todoService.test.ts exists with passing Jest tests for TodoStore.",
      "checks": [
        "test -f __tests__/todoService.test.ts",
        "npm test -- --testPathPatterns=\"todoService\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["lib/todoService.ts", "__tests__/todoService.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-004"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-004 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-004",
  "title": "Barrel export and integration test",
  "description": "Wire all modules through lib/index.ts and add a cross-module integration test.",
  "branchName": "ralph/sprint-1/story-S-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "lib/index.ts and __tests__/integration.test.ts",
    "preserved_invariants": [
      "APP_NAME and APP_VERSION exports must remain in lib/index.ts",
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update lib/index.ts to re-export all modules",
      "context": "Update lib/index.ts (which currently only exports APP_NAME and APP_VERSION). Add re-exports:\n  export * from './calendarService'\n  export * from './todoService'\n  export * from './types'\nKeep the existing APP_NAME and APP_VERSION exports. Commit the change.",
      "scope": ["lib/index.ts"],
      "acceptance": "lib/index.ts re-exports calendarService, todoService, and types. APP_NAME and APP_VERSION remain. TypeScript strict typecheck passes.",
      "checks": [
        "grep -q 'calendarService' lib/index.ts",
        "grep -q 'todoService' lib/index.ts",
        "grep -q 'APP_NAME' lib/index.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/integration.test.ts — cross-module Jest test",
      "context": "Create __tests__/integration.test.ts. Import from the barrel lib/index.ts. Write Jest tests:\n\n  import { CalendarStore, TodoStore, APP_NAME } from '../lib/index'\n\n  describe('integration', () => {\n    it('APP_NAME is exported from barrel', () => {\n      expect(APP_NAME).toBe('nextjs-calendar')\n    })\n\n    it('CalendarStore and TodoStore work together', () => {\n      const calStore = new CalendarStore()\n      const todoStore = new TodoStore()\n\n      calStore.addEvent({ id: 'e1', title: 'Standup', date: '2024-04-01', linkedTodoIds: ['t1'] })\n      todoStore.createTodo({ id: 't1', title: 'Prepare agenda', done: false, priority: 'high' })\n\n      expect(calStore.getEventsForDate('2024-04-01')).toHaveLength(1)\n      expect(calStore.getEventsForDate('2024-04-01')[0].title).toBe('Standup')\n      expect(todoStore.filterByPriority('high')).toHaveLength(1)\n\n      todoStore.completeTodo('t1')\n      expect(todoStore.getAllTodos()[0].done).toBe(true)\n\n      const event = calStore.getAllEvents()[0]\n      expect(event.linkedTodoIds).toContain('t1')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/integration.test.ts"],
      "acceptance": "__tests__/integration.test.ts exists with passing cross-module Jest assertions.",
      "checks": [
        "test -f __tests__/integration.test.ts",
        "npm test -- --testPathPatterns=\"integration\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["lib/index.ts", "__tests__/integration.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass including integration.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

fi  # end GENERATED guard for nextjs story.json

# Write ralph-sprint-test.sh for nextjs-calendar
cat > "$NEXTJS_DIR/scripts/ralph/ralph-sprint-test.sh" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
npm run build && npm run typecheck && npm test
SH
chmod +x "$NEXTJS_DIR/scripts/ralph/ralph-sprint-test.sh"

commit_baseline "$NEXTJS_DIR" "chore(smoke): nextjs-calendar sprint plan"


# ══════════════════════════════════════════════════════════════════════════════
#  PROJECT 2: angular-calendar
#  Real Angular project via ng new. Services in src/app/services/.
#  Tests as *.spec.ts using Jest + ts-jest.
# ══════════════════════════════════════════════════════════════════════════════

log "=== Setting up angular-calendar ==="

cd "$WORK_DIR"
log "  Running ng new..."
npx @angular/cli@latest new angular-calendar \
  --routing=false \
  --style=css \
  --skip-git \
  --standalone \
  --defaults \
  > "$LOG_DIR/angular-create.log" 2>&1 \
  || fail "ng new failed — see $LOG_DIR/angular-create.log"

cd "$ANGULAR_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

# Remove generated Karma/Jasmine spec files — incompatible with Jest
find src -name "*.spec.ts" -delete 2>/dev/null || true

log "  Adding Jest..."
npm install --save-dev jest @types/jest ts-jest jest-environment-node --silent \
  >> "$LOG_DIR/angular-create.log" 2>&1

npm pkg set scripts.test="jest"
npm pkg set scripts.typecheck="tsc --noEmit"
npm pkg set scripts.lint="tsc --noEmit"

cat > jest.config.ts <<'TS'
import type { Config } from 'jest'

const config: Config = {
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {
      tsconfig: {
        module: 'commonjs',
        moduleResolution: 'node',
        experimentalDecorators: true,
        emitDecoratorMetadata: true,
      },
    }],
  },
  testEnvironment: 'node',
  testMatch: ['**/*.spec.ts'],
  testPathIgnorePatterns: ['/node_modules/', '/dist/'],
}

export default config
TS

# Minimal baseline spec replacing deleted generated one
cat > src/app/app.spec.ts <<'SPEC'
describe('app', () => {
  it('is configured', () => {
    expect(true).toBe(true)
  })
})
SPEC

git add .
git reset -- dist >/dev/null 2>&1 || true
git commit -m "chore: init angular-calendar" >/dev/null

log "  installing ralph framework..."
HOME="$WORK_DIR/home-angular" "$REPO_ROOT/install.sh" \
  --project "$ANGULAR_DIR" > "$LOG_DIR/install-angular.log" 2>&1
assert_file_exists "$ANGULAR_DIR/scripts/ralph/ralph.sh"
assert_file_exists "$ANGULAR_DIR/scripts/ralph/ralph-task.sh"
assert_file_exists "$ANGULAR_DIR/scripts/ralph/ralph-sprint-commit.sh"
assert_file_exists "$ANGULAR_DIR/scripts/ralph/doctor.sh"

# ── Angular sprint scaffold ────────────────────────────────────────────────────

(
  cd "$ANGULAR_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-1 > "$LOG_DIR/angular-sprint-create.log" 2>&1
  assert_contains "$LOG_DIR/angular-sprint-create.log" "Created sprint: sprint-1"

  ./ralph-story.sh add --title "Data models" \
    --goal "Define class-based domain models for calendar events, todos, and categories." \
    --prompt-context "Create src/app/models.ts with class CalendarEvent, class Todo, class Category." \
    > "$LOG_DIR/angular-story-add-S-001.log" 2>&1

  ./ralph-story.sh add --title "CalendarService class" --depends-on S-001 \
    --goal "Implement CalendarService as a class with Map-backed event storage." \
    --prompt-context "Create src/app/services/calendar.service.ts with class CalendarService." \
    > "$LOG_DIR/angular-story-add-S-002.log" 2>&1

  ./ralph-story.sh add --title "TodoService class" --depends-on S-001 \
    --goal "Implement TodoService as a class with Map-backed todo storage." \
    --prompt-context "Create src/app/services/todo.service.ts with class TodoService." \
    > "$LOG_DIR/angular-story-add-S-003.log" 2>&1

  ./ralph-story.sh add --title "AppModule wiring and integration" --depends-on S-001 --depends-on S-002 --depends-on S-003 \
    --goal "Create AppModule class that wires CalendarService and TodoService together." \
    --prompt-context "Create src/app/app.module.ts with class AppModule having a static create() factory." \
    > "$LOG_DIR/angular-story-add-S-004.log" 2>&1

)

# ── Angular doctor check ───────────────────────────────────────────────────────

doctor_check "$ANGULAR_DIR" "angular"

# ── Angular story.json definitions ────────────────────────────────────────────

if [ "$GENERATED" -eq 1 ]; then
  generate_stories "$ANGULAR_DIR" "angular"
else

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-001"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-001 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-001",
  "title": "Data models",
  "description": "Define class-based domain models used throughout the app.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "src/app/models.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/models.ts with class-based models",
      "context": "Create src/app/models.ts. Export three classes:\n\n  export class CalendarEvent {\n    constructor(\n      public id: string,\n      public title: string,\n      public date: string,\n      public description: string = '',\n      public linkedTodoIds: string[] = []\n    ) {}\n  }\n\n  export class Todo {\n    public done: boolean = false\n    constructor(\n      public id: string,\n      public title: string,\n      public priority: 'low' | 'medium' | 'high' = 'medium',\n      public dueDate?: string\n    ) {}\n  }\n\n  export class Category {\n    constructor(\n      public id: string,\n      public name: string,\n      public color: string\n    ) {}\n  }\n\nCommit the file.",
      "scope": ["src/app/models.ts"],
      "acceptance": "src/app/models.ts exists and exports class CalendarEvent, class Todo, class Category. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/models.ts",
        "grep -q 'class CalendarEvent' src/app/models.ts",
        "grep -q 'class Todo' src/app/models.ts",
        "grep -q 'class Category' src/app/models.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/models.spec.ts — Jest class instantiation tests",
      "context": "Create src/app/models.spec.ts. Import the model classes from './models'. Write Jest tests:\n\n  import { CalendarEvent, Todo, Category } from './models'\n\n  describe('CalendarEvent', () => {\n    it('sets defaults for description and linkedTodoIds', () => {\n      const e = new CalendarEvent('e1', 'Meeting', '2024-01-01')\n      expect(e.id).toBe('e1')\n      expect(e.description).toBe('')\n      expect(e.linkedTodoIds).toEqual([])\n    })\n  })\n\n  describe('Todo', () => {\n    it('defaults done to false and priority to medium', () => {\n      const t = new Todo('t1', 'Task')\n      expect(t.done).toBe(false)\n      expect(t.priority).toBe('medium')\n    })\n    it('accepts explicit priority', () => {\n      const t = new Todo('t2', 'Urgent', 'high')\n      expect(t.priority).toBe('high')\n    })\n  })\n\n  describe('Category', () => {\n    it('stores id, name, color', () => {\n      const c = new Category('c1', 'Work', '#ff0000')\n      expect(c.name).toBe('Work')\n      expect(c.color).toBe('#ff0000')\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/models.spec.ts"],
      "acceptance": "src/app/models.spec.ts exists with passing Jest tests for all model classes.",
      "checks": [
        "test -f src/app/models.spec.ts",
        "npm test -- --testPathPatterns=\"models\\.spec\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/models.ts", "src/app/models.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-002"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-002 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-002",
  "title": "CalendarService class",
  "description": "Implement CalendarService as a class with Map-backed event storage.",
  "branchName": "ralph/sprint-1/story-S-002",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "src/app/services/calendar.service.ts and src/app/services/calendar.service.spec.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/services/calendar.service.ts",
      "context": "Create src/app/services/calendar.service.ts. Import CalendarEvent from '../models'.\nExport class CalendarService with:\n  - private events: Map<string, CalendarEvent> = new Map()\n  - addEvent(event: CalendarEvent): void  — sets events.set(event.id, event)\n  - removeEvent(id: string): boolean  — returns events.delete(id)\n  - getEventsForDate(date: string): CalendarEvent[]  — filters by event.date === date\n  - getAllEvents(): CalendarEvent[]  — returns Array.from(events.values())\nCommit the file.",
      "scope": ["src/app/services/calendar.service.ts"],
      "acceptance": "src/app/services/calendar.service.ts exists, exports class CalendarService with addEvent, removeEvent, getEventsForDate. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/services/calendar.service.ts",
        "grep -q 'class CalendarService' src/app/services/calendar.service.ts",
        "grep -q 'addEvent' src/app/services/calendar.service.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/services/calendar.service.spec.ts — Jest tests",
      "context": "Create src/app/services/calendar.service.spec.ts. Import CalendarService and CalendarEvent. Write Jest tests:\n\n  import { CalendarService } from './calendar.service'\n  import { CalendarEvent } from '../models'\n\n  describe('CalendarService', () => {\n    let service: CalendarService\n    beforeEach(() => { service = new CalendarService() })\n\n    it('adds events and queries by date', () => {\n      service.addEvent(new CalendarEvent('e1', 'A', '2024-05-01'))\n      service.addEvent(new CalendarEvent('e2', 'B', '2024-05-01'))\n      service.addEvent(new CalendarEvent('e3', 'C', '2024-05-02'))\n      expect(service.getEventsForDate('2024-05-01')).toHaveLength(2)\n      expect(service.getEventsForDate('2024-05-02')).toHaveLength(1)\n    })\n\n    it('removes an event and returns true', () => {\n      service.addEvent(new CalendarEvent('e1', 'A', '2024-05-01'))\n      expect(service.removeEvent('e1')).toBe(true)\n      expect(service.getAllEvents()).toHaveLength(0)\n    })\n\n    it('removeEvent returns false for unknown id', () => {\n      expect(service.removeEvent('nonexistent')).toBe(false)\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/services/calendar.service.spec.ts"],
      "acceptance": "src/app/services/calendar.service.spec.ts exists with passing Jest tests for CalendarService.",
      "checks": [
        "test -f src/app/services/calendar.service.spec.ts",
        "npm test -- --testPathPatterns=\"calendar\\.service\\.spec\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/services/calendar.service.ts", "src/app/services/calendar.service.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-003"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-003 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-003",
  "title": "TodoService class",
  "description": "Implement TodoService as a class with Map-backed todo storage.",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "src/app/services/todo.service.ts and src/app/services/todo.service.spec.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/services/todo.service.ts",
      "context": "Create src/app/services/todo.service.ts. Import Todo from '../models'.\nExport class TodoService with:\n  - private todos: Map<string, Todo> = new Map()\n  - create(todo: Todo): void  — sets todos.set(todo.id, todo)\n  - complete(id: string): void  — finds the todo and sets done = true\n  - delete(id: string): boolean  — returns todos.delete(id)\n  - getByPriority(priority: 'low' | 'medium' | 'high'): Todo[]  — filters by todo.priority\n  - getAll(): Todo[]  — returns Array.from(todos.values())\nCommit the file.",
      "scope": ["src/app/services/todo.service.ts"],
      "acceptance": "src/app/services/todo.service.ts exists, exports class TodoService with create, complete, delete, getByPriority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/services/todo.service.ts",
        "grep -q 'class TodoService' src/app/services/todo.service.ts",
        "grep -q 'getByPriority' src/app/services/todo.service.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/services/todo.service.spec.ts — Jest tests",
      "context": "Create src/app/services/todo.service.spec.ts. Import TodoService and Todo. Write Jest tests:\n\n  import { TodoService } from './todo.service'\n  import { Todo } from '../models'\n\n  describe('TodoService', () => {\n    let service: TodoService\n    beforeEach(() => { service = new TodoService() })\n\n    it('filters by priority', () => {\n      service.create(new Todo('t1', 'High 1', 'high'))\n      service.create(new Todo('t2', 'High 2', 'high'))\n      service.create(new Todo('t3', 'Low', 'low'))\n      expect(service.getByPriority('high')).toHaveLength(2)\n      expect(service.getByPriority('low')).toHaveLength(1)\n    })\n\n    it('completes a todo', () => {\n      service.create(new Todo('t1', 'Task', 'medium'))\n      service.complete('t1')\n      expect(service.getAll()[0].done).toBe(true)\n    })\n\n    it('deletes a todo and returns true', () => {\n      service.create(new Todo('t1', 'A', 'low'))\n      service.create(new Todo('t2', 'B', 'high'))\n      expect(service.delete('t1')).toBe(true)\n      expect(service.getAll()).toHaveLength(1)\n      expect(service.getAll()[0].id).toBe('t2')\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/services/todo.service.spec.ts"],
      "acceptance": "src/app/services/todo.service.spec.ts exists with passing Jest tests for TodoService.",
      "checks": [
        "test -f src/app/services/todo.service.spec.ts",
        "npm test -- --testPathPatterns=\"todo\\.service\\.spec\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/services/todo.service.ts", "src/app/services/todo.service.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-004"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-004 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-004",
  "title": "AppModule wiring and integration",
  "description": "Create AppModule that wires CalendarService and TodoService, with cross-service integration tests.",
  "branchName": "ralph/sprint-1/story-S-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "src/app/app.module.ts and src/app/app.module.spec.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/app.module.ts",
      "context": "Create src/app/app.module.ts. Import CalendarService from './services/calendar.service' and TodoService from './services/todo.service'.\nExport:\n  export interface AppServices {\n    calendarService: CalendarService\n    todoService: TodoService\n  }\n  export class AppModule {\n    static create(): AppServices {\n      return {\n        calendarService: new CalendarService(),\n        todoService: new TodoService(),\n      }\n    }\n  }\nCommit the file.",
      "scope": ["src/app/app.module.ts"],
      "acceptance": "src/app/app.module.ts exists, exports class AppModule with static create() returning AppServices. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/app.module.ts",
        "grep -q 'class AppModule' src/app/app.module.ts",
        "grep -q 'AppServices' src/app/app.module.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/app.module.spec.ts — cross-service Jest integration",
      "context": "Create src/app/app.module.spec.ts. Import AppModule, CalendarEvent, Todo. Write Jest tests:\n\n  import { AppModule } from './app.module'\n  import { CalendarEvent, Todo } from './models'\n\n  describe('AppModule', () => {\n    it('create() returns services with empty state', () => {\n      const { calendarService, todoService } = AppModule.create()\n      expect(calendarService.getAllEvents()).toHaveLength(0)\n      expect(todoService.getAll()).toHaveLength(0)\n    })\n\n    it('instances are independent across create() calls', () => {\n      const app1 = AppModule.create()\n      const app2 = AppModule.create()\n      app1.calendarService.addEvent(new CalendarEvent('e1', 'Meeting', '2024-06-01'))\n      expect(app1.calendarService.getAllEvents()).toHaveLength(1)\n      expect(app2.calendarService.getAllEvents()).toHaveLength(0)\n    })\n\n    it('cross-service integration', () => {\n      const { calendarService, todoService } = AppModule.create()\n      calendarService.addEvent(new CalendarEvent('e1', 'Standup', '2024-06-01'))\n      todoService.create(new Todo('t1', 'Agenda', 'high'))\n      expect(calendarService.getEventsForDate('2024-06-01')).toHaveLength(1)\n      expect(todoService.getByPriority('high')).toHaveLength(1)\n      todoService.complete('t1')\n      expect(todoService.getAll()[0].done).toBe(true)\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/app.module.spec.ts"],
      "acceptance": "src/app/app.module.spec.ts exists with passing cross-service Jest integration assertions.",
      "checks": [
        "test -f src/app/app.module.spec.ts",
        "npm test -- --testPathPatterns=\"app\\.module\\.spec\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/app.module.ts", "src/app/app.module.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass including integration.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

fi  # end GENERATED guard for angular story.json

# Write ralph-sprint-test.sh for angular-calendar
cat > "$ANGULAR_DIR/scripts/ralph/ralph-sprint-test.sh" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
npm run build && npm run typecheck && npm test
SH
chmod +x "$ANGULAR_DIR/scripts/ralph/ralph-sprint-test.sh"

commit_baseline "$ANGULAR_DIR" "chore(smoke): angular-calendar sprint plan"


# ══════════════════════════════════════════════════════════════════════════════
#  VALIDATION PHASE
#  Schema, dependency, and health checks for both projects before execution.
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "════════════════════════════════════════"
log "  VALIDATION PHASE"
log "════════════════════════════════════════"

for proj_label in nextjs angular; do
  if [ "$proj_label" = "nextjs" ]; then
    proj_dir="$NEXTJS_DIR"
  else
    proj_dir="$ANGULAR_DIR"
  fi

  ralph_dir="$proj_dir/scripts/ralph"
  log ""
  log "--- Validating $proj_label-calendar ---"

  # Schema + dependency validation
  validate_sprint "$ralph_dir" "sprint-1"

  # ralph-story.sh health — fatal if any story has structural issues
  for sid in S-001 S-002 S-003 S-004; do
    hlog="$LOG_DIR/${proj_label}-health-${sid}.log"
    if ! (cd "$ralph_dir" && ./ralph-story.sh health "$sid" > "$hlog" 2>&1); then
      log "  FAIL: health check for $proj_label $sid — see $hlog"
      cat "$hlog" >&2
      fail "Story health check failed: $proj_label $sid"
    fi
    log "  health OK: $proj_label $sid"
  done

  # Lifecycle coverage: planned → ready → active via prepare-all + sprint use
  prepare_and_activate "$proj_dir" "$proj_label" "sprint-1"
done

log ""
log "Validation complete — both projects structurally sound."


# ══════════════════════════════════════════════════════════════════════════════
#  EXECUTION PHASE
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "════════════════════════════════════════"
log "  EXECUTION PHASE"
log "════════════════════════════════════════"

NEXTJS_EXIT=0
ANGULAR_EXIT=0
NEXTJS_COMMIT_EXIT=0
ANGULAR_COMMIT_EXIT=0

log ""
log "--- Running nextjs-calendar sprint-1 ---"
run_sprint "$NEXTJS_DIR" "nextjs" "sprint-1" || NEXTJS_EXIT=$?

if [ "$NEXTJS_EXIT" -eq 0 ]; then
  log ""
  log "--- Post-sprint: nextjs-calendar sprint-1 ---"
  (cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-status.sh) \
    > "$LOG_DIR/nextjs-sprint-1-status.log" 2>&1 || true
  log "  ralph-status logged to: $LOG_DIR/nextjs-sprint-1-status.log"
  run_sprint_commit "$NEXTJS_DIR" "nextjs" "sprint-1" || NEXTJS_COMMIT_EXIT=$?
fi

log ""
log "--- Running angular-calendar sprint-1 ---"
run_sprint "$ANGULAR_DIR" "angular" "sprint-1" || ANGULAR_EXIT=$?

if [ "$ANGULAR_EXIT" -eq 0 ]; then
  log ""
  log "--- Post-sprint: angular-calendar sprint-1 ---"
  (cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-status.sh) \
    > "$LOG_DIR/angular-sprint-1-status.log" 2>&1 || true
  log "  ralph-status logged to: $LOG_DIR/angular-sprint-1-status.log"
  run_sprint_commit "$ANGULAR_DIR" "angular" "sprint-1" || ANGULAR_COMMIT_EXIT=$?
fi


# ══════════════════════════════════════════════════════════════════════════════
#  SPRINT 2 SETUP: nextjs-calendar  (UI layer — React components)
#
#  Sprint 2 depends on sprint 1's lib/ code being merged to main.
#  Only runs when sprint 1 passed and committed successfully.
# ══════════════════════════════════════════════════════════════════════════════

NEXTJS_S2_EXIT=0
ANGULAR_S2_EXIT=0
NEXTJS_S2_COMMIT_EXIT=0
ANGULAR_S2_COMMIT_EXIT=0
NEXTJS_S2_SKIPPED=0
ANGULAR_S2_SKIPPED=0

if [ "$NEXTJS_EXIT" -eq 0 ] && [ "$NEXTJS_COMMIT_EXIT" -eq 0 ]; then

log ""
log "=== Setting up nextjs-calendar sprint-2 (UI components) ==="

log "  Installing @testing-library packages..."
(
  cd "$NEXTJS_DIR"
  npm install --save-dev \
    @testing-library/react \
    @testing-library/jest-dom \
    @testing-library/user-event \
    jest-environment-jsdom \
    --silent
) >> "$LOG_DIR/nextjs-sprint2-setup.log" 2>&1 \
  || fail "nextjs sprint-2: @testing-library install failed — see $LOG_DIR/nextjs-sprint2-setup.log"

# Update jest.config.ts to support .tsx and per-file jsdom environment
cat > "$NEXTJS_DIR/jest.config.ts" <<'TS'
import type { Config } from 'jest'

const config: Config = {
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {
      tsconfig: {
        module: 'commonjs',
        moduleResolution: 'node',
        jsx: 'react-jsx',
      },
    }],
  },
  testEnvironment: 'node',
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/$1',
  },
  testMatch: ['**/__tests__/**/*.test.{ts,tsx}'],
  testPathIgnorePatterns: ['/node_modules/', '/.next/'],
}

export default config
TS

mkdir -p "$NEXTJS_DIR/components"
commit_baseline "$NEXTJS_DIR" "chore(smoke): nextjs-calendar sprint-2 infra"

(
  cd "$NEXTJS_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-2 > "$LOG_DIR/nextjs-sprint2-create.log" 2>&1
  assert_contains "$LOG_DIR/nextjs-sprint2-create.log" "Created sprint: sprint-2"

  ./ralph-story.sh add --title "CalendarView component" \
    --goal "Build a React client component that renders a list of calendar events with remove actions." \
    --prompt-context "Create components/CalendarView.tsx with 'use client', CalendarEvent[] events prop, onRemove callback, and data-testid attributes." \
    > "$LOG_DIR/nextjs-story-add-S2-001.log" 2>&1

  ./ralph-story.sh add --title "TodoList component" --depends-on S-001 \
    --goal "Build a React client component that renders todo items with complete and delete actions." \
    --prompt-context "Create components/TodoList.tsx with 'use client', Todo[] todos prop, onComplete and onDelete callbacks." \
    > "$LOG_DIR/nextjs-story-add-S2-002.log" 2>&1

  ./ralph-story.sh add --title "EventForm component" --depends-on S-001 \
    --goal "Build a controlled React form component for creating new calendar events." \
    --prompt-context "Create components/EventForm.tsx with 'use client', onAdd callback prop, title and date inputs with data-testid attributes." \
    > "$LOG_DIR/nextjs-story-add-S2-003.log" 2>&1

  ./ralph-story.sh add --title "CalendarApp integration component" --depends-on S-001 --depends-on S-002 --depends-on S-003 \
    --goal "Wire all sub-components together with useState-managed CalendarStore and TodoStore." \
    --prompt-context "Create components/CalendarApp.tsx using useState, CalendarStore, TodoStore from lib. Update app/page.tsx to render CalendarApp." \
    > "$LOG_DIR/nextjs-story-add-S2-004.log" 2>&1

)

# ── NextJS sprint-2 story.json definitions ─────────────────────────────────────

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-2/stories/S-001"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-001 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-001",
  "title": "CalendarView component",
  "description": "React client component rendering a list of CalendarEvent objects with remove buttons.",
  "branchName": "ralph/sprint-2/story-S-001",
  "sprint": "sprint-2",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "components/CalendarView.tsx and __tests__/CalendarView.test.tsx",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create components/CalendarView.tsx",
      "context": "Create components/CalendarView.tsx. Add 'use client' as the first line.\nImport CalendarEvent from '@/lib/types'.\n\nDefine and export default:\n  interface Props {\n    events: CalendarEvent[]\n    onRemove: (id: string) => void\n  }\n\n  export default function CalendarView({ events, onRemove }: Props) {\n    if (events.length === 0) {\n      return <div data-testid=\"empty-state\">No events yet.</div>\n    }\n    return (\n      <div data-testid=\"calendar-view\">\n        {events.map(event => (\n          <div key={event.id} data-testid=\"event-item\">\n            <span>{event.title}</span>\n            <span>{event.date}</span>\n            <button\n              data-testid={`remove-event-${event.id}`}\n              onClick={() => onRemove(event.id)}\n            >\n              Remove\n            </button>\n          </div>\n        ))}\n      </div>\n    )\n  }\n\nCommit the file.",
      "scope": ["components/CalendarView.tsx"],
      "acceptance": "components/CalendarView.tsx exists, exports default CalendarView, uses 'use client'. TypeScript strict typecheck passes.",
      "checks": [
        "test -f components/CalendarView.tsx",
        "grep -q \"'use client'\" components/CalendarView.tsx",
        "grep -q 'data-testid' components/CalendarView.tsx",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/CalendarView.test.tsx — React Testing Library tests",
      "context": "Create __tests__/CalendarView.test.tsx. The file MUST start with these two lines:\n  /**\n   * @jest-environment jsdom\n   */\n\nThen:\n  import '@testing-library/jest-dom'\n  import { render, screen, fireEvent } from '@testing-library/react'\n  import CalendarView from '../components/CalendarView'\n  import type { CalendarEvent } from '../lib/types'\n\n  const mockEvents: CalendarEvent[] = [\n    { id: 'e1', title: 'Morning Standup', date: '2024-03-15', linkedTodoIds: [] },\n    { id: 'e2', title: 'Sprint Review', date: '2024-03-16', linkedTodoIds: [] },\n  ]\n\n  describe('CalendarView', () => {\n    it('renders empty state when no events', () => {\n      render(<CalendarView events={[]} onRemove={() => {}} />)\n      expect(screen.getByTestId('empty-state')).toBeInTheDocument()\n    })\n\n    it('renders event items', () => {\n      render(<CalendarView events={mockEvents} onRemove={() => {}} />)\n      expect(screen.getByTestId('calendar-view')).toBeInTheDocument()\n      expect(screen.getByText('Morning Standup')).toBeInTheDocument()\n      expect(screen.getByText('Sprint Review')).toBeInTheDocument()\n    })\n\n    it('calls onRemove with correct id when Remove clicked', () => {\n      const onRemove = jest.fn()\n      render(<CalendarView events={mockEvents} onRemove={onRemove} />)\n      fireEvent.click(screen.getByTestId('remove-event-e1'))\n      expect(onRemove).toHaveBeenCalledWith('e1')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/CalendarView.test.tsx"],
      "acceptance": "__tests__/CalendarView.test.tsx exists with passing React Testing Library tests.",
      "checks": [
        "test -f __tests__/CalendarView.test.tsx",
        "grep -q '@jest-environment jsdom' __tests__/CalendarView.test.tsx",
        "npm test -- --testPathPatterns=\"CalendarView\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["components/CalendarView.tsx", "__tests__/CalendarView.test.tsx"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-2/stories/S-002"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-002 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-002",
  "title": "TodoList component",
  "description": "React client component rendering todo items with complete and delete actions.",
  "branchName": "ralph/sprint-2/story-S-002",
  "sprint": "sprint-2",
  "priority": 2,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "components/TodoList.tsx and __tests__/TodoList.test.tsx",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create components/TodoList.tsx",
      "context": "Create components/TodoList.tsx. Add 'use client' as the first line.\nImport Todo from '@/lib/types'.\n\nDefine and export default:\n  interface Props {\n    todos: Todo[]\n    onComplete: (id: string) => void\n    onDelete: (id: string) => void\n  }\n\n  export default function TodoList({ todos, onComplete, onDelete }: Props) {\n    if (todos.length === 0) {\n      return <div data-testid=\"empty-todos\">No todos yet.</div>\n    }\n    return (\n      <ul data-testid=\"todo-list\">\n        {todos.map(todo => (\n          <li key={todo.id} data-testid=\"todo-item\">\n            <span style={{ textDecoration: todo.done ? 'line-through' : 'none' }}>\n              {todo.title}\n            </span>\n            <span data-testid={`priority-${todo.id}`}>[{todo.priority}]</span>\n            <button\n              data-testid={`complete-todo-${todo.id}`}\n              onClick={() => onComplete(todo.id)}\n              disabled={todo.done}\n            >\n              Complete\n            </button>\n            <button\n              data-testid={`delete-todo-${todo.id}`}\n              onClick={() => onDelete(todo.id)}\n            >\n              Delete\n            </button>\n          </li>\n        ))}\n      </ul>\n    )\n  }\n\nCommit the file.",
      "scope": ["components/TodoList.tsx"],
      "acceptance": "components/TodoList.tsx exists, exports default TodoList, uses 'use client'. TypeScript strict typecheck passes.",
      "checks": [
        "test -f components/TodoList.tsx",
        "grep -q \"'use client'\" components/TodoList.tsx",
        "grep -q 'todo-list' components/TodoList.tsx",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/TodoList.test.tsx — React Testing Library tests",
      "context": "Create __tests__/TodoList.test.tsx. The file MUST start with these two lines:\n  /**\n   * @jest-environment jsdom\n   */\n\nThen:\n  import '@testing-library/jest-dom'\n  import { render, screen, fireEvent } from '@testing-library/react'\n  import TodoList from '../components/TodoList'\n  import type { Todo } from '../lib/types'\n\n  const mockTodos: Todo[] = [\n    { id: 't1', title: 'Write tests', done: false, priority: 'high' },\n    { id: 't2', title: 'Review PR', done: true, priority: 'medium' },\n  ]\n\n  describe('TodoList', () => {\n    it('renders empty state when no todos', () => {\n      render(<TodoList todos={[]} onComplete={() => {}} onDelete={() => {}} />)\n      expect(screen.getByTestId('empty-todos')).toBeInTheDocument()\n    })\n\n    it('renders todo items with priority', () => {\n      render(<TodoList todos={mockTodos} onComplete={() => {}} onDelete={() => {}} />)\n      expect(screen.getByTestId('todo-list')).toBeInTheDocument()\n      expect(screen.getByText('Write tests')).toBeInTheDocument()\n      expect(screen.getByTestId('priority-t1')).toHaveTextContent('high')\n    })\n\n    it('calls onComplete when Complete button clicked', () => {\n      const onComplete = jest.fn()\n      render(<TodoList todos={mockTodos} onComplete={onComplete} onDelete={() => {}} />)\n      fireEvent.click(screen.getByTestId('complete-todo-t1'))\n      expect(onComplete).toHaveBeenCalledWith('t1')\n    })\n\n    it('calls onDelete when Delete button clicked', () => {\n      const onDelete = jest.fn()\n      render(<TodoList todos={mockTodos} onComplete={() => {}} onDelete={onDelete} />)\n      fireEvent.click(screen.getByTestId('delete-todo-t2'))\n      expect(onDelete).toHaveBeenCalledWith('t2')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/TodoList.test.tsx"],
      "acceptance": "__tests__/TodoList.test.tsx exists with passing React Testing Library tests.",
      "checks": [
        "test -f __tests__/TodoList.test.tsx",
        "grep -q '@jest-environment jsdom' __tests__/TodoList.test.tsx",
        "npm test -- --testPathPatterns=\"TodoList\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["components/TodoList.tsx", "__tests__/TodoList.test.tsx"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-2/stories/S-003"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-003 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-003",
  "title": "EventForm component",
  "description": "Controlled React form component for creating new calendar events.",
  "branchName": "ralph/sprint-2/story-S-003",
  "sprint": "sprint-2",
  "priority": 3,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "components/EventForm.tsx and __tests__/EventForm.test.tsx",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create components/EventForm.tsx",
      "context": "Create components/EventForm.tsx. Add 'use client' as the first line.\nImport CalendarEvent from '@/lib/types' and useState from 'react'.\n\nDefine and export default:\n  interface Props {\n    onAdd: (event: CalendarEvent) => void\n  }\n\n  export default function EventForm({ onAdd }: Props) {\n    const [title, setTitle] = useState('')\n    const [date, setDate] = useState('')\n\n    const handleSubmit = (e: React.FormEvent) => {\n      e.preventDefault()\n      if (!title.trim() || !date) return\n      onAdd({ id: `e-${Date.now()}`, title: title.trim(), date, linkedTodoIds: [] })\n      setTitle('')\n      setDate('')\n    }\n\n    return (\n      <form data-testid=\"event-form\" onSubmit={handleSubmit}>\n        <input\n          data-testid=\"event-title-input\"\n          value={title}\n          onChange={e => setTitle(e.target.value)}\n          placeholder=\"Event title\"\n        />\n        <input\n          data-testid=\"event-date-input\"\n          type=\"date\"\n          value={date}\n          onChange={e => setDate(e.target.value)}\n        />\n        <button type=\"submit\" data-testid=\"submit-event\">Add Event</button>\n      </form>\n    )\n  }\n\nCommit the file.",
      "scope": ["components/EventForm.tsx"],
      "acceptance": "components/EventForm.tsx exists, exports default EventForm, uses 'use client'. TypeScript strict typecheck passes.",
      "checks": [
        "test -f components/EventForm.tsx",
        "grep -q \"'use client'\" components/EventForm.tsx",
        "grep -q 'event-form' components/EventForm.tsx",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/EventForm.test.tsx — React Testing Library tests",
      "context": "Create __tests__/EventForm.test.tsx. The file MUST start with these lines:\n  /**\n   * @jest-environment jsdom\n   */\n\nThen:\n  import '@testing-library/jest-dom'\n  import { render, screen, fireEvent } from '@testing-library/react'\n  import EventForm from '../components/EventForm'\n  import type { CalendarEvent } from '../lib/types'\n\n  describe('EventForm', () => {\n    it('renders form with inputs and submit button', () => {\n      render(<EventForm onAdd={() => {}} />)\n      expect(screen.getByTestId('event-form')).toBeInTheDocument()\n      expect(screen.getByTestId('event-title-input')).toBeInTheDocument()\n      expect(screen.getByTestId('event-date-input')).toBeInTheDocument()\n      expect(screen.getByTestId('submit-event')).toBeInTheDocument()\n    })\n\n    it('calls onAdd with event data on submit', () => {\n      const onAdd = jest.fn()\n      render(<EventForm onAdd={onAdd} />)\n      fireEvent.change(screen.getByTestId('event-title-input'), { target: { value: 'Team Sync' } })\n      fireEvent.change(screen.getByTestId('event-date-input'), { target: { value: '2024-05-01' } })\n      fireEvent.submit(screen.getByTestId('event-form'))\n      expect(onAdd).toHaveBeenCalledTimes(1)\n      const submitted = onAdd.mock.calls[0][0] as CalendarEvent\n      expect(submitted.title).toBe('Team Sync')\n      expect(submitted.date).toBe('2024-05-01')\n    })\n\n    it('clears inputs after submit', () => {\n      render(<EventForm onAdd={() => {}} />)\n      const titleInput = screen.getByTestId('event-title-input') as HTMLInputElement\n      const dateInput = screen.getByTestId('event-date-input') as HTMLInputElement\n      fireEvent.change(titleInput, { target: { value: 'Test Event' } })\n      fireEvent.change(dateInput, { target: { value: '2024-05-01' } })\n      fireEvent.submit(screen.getByTestId('event-form'))\n      expect(titleInput.value).toBe('')\n      expect(dateInput.value).toBe('')\n    })\n\n    it('does not call onAdd when title is empty', () => {\n      const onAdd = jest.fn()\n      render(<EventForm onAdd={onAdd} />)\n      fireEvent.change(screen.getByTestId('event-date-input'), { target: { value: '2024-05-01' } })\n      fireEvent.submit(screen.getByTestId('event-form'))\n      expect(onAdd).not.toHaveBeenCalled()\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/EventForm.test.tsx"],
      "acceptance": "__tests__/EventForm.test.tsx exists with passing React Testing Library tests.",
      "checks": [
        "test -f __tests__/EventForm.test.tsx",
        "grep -q '@jest-environment jsdom' __tests__/EventForm.test.tsx",
        "npm test -- --testPathPatterns=\"EventForm\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["components/EventForm.tsx", "__tests__/EventForm.test.tsx"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-2/stories/S-004"
(cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-story.sh import-story S-004 -) <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-004",
  "title": "CalendarApp integration component",
  "description": "Main client component wiring EventForm, CalendarView, and TodoList via useState-managed stores.",
  "branchName": "ralph/sprint-2/story-S-004",
  "sprint": "sprint-2",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "components/CalendarApp.tsx, app/page.tsx, __tests__/CalendarApp.test.tsx",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create components/CalendarApp.tsx",
      "context": "Create components/CalendarApp.tsx. Add 'use client' as the first line.\nImport: useState from 'react'; CalendarStore from '@/lib/calendarService'; TodoStore from '@/lib/todoService'; CalendarEvent, Todo from '@/lib/types'; CalendarView from './CalendarView'; TodoList from './TodoList'; EventForm from './EventForm'.\n\nExport default:\n  export default function CalendarApp() {\n    const [calStore] = useState(() => new CalendarStore())\n    const [todoStore] = useState(() => new TodoStore())\n    const [events, setEvents] = useState<CalendarEvent[]>([])\n    const [todos, setTodos] = useState<Todo[]>([])\n\n    const handleAddEvent = (event: CalendarEvent) => {\n      calStore.addEvent(event)\n      setEvents(calStore.getAllEvents())\n    }\n    const handleRemoveEvent = (id: string) => {\n      calStore.removeEvent(id)\n      setEvents(calStore.getAllEvents())\n    }\n    const handleCreateTodo = (todo: Todo) => {\n      todoStore.createTodo(todo)\n      setTodos(todoStore.getAllTodos())\n    }\n    const handleCompleteTodo = (id: string) => {\n      todoStore.completeTodo(id)\n      setTodos(todoStore.getAllTodos())\n    }\n    const handleDeleteTodo = (id: string) => {\n      todoStore.deleteTodo(id)\n      setTodos(todoStore.getAllTodos())\n    }\n\n    return (\n      <main data-testid=\"calendar-app\">\n        <h1>Calendar &amp; Todo App</h1>\n        <EventForm onAdd={handleAddEvent} />\n        <CalendarView events={events} onRemove={handleRemoveEvent} />\n        <TodoList todos={todos} onComplete={handleCompleteTodo} onDelete={handleDeleteTodo} />\n      </main>\n    )\n  }\n\nCommit the file.",
      "scope": ["components/CalendarApp.tsx"],
      "acceptance": "components/CalendarApp.tsx exists, exports default CalendarApp, wires all sub-components. TypeScript strict typecheck passes.",
      "checks": [
        "test -f components/CalendarApp.tsx",
        "grep -q \"'use client'\" components/CalendarApp.tsx",
        "grep -q 'CalendarView' components/CalendarApp.tsx",
        "grep -q 'TodoList' components/CalendarApp.tsx",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update app/page.tsx to render CalendarApp",
      "context": "Update app/page.tsx. Replace its content with:\n  import CalendarApp from '@/components/CalendarApp'\n\n  export default function Home() {\n    return <CalendarApp />\n  }\n\nThis is a server component that simply delegates to the CalendarApp client component.\nCommit the change.",
      "scope": ["app/page.tsx"],
      "acceptance": "app/page.tsx imports and renders CalendarApp. Build succeeds.",
      "checks": [
        "grep -q 'CalendarApp' app/page.tsx",
        "npm run build"
      ],
      "depends_on": ["T-01"],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Create __tests__/CalendarApp.test.tsx — integration tests",
      "context": "Create __tests__/CalendarApp.test.tsx. The file MUST start with:\n  /**\n   * @jest-environment jsdom\n   */\n\nThen:\n  import '@testing-library/jest-dom'\n  import { render, screen, fireEvent } from '@testing-library/react'\n  import CalendarApp from '../components/CalendarApp'\n\n  describe('CalendarApp', () => {\n    it('renders the app container', () => {\n      render(<CalendarApp />)\n      expect(screen.getByTestId('calendar-app')).toBeInTheDocument()\n    })\n\n    it('starts with empty state', () => {\n      render(<CalendarApp />)\n      expect(screen.getByTestId('empty-state')).toBeInTheDocument()\n      expect(screen.getByTestId('empty-todos')).toBeInTheDocument()\n    })\n\n    it('adds an event via the form', () => {\n      render(<CalendarApp />)\n      fireEvent.change(screen.getByTestId('event-title-input'), { target: { value: 'Kickoff' } })\n      fireEvent.change(screen.getByTestId('event-date-input'), { target: { value: '2024-06-01' } })\n      fireEvent.submit(screen.getByTestId('event-form'))\n      expect(screen.getByTestId('calendar-view')).toBeInTheDocument()\n      expect(screen.getByText('Kickoff')).toBeInTheDocument()\n    })\n\n    it('removes an event', () => {\n      render(<CalendarApp />)\n      fireEvent.change(screen.getByTestId('event-title-input'), { target: { value: 'Temp' } })\n      fireEvent.change(screen.getByTestId('event-date-input'), { target: { value: '2024-06-02' } })\n      fireEvent.submit(screen.getByTestId('event-form'))\n      const removeButtons = screen.getAllByText('Remove')\n      fireEvent.click(removeButtons[0])\n      expect(screen.getByTestId('empty-state')).toBeInTheDocument()\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/CalendarApp.test.tsx"],
      "acceptance": "__tests__/CalendarApp.test.tsx exists with passing integration tests.",
      "checks": [
        "test -f __tests__/CalendarApp.test.tsx",
        "grep -q '@jest-environment jsdom' __tests__/CalendarApp.test.tsx",
        "npm test -- --testPathPatterns=\"CalendarApp\\.test\""
      ],
      "depends_on": ["T-01"],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-04",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["components/CalendarApp.tsx", "app/page.tsx", "__tests__/CalendarApp.test.tsx"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-03"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

commit_baseline "$NEXTJS_DIR" "chore(smoke): nextjs-calendar sprint-2 plan"

else  # sprint 1 failed — skip sprint 2 for nextjs
  NEXTJS_S2_SKIPPED=1
  log ""
  log "=== Skipping nextjs-calendar sprint-2 (sprint-1 did not complete successfully) ==="
fi


# ══════════════════════════════════════════════════════════════════════════════
#  SPRINT 2 SETUP: angular-calendar  (UI layer — standalone components)
# ══════════════════════════════════════════════════════════════════════════════

if [ "$ANGULAR_EXIT" -eq 0 ] && [ "$ANGULAR_COMMIT_EXIT" -eq 0 ]; then

log ""
log "=== Setting up angular-calendar sprint-2 (UI components) ==="

# No new npm packages needed for Angular — class-only component tests use plain Jest
mkdir -p "$ANGULAR_DIR/src/app/components/calendar"
mkdir -p "$ANGULAR_DIR/src/app/components/todo-list"
mkdir -p "$ANGULAR_DIR/src/app/components/event-form"

(
  cd "$ANGULAR_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-2 > "$LOG_DIR/angular-sprint2-create.log" 2>&1
  assert_contains "$LOG_DIR/angular-sprint2-create.log" "Created sprint: sprint-2"

  ./ralph-story.sh add --title "CalendarComponent standalone" \
    --goal "Build a standalone Angular component rendering a calendar events list with remove output." \
    --prompt-context "Create src/app/components/calendar/calendar.component.ts standalone with Input events, Output removeEvent EventEmitter." \
    > "$LOG_DIR/angular-story-add-S2-001.log" 2>&1

  ./ralph-story.sh add --title "TodoListComponent standalone" --depends-on S-001 \
    --goal "Build a standalone Angular component rendering todo items with complete and delete outputs." \
    --prompt-context "Create src/app/components/todo-list/todo-list.component.ts standalone with Input todos, Output completeItem and deleteItem EventEmitters." \
    > "$LOG_DIR/angular-story-add-S2-002.log" 2>&1

  ./ralph-story.sh add --title "EventFormComponent standalone" --depends-on S-001 \
    --goal "Build a standalone Angular form component for adding new calendar events." \
    --prompt-context "Create src/app/components/event-form/event-form.component.ts standalone with eventTitle/eventDate properties, onSubmit() emitting addEvent EventEmitter." \
    > "$LOG_DIR/angular-story-add-S2-003.log" 2>&1

  ./ralph-story.sh add --title "AppComponent orchestration with signals" --depends-on S-001 --depends-on S-002 --depends-on S-003 \
    --goal "Update the main AppComponent to use Angular signals and orchestrate all sub-components." \
    --prompt-context "Update src/app/app.component.ts (or app.ts) to import CalendarComponent, TodoListComponent, EventFormComponent. Use signal<CalendarEvent[]> and signal<Todo[]> for reactive state." \
    > "$LOG_DIR/angular-story-add-S2-004.log" 2>&1

)

# ── Angular sprint-2 story.json definitions ────────────────────────────────────

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-2/stories/S-001"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-001 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-001",
  "title": "CalendarComponent standalone",
  "description": "Standalone Angular component rendering calendar events list with remove output.",
  "branchName": "ralph/sprint-2/story-S-001",
  "sprint": "sprint-2",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "src/app/components/calendar/calendar.component.ts and calendar.component.spec.ts",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/components/calendar/calendar.component.ts",
      "context": "Create src/app/components/calendar/calendar.component.ts.\nImport: Component, Input, Output, EventEmitter from '@angular/core'; CalendarEvent from '../../models'.\n\nExport:\n  @Component({\n    selector: 'app-calendar',\n    standalone: true,\n    template: `\n      <div>\n        @if (events.length === 0) {\n          <p>No events scheduled.</p>\n        }\n        @for (event of events; track event.id) {\n          <div>\n            <span>{{ event.title }}</span>\n            <span>{{ event.date }}</span>\n            <button (click)=\"onRemoveClick(event.id)\">Remove</button>\n          </div>\n        }\n      </div>\n    `\n  })\n  export class CalendarComponent {\n    @Input() events: CalendarEvent[] = []\n    @Output() removeEvent = new EventEmitter<string>()\n\n    onRemoveClick(id: string): void {\n      this.removeEvent.emit(id)\n    }\n  }\n\nCommit the file.",
      "scope": ["src/app/components/calendar/calendar.component.ts"],
      "acceptance": "calendar.component.ts exists, exports class CalendarComponent, standalone: true, has removeEvent Output. TypeScript typecheck passes.",
      "checks": [
        "test -f src/app/components/calendar/calendar.component.ts",
        "grep -q 'CalendarComponent' src/app/components/calendar/calendar.component.ts",
        "grep -q 'standalone: true' src/app/components/calendar/calendar.component.ts",
        "grep -q 'removeEvent' src/app/components/calendar/calendar.component.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/components/calendar/calendar.component.spec.ts — class-only Jest tests",
      "context": "Create src/app/components/calendar/calendar.component.spec.ts.\nImport: CalendarComponent from './calendar.component'; CalendarEvent from '../../models'.\nDo NOT use TestBed. Instantiate CalendarComponent with new.\n\nWrite Jest tests:\n  import { CalendarComponent } from './calendar.component'\n  import { CalendarEvent } from '../../models'\n\n  describe('CalendarComponent', () => {\n    let component: CalendarComponent\n\n    beforeEach(() => {\n      component = new CalendarComponent()\n    })\n\n    it('initializes with empty events', () => {\n      expect(component.events).toEqual([])\n    })\n\n    it('accepts events via Input', () => {\n      const events: CalendarEvent[] = [\n        new CalendarEvent('e1', 'Meeting', '2024-04-01'),\n        new CalendarEvent('e2', 'Review', '2024-04-02'),\n      ]\n      component.events = events\n      expect(component.events).toHaveLength(2)\n      expect(component.events[0].title).toBe('Meeting')\n    })\n\n    it('emits removeEvent when onRemoveClick is called', () => {\n      const emitted: string[] = []\n      component.removeEvent.subscribe((id: string) => emitted.push(id))\n      component.onRemoveClick('e1')\n      expect(emitted).toEqual(['e1'])\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/components/calendar/calendar.component.spec.ts"],
      "acceptance": "calendar.component.spec.ts exists with passing class-only Jest tests (no TestBed).",
      "checks": [
        "test -f src/app/components/calendar/calendar.component.spec.ts",
        "npm test -- --testPathPatterns=\"calendar\\.component\\.spec\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/components/calendar/calendar.component.ts", "src/app/components/calendar/calendar.component.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-2/stories/S-002"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-002 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-002",
  "title": "TodoListComponent standalone",
  "description": "Standalone Angular component rendering todo items with complete and delete outputs.",
  "branchName": "ralph/sprint-2/story-S-002",
  "sprint": "sprint-2",
  "priority": 2,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "src/app/components/todo-list/todo-list.component.ts and todo-list.component.spec.ts",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/components/todo-list/todo-list.component.ts",
      "context": "Create src/app/components/todo-list/todo-list.component.ts.\nImport: Component, Input, Output, EventEmitter from '@angular/core'; Todo from '../../models'.\n\nExport:\n  @Component({\n    selector: 'app-todo-list',\n    standalone: true,\n    template: `\n      <ul>\n        @for (todo of todos; track todo.id) {\n          <li>\n            <span [style.textDecoration]=\"todo.done ? 'line-through' : 'none'\">{{ todo.title }}</span>\n            <span>[{{ todo.priority }}]</span>\n            <button (click)=\"onCompleteClick(todo.id)\" [disabled]=\"todo.done\">Complete</button>\n            <button (click)=\"onDeleteClick(todo.id)\">Delete</button>\n          </li>\n        }\n      </ul>\n    `\n  })\n  export class TodoListComponent {\n    @Input() todos: Todo[] = []\n    @Output() completeItem = new EventEmitter<string>()\n    @Output() deleteItem = new EventEmitter<string>()\n\n    onCompleteClick(id: string): void { this.completeItem.emit(id) }\n    onDeleteClick(id: string): void { this.deleteItem.emit(id) }\n  }\n\nCommit the file.",
      "scope": ["src/app/components/todo-list/todo-list.component.ts"],
      "acceptance": "todo-list.component.ts exists, exports TodoListComponent, standalone: true, has completeItem and deleteItem Outputs. TypeScript typecheck passes.",
      "checks": [
        "test -f src/app/components/todo-list/todo-list.component.ts",
        "grep -q 'TodoListComponent' src/app/components/todo-list/todo-list.component.ts",
        "grep -q 'standalone: true' src/app/components/todo-list/todo-list.component.ts",
        "grep -q 'completeItem' src/app/components/todo-list/todo-list.component.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/components/todo-list/todo-list.component.spec.ts — class-only Jest tests",
      "context": "Create src/app/components/todo-list/todo-list.component.spec.ts.\nImport: TodoListComponent from './todo-list.component'; Todo from '../../models'.\nDo NOT use TestBed. Instantiate with new.\n\n  import { TodoListComponent } from './todo-list.component'\n  import { Todo } from '../../models'\n\n  describe('TodoListComponent', () => {\n    let component: TodoListComponent\n\n    beforeEach(() => {\n      component = new TodoListComponent()\n    })\n\n    it('initializes with empty todos', () => {\n      expect(component.todos).toEqual([])\n    })\n\n    it('accepts todos via Input', () => {\n      component.todos = [\n        new Todo('t1', 'Buy groceries', 'high'),\n        new Todo('t2', 'Write docs', 'low'),\n      ]\n      expect(component.todos).toHaveLength(2)\n      expect(component.todos[0].priority).toBe('high')\n    })\n\n    it('emits completeItem when onCompleteClick is called', () => {\n      const emitted: string[] = []\n      component.completeItem.subscribe((id: string) => emitted.push(id))\n      component.onCompleteClick('t1')\n      expect(emitted).toEqual(['t1'])\n    })\n\n    it('emits deleteItem when onDeleteClick is called', () => {\n      const emitted: string[] = []\n      component.deleteItem.subscribe((id: string) => emitted.push(id))\n      component.onDeleteClick('t2')\n      expect(emitted).toEqual(['t2'])\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/components/todo-list/todo-list.component.spec.ts"],
      "acceptance": "todo-list.component.spec.ts exists with passing class-only Jest tests.",
      "checks": [
        "test -f src/app/components/todo-list/todo-list.component.spec.ts",
        "npm test -- --testPathPatterns=\"todo-list\\.component\\.spec\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/components/todo-list/todo-list.component.ts", "src/app/components/todo-list/todo-list.component.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-2/stories/S-003"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-003 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-003",
  "title": "EventFormComponent standalone",
  "description": "Standalone Angular form component for creating new calendar events.",
  "branchName": "ralph/sprint-2/story-S-003",
  "sprint": "sprint-2",
  "priority": 3,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "src/app/components/event-form/event-form.component.ts and event-form.component.spec.ts",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/components/event-form/event-form.component.ts",
      "context": "Create src/app/components/event-form/event-form.component.ts.\nImport: Component, Output, EventEmitter from '@angular/core'; FormsModule from '@angular/forms'; CalendarEvent from '../../models'.\n\nExport:\n  @Component({\n    selector: 'app-event-form',\n    standalone: true,\n    imports: [FormsModule],\n    template: `\n      <form (ngSubmit)=\"onSubmit()\">\n        <input [(ngModel)]=\"eventTitle\" name=\"eventTitle\" placeholder=\"Event title\" />\n        <input [(ngModel)]=\"eventDate\" name=\"eventDate\" type=\"date\" />\n        <button type=\"submit\">Add Event</button>\n      </form>\n    `\n  })\n  export class EventFormComponent {\n    eventTitle: string = ''\n    eventDate: string = ''\n    @Output() addEvent = new EventEmitter<CalendarEvent>()\n\n    onSubmit(): void {\n      if (!this.eventTitle.trim() || !this.eventDate) return\n      this.addEvent.emit(new CalendarEvent(\n        `e-${Date.now()}`,\n        this.eventTitle.trim(),\n        this.eventDate\n      ))\n      this.eventTitle = ''\n      this.eventDate = ''\n    }\n  }\n\nCommit the file.",
      "scope": ["src/app/components/event-form/event-form.component.ts"],
      "acceptance": "event-form.component.ts exists, exports EventFormComponent, standalone: true, has addEvent Output. TypeScript typecheck passes.",
      "checks": [
        "test -f src/app/components/event-form/event-form.component.ts",
        "grep -q 'EventFormComponent' src/app/components/event-form/event-form.component.ts",
        "grep -q 'standalone: true' src/app/components/event-form/event-form.component.ts",
        "grep -q 'addEvent' src/app/components/event-form/event-form.component.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/components/event-form/event-form.component.spec.ts — class-only Jest tests",
      "context": "Create src/app/components/event-form/event-form.component.spec.ts.\nImport: EventFormComponent from './event-form.component'; CalendarEvent from '../../models'.\nDo NOT use TestBed. Instantiate with new.\n\n  import { EventFormComponent } from './event-form.component'\n  import { CalendarEvent } from '../../models'\n\n  describe('EventFormComponent', () => {\n    let component: EventFormComponent\n\n    beforeEach(() => {\n      component = new EventFormComponent()\n    })\n\n    it('initializes with empty fields', () => {\n      expect(component.eventTitle).toBe('')\n      expect(component.eventDate).toBe('')\n    })\n\n    it('emits addEvent with correct data on valid submit', () => {\n      const emitted: CalendarEvent[] = []\n      component.addEvent.subscribe((e: CalendarEvent) => emitted.push(e))\n      component.eventTitle = 'Sprint Planning'\n      component.eventDate = '2024-05-15'\n      component.onSubmit()\n      expect(emitted).toHaveLength(1)\n      expect(emitted[0].title).toBe('Sprint Planning')\n      expect(emitted[0].date).toBe('2024-05-15')\n    })\n\n    it('clears fields after valid submit', () => {\n      component.eventTitle = 'Sprint Planning'\n      component.eventDate = '2024-05-15'\n      component.onSubmit()\n      expect(component.eventTitle).toBe('')\n      expect(component.eventDate).toBe('')\n    })\n\n    it('does not emit when title is empty', () => {\n      const emitted: CalendarEvent[] = []\n      component.addEvent.subscribe((e: CalendarEvent) => emitted.push(e))\n      component.eventTitle = ''\n      component.eventDate = '2024-05-15'\n      component.onSubmit()\n      expect(emitted).toHaveLength(0)\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/components/event-form/event-form.component.spec.ts"],
      "acceptance": "event-form.component.spec.ts exists with passing class-only Jest tests.",
      "checks": [
        "test -f src/app/components/event-form/event-form.component.spec.ts",
        "npm test -- --testPathPatterns=\"event-form\\.component\\.spec\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/components/event-form/event-form.component.ts", "src/app/components/event-form/event-form.component.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-2/stories/S-004"
(cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-story.sh import-story S-004 -) <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-004",
  "title": "AppComponent orchestration with signals",
  "description": "Update AppComponent to use Angular signals and orchestrate CalendarComponent, TodoListComponent, and EventFormComponent.",
  "branchName": "ralph/sprint-2/story-S-004",
  "sprint": "sprint-2",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "src/app/app.component.ts (or app.ts) and src/app/app.spec.ts",
    "preserved_invariants": [
      "All sprint-1 tests must continue to pass",
      "TypeScript strict mode must remain satisfied"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update AppComponent to use signals and orchestrate sub-components",
      "context": "Find the main app component file — it will be src/app/app.component.ts or src/app/app.ts (check which exists). Replace its entire content with the following:\n\n  import { Component, signal } from '@angular/core'\n  import { CalendarService } from './services/calendar.service'\n  import { TodoService } from './services/todo.service'\n  import { CalendarComponent } from './components/calendar/calendar.component'\n  import { TodoListComponent } from './components/todo-list/todo-list.component'\n  import { EventFormComponent } from './components/event-form/event-form.component'\n  import { CalendarEvent, Todo } from './models'\n\n  @Component({\n    selector: 'app-root',\n    standalone: true,\n    imports: [CalendarComponent, TodoListComponent, EventFormComponent],\n    template: `\n      <main>\n        <h1>Calendar &amp; Todo App</h1>\n        <app-event-form (addEvent)=\"handleAddEvent($event)\" />\n        <app-calendar [events]=\"events()\" (removeEvent)=\"handleRemoveEvent($event)\" />\n        <app-todo-list [todos]=\"todos()\" (completeItem)=\"handleCompleteItem($event)\" (deleteItem)=\"handleDeleteItem($event)\" />\n      </main>\n    `\n  })\n  export class AppComponent {\n    private calSvc = new CalendarService()\n    private todoSvc = new TodoService()\n    events = signal<CalendarEvent[]>([])\n    todos = signal<Todo[]>([])\n\n    handleAddEvent(event: CalendarEvent): void {\n      this.calSvc.addEvent(event)\n      this.events.set(this.calSvc.getAllEvents())\n    }\n    handleRemoveEvent(id: string): void {\n      this.calSvc.removeEvent(id)\n      this.events.set(this.calSvc.getAllEvents())\n    }\n    handleCompleteItem(id: string): void {\n      this.todoSvc.complete(id)\n      this.todos.set(this.todoSvc.getAll())\n    }\n    handleDeleteItem(id: string): void {\n      this.todoSvc.delete(id)\n      this.todos.set(this.todoSvc.getAll())\n    }\n  }\n\nCommit the change.",
      "scope": ["src/app/app.component.ts"],
      "acceptance": "AppComponent imports and uses CalendarComponent, TodoListComponent, EventFormComponent. Uses signal<> for events and todos. TypeScript typecheck passes.",
      "checks": [
        "grep -rq 'CalendarComponent' src/app/",
        "grep -rq 'signal' src/app/app.component.ts 2>/dev/null || grep -rq 'signal' src/app/app.ts 2>/dev/null",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update src/app/app.spec.ts — signal and orchestration tests",
      "context": "Replace the entire content of src/app/app.spec.ts with:\n\n  import { AppComponent } from './app.component'\n  import { CalendarEvent, Todo } from './models'\n\n  describe('AppComponent', () => {\n    let component: AppComponent\n\n    beforeEach(() => {\n      component = new AppComponent()\n    })\n\n    it('initializes with empty signals', () => {\n      expect(component.events()).toEqual([])\n      expect(component.todos()).toEqual([])\n    })\n\n    it('handleAddEvent adds event and updates signal', () => {\n      const event = new CalendarEvent('e1', 'Standup', '2024-06-01')\n      component.handleAddEvent(event)\n      expect(component.events()).toHaveLength(1)\n      expect(component.events()[0].title).toBe('Standup')\n    })\n\n    it('handleRemoveEvent removes event and updates signal', () => {\n      component.handleAddEvent(new CalendarEvent('e1', 'Standup', '2024-06-01'))\n      component.handleAddEvent(new CalendarEvent('e2', 'Retro', '2024-06-02'))\n      component.handleRemoveEvent('e1')\n      expect(component.events()).toHaveLength(1)\n      expect(component.events()[0].id).toBe('e2')\n    })\n\n    it('handleCompleteItem marks todo done and updates signal', () => {\n      const todo = new Todo('t1', 'Prepare slides', 'high')\n      component.todoSvc_test = component['todoSvc']\n      component['todoSvc'].create(todo)\n      component.todos.set(component['todoSvc'].getAll())\n      component.handleCompleteItem('t1')\n      expect(component.todos()[0].done).toBe(true)\n    })\n  })\n\nNOTE: If accessing private todoSvc directly in tests causes TypeScript errors, simplify by only testing handleAddEvent, handleRemoveEvent without accessing private members. Write the tests that compile cleanly. Commit the file.",
      "scope": ["src/app/app.spec.ts"],
      "acceptance": "src/app/app.spec.ts updated with passing Jest tests exercising signal-based state mutations.",
      "checks": [
        "test -f src/app/app.spec.ts",
        "npm test -- --testPathPatterns=\"app\\.spec\"",
        "npm run typecheck"
      ],
      "depends_on": ["T-01"],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/app.component.ts", "src/app/app.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

commit_baseline "$ANGULAR_DIR" "chore(smoke): angular-calendar sprint-2 plan"

else  # sprint 1 failed — skip sprint 2 for angular
  ANGULAR_S2_SKIPPED=1
  log ""
  log "=== Skipping angular-calendar sprint-2 (sprint-1 did not complete successfully) ==="
fi


# ══════════════════════════════════════════════════════════════════════════════
#  VALIDATION PHASE 2
# ══════════════════════════════════════════════════════════════════════════════

if [ "$NEXTJS_S2_SKIPPED" -eq 0 ] || [ "$ANGULAR_S2_SKIPPED" -eq 0 ]; then
  log ""
  log "════════════════════════════════════════"
  log "  VALIDATION PHASE 2"
  log "════════════════════════════════════════"

  for proj_label in nextjs angular; do
    if [ "$proj_label" = "nextjs" ]; then
      proj_dir="$NEXTJS_DIR"
      [ "$NEXTJS_S2_SKIPPED" -eq 0 ] || continue
    else
      proj_dir="$ANGULAR_DIR"
      [ "$ANGULAR_S2_SKIPPED" -eq 0 ] || continue
    fi

    ralph_dir="$proj_dir/scripts/ralph"
    log ""
    log "--- Validating $proj_label-calendar sprint-2 ---"

    validate_sprint "$ralph_dir" "sprint-2"

    for sid in S-001 S-002 S-003 S-004; do
      hlog="$LOG_DIR/${proj_label}-s2-health-${sid}.log"
      if ! (cd "$ralph_dir" && ./ralph-story.sh health "$sid" > "$hlog" 2>&1); then
        log "  FAIL: health check for $proj_label sprint-2 $sid — see $hlog"
        cat "$hlog" >&2
        fail "Story health check failed: $proj_label sprint-2 $sid"
      fi
      log "  health OK: $proj_label sprint-2 $sid"
    done

    # Lifecycle coverage: planned → ready → active via prepare-all + sprint use
    prepare_and_activate "$proj_dir" "$proj_label" "sprint-2"
  done

  log ""
  log "Sprint-2 validation complete."
fi


# ══════════════════════════════════════════════════════════════════════════════
#  EXECUTION PHASE 2
# ══════════════════════════════════════════════════════════════════════════════

if [ "$NEXTJS_S2_SKIPPED" -eq 0 ] || [ "$ANGULAR_S2_SKIPPED" -eq 0 ]; then
  log ""
  log "════════════════════════════════════════"
  log "  EXECUTION PHASE 2"
  log "════════════════════════════════════════"
fi

if [ "$NEXTJS_S2_SKIPPED" -eq 0 ]; then
  log ""
  log "--- Running nextjs-calendar sprint-2 ---"
  run_sprint "$NEXTJS_DIR" "nextjs" "sprint-2" || NEXTJS_S2_EXIT=$?

  if [ "$NEXTJS_S2_EXIT" -eq 0 ]; then
    log ""
    log "--- Post-sprint: nextjs-calendar sprint-2 ---"
    (cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-status.sh) \
      > "$LOG_DIR/nextjs-sprint-2-status.log" 2>&1 || true
    log "  ralph-status logged to: $LOG_DIR/nextjs-sprint-2-status.log"
    run_sprint_commit "$NEXTJS_DIR" "nextjs" "sprint-2" || NEXTJS_S2_COMMIT_EXIT=$?
  fi
fi

if [ "$ANGULAR_S2_SKIPPED" -eq 0 ]; then
  log ""
  log "--- Running angular-calendar sprint-2 ---"
  run_sprint "$ANGULAR_DIR" "angular" "sprint-2" || ANGULAR_S2_EXIT=$?

  if [ "$ANGULAR_S2_EXIT" -eq 0 ]; then
    log ""
    log "--- Post-sprint: angular-calendar sprint-2 ---"
    (cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-status.sh) \
      > "$LOG_DIR/angular-sprint-2-status.log" 2>&1 || true
    log "  ralph-status logged to: $LOG_DIR/angular-sprint-2-status.log"
    run_sprint_commit "$ANGULAR_DIR" "angular" "sprint-2" || ANGULAR_S2_COMMIT_EXIT=$?
  fi
fi


# ══════════════════════════════════════════════════════════════════════════════
#  REPORT PHASE
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "════════════════════════════════════════"
log "  FINAL REPORT"
log "════════════════════════════════════════"

overall_exit=0

# Helper: report one sprint for one project
report_sprint() {
  local proj_label="$1"
  local proj_dir="$2"
  local sprint="$3"
  local sprint_exit="$4"
  local commit_exit="$5"
  local skipped="${6:-0}"

  local sprint_log="$LOG_DIR/${proj_label}-${sprint}.log"
  local stories_file="$proj_dir/scripts/ralph/sprints/$sprint/stories.json"

  echo ""
  echo "── $proj_label-calendar / $sprint ─────────────────────────────────"

  if [ "$skipped" -eq 1 ]; then
    echo "  SKIPPED (prerequisite sprint did not complete)"
    return
  fi

  # Story completion from stories.json
  if [ -f "$stories_file" ]; then
    done_count="$(count_stories_done "$stories_file")"
    total_count="$(jq '.stories | length' "$stories_file" 2>/dev/null || echo '?')"
    echo "  Stories done: $done_count / $total_count"
    jq -r '.stories[] | "  \(.id): \(.status) (passes=\(.passes))"' "$stories_file" 2>/dev/null || true
  else
    echo "  WARNING: stories.json not found"
  fi

  # Story status lines from log
  if [ -f "$sprint_log" ]; then
    echo ""
    echo "  Loop output summary:"
    extract_story_status "$sprint_log" | sed 's/^/    /' || echo "    (no story-complete markers found)"

    # Structural failures
    struct_failures="$(extract_structural_failures "$sprint_log")"
    if [ -n "$struct_failures" ]; then
      echo ""
      echo "  Structural failures caught (short-circuited early):"
      echo "$struct_failures" | sed 's/^/    /'
    fi

    # Task failures
    task_failures="$(extract_task_failures "$sprint_log")"
    if [ -n "$task_failures" ]; then
      echo ""
      echo "  Tasks that exhausted retries:"
      echo "$task_failures" | sed 's/^/    /'
      overall_exit=1
    fi
  fi

  # Sprint exit
  if [ "$sprint_exit" -eq 0 ]; then
    echo ""
    echo "  Sprint exit: PASS"
  else
    echo ""
    echo "  Sprint exit: FAIL (exit $sprint_exit)"
    overall_exit=1
  fi

  # Post-sprint assertions
  echo ""
  echo "  Post-sprint assertions:"

  if [ -f "$stories_file" ]; then
    if jq -e 'all(.stories[]; .status == "done" and .passes == true)' \
         "$stories_file" > /dev/null 2>&1; then
      echo "    All stories done=true, passes=true: PASS"
    else
      echo "    Some stories not done/passing: FAIL"
      overall_exit=1
    fi
  fi

  # Sprint commit
  if [ "$sprint_exit" -eq 0 ]; then
    if [ "$commit_exit" -eq 0 ]; then
      sprint_status="$(jq -r '.status // "unknown"' "$stories_file" 2>/dev/null || echo "unknown")"
      echo "    ralph-sprint-commit: PASS (status=$sprint_status)"
    else
      echo "    ralph-sprint-commit: FAIL"
      overall_exit=1
    fi
  fi
}

# ── Sprint 1 results ───────────────────────────────────────────────────────────

echo ""
echo "════ SPRINT 1 RESULTS ════════════════════════════════════════"

report_sprint "nextjs"   "$NEXTJS_DIR"   "sprint-1" "$NEXTJS_EXIT"   "$NEXTJS_COMMIT_EXIT"
report_sprint "angular"  "$ANGULAR_DIR"  "sprint-1" "$ANGULAR_EXIT"  "$ANGULAR_COMMIT_EXIT"

# ralph-verify runs once per project after the last completed sprint
for proj_label in nextjs angular; do
  if [ "$proj_label" = "nextjs" ]; then
    proj_dir="$NEXTJS_DIR"
    s1_exit=$NEXTJS_EXIT; s1_commit=$NEXTJS_COMMIT_EXIT
    s2_exit=$NEXTJS_S2_EXIT; s2_commit=$NEXTJS_S2_COMMIT_EXIT; s2_skipped=$NEXTJS_S2_SKIPPED
  else
    proj_dir="$ANGULAR_DIR"
    s1_exit=$ANGULAR_EXIT; s1_commit=$ANGULAR_COMMIT_EXIT
    s2_exit=$ANGULAR_S2_EXIT; s2_commit=$ANGULAR_S2_COMMIT_EXIT; s2_skipped=$ANGULAR_S2_SKIPPED
  fi

  # Verify after the last successfully committed sprint
  if [ "$s2_skipped" -eq 0 ] && [ "$s2_exit" -eq 0 ] && [ "$s2_commit" -eq 0 ]; then
    verify_log="$LOG_DIR/${proj_label}-verify.log"
    echo ""
    echo "── $proj_label-calendar / post-sprint-2 ralph-verify ─────"
    if (cd "$proj_dir/scripts/ralph" && ./ralph-verify.sh --full) > "$verify_log" 2>&1; then
      echo "    ralph-verify --full: PASS"
    else
      echo "    ralph-verify --full: FAIL"
      overall_exit=1
    fi
  elif [ "$s1_exit" -eq 0 ] && [ "$s1_commit" -eq 0 ]; then
    verify_log="$LOG_DIR/${proj_label}-verify.log"
    echo ""
    echo "── $proj_label-calendar / post-sprint-1 ralph-verify ─────"
    if (cd "$proj_dir/scripts/ralph" && ./ralph-verify.sh --full) > "$verify_log" 2>&1; then
      echo "    ralph-verify --full: PASS"
    else
      echo "    ralph-verify --full: FAIL"
      overall_exit=1
    fi
  fi
done

# ── Sprint 2 results ───────────────────────────────────────────────────────────

if [ "$NEXTJS_S2_SKIPPED" -eq 0 ] || [ "$ANGULAR_S2_SKIPPED" -eq 0 ]; then
  echo ""
  echo "════ SPRINT 2 RESULTS ════════════════════════════════════════"

  report_sprint "nextjs"   "$NEXTJS_DIR"   "sprint-2" "$NEXTJS_S2_EXIT"   "$NEXTJS_S2_COMMIT_EXIT"  "$NEXTJS_S2_SKIPPED"
  report_sprint "angular"  "$ANGULAR_DIR"  "sprint-2" "$ANGULAR_S2_EXIT"  "$ANGULAR_S2_COMMIT_EXIT" "$ANGULAR_S2_SKIPPED"
fi

# ── Behavioral observations ────────────────────────────────────────────────────

echo ""
echo "── Behavioral observations ───────────────────────────────────"
for proj_label in nextjs angular; do
  for sprint in sprint-1 sprint-2; do
    sprint_log="$LOG_DIR/${proj_label}-${sprint}.log"
    [ -f "$sprint_log" ] || continue
    retries="$(awk '/Retrying\.\.\./{c++} END{print c+0}' "$sprint_log" 2>/dev/null || echo 0)"
    structural="$(grep -c "STRUCTURAL FAILURE" "$sprint_log" 2>/dev/null; true)"
    blocked="$(grep -c "BLOCKED — dependencies" "$sprint_log" 2>/dev/null; true)"
    echo "  $proj_label/$sprint: retries=$retries  structural_short_circuits=$structural  blocked=$blocked"
  done
done

# ── Efficiency metrics ─────────────────────────────────────────────────────────

echo ""
echo "── efficiency metrics ────────────────────────────────────────"
total_tokens_all=0
total_stories_all=0
for proj_label in nextjs angular; do
  proj_tokens=0
  proj_stories=0
  proj_generate_tokens=0
  for sid in S-001 S-002 S-003 S-004; do
    proj_generate_tokens=$((proj_generate_tokens + $(extract_tokens_from_log "$LOG_DIR/${proj_label}-generate-${sid}.log")))
  done
  for sprint in sprint-1 sprint-2; do
    sprint_log="$LOG_DIR/${proj_label}-${sprint}.log"
    [ -f "$sprint_log" ] || continue
    sprint_tokens="$(extract_tokens_from_log "$sprint_log")"
    sprint_stories="$(awk '/=== Story .* COMPLETE ===/ { c += 1 } END { print c + 0 }' "$sprint_log")"
    proj_tokens=$((proj_tokens + sprint_tokens))
    proj_stories=$((proj_stories + sprint_stories))
    echo "  $proj_label/$sprint: tokens=$sprint_tokens stories_completed=$sprint_stories"
  done
  if [ "$proj_generate_tokens" -gt 0 ]; then
    echo "  $proj_label/generate: tokens=$proj_generate_tokens"
    proj_tokens=$((proj_tokens + proj_generate_tokens))
  fi
  echo "  $proj_label TOTAL: tokens=$proj_tokens stories_completed=$proj_stories"
  total_tokens_all=$((total_tokens_all + proj_tokens))
  total_stories_all=$((total_stories_all + proj_stories))
done
if [ "$total_tokens_all" -eq 0 ]; then
  echo "  ALL: tokens=unavailable (no 'tokens used' markers in codex output) stories_completed=$total_stories_all"
else
  echo "  ALL: tokens=$total_tokens_all stories_completed=$total_stories_all"
fi
benchmark_set_tokens "$total_tokens_all"
benchmark_set_stories "$total_stories_all"

# ── Generation mode note ───────────────────────────────────────────────────────

if [ "$GENERATED" -eq 1 ]; then
  echo ""
  echo "  Mode: --generated (sprint-1 story.json files produced by ralph-story.sh generate)"
else
  echo ""
  echo "  Mode: default (framework-imported story.json task plans)"
fi

echo ""

if [ "$overall_exit" -eq 0 ]; then
  log "PASS — both calendar projects completed all sprints successfully"
else
  log "FAIL — one or more assertions failed (see above)"
fi

if [ "$KEEP" -eq 1 ]; then
  echo ""
  echo "[smoke] work dir retained for inspection: $WORK_DIR"
  echo "  nextjs:   $NEXTJS_DIR"
  echo "  angular:  $ANGULAR_DIR"
  echo "  logs:     $LOG_DIR"
fi
