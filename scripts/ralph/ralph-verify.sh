#!/usr/bin/env bash
set -euo pipefail

MODE="targeted"
STORY_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCAL_VERIFY_ADAPTER="$SCRIPT_DIR/verify.local.sh"
IGNORE_FILE="$SCRIPT_DIR/known-test-baseline-failures.txt"
DEFAULT_FULL_IGNORE_PATTERNS=(
  "<rootDir>/tests/playwright/"
)

source "$SCRIPT_DIR/lib/search.sh"

if [ -f "$LOCAL_VERIFY_ADAPTER" ]; then
  # shellcheck source=/dev/null
  source "$LOCAL_VERIFY_ADAPTER"
fi

usage() {
  cat <<USAGE
Usage: ./scripts/ralph/ralph-verify.sh [--targeted|--full] [--story-final] [--story PATH]

Modes:
  --targeted    Run repo verification focused on changed files (default)
  --full        Run repo full verification
  --story-final Compatibility alias for --full

Repo adapters:
  - Define repo-specific behavior in scripts/ralph/verify.local.sh
  - If no adapter is present, Ralph falls back to built-in Node.js or Python defaults
USAGE
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

has_function() {
  declare -F "$1" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targeted) MODE="targeted"; shift ;;
    --full) MODE="full"; shift ;;
    --story-final) MODE="full"; shift ;;
    --story) STORY_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$WORKSPACE_ROOT"

QUALITY_CHECKS_RAN=0
TEST_SCRIPT=""
TEST_SCRIPT_SUPPORTS_TARGETING=0

collect_changed_files() {
  {
    git diff --name-only --diff-filter=ACMRTUXB HEAD || true
    git ls-files --others --exclude-standard || true
  } | sed '/^$/d' | sort -u
}

list_repo_test_files() {
  list_test_files src app tests
}

detect_builtin_adapter() {
  if [ -f package.json ]; then
    printf 'node\n'
    return 0
  fi

  if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ] || [ -f setup.py ] || [ -d tests ]; then
    printf 'python\n'
    return 0
  fi

  return 1
}

builtin_adapter() {
  if has_function ralph_verify_adapter_name; then
    ralph_verify_adapter_name
    return 0
  fi

  detect_builtin_adapter
}

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

select_node_test_script() {
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

run_selected_node_test_script() {
  if [ "$TEST_SCRIPT" = "test" ]; then
    npm test "$@"
    return 0
  fi

  if [ "$#" -gt 0 ]; then
    echo "[ralph-verify] $TEST_SCRIPT does not support targeted test selection; running the repo-defined regression command instead"
  fi

  npm run "$TEST_SCRIPT"
}

append_matching_node_tests_for_source() {
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
        if [ "$stem" = "index" ] || [ "$stem" = "main" ] || [ "$stem" = "mod" ]; then
          printf '%s\n' "$candidate"
        fi
        ;;
    esac
  done >> "$tests_file"
}

discover_node_targeted_tests() {
  local changed tests tmp_tests has_changed_source test_count repo_tests
  changed="$(collect_changed_files)"
  [ -n "$changed" ] || return 0

  tests=""
  tmp_tests="/tmp/ralph-targeted-tests.$$"
  : > "$tmp_tests"
  has_changed_source=0

  while IFS= read -r f; do
    case "$f" in
      *test.ts|*test.tsx|*test.js|*test.jsx|*test.mjs|*test.cjs|*spec.ts|*spec.tsx|*spec.js|*spec.jsx|*spec.mjs|*spec.cjs)
        [ -f "$f" ] && tests+="$f"$'\n'
        ;;
    esac
  done <<< "$changed"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      src/*|app/*)
        has_changed_source=1
        append_matching_node_tests_for_source "$f" "$tmp_tests"
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

detect_python_bin() {
  if [ -x .venv/bin/python ]; then
    printf '.venv/bin/python\n'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3\n'
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf 'python\n'
    return 0
  fi
  return 1
}

python_has_module() {
  local module_name="$1"
  local python_bin
  python_bin="$(detect_python_bin)" || return 1
  "$python_bin" - "$module_name" <<'PY'
import importlib.util
import sys
module_name = sys.argv[1]
sys.exit(0 if importlib.util.find_spec(module_name) else 1)
PY
}

run_python_module_or_cmd() {
  local command_name="$1"
  local module_name="$2"
  shift 2

  if command -v "$command_name" >/dev/null 2>&1; then
    "$command_name" "$@"
    return 0
  fi

  local python_bin
  python_bin="$(detect_python_bin)" || fail "No Python interpreter available for $module_name"
  "$python_bin" -m "$module_name" "$@"
}

list_python_test_files() {
  find tests -type f \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null | sort -u
}

append_matching_python_tests_for_source() {
  local source_path="$1"
  local tests_file="$2"
  local base stem dir_base candidate

  base="$(basename "$source_path")"
  stem="${base%.*}"
  dir_base="$(basename "$(dirname "$source_path")")"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
      */test_"$stem".py|*/"$stem"_test.py)
        printf '%s\n' "$candidate"
        ;;
      */test_"$dir_base".py|*/"$dir_base"_test.py)
        if [ "$stem" = "__init__" ] || [ "$stem" = "main" ] || [ "$stem" = "app" ]; then
          printf '%s\n' "$candidate"
        fi
        ;;
    esac
  done < <(list_python_test_files) >> "$tests_file"
}

