#!/bin/bash
# ralph-sprint-migrate.sh — Convert a sprint from epic/PRD format to story-task format.
#
# Migration mapping:
#   epics.json epic          → stories.json entry + story.json file
#   epic.id (EPIC-XXX)       → story.storyId (S-XXX)
#   epic.title               → story.title
#   epic.goal                → story.description + spec.scope
#   epic.dependsOn           → story.depends_on (IDs remapped EPIC-XXX → S-XXX)
#   epic.status              → story.status
#   epic.effort              → story.effort
#   epic.planningSource      → story.planningSource
#   PRD userStory.id         → task.id (US-XXX → T-XX)
#   PRD userStory.description + acceptanceCriteria → task.context + task.acceptance
#   PRD userStory.scopePaths → task.scope
#   acceptanceCriteria keywords → task.checks (inferred: typecheck/tests/lint)
#   PRD branchName           → story.branchName
#
# Usage:
#   ./ralph-sprint-migrate.sh [--sprint SPRINT] [--dry-run] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

TARGET_SPRINT=""
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./ralph-sprint-migrate.sh [options]

Convert a sprint from epics.json / PRD format to stories.json / story.json format.

Options:
  --sprint NAME    Sprint to migrate (default: active sprint)
  --dry-run        Print migration plan without writing files
  --force          Overwrite existing stories.json and story.json files
  -h, --help       Show help

The migration is non-destructive by default:
  - epics.json is NOT removed; stories.json is written alongside it
  - Existing story.json files are skipped unless --force is used
  - PRD markdown is preserved; story.json references it under spec.prdPath

After migration, verify with:
  ./ralph-story.sh list
  ./ralph-story.sh tasks S-001
EOF
}

fail() { echo "ERROR: $1" >&2; exit 1; }
log()  { echo "$1"; }
dry()  { [ "$DRY_RUN" -eq 0 ] && return 0 || return 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sprint)   TARGET_SPRINT="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq

# Resolve sprint
if [ -z "$TARGET_SPRINT" ]; then
  [ -f "$ACTIVE_SPRINT_FILE" ] || fail "No --sprint given and no .active-sprint file found."
  TARGET_SPRINT="$(awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE")"
fi

SPRINT_DIR="$SPRINTS_DIR/$TARGET_SPRINT"
EPICS_FILE="$SPRINT_DIR/epics.json"
STORIES_FILE="$SPRINT_DIR/stories.json"
STORIES_SUBDIR="$SPRINT_DIR/stories"
TASKS_PRD_DIR="$SCRIPT_DIR/tasks"

[ -d "$SPRINT_DIR" ] || fail "Sprint directory not found: $SPRINT_DIR"
[ -f "$EPICS_FILE" ] || fail "epics.json not found: $EPICS_FILE"

if [ -f "$STORIES_FILE" ] && [ "$FORCE" -eq 0 ]; then
  fail "stories.json already exists at $STORIES_FILE. Use --force to overwrite."
fi

log "=== ralph-sprint-migrate: $TARGET_SPRINT ==="
log "Source: $EPICS_FILE"
log "Target: $STORIES_FILE"
[ "$DRY_RUN" -eq 1 ] && log "[DRY RUN — no files will be written]"
log ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Remap EPIC-XXX → S-XXX
remap_id() {
  local raw="$1"
  # Already S-format
  echo "$raw" | grep -q '^S-[0-9]' && { echo "$raw"; return; }
  # EPIC-XXX → S-XXX
  local num
  num="$(echo "$raw" | sed 's/^EPIC-0*//')"
  printf 'S-%03d' "$num"
}

# Remap US-XXX → T-XX
remap_task_id() {
  local raw="$1"
  local num
  num="$(echo "$raw" | sed 's/^US-0*//')"
  printf 'T-%02d' "$num"
}

epic_branch_suffix() {
  local epic_id="$1"
  local num
  num="$(echo "$epic_id" | sed 's/^EPIC-0*//')"
  printf 'epic-%03d' "$num"
}

