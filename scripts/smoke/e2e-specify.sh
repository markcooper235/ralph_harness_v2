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
#   [per story, dep order]: specify (--no-generate) → validate .specify/ →
#     generate → normalize/reorder checks → validate story.json →
#   ralph-story.sh prepare-all (planned→ready) →
#   ralph-sprint.sh use (ready→active, lifecycle coverage) →
#   ralph.sh → ralph-sprint-commit.sh → ralph-verify.sh --full
#
# Stories:
#   S-001: PhoneValidatorService  — lib/phone-validator.ts + unit tests
#   S-002: PhoneInput component   — components/PhoneInput.tsx + RTL tests
#                                   (depends on S-001)
#   S-003: BatchValidator + App   — lib/batch-validator.ts + app/page.tsx
#                                   integration (depends on S-001, S-002)
#
# Usage:
#   ./scripts/smoke/e2e-specify.sh [--keep] [--max-retries N] [--reuse-dir DIR]
#
# Flags:
#   --keep            Keep work directory on success (always kept on failure)
#   --max-retries N   Retry count per task (default: 2)
#   --reuse-dir DIR   Skip project setup and specify/generate; reuse an
#                     existing work directory from a previous --keep run.
#                     Story branches left mid-run are reset to "ready".
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
# shellcheck source=./lib/token-parser.sh
source "$SCRIPT_DIR/lib/token-parser.sh"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-specify.tsv"

KEEP=0
MAX_RETRIES=2
REUSE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)        KEEP=1; shift ;;
    --max-retries) MAX_RETRIES="${2:-2}"; shift 2 ;;
    --reuse-dir)   REUSE_DIR="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$REUSE_DIR" ]; then
  [ -d "$REUSE_DIR" ] || { echo "ERROR: --reuse-dir: directory does not exist: $REUSE_DIR" >&2; exit 1; }
  WORK_DIR="$(cd "$REUSE_DIR" && pwd)"
  KEEP=1
else
  WORK_DIR="$(mktemp -d /tmp/ralph-specify-smoke.XXXXXX)"
fi
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

PROJ_DIR="$WORK_DIR/nextjs-phone-validator"

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
    echo "  project:  $PROJ_DIR"
    echo "  logs:     $LOG_DIR"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
benchmark_init "specify" "specify-pipeline" "$BENCH_FILE"

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

  # Each check must be syntactically valid shell
  local bad_checks=0 _chk
  while IFS= read -r _chk; do
    bash -n <<< "$_chk" 2>/dev/null || {
      log "  WARN [$story_id] syntax error in check: $_chk"
      bad_checks=$((bad_checks + 1))
    }
  done < <(jq -r '.tasks[].checks[]' "$story_file" 2>/dev/null)
  [ "$bad_checks" -eq 0 ] || fail "[$story_id] $bad_checks check(s) with bash syntax errors"

  local task_count
  task_count="$(jq '.tasks | length' "$story_file")"
  log "  [$story_id] story.json OK ($task_count tasks)"
}

# ── normalize_story_checks ─────────────────────────────────────────────────
# Fix rg escape sequences and add grep -E fallback in a story's story.json.

normalize_story_checks() {
  local story_id="$1"
  local _sf="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$story_id/story.json"
  [ -f "$_sf" ] || return 0
  local _tmp
  _tmp="$(mktemp)"
  jq '
    (.tasks[].checks[] |=
      if type == "string" then
        (if test("^rg ") then
           gsub("\\\\(?<c>[^ntrfaebsvdDwWsSpPhH0-9\\\\/\"])"; .c)
         else . end) |
        (if test("^rg \"[^\"]+\" [^ ]+$") then
           capture("^rg \"(?<pat>[^\"]+)\" (?<file>[^ ]+)$") |
           "rg -q \"\(.pat)\" \(.file) 2>/dev/null || grep -qE \"\(.pat)\" \(.file)"
         elif test("^rg -[a-zA-Z]+ \"[^\"]+\" [^ ]+$") then
           capture("^rg -[a-zA-Z]+ \"(?<pat>[^\"]+)\" (?<file>[^ ]+)$") |
           "rg -q \"\(.pat)\" \(.file) 2>/dev/null || grep -qE \"\(.pat)\" \(.file)"
         else . end)
      else . end
    )
  ' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"
  if jq -r '.tasks[].checks[]' "$_sf" 2>/dev/null \
      | grep -qE '^rg .*\\[\[\]\(\)]'; then
    fail "[$story_id] rg checks still contain unstripped \\[ \\] \\( \\) escapes"
  fi
}

