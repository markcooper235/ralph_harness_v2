#!/bin/bash
# e2e-specify.sh — End-to-end SpecKit pipeline smoke test
#
# Exercises the full SpecKit → generate → sprint execution pipeline for a
# NextJS phone number validation project.
#
# Project: nextjs-phone-validator
#   A Next.js app with a phone number validation library and a React UI
#   component, built across 3 stories in a single sprint.
#
# Pipeline under test:
#   install.sh → doctor.sh → ralph-sprint.sh create → ralph-story.sh add →
#   ralph-story.sh specify (--no-generate, serial) → validate .specify/ →
#   ralph-story.sh generate-all → validate story.json →
#   ralph-story.sh health → ralph.sh → ralph-sprint-commit.sh →
#   ralph-verify.sh --full
#
# Stories:
#   S-001: PhoneValidatorService  — lib/phone-validator.ts + unit tests
#   S-002: PhoneInput component   — components/PhoneInput.tsx + RTL tests
#                                   (depends on S-001)
#   S-003: BatchValidator + App   — lib/batch-validator.ts + app/page.tsx
#                                   integration (depends on S-001, S-002)
#
# Usage:
#   ./scripts/smoke/e2e-specify.sh [--keep] [--max-retries N]
#
# Flags:
#   --keep          Keep work directory on success (always kept on failure)
#   --max-retries N Retry count per task (default: 2)
#
# Requires:
#   specify CLI (installed automatically via uv → pip → npx if missing)

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

KEEP=0
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)        KEEP=1; shift ;;
    --max-retries) MAX_RETRIES="${2:-2}"; shift 2 ;;
    -h|--help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

WORK_DIR="$(mktemp -d /tmp/ralph-specify-smoke.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

PROJ_DIR="$WORK_DIR/nextjs-phone-validator"

# ── Cleanup ────────────────────────────────────────────────────────────────────

cleanup() {
  local code=$?
  if [ "$KEEP" -eq 1 ] || [ "$code" -ne 0 ]; then
    echo ""
    echo "[smoke] work dir retained for inspection: $WORK_DIR"
    echo "  project:  $PROJ_DIR"
    echo "  logs:     $LOG_DIR"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# ── ensure_specify ─────────────────────────────────────────────────────────────
# Install the specify CLI if not already available.
# Priority: uv → pip → npx (persistent wrapper)

ensure_specify() {
  # Already on PATH?
  if command -v specify >/dev/null 2>&1; then
    log "specify CLI found: $(command -v specify)"
    return 0
  fi

  log "specify CLI not found — attempting install..."

  if command -v uv >/dev/null 2>&1; then
    log "  Installing via uv..."
    if uv tool install "git+https://github.com/github/spec-kit.git" \
         >> "$LOG_DIR/specify-install.log" 2>&1; then
      log "  Installed specify via uv."
      export PATH="$HOME/.local/bin:$PATH"
      return 0
    fi
    log "  uv install failed — trying pip..."
  fi

  if command -v pip >/dev/null 2>&1; then
    log "  Installing via pip..."
    if pip install "git+https://github.com/github/spec-kit.git" \
         >> "$LOG_DIR/specify-install.log" 2>&1; then
      log "  Installed specify via pip."
      return 0
    fi
    log "  pip install failed — falling back to npx wrapper..."
  fi

  if command -v npx >/dev/null 2>&1; then
    log "  specify will be invoked via npx (no persistent install)."
    # Create a thin wrapper so 'specify' resolves on PATH
    mkdir -p "$WORK_DIR/bin"
    printf '#!/bin/sh\nexec npx --yes specify "$@"\n' > "$WORK_DIR/bin/specify"
    chmod +x "$WORK_DIR/bin/specify"
    export PATH="$WORK_DIR/bin:$PATH"
    return 0
  fi

  fail "Cannot install specify CLI — uv, pip, and npx all unavailable."
}

# ── doctor_check ───────────────────────────────────────────────────────────────
# Run doctor.sh after install. Must NOT tolerate a missing specify CLI here —
# this test requires it for the specify pipeline.

doctor_check() {
  local dlog="$LOG_DIR/doctor.log"
  log "  Running doctor.sh..."
  if (cd "$PROJ_DIR/scripts/ralph" && CODEX_BIN=codex ./doctor.sh) > "$dlog" 2>&1; then
    log "  doctor.sh PASS"
  else
    cat "$dlog" >&2
    fail "doctor.sh failed — see $dlog (specify CLI must be installed for this test)"
  fi
}

# ── validate_specify_artifacts ─────────────────────────────────────────────────
# Assert that all three SpecKit artifacts were produced for a story.

validate_specify_artifacts() {
  local story_id="$1"
  local story_dir="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$story_id"
  local specify_dir="$story_dir/.specify"

  assert_dir_exists "$specify_dir"
  assert_file_exists "$specify_dir/input.md"
  assert_file_exists "$specify_dir/spec.md"
  assert_file_exists "$specify_dir/plan.md"
  assert_file_exists "$specify_dir/tasks.md"

  # Artifacts must be non-trivial
  local spec_words
  spec_words="$(wc -w < "$specify_dir/spec.md")"
  [ "$spec_words" -ge 50 ] \
    || fail "[$story_id] spec.md too short ($spec_words words) — SpecKit may not have run"

  log "  [$story_id] .specify/ artifacts OK (spec=$spec_words words)"
}

# ── validate_story_json ────────────────────────────────────────────────────────
# Assert that story.json was generated and has tasks with checks.

validate_story_json() {
  local story_id="$1"
  local story_file="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$story_id/story.json"

  assert_file_exists "$story_file"
  assert_json_expr "$story_file" '.tasks | length > 0'

  # Each task must have at least one check
  local bad_tasks
  bad_tasks="$(jq -r '.tasks[] | select((.checks | length) == 0) | .id' "$story_file")"
  [ -z "$bad_tasks" ] || fail "[$story_id] tasks with no checks: $bad_tasks"

  local task_count
  task_count="$(jq '.tasks | length' "$story_file")"
  log "  [$story_id] story.json OK ($task_count tasks)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Install specify CLI if missing
# ─────────────────────────────────────────────────────────────────────────────

log "=== Ensuring specify CLI is available ==="
ensure_specify

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Set up NextJS project
# ─────────────────────────────────────────────────────────────────────────────

log "=== Setting up nextjs-phone-validator ==="

cd "$WORK_DIR"
log "  Running create-next-app..."
npx create-next-app@latest nextjs-phone-validator \
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

cd "$PROJ_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

log "  Adding Jest + Testing Library..."
npm install --save-dev \
  jest @types/jest ts-jest jest-environment-node jest-environment-jsdom \
  @testing-library/react @testing-library/jest-dom \
  --silent \
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
        jsx: 'react-jsx',
      },
    }],
  },
  testEnvironment: 'node',
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/$1',
  },
  testMatch: ['**/__tests__/**/*.test.ts', '**/__tests__/**/*.test.tsx'],
  testPathIgnorePatterns: ['/node_modules/', '/.next/'],
}