# Infer machine-executable checks from acceptance criteria text
infer_checks() {
  local criteria_json="$1"
  local checks="[]"

  if printf '%s\n' "$criteria_json" | grep -Eqi '(^|[^[:alnum:]_])(typecheck|tsc|type check|type-check)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run typecheck"]')"
  fi
  if printf '%s\n' "$criteria_json" | grep -Eqi '(^|[^[:alnum:]_])(test|tests|jest|vitest|pytest|go test)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm test"]')"
  fi
  if printf '%s\n' "$criteria_json" | grep -Eqi '(^|[^[:alnum:]_])(lint|eslint)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run lint"]')"
  fi
  if printf '%s\n' "$criteria_json" | grep -Eqi '(^|[^[:alnum:]_])(build)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run build"]')"
  fi

  # Fallback: at minimum require typecheck if no checks inferred
  if [ "$checks" = "[]" ]; then
    checks='["npm run typecheck"]'
  fi

  echo "$checks"
}

choose_live_prd_json_for_epic() {
  local epic_id="$1"
  local expected_suffix active_epic current_branch
  local live_prd="$SCRIPT_DIR/prd.json"
  local active_prd="$SCRIPT_DIR/.active-prd"

  [ -f "$live_prd" ] || return 1

  expected_suffix="$(epic_branch_suffix "$epic_id")"

  if [ -f "$active_prd" ]; then
    active_epic="$(jq -r '.epicId // empty' "$active_prd" 2>/dev/null || true)"
    if [ "$active_epic" = "$epic_id" ]; then
      printf '%s\n' "$live_prd"
      return 0
    fi
  fi

  current_branch="$(jq -r '.branchName // empty' "$live_prd" 2>/dev/null || true)"
  if [[ "$current_branch" = *"/$expected_suffix" ]] || [[ "$current_branch" = *"$expected_suffix" ]]; then
    printf '%s\n' "$live_prd"
    return 0
  fi

  return 1
}

