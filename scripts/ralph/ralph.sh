#!/bin/bash
# ralph.sh — Sprint execution loop for the story-task architecture.
#
# Runs all eligible stories in the active sprint sequentially:
#   start-next → ralph-story-run.sh → repeat until no eligible stories remain.
#
# Usage: ./scripts/ralph/ralph.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from .ralph-env files
# Priority: $HOME/.ralph-env (user-specific) then scripts/ralph/.ralph-env (project-specific fallback)
if [ -f "${HOME}/.ralph-env" ]; then
    # shellcheck source=/dev/null
    . "${HOME}/.ralph-env"
elif [ -f "${SCRIPT_DIR}/.ralph-env" ]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/.ralph-env"
fi

# Fallback to native API keys and unset base URL overrides on failure
# Unset base URL overrides to let harnesses use their default endpoints
unset OPENAI_BASE_URL
unset ANTHROPIC_BASE_URL
# Reset API keys to native values if set, otherwise unset to allow harness-configured auth (e.g., OAuth)
if [ -n "${OPENAI_API_KEY_NATIVE:-}" ]; then
    OPENAI_API_KEY="${OPENAI_API_KEY_NATIVE}"
else
    unset OPENAI_API_KEY
fi
if [ -n "${ANTHROPIC_API_KEY_NATIVE:-}" ]; then
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY_NATIVE}"
else
    unset ANTHROPIC_API_KEY
fi

WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
LOCK_DIR="$SCRIPT_DIR/.workflow-lock"
RALPH_HARNESS="${RALPH_HARNESS:-codex}"
RALPH_MODEL="${RALPH_MODEL:-}"
RALPH_AGENT="${RALPH_AGENT:-}"
export RALPH_HARNESS RALPH_MODEL RALPH_AGENT
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
RUNTIME_ROOT="$SCRIPT_DIR/runtime"
SPRINT_RUNS_DIR="$RUNTIME_ROOT/sprint-runs"
RUNTIME_RETENTION=3

MAX_STORIES=50
CONTINUE_ON_FAILURE=false
DRY_RUN=false
SKIP_FALLOW=false
MAX_RETRIES=1

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph.sh [options]

Runs all eligible stories in the active sprint:
   start-next → ralph-story-run.sh → repeat until no eligible stories remain.

Does NOT run ralph-sprint-commit.sh — that merge step is intentionally manual.

Options:
   --continue-on-failure   Continue to next story when a story fails (default: stop)
   --max-stories N         Safety ceiling on stories executed (default: 50)
   --max-retries N         Max targeted remediation cycles after the main story cycle (default: 1)
   --skip-fallow           Deprecated compatibility flag; no effect
   --dry-run               Print plan without executing
   --harness HARNESS       Specify harness to use (codex|opencode|piagent|claude_code) (default: codex)
   --model MODEL           Specify model to use with the harness (default: harness-specific)
   --agent AGENT           Specify agent/subagent type to use (default: harness-specific)
   -h, --help              Show this help

Environment:
   CODEX_BIN               Codex binary path (default: codex)
   RALPH_CODEX_PROFILE     Profile passed to codex exec
   RALPH_HARNESS           Harness to use (overridden by --harness)
   RALPH_MODEL             Model to use (overridden by --model)
   RALPH_AGENT             Agent to use (overridden by --agent)
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
    --harness)             RALPH_HARNESS="${2:-}"; shift 2 ;;
    --model)               RALPH_MODEL="${2:-}"; shift 2 ;;
    --agent)               RALPH_AGENT="${2:-}"; shift 2 ;;
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
# Workflow lock (shared with ralph-story-run.sh via RALPH_LOCK_HELD env var)
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

get_active_story_id() {
  jq -r '.activeStoryId // empty' "$STORIES_FILE" 2>/dev/null || true
}

get_story_field() {
  local story_id="$1"
  local field="$2"
  jq -r --arg id "$story_id" --arg field "$field" '
    .stories[]
    | select(.id == $id)
    | .[$field] // empty
  ' "$STORIES_FILE" 2>/dev/null || true
}

