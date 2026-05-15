#!/bin/bash
# ralph.sh — Sprint execution loop for the story-task architecture.
#
# Runs all eligible stories in the active sprint sequentially:
#   start-next → ralph-task.sh → repeat until no eligible stories remain.
#
# Usage: ./scripts/ralph/ralph.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
LOCK_DIR="$SCRIPT_DIR/.workflow-lock"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINTS_DIR="$SCRIPT_DIR/sprints"

MAX_STORIES=50
CONTINUE_ON_FAILURE=false
DRY_RUN=false
SKIP_FALLOW=false
MAX_RETRIES=2

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph.sh [options]

Runs all eligible stories in the active sprint:
  start-next → ralph-task.sh → repeat until no eligible stories remain.

Does NOT run ralph-sprint-commit.sh — that merge step is intentionally manual.

Options:
  --continue-on-failure   Continue to next story when a story fails (default: stop)
  --max-stories N         Safety ceiling on stories executed (default: 50)
  --max-retries N         Per-task Codex retry count (default: 2)
  --skip-fallow           Deprecated compatibility flag; no effect
  --dry-run               Print plan without executing
  -h, --help              Show this help

Environment:
  CODEX_BIN               Codex binary path (default: codex)
  RALPH_CODEX_PROFILE     Profile passed to codex exec
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --continue-on-failure) CONTINUE_ON_FAILURE=true; shift ;;
    --max-stories)         MAX_STORIES="${2:-50}"; shift 2 ;;
    --max-retries)         MAX_RETRIES="${2:-2}"; shift 2 ;;
    --skip-fallow)         SKIP_FALLOW=true; shift ;;
    --dry-run)             DRY_RUN=true; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ "$MAX_STORIES" =~ ^[1-9][0-9]*$ ]] || fail "--max-stories must be a positive integer"
