#!/bin/bash
# e2e-profile-corpus.sh — Purpose-built benchmark corpus for profile mapping.
#
# This suite creates a small, fixed Next.js project and exercises a realistic
# story corpus that mirrors day-to-day work:
# - implementation
# - tests / verification
# - refactoring
# - documentation
# - code review hardening
# - devops / CI checks
#
# The corpus is defined in scripts/smoke/profile-benchmark-corpus.json and is
# intentionally stable so harness comparisons produce meaningful numbers.

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { local t=$1; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$t" "$@"; }
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORPUS_FILE="$SCRIPT_DIR/profile-benchmark-corpus.json"

# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"
# shellcheck source=./lib/token-parser.sh
source "$SCRIPT_DIR/lib/token-parser.sh"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-profile-corpus.tsv"
WORK_DIR="$(mktemp -d /tmp/ralph-profile-corpus.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

KEEP=0
REUSE_DIR=""
CODEX_BIN_VALUE="${CODEX_BIN:-codex}"
SMOKE_HARNESS="${SMOKE_HARNESS:-${RALPH_HARNESS:-codex}}"
SMOKE_MODEL="${SMOKE_MODEL:-${RALPH_MODEL:-}}"
SMOKE_AGENT="${SMOKE_AGENT:-${RALPH_AGENT:-}}"
SMOKE_BIN_DIR="$WORK_DIR/bin"
SMOKE_CODEX_BIN="$SMOKE_BIN_DIR/codex"
REAL_CODEX_BIN=""
RESULT_FIRST_POLICY=$'Benchmark policy: every task must produce a concrete result artifact or an explicit "no issues found" result. Audit tasks should write a findings/verdict artifact and include a shell check that verifies it exists or is non-empty. If a task changes code or files, it must include the normal verification checks for the changed surface (typecheck, lint, test, build, or equivalent). Do not emit empty-check tasks.'

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/e2e-profile-corpus.sh [--keep] [--reuse-dir DIR]

Runs a fixed benchmark corpus through Ralph using the selected harness.
The corpus is intentionally stable and representative of common day-to-day work.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --reuse-dir) REUSE_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { echo "[profile-corpus] $*"; }
fail() { echo "[profile-corpus] FAIL: $*" >&2; exit 1; }

ensure_specify() {
  if command -v specify >/dev/null 2>&1; then
    log "specify CLI found: $(command -v specify)"
    return 0
  fi
  fail "specify CLI must be available for this benchmark"
}

setup_codex_wrapper() {
  mkdir -p "$SMOKE_BIN_DIR"
  if [ "$SMOKE_HARNESS" = "codex" ]; then
    REAL_CODEX_BIN="$(command -v "$CODEX_BIN_VALUE" 2>/dev/null || true)"
    [ -n "$REAL_CODEX_BIN" ] || { fail "codex binary not found: $CODEX_BIN_VALUE"; }
    cat > "$SMOKE_CODEX_BIN" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--yolo" ] && [ "\${2:-}" = "exec" ]; then
  shift 2
  exec "$REAL_CODEX_BIN" --yolo exec --disable plugins --ignore-rules "\$@"
fi
if [ "\${1:-}" = "exec" ]; then
  shift
  exec "$REAL_CODEX_BIN" exec --disable plugins --ignore-rules "\$@"
fi
exec "$REAL_CODEX_BIN" "\$@"
EOF
    chmod +x "$SMOKE_CODEX_BIN"
  else
    : > "$SMOKE_CODEX_BIN"
    chmod +x "$SMOKE_CODEX_BIN"
  fi
  export PATH="$SMOKE_BIN_DIR:$PATH"
}

setup_project() {
  local proj_dir="$1"
  log "=== Setting up nextjs-phone-validator ==="
  cd "$WORK_DIR"
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

  cd "$proj_dir"
  git init -b main >/dev/null
  git config user.name "Ralph Corpus Smoke"
  git config user.email "ralph-corpus@example.com"

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

  mkdir -p lib components __tests__ .github/workflows

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
}

