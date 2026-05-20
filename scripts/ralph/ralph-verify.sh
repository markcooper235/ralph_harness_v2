#!/usr/bin/env bash
set -euo pipefail

MODE="targeted"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source "$SCRIPT_DIR/lib/search.sh"
IGNORE_FILE="$SCRIPT_DIR/known-test-baseline-failures.txt"
DEFAULT_FULL_IGNORE_PATTERNS=(
  "<rootDir>/tests/playwright/"
)

usage() {
  cat <<USAGE
Usage: ./scripts/ralph/ralph-verify.sh [--targeted|--full]

Modes:
  --targeted  Run typecheck, lint, and tests focused on changed files (default)
  --full      Run typecheck, lint, then full suite with known baseline failures ignored
USAGE
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targeted) MODE="targeted"; shift ;;
    --full) MODE="full"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$WORKSPACE_ROOT"

npm_has_script() {
  local script_name="$1"
  node -e '
    const fs = require("fs");
    const scriptName = process.argv[1];
    try {
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      const hasScript = !!(pkg.scripts && Object.prototype.hasOwnProperty.call(pkg.scripts, scriptName));
      process.exit(hasScript ? 0 : 1);
    } catch (error) {
      process.exit(1);
    }
  ' "$script_name"
}

run_optional_script() {
  local script_name="$1"
  if npm_has_script "$script_name"; then
    echo "[ralph-verify] running $script_name"
    npm run "$script_name"
    return 0
  fi

  echo "[ralph-verify] skipping $script_name (script not defined)"
  return 1
}

QUALITY_CHECKS_RAN=0
TEST_SCRIPT=""
TEST_SCRIPT_SUPPORTS_TARGETING=0

run_base_checks() {
  run_optional_script typecheck && QUALITY_CHECKS_RAN=1
  run_optional_script lint && QUALITY_CHECKS_RAN=1
  return 0
}

select_test_script() {
  if npm_has_script test; then
    TEST_SCRIPT="test"
    TEST_SCRIPT_SUPPORTS_TARGETING=1
    return 0
  fi

  if npm_has_script test:verify-regression; then
    TEST_SCRIPT="test:verify-regression"
    TEST_SCRIPT_SUPPORTS_TARGETING=0
    return 0
  fi

  if npm_has_script test:regression; then
    TEST_SCRIPT="test:regression"
    TEST_SCRIPT_SUPPORTS_TARGETING=0
    return 0
  fi

  fail "No runnable verification script found. Define at least one of: test, test:verify-regression, or test:regression."
}

run_selected_test_script() {
  if [ "$TEST_SCRIPT" = "test" ]; then
    npm test "$@"
    return 0
  fi

  if [ "$#" -gt 0 ]; then
    echo "[ralph-verify] $TEST_SCRIPT does not support targeted test selection; running the repo-defined regression command instead"
  fi

  npm run "$TEST_SCRIPT"
}

collect_changed_files() {
  {
    git diff --name-only --diff-filter=ACMRTUXB HEAD || true
    git ls-files --others --exclude-standard || true
  } | sed '/^$/d' | sort -u
}

list_repo_test_files() {
  list_test_files src app tests
}

append_matching_tests_for_source() {
  local source_path="$1"
  local tests_file="$2"
  local base dir stem dir_base

  base="$(basename "$source_path")"
  stem="${base%.*}"
  dir="$(dirname "$source_path")"
  dir_base="$(basename "$dir")"

  list_repo_test_files | while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
      *"/${stem}.test."*|*"/${stem}.spec."*)
        printf '%s\n' "$candidate"
        ;;
      *"/${dir_base}.test."*|*"/${dir_base}.spec."*)
        # Catch index/module-style sources like src/index.ts -> tests/hello.test.mjs
        if [ "$stem" = "index" ] || [ "$stem" = "main" ] || [ "$stem" = "mod" ]; then
          printf '%s\n' "$candidate"
        fi
        ;;
    esac
  done >> "$tests_file"
}