choose_archived_prd_json_for_epic() {
  local epic_id="$1"
  local expected_suffix archive_root candidate branch_name

  expected_suffix="$(epic_branch_suffix "$epic_id")"

  for archive_root in \
    "$TASKS_PRD_DIR/archive/$TARGET_SPRINT" \
    "$TASKS_PRD_DIR/archive/prds" \
    "$SCRIPT_DIR/archive" \
    "$SCRIPT_DIR/archive/$TARGET_SPRINT"
  do
    [ -d "$archive_root" ] || continue
    while IFS= read -r candidate; do
      [ -f "$candidate" ] || continue
      branch_name="$(jq -r '.branchName // empty' "$candidate" 2>/dev/null || true)"
      if [[ "$branch_name" = *"/$expected_suffix" ]] || [[ "$branch_name" = *"$expected_suffix" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$archive_root" -type f -name 'prd.json' | sort -r)
  done

  return 1
}

effective_story_status_for_migration() {
  local source_status="$1"
  local tasks_recovered="$2"

  if [ "$tasks_recovered" = "true" ]; then
    printf '%s\n' "$source_status"
    return 0
  fi

  case "$source_status" in
    active|planned|ready)
      printf 'blocked\n'
      ;;
    *)
      printf '%s\n' "$source_status"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Load epics
# ---------------------------------------------------------------------------

EPIC_COUNT="$(jq '.epics | length' "$EPICS_FILE")"
SPRINT_PROJECT="$(jq -r '.project' "$EPICS_FILE")"
CAPACITY_TARGET="$(jq -r '.capacityTarget // 8' "$EPICS_FILE")"
CAPACITY_CEILING="$(jq -r '.capacityCeiling // 10' "$EPICS_FILE")"

# Normalize legacy "aborted" → "abandoned" before processing
aborted_count="$(jq '[.epics[] | select(.status == "aborted")] | length' "$EPICS_FILE")"
if [ "$aborted_count" -gt 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    tmp="$(mktemp)"
    jq '.epics = (.epics | map(if .status == "aborted" then .status = "abandoned" else . end))' \
      "$EPICS_FILE" > "$tmp"
    mv "$tmp" "$EPICS_FILE"
  fi
  log "Normalized $aborted_count epic(s): aborted → abandoned"
fi

log "Project: $SPRINT_PROJECT"
log "Epics to migrate: $EPIC_COUNT"
log ""

# ---------------------------------------------------------------------------
# Build stories.json entries and story.json files
# ---------------------------------------------------------------------------

STORIES_ENTRIES="[]"
MIGRATED=0
SKIPPED=0
AUTO_RECOVERED=0
declare -a RECOVERY_PENDING=()

for i in $(seq 0 $((EPIC_COUNT - 1))); do
  epic="$(jq ".epics[$i]" "$EPICS_FILE")"

  epic_id="$(echo "$epic" | jq -r '.id')"
  epic_title="$(echo "$epic" | jq -r '.title')"
  epic_goal="$(echo "$epic" | jq -r '.goal // ""')"
  epic_status="$(echo "$epic" | jq -r '.status')"
  epic_effort="$(echo "$epic" | jq -r '.effort // 3')"
  epic_priority="$(echo "$epic" | jq -r '.priority')"
  epic_planning_source="$(echo "$epic" | jq -r '.planningSource // "local"')"
  epic_prompt_context="$(echo "$epic" | jq -r '.promptContext // ""')"
  epic_depends_raw="$(echo "$epic" | jq -r '.dependsOn[]?' | tr '\n' ',')"
  story_id="$(remap_id "$epic_id")"
  story_path_rel="scripts/ralph/sprints/$TARGET_SPRINT/stories/$story_id/story.json"
  story_path_abs="$WORKSPACE_ROOT/$story_path_rel"

  log "  $epic_id → $story_id: $epic_title"

  # Remap dependencies
  deps_json="[]"
  if [ -n "$epic_depends_raw" ]; then
    while IFS= read -r dep_raw; do
      [ -z "$dep_raw" ] && continue
      dep_new="$(remap_id "$dep_raw")"
      deps_json="$(echo "$deps_json" | jq --arg d "$dep_new" '. + [$d]')"
    done < <(echo "$epic" | jq -r '.dependsOn[]?')
  fi

  # Build story.json from PRD if available
  if [ -f "$story_path_abs" ] && [ "$FORCE" -eq 0 ]; then
    story_entry="$(jq -n \
      --arg id "$story_id" \
      --arg title "$epic_title" \
      --argjson priority "$epic_priority" \
      --argjson effort "$epic_effort" \
      --arg ps "$epic_planning_source" \
      --arg status "$epic_status" \
      --argjson depends "$deps_json" \
      --arg path "$story_path_rel" \
      --arg goal "$epic_goal" \
      --arg ctx "$epic_prompt_context" \
      '{
        "id": $id,
        "title": $title,
        "priority": $priority,
        "effort": $effort,
        "planningSource": $ps,
        "status": $status,
        "depends_on": $depends,
        "story_path": $path,
        "goal": $goal,
        "promptContext": $ctx
      }')"
    STORIES_ENTRIES="$(echo "$STORIES_ENTRIES" | jq --argjson entry "$story_entry" '. + [$entry]')"
    log "    SKIP story.json (exists, use --force to overwrite)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Find PRD markdown path
  prd_md_path="$(echo "$epic" | jq -r '.prdPaths[0] // empty')"

  TASKS_JSON="[]"
  TASKS_RECOVERED="false"
  STORY_BRANCH=""
  STORY_SCOPE=""
  STORY_OUT_OF_SCOPE="[]"
  STORY_FIRST_SLICE='{}'
  STORY_INVARIANTS="[]"
  STORY_SUPPORTING="[]"
  STORY_VERIFICATION="[]"
  PRD_MD_REF=""

  # Try to parse the PRD JSON (prd.json may have been archived; use prdPaths as reference)
  # We rely on the prd.json.example shape: project, branchName, userStories[]
  # Look for prd.json in task archive or current location
  prd_json_candidates=()
  if [ -n "$prd_md_path" ]; then
    PRD_MD_REF="$prd_md_path"
    # Infer prd.json sibling or sprint task directory
    prd_dir="$(dirname "$WORKSPACE_ROOT/$prd_md_path")"
    if [ -f "$prd_dir/prd.json" ]; then
      prd_json_candidates+=("$prd_dir/prd.json")
    fi
  fi
  # Only use the live runtime prd.json if it clearly belongs to this epic.
  if live_prd_json="$(choose_live_prd_json_for_epic "$epic_id" 2>/dev/null || true)" && [ -n "$live_prd_json" ]; then
    prd_json_candidates+=("$live_prd_json")
  fi
  # Archived per-epic prd.json is the safest fallback for non-active legacy epics.
  if archived_prd_json="$(choose_archived_prd_json_for_epic "$epic_id" 2>/dev/null || true)" && [ -n "$archived_prd_json" ]; then
    prd_json_candidates+=("$archived_prd_json")
  fi

  for prd_json_path in "${prd_json_candidates[@]:-}"; do
    [ -f "$prd_json_path" ] || continue
    branch_check="$(jq -r '.branchName // empty' "$prd_json_path")"
    [ -n "$branch_check" ] || continue
    STORY_BRANCH="$branch_check"

    story_count="$(jq '.userStories | length' "$prd_json_path")"

    for j in $(seq 0 $((story_count - 1))); do
      us="$(jq ".userStories[$j]" "$prd_json_path")"
      us_id="$(echo "$us" | jq -r '.id')"
      us_title="$(echo "$us" | jq -r '.title')"
      us_desc="$(echo "$us" | jq -r '.description // ""')"
      us_scope="$(echo "$us" | jq -r '.scopePaths // []')"
      us_ac="$(echo "$us" | jq -r '.acceptanceCriteria // []')"
      us_passes="$(echo "$us" | jq -r '.passes // false')"
      us_notes="$(echo "$us" | jq -r '.notes // ""')"

      task_id="$(remap_task_id "$us_id")"

      # Build context from description + acceptance criteria
      ac_text="$(echo "$us_ac" | jq -r '.[]' | awk '{print "- "$0}')"
      task_context="$us_desc"
      [ -n "$ac_text" ] && task_context="$task_context

Acceptance:
$ac_text"

      # Build acceptance (human-readable summary from AC)
      ac_summary="$(echo "$us_ac" | jq -r 'join(". ")')"

      # Infer checks
      task_checks="$(infer_checks "$(echo "$us_ac" | jq -r '. | @json')")"

      # Task status from passes field
      task_status="pending"
      [ "$us_passes" = "true" ] && task_status="done"

      task_obj="$(jq -n \
        --arg id "$task_id" \
        --arg title "$us_title" \
        --arg context "$task_context" \
        --argjson scope "$us_scope" \
        --arg acceptance "$ac_summary" \
        --argjson checks "$task_checks" \
        --arg status "$task_status" \
        --argjson passes "$us_passes" \
        '{
          "id": $id,
          "title": $title,
          "context": $context,
          "scope": $scope,
          "acceptance": $acceptance,
          "checks": $checks,
          "depends_on": [],
          "status": $status,
          "passes": $passes
        }')"

      TASKS_JSON="$(echo "$TASKS_JSON" | jq --argjson t "$task_obj" '. + [$t]')"
    done
    if [ "$(echo "$TASKS_JSON" | jq 'length')" -gt 0 ]; then
      TASKS_RECOVERED="true"
    fi
    STORY_SCOPE="$(jq -r '.description // ""' "$prd_json_path")"
    break
  done

  effective_story_status="$(effective_story_status_for_migration "$epic_status" "$TASKS_RECOVERED")"

  if [ "$TASKS_RECOVERED" != "true" ]; then
    placeholder_task_status="pending"
    placeholder_task_passes="false"
    case "$epic_status" in
      done|abandoned)
        placeholder_task_status="done"
        placeholder_task_passes="true"
        ;;
    esac
    migration_context="Legacy migration could not recover task-level data for $story_id."
    if [ -n "$PRD_MD_REF" ]; then
      migration_context="$migration_context