export default config
TS

mkdir -p lib components __tests__

cat > lib/index.ts <<'TS'
export const APP_NAME = "nextjs-phone-validator"
export const APP_VERSION = "0.1.0"
TS

cat > __tests__/baseline.test.ts <<'TS'
import { APP_NAME, APP_VERSION } from '../lib/index'

describe('baseline', () => {
  it('exports APP_NAME', () => {
    expect(APP_NAME).toBe('nextjs-phone-validator')
  })
  it('exports APP_VERSION', () => {
    expect(typeof APP_VERSION).toBe('string')
  })
})
TS

git add .
git reset -- .next >/dev/null 2>&1 || true
git commit -m "chore: init nextjs-phone-validator" >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Install Ralph
# ─────────────────────────────────────────────────────────────────────────────

log "  Installing Ralph..."
HOME="$WORK_DIR/home-nextjs" "$REPO_ROOT/install.sh" \
  --project "$PROJ_DIR" > "$LOG_DIR/install.log" 2>&1

assert_file_exists "$PROJ_DIR/scripts/ralph/ralph.sh"
assert_file_exists "$PROJ_DIR/scripts/ralph/ralph-story.sh"
assert_file_exists "$PROJ_DIR/scripts/ralph/ralph-sprint.sh"
assert_file_exists "$PROJ_DIR/scripts/ralph/ralph-sprint-commit.sh"
assert_file_exists "$PROJ_DIR/scripts/ralph/doctor.sh"

# Write ralph-sprint-test.sh — required regression gate for sprint-commit
cat > "$PROJ_DIR/scripts/ralph/ralph-sprint-test.sh" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
npm run build && npm run typecheck && npm test
SH
chmod +x "$PROJ_DIR/scripts/ralph/ralph-sprint-test.sh"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Doctor check (specify CLI required)
# ─────────────────────────────────────────────────────────────────────────────

doctor_check

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Create sprint and add stories
# ─────────────────────────────────────────────────────────────────────────────