# ── reorder_story_tasks ────────────────────────────────────────────────────
# Topological sort of story.json tasks, respecting depends_on constraints.
# Within each tier of simultaneously-eligible tasks, a title-based priority
# breaks ties: confirm(0) → implement(5) → integrate/default(10) → test(20)
# → final/regression(99).

reorder_story_tasks() {
  local story_id="$1"
  local _sf="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$story_id/story.json"
  [ -f "$_sf" ] || return 0
  local _tmp
  _tmp="$(mktemp)"
  jq '
    .tasks |= (
      . as $all |
      # Kahn topological sort: repeatedly emit the lowest-priority eligible task.
      # "Eligible" = all depends_on are already in the emitted set.
      reduce range(length) as $_ (
        { rem: $all, done: [] };
        (.done | map(.id)) as $placed |
        (
          .rem | map(select(
            .depends_on | length == 0
              or all(. as $d | $placed | any(. == $d))
          )) |
          sort_by(
            if   (.id    | test("final$"))
              or (.title | test("(?i)regression|final"))              then 99
            elif (.title | test("(?i)test|spec"))                     then 20
            elif (.title | test("(?i)integrat|home.*page|page.*app")) then 10
            elif (.title | test("(?i)implement|create|build|librar")) then  5
            elif (.title | test("(?i)confirm|depend|prerequisit"))    then  0
            else 10 end
          ) | .[0]
        ) as $next |
        if $next then
          { rem: (.rem | map(select(.id != $next.id))), done: (.done + [$next]) }
        else
          { rem: [], done: (.done + .rem) }
        end
      ) |
      .done
    )
  ' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Install specify CLI if missing
# ─────────────────────────────────────────────────────────────────────────────

log "=== Ensuring specify CLI is available ==="
ensure_specify

if [ -n "$REUSE_DIR" ]; then
  # ── --reuse-dir: skip project setup, validate existing project ──────────────
  log "=== Reusing existing work dir: $WORK_DIR ==="
  [ -d "$PROJ_DIR" ] \
    || fail "--reuse-dir: project directory missing: $PROJ_DIR"
  [ -f "$PROJ_DIR/scripts/ralph/ralph.sh" ] \
    || fail "--reuse-dir: ralph not installed in $PROJ_DIR/scripts/ralph"
  assert_file_exists "$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories.json"
  log "  Project and sprint structure OK"

  # Reset any story branches left mid-run: "active" → "ready", delete branches.
  log "  Cleaning up mid-run story state..."
  (
    cd "$PROJ_DIR"
    _sf="scripts/ralph/sprints/sprint-1/stories.json"

    # Switch to sprint branch — may be on a story branch from a partial run
    _cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [ "$_cur" != "ralph/sprint/sprint-1" ]; then
      git checkout ralph/sprint/sprint-1 2>/dev/null \
        || fail "Cannot checkout sprint branch for resume"
    fi

    # Reset active (stuck) stories → ready
    _tmp="$(mktemp)"
    jq '
      (.stories[] | select(.status == "active")) |= . + {"status": "ready"} |
      .activeStoryId = null
    ' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"

    # Delete stale story branches so ralph.sh can re-create them cleanly
    _stale_branches="$(git branch | grep -E 'ralph/sprint-[0-9]+/story-' \
                        | sed 's/^[* ]*//' || true)"
    if [ -n "$_stale_branches" ]; then
      while IFS= read -r _br; do
        [ -n "$_br" ] || continue
        git branch -D "$_br" 2>/dev/null && log "  Deleted stale branch: $_br" || true
      done <<< "$_stale_branches"
    fi

    git add "$_sf"
    git diff --cached --quiet \
      || git commit -m "chore(ralph): reset active stories to ready for resume" --quiet
  )
  log "  Mid-run cleanup complete"

else
  # ── Fresh run: create project from scratch ────────────────────────────────

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
  @testing-library/user-event \
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

# Prevent rg from scanning node_modules and .next during specify/generate
# Codex sessions — without this, rg scans node_modules/next/dist/docs and
# inflates session size 3-4x.
cat > .rgignore << 'EOF'
node_modules/
.next/
EOF

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
    --depends-on S-001 \
    --prompt-context "Create components/PhoneInput.tsx. Add 'use client' directive at the top. Props: value: string, onChange: (v: string) => void, onValidationChange?: (valid: boolean) => void. Render: an <input data-testid='phone-input'> for the phone number, a <span data-testid='validation-message'> showing 'Valid' or 'Invalid', and a <button data-testid='clear-button'> that calls onChange(''). Import PhoneValidatorService from '../lib/phone-validator'. Add @testing-library/react tests in __tests__/PhoneInput.test.tsx with @jest-environment jsdom." \
    > "$LOG_DIR/story-add-S-002.log" 2>&1

  ./ralph-story.sh add \
    --title "BatchValidator and app integration" \
    --goal "Implement a BatchValidator class in lib/batch-validator.ts and integrate the PhoneInput component into app/page.tsx." \
    --depends-on S-001 \
    --depends-on S-002 \
    --prompt-context "Create lib/batch-validator.ts. Export interface BatchResult { valid: string[]; invalid: string[]; summary: string }. Export class BatchValidator with method validateAll(phones: string[]): BatchResult — uses PhoneValidatorService.isValidFormat. Update app/page.tsx to import and render the PhoneInput component with useState for the phone value. Add integration tests in __tests__/batch-validator.test.ts." \
    > "$LOG_DIR/story-add-S-003.log" 2>&1
) || fail "Sprint and story setup failed"