Source PRD markdown:
- $PRD_MD_REF

Regenerate the story plan with:
- ./scripts/ralph/ralph-story.sh generate $story_id --force"
    else
      migration_context="$migration_context

No matching legacy prd.json or PRD markdown source was found.
Reconstruct this story manually before execution."
    fi
    placeholder_check='test -n "legacy-migration-placeholder"'
    TASKS_JSON="$(jq -n \
      --arg id "T-01" \
      --arg title "Recover legacy story plan" \
      --arg context "$migration_context" \
      --arg acceptance "Legacy task data could not be recovered automatically; regenerate or reconstruct before execution." \
      --arg check "$placeholder_check" \
      --arg status "$placeholder_task_status" \
      --argjson passes "$placeholder_task_passes" \
      '[
        {
          "id": $id,
          "title": $title,
          "context": $context,
          "scope": [],
          "acceptance": $acceptance,
          "checks": [$check],
          "depends_on": [],
          "status": $status,
          "passes": $passes
        }
      ]')"
    STORY_VERIFICATION="$(jq -n --arg note "Migration placeholder only; regenerate story plan before running this story." '[$note]')"
    RECOVERY_PENDING+=("$story_id")
  fi

  # Build stories.json entry after migration status is finalized
  story_entry="$(jq -n \
    --arg id "$story_id" \
    --arg title "$epic_title" \
    --argjson priority "$epic_priority" \
    --argjson effort "$epic_effort" \
    --arg ps "$epic_planning_source" \
    --arg status "$effective_story_status" \
    --argjson depends "$deps_json" \
    --arg path "$story_path_rel" \
    --arg goal "$epic_goal" \
    --arg ctx "$epic_prompt_context" \
    '{
      "id": $id,
      "title": $title,
      "priority": $priority,
      "effort": $effort,
      "planningSource": $ps,
      "status": $status,
      "depends_on": $depends,
      "story_path": $path,
      "goal": $goal,
      "promptContext": $ctx
    }')"

  STORIES_ENTRIES="$(echo "$STORIES_ENTRIES" | jq --argjson entry "$story_entry" '. + [$entry]')"

  # Fall back to goal as scope if no PRD parsed
  [ -z "$STORY_SCOPE" ] && STORY_SCOPE="$epic_goal"
  [ -z "$STORY_BRANCH" ] && STORY_BRANCH="ralph/$TARGET_SPRINT/$(epic_branch_suffix "$epic_id")"

  story_json="$(jq -n \
    --arg version "1" \
    --arg project "$SPRINT_PROJECT" \
    --arg storyId "$story_id" \
    --arg title "$epic_title" \
    --arg description "$epic_goal" \
    --arg branchName "$STORY_BRANCH" \
    --arg sprint "$TARGET_SPRINT" \
    --argjson priority "$epic_priority" \
    --argjson depends "$deps_json" \
    --arg status "$effective_story_status" \
    --arg scope "$STORY_SCOPE" \
    --argjson outOfScope "$STORY_OUT_OF_SCOPE" \
    --argjson firstSlice "$STORY_FIRST_SLICE" \
    --argjson invariants "$STORY_INVARIANTS" \
    --argjson supporting "$STORY_SUPPORTING" \
    --argjson verification "$STORY_VERIFICATION" \
    --arg prdRef "$PRD_MD_REF" \
    --argjson tasks "$TASKS_JSON" \
    --argjson tasksRecovered "$(if [ "$TASKS_RECOVERED" = "true" ]; then echo true; else echo false; fi)" \
    '{
      "version": 1,
      "project": $project,
      "storyId": $storyId,
      "title": $title,
      "description": $description,
      "branchName": $branchName,
      "sprint": $sprint,
      "priority": $priority,
      "depends_on": $depends,
      "status": $status,
      "spec": {
        "scope": $scope,
        "out_of_scope": $outOfScope,
        "first_slice": $firstSlice,
        "preserved_invariants": $invariants,
        "supporting_files": $supporting,
        "verification": $verification,
        "prdRef": $prdRef
      },
      "migration": {
        "source": "legacy-epic",
        "tasks_recovered": $tasksRecovered
      },
      "tasks": $tasks,
      "passes": false
    }')"

  if dry; then
    story_dir_abs="$(dirname "$story_path_abs")"
    if [ "$DRY_RUN" -eq 0 ]; then
      mkdir -p "$story_dir_abs"
      echo "$story_json" > "$story_path_abs"
    fi
    MIGRATED=$((MIGRATED + 1))
    log "    Wrote: $story_path_rel"
    if [ "$TASKS_RECOVERED" = "true" ]; then
      log "    Tasks: $(echo "$TASKS_JSON" | jq 'length') tasks recovered from legacy PRD data"
    else
      log "    Tasks: placeholder story created; task-level data was not recoverable"
    fi
  else
    log "    [DRY RUN] Would write: $story_path_rel"
    if [ "$TASKS_RECOVERED" = "true" ]; then
      log "    [DRY RUN] Tasks: $(echo "$TASKS_JSON" | jq 'length') tasks recoverable from legacy PRD data"
    else
      log "    [DRY RUN] Tasks: placeholder story would be created; task-level data not recoverable"
    fi
    log "    Story JSON preview:"
    echo "$story_json" | jq '.'
  fi
