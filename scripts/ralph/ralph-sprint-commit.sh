#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ARCHIVE_DIR="$SPRINTS_DIR/archive"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
SPRINT_BRANCH_PREFIX="ralph/sprint"
RALPH_FREE_MODE="${RALPH_FREE_MODE:-0}"
export RALPH_FREE_MODE
source "$SCRIPT_DIR/lib/sprint-layout.sh"
TARGET_BRANCH=""
DRY_RUN=false
KEEP_SOURCE=false
SKIP_REGRESSION=false
RUN_FALLOW=false
FALLOW_AUTOFIX=false
FULL_REGRESSION=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/ralph/ralph-sprint-commit.sh [--target BRANCH] [--dry-run] [--keep] [--skip-regression] [--run-fallow] [--fallow-autofix] [--full-regression] [--free]

Behavior:
  1. Validates active sprint exists and all stories are done/abandoned
  2. Optionally runs fallow cleanup across completed stories
  3. Runs sprint-scoped verification by default, or full regression when requested
  4. Ensures sprint branch exists (ralph/sprint/<active-sprint>)
  5. Archives sprint-level artifacts to scripts/ralph/sprints/archive/
  6. Merges sprint branch into its recorded parent branch (or explicit target)
  7. Clears active Ralph sprint/prd state for next sprint/standalone run

Options:
  --target BRANCH      Explicit merge target branch
  --dry-run            Print plan only
  --keep               Keep sprint branch after successful merge
  --skip-regression    Skip the sprint regression gate (bypass for debugging)
  --run-fallow         Run optional fallow cleanup/checks before regression
  --fallow-autofix     Allow scoped fallow auto-fix during --run-fallow cleanup
  --full-regression    Run repo-wide regression instead of sprint-scoped verification
  --free               Prefer the OpenRouter free-tier model mapping
  -h, --help           Show this help
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

sprint_branch_name() {
  local sprint="$1"
  printf '%s/%s' "$SPRINT_BRANCH_PREFIX" "$sprint"
}

default_target_branch() {
  if git show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
    return 0
  fi
  fail "Could not find target branch (master or main)."
}

branch_parent_from_upstream() {
  local branch="$1"
  git for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null | head -n1
}

resolve_sprint_merge_target() {
  local sprint_branch="$1"
  local parent_branch
  parent_branch="$(branch_parent_from_upstream "$sprint_branch")"
  if [ -n "$parent_branch" ]; then
    printf '%s\n' "$parent_branch"
    return 0
  fi
  default_target_branch
}

ensure_clean_worktree() {
  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    fail "Working tree is not clean. Commit/stash changes before ralph-sprint-commit."
  fi
}

validate_stories_done_or_abandoned() {
  local stories_file="$1"
  jq -e '.stories and (.stories|type=="array")' "$stories_file" >/dev/null 2>&1 || fail "Invalid stories file: $stories_file"

  local invalid
  invalid="$(jq -r '.stories[] | select((.status != "done") and (.status != "abandoned")) | "\(.id)\t\(.status)"' "$stories_file")"
  if [ -n "$invalid" ]; then
    echo "Sprint has incomplete stories:" >&2
    printf '%s\n' "$invalid" >&2
    fail "All sprint stories must be done or abandoned before sprint commit."
  fi
}

ensure_transient_files_untracked() {
  local tracked
  tracked="$(git ls-files -- "$PRD_FILE" "$PROGRESS_FILE" || true)"
  [ -z "$tracked" ] && return 0

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    git rm --cached -- "$path" >/dev/null 2>&1 || true
  done <<< "$tracked"

  if ! git diff --cached --quiet; then
    git commit -m "chore(ralph): keep transient Ralph files untracked"
    echo "Removed transient Ralph files from git tracking on target branch."
  fi
}

prune_archive_retention() {
  local keep_count="${1:-7}"
  [ -d "$ARCHIVE_DIR" ] || return 0

  local -a archive_dirs=()
  mapfile -t archive_dirs < <(
    find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%f\n' 2>/dev/null \
      | sort -nr \
      | awk -F '\t' '{print $2}'
  )

  [ "${#archive_dirs[@]}" -gt "$keep_count" ] || return 0

  local i dir_name dir_path
  for ((i = keep_count; i < ${#archive_dirs[@]}; i++)); do
    dir_name="${archive_dirs[$i]}"
    dir_path="$ARCHIVE_DIR/$dir_name"
    [ -d "$dir_path" ] || continue
    if [ ! -f "$ARCHIVE_DIR/$dir_name.zip" ]; then
      (cd "$ARCHIVE_DIR" && zip -rq "$dir_name.zip" "$dir_name")
    fi
    rm -rf "$dir_path"
    echo "Compressed archived sprint: $ARCHIVE_DIR/$dir_name.zip"
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      TARGET_BRANCH="${2:-}"
      [ -n "$TARGET_BRANCH" ] || fail "--target requires a branch name"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --keep)
      KEEP_SOURCE=true
      shift
      ;;
    --skip-regression)
      SKIP_REGRESSION=true
      shift
      ;;
    --run-fallow)
      RUN_FALLOW=true
      shift
      ;;
    --fallow-autofix)
      FALLOW_AUTOFIX=true
      shift
      ;;
    --full-regression)
      FULL_REGRESSION=true
      shift
      ;;
    --free)
      RALPH_FREE_MODE=1
      export RALPH_FREE_MODE
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

