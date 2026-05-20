#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
source "$SCRIPT_DIR/lib/codex-exec.sh"
ROADMAP_JSON="$SCRIPT_DIR/roadmap.json"
ROADMAP_MD="$SCRIPT_DIR/roadmap.md"
ROADMAP_SOURCE="$SCRIPT_DIR/roadmap-source.md"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EDITOR_HELPER="$SCRIPT_DIR/lib/editor-intake.sh"
SPRINT_CLI="$SCRIPT_DIR/ralph-sprint.sh"

# shellcheck source=./lib/editor-intake.sh
source "$EDITOR_HELPER"

VISION=""
CONSTRAINTS=""
SPRINT_COUNT=3
CAPACITY_TARGET=8
CAPACITY_CEILING=10
QUIET=0
APPLY_ONLY=0
REFINE_MODE=0
REVISION_NOTE=""
ROADMAP_WORK_DIR=""
ROADMAP_JSON_WORK=""
ROADMAP_MD_WORK=""
ROADMAP_SOURCE_WORK=""
ROADMAP_REVISION_ID=""

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-roadmap.sh [options]

Create or refine a durable roadmap plan and seed sprint/story backlogs.

Options:
  --vision TEXT             Roadmap vision / future-state description
  --constraints TEXT        Optional planning constraints
  --refine                  Refine an existing roadmap/source instead of creating the first plan
  --revision-note TEXT      Why the roadmap changed; recorded in roadmap-source.md
  --sprints N               Number of roadmap sprints to plan (default: 3)
  --capacity-target N       Sprint effort target (default: 8)
  --capacity-ceiling N      Sprint effort ceiling (default: 10)
  --apply-only              Apply existing scripts/ralph/roadmap.json without re-planning
  --quiet                   Reduce wrapper output
  -h, --help                Show help

Notes:
  - Each story effort must be one of: 1, 2, 3, 5
  - Roadmap planning keeps stories sprint-safe; oversized work should roll into later sprints
  - Refinement is additive by default: prefer updating open/future work and adding follow-up stories or sprints over churning completed work
EOF
}

