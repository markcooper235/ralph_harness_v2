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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targeted) MODE="targeted"; shift ;;
    --full) MODE="full"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$WORKSPACE_ROOT"

run_base_checks() {
  echo "[ralph-verify] running typecheck"
  npm run typecheck
  echo "[ralph-verify] running lint"
  npm run lint
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
  if [ "$discover_status" -eq 2 ]; then
    run_full_suite
    return 0
  fi
  if [ -z "$tests" ]; then
    echo "[ralph-verify] no targeted test files inferred from changed files; skipping targeted test run"
    return 0
  fi

  echo "[ralph-verify] running targeted tests:"
  printf '%s\n' "$tests" | sed 's/^/  - /'
  # shellcheck disable=SC2206
  local args=( $tests )
  npm test -- --runInBand --runTestsByPath "${args[@]}"
}

run_full_suite() {
  local ignore_re
  ignore_re="$(build_ignore_regex || true)"
  echo "[ralph-verify] running full test suite"
  if [ -n "$ignore_re" ]; then
    echo "[ralph-verify] applying known baseline ignore patterns from $IGNORE_FILE"
    npm test -- --runInBand --testPathIgnorePatterns "$ignore_re"
  else
    npm test -- --runInBand
  fi
}

run_base_checks
case "$MODE" in
  targeted) run_targeted_tests ;;
  full) run_full_suite ;;
  *) echo "Invalid mode: $MODE" >&2; exit 1 ;;
esac

echo "[ralph-verify] $MODE verification passed"
