#!/bin/bash
# ralph-story-run.sh — Story-level executor for the story-task architecture.
#
# Runs one primary Codex session per story, keeping task progression, ordinary
# check-fix loops, and story.json updates inside that story cycle. Shell checks
# remain the source of truth for final pass/fail state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
source "$SCRIPT_DIR/lib/codex-exec.sh"
LOCK_DIR="$SCRIPT_DIR/.workflow-lock"

STORY_FILE=""
TARGET_TASK_ID=""
MAX_RETRIES=1
DRY_RUN=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: ./ralph-story-run.sh [options]

Run the active story as a single primary Codex cycle. The model executes tasks
in dependency order, fixes ordinary issues in-session, and updates story.json.
Shell checks still decide final pass/fail state after the cycle exits.

Options:
  --story PATH        Path to story.json (default: active story from sprint)
  --task-id ID        Limit execution to a single task for focused repair
  --max-retries N     Max targeted remediation cycles after the primary story cycle (default: 1)
  --dry-run           Print the prompt without executing Codex
  --quiet             Suppress verbose output
  -h, --help          Show help

Environment:
  CODEX_BIN           Codex binary path (default: codex)
  RALPH_CODEX_PROFILE Profile flag passed to codex exec
EOF
}

fail() { echo "ERROR: $1" >&2; exit 1; }
log()  { [ "$QUIET" -eq 0 ] && echo "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)       STORY_FILE="${2:-}"; shift 2 ;;
    --task-id)     TARGET_TASK_ID="${2:-}"; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:-1}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    --skip-fallow) shift ;; # deprecated compatibility flag
    -h|--help)     usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq
require_cmd git

