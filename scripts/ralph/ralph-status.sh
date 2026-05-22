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
Usage: ./scripts/ralph/ralph-status.sh [--prep-details] [--prep-story-limit N]

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

latest_prep_summary_for_sprint() {
  local sprint="$1"
  local prep_root="$SCRIPT_DIR/runtime/prep-runs"
  [ -d "$prep_root" ] || return 1
  find "$prep_root" -type f -name 'prepare-run.json' -path "*-${sprint}-*/prepare-run.json" 2>/dev/null | sort | tail -n1
}

prep_status_line() {
  local sprint="$1"
  local prep_details="${2:-0}"
  local prep_story_limit="${3:-5}"
  local summary_path
  summary_path="$(latest_prep_summary_for_sprint "$sprint" || true)"
  if [ -z "$summary_path" ] || [ ! -f "$summary_path" ]; then
    printf 'Prep: (no prep run journal found)\n'
    return 0
  fi

  local mode status finished_at story_count failed_count skipped_count passed_count total_duration_ms
  mode="$(jq -r '.mode // "prep"' "$summary_path" 2>/dev/null || echo "prep")"
  status="$(jq -r '.status // "running"' "$summary_path" 2>/dev/null || echo "running")"
  finished_at="$(jq -r '.finished_at // .started_at // ""' "$summary_path" 2>/dev/null || true)"
  story_count="$(jq -r '(.stories // {}) | length' "$summary_path" 2>/dev/null || echo 0)"
  failed_count="$(jq -r '.metrics.failed_stages // ([.stories[]?[]? | select(.status == "failed")] | length)' "$summary_path" 2>/dev/null || echo 0)"
  skipped_count="$(jq -r '.metrics.skipped_stages // ([.stories[]?[]? | select(.status == "skipped")] | length)' "$summary_path" 2>/dev/null || echo 0)"
  passed_count="$(jq -r '.metrics.passed_stages // ([.stories[]?[]? | select(.status == "passed")] | length)' "$summary_path" 2>/dev/null || echo 0)"
  total_duration_ms="$(jq -r '.metrics.total_duration_ms // 0' "$summary_path" 2>/dev/null || echo 0)"

  printf 'Prep: %s (%s, stories=%s, passed-stages=%s, failed-stages=%s, skipped-stages=%s, duration-ms=%s)\n' "$status" "$mode" "$story_count" "$passed_count" "$failed_count" "$skipped_count" "$total_duration_ms"
  [ -n "$finished_at" ] && printf 'Prep updated: %s\n' "$finished_at"
  printf 'Prep journal: %s\n' "$summary_path"
  prep_story_stage_lines "$summary_path" "$prep_story_limit"
  if [ "$prep_details" -eq 1 ]; then
    prep_story_stage_detail_lines "$summary_path" "$prep_story_limit"
  fi
}

prep_story_stage_lines() {
  local summary_path="$1"
  local story_limit="${2:-5}"
  [ -f "$summary_path" ] || return 0

  jq -r '
    (.stories // {})
    | to_entries
    | sort_by(.key)
    | .[:$limit]
    | .[]
    | .key as $story_id
    | (.value | to_entries | sort_by(.key) | map("\(.key)=\(.value.status // "unknown")") | join(", ")) as $stages
    | "Prep story " + $story_id + ": " + (if $stages == "" then "(no stages recorded)" else $stages end)
  ' --argjson limit "$story_limit" "$summary_path" 2>/dev/null || true
}

prep_story_stage_detail_lines() {
  local summary_path="$1"
  local story_limit="${2:-5}"
  [ -f "$summary_path" ] || return 0

  jq -r '
    (.stories // {})
    | to_entries
    | sort_by(.key)
    | .[:$limit]
    | .[]
    | .key as $story_id
    | .value
    | to_entries
    | sort_by(.key)
    | .[]
    | "Prep detail " + $story_id + " " + .key + ": "
      + (.value.status // "unknown")
      + (if (.value.detail // "") == "" then "" else " - " + .value.detail end)
      + " (duration-ms=" + ((.value.duration_ms // 0) | tostring) + ", updated=" + (.value.updated_at // "unknown") + ")"
  ' --argjson limit "$story_limit" "$summary_path" 2>/dev/null || true
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

story_file_status() {
  local stories_file="$1"
  local story_id="$2"
  local raw_path story_path_abs

  [ -n "$story_id" ] || return 0
  raw_path="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .story_path // ""' "$stories_file" 2>/dev/null || true)"
  [ -n "$raw_path" ] || return 0
  [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"
  [ -f "$story_path_abs" ] || return 0

  jq -r '.status // empty' "$story_path_abs" 2>/dev/null || true
}

active_sprint_story_line() {
  local stories_file="$1"
  local story_id="$2"
  [ -n "$story_id" ] || return 0
  local backlog_status file_status
  backlog_status="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | (.status // "planned")' "$stories_file" 2>/dev/null || true)"
  file_status="$(story_file_status "$stories_file" "$story_id")"

  jq -r --arg id "$story_id" '
    .stories[]
    | select(.id == $id)
    | "Active story: \(.id) (P\(.priority // 0) E\(.effort // 0)) - \(.title)"
  ' "$stories_file"

  if [ -n "$file_status" ] && [ "$file_status" != "$backlog_status" ]; then
    printf 'Story status: backlog=%s, story.json=%s\n' "$backlog_status" "$file_status"
  else
    printf 'Story status: %s\n' "${file_status:-$backlog_status}"
  fi
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
  local all_done story_status story_file_state

  all_done=false
  if [ -f "$stories_file" ]; then
    if jq -e '(.stories // []) | length > 0 and all(.[]; .status == "done" or .status == "abandoned")' "$stories_file" >/dev/null 2>&1; then
      all_done=true
    fi
  fi

  story_status=""
  if [ -n "$sprint_story_id" ] && [ -f "$stories_file" ]; then
    story_status="$(jq -r --arg id "$sprint_story_id" '.stories[] | select(.id == $id) | (.status // "")' "$stories_file" 2>/dev/null || true)"
    story_file_state="$(story_file_status "$stories_file" "$sprint_story_id")"
  fi

  if [ "$all_done" = true ] && [ "$loop_state" = "running" ]; then
    printf 'Next action: wait for Ralph to finish closeout.\n'
  elif [ "$all_done" = true ]; then
    printf 'Next action: run ./scripts/ralph/ralph-sprint-commit.sh to close out the completed sprint.\n'
  elif [ -n "$sprint_story_id" ] && [ "$story_status" = "active" ] && [ "$story_file_state" = "done" ] && [ "$loop_state" = "running" ]; then
    printf 'Next action: wait for Ralph to reconcile story closeout.\n'
  elif [ -n "$sprint_story_id" ] && [ "$story_status" = "active" ] && [ "$story_file_state" = "done" ]; then
    printf 'Next action: run ./scripts/ralph/ralph-story-run.sh to reconcile completed story closeout.\n'
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

  local prep_details=0 prep_story_limit=5

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        usage
        exit 0
        ;;
      --prep-details)
        prep_details=1
        shift
        ;;
      --prep-story-limit)
        prep_story_limit="${2:-}"
        [ -n "$prep_story_limit" ] || fail "Missing value for --prep-story-limit"
        [[ "$prep_story_limit" =~ ^[1-9][0-9]*$ ]] || fail "--prep-story-limit must be a positive integer"
        shift 2
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

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
  prep_status_line "$active_sprint" "$prep_details" "$prep_story_limit"
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