_cur_branch="$(git -C "$PROJ_DIR" rev-parse --abbrev-ref HEAD)"
[ "$_cur_branch" = "ralph/sprint/sprint-1" ] \
  || fail "Sprint branch not checked out: expected 'ralph/sprint/sprint-1', got '$_cur_branch'"
log "  Sprint branch confirmed: $_cur_branch"

assert_file_exists "$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories.json"

fi  # end: fresh run vs --reuse-dir

# ─────────────────────────────────────────────────────────────────────────────
# STEPS 6-9: Specify + validate + generate + validate per story (dep order)
#
# Interleaving specify and generate for each story in dependency order ensures
# that when S-002 is specified, S-001's story.json already exists and is used
# as prior-story context. Running all specifies first (--no-generate) silently
# drops that context because story.json is absent at specify time (Bug 5).
#
# Per-story flow: specify → validate artifacts → generate → normalize/reorder
#                 checks → validate story.json
# ─────────────────────────────────────────────────────────────────────────────

log "=== SpecKit specify + generate per story (dependency order) ==="
glog="$LOG_DIR/generate-all.log"

for sid in S-001 S-002 S-003; do
  slog="$LOG_DIR/specify-${sid}.log"
  _sf="$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$sid/story.json"

  if [ -n "$REUSE_DIR" ] \
      && [ -f "$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories/$sid/.specify/spec.md" ] \
      && [ -f "$_sf" ]; then
    # --reuse-dir: artifacts already exist — validate only
    log "  [$sid] Reusing existing specify+generate artifacts"
    validate_specify_artifacts "$sid"
    log "  [$sid] specify PASS (reused)"
    validate_story_json "$sid"
    log "  [$sid] generate PASS (reused)"
    continue
  fi

  # STEP 6: specify — --no-generate keeps the specify phase independently testable
  log "  [$sid] Specifying..."
  if ! (cd "$PROJ_DIR/scripts/ralph" && \
        ./ralph-story.sh specify "$sid" --no-generate) > "$slog" 2>&1; then
    cat "$slog" >&2
    fail "specify $sid failed — see $slog"
  fi

  # STEP 7: validate .specify/ artifacts immediately
  validate_specify_artifacts "$sid"
  log "  [$sid] specify PASS"

  # STEP 8: generate story.json — makes this story's context available to the
  # next story's specify call (dep-context fix for Bug 5)
  log "  [$sid] Generating story.json..."
  if ! (cd "$PROJ_DIR/scripts/ralph" && CODEX_BIN=codex \
        ./ralph-story.sh generate "$sid") >> "$glog" 2>&1; then
    log "  [$sid] Retrying generate..."
    (cd "$PROJ_DIR/scripts/ralph" && CODEX_BIN=codex \
      ./ralph-story.sh generate "$sid" --force) >> "$glog" 2>&1 \
      || fail "generate $sid failed — see $glog"
  fi

  # STEP 9: validate story.json immediately
  validate_story_json "$sid"
  log "  [$sid] generate PASS"
