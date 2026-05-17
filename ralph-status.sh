#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
SPRINT_BRANCH_PREFIX="ralph/sprint"

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-status.sh

Shows the current Ralph workflow state for the active sprint and story,
including loop status, branch/worktree state, and next action guidance.
EOF
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
  printf '%s/%s\n' "$SPRINT_BRANCH_PREFIX" "$sprint"
}

worktree_status() {
  if [ -n "$(git status --short 2>/dev/null)" ]; then
    printf 'dirty\n'
  else
    printf 'clean\n'
  fi
}

loop_status() {
  if pgrep -af 'scripts/ralph/ralph\.sh' >/dev/null 2>&1; then
    printf 'running\n'
  else
    printf 'stopped\n'
  fi
}

story_readiness() {
  local story_id="$1" stories_file="$2" workspace_root="$3"
  local status
  status="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .status // "planned"' "$stories_file" 2>/dev/null || true)"
  case "$status" in
    done|abandoned|active) echo "$status"; return ;;
  esac

  local raw_path story_path_abs specify_dir
  raw_path="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .story_path // ""' "$stories_file" 2>/dev/null || true)"
  if [ -z "$raw_path" ]; then echo "stub"; return; fi
  [[ "$raw_path" != /* ]] && story_path_abs="$workspace_root/$raw_path" || story_path_abs="$raw_path"
  specify_dir="$(dirname "$story_path_abs")/.specify"

  if [ -f "$story_path_abs" ]; then
    echo "ready"
  elif [ -f "$specify_dir/spec.md" ] && [ -f "$specify_dir/tasks.md" ]; then
    echo "specked"
  else
    echo "stub"
  fi
}

sprint_stories_table() {
  local stories_file="$1" workspace_root="$2"
  local active_id
  active_id="$(jq -r '.activeStoryId // ""' "$stories_file" 2>/dev/null || true)"

  printf '\n%-3s %-10s %-6s %-6s %-10s %-12s %s\n' "" "ID" "PRI" "EFF" "READY" "STATUS" "TITLE"
  printf '%-3s %-10s %-6s %-6s %-10s %-12s %s\n' "---" "----------" "------" "------" "----------" "------------" "-----"

  jq -r '.stories | sort_by(.priority) | .[] | [.id, (.priority|tostring), (.effort|tostring), .status, .title] | @tsv' \
    "$stories_file" 2>/dev/null \
  | while IFS=$'\t' read -r sid pri eff st title; do
      local marker readiness
      marker="   "
      [ "$sid" = "$active_id" ] && marker="-> "
      readiness="$(story_readiness "$sid" "$stories_file" "$workspace_root")"
      printf '%s %-10s %-6s %-6s %-10s %-12s %s\n' "$marker" "$sid" "$pri" "$eff" "$readiness" "$st" "$title"
    done
}

stories_file_for_sprint() {
  local sprint="$1"
  printf '%s/%s/stories.json\n' "$SPRINTS_DIR" "$sprint"
}

active_sprint_story_id() {
  local stories_file="$1"
  jq -r '.activeStoryId // empty' "$stories_file"
}

active_sprint_story_line() {
  local stories_file="$1"
  local story_id="$2"
  [ -n "$story_id" ] || return 0
  jq -r --arg id "$story_id" '
    .stories[]
    | select(.id == $id)
    | "Active story: \(.id) (P\(.priority // 0) E\(.effort // 0)) - \(.title)\nStory status: \(.status // "planned")"
  ' "$stories_file"
}

next_sprint_story_line() {
  local stories_file="$1"
  local next_id
  if next_id="$(RALPH_STORIES_FILE="$stories_file" "$SCRIPT_DIR/ralph-story.sh" next-id 2>/dev/null || true)" && [ -n "$next_id" ]; then
    jq -r --arg id "$next_id" '
      .stories[]
      | select(.id == $id)
      | "Next eligible story: \(.id) (P\(.priority // 0) E\(.effort // 0)) - \(.title)"
    ' "$stories_file"
  else
    printf 'Next eligible story: (none)\n'
  fi
}

latest_story_commit_line() {
  local line
  line="$(git log --oneline --max-count=1 --grep='^\(feat\|fix\): \[US-' 2>/dev/null || true)"
  if [ -n "$line" ]; then
    printf 'Latest story commit: %s\n' "$line"
  fi
}

next_action_line() {
  local sprint_story_id="$1"
  local stories_file="$2"
  local loop_state="$3"
  local all_done story_status

  all_done=false
  if [ -f "$stories_file" ]; then
    if jq -e '(.stories // []) | length > 0 and all(.[]; .status == "done" or .status == "abandoned")' "$stories_file" >/dev/null 2>&1; then
      all_done=true
    fi
  fi

  story_status=""
  if [ -n "$sprint_story_id" ] && [ -f "$stories_file" ]; then
    story_status="$(jq -r --arg id "$sprint_story_id" '.stories[] | select(.id == $id) | (.status // "")' "$stories_file" 2>/dev/null || true)"
  fi

  if [ "$all_done" = true ] && [ "$loop_state" = "running" ]; then
    printf 'Next action: wait for Ralph to finish closeout.\n'
  elif [ "$all_done" = true ]; then
    printf 'Next action: run ./scripts/ralph/ralph-sprint-commit.sh to close out the completed sprint.\n'
  elif [ "$loop_state" = "running" ]; then
    printf 'Next action: Ralph is running; monitor the active story.\n'
  elif [ -n "$sprint_story_id" ] && [ "$story_status" = "active" ]; then
    printf 'Next action: run ./scripts/ralph/ralph-story-run.sh to continue the active story.\n'
  else
    printf 'Next action: run ./scripts/ralph/ralph-story.sh start-next && ./scripts/ralph/ralph-story-run.sh\n'
  fi
}

main() {
  require_cmd git
  require_cmd jq
  require_cmd pgrep

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac

  local active_sprint stories_file current_branch sprint_branch loop_state worktree_state sprint_story_id
  active_sprint="$(get_active_sprint || true)"

  if [ -z "$active_sprint" ]; then
    echo "Active sprint: (none)"
    echo "Loop: $(loop_status)"
    echo "Worktree: $(worktree_status)"
    echo "Next action: run ./scripts/ralph/ralph-sprint.sh use <sprint-name>."
    exit 0
  fi

  stories_file="$(stories_file_for_sprint "$active_sprint")"

  current_branch="$(git branch --show-current)"
  sprint_branch="$(sprint_branch_name "$active_sprint")"
  loop_state="$(loop_status)"
  worktree_state="$(worktree_status)"

  if [ -f "$stories_file" ]; then
    sprint_story_id="$(active_sprint_story_id "$stories_file")"
  else
    sprint_story_id=""
  fi

  echo "Active sprint: $active_sprint"
  echo "Sprint branch: $sprint_branch"
  echo "Current branch: ${current_branch:-'(detached)'}"
  echo "Loop: $loop_state"
  echo "Worktree: $worktree_state"
  if [ -f "$stories_file" ]; then
    if [ -n "$sprint_story_id" ]; then
      active_sprint_story_line "$stories_file" "$sprint_story_id"
    else
      echo "Active story: (none)"
    fi
    next_sprint_story_line "$stories_file"
  else
    echo "Active story: (no stories.json found)"
    echo "Next eligible story: (none)"
  fi
  if [ -f "$stories_file" ]; then
    sprint_stories_table "$stories_file" "$WORKSPACE_ROOT"
  fi
  latest_story_commit_line
  next_action_line "$sprint_story_id" "$stories_file" "$loop_state"
}

main "$@"