install_ralph() {
  local proj_dir="$1"
  log "  Installing Ralph..."
  "$REPO_ROOT/install.sh" \
    --project "$proj_dir" > "$LOG_DIR/install.log" 2>&1

  assert_file_exists "$proj_dir/scripts/ralph/ralph.sh"
  assert_file_exists "$proj_dir/scripts/ralph/ralph-story.sh"
  assert_file_exists "$proj_dir/scripts/ralph/ralph-sprint.sh"
  assert_file_exists "$proj_dir/scripts/ralph/doctor.sh"
}

validate_specify_artifacts() {
  local proj_dir="$1"
  local story_id="$2"
  local story_dir="$proj_dir/scripts/ralph/sprints/sprint-1/stories/$story_id/.specify"

  assert_file_exists "$story_dir/input.md"
  assert_file_exists "$story_dir/spec.md"
  assert_file_exists "$story_dir/plan.md"
  assert_file_exists "$story_dir/tasks.md"

  local spec_words
  spec_words="$(wc -w < "$story_dir/spec.md")"
  [ "$spec_words" -ge 50 ] || fail "[$story_id] spec.md too short ($spec_words words)"
}

validate_story_json() {
  local story_file="$1"
  assert_file_exists "$story_file"
  assert_json_expr "$story_file" '.tasks | length > 0'
  local bad_tasks
  bad_tasks="$(jq -r '.tasks[] | select((.checks | length) == 0) | .id' "$story_file")"
  [ -z "$bad_tasks" ] || fail "[$story_file] tasks with no checks: $bad_tasks"
}

run_story_pipeline() {
  local proj_dir="$1"
  local story_id="$2"
  local harness="$3"
  local model="${4:-}"
  local agent="${5:-}"
  local spec_log="$LOG_DIR/specify-${story_id}.log"
  local generate_log="$LOG_DIR/generate-${story_id}.log"
  local story_path="$proj_dir/scripts/ralph/sprints/sprint-1/stories/$story_id/story.json"

  log "  [$story_id] Specifying..."
  if ! (
    cd "$proj_dir/scripts/ralph" && \
    RALPH_HARNESS="$harness" RALPH_MODEL="$model" RALPH_AGENT="$agent" RALPH_STRUCTURED_OUTPUT=1 \
    ./ralph-story.sh specify "$story_id" --no-generate
  ) > "$spec_log" 2>&1; then
    cat "$spec_log" >&2
    fail "specify $story_id failed — see $spec_log"
  fi

  validate_specify_artifacts "$proj_dir" "$story_id"
  log "  [$story_id] specify PASS"

  log "  [$story_id] Generating story.json..."
  if ! (
    cd "$proj_dir/scripts/ralph" && CODEX_BIN="$SMOKE_CODEX_BIN" \
    RALPH_HARNESS="$harness" RALPH_MODEL="$model" RALPH_AGENT="$agent" RALPH_STRUCTURED_OUTPUT=1 \
    ./ralph-story.sh generate "$story_id"
  ) >> "$generate_log" 2>&1; then
    cat "$generate_log" >&2
    fail "generate $story_id failed — see $generate_log"
  fi

  validate_story_json "$story_path"
  log "  [$story_id] generate PASS"
}

write_story_corpus() {
  local proj_dir="$1"
  local corpus_path="$2"
  local active_sprint="sprint-1"
  cd "$proj_dir/scripts/ralph"
  while IFS= read -r story_json; do
    local sid title agent goal prompt_context
    sid="$(jq -r '.id' <<<"$story_json")"
    title="$(jq -r '.title' <<<"$story_json")"
    agent="$(jq -r '.agent' <<<"$story_json")"
    goal="$(jq -r '.goal' <<<"$story_json")"
    prompt_context="$(jq -r '.promptContext' <<<"$story_json")"
    prompt_context="${prompt_context}"$'\n\n'"${RESULT_FIRST_POLICY}"

    local -a add_args=(--id "$sid" --title "$title" --goal "$goal" --prompt-context "$prompt_context" --agent "$agent")
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      add_args+=(--depends-on "$dep")
    done < <(jq -r '.depends_on[]? // empty' <<<"$story_json")

    ./ralph-story.sh add "${add_args[@]}" >/dev/null
  done < <(jq -c '.stories[]' "$corpus_path")

  assert_file_exists "$proj_dir/scripts/ralph/sprints/$active_sprint/stories.json"
}