resolve_story_path_abs() {
  local story_id="$1"
  local story_path
  story_path="$(get_story_field "$story_id" "story_path")"
  [ -n "$story_path" ] || return 1
  [[ "$story_path" != /* ]] && story_path="$WORKSPACE_ROOT/$story_path"
  printf '%s\n' "$story_path"
}

ensure_active_story_branch() {
  local story_id="$1"
  local story_path story_branch current_branch
  story_path="$(resolve_story_path_abs "$story_id")"
  [ -f "$story_path" ] || fail "Active story file not found for $story_id: ${story_path:-unknown}"

  story_branch="$(jq -r '.branchName // empty' "$story_path" 2>/dev/null || true)"
  [ -n "$story_branch" ] || fail "Active story $story_id is missing branchName in $story_path"

  if ! git show-ref --verify --quiet "refs/heads/$story_branch"; then
    git branch "$story_branch" "$SPRINT_BRANCH"
    echo "Created missing story branch for active story: $story_branch (from $SPRINT_BRANCH)"
  fi

  current_branch="$(git branch --show-current)"
  if [ "$current_branch" != "$story_branch" ]; then
    git checkout "$story_branch" >/dev/null
    echo "Checked out active story branch: $story_branch"
  fi
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
[ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$ACTIVE_SPRINT'. Run ralph-sprint.sh create or seed the sprint via ralph-roadmap.sh."

SPRINT_BRANCH="ralph/sprint/$ACTIVE_SPRINT"
if ! git show-ref --verify --quiet "refs/heads/$SPRINT_BRANCH"; then
  fail "Sprint branch missing: $SPRINT_BRANCH. Run: ./scripts/ralph/ralph-sprint.sh branch $ACTIVE_SPRINT"
fi

CURRENT_BRANCH="$(git branch --show-current)"
ACTIVE_STORY_ID_PRECHECK="$(get_active_story_id)"
if [ "$CURRENT_BRANCH" != "$SPRINT_BRANCH" ]; then
  if [ -n "$ACTIVE_STORY_ID_PRECHECK" ]; then
    ACTIVE_STORY_PATH_PRECHECK="$(resolve_story_path_abs "$ACTIVE_STORY_ID_PRECHECK" 2>/dev/null || true)"
    ACTIVE_STORY_BRANCH_PRECHECK=""
    if [ -n "$ACTIVE_STORY_PATH_PRECHECK" ] && [ -f "$ACTIVE_STORY_PATH_PRECHECK" ]; then
      ACTIVE_STORY_BRANCH_PRECHECK="$(jq -r '.branchName // empty' "$ACTIVE_STORY_PATH_PRECHECK" 2>/dev/null || true)"
    fi
    if [ -n "$ACTIVE_STORY_BRANCH_PRECHECK" ] && [ "$CURRENT_BRANCH" = "$ACTIVE_STORY_BRANCH_PRECHECK" ]; then
      echo "Resuming from active story branch: $CURRENT_BRANCH"
    else
      fail "Not on sprint branch '$SPRINT_BRANCH'. Currently on: $CURRENT_BRANCH"
    fi
  else
    fail "Not on sprint branch '$SPRINT_BRANCH'. Currently on: $CURRENT_BRANCH"
  fi
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  fail "Working tree has uncommitted changes. Commit or stash before running ralph."
fi

acquire_workflow_lock

prune_runtime_runs() {
  local runs_dir="$1"
  local keep_count="${2:-3}"
  [ -d "$runs_dir" ] || return 0

  local run_paths=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    run_paths+=("$path")
  done < <(find "$runs_dir" -mindepth 1 -maxdepth 1 -type d | sort)

  local total="${#run_paths[@]}"
  [ "$total" -gt "$keep_count" ] || return 0

  local prune_count=$((total - keep_count))
  local i
  for ((i = 0; i < prune_count; i++)); do
    rm -rf "${run_paths[$i]}"
  done
}

write_sprint_run_manifest() {
  local phase="$1"
  local manifest_path="$SPRINT_RUN_DIR/sprint-run.json"
  local total_story_count current_active_story_id current_active_story_title current_done_count current_remaining
  total_story_count="$(jq -r '(.stories // []) | length' "$STORIES_FILE" 2>/dev/null || echo 0)"
  current_active_story_id="$(jq -r '.activeStoryId // ""' "$STORIES_FILE" 2>/dev/null || true)"
  current_active_story_title="$(jq -r --arg id "$current_active_story_id" 'if $id == "" then "" else (.stories[] | select(.id == $id) | .title // "") end' "$STORIES_FILE" 2>/dev/null || true)"
  current_done_count="$(jq -r '[.stories[]? | select((.status // "") == "done" and (.passes // false) == true)] | length' "$STORIES_FILE" 2>/dev/null || echo 0)"
  current_remaining="$(jq -r '[.stories[]? | select((.status // "") != "done" and (.status // "") != "abandoned")] | length' "$STORIES_FILE" 2>/dev/null || echo 0)"
  jq -n \
    --arg sprint "$ACTIVE_SPRINT" \
    --arg sprint_branch "$SPRINT_BRANCH" \
    --arg stories_file "$STORIES_FILE" \
    --arg started_at "$SPRINT_RUN_STARTED_AT" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg phase "$phase" \
    --arg log_file "$SPRINT_LOG_FILE" \
    --arg run_dir "$SPRINT_RUN_DIR" \
    --arg active_story_id "$current_active_story_id" \
    --arg active_story_title "$current_active_story_title" \
    --argjson story_count "${story_count:-0}" \
    --argjson total_story_count "$total_story_count" \
    --argjson done_count "$current_done_count" \
    --argjson failed_count "${failed_count:-0}" \
    --argjson remaining "$current_remaining" \
    '{
      sprint: $sprint,
      sprint_branch: $sprint_branch,
      stories_file: $stories_file,
      started_at: $started_at,
      updated_at: $updated_at,
      phase: $phase,
      log_file: $log_file,
      run_dir: $run_dir,
      story_count: $story_count,
      total_story_count: $total_story_count,
      done_count: $done_count,
      failed_count: $failed_count,
      remaining_stories: $remaining,
      active_story_id: (if $active_story_id == "" then null else $active_story_id end),
      active_story_title: (if $active_story_title == "" then null else $active_story_title end)
    }' > "$manifest_path"
}

SPRINT_RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SPRINT_RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)-$ACTIVE_SPRINT"
SPRINT_RUN_DIR="$SPRINT_RUNS_DIR/$SPRINT_RUN_ID"
SPRINT_LOG_FILE="$SPRINT_RUN_DIR/sprint.log"
mkdir -p "$SPRINT_RUN_DIR/stories"
prune_runtime_runs "$SPRINT_RUNS_DIR" "$RUNTIME_RETENTION"
export RALPH_SPRINT_RUN_DIR="$SPRINT_RUN_DIR"
export RALPH_SPRINT_LOG_FILE="$SPRINT_LOG_FILE"

if [ "$DRY_RUN" != "true" ]; then
  exec > >(tee -a "$SPRINT_LOG_FILE") 2>&1
fi

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
remaining="unknown"
write_sprint_run_manifest "started"

echo ""
echo "Ralph sprint loop: $ACTIVE_SPRINT"
echo "Stories file:      $STORIES_FILE"
echo "Runtime journal:   $SPRINT_RUN_DIR"
echo ""

while [ "$story_count" -lt "$MAX_STORIES" ]; do
  write_sprint_run_manifest "selecting-story"
  active_story_id="$(get_active_story_id)"
  next_id=""
  story_already_active=false

  if [ -n "$active_story_id" ]; then
    active_story_status="$(get_story_field "$active_story_id" "status")"
    if [ "$active_story_status" = "active" ]; then
      next_id="$active_story_id"
      story_already_active=true
      echo "Resuming active story: $next_id"
      ensure_active_story_branch "$next_id"
    fi
  fi

  if [ -z "$next_id" ]; then
    next_id="$("$SCRIPT_DIR/ralph-story.sh" next-id 2>/dev/null || true)"
  fi

  if [ -z "$next_id" ]; then
    echo "No more eligible stories."
    write_sprint_run_manifest "idle"
    break
  fi

  story_title="$(jq -r --arg id "$next_id" '.stories[] | select(.id == $id) | .title' "$STORIES_FILE" 2>/dev/null || echo "(unknown)")"
  story_count=$((story_count + 1))
  write_sprint_run_manifest "story-selected"

  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Story $story_count: $next_id — $story_title"
  echo "════════════════════════════════════════════════════"

  if [ "$DRY_RUN" = "true" ]; then
    if [ "$story_already_active" = "true" ]; then
      echo "[DRY RUN] Would resume active story: ralph-story-run.sh"
    else
      echo "[DRY RUN] Would run: ralph-story.sh start-next && ralph-story-run.sh"
    fi
    echo "[DRY RUN] Stopping after first story in dry-run mode."
    write_sprint_run_manifest "dry-run"
    break
  fi

  if [ "$story_already_active" != "true" ]; then
    # Activate story and create story branch
    if ! "$SCRIPT_DIR/ralph-story.sh" start-next; then
      echo ""
      echo "ERROR: start-next failed for $next_id"
      failed_count=$((failed_count + 1))
      write_sprint_run_manifest "start-next-failed"
      if [ "$CONTINUE_ON_FAILURE" = "true" ]; then
        git -C "$WORKSPACE_ROOT" checkout "$SPRINT_BRANCH" 2>/dev/null || true
        write_sprint_run_manifest "waiting-for-next"
        continue
      fi
      break
    fi
  else
    echo "Continuing previously active story without restarting it."
  fi
  write_sprint_run_manifest "running-story"

  # Build ralph-story-run.sh args
  story_run_args=(--max-retries "$MAX_RETRIES")

  # Execute the story in a single primary Codex cycle
  if "$SCRIPT_DIR/ralph-story-run.sh" "${story_run_args[@]}"; then
    echo ""
    echo "DONE: $next_id complete"
    done_count=$((done_count + 1))
    write_sprint_run_manifest "story-completed"
  else
    echo ""
    echo "FAIL: $next_id — story branch left intact for inspection"
    echo "      To reset: ./scripts/ralph/ralph-story.sh set-status $next_id planned"
    failed_count=$((failed_count + 1))
    write_sprint_run_manifest "story-failed"
    if [ "$CONTINUE_ON_FAILURE" = "true" ]; then
      git -C "$WORKSPACE_ROOT" checkout "$SPRINT_BRANCH" 2>/dev/null || true
      write_sprint_run_manifest "waiting-for-next"
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

write_sprint_run_manifest "completed"

[ "$failed_count" -eq 0 ] || exit 1