resolve_story_file() {
  if [ -n "$STORY_FILE" ]; then
    [ -f "$STORY_FILE" ] || fail "Story file not found: $STORY_FILE"
    return
  fi

  local active_sprint_file="$SCRIPT_DIR/.active-sprint"
  [ -f "$active_sprint_file" ] || fail "No --story given and no .active-sprint found."
  local sprint
  sprint="$(cat "$active_sprint_file")"

  local stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  [ -f "$stories_file" ] || fail "No stories.json for sprint $sprint: $stories_file"

  local active_id
  active_id="$(jq -r '.activeStoryId // empty' "$stories_file")"
  [ -n "$active_id" ] || fail "No activeStoryId set in $stories_file. Run ralph-story.sh use <id> first."

  local story_path
  story_path="$(jq -r --arg id "$active_id" '.stories[] | select(.id == $id) | .story_path // empty' "$stories_file")"
  [ -n "$story_path" ] || fail "Story $active_id not found in $stories_file"
  [[ "$story_path" != /* ]] && story_path="$WORKSPACE_ROOT/$story_path"
  [ -f "$story_path" ] || fail "Story file not found: $story_path"
  STORY_FILE="$story_path"
}

resolve_story_file
STORY_DIR="$(dirname "$STORY_FILE")"

task_status() {
  local task_id="$1"
  jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .status // "pending"' "$STORY_FILE"
}

task_passes() {
  local task_id="$1"
  jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .passes // false' "$STORY_FILE"
}

deps_met() {
  local task_id="$1"
  local deps
  deps="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .depends_on[]?' "$STORY_FILE")"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    [ "$(task_passes "$dep")" = "true" ] || return 1
  done <<< "$deps"
  return 0
}

set_task_field() {
  local task_id="$1"
  local field="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$task_id" --arg field "$field" --argjson val "$value" \
    '(.tasks[] | select(.id == $id) | .[$field]) = $val' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

set_story_field() {
  local field="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg field "$field" --argjson val "$value" '.[$field] = $val' "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

mark_task_done() {
  local task_id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$task_id" \
    '(.tasks[] | select(.id == $id)) |= . + {"status": "done", "passes": true}' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

mark_task_failed() {
  local task_id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$task_id" \
    '(.tasks[] | select(.id == $id)) |= . + {"status": "failed", "passes": false}' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

mark_story_done() {
  local tmp
  tmp="$(mktemp)"
  jq '. + {"status": "done", "passes": true}' "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

resolve_repo_path() {
  local raw="$1"
  [[ "$raw" == /* ]] && printf '%s\n' "$raw" || printf '%s/%s\n' "$WORKSPACE_ROOT" "$raw"
}

filtered_task_scope_json() {
  local task_id="$1"
  jq -c --arg id "$task_id" '
    [
      .tasks[]
      | select(.id == $id)
      | (.scope // [])[]
      | select(type == "string")
      | select((test("(^|/)(node_modules|\\.next|coverage|dist|build|vendor)/")) | not)
    ]
  ' "$STORY_FILE"
}

extract_check_file() {
  local check="$1"
  if [[ "$check" =~ test[[:space:]]+-[fed][[:space:]]+([^[:space:]]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$check" =~ \[[[:space:]]+-[fed][[:space:]]+([^[:space:]|]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  case "$check" in
    grep\ *|cat\ *|wc\ *)
      awk '{print $NF}' <<< "$check"
      ;;
  esac
}

check_fp() {
  local check="$1"
  local task_id="$2"
  local ref
  ref="$(extract_check_file "$check")"
  if [ -n "$ref" ]; then
    local abs
    abs="$(resolve_repo_path "$ref")"
    if [ -f "$abs" ]; then
      git -C "$WORKSPACE_ROOT" hash-object "$abs" 2>/dev/null || echo "UNHASHED"
    else
      echo "ABSENT:$ref"
    fi
    return
  fi

  local fp=""
  while IFS= read -r sf; do
    [ -z "$sf" ] && continue
    local abs
    abs="$(resolve_repo_path "$sf")"
    if [ -f "$abs" ]; then
      fp+=$(git -C "$WORKSPACE_ROOT" hash-object "$abs" 2>/dev/null || echo "X")
    else
      fp+="ABSENT:$sf"
    fi
  done < <(filtered_task_scope_json "$task_id" | jq -r '.[]?')
  echo "${fp:-EMPTY}"
}

capture_failing_fingerprints() {
  local out="$1"
  : > "$out"
  local task_ids=()
  while IFS= read -r tid; do
    task_ids+=("$tid")
  done < <(jq -r '.tasks[].id' "$STORY_FILE")

  local task_id
  for task_id in "${task_ids[@]}"; do
    [ "$(task_passes "$task_id")" = "true" ] && continue
    local check_num=0 check
    while IFS= read -r check; do
      [ -z "$check" ] && continue
      check_num=$((check_num + 1))
      if ! (cd "$WORKSPACE_ROOT" && eval "$check") >/dev/null 2>&1; then
        echo "${task_id}|${check_num}|$(check_fp "$check" "$task_id")" >> "$out"
      fi
    done < <(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .checks[]?' "$STORY_FILE")
  done
}

dependency_handoff_json() {
  local entries='[]'
  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local stories_file dep_path
    stories_file="$SCRIPT_DIR/sprints/$(awk 'NF {print; exit}' "$SCRIPT_DIR/.active-sprint" 2>/dev/null || true)/stories.json"
    [ -f "$stories_file" ] || continue
    dep_path="$(jq -r --arg id "$dep_id" '.stories[] | select(.id == $id) | .story_path // ""' "$stories_file" 2>/dev/null)"
    [ -n "$dep_path" ] || continue
    dep_path="$(resolve_repo_path "$dep_path")"
    [ -f "$dep_path" ] || continue

    local dep_title files_json contracts_json risks_json dep_entry
    dep_title="$(jq -r '.title // ""' "$dep_path")"
    files_json="$(jq -c '.story_handoff.files_touched // []' "$dep_path" 2>/dev/null || echo '[]')"
    contracts_json="$(jq -c '.story_handoff.contracts_added // []' "$dep_path" 2>/dev/null || echo '[]')"
    risks_json="$(jq -c '.story_handoff.residual_risks // []' "$dep_path" 2>/dev/null || echo '[]')"
    dep_entry="$(jq -nc \
      --arg id "$dep_id" \
      --arg title "$dep_title" \
      --argjson files "$files_json" \
      --argjson contracts "$contracts_json" \
      --argjson risks "$risks_json" \
      '{id: $id, title: $title, files_touched: $files, contracts_added: $contracts, residual_risks: $risks}')"
    entries="$(jq -c --argjson entry "$dep_entry" '. + [$entry]' <<< "$entries")"
  done < <(jq -r '.depends_on[]?' "$STORY_FILE" 2>/dev/null)

  printf '%s\n' "$entries"
}

write_execution_manifest() {
  local manifest_path="$STORY_DIR/.story-execution.json"
  local deps_json
  deps_json="$(dependency_handoff_json)"
  jq -c \
    --arg target "$TARGET_TASK_ID" \
    --argjson deps "$deps_json" '
    {
      storyId,
      title,
      goal: (.goal // .description // ""),
      scope: (.spec.scope // ""),
      preserved_invariants: (.spec.preserved_invariants // []),
      dependency_handoff: $deps,
      tasks: [
        .tasks[]
        | select(.passes != true)
        | select($target == "" or .id == $target)
        | {
            id,
            title,
            scope: [
              (.scope // [])[]
              | select(type == "string")
              | select((test("(^|/)(node_modules|\\.next|coverage|dist|build|vendor)/")) | not)
            ],
            depends_on: (.depends_on // []),
            checks: (.checks // [])
          }
      ]
    }
  ' "$STORY_FILE" > "$manifest_path"
  printf '%s\n' "$manifest_path"
}

build_story_prompt() {
  local manifest_path mode_line
  manifest_path="$(write_execution_manifest)"
  if [ -n "$TARGET_TASK_ID" ]; then
    mode_line="Only execute task $TARGET_TASK_ID and any required story.json updates for that task."
  else
    mode_line="Execute all pending tasks in dependency order."
  fi

  cat <<PROMPT
Execute this story.

Read this execution summary first:
$manifest_path

Update this source-of-truth file as you work:
$STORY_FILE

$mode_line

Rules:
- Use the execution summary for the minimal task list, checks, invariants, and dependency handoff.
- Use story.json as the durable source of truth when you need fuller details and when writing status/handoff updates.
- Ignore vendor and generated trees such as node_modules, .next, coverage, dist, build, and vendor unless a check explicitly requires them.
- Stay inside each task's scope when editing.
- Run each task's checks yourself before moving on.
- Fix ordinary check failures in-session instead of stopping early.
- After a task passes, update that task with:
  status="done", passes=true, and handoff={"changed_files":[],"artifacts":[],"checks_passed":[],"remaining_risks":[]}
- If a task cannot be completed, mark it failed with a compact handoff and stop.
- When all tasks pass, set status="done", passes=true, and story_handoff={"completed_tasks":[],"files_touched":[],"contracts_added":[],"residual_risks":[]}
- Keep residual risk lists empty unless something truly remains unresolved.
- Commit code and story.json changes as needed.
- Do not update stories.json.
PROMPT
}

run_story_cycle() {
  local cycle_kind="$1"
  local prompt="$2"
  local log_file="$STORY_DIR/.story-run-${cycle_kind}.log"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY RUN] Would run story cycle: $cycle_kind"
    log "--- prompt ---"
    log "$prompt"
    log "--------------"
    return 0
  fi

  log "Running Codex story cycle: $cycle_kind"
  codex_exec_prompt "$prompt" "$WORKSPACE_ROOT" 2>&1 | tee "$log_file"
}

ensure_task_handoff_fallback() {
  local task_id="$1"
  local existing
  existing="$(jq -c --arg id "$task_id" '.tasks[] | select(.id == $id) | .handoff // empty' "$STORY_FILE")"
  [ -n "$existing" ] && [ "$existing" != "null" ] && return 0

  local handoff
  handoff="$(jq -nc \
    --argjson changed "$(filtered_task_scope_json "$task_id")" \
    --argjson checks "$(jq -c --arg id "$task_id" '.tasks[] | select(.id == $id) | (.checks // [])' "$STORY_FILE")" \
    '{changed_files: $changed, artifacts: [], checks_passed: $checks, remaining_risks: []}')"
  set_task_field "$task_id" "handoff" "$handoff"
}

set_task_handoff_failure() {
  local task_id="$1"
  local checks_json="$2"
  local risk_text="$3"
  local handoff
  handoff="$(jq -nc \
    --argjson changed "$(filtered_task_scope_json "$task_id")" \
    --argjson checks "$checks_json" \
    --arg risk "$risk_text" \
    '{changed_files: $changed, artifacts: [], checks_passed: [], remaining_risks: [$risk], failing_checks: $checks}')"
  set_task_field "$task_id" "handoff" "$handoff"
}

finalize_story_handoff() {
  local handoff
  handoff="$(jq -c '
    {
      completed_tasks: [.tasks[] | select(.passes == true) | .id],
      files_touched: ([
        .tasks[]
        | select(.passes == true)
        | (.handoff.changed_files // .scope // [])[]?
        | select(type == "string")
        | select((test("(^|/)(node_modules|\\.next|coverage|dist|build|vendor)/")) | not)
      ] | unique),
      contracts_added: ([.tasks[] | select(.passes == true) | (.handoff.artifacts // [])[]?] | unique),
      residual_risks: ([.tasks[] | (.handoff.remaining_risks // [])[]?] | unique)
    }
  ' "$STORY_FILE")"
  set_story_field "story_handoff" "$handoff"
}

VERIFY_FAILED_TASK_ID=""
VERIFY_FAILED_CHECKS_JSON="[]"
VERIFY_FAILED_STRUCTURAL=0

verify_story() {
  local baseline_fp_file="$1"
  VERIFY_FAILED_TASK_ID=""
  VERIFY_FAILED_CHECKS_JSON="[]"
  VERIFY_FAILED_STRUCTURAL=0

  local failure_seen=0
  local task_id
  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue

    if [ "$failure_seen" -eq 1 ] && ! deps_met "$task_id"; then
      set_task_field "$task_id" "status" '"blocked"'
      set_task_field "$task_id" "passes" 'false'
      continue
    fi

    if ! deps_met "$task_id"; then
      set_task_field "$task_id" "status" '"blocked"'
      set_task_field "$task_id" "passes" 'false'
      failure_seen=1
      [ -n "$VERIFY_FAILED_TASK_ID" ] || VERIFY_FAILED_TASK_ID="$task_id"
      continue
    fi

    local fp_file fail_file
    fp_file="$(mktemp)"
    fail_file="$(mktemp)"
    : > "$fp_file"
    : > "$fail_file"

    local check_num=0 check failed=0
    while IFS= read -r check; do
      [ -z "$check" ] && continue
      check_num=$((check_num + 1))
      if (cd "$WORKSPACE_ROOT" && eval "$check") >/dev/null 2>&1; then
        :
      else
        failed=1
        echo "${task_id}|${check_num}|$(check_fp "$check" "$task_id")" >> "$fp_file"
        printf '%s\n' "$check" >> "$fail_file"
      fi
    done < <(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .checks[]?' "$STORY_FILE")

    if [ "$failed" -eq 0 ]; then
      mark_task_done "$task_id"
      ensure_task_handoff_fallback "$task_id"
      rm -f "$fp_file" "$fail_file"
      continue
    fi

    failure_seen=1
    mark_task_failed "$task_id"
    VERIFY_FAILED_TASK_ID="$task_id"
    VERIFY_FAILED_CHECKS_JSON="$(jq -Rsc 'split("\n") | map(select(length > 0))' "$fail_file")"
    set_task_handoff_failure "$task_id" "$VERIFY_FAILED_CHECKS_JSON" "Shell checks still failing after story cycle."

    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      if grep -qF "$entry" "$baseline_fp_file" 2>/dev/null; then
        VERIFY_FAILED_STRUCTURAL=1
        break
      fi
    done < "$fp_file"

    rm -f "$fp_file" "$fail_file"
    break
  done < <(if [ -n "$TARGET_TASK_ID" ]; then printf '%s\n' "$TARGET_TASK_ID"; else jq -r '.tasks[].id' "$STORY_FILE"; fi)

  [ -z "$VERIFY_FAILED_TASK_ID" ]
}

acquire_lock() {
  if [ "${RALPH_LOCK_HELD:-0}" = "1" ]; then return 0; fi
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    RALPH_LOCK_HELD=1
    export RALPH_LOCK_HELD
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' INT TERM EXIT
    return 0
  fi
  fail "Another Ralph workflow is running (lock: $LOCK_DIR). Use ralph-cleanup.sh --force to clear stale locks."
}

sync_story_metadata_to_backlog() {
  local active_sprint_file="$SCRIPT_DIR/.active-sprint"
  [ -f "$active_sprint_file" ] || return 0
  local sprint meta_file stmp
  sprint="$(awk 'NF {print; exit}' "$active_sprint_file")"
  meta_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  [ -f "$meta_file" ] || return 0
  stmp="$(mktemp)"
  jq --arg id "$STORY_ID" '
    .stories = [.stories[] | if .id == $id then .status = "done" | .passes = true else . end]
    | .activeStoryId = null
  ' "$meta_file" > "$stmp"
  mv "$stmp" "$meta_file"
}

merge_story_branch() {
  local story_branch story_title sprint sprint_branch merge_target meta_stories_file
  story_branch="$(jq -r '.branchName // ""' "$STORY_FILE" 2>/dev/null || true)"
  story_title="$(jq -r '.title // ""' "$STORY_FILE" 2>/dev/null || true)"
  sprint="$(awk 'NF {print; exit}' "$SCRIPT_DIR/.active-sprint" 2>/dev/null || true)"
  [ -n "$story_branch" ] && [ -n "$sprint" ] || return 0

  sprint_branch="ralph/sprint/$sprint"
  merge_target="$(git -C "$WORKSPACE_ROOT" for-each-ref --format='%(upstream:short)' "refs/heads/$story_branch" 2>/dev/null | head -n1)"
  [ -n "$merge_target" ] || merge_target="$sprint_branch"
  meta_stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"

  if ! git -C "$WORKSPACE_ROOT" show-ref --verify --quiet "refs/heads/$merge_target" 2>/dev/null; then
    return 0
  fi

  git -C "$WORKSPACE_ROOT" add "$STORY_FILE" 2>/dev/null || true
  [ -f "$meta_stories_file" ] && git -C "$WORKSPACE_ROOT" add "$meta_stories_file" 2>/dev/null || true
  if ! git -C "$WORKSPACE_ROOT" diff --cached --quiet 2>/dev/null; then
    git -C "$WORKSPACE_ROOT" commit -m "chore(ralph): $STORY_ID complete — story metadata"
    log "Committed story metadata on story branch."
  fi

  log "--- Merging $STORY_ID → parent branch ---"
  git -C "$WORKSPACE_ROOT" checkout "$merge_target"
  if git -C "$WORKSPACE_ROOT" -c merge.renames=false merge --no-ff "$story_branch" -m "merge: $STORY_ID — $story_title"; then
    git -C "$WORKSPACE_ROOT" branch -d "$story_branch" 2>/dev/null \
      || git -C "$WORKSPACE_ROOT" branch -D "$story_branch" 2>/dev/null \
      || true
    rm -f \
      "$STORY_DIR"/.story-run-*.log \
      "$STORY_DIR"/.story-execution.json \
      "$STORY_DIR"/.task-log-*.txt \
      "$STORY_DIR"/.fallow-autofix.txt \
      "$STORY_DIR"/.fallow-report.json
    log "Merged and deleted story branch: $story_branch"
  else
    log "WARN: Merge conflict merging $story_branch → $merge_target. Resolve manually then delete $story_branch."
  fi
}

build_remediation_prompt() {
  local task_id="$1"
  local checks_json="$2"
  local task_scope checks_text
  task_scope="$(filtered_task_scope_json "$task_id" | jq -r 'join(", ")')"
  checks_text="$(jq -r '.[]' <<< "$checks_json" 2>/dev/null || printf '%s\n' "$checks_json")"
  cat <<PROMPT
Repair the remaining failing story checks.

Read and update:
$STORY_FILE

Focus only on task $task_id.
Scope: ${task_scope:-none}
Still failing checks:
$checks_text

Rules:
- Make only the minimal code and story.json changes needed to satisfy the failing checks.
- Re-run the failing checks yourself before finishing.
- Update the task handoff compactly.
- Stop once the failing checks are green. Do not update stories.json.
PROMPT
}

acquire_lock

STORY_ID="$(jq -r '.storyId' "$STORY_FILE")"
STORY_TITLE="$(jq -r '.title' "$STORY_FILE")"

log ""
log "=== ralph-story-run: $STORY_ID — $STORY_TITLE ==="
log "Story file: $STORY_FILE"
log ""

if [ -n "$TARGET_TASK_ID" ]; then
  jq -e --arg id "$TARGET_TASK_ID" '.tasks[] | select(.id == $id)' "$STORY_FILE" >/dev/null \
    || fail "Task $TARGET_TASK_ID not found in story."
fi

baseline_fp_file="$(mktemp)"
capture_failing_fingerprints "$baseline_fp_file"

primary_prompt="$(build_story_prompt)"
run_story_cycle "primary" "$primary_prompt"

remediation_count=0
if ! verify_story "$baseline_fp_file"; then
  while [ "$remediation_count" -lt "$MAX_RETRIES" ]; do
    if [ "$VERIFY_FAILED_STRUCTURAL" -eq 1 ] || [ -z "$VERIFY_FAILED_TASK_ID" ]; then
      break
    fi
    remediation_count=$((remediation_count + 1))
    remediation_prompt="$(build_remediation_prompt "$VERIFY_FAILED_TASK_ID" "$VERIFY_FAILED_CHECKS_JSON")"
    capture_failing_fingerprints "$baseline_fp_file"
    run_story_cycle "remediation-$remediation_count" "$remediation_prompt"
    verify_story "$baseline_fp_file" && break
  done
fi
rm -f "$baseline_fp_file"

if [ -n "$VERIFY_FAILED_TASK_ID" ]; then
  log "=== Story $STORY_ID: some tasks incomplete or blocked ==="
  exit 1
fi

finalize_story_handoff
mark_story_done
sync_story_metadata_to_backlog
merge_story_branch

log "=== Story $STORY_ID COMPLETE ==="
exit 0