log "=== Creating sprint and stories ==="
(
  cd "$PROJ_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-1 > "$LOG_DIR/sprint-create.log" 2>&1
  assert_contains "$LOG_DIR/sprint-create.log" "Created sprint: sprint-1"

  ./ralph-story.sh add \
    --title "PhoneValidatorService" \
    --goal "Implement a phone number validation library in lib/phone-validator.ts with functions to validate format, normalise, classify type, and strip formatting." \
    --prompt-context "Create lib/phone-validator.ts. Export: isValidFormat(phone: string): boolean — accepts common US formats like (555) 867-5309, 555-867-5309, +15558675309. normalize(phone: string): string — returns digits only. getType(phone: string): 'mobile' | 'landline' | 'toll-free' | 'unknown' — toll-free when starts with 800/888/877/866/855/844/833. stripFormatting(phone: string): string — removes spaces, dashes, parens, dots. Add unit tests in __tests__/phone-validator.test.ts." \
    > "$LOG_DIR/story-add-S-001.log" 2>&1

  ./ralph-story.sh add \
    --title "PhoneInput React component" \
    --goal "Build a controlled PhoneInput React component in components/PhoneInput.tsx that validates input in real time using PhoneValidatorService." \
    --prompt-context "Create components/PhoneInput.tsx. Add 'use client' directive at the top. Props: value: string, onChange: (v: string) => void, onValidationChange?: (valid: boolean) => void. Render: an <input data-testid='phone-input'> for the phone number, a <span data-testid='validation-message'> showing 'Valid' or 'Invalid', and a <button data-testid='clear-button'> that calls onChange(''). Import PhoneValidatorService from '../lib/phone-validator'. Add @testing-library/react tests in __tests__/PhoneInput.test.tsx with @jest-environment jsdom." \
    > "$LOG_DIR/story-add-S-002.log" 2>&1

  ./ralph-story.sh add \
    --title "BatchValidator and app integration" \
    --goal "Implement a BatchValidator class in lib/batch-validator.ts and integrate the PhoneInput component into app/page.tsx." \
    --prompt-context "Create lib/batch-validator.ts. Export interface BatchResult { valid: string[]; invalid: string[]; summary: string }. Export class BatchValidator with method validateAll(phones: string[]): BatchResult — uses PhoneValidatorService.isValidFormat. Update app/page.tsx to import and render the PhoneInput component with useState for the phone value. Add integration tests in __tests__/batch-validator.test.ts." \
    > "$LOG_DIR/story-add-S-003.log" 2>&1

  # Patch story-level depends_on into stories.json.
  # ralph-story.sh add does not yet accept --depends-on (known framework gap).
  _sf="sprints/sprint-1/stories.json"
  _tmp="$(mktemp)"
  jq '
    .stories = [.stories[] |
      if   .id == "S-002" then .depends_on = ["S-001"]
      elif .id == "S-003" then .depends_on = ["S-001", "S-002"]
      else . end
    ]
  ' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"

  log "  stories.json patched with depends_on"
)

assert_file_exists "$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories.json"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Run specify (--no-generate) for each story — validates SpecKit
# ─────────────────────────────────────────────────────────────────────────────

log "=== Running SpecKit specify phase (serial, --no-generate) ==="

for sid in S-001 S-002 S-003; do
  slog="$LOG_DIR/specify-${sid}.log"
  log "  Specifying $sid..."
  if ! (cd "$PROJ_DIR/scripts/ralph" && CODEX_BIN=codex \
        ./ralph-story.sh specify "$sid" --no-generate) > "$slog" 2>&1; then
    cat "$slog" >&2
    fail "specify $sid failed — see $slog"
  fi
  log "  specify $sid PASS"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: Validate .specify/ artifacts for each story
# ─────────────────────────────────────────────────────────────────────────────

log "=== Validating SpecKit artifacts ==="

for sid in S-001 S-002 S-003; do
  validate_specify_artifacts "$sid"
done

log "  All SpecKit artifacts present and non-trivial"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: Generate story.json for all stories
# ─────────────────────────────────────────────────────────────────────────────

log "=== Running generate-all (serial to avoid stdin contention) ==="
glog="$LOG_DIR/generate-all.log"
(cd "$PROJ_DIR/scripts/ralph" && CODEX_BIN=codex \
  ./ralph-story.sh generate-all --jobs 1) > "$glog" 2>&1 || true

# Retry any story whose story.json is missing or lacks storyId (transient Codex error)
for _sid in S-001 S-002 S-003; do
  _sf="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$_sid/story.json"
  if [ ! -f "$_sf" ] || ! jq -e '.storyId' "$_sf" >/dev/null 2>&1; then
    log "  Retrying generate for $_sid..."
    (cd "$PROJ_DIR/scripts/ralph" && CODEX_BIN=codex \
      ./ralph-story.sh generate "$_sid" --force) >> "$glog" 2>&1 \
      || fail "generate retry failed for $_sid — see $glog"
  fi