discover_python_targeted_tests() {
  local changed tests tmp_tests has_changed_source test_count repo_tests
  changed="$(collect_changed_files)"
  [ -n "$changed" ] || return 0

  tests=""
  tmp_tests="/tmp/ralph-python-targeted-tests.$$"
  : > "$tmp_tests"
  has_changed_source=0

  while IFS= read -r f; do
    case "$f" in
      tests/test_*.py|tests/*_test.py|*/tests/test_*.py|*/tests/*_test.py)
        [ -f "$f" ] && tests+="$f"$'\n'
        ;;
    esac
  done <<< "$changed"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      tests/*) ;;
      *.py)
        has_changed_source=1
        append_matching_python_tests_for_source "$f" "$tmp_tests"
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
    repo_tests="$(list_python_test_files | sed '/^$/d' | sort -u)"
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

default_run_base_checks() {
  local adapter
  adapter="$(builtin_adapter)" || fail "Could not detect a built-in verification adapter. Add scripts/ralph/verify.local.sh for this repo."

  case "$adapter" in
    node)
      run_optional_script typecheck && QUALITY_CHECKS_RAN=1
      run_optional_script lint && QUALITY_CHECKS_RAN=1
      select_node_test_script
      ;;
    python)
      if command -v ruff >/dev/null 2>&1 || python_has_module ruff; then
        echo "[ralph-verify] running ruff"
        run_python_module_or_cmd ruff ruff check .
        QUALITY_CHECKS_RAN=1
      else
        echo "[ralph-verify] skipping ruff (tool not available)"
      fi

      if command -v mypy >/dev/null 2>&1 || python_has_module mypy; then
        echo "[ralph-verify] running mypy"
        run_python_module_or_cmd mypy mypy .
        QUALITY_CHECKS_RAN=1
      else
        echo "[ralph-verify] skipping mypy (tool not available)"
      fi
      ;;
    *)
      fail "Unsupported built-in verification adapter: $adapter"
      ;;
  esac
}

default_discover_targeted_tests() {
  local adapter
  adapter="$(builtin_adapter)" || fail "Could not detect a built-in verification adapter. Add scripts/ralph/verify.local.sh for this repo."

  case "$adapter" in
    node) discover_node_targeted_tests ;;
    python) discover_python_targeted_tests ;;
    *) fail "Unsupported built-in verification adapter: $adapter" ;;
  esac
}

default_run_targeted_tests() {
  local tests=("$@")
  local adapter
  adapter="$(builtin_adapter)" || fail "Could not detect a built-in verification adapter. Add scripts/ralph/verify.local.sh for this repo."

  case "$adapter" in
    node)
      if [ "$TEST_SCRIPT_SUPPORTS_TARGETING" -eq 0 ]; then
        echo "[ralph-verify] targeted selection unavailable via npm run $TEST_SCRIPT; running repo-defined verification instead"
        run_selected_node_test_script
        return 0
      fi

      echo "[ralph-verify] running targeted tests:"
      printf '%s\n' "${tests[@]}" | sed 's/^/  - /'
      npm test -- --runInBand --runTestsByPath "${tests[@]}"
      ;;
    python)
      echo "[ralph-verify] running targeted tests:"
      printf '%s\n' "${tests[@]}" | sed 's/^/  - /'
      run_python_module_or_cmd pytest pytest "${tests[@]}"
      ;;
    *)
      fail "Unsupported built-in verification adapter: $adapter"
      ;;
  esac
}

default_run_full_suite() {
  local adapter
  adapter="$(builtin_adapter)" || fail "Could not detect a built-in verification adapter. Add scripts/ralph/verify.local.sh for this repo."

  case "$adapter" in
    node)
      local ignore_re
      echo "[ralph-verify] running full test suite"
      if [ "$TEST_SCRIPT" = "test" ]; then
        ignore_re="$(build_ignore_regex || true)"
        if [ -n "$ignore_re" ]; then
          echo "[ralph-verify] applying known baseline ignore patterns from $IGNORE_FILE"
          npm test -- --runInBand --testPathIgnorePatterns "$ignore_re"
        else
          npm test -- --runInBand
        fi
        return 0
      fi

      run_selected_node_test_script
      ;;
    python)
      echo "[ralph-verify] running full test suite"
      run_python_module_or_cmd pytest pytest
      ;;
    *)
      fail "Unsupported built-in verification adapter: $adapter"
      ;;
  esac
}

run_base_checks() {
  if has_function ralph_verify_run_base_checks; then
    ralph_verify_run_base_checks
  else
    default_run_base_checks
  fi
}

discover_targeted_tests() {
  if has_function ralph_verify_discover_targeted_tests; then
    ralph_verify_discover_targeted_tests
  else
    default_discover_targeted_tests
  fi
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
    echo "[ralph-verify] no targeted test files inferred from changed files; falling back to full test suite"
    run_full_suite
    return 0
  fi

  # shellcheck disable=SC2206
  local args=( $tests )
  if has_function ralph_verify_run_targeted_tests; then
    ralph_verify_run_targeted_tests "${args[@]}"
  else
    default_run_targeted_tests "${args[@]}"
  fi
}

run_full_suite() {
  if has_function ralph_verify_run_full_suite; then
    ralph_verify_run_full_suite
  else
    default_run_full_suite
  fi
}

run_base_checks
if [ "$QUALITY_CHECKS_RAN" -eq 0 ]; then
  if [ -n "$TEST_SCRIPT" ]; then
    echo "[ralph-verify] no base quality checks defined; relying on $TEST_SCRIPT for required verification"
  else
    echo "[ralph-verify] no base quality checks defined; relying on test execution for required verification"
  fi
fi

case "$MODE" in
  targeted) run_targeted_tests ;;
  full) run_full_suite ;;
  *) echo "Invalid mode: $MODE" >&2; exit 1 ;;
esac

echo "[ralph-verify] $MODE verification passed"