require_cmd git
require_cmd jq
require_cmd sed
require_cmd awk
require_cmd zip

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Must be run inside a git repository."
fi

ACTIVE_SPRINT="$(get_active_sprint || true)"
[ -n "$ACTIVE_SPRINT" ] || fail "No active sprint set."

STORIES_FILE="$(sprint_stories_file "$ACTIVE_SPRINT")"
[ -f "$STORIES_FILE" ] || fail "Missing stories file: $STORIES_FILE"

SPRINT_BRANCH="$(sprint_branch_name "$ACTIVE_SPRINT")"
if ! git show-ref --verify --quiet "refs/heads/$SPRINT_BRANCH"; then
  fail "Missing sprint branch: $SPRINT_BRANCH"
fi

if [ -z "$TARGET_BRANCH" ]; then
  TARGET_BRANCH="$(resolve_sprint_merge_target "$SPRINT_BRANCH")"
fi

if [ "$SPRINT_BRANCH" = "$TARGET_BRANCH" ]; then
  fail "Sprint branch and target branch are the same ($SPRINT_BRANCH)."
fi

if ! git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  fail "Missing target branch: $TARGET_BRANCH"
fi

validate_stories_done_or_abandoned "$STORIES_FILE"

if [ "$FALLOW_AUTOFIX" = "true" ] && [ "$RUN_FALLOW" != "true" ]; then
  fail "--fallow-autofix requires --run-fallow."
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "Ralph sprint commit plan:"
  echo "  sprint:        $ACTIVE_SPRINT"
  echo "  sprint branch: $SPRINT_BRANCH"
  echo "  target branch: $TARGET_BRANCH"
  echo "  stories file:  $STORIES_FILE"
  echo "  archive root:  $ARCHIVE_DIR"
  echo "  run fallow:    $RUN_FALLOW"
  echo "  fallow autofix:$FALLOW_AUTOFIX"
  if [ "$KEEP_SOURCE" = "true" ]; then
    echo "  delete source: no (--keep)"
  else
    echo "  delete source: yes"
  fi
  exit 0
fi

ensure_clean_worktree