done

# ---------------------------------------------------------------------------
# Write stories.json
# ---------------------------------------------------------------------------

ACTIVE_EPIC_ID="$(jq -r '.activeEpicId // empty' "$EPICS_FILE")"
ACTIVE_STORY_ID=""
[ -n "$ACTIVE_EPIC_ID" ] && ACTIVE_STORY_ID="$(remap_id "$ACTIVE_EPIC_ID")"
if [ -n "$ACTIVE_STORY_ID" ]; then
  active_story_status="$(echo "$STORIES_ENTRIES" | jq -r --arg id "$ACTIVE_STORY_ID" '.[] | select(.id == $id) | .status // empty')"
  case "$active_story_status" in
    blocked|done|abandoned|"")
      ACTIVE_STORY_ID=""
      ;;
  esac
fi
SPRINT_STATUS="planned"
if [ -n "$ACTIVE_EPIC_ID" ] || jq -e '[.epics[]? | select(.status == "active")] | length > 0' "$EPICS_FILE" >/dev/null 2>&1; then
  SPRINT_STATUS="active"
fi

stories_json="$(jq -n \
  --argjson version 1 \
  --arg project "$SPRINT_PROJECT" \
  --arg sprint "$TARGET_SPRINT" \
  --arg status "$SPRINT_STATUS" \
  --argjson capacityTarget "$CAPACITY_TARGET" \
  --argjson capacityCeiling "$CAPACITY_CEILING" \
  --arg activeStoryId "${ACTIVE_STORY_ID:-null}" \
  --argjson stories "$STORIES_ENTRIES" \
  '{
    "version": $version,
    "project": $project,
    "sprint": $sprint,
    "status": $status,
    "capacityTarget": $capacityTarget,
    "capacityCeiling": $capacityCeiling,
    "activeStoryId": (if $activeStoryId == "null" then null else $activeStoryId end),
    "stories": $stories
  }')"

