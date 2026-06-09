#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ARCHIVE_ROOT="$SPRINTS_DIR/archive"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINT_BRANCH_PREFIX="ralph/sprint"
RALPH_FREE_MODE="${RALPH_FREE_MODE:-0}"
export RALPH_FREE_MODE
source "$SCRIPT_DIR/lib/sprint-layout.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/ralph/ralph-sprint.sh [--free] <command> [args]

Commands:
  list                              List available sprints
  create <sprint-name> [--no-activate]  Create sprint structure and stories.json scaffold
  remove <sprint-name> [options]    Remove sprint (archive by default)
  use <sprint-name>                 Activate sprint (requires status=ready, previous=closed)
  mark-ready <sprint-name> [--no-commit]  Promote eligible planned stories and mark sprint ready
  restage <sprint-name>             Reset sprint + story statuses to planned for lifecycle reruns
  next [--activate]                 Show the next ready sprint, optionally activate it
  branch <sprint-name>              Ensure sprint branch exists (ralph/sprint/<sprint-name>)
  status                            Show active sprint + story readiness
  -h, --help                        Show this help

Global options:
  --free                            Prefer the OpenRouter free-tier model mapping

Remove options:
  --hard                            Permanently delete sprint dirs instead of archiving
  --yes                             Skip confirmation prompt
  --drop-branch                     Delete sprint branch even if not merged
                                    (implied automatically by --hard)

To add stories to a sprint:
  ./ralph-story.sh add --title '<title>' [options]

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

normalize_sprint_name() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

sprint_branch_name() {
  local sprint="$1"
  printf '%s/%s' "$SPRINT_BRANCH_PREFIX" "$sprint"
}

branch_parent_from_upstream() {
  local branch="$1"
  git for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null | head -n1
}

set_branch_parent() {
  local branch="$1"
  local parent="$2"
  [ -n "$branch" ] && [ -n "$parent" ] || return 0
  git branch --set-upstream-to="$parent" "$branch" >/dev/null 2>&1 || true
}

resolve_branch_parent() {
  local branch="$1"
  local parent
  parent="$(branch_parent_from_upstream "$branch")"
  if [ -n "$parent" ]; then
    printf '%s\n' "$parent"
    return 0
  fi
  default_primary_branch
}

default_primary_branch() {
  if git show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
    return 0
  fi
  fail "Could not find base branch (master or main) for sprint branch creation."
}