run_optional_fallow_cleanup() {
  [ "$RUN_FALLOW" = "true" ] || return 0
  [ -f "$SCRIPT_DIR/ralph-fallow-run.sh" ] || fail "ralph-fallow-run.sh not found but --run-fallow was requested."

  local story_paths=()
  while IFS= read -r story_path; do
    [ -n "$story_path" ] || continue
    if [[ "$story_path" != /* ]]; then
      story_path="$WORKSPACE_ROOT/$story_path"
    fi
    [ -f "$story_path" ] || fail "Missing story file for fallow cleanup: $story_path"
    story_paths+=("$story_path")
  done < <(jq -r '.stories[] | select(.status == "done") | .story_path // empty' "$STORIES_FILE")

  [ "${#story_paths[@]}" -gt 0 ] || { echo "No completed stories to scan with fallow."; return 0; }

  if [ "$(git branch --show-current)" != "$SPRINT_BRANCH" ]; then
    git checkout "$SPRINT_BRANCH"
  fi

  echo "--- Optional fallow cleanup ---"
  if [ "$FALLOW_AUTOFIX" = "true" ]; then
    echo "Fallow auto-fix enabled for sprint closeout cleanup."
  fi
  local story_path
  for story_path in "${story_paths[@]}"; do
    echo "Running fallow for $(basename "$(dirname "$story_path")")"
    local fallow_env=()
    if [ "$FALLOW_AUTOFIX" = "true" ]; then
      fallow_env+=(RALPH_FALLOW_EXACT_AUTOFIX=1)
      fallow_env+=(RALPH_FALLOW_CODEX_AUTOFIX=1)
    fi
    if ! env "${fallow_env[@]}" "$SCRIPT_DIR/ralph-fallow-run.sh" --story "$story_path"; then
      fail "Optional fallow cleanup failed for $story_path. Resolve issues or rerun sprint commit without --run-fallow."
    fi
  done
  echo "Optional fallow cleanup: PASS"
  ensure_clean_worktree
}

run_optional_fallow_cleanup

# Pre-merge regression gate
if [ "$SKIP_REGRESSION" = "true" ]; then
  echo "WARN: Sprint regression gate skipped (--skip-regression)"
elif [ "$FULL_REGRESSION" = "true" ]; then
  if [ ! -f "$SCRIPT_DIR/ralph-sprint-test.sh" ]; then
    fail "ralph-sprint-test.sh not found — full regression gate is required when --full-regression is requested.
  Create it from the template: cp $SCRIPT_DIR/ralph-sprint-test.sh.example $SCRIPT_DIR/ralph-sprint-test.sh"
  fi
  echo "--- Full regression gate ---"
  if ! "$SCRIPT_DIR/ralph-sprint-test.sh"; then
    fail "Full regression failed — correct failures before sprint commit. Use --skip-regression to bypass."
  fi
  echo "Full regression: PASS"
else
  echo "--- Sprint scoped verification gate ---"
  if ! "$SCRIPT_DIR/ralph-verify.sh" --sprint --sprint-name "$ACTIVE_SPRINT"; then
    fail "Sprint-scoped verification failed — correct failures before sprint commit. Use --full-regression for full repo validation or --skip-regression to bypass."
  fi
  echo "Sprint-scoped verification: PASS"
fi

CURRENT_BRANCH="$(git branch --show-current)"

# Archive sprint-level metadata
DATE_PREFIX="$(date +%F)"
ARCHIVE_PATH="$ARCHIVE_DIR/$DATE_PREFIX-$ACTIVE_SPRINT"
if [ -e "$ARCHIVE_PATH" ]; then
  ARCHIVE_PATH="$ARCHIVE_DIR/$DATE_PREFIX-$ACTIVE_SPRINT-$(date +%H%M%S)"
fi
SOURCE_SPRINT_DIR="$(dirname "$STORIES_FILE")"
ARCHIVE_TARGET_PREFIX="${SCRIPT_DIR#${WORKSPACE_ROOT}/}/sprints/archive/$(basename "$ARCHIVE_PATH")"
move_sprint_dir "$ACTIVE_SPRINT" "$SOURCE_SPRINT_DIR" "$ARCHIVE_PATH" "${SCRIPT_DIR#${WORKSPACE_ROOT}/}/sprints/$ACTIVE_SPRINT" "$ARCHIVE_TARGET_PREFIX"
[ -f "$ACTIVE_SPRINT_FILE" ] && cp "$ACTIVE_SPRINT_FILE" "$ARCHIVE_PATH/.active-sprint"
[ -f "$ACTIVE_PRD_FILE" ] && cp "$ACTIVE_PRD_FILE" "$ARCHIVE_PATH/.active-prd"
[ -f "$LAST_BRANCH_FILE" ] && cp "$LAST_BRANCH_FILE" "$ARCHIVE_PATH/.last-branch"

cat > "$ARCHIVE_PATH/archive-manifest.txt" <<MANIFEST
archive_time=$(date -Iseconds)
active_sprint=$ACTIVE_SPRINT
sprint_branch=$SPRINT_BRANCH
target_branch=$TARGET_BRANCH
source_stories_file=$STORIES_FILE
MANIFEST

TMP_FILE="$(mktemp)"
jq '.status = "closed" | .activeStoryId = null' "$ARCHIVE_PATH/stories.json" > "$TMP_FILE"
mv "$TMP_FILE" "$ARCHIVE_PATH/stories.json"
prune_archive_retention 7

git add -A "$SOURCE_SPRINT_DIR" "$ARCHIVE_DIR"
if ! git diff --cached --quiet; then
  git commit -m "chore(ralph): archive sprint $ACTIVE_SPRINT closeout artifacts"
fi

# Merge sprint branch into target
if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  git checkout "$TARGET_BRANCH"
fi

if ! git -c merge.renames=false merge --no-ff "$SPRINT_BRANCH" -m "merge: Ralph sprint $SPRINT_BRANCH"; then
  fail "Merge conflict while merging $SPRINT_BRANCH into $TARGET_BRANCH. Resolve manually."
fi

ensure_transient_files_untracked

# Clear active Ralph state for next sprint
rm -f "$ACTIVE_SPRINT_FILE" "$ACTIVE_PRD_FILE" "$LAST_BRANCH_FILE"

if [ -n "$(git status --porcelain -- "$ACTIVE_SPRINT_FILE" "$ACTIVE_PRD_FILE" "$LAST_BRANCH_FILE")" ]; then
  git add -A "$ACTIVE_SPRINT_FILE" "$ACTIVE_PRD_FILE" "$LAST_BRANCH_FILE" 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -m "chore(ralph): clear active sprint state after sprint commit"
  fi
fi

if [ "$KEEP_SOURCE" != "true" ]; then
  if git show-ref --verify --quiet "refs/heads/$SPRINT_BRANCH"; then
    if ! git branch -d "$SPRINT_BRANCH" >/dev/null 2>&1; then
      git branch -D "$SPRINT_BRANCH" >/dev/null 2>&1 || fail "Merged successfully, but failed to delete sprint branch: $SPRINT_BRANCH"
    fi
    echo "Deleted source sprint branch: $SPRINT_BRANCH"
  fi
else
  echo "Kept sprint branch: $SPRINT_BRANCH"
fi

echo "Sprint merge complete: $SPRINT_BRANCH -> $TARGET_BRANCH"
echo "Ralph state cleared and ready for next sprint/PRD setup."