done
log "  generate-all PASS"

# Normalize rg checks in generated story.json files.
# Codex emits rg patterns with \( \[ \] escapes that trigger parse errors in
# ripgrep's regex engine when combined (e.g. \[]) causes "unopened group").
# Convert unconditionally: rg "pattern" file → grep -qF "unescaped" file,
# stripping all \X escape sequences so fixed-string search is safe.
log "  Normalizing rg → grep -qF in generated story.json checks..."
for _sid in S-001 S-002 S-003; do
  _sf="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$_sid/story.json"
  [ -f "$_sf" ] || continue
  _tmp="$(mktemp)"
  jq '(.tasks[].checks[] |=
    if startswith("rg \"") then
      gsub("^rg \""; "grep -qF \"") | gsub("\\\\(?<c>.)"; .c)
    else . end
  )' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: Validate generated story.json files
# ─────────────────────────────────────────────────────────────────────────────

log "=== Validating generated story.json files ==="

for sid in S-001 S-002 S-003; do
  validate_story_json "$sid"
done

log "  All story.json files valid"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: Run health check to promote stories to ready
# ─────────────────────────────────────────────────────────────────────────────

log "=== Running health checks ==="
for sid in S-001 S-002 S-003; do
  hlog="$LOG_DIR/health-${sid}.log"
  if ! (cd "$PROJ_DIR/scripts/ralph" && ./ralph-story.sh health "$sid") > "$hlog" 2>&1; then
    cat "$hlog" >&2
    fail "health check failed for $sid — see $hlog"
  fi
  log "  health $sid PASS"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11: Execute sprint
# ─────────────────────────────────────────────────────────────────────────────

log "=== Running sprint ==="
sprint_log="$LOG_DIR/sprint-1.log"

# Wrap in a function so PIPESTATUS is captured before set -e can fire on a
# non-zero exit from ralph.sh (which exits 1 when any story is incomplete).
_run_sprint() {
  (
    cd "$PROJ_DIR/scripts/ralph"
    timeout 2700 env CODEX_BIN=codex \
      ./ralph.sh --max-retries "$MAX_RETRIES" --continue-on-failure \
      2>&1
  ) | tee "$sprint_log"
  return "${PIPESTATUS[0]}"
}

SPRINT_EXIT=0
_run_sprint || SPRINT_EXIT=$?

# ─────────────────────────────────────────────────────────────────────────────
# STEP 12: Sprint commit
# ─────────────────────────────────────────────────────────────────────────────

COMMIT_EXIT=0
if [ "$SPRINT_EXIT" -eq 0 ]; then
  # Commit any uncommitted changes left by the sprint (can happen when a
  # generated task's acceptance criteria say "remain uncommitted" but a prior
  # subtask still staged files).
  (
    cd "$PROJ_DIR"
    git add -A
    if ! git diff --cached --quiet; then
      log "  Committing leftover uncommitted changes before sprint-commit..."
      git commit -m "chore: finalize sprint-1 uncommitted changes" >/dev/null
    fi
  )

  log "=== Running sprint-commit ==="
  clog="$LOG_DIR/sprint-commit.log"
  if ! (cd "$PROJ_DIR/scripts/ralph" && ./ralph-sprint-commit.sh) > "$clog" 2>&1; then
    cat "$clog" >&2
    COMMIT_EXIT=1
  else
    # Assert sprint is now closed in stories.json
    stories_file="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories.json"
    sprint_status="$(jq -r '.status // "unknown"' "$stories_file" 2>/dev/null || echo "unknown")"
    [ "$sprint_status" = "closed" ] \
      || fail "sprint-commit: expected stories.json status=closed, got '$sprint_status'"
    log "  sprint-commit PASS (status=closed)"
  fi
else
  log "  Skipping sprint-commit (sprint did not complete cleanly)"
  COMMIT_EXIT=1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 13: Ralph verify
# ─────────────────────────────────────────────────────────────────────────────

VERIFY_EXIT=0
if [ "$SPRINT_EXIT" -eq 0 ] && [ "$COMMIT_EXIT" -eq 0 ]; then
  log "=== Running ralph-verify --full ==="
  vlog="$LOG_DIR/verify.log"
  if ! (cd "$PROJ_DIR/scripts/ralph" && ./ralph-verify.sh --full) > "$vlog" 2>&1; then
    cat "$vlog" >&2
    VERIFY_EXIT=1
  else
    log "  ralph-verify --full PASS"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# FINAL REPORT