default_base_branch() {
  local current_branch
  current_branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -n "$current_branch" ] && [[ "$current_branch" != ralph/* ]] \
    && git show-ref --verify --quiet "refs/heads/$current_branch"; then
    printf '%s\n' "$current_branch"
    return 0
  fi
  default_primary_branch
}

ensure_sprint_branch_exists() {
  local sprint="$1"
  local sprint_branch base_branch
  sprint_branch="$(sprint_branch_name "$sprint")"
  if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
    return 0
  fi

  base_branch="$(default_base_branch)"
  git branch "$sprint_branch" "$base_branch"
  set_branch_parent "$sprint_branch" "$base_branch"
  echo "Created sprint branch: $sprint_branch (from $base_branch)"
}

checkout_sprint_branch() {
  local sprint="$1"
  local sprint_branch
  sprint_branch="$(sprint_branch_name "$sprint")"
  git checkout "$sprint_branch" >/dev/null
  echo "Checked out sprint branch: $sprint_branch"
}

ensure_sprint_structure() {
  local sprint="$1"
  ensure_sprint_backlog_structure "$sprint"
}

get_sprint_status() {
  local sprint="$1"
  local sf
  sf="$(sprint_stories_file "$sprint")"
  [ -f "$sf" ] || { echo "planned"; return 0; }
  jq -r '.status // "planned"' "$sf"
}

set_sprint_status() {
  local sprint="$1"
  local new_status="$2"
  local sf tmp
  sf="$(sprint_stories_file "$sprint")"
  [ -f "$sf" ] || fail "Sprint stories file not found: $sf"
  tmp="$(mktemp)"
  jq --arg s "$new_status" '.status = $s' "$sf" > "$tmp"
  mv "$tmp" "$sf"
}

commit_sprint_ready_checkpoint() {
  local sprint="$1"
  local sprint_dir stories_file

  sprint_dir="$(sprint_live_dir "$sprint")"
  stories_file="$(sprint_stories_file "$sprint")"

  git add "$stories_file" "$sprint_dir" 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "chore(ralph): ready sprint $sprint"
  fi
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

set_active_sprint() {
  local sprint="$1"
  echo "$sprint" > "$ACTIVE_SPRINT_FILE"
}

activate_sprint() {
  local sprint="$1"
  local backlog_dir live_dir stories_file

  backlog_dir="$(sprint_backlog_dir "$sprint")"
  live_dir="$(sprint_live_dir "$sprint")"

  if [ -d "$backlog_dir" ] && [ ! -d "$live_dir" ]; then
    move_sprint_dir "$sprint" "$backlog_dir" "$live_dir" \
      "${SCRIPT_DIR#${WORKSPACE_ROOT}/}/backlog/$sprint" \
      "${SCRIPT_DIR#${WORKSPACE_ROOT}/}/sprints/$sprint"
  fi

  stories_file="$(sprint_stories_file "$sprint")" || fail "Sprint does not exist: $sprint"
  [ -f "$stories_file" ] || fail "Sprint does not exist: $sprint"

  # Gate: sprint must be marked ready before activation
  local sprint_status
  sprint_status="$(get_sprint_status "$sprint")"
  if [ "$sprint_status" != "ready" ]; then
    fail "Sprint '$sprint' is not ready (status: $sprint_status). Run: ./ralph-sprint.sh mark-ready $sprint"
  fi

  # Gate: no other sprint can be active (enforces sequential sprint flow)
  local other_sprint
  while IFS= read -r other_sprint; do
    [ -n "$other_sprint" ] || continue
    [ "$other_sprint" = "$sprint" ] && continue
    local other_status
    other_status="$(get_sprint_status "$other_sprint")"
    if [ "$other_status" = "active" ]; then
      fail "Sprint '$other_sprint' is still active. Run: ./ralph-sprint-commit.sh to close it first."
    fi
  done < <(sorted_sprints)

  # Write activation metadata before branching so sprint branch inherits committed state
  set_sprint_status "$sprint" "active"
  set_active_sprint "$sprint"

  git add -A "$backlog_dir" "$live_dir" 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "chore(ralph): activate sprint $sprint"
  fi

  ensure_sprint_branch_exists "$sprint"
  echo "Active sprint set to: $sprint"
  checkout_sprint_branch "$sprint"
}

sorted_sprints() {
  {
    [ -d "$(ralph_backlog_root)" ] && find "$(ralph_backlog_root)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null -exec basename {} \;
    [ -d "$SPRINTS_DIR" ] && find "$SPRINTS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name archive 2>/dev/null -exec basename {} \;
  } \
    | awk '
        /^sprint-[0-9]+$/ {
          num = $0; sub(/^sprint-/, "", num)
          printf "0\t%09d\t%s\n", num + 0, $0
          next
        }
        {
          printf "1\t%s\t%s\n", $0, $0
        }
      ' \
    | sort -t $'\t' -k1,1 -k2,2 \
    | cut -f3
}

sprint_ordinal() {
  local sprint="$1"
  if [[ "$sprint" =~ ^sprint-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

roadmap_baseline_sprint() {
  local roadmap_file
  roadmap_file="$SCRIPT_DIR/roadmap.json"
  [ -f "$roadmap_file" ] || return 1

  jq -r '
    [.sprints[]?.name | select(test("^sprint-[0-9]+$"))]
    | sort_by(capture("^sprint-(?<n>[0-9]+)$").n | tonumber)
    | .[0] // empty
  ' "$roadmap_file"
}

sprint_is_historic_for_auto_selection() {
  local sprint="$1"
  local sprint_num baseline_sprint baseline_num

  sprint_num="$(sprint_ordinal "$sprint" || true)"
  [ -n "$sprint_num" ] || return 1

  baseline_sprint="$(roadmap_baseline_sprint || true)"
  [ -n "$baseline_sprint" ] || return 1

  baseline_num="$(sprint_ordinal "$baseline_sprint" || true)"
  [ -n "$baseline_num" ] || return 1

  [ "$sprint_num" -lt "$baseline_num" ]
}

sprint_is_unfinished() {
  local sprint="$1"
  local stories_file
  local historic_for_auto_selection
  stories_file="$(sprint_stories_file "$sprint")"
  [ -f "$stories_file" ] || return 1
  historic_for_auto_selection=false
  if sprint_is_historic_for_auto_selection "$sprint"; then
    historic_for_auto_selection=true
  fi

  jq -e --argjson historic "$historic_for_auto_selection" '
    (.stories | type) == "array" and
    (.stories | length > 0) and (
      (.activeStoryId // null) != null
      or any(
        .stories[]?;
        (.status // "planned") as $s
        | if $historic then
            ($s != "done" and $s != "abandoned" and $s != "blocked")
          else
            ($s != "done" and $s != "abandoned")
          end
      )
    )
  ' "$stories_file" >/dev/null 2>&1
}

find_next_sprint() {
  local sprint
  while IFS= read -r sprint; do
    [ -n "$sprint" ] || continue
    local status
    status="$(get_sprint_status "$sprint")"
    [ "$status" = "ready" ] || continue
    if sprint_is_unfinished "$sprint"; then
      printf '%s\n' "$sprint"
      return 0
    fi
  done < <(sorted_sprints)

  return 1
}

# ---------------------------------------------------------------------------
# Sprint readiness status (story-based)
# ---------------------------------------------------------------------------

readiness_status() {
  local sprint="$1"
  local stories_file sprint_branch current_branch

  stories_file="$(sprint_stories_file "$sprint")"
  sprint_branch="$(sprint_branch_name "$sprint")"
  current_branch="$(git branch --show-current)"

  [ -f "$stories_file" ] || fail "Missing sprint stories file: $stories_file"
  jq -e '.stories and (.stories | type == "array")' "$stories_file" >/dev/null 2>&1 \
    || fail "Invalid stories.json: $stories_file"

  echo "Active sprint:   $sprint"
  echo "Stories file:    $stories_file"

  local story_count capacity_target capacity_ceiling planned_effort
  story_count="$(jq '.stories | length' "$stories_file")"
  capacity_target="$(jq -r '.capacityTarget // 8' "$stories_file")"
  capacity_ceiling="$(jq -r '.capacityCeiling // 10' "$stories_file")"
  planned_effort="$(jq -r '[.stories[]?.effort // 0] | add // 0' "$stories_file")"
  echo "Story count:     $story_count"
  echo "Capacity:        target=$capacity_target  ceiling=$capacity_ceiling  planned=$planned_effort"
  if [ "$planned_effort" -gt "$capacity_ceiling" ]; then
    echo "WARNING: planned effort ($planned_effort) exceeds sprint ceiling ($capacity_ceiling)."
  fi

  if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
    echo "Sprint branch:   $sprint_branch (exists)"
  else
    echo "Sprint branch:   $sprint_branch (missing — run: ralph-sprint.sh branch $sprint)"
  fi
  echo "Current branch:  $current_branch"

  local active_id
  active_id="$(jq -r '.activeStoryId // empty' "$stories_file")"
  if [ -n "$active_id" ]; then
    jq -r --arg id "$active_id" '
      .stories[] | select(.id == $id)
      | "Active story:    \(.id) (P\(.priority) E\(.effort // 0)) — \(.title)\n" +
        "  status: \(.status)"
    ' "$stories_file" 2>/dev/null || echo "Active story:    $active_id (not found in stories list)"
  else
    echo "Active story:    (none)"
  fi

  local next_id
  next_id="$(RALPH_STORIES_FILE="$stories_file" "$SCRIPT_DIR/ralph-story.sh" next-id 2>/dev/null || true)"
  if [ -n "$next_id" ]; then
    jq -r --arg id "$next_id" '
      .stories[] | select(.id == $id)
      | "Next story:      \(.id) (P\(.priority) E\(.effort // 0)) — \(.title)"
    ' "$stories_file" 2>/dev/null || echo "Next story:      $next_id"
  else
    echo "Next story:      (none eligible)"
  fi

  echo ""
  if [ -n "$active_id" ]; then
    echo "Next action: ./ralph-story-run.sh to continue active story $active_id"
  elif [ -n "$next_id" ]; then
    echo "Next action: ./ralph-story.sh start-next && ./ralph-story-run.sh"
  else
    echo "Next action: ./ralph-story.sh add --title '<title>' to plan new work"
  fi
}

# ---------------------------------------------------------------------------
# cmd_create
# ---------------------------------------------------------------------------

cmd_create() {
  local sprint no_activate

  [ $# -ge 1 ] || fail "Usage: create <sprint-name> [--no-activate]"
  sprint="$(normalize_sprint_name "$1")"
  [ -n "$sprint" ] || fail "Invalid sprint name."
  shift || true
  no_activate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-activate) no_activate=1 ;;
      *) fail "Unknown create option: $1" ;;
    esac
    shift
  done

  ensure_sprint_structure "$sprint"
  echo "Created sprint: $sprint"
  if [ "$no_activate" -eq 1 ]; then
    echo "Sprint remains planned."
    return 0
  fi

  set_sprint_status "$sprint" "active"
  ensure_sprint_branch_exists "$sprint"
  set_active_sprint "$sprint"
  echo "Active sprint set to: $sprint"
  checkout_sprint_branch "$sprint"
  echo ""
  echo "Add stories with: ./ralph-story.sh add --title '<title>' [options]"
}

cmd_mark_ready() {
  local sprint auto_commit=1

  [ $# -ge 1 ] || fail "Usage: mark-ready <sprint-name> [--no-commit]"
  sprint="$(normalize_sprint_name "$1")"
  [ -n "$sprint" ] || fail "Invalid sprint name."
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-commit) auto_commit=0; shift ;;
      *) fail "Unknown mark-ready option: $1" ;;
    esac
  done

  local sf
  sf="$(sprint_stories_file "$sprint")"
  [ -f "$sf" ] || fail "Sprint does not exist: $sprint"

  local cur_status
  cur_status="$(get_sprint_status "$sprint")"
  if [ "$cur_status" = "active" ] || [ "$cur_status" = "closed" ]; then
    fail "Sprint '$sprint' is already $cur_status — cannot mark ready."
  fi

  # Require at least one story
  local story_count
  story_count="$(jq '.stories | length' "$sf")"
  if [ "$story_count" -eq 0 ]; then
    fail "Sprint '$sprint' has no stories. Add stories with: ./ralph-story.sh add --title '<title>'"
  fi

  # Promote eligible planned stories to ready. This is the explicit readiness
  # boundary after prepare-all, which now only generates and validates artifacts.
  local promoted_any=0
  while IFS=$'\t' read -r sid status raw_path; do
    [ -n "$sid" ] || continue
    [ "$status" = "planned" ] || continue

    local story_path_abs
    if [[ "$raw_path" != /* ]]; then
      story_path_abs="$WORKSPACE_ROOT/$raw_path"
    else
      story_path_abs="$raw_path"
    fi

    if [ ! -f "$story_path_abs" ]; then
      continue
    fi

    if ! jq -e '.tasks | length > 0' "$story_path_abs" >/dev/null 2>&1; then
      continue
    fi

    if ! RALPH_STORIES_FILE="$sf" "$SCRIPT_DIR/ralph-story.sh" health "$sid" >/dev/null 2>&1; then
      continue
    fi

    local tmp
    tmp="$(mktemp)"
    jq --arg id "$sid" '
      .stories = (
        .stories
        | map(if .id == $id then .status = "ready" else . end)
      )
    ' "$sf" > "$tmp"
    mv "$tmp" "$sf"
    promoted_any=1
  done < <(jq -r '.stories[] | select((.status != "done") and (.status != "abandoned")) | [.id, (.status // "planned"), (.story_path // "")] | @tsv' "$sf")

  [ "$promoted_any" -eq 1 ] && echo "Promoted eligible planned stories to ready."

  # Validate all non-done/abandoned stories are now ready
  local not_ready
  not_ready="$(jq -r '.stories[] | select((.status != "done") and (.status != "abandoned") and (.status != "ready")) | "\(.id)\t\(.status // "planned")"' "$sf")"
  if [ -n "$not_ready" ]; then
    echo "Sprint has stories not yet ready:" >&2
    printf '%s\n' "$not_ready" >&2
    fail "All active stories must be eligible and healthy before marking the sprint ready. Run: ./ralph-story.sh prepare-all and fix any remaining health issues."
  fi

  set_sprint_status "$sprint" "ready"
  if [ "$auto_commit" -eq 1 ]; then
    commit_sprint_ready_checkpoint "$sprint"
  fi
  echo "Sprint '$sprint' marked ready."
  echo "To activate: ./ralph-sprint.sh use $sprint"
}

cmd_restage() {
  local sprint

  [ $# -eq 1 ] || fail "Usage: restage <sprint-name>"
  sprint="$(normalize_sprint_name "$1")"
  [ -n "$sprint" ] || fail "Invalid sprint name."

  local sf tmp
  sf="$(sprint_stories_file "$sprint")"
  [ -f "$sf" ] || fail "Sprint does not exist: $sprint"

  tmp="$(mktemp)"
  jq '
    .status = "planned"
    | .activeStoryId = null
    | .stories |= map(
        if (.status == "done" or .status == "abandoned" or .status == "blocked") then
          .
        else
          .status = "planned" | .passes = false
        end
      )
  ' "$sf" > "$tmp"
  mv "$tmp" "$sf"

  echo "Sprint '$sprint' restaged to planned."
}

# ---------------------------------------------------------------------------
# confirm_action / remove_sprint
# ---------------------------------------------------------------------------

confirm_action() {
  local prompt="$1"
  local assume_yes="${2:-0}"
  local reply
  if [ "$assume_yes" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    fail "Confirmation required in non-interactive mode. Re-run with --yes."
  fi
  read -r -p "$prompt [y/N]: " reply
  case "${reply,,}" in
    y|yes) return 0 ;;
    *) fail "Aborted." ;;
  esac
}

remove_sprint() {
  local sprint_raw="$1"
  shift
  local sprint hard_delete assume_yes drop_branch
  local stories_file sprint_dir archive_dir stamp sprint_branch parent_branch active

  sprint="$(normalize_sprint_name "$sprint_raw")"
  [ -n "$sprint" ] || fail "Invalid sprint name."

  hard_delete=0
  assume_yes=0
  drop_branch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hard)       hard_delete=1; drop_branch=1 ;;
      --yes)        assume_yes=1 ;;
      --drop-branch) drop_branch=1 ;;
      *) fail "Unknown remove option: $1" ;;
    esac
    shift
  done

  stories_file="$(sprint_stories_file "$sprint")"
  sprint_dir="$(dirname "$stories_file")"
  [ -f "$stories_file" ] || fail "Sprint does not exist: $sprint"

  active="$(get_active_sprint || true)"
  if [ "$active" = "$sprint" ]; then
    confirm_action "Sprint $sprint is active. Remove and clear active sprint?" "$assume_yes"
    rm -f "$ACTIVE_SPRINT_FILE"
  else
    if [ "$hard_delete" -eq 1 ]; then
      confirm_action "Permanently delete sprint $sprint?" "$assume_yes"
    else
      confirm_action "Archive and remove sprint $sprint?" "$assume_yes"
    fi
  fi

  if [ "$hard_delete" -eq 1 ]; then
    rm -rf "$sprint_dir"
    echo "Removed sprint permanently: $sprint"
  else
    stamp="$(date +%F)-${sprint}-removed"
    archive_dir="$ARCHIVE_ROOT/$stamp"
    if [ -e "$archive_dir" ]; then
      archive_dir="${archive_dir}-$(date +%H%M%S)"
    fi
    mkdir -p "$archive_dir"
    [ -d "$sprint_dir" ] && mv "$sprint_dir" "$archive_dir/sprint"
    cat > "$archive_dir/archive-manifest.txt" <<EOF
action=remove-sprint
sprint=$sprint
removed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
source_sprint_dir=$sprint_dir
EOF
    echo "Archived sprint to: $archive_dir"
  fi

  sprint_branch="$(sprint_branch_name "$sprint")"
  if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
    parent_branch="$(resolve_branch_parent "$sprint_branch")"
    if [ "$drop_branch" -eq 1 ]; then
      if [ "$(git branch --show-current)" = "$sprint_branch" ]; then
        git checkout "$parent_branch" >/dev/null
      fi
      git branch -D "$sprint_branch" >/dev/null
      echo "Deleted sprint branch: $sprint_branch"
    else
      if git merge-base --is-ancestor "$sprint_branch" "$parent_branch"; then
        if [ "$(git branch --show-current)" = "$sprint_branch" ]; then
          git checkout "$parent_branch" >/dev/null
        fi
        git branch -d "$sprint_branch" >/dev/null
        echo "Deleted merged sprint branch: $sprint_branch"
      else
        echo "Kept unmerged sprint branch: $sprint_branch (use --drop-branch to force delete)"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  require_cmd git
  require_cmd jq
  require_cmd sed
  require_cmd tr

  while [ $# -gt 0 ]; do
    case "$1" in
      --free)
        RALPH_FREE_MODE=1
        export RALPH_FREE_MODE
        shift
        ;;
      --)
        shift
        break
        ;;
      -h|--help|help)
        usage
        return 0
        ;;
      -*)
        fail "Unknown global option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  local cmd="${1:-}"
  case "$cmd" in
    list)
      sorted_sprints
      ;;
    create)
      shift
      cmd_create "$@"
      ;;
    remove)
      [ $# -ge 2 ] || fail "Usage: remove <sprint-name> [--hard] [--yes] [--drop-branch]"
      remove_sprint "$2" "${@:3}"
      ;;
    use)
      [ $# -eq 2 ] || fail "Usage: use <sprint-name>"
      local sprint
      sprint="$(normalize_sprint_name "$2")"
      activate_sprint "$sprint"
      ;;
    mark-ready)
      shift
      cmd_mark_ready "$@"
      ;;
    restage)
      shift
      cmd_restage "$@"
      ;;
    next)
      shift
      local next_sprint activate
      activate=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --activate) activate=1 ;;
          *) fail "Usage: next [--activate]" ;;
        esac
        shift
      done
      next_sprint="$(find_next_sprint)" || fail "No ready sprint found. Mark one ready with: ./ralph-sprint.sh mark-ready <name>"
      echo "$next_sprint"
      if [ "$activate" -eq 1 ]; then
        activate_sprint "$next_sprint"
      fi
      ;;
    branch)
      [ $# -eq 2 ] || fail "Usage: branch <sprint-name>"
      local sprint
      sprint="$(normalize_sprint_name "$2")"
      [ -f "$(sprint_stories_file "$sprint")" ] || fail "Sprint does not exist: $sprint"
      ensure_sprint_branch_exists "$sprint"
      ;;
    status)
      local active
      active="$(get_active_sprint || true)"
      [ -n "$active" ] || fail "No active sprint set."
      readiness_status "$active"
      ;;
    add-epic|add-epics)
      echo "ralph-sprint.sh: '$cmd' is removed. Use ralph-story.sh to manage stories." >&2
      echo "  ./ralph-story.sh add --title '<title>' [options]" >&2
      exit 1
      ;;
    bootstrap-current)
      echo "ralph-sprint.sh: 'bootstrap-current' is removed." >&2
      echo "  Sprint planning now starts from stories.json and story.json artifacts." >&2
      exit 1
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      fail "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