log() {
  if [ "$QUIET" -ne 1 ]; then
    printf '%s\n' "$*"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

get_story_planning_source_from_backlog() {
  local stories_file="$1"
  local story_id="$2"
  jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | (.planningSource // "legacy")' "$stories_file"
}

get_story_status_from_backlog() {
  local stories_file="$1"
  local story_id="$2"
  jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | (.status // "planned")' "$stories_file"
}

story_exists_in_backlog() {
  local stories_file="$1"
  local story_id="$2"
  jq -e --arg id "$story_id" '.stories[] | select(.id == $id)' "$stories_file" >/dev/null 2>&1
}

setup_work_paths() {
  if [ -n "$ROADMAP_WORK_DIR" ] && [ -d "$ROADMAP_WORK_DIR" ]; then
    return 0
  fi
  ROADMAP_WORK_DIR="$(mktemp -d)"
  ROADMAP_JSON_WORK="$ROADMAP_WORK_DIR/roadmap.json"
  ROADMAP_MD_WORK="$ROADMAP_WORK_DIR/roadmap.md"
  ROADMAP_SOURCE_WORK="$ROADMAP_WORK_DIR/roadmap-source.md"
  trap 'rm -rf "$ROADMAP_WORK_DIR" >/dev/null 2>&1 || true' EXIT
}


ensure_clean_worktree() {
  git diff --quiet || fail "Working tree has unstaged changes. Commit or stash them before roadmap planning."
  git diff --cached --quiet || fail "Working tree has staged changes. Commit or stash them before roadmap planning."
}

collect_editor_intake() {
  local intake_file intake_block
  local vision_prefill constraints_prefill note_prefill
  vision_prefill="${VISION:-${CURRENT_SOURCE_VISION:-}}"
  constraints_prefill="${CONSTRAINTS:-${CURRENT_SOURCE_CONSTRAINTS:-}}"
  note_prefill="${REVISION_NOTE:-}"
  intake_file="$(mktemp)"
  cat > "$intake_file" <<EOF
# Ralph Roadmap Intake
#
# Fill in the section below, save, and close your editor.

<!-- BEGIN INPUT -->
VISION:
$vision_prefill

CONSTRAINTS:
$constraints_prefill

REVISION_NOTE:
$note_prefill

<!-- END INPUT -->
EOF
  run_editor_on_file "$intake_file"
  intake_block="$(extract_marked_block "$intake_file" "<!-- BEGIN INPUT -->" "<!-- END INPUT -->")"
  rm -f "$intake_file"

  VISION="$(printf '%s\n' "$intake_block" | awk '
    /^VISION:/ { sub(/^VISION:[[:space:]]*/, ""); in_vision=1; in_constraints=0; print; next }
    /^CONSTRAINTS:/ { in_constraints=1; in_vision=0; next }
    in_vision { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
  CONSTRAINTS="$(printf '%s\n' "$intake_block" | awk '
    /^CONSTRAINTS:/ { sub(/^CONSTRAINTS:[[:space:]]*/, ""); in_constraints=1; print; next }
    /^REVISION_NOTE:/ { in_constraints=0; next }
    in_constraints { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
  REVISION_NOTE="$(printf '%s\n' "$intake_block" | awk '
    /^REVISION_NOTE:/ { sub(/^REVISION_NOTE:[[:space:]]*/, ""); in_note=1; print; next }
    in_note { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
}

read_current_roadmap_source() {
  CURRENT_SOURCE_VISION=""
  CURRENT_SOURCE_CONSTRAINTS=""
  [ -f "$ROADMAP_SOURCE" ] || return 0

  CURRENT_SOURCE_VISION="$(printf '%s\n' "$(
    extract_marked_block "$ROADMAP_SOURCE" "<!-- BEGIN CURRENT -->" "<!-- END CURRENT -->" \
      | awk '
          /^VISION:/ { sub(/^VISION:[[:space:]]*/, ""); in_vision=1; in_constraints=0; in_note=0; print; next }
          /^CONSTRAINTS:/ { in_constraints=1; in_vision=0; in_note=0; next }
          /^REVISION_NOTE:/ { in_note=1; in_vision=0; in_constraints=0; next }
          in_vision { print }
        '
  )" | sed '/^[[:space:]]*$/N;/^\n$/D')"
  CURRENT_SOURCE_CONSTRAINTS="$(printf '%s\n' "$(
    extract_marked_block "$ROADMAP_SOURCE" "<!-- BEGIN CURRENT -->" "<!-- END CURRENT -->" \
      | awk '
          /^CONSTRAINTS:/ { sub(/^CONSTRAINTS:[[:space:]]*/, ""); in_constraints=1; in_vision=0; in_note=0; print; next }
          /^REVISION_NOTE:/ { in_note=1; in_vision=0; in_constraints=0; next }
          in_constraints { print }
        '
  )" | sed '/^[[:space:]]*$/N;/^\n$/D')"
}

write_roadmap_source() {
  local ts history existing_history note
  ts="$ROADMAP_REVISION_ID"
  note="${REVISION_NOTE:-Initial roadmap creation.}"
  existing_history=""
  if [ -f "$ROADMAP_SOURCE" ]; then
    existing_history="$(awk 'found {print} /^## Revision History$/ {found=1; next}' "$ROADMAP_SOURCE")"
  fi

  {
    printf '# Ralph Roadmap Source\n\n'
    printf 'This is the durable roadmap input. Refine it when the target state changes; downstream sprint and story plans should reconcile from here.\n\n'
    printf '<!-- BEGIN CURRENT -->\n'
    printf 'VISION:\n%s\n\n' "$VISION"
    printf 'CONSTRAINTS:\n%s\n\n' "${CONSTRAINTS:-Not provided.}"
    printf 'REVISION_NOTE:\n%s\n' "$note"
    printf '<!-- END CURRENT -->\n\n'
    printf '## Revision Policy\n\n'
    printf -- '- Update open and future work directly.\n'
    printf -- '- Treat closed sprints as stable by default.\n'
    printf -- '- Only reopen closed sprints for tightly scoped, low-churn additions.\n'
    printf -- '- Otherwise inject new stories or new sprints for the refinement.\n\n'
    printf '## Revision History\n'
    if [ -n "$existing_history" ]; then
      printf '%s\n' "$existing_history"
    fi
    printf -- '- %s | %s\n' "$ts" "$note"
  } > "$ROADMAP_SOURCE_WORK"
}

plan_roadmap_json() {
  local prompt
  local source_hint refine_hint current_plan_hint backlog_hint
  source_hint="Create the first roadmap plan from the durable source inputs."
  refine_hint=""
  current_plan_hint=""
  backlog_hint=""

  if [ "$REFINE_MODE" -eq 1 ]; then
    source_hint="This is a roadmap refinement. Update the roadmap while preserving traceability to the current source and backlog."
    refine_hint=$(
      cat <<EOF
- Source file: \`scripts/ralph/roadmap-source.md\`
- Current roadmap file: \`scripts/ralph/roadmap.json\`
- Revision note: ${REVISION_NOTE:-none}
EOF
    )
    if [ -f "$ROADMAP_JSON" ]; then
      current_plan_hint="- Current roadmap JSON already exists at \`scripts/ralph/roadmap.json\`."
    fi
    backlog_hint="- Existing sprint backlogs may already contain active or completed stories. Prefer additive updates over churn."
  fi

  mkdir -p "$SCRIPT_DIR"

  prompt=$(
    cat <<EOF
Use the \`prd\` skill.

Create a roadmap plan and write valid JSON to \`$ROADMAP_JSON_WORK\`.

Inputs:
- Project: \`$(basename "$WORKSPACE_ROOT")\`
- Vision: $VISION
- Constraints: ${CONSTRAINTS:-none}
- Source policy: $source_hint
$refine_hint
$current_plan_hint
$backlog_hint
- Sprint count: $SPRINT_COUNT
- Sprint effort target: $CAPACITY_TARGET
- Sprint effort ceiling: $CAPACITY_CEILING

Requirements:
1. Output JSON with keys: project, visionSummary, constraintsSummary, capacityTarget, capacityCeiling, sprints.
2. Create exactly $SPRINT_COUNT sprints. Name each sprint with a short descriptive kebab-case feature slug prefixed with "sprint-" (e.g. sprint-user-auth, sprint-data-model, sprint-api-layer). Names must match ^sprint-[a-z0-9-]+$.
3. Each sprint object must contain: name, title, goal, capacityTarget, capacityCeiling, stories. The "title" is a short human-readable label (e.g. "User Authentication"); "goal" is a one-sentence description of the sprint objective.
4. Each story must contain: id, title, priority, effort, dependsOn, goal, promptContext.
5. Story IDs must use the format S-NNN (e.g., S-001, S-002), unique across all sprints.
6. Story effort must be one of: 1, 2, 3, 5.
7. Keep each sprint at or under the capacity ceiling; if more work exists, roll overflow into later sprints.
8. If any story would be too large to deliver in a single focused Codex session, split it now.
9. Use \`dependsOn\` only for dependencies inside the same sprint. Express cross-sprint sequencing by sprint order, not cross-sprint dependency links.
10. Write execution-oriented \`promptContext\` that is specific enough for later task generation.
11. Treat closed/completed sprints as stable by default. Only place new work into a closed sprint when it is tightly scoped and likely lower churn than adding a follow-up story or sprint.
12. Prefer additive follow-up stories or new sprints over reopening completed work when the refinement would otherwise cause broad refactor churn.
13. Preserve stable story IDs for unchanged work when refining; use new IDs for genuinely new follow-up work.
14. Do not create runtime files or PRD JSON. This is planning only.

Return only a short summary after writing the file.
EOF
  )

  codex_exec_prompt "$prompt" "$WORKSPACE_ROOT"
}

validate_roadmap_json() {
  [ -f "$ROADMAP_JSON_WORK" ] || fail "Roadmap JSON was not created: $ROADMAP_JSON_WORK"
  jq -e \
    --argjson sprintCount "$SPRINT_COUNT" \
    --argjson target "$CAPACITY_TARGET" \
    --argjson ceiling "$CAPACITY_CEILING" '
    .project and
    .visionSummary and
    .capacityTarget == $target and
    .capacityCeiling == $ceiling and
    (.sprints | type == "array") and
    (.sprints | length == $sprintCount) and
    all(.sprints[];
      .name and (.name | test("^sprint-[a-z0-9-]+$")) and
      .title and .goal and
      .capacityTarget == $target and
      .capacityCeiling == $ceiling and
      (.stories | type == "array") and
      ([.stories[]?.effort] | all(. == 1 or . == 2 or . == 3 or . == 5))
    )
  ' "$ROADMAP_JSON_WORK" >/dev/null 2>&1 || fail "Invalid roadmap JSON structure: $ROADMAP_JSON_WORK"

  jq -e '
    [ .sprints[].stories[].id ] as $ids
    | ($ids | unique | length) == ($ids | length)
  ' "$ROADMAP_JSON_WORK" >/dev/null 2>&1 || fail "Roadmap JSON contains duplicate story IDs."

  jq -e '
    .sprints
    | all(.[]; ([.stories[]?.effort] | add // 0) <= .capacityCeiling)
  ' "$ROADMAP_JSON_WORK" >/dev/null 2>&1 || fail "Roadmap JSON exceeds sprint capacity ceiling."
  validate_sprint_local_dependencies
}

validate_sprint_local_dependencies() {
  local sprint local_ids story_id dep_id
  while IFS= read -r sprint; do
    [ -n "$sprint" ] || continue
    local_ids="$(jq -r --arg sprint "$sprint" '.sprints[] | select(.name == $sprint) | .stories[]?.id' "$ROADMAP_JSON_WORK")"
    while IFS=$'\t' read -r story_id dep_id; do
      [ -n "$story_id" ] || continue
      [ -n "$dep_id" ] || continue
      if ! printf '%s\n' "$local_ids" | grep -qx "$dep_id"; then
        fail "Roadmap JSON contains cross-sprint or missing dependency: $story_id -> $dep_id"
      fi
    done < <(jq -r --arg sprint "$sprint" '
      .sprints[]
      | select(.name == $sprint)
      | .stories[]
      | .id as $id
      | (.dependsOn // [])[]
      | [$id, .] | @tsv
    ' "$ROADMAP_JSON_WORK")
  done < <(jq -r '.sprints[].name' "$ROADMAP_JSON_WORK")
}

render_roadmap_markdown() {
  jq -r '
    "# Ralph Roadmap\n\n" +
    "## Vision\n\n" + .visionSummary + "\n\n" +
    "## Constraints\n\n" + (.constraintsSummary // "None provided.") + "\n\n" +
    "Source of truth: `scripts/ralph/roadmap-source.md`\n\n" +
    "## Capacity Policy\n\n" +
    "- Sprint target effort: \(.capacityTarget)\n" +
    "- Sprint ceiling effort: \(.capacityCeiling)\n" +
    "- Story effort scale: 1, 2, 3, 5\n" +
    "- Cross-sprint sequencing is expressed by sprint order; \u0060dependsOn\u0060 is sprint-local only.\n\n" +
    (
      .sprints
      | map(
          "## " + .title + " (" + .name + ")\n\n" +
          "Goal: " + .goal + "\n\n" +
          "Planned effort: " + (([.stories[]?.effort] | add // 0) | tostring) + "/" + (.capacityCeiling | tostring) + "\n\n" +
          (
            .stories
            | sort_by(.priority, .id)
            | map(
                "- **" + .id + "** (P" + (.priority | tostring) + " E" + (.effort | tostring) + ") " + .title +
                if ((.dependsOn // []) | length) > 0 then " | depends on: " + ((.dependsOn // []) | join(", ")) else "" end
              )
            | join("\n")
          ) + "\n"
        )
      | join("\n")
    )
  ' "$ROADMAP_JSON_WORK" > "$ROADMAP_MD_WORK"
}

ensure_empty_sprint_backlog() {
  local sprint="$1"
  local stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  [ -f "$stories_file" ] || return 0
  if jq -e '(.stories | length) == 0' "$stories_file" >/dev/null 2>&1; then
    return 0
  fi
  if is_seed_example_backlog "$stories_file"; then
    reset_seed_example_backlog "$stories_file" "$sprint"
    return 0
  fi
  fail "Sprint backlog already has stories: $stories_file"
}

is_seed_example_backlog() {
  local stories_file="$1"
  jq -e '
    (.stories | length) == 2 and
    .stories[0].title == "Foundation Story" and
    .stories[1].title == "Follow-on Story"
  ' "$stories_file" >/dev/null 2>&1
}

reset_seed_example_backlog() {
  local stories_file="$1"
  local sprint="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg sprint "$sprint" --arg project "$(basename "$WORKSPACE_ROOT")" '
    .project = $project
    | .sprint = $sprint
    | .activeStoryId = null
    | .stories = []
  ' "$stories_file" > "$tmp_file"
  mv "$tmp_file" "$stories_file"
}

ensure_sprint_structure_local() {
  local sprint="$1"
  local stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  mkdir -p "$SCRIPT_DIR/sprints/$sprint/stories" "$SCRIPT_DIR/tasks/$sprint" "$SCRIPT_DIR/tasks/archive/$sprint"
  if [ ! -f "$stories_file" ]; then
    jq -n \
      --arg project "$(basename "$WORKSPACE_ROOT")" \
      --arg sprint "$sprint" \
      --argjson target "$CAPACITY_TARGET" \
      --argjson ceiling "$CAPACITY_CEILING" \
      '{
        "version": 1,
        "project": $project,
        "sprint": $sprint,
        "status": "planned",
        "capacityTarget": $target,
        "capacityCeiling": $ceiling,
        "activeStoryId": null,
        "stories": []
      }' > "$stories_file"
  fi
}

write_sprint_capacity_metadata() {
  local sprint="$1"
  local sprint_title="$2"
  local stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg sprint "$sprint" --arg title "$sprint_title" \
     --argjson target "$CAPACITY_TARGET" --argjson ceiling "$CAPACITY_CEILING" '
    .sprint = $sprint
    | .title = $title
    | .capacityTarget = $target
    | .capacityCeiling = $ceiling
  ' "$stories_file" > "$tmp_file"
  mv "$tmp_file" "$stories_file"
}

upsert_story_metadata() {
  local stories_file="$1"
  local story_json="$2"
  local story_id status planning_source tmp_file
  story_id="$(printf '%s\n' "$story_json" | jq -r '.id')"
  status="$(get_story_status_from_backlog "$stories_file" "$story_id")"
  planning_source="$(get_story_planning_source_from_backlog "$stories_file" "$story_id")"

  case "$status" in
    done|abandoned|active)
      return 0
      ;;
  esac
  if [ "$planning_source" = "local" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  jq --argjson story "$story_json" --arg sourceRef "$ROADMAP_REVISION_ID" '
    .stories = (
      .stories
      | map(
          if .id == $story.id then
            .title = $story.title
            | .priority = $story.priority
            | .effort = $story.effort
            | .planningSource = "roadmap"
            | .sourceRef = $sourceRef
            | .depends_on = ($story.dependsOn // [])
            | .goal = $story.goal
            | .promptContext = $story.promptContext
          else
            .
          end
        )
    )
  ' "$stories_file" > "$tmp_file"
  mv "$tmp_file" "$stories_file"
}

reconcile_sprint_backlog() {
  local sprint_name="$1"
  local stories_file="$SCRIPT_DIR/sprints/$sprint_name/stories.json"
  local story_json story_id depends_json story_path tmp_file

  while IFS= read -r story_json; do
    [ -n "$story_json" ] || continue
    story_id="$(printf '%s\n' "$story_json" | jq -r '.id')"

    if story_exists_in_backlog "$stories_file" "$story_id"; then
      upsert_story_metadata "$stories_file" "$story_json"
    else
      depends_json="$(printf '%s\n' "$story_json" | jq -c '(.dependsOn // [])')"
      story_path="${SCRIPT_DIR#${WORKSPACE_ROOT}/}/sprints/$sprint_name/stories/$story_id/story.json"
      tmp_file="$(mktemp)"
      jq \
        --argjson story "$story_json" \
        --argjson depends "$depends_json" \
        --arg path "$story_path" \
        --arg sourceRef "$ROADMAP_REVISION_ID" \
        '.stories += [{
          "id": $story.id,
          "title": $story.title,
          "priority": $story.priority,
          "effort": $story.effort,
          "planningSource": "roadmap",
          "sourceRef": $sourceRef,
          "status": "planned",
          "depends_on": $depends,
          "story_path": $path,
          "goal": $story.goal,
          "promptContext": $story.promptContext
        }]' \
        "$stories_file" > "$tmp_file"
      mv "$tmp_file" "$stories_file"
    fi
  done < <(jq -c --arg sprint "$sprint_name" '.sprints[] | select(.name == $sprint) | .stories[]' "$ROADMAP_JSON_WORK")
}

apply_roadmap_to_sprints() {
  local first_sprint=""
  local sprint_count sprint_name sprint_goal

  sprint_count="$(jq '.sprints | length' "$ROADMAP_JSON_WORK")"
  [ "$sprint_count" -gt 0 ] || fail "Roadmap has no sprints to apply."

  while IFS=$'\t' read -r sprint_name sprint_title; do
    [ -n "$sprint_name" ] || continue
    if [ -z "$first_sprint" ]; then
      first_sprint="$sprint_name"
    fi

    ensure_sprint_structure_local "$sprint_name"
    if [ -f "$SCRIPT_DIR/sprints/$sprint_name/stories.json" ]; then
      if [ "$REFINE_MODE" -eq 1 ]; then
        if is_seed_example_backlog "$SCRIPT_DIR/sprints/$sprint_name/stories.json"; then
          reset_seed_example_backlog "$SCRIPT_DIR/sprints/$sprint_name/stories.json" "$sprint_name"
        fi
      else
        ensure_empty_sprint_backlog "$sprint_name"
      fi
    fi
    write_sprint_capacity_metadata "$sprint_name" "$sprint_title"
    reconcile_sprint_backlog "$sprint_name"
  done < <(jq -r '.sprints[] | [.name, .title] | @tsv' "$ROADMAP_JSON_WORK")

  if [ -n "$first_sprint" ]; then
    log "Roadmap applied. Next steps for $first_sprint:"
    log "  ./ralph-story.sh prepare-all --jobs 2"
    log "  ./ralph-sprint.sh mark-ready $first_sprint"
    log "  ./ralph-sprint.sh use $first_sprint         (creates branch + activates)"
  fi
}

publish_roadmap_artifacts() {
  [ -f "$ROADMAP_JSON_WORK" ] && cp "$ROADMAP_JSON_WORK" "$ROADMAP_JSON"
  [ -f "$ROADMAP_MD_WORK" ] && cp "$ROADMAP_MD_WORK" "$ROADMAP_MD"
  [ -f "$ROADMAP_SOURCE_WORK" ] && cp "$ROADMAP_SOURCE_WORK" "$ROADMAP_SOURCE"
}

commit_roadmap_artifacts_if_needed() {
  local status_lines
  status_lines="$(git status --porcelain -- "$ROADMAP_JSON" "$ROADMAP_MD" "$ROADMAP_SOURCE" "$SCRIPT_DIR/sprints" || true)"
  [ -n "$status_lines" ] || return 0

  git add -- "$ROADMAP_JSON" "$ROADMAP_MD" "$ROADMAP_SOURCE" "$SCRIPT_DIR/sprints"
  if git diff --cached --quiet; then
    return 0
  fi

  if [ "$REFINE_MODE" -eq 1 ]; then
    git commit -m "chore(ralph): refine roadmap plan" >/dev/null
  else
    git commit -m "chore(ralph): add roadmap plan" >/dev/null
  fi
  log "Committed roadmap plan artifacts."
}

main() {
  require_cmd jq
  require_cmd git
  require_cmd "$CODEX_BIN"

  while [ $# -gt 0 ]; do
    case "$1" in
      --vision)
        VISION="${2:-}"
        shift 2
        ;;
      --constraints)
        CONSTRAINTS="${2:-}"
        shift 2
        ;;
      --refine)
        REFINE_MODE=1
        shift
        ;;
      --revision-note)
        REVISION_NOTE="${2:-}"
        shift 2
        ;;
      --sprints)
        SPRINT_COUNT="${2:-}"
        shift 2
        ;;
      --capacity-target)
        CAPACITY_TARGET="${2:-}"
        shift 2
        ;;
      --capacity-ceiling)
        CAPACITY_CEILING="${2:-}"
        shift 2
        ;;
      --apply-only)
        APPLY_ONLY=1
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
        fail "Unknown option: $1"
        ;;
    esac
  done

  [[ "$SPRINT_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "--sprints must be a positive integer."
  [[ "$CAPACITY_TARGET" =~ ^[1-9][0-9]*$ ]] || fail "--capacity-target must be a positive integer."
  [[ "$CAPACITY_CEILING" =~ ^[1-9][0-9]*$ ]] || fail "--capacity-ceiling must be a positive integer."
  [ "$CAPACITY_TARGET" -le "$CAPACITY_CEILING" ] || fail "--capacity-target must be less than or equal to --capacity-ceiling."
  ROADMAP_REVISION_ID="$(date -Iseconds)"

  ensure_clean_worktree
  read_current_roadmap_source
  setup_work_paths

  if [ "$APPLY_ONLY" -ne 1 ]; then
    if [ -z "$VISION" ]; then
      if [ -t 0 ] || [ -t 1 ]; then
        collect_editor_intake
      fi
    fi
    if [ -z "$VISION" ] && [ "$REFINE_MODE" -eq 1 ] && [ -n "${CURRENT_SOURCE_VISION:-}" ]; then
      VISION="$CURRENT_SOURCE_VISION"
    fi
    if [ -z "$CONSTRAINTS" ] && [ "$REFINE_MODE" -eq 1 ] && [ -n "${CURRENT_SOURCE_CONSTRAINTS:-}" ]; then
      CONSTRAINTS="$CURRENT_SOURCE_CONSTRAINTS"
    fi
    [ -n "$VISION" ] || fail "Vision is required. Pass --vision or use interactive editor intake."
    if [ "$REFINE_MODE" -eq 1 ]; then
      [ -f "$ROADMAP_SOURCE" ] || fail "Cannot refine without existing roadmap source: scripts/ralph/roadmap-source.md"
      [ -f "$ROADMAP_JSON" ] || fail "Cannot refine without existing roadmap plan: scripts/ralph/roadmap.json"
    fi
    write_roadmap_source
    plan_roadmap_json
  else
    [ -f "$ROADMAP_JSON" ] || fail "Missing roadmap JSON for --apply-only: $ROADMAP_JSON"
    cp "$ROADMAP_JSON" "$ROADMAP_JSON_WORK"
    [ -f "$ROADMAP_MD" ] && cp "$ROADMAP_MD" "$ROADMAP_MD_WORK"
    [ -f "$ROADMAP_SOURCE" ] && cp "$ROADMAP_SOURCE" "$ROADMAP_SOURCE_WORK"
  fi

  validate_roadmap_json
  render_roadmap_markdown
  apply_roadmap_to_sprints
  publish_roadmap_artifacts
  commit_roadmap_artifacts_if_needed

  log "Roadmap plan ready:"
  log "- Source: scripts/ralph/roadmap-source.md"
  log "- JSON: scripts/ralph/roadmap.json"
  log "- Markdown: scripts/ralph/roadmap.md"
}

main "$@"