[[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]       || fail "--max-retries must be a non-negative integer"

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd git
require_cmd jq
require_cmd "$CODEX_BIN"

# ---------------------------------------------------------------------------
# Workflow lock (shared with ralph-task.sh via RALPH_LOCK_HELD env var)
# ---------------------------------------------------------------------------

acquire_workflow_lock() {
  if [ "${RALPH_LOCK_HELD:-0}" = "1" ]; then return 0; fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another Ralph workflow is running (lock: $LOCK_DIR). Use ralph-cleanup.sh --force to clear stale locks."
  fi
  export RALPH_LOCK_HELD=1
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
}

# ---------------------------------------------------------------------------
# Validate sprint state
# ---------------------------------------------------------------------------

get_active_sprint() {
  [ -f "$ACTIVE_SPRINT_FILE" ] || return 1
  awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
}

ACTIVE_SPRINT="$(get_active_sprint || true)"

if [ -z "$ACTIVE_SPRINT" ]; then
  echo "No active sprint — auto-selecting next ready sprint..."
  if ! "$SCRIPT_DIR/ralph-sprint.sh" next --activate; then
    fail "No ready sprint found. Mark one ready with: ./scripts/ralph/ralph-sprint.sh mark-ready <name>"
  fi
  ACTIVE_SPRINT="$(get_active_sprint || true)"
  [ -n "$ACTIVE_SPRINT" ] || fail "Sprint activation succeeded but .active-sprint is still empty."
  echo "Activated sprint: $ACTIVE_SPRINT"
fi

STORIES_FILE="$SPRINTS_DIR/$ACTIVE_SPRINT/stories.json"
[ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$ACTIVE_SPRINT'. Run ralph-sprint.sh create or ralph-sprint-migrate.sh."

SPRINT_BRANCH="ralph/sprint/$ACTIVE_SPRINT"
if ! git show-ref --verify --quiet "refs/heads/$SPRINT_BRANCH"; then
  fail "Sprint branch missing: $SPRINT_BRANCH. Run: ./scripts/ralph/ralph-sprint.sh branch $ACTIVE_SPRINT"
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$SPRINT_BRANCH" ]; then
  fail "Not on sprint branch '$SPRINT_BRANCH'. Currently on: $CURRENT_BRANCH"
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  fail "Working tree has uncommitted changes. Commit or stash before running ralph."
fi

acquire_workflow_lock

# ---------------------------------------------------------------------------
# Pre-flight: warn about stories with no story.json
# ---------------------------------------------------------------------------

unprepared_ids=()
while IFS=$'\t' read -r sid spath; do
  [ -n "$sid" ] || continue
  [[ "$spath" != /* ]] && spath="$WORKSPACE_ROOT/$spath"
  [ -f "$spath" ] || unprepared_ids+=("$sid")
done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | [.id, (.story_path // "")] | @tsv' "$STORIES_FILE" 2>/dev/null)

if [ "${#unprepared_ids[@]}" -gt 0 ]; then
  echo "WARN: ${#unprepared_ids[@]} story/stories have no story.json — run prepare-all first:"
  printf '  %s\n' "${unprepared_ids[@]}"
  echo "  ./scripts/ralph/ralph-story.sh prepare-all --jobs 2"
  echo ""
fi

# ---------------------------------------------------------------------------
# Sprint execution loop
# ---------------------------------------------------------------------------

story_count=0
done_count=0
failed_count=0

echo ""
echo "Ralph sprint loop: $ACTIVE_SPRINT"
echo "Stories file:      $STORIES_FILE"
echo ""

while [ "$story_count" -lt "$MAX_STORIES" ]; do
  next_id="$("$SCRIPT_DIR/ralph-story.sh" next-id 2>/dev/null || true)"

  if [ -z "$next_id" ]; then
    echo "No more eligible stories."
    break
  fi

  story_title="$(jq -r --arg id "$next_id" '.stories[] | select(.id == $id) | .title' "$STORIES_FILE" 2>/dev/null || echo "(unknown)")"
  story_count=$((story_count + 1))

  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Story $story_count: $next_id — $story_title"
  echo "════════════════════════════════════════════════════"

  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would run: ralph-story.sh start-next && ralph-task.sh"
    echo "[DRY RUN] Stopping after first story in dry-run mode."
    break
  fi

  # Activate story and create story branch
  if ! "$SCRIPT_DIR/ralph-story.sh" start-next; then
    echo ""
    echo "ERROR: start-next failed for $next_id"
    failed_count=$((failed_count + 1))
    if [ "$CONTINUE_ON_FAILURE" = "true" ]; then
      git -C "$WORKSPACE_ROOT" checkout "$SPRINT_BRANCH" 2>/dev/null || true
      continue
    fi
    break
  fi

  # Build ralph-task.sh args
  task_args=(--max-retries "$MAX_RETRIES")
  [ "$SKIP_FALLOW" = "true" ] && task_args+=(--skip-fallow)

  # Execute all tasks in the story
  if "$SCRIPT_DIR/ralph-task.sh" "${task_args[@]}"; then
    echo ""
    echo "DONE: $next_id complete"
    done_count=$((done_count + 1))
  else
    echo ""
    echo "FAIL: $next_id — story branch left intact for inspection"
    echo "      To reset: ./scripts/ralph/ralph-story.sh set-status $next_id planned"
    failed_count=$((failed_count + 1))
    if [ "$CONTINUE_ON_FAILURE" = "true" ]; then
      git -C "$WORKSPACE_ROOT" checkout "$SPRINT_BRANCH" 2>/dev/null || true
      continue
    fi
    break
  fi
done

if [ "$story_count" -ge "$MAX_STORIES" ] && [ -n "$("$SCRIPT_DIR/ralph-story.sh" next-id 2>/dev/null || true)" ]; then
  echo ""
  echo "WARN: Reached --max-stories ceiling ($MAX_STORIES). Stories may remain."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "════════════════════════════════════════════════════"
echo "  Sprint loop complete: $ACTIVE_SPRINT"
printf "  Done: %d  Failed: %d\n" "$done_count" "$failed_count"
echo "════════════════════════════════════════════════════"
echo ""

remaining="$(jq '[.stories[] | select(.status != "done" and .status != "abandoned")] | length' "$STORIES_FILE" 2>/dev/null || echo "?")"

if [ "$remaining" = "0" ]; then
  echo "All stories done or abandoned. Ready for sprint commit:"
  echo "  ./scripts/ralph/ralph-sprint-commit.sh"
else
  echo "$remaining story/stories remaining."
  if [ "$failed_count" -gt 0 ]; then
    echo "Review failed stories, fix issues, then re-run ralph.sh."
    echo "To reset a stuck story: ./scripts/ralph/ralph-story.sh set-status <ID> planned"
  fi
fi

[ "$failed_count" -eq 0 ] || exit 1