if [ "$DRY_RUN" -eq 0 ]; then
  echo "$stories_json" > "$STORIES_FILE"
  log ""
  log "Wrote: $STORIES_FILE"
else
  log ""
  log "[DRY RUN] stories.json preview:"
  echo "$stories_json" | jq '.'
fi

if [ "$DRY_RUN" -eq 0 ] && [ "${#RECOVERY_PENDING[@]}" -gt 0 ]; then
  log ""
  log "Auto-recovering ${#RECOVERY_PENDING[@]} migrated placeholder stor$( [ "${#RECOVERY_PENDING[@]}" -eq 1 ] && printf 'y' || printf 'ies' )..."
  for story_id in "${RECOVERY_PENDING[@]}"; do
    log "  Recovering $story_id..."
    if "$SCRIPT_DIR/ralph-story.sh" generate "$story_id" --force; then
      AUTO_RECOVERED=$((AUTO_RECOVERED + 1))
    else
      fail "Automatic recovery failed for $story_id. Resolve the preserved legacy source and rerun migration with --force."
    fi
  done
fi

log ""
log "=== Migration complete ==="
log "  Migrated: $MIGRATED stories"
log "  Skipped:  $SKIPPED (already had story.json)"
log "  Recovered automatically: $AUTO_RECOVERED"
log ""
log "Next steps:"
log "  ./ralph-story.sh list"
log "  ./ralph-story.sh tasks S-001"
log "  ./ralph-task.sh"