# ─────────────────────────────────────────────────────────────────────────────

log ""
log "════════════════════════════════════════"
log "  FINAL REPORT"
log "════════════════════════════════════════"

echo ""
echo "── specify phase ─────────────────────────────────────────────"
for sid in S-001 S-002 S-003; do
  slog="$LOG_DIR/specify-${sid}.log"
  specify_dir="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$sid/.specify"
  if [ -f "$specify_dir/spec.md" ] && [ -f "$specify_dir/plan.md" ] && [ -f "$specify_dir/tasks.md" ]; then
    spec_words="$(wc -w < "$specify_dir/spec.md")"
    plan_words="$(wc -w < "$specify_dir/plan.md")"
    tasks_words="$(wc -w < "$specify_dir/tasks.md")"
    echo "  $sid: spec=${spec_words}w plan=${plan_words}w tasks=${tasks_words}w"
  else
    echo "  $sid: MISSING artifacts"
  fi
done

echo ""
echo "── generate phase ────────────────────────────────────────────"
for sid in S-001 S-002 S-003; do
  story_file="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$sid/story.json"
  if [ -f "$story_file" ]; then
    task_count="$(jq '.tasks | length' "$story_file" 2>/dev/null || echo '?')"
    echo "  $sid: story.json ($task_count tasks)"
  else
    echo "  $sid: story.json MISSING"
  fi
done

echo ""
echo "── sprint execution ──────────────────────────────────────────"
stories_file="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories.json"
if [ -f "$stories_file" ]; then
  done_count="$(jq '[.stories[] | select(.status == "done")] | length' "$stories_file" 2>/dev/null || echo 0)"
  total_count="$(jq '.stories | length' "$stories_file" 2>/dev/null || echo '?')"
  echo "  Stories done: $done_count / $total_count"
  jq -r '.stories[] | "  \(.id): \(.status) (passes=\(.passes))"' "$stories_file" 2>/dev/null || true
fi

if [ -f "$sprint_log" ]; then
  echo ""
  echo "  Loop output summary:"
  grep -E "=== Story S-[0-9]+ (COMPLETE|some tasks)" "$sprint_log" 2>/dev/null \
    | sed 's/^/    /' || echo "    (no story-complete markers found)"

  retries="$(awk '/Retrying\.\.\./{c++} END{print c+0}' "$sprint_log" 2>/dev/null || echo 0)"
  structural="$(grep -c "STRUCTURAL FAILURE" "$sprint_log" 2>/dev/null; true)"
  blocked="$(grep -c "BLOCKED — dependencies" "$sprint_log" 2>/dev/null; true)"
  echo ""
  echo "  Behavioral: retries=$retries  structural_short_circuits=$structural  blocked=$blocked"
fi

echo ""
echo "── pipeline stages ───────────────────────────────────────────"
echo "  specify-phase:  PASS"
echo "  generate-phase: PASS"
if [ "$SPRINT_EXIT" -eq 0 ]; then
  echo "  sprint-run:     PASS"
else
  echo "  sprint-run:     FAIL (exit $SPRINT_EXIT)"
fi
if [ "$COMMIT_EXIT" -eq 0 ]; then
  echo "  sprint-commit:  PASS"
else
  echo "  sprint-commit:  FAIL"
fi
if [ "$VERIFY_EXIT" -eq 0 ] && [ "$SPRINT_EXIT" -eq 0 ] && [ "$COMMIT_EXIT" -eq 0 ]; then
  echo "  ralph-verify:   PASS"
elif [ "$SPRINT_EXIT" -ne 0 ] || [ "$COMMIT_EXIT" -ne 0 ]; then
  echo "  ralph-verify:   SKIPPED"
else
  echo "  ralph-verify:   FAIL"
fi

echo ""

overall_exit=0
[ "$SPRINT_EXIT" -eq 0 ]  || overall_exit=1
[ "$COMMIT_EXIT" -eq 0 ]  || overall_exit=1
[ "$VERIFY_EXIT" -eq 0 ]  || overall_exit=1

if [ "$overall_exit" -eq 0 ]; then
  log "PASS — SpecKit pipeline completed end-to-end successfully"
else
  log "FAIL — one or more pipeline stages failed (see above)"
fi

if [ "$KEEP" -eq 1 ]; then
  echo ""
  echo "[smoke] work dir retained for inspection: $WORK_DIR"
  echo "  project:  $PROJ_DIR"
  echo "  logs:     $LOG_DIR"
fi

exit "$overall_exit"