discover_targeted_tests() {
  local changed tests tmp_tests has_changed_source test_count repo_tests
  changed="$(collect_changed_files)"
  [ -n "$changed" ] || return 0

  tests=""
  tmp_tests="/tmp/ralph-targeted-tests.$$"
  : > "$tmp_tests"
  has_changed_source=0

  # Include changed test files directly.
  while IFS= read -r f; do
    case "$f" in
      *test.ts|*test.tsx|*test.js|*test.jsx|*test.mjs|*test.cjs|*spec.ts|*spec.tsx|*spec.js|*spec.jsx|*spec.mjs|*spec.cjs)
        [ -f "$f" ] && tests+="$f"$'\n'
        ;;
    esac
  done <<< "$changed"

  # For changed source files, infer related tests by source stem and common entrypoint/module patterns.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      src/*|app/*)
        has_changed_source=1
        append_matching_tests_for_source "$f" "$tmp_tests"
        ;;
    esac
  done <<< "$changed"

  if [ -s "$tmp_tests" ]; then
    tests+="$(sort -u "$tmp_tests")"$'\n'
  fi
  rm -f "$tmp_tests" || true

  tests="$(printf '%s' "$tests" | sed '/^$/d' | sort -u)"
  test_count="$(printf '%s\n' "$tests" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$has_changed_source" -eq 1 ] && [ "${test_count:-0}" -eq 0 ]; then
    repo_tests="$(list_repo_test_files | sed '/^$/d' | sort -u)"
    if [ "$(printf '%s\n' "$repo_tests" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ]; then
      tests="$repo_tests"
      test_count=1
    fi
  fi

  if [ "$has_changed_source" -eq 1 ] && [ "${test_count:-0}" -eq 0 ]; then
    echo "[ralph-verify] no related targeted tests inferred for changed source files; falling back to full test suite" >&2
    return 2
  fi

  printf '%s' "$tests"
}

build_ignore_regex() {
  {
    printf '%s\n' "${DEFAULT_FULL_IGNORE_PATTERNS[@]}"
    [ -f "$IGNORE_FILE" ] && awk 'NF && $1 !~ /^#/' "$IGNORE_FILE"
  } | sed '/^$/d' | sort -u | paste -sd'|' -
}

run_targeted_tests() {
  local tests discover_status
  discover_status=0
  tests="$(discover_targeted_tests)" || discover_status=$?
  if [ "$TEST_SCRIPT_SUPPORTS_TARGETING" -eq 0 ]; then
    echo "[ralph-verify] targeted selection unavailable via npm run $TEST_SCRIPT; running repo-defined verification instead"
    run_selected_test_script
    return 0
  fi
  if [ "$discover_status" -eq 2 ]; then
    run_full_suite
    return 0
  fi
  if [ -z "$tests" ]; then
    echo "[ralph-verify] no targeted test files inferred from changed files; falling back to full test suite"
    run_full_suite
    return 0
  fi

  echo "[ralph-verify] running targeted tests:"
  printf '%s\n' "$tests" | sed 's/^/  - /'
  # shellcheck disable=SC2206
  local args=( $tests )
  run_selected_test_script -- --runInBand --runTestsByPath "${args[@]}"
}

run_full_suite() {
  local ignore_re
  echo "[ralph-verify] running full test suite"
  if [ "$TEST_SCRIPT" = "test" ]; then
    ignore_re="$(build_ignore_regex || true)"
    if [ -n "$ignore_re" ]; then
      echo "[ralph-verify] applying known baseline ignore patterns from $IGNORE_FILE"
      run_selected_test_script -- --runInBand --testPathIgnorePatterns "$ignore_re"
    else
      run_selected_test_script -- --runInBand
    fi
    return 0
  fi

  run_selected_test_script
}

run_base_checks
select_test_script
if [ "$QUALITY_CHECKS_RAN" -eq 0 ]; then
  echo "[ralph-verify] no typecheck/lint scripts defined; relying on $TEST_SCRIPT for required verification"
fi
case "$MODE" in
  targeted) run_targeted_tests ;;
  full) run_full_suite ;;
  *) echo "Invalid mode: $MODE" >&2; exit 1 ;;
esac

echo "[ralph-verify] $MODE verification passed"