done

log "  All stories: specify + generate complete"

# Reset sprint to "planned" now that specify+generate are done (both require
# an active sprint to resolve stories.json). We keep .active-sprint in place
# so prepare-all (which also calls specify-all/generate-all) can still resolve
# stories.json. After prepare-all promotes to "ready" we remove .active-sprint
# so that 'ralph-sprint.sh use' can complete the planned→ready→active path.
(
  cd "$PROJ_DIR/scripts/ralph"
  ./ralph-sprint.sh restage sprint-1
  git add sprints/sprint-1/stories.json
  git diff --cached --quiet \
    || git commit -m "chore(ralph): restage sprint for lifecycle test" --quiet
)
log "  Sprint restaged to 'planned' for lifecycle coverage"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: prepare-all — validate stories and promote to ready
#
# prepare-all = specify-all (no-op: artifacts exist) +
#               generate-all (no-op: story.json exists) +
#               health per story + promote planned → ready
# Using prepare-all exercises the full promotion code path and leaves stories
# in the correct "ready" state before sprint execution.
# ─────────────────────────────────────────────────────────────────────────────

log "=== Running prepare-all (validate and promote stories to ready) ==="
palog="$LOG_DIR/prepare-all.log"
if ! (cd "$PROJ_DIR/scripts/ralph" && ./ralph-story.sh prepare-all) > "$palog" 2>&1; then
  cat "$palog" >&2
  fail "prepare-all failed — see $palog"
fi
log "  prepare-all PASS"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10.5: Activate sprint via 'ralph-sprint.sh use' (Bug 2 lifecycle test)
#
# prepare-all promoted stories to "ready" and marked the sprint "ready".
# Activating via `use` exercises the planned → ready → active path that
# ralph-sprint.sh create bypasses (it activates directly without going through
# the ready state).
# ─────────────────────────────────────────────────────────────────────────────

log "=== Activating sprint via 'ralph-sprint.sh use' (lifecycle test) ==="
ulog="$LOG_DIR/sprint-use.log"
if ! (cd "$PROJ_DIR/scripts/ralph" && ./ralph-sprint.sh use sprint-1) > "$ulog" 2>&1; then
  cat "$ulog" >&2
  fail "'ralph-sprint.sh use sprint-1' failed — see $ulog"
fi

_sprint_status="$(jq -r '.status // "unknown"' \
  "$PROJ_DIR/scripts/ralph/sprints/sprint-1/stories.json" 2>/dev/null || echo "unknown")"
[ "$_sprint_status" = "active" ] \
  || fail "Sprint should be 'active' after 'use', got '$_sprint_status'"
assert_file_exists "$PROJ_DIR/scripts/ralph/.active-sprint"
log "  Sprint lifecycle PASS: planned → ready → active"

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
echo "  prepare-all:    PASS"
echo "  sprint-use:     PASS"
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

# ── Efficiency metrics ───────────────────────────────────────────────────────
specify_tokens=0
generate_tokens=0
sprint_tokens=0
for sid in S-001 S-002 S-003; do
  specify_tokens=$((specify_tokens + $(extract_tokens_from_log "$LOG_DIR/specify-${sid}.log")))
done
generate_tokens="$(extract_tokens_from_log "$LOG_DIR/generate-all.log")"
sprint_tokens="$(extract_tokens_from_log "$sprint_log")"
total_tokens=$((specify_tokens + generate_tokens + sprint_tokens))
stories_completed=0
if [ -f "$sprint_log" ]; then
  stories_completed="$(awk '/=== Story .* COMPLETE ===/ { c += 1 } END { print c + 0 }' "$sprint_log")"
fi
benchmark_set_tokens "$total_tokens"
benchmark_set_stories "$stories_completed"

echo ""
echo "── efficiency metrics ────────────────────────────────────────"
if [ "$total_tokens" -eq 0 ]; then
  echo "  tokens: unavailable (no 'tokens used' markers in codex output)"
else
  echo "  tokens: specify=$specify_tokens generate=$generate_tokens sprint=$sprint_tokens total=$total_tokens"
fi
echo "  stories completed: $stories_completed"

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
