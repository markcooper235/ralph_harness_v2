#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

MODE="all"
STORY_PATH=""
CHANGED_SINCE=""
FORMAT="human"
GLOBAL_SCOPE=0
DRY_RUN=0
NO_AUTOFIX=0
QUIET=0
SUMMARY=0
SCORE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-fallow-run.sh [options]

Run Fallow either through the existing Ralph story gate or directly against the
repo for broader scans.

Scope options:
  --story PATH        Run the existing Ralph story-scoped gate for story.json
  --changed-since REF Run Fallow against changes since a git ref
  --global            Run Fallow against the whole repo

Mode options:
  --mode MODE         One of: all, audit, dead-code, dupes, health
  --format FORMAT     One of: human, json, compact, markdown, sarif
  --summary           Summary counts only (direct CLI modes)
  --score             Include score output where supported

Story-gate options:
  --dry-run           Report story findings without failing
  --no-autofix        Disable story-gate auto-fix attempts
  --quiet             Reduce output

Examples:
  ./scripts/ralph/ralph-fallow-run.sh --story scripts/ralph/sprints/sprint-1/stories/S-001/story.json
  ./scripts/ralph/ralph-fallow-run.sh --global --mode all --format json --score
  ./scripts/ralph/ralph-fallow-run.sh --changed-since main --mode audit --format json
  ./scripts/ralph/ralph-fallow-run.sh --changed-since HEAD~5 --mode dead-code --summary
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)
      STORY_PATH="${2:-}"
      shift 2
      ;;
    --changed-since|--base)
      CHANGED_SINCE="${2:-}"
      shift 2
      ;;
    --global)
      GLOBAL_SCOPE=1
      shift
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --summary)
      SUMMARY=1
      shift
      ;;
    --score)
      SCORE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-autofix)
      NO_AUTOFIX=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  all|audit|dead-code|dupes|health) ;;
  *) fail "--mode must be one of: all, audit, dead-code, dupes, health" ;;
esac

case "$FORMAT" in
  human|json|compact|markdown|sarif) ;;
  *) fail "--format must be one of: human, json, compact, markdown, sarif" ;;
esac

if [ -n "$STORY_PATH" ] && { [ "$GLOBAL_SCOPE" -eq 1 ] || [ -n "$CHANGED_SINCE" ]; }; then
  fail "--story cannot be combined with --global or --changed-since"
fi

if [ -n "$STORY_PATH" ]; then
  [ -f "$STORY_PATH" ] || fail "Story file not found: $STORY_PATH"
  cmd=("$SCRIPT_DIR/ralph-fallow.sh" "--story" "$STORY_PATH")
  [ "$DRY_RUN" -eq 1 ] && cmd+=("--dry-run")
  [ "$NO_AUTOFIX" -eq 1 ] && cmd+=("--no-autofix")
  [ "$QUIET" -eq 1 ] && cmd+=("--quiet")
  cd "$WORKSPACE_ROOT"
  exec "${cmd[@]}"
fi

detect_fallow() {
  if [ -x "$WORKSPACE_ROOT/node_modules/.bin/fallow" ]; then
    FALLOW_CMD=("$WORKSPACE_ROOT/node_modules/.bin/fallow")
    return 0
  fi
  if command -v fallow >/dev/null 2>&1; then
    FALLOW_CMD=("fallow")
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    FALLOW_CMD=("npx" "--yes" "fallow")
    return 0
  fi
  fail "Fallow CLI not found. Install it with 'npm install -g fallow' or add it to the project."
}

detect_fallow

global_args=("--format" "$FORMAT")
[ "$QUIET" -eq 1 ] && global_args+=("--quiet")
[ -n "$CHANGED_SINCE" ] && global_args+=("--changed-since" "$CHANGED_SINCE")
[ "$SUMMARY" -eq 1 ] && global_args+=("--summary")

cmd=("${FALLOW_CMD[@]}")

case "$MODE" in
  all)
    cmd+=("${global_args[@]}")
    [ "$SCORE" -eq 1 ] && cmd+=("--score")
    ;;
  audit)
    cmd+=("${global_args[@]}" "audit")
    ;;
  dead-code)
    cmd+=("${global_args[@]}" "dead-code")
    ;;
  dupes)
    cmd+=("${global_args[@]}" "dupes")
    ;;
  health)
    cmd+=("${global_args[@]}" "health")
    [ "$SCORE" -eq 1 ] && cmd+=("--score")
    ;;
esac

cd "$WORKSPACE_ROOT"
exec "${cmd[@]}"