main() {
  ensure_specify
  setup_codex_wrapper

  if [ -n "$REUSE_DIR" ]; then
    WORK_DIR="$(cd "$REUSE_DIR" && pwd)"
    KEEP=1
  fi

  local proj_dir="$WORK_DIR/nextjs-phone-validator"
  local benchmark_label
  benchmark_label="$(basename "$BENCH_FILE" .tsv)"

  benchmark_init "profile-corpus" "$SMOKE_HARNESS" "$BENCH_FILE"
  trap 'code=$?; if [ "$KEEP" -eq 1 ] || [ "$code" -ne 0 ]; then echo ""; echo "[profile-corpus] work dir retained: $WORK_DIR"; else rm -rf "$WORK_DIR"; fi' EXIT
  log "work dir: $WORK_DIR"
  log "benchmark file: $BENCH_FILE"
  log "harness: $SMOKE_HARNESS"
  [ -n "$SMOKE_MODEL" ] && log "model override: $SMOKE_MODEL"
  [ -n "$SMOKE_AGENT" ] && log "agent override: $SMOKE_AGENT"

  benchmark_init "$benchmark_label" "$SMOKE_HARNESS" "$BENCH_FILE"

  setup_project "$proj_dir"
  install_ralph "$proj_dir"

  log "=== Creating sprint and benchmark stories ==="
  cd "$proj_dir/scripts/ralph"
  ./ralph-sprint.sh create sprint-1 > "$LOG_DIR/sprint-create.log" 2>&1
  assert_contains "$LOG_DIR/sprint-create.log" "Created sprint: sprint-1"
  assert_contains "$LOG_DIR/sprint-create.log" "Active sprint set to: sprint-1"
  write_story_corpus "$proj_dir" "$CORPUS_FILE"

  log "=== SpecKit specify + generate per corpus story ==="
  while IFS= read -r story_json; do
    local sid harness_model harness_agent
    sid="$(jq -r '.id' <<<"$story_json")"
    harness_model="$SMOKE_MODEL"
    harness_agent=""
    run_story_pipeline "$proj_dir" "$sid" "$SMOKE_HARNESS" "$harness_model" "$harness_agent"
  done < <(jq -c '.stories[]' "$CORPUS_FILE")

  log "  All corpus stories: specify + generate complete"

  log "=== Restaging sprint to planned ==="
  if ! (cd "$proj_dir/scripts/ralph" && ./ralph-sprint.sh restage sprint-1) > "$LOG_DIR/sprint-restage.log" 2>&1; then
    cat "$LOG_DIR/sprint-restage.log" >&2
    fail "sprint restage failed"
  fi
  log "  sprint restage PASS"

  log "=== Running prepare-all ==="
  palog="$LOG_DIR/prepare-all.log"
  PREPARE_EXIT=0
  if ! (
    cd "$proj_dir/scripts/ralph"
    env \
      RALPH_HARNESS="$SMOKE_HARNESS" \
      RALPH_MODEL="$SMOKE_MODEL" \
      RALPH_AGENT="$SMOKE_AGENT" \
      RALPH_STRUCTURED_OUTPUT=1 \
      ./ralph-story.sh prepare-all
  ) > "$palog" 2>&1; then
    cat "$palog" >&2
    PREPARE_EXIT=1
    log "WARN: prepare-all failed — see $palog"
  fi
  if [ "$PREPARE_EXIT" -eq 0 ]; then
    log "  prepare-all PASS"
  fi

  (
    cd "$proj_dir"
    git add scripts/ralph/sprints/sprint-1/stories scripts/ralph/sprints/sprint-1/stories.json
    if ! git diff --cached --quiet; then
      git commit -m "chore(ralph): commit prepared benchmark corpus" >/dev/null
    fi
  )

  sprint_harness_log="$LOG_DIR/sprint-harness.log"
  SPRINT_EXIT=1
  if [ "$PREPARE_EXIT" -eq 0 ]; then
    log "=== Activating sprint ==="
    if ! (cd "$proj_dir/scripts/ralph" && ./ralph-sprint.sh use sprint-1) > "$LOG_DIR/sprint-use.log" 2>&1; then
      cat "$LOG_DIR/sprint-use.log" >&2
      log "WARN: sprint use failed"
    else
      log "=== Running sprint ==="
      SPRINT_EXIT=0
      (
        cd "$proj_dir/scripts/ralph"
        timeout 2700 env CODEX_BIN="$SMOKE_CODEX_BIN" \
          RALPH_HARNESS="$SMOKE_HARNESS" RALPH_MODEL="$SMOKE_MODEL" RALPH_AGENT="$SMOKE_AGENT" RALPH_STRUCTURED_OUTPUT=1 \
          ./ralph.sh --max-retries 2 --continue-on-failure --harness "$SMOKE_HARNESS" \
          > "$sprint_harness_log" 2>&1
      ) || SPRINT_EXIT=$?
    fi
  fi

  COMMIT_EXIT=0
  if [ "$SPRINT_EXIT" -eq 0 ]; then
    (
      cd "$proj_dir"
      git add -A
      if ! git diff --cached --quiet; then
        git commit -m "chore: finalize benchmark corpus" >/dev/null
      fi
    )
  else
    COMMIT_EXIT=1
  fi

  VERIFY_EXIT=0
  if [ "$SPRINT_EXIT" -eq 0 ] && [ "$COMMIT_EXIT" -eq 0 ]; then
    if ! (cd "$proj_dir/scripts/ralph" && ./ralph-verify.sh --full) > "$LOG_DIR/verify.log" 2>&1; then
      VERIFY_EXIT=1
    fi
  else
    VERIFY_EXIT=1
  fi

  local specify_tokens generate_tokens sprint_tokens total_tokens stories_completed retry_count
  specify_tokens=0
  generate_tokens=0
  while IFS= read -r story_json; do
    sid="$(jq -r '.id' <<<"$story_json")"
    specify_tokens=$((specify_tokens + $(extract_tokens_from_log "$LOG_DIR/specify-${sid}.log")))
    generate_tokens=$((generate_tokens + $(extract_tokens_from_log "$LOG_DIR/generate-${sid}.log")))
  done < <(jq -c '.stories[]' "$CORPUS_FILE")
  sprint_tokens="$(extract_tokens_from_log "$sprint_harness_log")"
  total_tokens=$((specify_tokens + generate_tokens + sprint_tokens))
  stories_completed="$(awk '/=== Story .* COMPLETE ===/ { c += 1 } END { print c + 0 }' "$LOG_DIR/sprint-harness.log" 2>/dev/null || echo 0)"
  retry_count="$(awk '/Retrying\.\.\./{c++} END{print c+0}' "$LOG_DIR/sprint-harness.log" 2>/dev/null || echo 0)"

  benchmark_set_planning_tokens "$((specify_tokens + generate_tokens))"
  benchmark_set_execution_tokens "$sprint_tokens"
  benchmark_set_story_cycles "$stories_completed"
  benchmark_set_stories "$(jq '.stories | length' "$CORPUS_FILE")"
  benchmark_set_retries "$retry_count"

  echo ""
  echo "── corpus benchmark ───────────────────────────────────────"
  echo "  stories: $(jq '.stories | length' "$CORPUS_FILE")"
  echo "  tokens: specify=$specify_tokens generate=$generate_tokens sprint=$sprint_tokens total=$total_tokens"
  echo "  completed: $stories_completed"
  echo "  retries: $retry_count"
  echo "  sprint-run: $SPRINT_EXIT"
  echo "  commit: $COMMIT_EXIT"
  echo "  verify: $VERIFY_EXIT"

  local status="pass"
  [ "$PREPARE_EXIT" -eq 0 ] && [ "$SPRINT_EXIT" -eq 0 ] && [ "$COMMIT_EXIT" -eq 0 ] && [ "$VERIFY_EXIT" -eq 0 ] || status="fail"
  benchmark_set_notes "corpus=profile-benchmark-corpus;harness=$SMOKE_HARNESS"
  benchmark_append_row "$status"

  if [ "$status" = "pass" ]; then
    log "PASS — corpus benchmark completed"
  else
    log "FAIL — corpus benchmark did not complete cleanly"
  fi
}

main "$@"
