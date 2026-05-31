#!/bin/bash
# ralph-story.sh — Story management for the story-task architecture.
#
# Stories replace epics as the sprint-level planning unit.
# Each story is a task container with its own story.json.
#
# Usage:
#   ./ralph-story.sh <command> [args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
STORIES_FILE="${RALPH_STORIES_FILE:-}"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
source "$SCRIPT_DIR/lib/codex-exec.sh"
source "$SCRIPT_DIR/lib/specify.sh"

fail() { echo "ERROR: $1" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_seconds() {
  date +%s
}

compact_text() {
  local value="${1:-}"
  local max_chars="${2:-280}"
  printf '%s' "$value" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' \
    | awk -v limit="$max_chars" '{
        if (length($0) <= limit) {
          print $0
        } else {
          print substr($0, 1, limit - 3) "..."
        }
      }'
}

compact_list() {
  local value="${1:-}"
  local max_items="${2:-4}"
  [ -n "$value" ] || return 0
  printf '%s\n' "$value" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | awk -v limit="$max_items" '
        NR <= limit { items[NR] = $0 }
        END {
          for (i = 1; i <= NR && i <= limit; i++) {
            if (i > 1) printf ", "
            printf "%s", items[i]
          }
          if (NR > limit) printf ", ..."
          printf "\n"
        }
      '
}

prep_runtime_root() {
  printf '%s/runtime/prep-runs\n' "$SCRIPT_DIR"
}

latest_prep_summary_for_sprint() {
  local sprint="$1"
  local prep_root
  prep_root="$(prep_runtime_root)"
  [ -d "$prep_root" ] || return 1
  find "$prep_root" -type f -name 'prepare-run.json' -path "*-${sprint}-*/prepare-run.json" 2>/dev/null | sort | tail -n1
}

ensure_prep_run_dir() {
  local sprint="$1"
  local mode="${2:-prep}"
  if [ -n "${RALPH_PREP_RUN_DIR:-}" ]; then
    mkdir -p "$RALPH_PREP_RUN_DIR"
    printf '%s\n' "$RALPH_PREP_RUN_DIR"
    return 0
  fi

  local stamp run_dir
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  run_dir="$(prep_runtime_root)/${stamp}-${sprint}-${mode}"
  mkdir -p "$run_dir"
  cat > "$run_dir/prepare-run.json" <<EOF
{
  "version": 1,
  "mode": "$mode",
  "sprint": "$sprint",
  "started_at": "$(timestamp_utc)",
  "stories": {}
}
EOF
  RALPH_PREP_RUN_DIR="$run_dir"
  export RALPH_PREP_RUN_DIR
  printf '%s\n' "$run_dir"
}

prep_summary_path() {
  [ -n "${RALPH_PREP_RUN_DIR:-}" ] || return 1
  printf '%s/prepare-run.json\n' "$RALPH_PREP_RUN_DIR"
}

prep_stage_log_path() {
  local story_id="$1"
  local stage="$2"
  [ -n "${RALPH_PREP_RUN_DIR:-}" ] || return 1
  printf '%s/%s-%s.log\n' "$RALPH_PREP_RUN_DIR" "$story_id" "$stage"
}

prep_stage_status_path() {
  local story_id="$1"
  local stage="$2"
  [ -n "${RALPH_PREP_RUN_DIR:-}" ] || return 1
  printf '%s/stages/%s-%s.json\n' "$RALPH_PREP_RUN_DIR" "$story_id" "$stage"
}

prep_record_stage() {
  local story_id="$1"
  local stage="$2"
  local status="$3"
  local detail="${4:-}"
  local artifacts_json="${5:-[]}"
  local duration_ms="${6:-0}"
  local stage_path
  stage_path="$(prep_stage_status_path "$story_id" "$stage" 2>/dev/null || true)"
  [ -n "$stage_path" ] || return 0
  mkdir -p "$(dirname "$stage_path")"
  jq -n \
    --arg storyId "$story_id" \
    --arg stage "$stage" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg updated_at "$(timestamp_utc)" \
    --argjson artifacts "$artifacts_json" \
    --argjson duration_ms "$duration_ms" \
    '{
      storyId: $storyId,
      stage: $stage,
      status: $status,
      detail: $detail,
      artifacts: $artifacts,
      duration_ms: $duration_ms,
      updated_at: $updated_at
    }' > "$stage_path"
}

prep_finalize_summary() {
  local final_status="$1"
  local summary_path tmp stories_json metrics_json stage_dir
  summary_path="$(prep_summary_path 2>/dev/null || true)"
  [ -n "$summary_path" ] && [ -f "$summary_path" ] || return 0
  stage_dir="$RALPH_PREP_RUN_DIR/stages"
  if [ -d "$stage_dir" ]; then
    stories_json="$(
      find "$stage_dir" -type f -name '*.json' -print \
        | sort \
        | while IFS= read -r stage_file; do
            jq -c '.' "$stage_file"
          done \
        | jq -sc '
            reduce .[] as $entry ({};
              .[$entry.storyId] = ((.[$entry.storyId] // {}) + {
                ($entry.stage): {
                  status: $entry.status,
                  detail: $entry.detail,
                  artifacts: $entry.artifacts,
                  duration_ms: ($entry.duration_ms // 0),
                  updated_at: $entry.updated_at
                }
              })
            )
          '
    )"
    metrics_json="$(
      find "$stage_dir" -type f -name '*.json' -print \
        | sort \
        | while IFS= read -r stage_file; do
            jq -c '.' "$stage_file"
          done \
        | jq -sc '
            {
              stage_count: length,
              passed_stages: map(select(.status == "passed")) | length,
              skipped_stages: map(select(.status == "skipped")) | length,
              failed_stages: map(select(.status == "failed")) | length,
              running_stages: map(select(.status == "running")) | length,
              total_duration_ms: (map(.duration_ms // 0) | add // 0)
            }
          '
    )"
  else
    stories_json='{}'
    metrics_json='{"stage_count":0,"passed_stages":0,"skipped_stages":0,"failed_stages":0,"running_stages":0,"total_duration_ms":0}'
  fi
  tmp="$(mktemp)"
  jq \
    --arg status "$final_status" \
    --arg finished_at "$(timestamp_utc)" \
    --argjson stories "$stories_json" \
    --argjson metrics "$metrics_json" \
    '.status = $status | .finished_at = $finished_at | .stories = $stories | .metrics = $metrics' \
    "$summary_path" > "$tmp"
  mv "$tmp" "$summary_path"
}

require_story_sprint() {
  local sprint_value="${1:-}"
  local story_id="${2:-story}"
  [ -n "$sprint_value" ] || fail "Story $story_id is missing sprint metadata in stories.json."
}

story_prep_context_path() {
  local story_dir="$1"
  printf '%s/.prep-context.json\n' "$story_dir"
}

story_prep_bundle_dir() {
  local story_dir="$1"
  printf '%s/.prep\n' "$story_dir"
}

story_prep_bundle_context_path() {
  local story_dir="$1"
  printf '%s/context.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_dependencies_path() {
  local story_dir="$1"
  printf '%s/dependencies.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_commands_path() {
  local story_dir="$1"
  printf '%s/commands.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_schema_path() {
  local story_dir="$1"
  printf '%s/schema.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

focus_hints_to_json() {
  local focus_hints="${1:-}"
  if [ -n "$focus_hints" ]; then
    printf '%s\n' "$focus_hints" | sed -n 's/^[[:space:]]*-[[:space:]]*`\(.*\)`$/\1/p' | jq -R . | jq -s .
  else
    printf '[]\n'
  fi
}

write_story_prep_bundle() {
  local story_dir="$1"
  local story_id="$2"
  local sprint="$3"
  local title="$4"
  local goal="$5"
  local prompt_context="$6"
  local repo_briefing_rel="$7"
  local command_map_json="$8"
  local depends_on_json="$9"
  local likely_files_json="${10:-[]}"
  local dependency_bundle_json="${11:-[]}"
  local fingerprint="${12:-}"
  local bundle_dir context_path dependencies_path commands_path schema_path

  bundle_dir="$(story_prep_bundle_dir "$story_dir")"
  context_path="$(story_prep_bundle_context_path "$story_dir")"
  dependencies_path="$(story_prep_bundle_dependencies_path "$story_dir")"
  commands_path="$(story_prep_bundle_commands_path "$story_dir")"
  schema_path="$(story_prep_bundle_schema_path "$story_dir")"
  mkdir -p "$bundle_dir"

  jq -n \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefing "$repo_briefing_rel" \
    --arg fingerprint "$fingerprint" \
    --arg generatedAt "$(timestamp_utc)" \
    --argjson dependsOn "$depends_on_json" \
    --argjson likelyFiles "$likely_files_json" \
    '{
      version: 1,
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefing: $repoBriefing,
      fingerprint: $fingerprint,
      dependsOn: $dependsOn,
      likelyFiles: $likelyFiles,
      generatedAt: $generatedAt
    }' > "$context_path"

  printf '%s\n' "$dependency_bundle_json" | jq '.' > "$dependencies_path"
  printf '%s\n' "$command_map_json" | jq '.' > "$commands_path"
  jq -n \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg exampleBranch "ralph/${sprint}/story-S-001" \
    '{
      version: 1,
      container: {
        requiredTopLevel: [
          "version",
          "project",
          "storyId",
          "title",
          "description",
          "branchName",
          "sprint",
          "priority",
          "depends_on",
          "status",
          "spec",
          "tasks",
          "passes"
        ],
        requiredSpecFields: [
          "scope",
          "out_of_scope",
          "first_slice",
          "preserved_invariants",
          "supporting_files",
          "verification"
        ],
        requiredTaskFields: [
          "id",
          "title",
          "context",
          "scope",
          "acceptance",
          "checks",
          "depends_on",
          "status",
          "passes"
        ],
        topLevelDefaults: {
          version: 1,
          sprint: $sprint,
          status: "planned",
          passes: false
        },
        taskDefaults: {
          status: "pending",
          passes: false
        },
        taskStatusValues: ["pending", "done", "failed", "blocked"],
        fieldRules: [
          "spec.scope is a concise string summary, not an array",
          "task scope arrays must contain repo-relative concrete file paths",
          "task acceptance is a single string summary, not an array",
          "checks must be binary shell commands",
          "depends_on must reference task ids within the same story",
          "do not add extra top-level sections outside the standard story container"
        ],
        example: {
          version: 1,
          project: "repo-name",
          storyId: "S-001",
          title: $title,
          description: "Backlog goal for the story.",
          branchName: $exampleBranch,
          sprint: $sprint,
          priority: 1,
          depends_on: [],
          status: "planned",
          spec: {
            scope: "Concise summary of the work for this story.",
            out_of_scope: [],
            first_slice: {},
            preserved_invariants: [],
            supporting_files: [],
            verification: ["npm run test"]
          },
          tasks: [
            {
              id: "T-01",
              title: "Implement the main slice",
              context: "Self-contained implementation instructions for a fresh Codex session.",
              scope: ["lib/example.ts", "__tests__/example.test.ts"],
              acceptance: "Implementation exists and the targeted verification passes.",
              checks: ["npm run test"],
              depends_on: [],
              status: "pending",
              passes: false
            }
          ],
          passes: false
        }
      }
    }' > "$schema_path"
}

write_story_prep_context() {
  local output_path="$1"
  local story_id="$2"
  local sprint="$3"
  local title="$4"
  local goal="$5"
  local prompt_context="$6"
  local repo_briefing_rel="$7"
  local command_map_json="$8"
  local depends_on_json="$9"
  local focus_hints="${10:-}"
  local dependency_context="${11:-}"
  local fingerprint="${12:-}"
  local dependency_bundle_json="${13:-[]}"

  local focus_json dependency_context_json existing_generation_json
  focus_json="$(focus_hints_to_json "$focus_hints")"
  dependency_context_json="$(printf '%s' "$dependency_context" | jq -Rs '.')"
  existing_generation_json='null'
  if [ -f "$output_path" ]; then
    existing_generation_json="$(jq -c --arg fingerprint "$fingerprint" '
      if (.fingerprint // "") == $fingerprint then
        (.generation // null)
      else
        null
      end
    ' "$output_path" 2>/dev/null || printf 'null')"
  fi
  mkdir -p "$(dirname "$output_path")"

  jq -n \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefing "$repo_briefing_rel" \
    --arg fingerprint "$fingerprint" \
    --arg generatedAt "$(timestamp_utc)" \
    --argjson commands "$command_map_json" \
    --argjson dependsOn "$depends_on_json" \
    --argjson likelyFiles "$focus_json" \
    --argjson dependencyContext "$dependency_context_json" \
    --argjson dependencyStories "$dependency_bundle_json" \
    --argjson generation "$existing_generation_json" \
    '{
      version: 1,
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefing: $repoBriefing,
      fingerprint: $fingerprint,
      commands: $commands,
      dependsOn: $dependsOn,
      likelyFiles: $likelyFiles,
      dependencyContext: $dependencyContext,
      dependencyStories: $dependencyStories
    }
    + (if $generation == null then {} else {generation: $generation} end)
    + {
      generatedAt: $generatedAt
    }' > "$output_path"
}

format_command_map_for_prompt() {
  local command_map_json="$1"
  printf '%s' "$command_map_json" | jq -r '
    [
      "- typecheck: " + (.typecheck // "unavailable"),
      "- lint: " + (.lint // "unavailable"),
      "- test: " + (.test // "unavailable"),
      "- build: " + (.build // "unavailable")
    ] | join("\n")
  '
}

read_story_prep_fingerprint() {
  local prep_context_path="$1"
  [ -f "$prep_context_path" ] || return 0
  jq -r '.fingerprint // empty' "$prep_context_path" 2>/dev/null || true
}

read_story_generate_fingerprint() {
  local prep_context_path="$1"
  [ -f "$prep_context_path" ] || return 0
  jq -r '.generation.generatedFromFingerprint // empty' "$prep_context_path" 2>/dev/null || true
}

write_story_generate_provenance() {
  local prep_context_path="$1"
  local source_fingerprint="$2"
  local source_type="${3:-generated}"
  local story_path="$4"
  local tmp

  mkdir -p "$(dirname "$prep_context_path")"
  if [ -f "$prep_context_path" ]; then
    tmp="$(mktemp)"
    jq \
      --arg fingerprint "$source_fingerprint" \
      --arg source_type "$source_type" \
      --arg story_path "$story_path" \
      --arg generated_at "$(timestamp_utc)" \
      '.generation = {
        generatedFromFingerprint: $fingerprint,
        sourceType: $source_type,
        storyPath: $story_path,
        generatedAt: $generated_at
      }' \
      "$prep_context_path" > "$tmp"
    mv "$tmp" "$prep_context_path"
    return 0
  fi

  jq -n \
    --arg fingerprint "$source_fingerprint" \
    --arg source_type "$source_type" \
    --arg story_path "$story_path" \
    --arg generated_at "$(timestamp_utc)" \
    '{
      version: 1,
      fingerprint: $fingerprint,
      generatedAt: $generated_at,
      generation: {
        generatedFromFingerprint: $fingerprint,
        sourceType: $source_type,
        storyPath: $story_path,
        generatedAt: $generated_at
      }
    }' > "$prep_context_path"
}

specify_artifacts_complete() {
  local specify_dir="$1"
  [ -f "$specify_dir/spec.md" ] && [ -s "$specify_dir/spec.md" ] \
    && [ -f "$specify_dir/plan.md" ] && [ -s "$specify_dir/plan.md" ] \
    && [ -f "$specify_dir/tasks.md" ] && [ -s "$specify_dir/tasks.md" ]
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
    return 0
  fi
  fail "Missing SHA-256 hashing support (sha256sum, shasum, openssl, or python3)."
}

compute_story_prep_fingerprint() {
  local story_id="$1"
  local sprint="$2"
  local title="$3"
  local goal="$4"
  local prompt_context="$5"
  local repo_briefing_abs="$6"
  local command_map_json="$7"
  local depends_on_json="$8"
  local focus_hints="${9:-}"
  local dependency_context="${10:-}"
  local repo_briefing_hash focus_json dependency_context_json payload

  if [ -n "$repo_briefing_abs" ] && [ -f "$repo_briefing_abs" ]; then
    repo_briefing_hash="$(hash_text < "$repo_briefing_abs")"
  else
    repo_briefing_hash=""
  fi

  if [ -n "$focus_hints" ]; then
    focus_json="$(printf '%s\n' "$focus_hints" | sed -n 's/^[[:space:]]*-[[:space:]]*`\(.*\)`$/\1/p' | jq -R . | jq -s .)"
  else
    focus_json='[]'
  fi
  dependency_context_json="$(printf '%s' "$dependency_context" | jq -Rs '.')"

  payload="$(jq -nc \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefingHash "$repo_briefing_hash" \
    --argjson commands "$command_map_json" \
    --argjson dependsOn "$depends_on_json" \
    --argjson likelyFiles "$focus_json" \
    --argjson dependencyContext "$dependency_context_json" \
    '{
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefingHash: $repoBriefingHash,
      commands: $commands,
      dependsOn: $dependsOn,
      likelyFiles: $likelyFiles,
      dependencyContext: $dependencyContext
    }')"
  printf '%s' "$payload" | hash_text
}

sanitize_dep_file_list() {
  local value="${1:-}"
  [ -n "$value" ] || return 0
  printf '%s\n' "$value" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sanitize_specify_paths \
    | join_with_comma_space
}

branch_parent_from_upstream() {
  local branch="$1"
  git -C "$WORKSPACE_ROOT" for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null | head -n1
}

set_branch_parent() {
  local branch="$1"
  local parent="$2"
  [ -n "$branch" ] && [ -n "$parent" ] || return 0
  git -C "$WORKSPACE_ROOT" branch --set-upstream-to="$parent" "$branch" >/dev/null 2>&1 || true
}

get_active_sprint() {
  [ -f "$ACTIVE_SPRINT_FILE" ] || return 1
  awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
}

resolve_stories_file() {
  if [ -n "$STORIES_FILE" ]; then
    [ -f "$STORIES_FILE" ] || fail "Stories file not found: $STORIES_FILE"
    return
  fi

  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint. Use ralph-sprint.sh use <sprint-name>."

  STORIES_FILE="$SPRINTS_DIR/$active_sprint/stories.json"
  [ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$active_sprint'. Run ralph-roadmap.sh or create the sprint backlog first."
}

usage() {
  cat <<'EOF'
Usage: ./ralph-story.sh <command> [args]

Commands:
  list                       List all stories in the active sprint
  show <ID>                  Show full story.json for a story
  next                       Show the next eligible story (no blockers, lowest priority)
  next-id                    Print only the next eligible story ID
  use <ID>                   Set a story as the active story
  start-next                 Set next eligible story as active
  tasks <ID>                 List tasks in a story with their status
  set-status <ID> <STATUS>   Set story status (planned|ready|active|done|abandoned|blocked)
  abandon <ID> [REASON]      Mark story abandoned
  health [ID]                Validate active stories (excludes done/abandoned)
  health-all                 Full audit sweep including done/abandoned stories
  specify <ID>               Run SpecKit analysis then generate story.json (primary path)
  specify-all [--force] [--jobs N]  Run SpecKit for all pending stories (default: serial)
  generate <ID>              Generate story.json (uses SpecKit artifacts when present)
  generate-all [--force] [--jobs N] Generate story.json for all stories with SpecKit artifacts
  prepare-all [--force] [--jobs N]  specify-all + generate-all + health + promote to ready
  prep-status [options]      Show latest prep journal summary for a sprint
  import-prd [PATH]          Import prd.json userStories into sprint backlog
  import-story <ID> <PATH|-] Import a story.json via framework validation
  add [options]              Add a story non-interactively

Eligibility for "next":
  - status is ready or planned
  - all depends_on stories are done
  - lowest priority wins, then ID

Specify options:
  --dry-run                  Print plan without running
  --force                    Re-run SpecKit even if artifacts exist
  --no-generate              Stop after SpecKit analysis (skip story.json generation)

Generate options:
  --dry-run                  Print the Codex prompt without running
  --force                    Overwrite existing story.json

Prep-status options:
  --sprint NAME              Inspect a specific sprint (default: active sprint)
  --story ID                 Limit detail output to one story
  --details                  Include per-stage detail lines
  --story-limit N            Limit compact story output (default: 5)

Import-prd options:
  PATH                       Path to prd.json (default: scripts/ralph/prd.json)

Add options:
  --id S-XXX                 Explicit story ID (default: next sequential)
  --title TEXT               Story title (required)
  --priority N               Priority (default: next available)
  --effort N                 Effort: 1, 2, 3, or 5 (default: 3)
  --status STATUS            planned|ready (default: planned)
  --depends-on IDS           Comma-separated dependency IDs (repeatable)
  --prompt-context TEXT      Planning context for story generation
  --goal TEXT                Story goal description
EOF
}

# ---------------------------------------------------------------------------
# Resolve story file path (absolute)
# ---------------------------------------------------------------------------

resolve_story_path() {
  local story_id="$1"
  local raw_path
  raw_path="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .story_path // empty' "$STORIES_FILE")"
  [ -n "$raw_path" ] || fail "Story $story_id not found in $STORIES_FILE"

  if [[ "$raw_path" != /* ]]; then
    echo "$WORKSPACE_ROOT/$raw_path"
  else
    echo "$raw_path"
  fi
}

resolve_repo_relative_path() {
  local raw_path="$1"
  if [[ "$raw_path" != /* ]]; then
    printf '%s\n' "$WORKSPACE_ROOT/$raw_path"
  else
    printf '%s\n' "$raw_path"
  fi
}

story_exists_in_backlog() {
  local story_id="$1"
  jq -e --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE" >/dev/null 2>&1
}

parse_depends_on_args() {
  local story_id="${1:-}"
  shift || true
  local values=()
  local raw dep
  for raw in "$@"; do
    [ -n "$raw" ] || continue
    while IFS= read -r dep; do
      dep="$(printf '%s' "$dep" | awk '{$1=$1;print}')"
      [ -n "$dep" ] || continue
      [ "$dep" != "$story_id" ] || fail "Story $story_id cannot depend on itself."
      story_exists_in_backlog "$dep" || fail "Unknown dependency '$dep'. Add the story first."
      values+=("$dep")
    done < <(printf '%s\n' "$raw" | tr ',' '\n')
  done

  if [ "${#values[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${values[@]}" \
    | awk 'NF && !seen[$0]++' \
    | jq -R . \
    | jq -s .
}

normalize_story_container() {
  local story_path="$1"
  local tmp
  tmp="$(mktemp)"
  jq '
    (.tasks // []) |= map(
      .depends_on =
        (if (.depends_on | type) == "array" then .depends_on
         elif (.depends_on | type) == "string" then [ .depends_on ]
         else [] end)
    )
    | (.tasks // []) |= (
      . as $all
      | reduce range(length) as $_ (
          { rem: $all, done: [] };
          (.done | map(.id)) as $placed
          | (
              .rem
              | map(select(
                  (.depends_on // []) | all(.[]; . as $d | $placed | index($d) != null)
                ))
              | sort_by(
                  if   (.id    | test("final$"))
                    or (.title | test("(?i)regression|final"))              then 99
                  elif (.title | test("(?i)test|spec"))                     then 20
                  elif (.title | test("(?i)integrat|home.*page|page.*app")) then 10
                  elif (.title | test("(?i)implement|create|build|librar")) then  5
                  elif (.title | test("(?i)confirm|depend|prerequisit"))    then  0
                  else 10 end
                )
              | .[0]
            ) as $next
          | if $next then
              {
                rem: (.rem | map(select(.id != $next.id))),
                done: (.done + [
                  ($next | .checks |= map(
                    if type == "string" then
                      (if test("^rg ") then
                         gsub("\\\\(?<c>[^ntrfaebsvdDwWsSpPhH0-9\\\\/\"])"; .c)
                       else . end)
                      | (if test("^rg \"[^\"]+\" [^ ]+$") then
                           capture("^rg \"(?<pat>[^\"]+)\" (?<file>[^ ]+)$")
                           | "rg -Fq \"\(.pat)\" \(.file) 2>/dev/null"
                         elif test("^rg -[a-zA-Z]+ \"[^\"]+\" [^ ]+$") then
                           capture("^rg -[a-zA-Z]+ \"(?<pat>[^\"]+)\" (?<file>[^ ]+)$")
                           | "rg -Fq \"\(.pat)\" \(.file) 2>/dev/null"
                         else . end)
                    else . end
                  ))
                ])
              }
            else .
            end
        )
      | .done
    )
  ' "$story_path" > "$tmp"
  mv "$tmp" "$story_path"
}

validate_story_container_file() {
  local story_path="$1"
  local expected_story_id="$2"
  local expected_sprint="$3"

  jq -e '.' "$story_path" >/dev/null 2>&1 || fail "Invalid JSON: $story_path"
  jq -e --arg id "$expected_story_id" '.storyId == $id' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json storyId must be $expected_story_id"
  jq -e --arg sprint "$expected_sprint" '.sprint == $sprint' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json sprint must be $expected_sprint"
  jq -e '.tasks | type == "array" and length > 0' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json must contain tasks[]"
  jq -e 'all(.tasks[]; (.checks | type) == "array" and (.checks | length) > 0)' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json has task(s) without checks"

  local bad_check=0 check
  while IFS= read -r check; do
    bash -n <<< "$check" 2>/dev/null || bad_check=$((bad_check + 1))
  done < <(jq -r '.tasks[].checks[]' "$story_path")
  [ "$bad_check" -eq 0 ] || fail "Imported story.json contains shell-invalid checks"
}

story_is_unrecovered_migration_placeholder() {
  local story_path="$1"
  [ -f "$story_path" ] || return 1
  jq -e '.migration.tasks_recovered == false' "$story_path" >/dev/null 2>&1
}

infer_checks_from_text() {
  local text="$1"
  local checks="[]"

  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(typecheck|tsc|type check|type-check)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run typecheck"]')"
  fi
  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(test|tests|jest|vitest|pytest|go test)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm test"]')"
  fi
  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(lint|eslint)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run lint"]')"
  fi
  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(build)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run build"]')"
  fi
  if printf '%s\n' "$text" | rg -qi 'verify in browser|playwright|cypress|verification'; then
    checks="$(echo "$checks" | jq '. + ["echo browser verification required"]')"
  fi

  if [ "$checks" = "[]" ]; then
    checks='["npm run typecheck"]'
  fi

  echo "$checks"
}

extract_markdown_section_body() {
  local file="$1"
  local heading="$2"
  awk -v heading="$heading" '
    $0 == heading { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$file"
}

extract_markdown_section_body_any() {
  local file="$1"
  shift
  local heading body
  for heading in "$@"; do
    body="$(extract_markdown_section_body "$file" "$heading")"
    if [ -n "$(printf '%s\n' "$body" | awk 'NF { print; exit }')" ]; then
      printf '%s\n' "$body"
      return 0
    fi
  done
  return 1
}

json_array_from_markdown_bullets() {
  local text="$1"
  printf '%s\n' "$text" \
    | sed -n -E 's/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*//p' \
    | awk 'NF' \
    | jq -R . \
    | jq -s .
}

json_first_slice_from_markdown() {
  local text="$1"
  local source destination entrypoint
  source="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*-[[:space:]]*exact source:[[:space:]]*//Ip' | head -n 1)"
  destination="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*-[[:space:]]*destination:[[:space:]]*//Ip' | head -n 1)"
  entrypoint="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*-[[:space:]]*\(entrypoint\|workflow\|commands\|caller workflow\):[[:space:]]*//Ip' | head -n 1)"
  jq -n \
    --arg source "$source" \
    --arg destination "$destination" \
    --arg entrypoint "$entrypoint" \
    '{
      source: $source,
      destination: $destination,
      entrypoint: $entrypoint
    }'
}

json_scope_from_text() {
  local text="$1"
  {
    printf '%s\n' "$text" | rg -o '`[^`]+`' | tr -d '`' || true
    printf '%s\n' "$text" | rg -o '([A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+' || true
    printf '%s\n' "$text" | rg -o '([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+' || true
  } \
    | sed -E 's/^[("'\''`]+//; s/[)"'\''`.,;:]+$//' \
    | awk 'NF && !seen[$0]++' \
    | jq -R . \
    | jq -s '
        unique
        | map(select(length > 0)) as $all
        | $all
        | map(select(
            . as $candidate
            | ($all | any(. != $candidate and endswith("/" + $candidate))) | not
          ))
      '
}

scope_fallback_from_spec() {
  local task_scope_json="$1"
  local support_json="$2"
  local first_slice_json="$3"
  printf '%s' "$task_scope_json" | jq \
    --argjson support "$support_json" \
    --argjson first_slice "$first_slice_json" \
    '
      if length > 0 then
        .
      else
        (
          (($support // []) + [($first_slice.destination // empty), ($first_slice.source // empty)])
          | map(select(type == "string" and length > 0))
          | map(sub("^[./]+"; ""))
          | map(select(test("\\.(md|txt)$") | not))
          | unique
        )
      end
    '
}

task_id_from_prd_story() {
  local raw_id="$1"
  local fallback_index="$2"
  local num
  num="$(printf '%s\n' "$raw_id" | sed -n 's/^US-\?0*\([0-9][0-9]*\)$/\1/p')"
  if [ -n "$num" ]; then
    printf 'T-%02d\n' "$num"
  else
    printf 'T-%02d\n' "$fallback_index"
  fi
}

parse_legacy_markdown_story_json() {
  local markdown_path="$1"
  local output_path="$2"
  local story_id="$3"
  local title="$4"
  local description="$5"
  local branch_name="$6"
  local sprint="$7"
  local priority="$8"
  local depends_json="$9"
  local project_name="${10}"

  [ -f "$markdown_path" ] || return 1

  local user_stories_body scope_body out_scope_body slice_body support_body invariants_body definition_body
  user_stories_body="$(extract_markdown_section_body_any "$markdown_path" '## User Stories' '## Stories' '## Implementation Stories' || true)"
  [ -n "$user_stories_body" ] || return 1

  if ! printf '%s\n' "$user_stories_body" | rg -q '^(### ([Ss]tory[[:space:]]+[0-9]+:|[0-9]+[.)][[:space:]]+|[^#].+)|[Ss]tory[[:space:]]+[[:alnum:]]+([:.-][[:space:]].*)?)'; then
    return 1
  fi

  scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Scope' '## In Scope' || true)"
  out_scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Out of Scope' '## Not In Scope' || true)"
  slice_body="$(extract_markdown_section_body_any "$markdown_path" '## First Slice Expectations' '## First Slice' '## Initial Slice' || true)"
  support_body="$(extract_markdown_section_body_any "$markdown_path" '## Allowed Supporting Files' '## Supporting Files' '## Files in Scope' || true)"
  invariants_body="$(extract_markdown_section_body_any "$markdown_path" '## Preserved Invariants' '## Invariants' || true)"
  definition_body="$(extract_markdown_section_body_any "$markdown_path" '## Definition of Done' '## Verification' '## Done Criteria' || true)"

  local spec_scope
  spec_scope="$(printf '%s\n' "$scope_body" | awk 'NF { print }' | paste -sd ' ' -)"
  [ -n "$spec_scope" ] || spec_scope="$description"

  local out_scope_json invariants_json support_json verification_json first_slice_json
  out_scope_json="$(json_array_from_markdown_bullets "$out_scope_body")"
  invariants_json="$(json_array_from_markdown_bullets "$invariants_body")"
  support_json="$(json_array_from_markdown_bullets "$support_body")"
  verification_json="$(json_array_from_markdown_bullets "$definition_body")"
  first_slice_json="$(json_first_slice_from_markdown "$slice_body")"

  local tasks_json
  tasks_json="$(
    printf '%s\n' "$user_stories_body" | awk '
      BEGIN {
        task_index = 0
        state = ""
        title = ""
        desc = ""
        acceptance = ""
        proof = ""
      }
      function trim(str) {
        gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", str)
        return str
      }
      function emit_task() {
        if (title == "") return
        task_index += 1
        gsub(/\n+$/, "", desc)
        gsub(/\n+$/, "", acceptance)
        gsub(/\n+$/, "", proof)
        printf("{\"id\":\"T-%02d\",\"title\":%s,\"desc\":%s,\"acceptance\":%s,\"proof\":%s}\n",
          task_index,
          tojson(trim(title)),
          tojson(trim(desc)),
          tojson(trim(acceptance)),
          tojson(trim(proof)))
      }
      function tojson(str,    out, i, c) {
        out = "\""
        for (i = 1; i <= length(str); i++) {
          c = substr(str, i, 1)
          if (c == "\\") out = out "\\\\"
          else if (c == "\"") out = out "\\\""
          else if (c == "\n") out = out "\\n"
          else out = out c
        }
        return out "\""
      }
      function normalize_title(raw,    cleaned) {
        cleaned = raw
        sub(/^###[[:space:]]*/, "", cleaned)
        sub(/^[Ss]tory[[:space:]]+[0-9]+:[[:space:]]*/, "", cleaned)
        sub(/^[0-9]+[.)][[:space:]]*/, "", cleaned)
        sub(/^[Ss]tory[[:space:]]+[[:alnum:]]+[[:space:]]*[-:][[:space:]]*/, "", cleaned)
        sub(/^[*][*](.*)[*][*]$/, "\\1", cleaned)
        return trim(cleaned)
      }
      function is_story_heading(raw,    probe) {
        probe = raw
        if (probe ~ /^### /) return 1
        if (probe ~ /^[Ss]tory[[:space:]]+[[:alnum:]]+([:.-][[:space:]].*)?$/) return 1
        return 0
      }
      /^[#[:space:]]*\**Acceptance Criteria:?\**[[:space:]]*$/ { state = "accept"; next }
      /^[#[:space:]]*\**Proof Obligations:?\**[[:space:]]*$/ { state = "proof"; next }
      /^[#[:space:]]*\**Description:?\**[[:space:]]*$/ { state = "desc"; next }
      /^[#[:space:]]*\**Description:[[:space:]]+/ {
        sub(/^[#[:space:]]*\**Description:[[:space:]]*/, "", $0)
        state = "desc"
        if (desc == "") desc = $0
        else desc = desc "\n" $0
        next
      }
      {
        if (is_story_heading($0)) {
          emit_task()
          title = normalize_title($0)
          if (title == "" || title ~ /^[Ss]tory[[:space:]]+[[:alnum:]]+$/) {
            title = trim($0)
            sub(/^###[[:space:]]*/, "", title)
          }
          desc = ""
          acceptance = ""
          proof = ""
          state = "desc"
          next
        }
        if ($0 ~ /^[#[:space:]]*\**Acceptance Criteria:?\**[[:space:]]*$/) { state = "accept"; next }
        if ($0 ~ /^[#[:space:]]*\**Proof Obligations:?\**[[:space:]]*$/) { state = "proof"; next }
        if ($0 ~ /^[#[:space:]]*\**Description:?\**[[:space:]]*$/) { state = "desc"; next }
        if (state == "desc") {
          if (desc == "") desc = $0
          else desc = desc "\n" $0
        } else if (state == "accept" && $0 ~ /^[[:space:]]*([-*]|[0-9]+[.)])/) {
          sub(/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*/, "", $0)
          if (acceptance == "") acceptance = $0
          else acceptance = acceptance "\n" $0
        } else if (state == "proof" && $0 ~ /^[[:space:]]*([-*]|[0-9]+[.)])/) {
          sub(/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*/, "", $0)
          if (proof == "") proof = $0
          else proof = proof "\n" $0
        } else if (state == "desc" && $0 ~ /^[[:space:]]*$/) {
          next
        }
      }
      END { emit_task() }
    ' | jq -Rs '
      split("\n")
      | map(select(length > 0) | fromjson)
    '
  )"

  local final_tasks_json="[]"
  local previous_task_id=""
  while IFS= read -r task_row; do
    [ -n "$task_row" ] || continue
    local task_id task_title task_desc task_acceptance_block task_proof_block
    local task_context task_acceptance_summary scope_text scope_json checks_json depends_task
    task_id="$(printf '%s' "$task_row" | jq -r '.id')"
    task_title="$(printf '%s' "$task_row" | jq -r '.title')"
    task_desc="$(printf '%s' "$task_row" | jq -r '.desc')"
    task_acceptance_block="$(printf '%s' "$task_row" | jq -r '.acceptance')"
    task_proof_block="$(printf '%s' "$task_row" | jq -r '.proof')"

    task_context="$task_desc"
    if [ -n "$task_acceptance_block" ]; then
      if [ -n "$task_context" ]; then
        task_context="$task_context"$'\n\n'"Acceptance Criteria:"$'\n'
      else
        task_context="Acceptance Criteria:"$'\n'
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        task_context="$task_context- $line"$'\n'
      done < <(printf '%s\n' "$task_acceptance_block")
    fi
    if [ -n "$task_proof_block" ]; then
      if [ -n "$task_context" ]; then
        task_context="$task_context"$'\n'"Proof Obligations:"$'\n'
      else
        task_context="Proof Obligations:"$'\n'
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        task_context="$task_context- $line"$'\n'
      done < <(printf '%s\n' "$task_proof_block")
    fi
    task_context="${task_context%$'\n'}"
    [ -n "$task_context" ] || task_context="Recover implementation details from preserved legacy PRD markdown."

    task_acceptance_summary="$(printf '%s\n%s\n' "$task_acceptance_block" "$task_proof_block" | awk 'NF { print }' | paste -sd ' ' -)"
    [ -n "$task_acceptance_summary" ] || task_acceptance_summary="$task_title completed according to legacy PRD markdown."

    scope_text="$(printf '%s\n%s\n%s\n' "$task_desc" "$task_acceptance_block" "$task_proof_block")"
    scope_json="$(json_scope_from_text "$scope_text")"
    scope_json="$(scope_fallback_from_spec "$scope_json" "$support_json" "$first_slice_json")"
    checks_json="$(infer_checks_from_text "$task_acceptance_summary")"
    depends_task="[]"
    if [ -n "$previous_task_id" ]; then
      depends_task="$(jq -nc --arg dep "$previous_task_id" '[$dep]')"
    fi
    final_tasks_json="$(printf '%s' "$final_tasks_json" | jq \
      --arg id "$task_id" \
      --arg title "$task_title" \
      --arg context "$task_context" \
      --arg acceptance "$task_acceptance_summary" \
      --argjson scope "$scope_json" \
      --argjson checks "$checks_json" \
      --argjson depends "$depends_task" \
      '. + [{
        "id": $id,
        "title": $title,
        "context": $context,
        "scope": $scope,
        "acceptance": $acceptance,
        "checks": $checks,
        "depends_on": $depends,
        "status": "pending",
        "passes": false
      }]')"
    previous_task_id="$task_id"
  done < <(printf '%s' "$tasks_json" | jq -c '.[]')

  [ "$(printf '%s' "$final_tasks_json" | jq 'length')" -gt 0 ] || return 1

  local prd_ref="$markdown_path"
  if [[ "$prd_ref" == "$WORKSPACE_ROOT/"* ]]; then
    prd_ref="${prd_ref#$WORKSPACE_ROOT/}"
  fi

  jq -n \
    --argjson version 1 \
    --arg project "$project_name" \
    --arg sid "$story_id" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg branch "$branch_name" \
    --arg sprint "$sprint" \
    --argjson priority "$priority" \
    --argjson depends "$depends_json" \
    --arg scope "$spec_scope" \
    --argjson out_scope "$out_scope_json" \
    --argjson first_slice "$first_slice_json" \
    --argjson invariants "$invariants_json" \
    --argjson support "$support_json" \
    --argjson verification "$verification_json" \
    --arg prd_ref "$prd_ref" \
    --argjson tasks "$final_tasks_json" \
    '{
      "version": $version,
      "project": $project,
      "storyId": $sid,
      "title": $title,
      "description": $desc,
      "branchName": $branch,
      "sprint": $sprint,
      "priority": $priority,
      "depends_on": $depends,
      "status": "planned",
      "spec": {
        "scope": $scope,
        "out_of_scope": $out_scope,
        "first_slice": $first_slice,
        "preserved_invariants": $invariants,
        "supporting_files": $support,
        "verification": $verification,
        "prdRef": $prd_ref
      },
      "migration": {
        "source": "legacy-prd-markdown",
        "tasks_recovered": true
      },
      "tasks": $tasks,
      "passes": false
    }' > "$output_path"
}

mark_guided_migration_recovery() {
  local story_path="$1"
  local fallback_reason="$2"
  local prd_ref="$3"
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg reason "$fallback_reason" \
    --arg prd_ref "$prd_ref" \
    '
      .migration = ((.migration // {}) + {
        source: "legacy-placeholder-guided-recovery",
        tasks_recovered: true,
        recoveryMode: "guided-codex-fallback",
        recoveryWarnings: (
          [
            "Task plan was regenerated through guided fallback recovery rather than deterministic legacy markdown compilation.",
            $reason
          ]
          | map(select(length > 0))
        )
      })
      | if ($prd_ref | length) > 0 then
          .spec = ((.spec // {}) + { prdRef: $prd_ref })
        else
          .
        end
      | .spec.verification = (
          ((.spec.verification // []) + [
            "Legacy migration fallback recovery used guided generation; review task scope and acceptance checks before execution."
          ])
          | unique
        )
    ' "$story_path" > "$tmp"
  mv "$tmp" "$story_path"
}

mark_prd_bridge_migration_recovery() {
  local story_path="$1"
  local prd_ref="$2"
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg prd_ref "$prd_ref" \
    '
      .migration = ((.migration // {}) + {
        source: "legacy-prd-json-bridge",
        tasks_recovered: true,
        recoveryMode: "guided-prd-json-bridge",
        recoveryWarnings: [
          "Task plan was recovered by converting preserved PRD markdown into a temporary prd.json bridge before generating story.json."
        ]
      })
      | if ($prd_ref | length) > 0 then
          .spec = ((.spec // {}) + { prdRef: $prd_ref })
        else
          .
        end
      | .spec.verification = (
          ((.spec.verification // []) + [
            "Legacy migration used a temporary prd.json bridge; review generated tasks and acceptance checks before execution."
          ])
          | unique
        )
    ' "$story_path" > "$tmp"
  mv "$tmp" "$story_path"
}

bridge_markdown_to_prd_json() {
  local markdown_path="$1"
  local temp_prd_path="$2"
  local branch_name="$3"
  local project_name="$4"
  local story_title="$5"
  local story_goal="$6"

  local prompt
  prompt="$(cat <<PRDBRIDGE
## Recover temporary prd.json for legacy migration

Source PRD markdown: $markdown_path

Use the PRD skill to normalize the markdown structure, then use the Ralph PRD converter rules to produce a valid temporary prd.json for migration recovery.

Write the temporary prd.json to: $temp_prd_path

Requirements:
1. project: $project_name
2. branchName: $branch_name
3. description should summarize: $story_goal
4. Preserve the PRD intent, but split oversized work into focused userStories when needed.
5. Every user story must include verifiable acceptance criteria and "Typecheck passes".
6. Add "Tests pass" and lint/browser verification only when the markdown warrants it.
7. Set every story to passes=false and notes="".
8. Do not write story.json in this step.
PRDBRIDGE
)"

  codex_exec_prompt "$prompt" "$WORKSPACE_ROOT"
  [ -f "$temp_prd_path" ] || return 1
  jq -e '.userStories | length > 0' "$temp_prd_path" >/dev/null 2>&1
}

build_story_json_from_prd_json() {
  local prd_json_path="$1"
  local output_path="$2"
  local story_id="$3"
  local title="$4"
  local description="$5"
  local branch_name="$6"
  local sprint="$7"
  local priority="$8"
  local depends_json="$9"
  local project_name="${10}"
  local markdown_path="${11:-}"

  [ -f "$prd_json_path" ] || return 1
  jq -e '.userStories | length > 0' "$prd_json_path" >/dev/null 2>&1 || return 1

  local scope_body out_scope_body slice_body support_body invariants_body definition_body
  local spec_scope out_scope_json invariants_json support_json verification_json first_slice_json

  if [ -n "$markdown_path" ] && [ -f "$markdown_path" ]; then
    scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Scope' '## In Scope' || true)"
    out_scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Out of Scope' '## Not In Scope' || true)"
    slice_body="$(extract_markdown_section_body_any "$markdown_path" '## First Slice Expectations' '## First Slice' '## Initial Slice' || true)"
    support_body="$(extract_markdown_section_body_any "$markdown_path" '## Allowed Supporting Files' '## Supporting Files' '## Files in Scope' || true)"
    invariants_body="$(extract_markdown_section_body_any "$markdown_path" '## Preserved Invariants' '## Invariants' || true)"
    definition_body="$(extract_markdown_section_body_any "$markdown_path" '## Definition of Done' '## Verification' '## Done Criteria' || true)"
  else
    scope_body=""
    out_scope_body=""
    slice_body=""
    support_body=""
    invariants_body=""
    definition_body=""
  fi

  spec_scope="$(printf '%s\n' "$scope_body" | awk 'NF { print }' | paste -sd ' ' -)"
  [ -n "$spec_scope" ] || spec_scope="$(jq -r '.description // empty' "$prd_json_path")"
  [ -n "$spec_scope" ] || spec_scope="$description"
  out_scope_json="$(json_array_from_markdown_bullets "$out_scope_body")"
  invariants_json="$(json_array_from_markdown_bullets "$invariants_body")"
  support_json="$(json_array_from_markdown_bullets "$support_body")"
  verification_json="$(json_array_from_markdown_bullets "$definition_body")"
  first_slice_json="$(json_first_slice_from_markdown "$slice_body")"

  local final_tasks_json="[]"
  local previous_task_id=""
  local index=1
  while IFS= read -r us_row; do
    [ -n "$us_row" ] || continue
    local raw_us_id task_id us_title us_desc us_acceptance us_scope us_context acceptance_summary checks_json depends_task
    raw_us_id="$(printf '%s' "$us_row" | jq -r '.id // empty')"
    task_id="$(task_id_from_prd_story "$raw_us_id" "$index")"
    us_title="$(printf '%s' "$us_row" | jq -r '.title // ""')"
    us_desc="$(printf '%s' "$us_row" | jq -r '.description // ""')"
    us_acceptance="$(printf '%s' "$us_row" | jq -c '.acceptanceCriteria // []')"
    us_scope="$(printf '%s' "$us_row" | jq -c '.scopePaths // []')"
    us_context="$us_desc"
    if [ "$(printf '%s' "$us_acceptance" | jq 'length')" -gt 0 ]; then
      local ac_lines
      ac_lines="$(printf '%s' "$us_acceptance" | jq -r '.[]' | sed 's/^/- /')"
      if [ -n "$us_context" ]; then
        us_context="$us_context"$'\n\n'"Acceptance Criteria:"$'\n'"$ac_lines"
      else
        us_context="Acceptance Criteria:"$'\n'"$ac_lines"
      fi
    fi
    acceptance_summary="$(printf '%s' "$us_acceptance" | jq -r 'join(". ")')"
    [ -n "$acceptance_summary" ] || acceptance_summary="$us_title completed according to temporary prd.json recovery."
    checks_json="$(infer_checks_from_text "$(printf '%s' "$us_acceptance" | jq -r 'join(" ")')")"
    us_scope="$(scope_fallback_from_spec "$us_scope" "$support_json" "$first_slice_json")"
    depends_task="[]"
    if [ -n "$previous_task_id" ]; then
      depends_task="$(jq -nc --arg dep "$previous_task_id" '[$dep]')"
    fi
    final_tasks_json="$(printf '%s' "$final_tasks_json" | jq \
      --arg id "$task_id" \
      --arg title "$us_title" \
      --arg context "$us_context" \
      --arg acceptance "$acceptance_summary" \
      --argjson scope "$us_scope" \
      --argjson checks "$checks_json" \
      --argjson depends "$depends_task" \
      '. + [{
        "id": $id,
        "title": $title,
        "context": $context,
        "scope": $scope,
        "acceptance": $acceptance,
        "checks": $checks,
        "depends_on": $depends,
        "status": "pending",
        "passes": false
      }]')"
    previous_task_id="$task_id"
    index=$((index + 1))
  done < <(jq -c '.userStories[]' "$prd_json_path")

  [ "$(printf '%s' "$final_tasks_json" | jq 'length')" -gt 0 ] || return 1

  local prd_ref="$markdown_path"
  if [ -n "$prd_ref" ] && [[ "$prd_ref" == "$WORKSPACE_ROOT/"* ]]; then
    prd_ref="${prd_ref#$WORKSPACE_ROOT/}"
  fi

  jq -n \
    --argjson version 1 \
    --arg project "$project_name" \
    --arg sid "$story_id" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg branch "$branch_name" \
    --arg sprint "$sprint" \
    --argjson priority "$priority" \
    --argjson depends "$depends_json" \
    --arg scope "$spec_scope" \
    --argjson out_scope "$out_scope_json" \
    --argjson first_slice "$first_slice_json" \
    --argjson invariants "$invariants_json" \
    --argjson support "$support_json" \
    --argjson verification "$verification_json" \
    --arg prd_ref "$prd_ref" \
    --argjson tasks "$final_tasks_json" \
    '{
      "version": $version,
      "project": $project,
      "storyId": $sid,
      "title": $title,
      "description": $desc,
      "branchName": $branch,
      "sprint": $sprint,
      "priority": $priority,
      "depends_on": $depends,
      "status": "planned",
      "spec": {
        "scope": $scope,
        "out_of_scope": $out_scope,
        "first_slice": $first_slice,
        "preserved_invariants": $invariants,
        "supporting_files": $support,
        "verification": $verification,
        "prdRef": $prd_ref
      },
      "tasks": $tasks,
      "passes": false
    }' > "$output_path"
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

cmd_list() {
  resolve_stories_file

  local sprint
  sprint="$(jq -r '.sprint' "$STORIES_FILE")"
  local active_id
  active_id="$(jq -r '.activeStoryId // "none"' "$STORIES_FILE")"

  echo "Sprint: $sprint   active=$active_id"
  echo ""
  printf "%-10s %-6s %-6s %-12s %s\n" "ID" "PRI" "EFF" "STATUS" "TITLE"
  printf "%-10s %-6s %-6s %-12s %s\n" "----------" "------" "------" "------------" "-----"

  jq -r '
    .stories | sort_by(.priority) | .[] |
    [.id, (.priority|tostring), (.effort|tostring), .status, .title] | @tsv
  ' "$STORIES_FILE" | while IFS=$'\t' read -r sid pri eff status title; do
    marker="  "
    [ "$sid" = "$active_id" ] && marker="->"
    printf "%s %-8s %-6s %-6s %-12s %s\n" "$marker" "$sid" "$pri" "$eff" "$status" "$title"
  done
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

cmd_show() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh show <ID>"
  resolve_stories_file

  local story_path
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found at: $story_path"
  jq '.' "$story_path"
}

# ---------------------------------------------------------------------------
# next / next-id
# ---------------------------------------------------------------------------

cmd_next_id() {
  resolve_stories_file

  jq -r '
    .stories
    | map(select(.status == "ready" or .status == "planned"))
    | sort_by([.priority, .id])
    | .[]
    | .id
  ' "$STORIES_FILE" | while IFS= read -r sid; do
    # Check dependencies
    local deps_ok=true
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      dep_status="$(jq -r --arg d "$dep" '.stories[] | select(.id == $d) | .status' "$STORIES_FILE")"
      # Sprint backlog files only contain sprint-local stories. Cross-sprint
      # sequencing is enforced by sprint order, so missing deps here should not
      # block the next story in the active sprint.
      [ -z "$dep_status" ] && continue
      if [ "$dep_status" != "done" ]; then
        deps_ok=false
        break
      fi
    done < <(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .depends_on[]?' "$STORIES_FILE")
    if [ "$deps_ok" = "true" ]; then
      echo "$sid"
      return 0
    fi
  done
}

cmd_next() {
  resolve_stories_file
  local next_id
  next_id="$(cmd_next_id)"
  [ -n "$next_id" ] || { echo "No eligible story found."; return 0; }

  jq --arg id "$next_id" '.stories[] | select(.id == $id)' "$STORIES_FILE"
}

# ---------------------------------------------------------------------------
# use
# ---------------------------------------------------------------------------

cmd_use() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh use <ID>"
  resolve_stories_file

  local exists
  exists="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .id' "$STORIES_FILE")"
  [ -n "$exists" ] || fail "Story $story_id not found."

  local story_path
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found for $story_id: $story_path
  Run: ./ralph-story.sh generate $story_id"

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$story_id" '.activeStoryId = $id' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Active story set to: $story_id"
}

# ---------------------------------------------------------------------------
# start-next
# ---------------------------------------------------------------------------

cmd_start_next() {
  resolve_stories_file
  local next_id
  next_id="$(cmd_next_id)"
  [ -n "$next_id" ] || fail "No eligible story to start."

  local story_path
  story_path="$(resolve_story_path "$next_id")"
  [ -f "$story_path" ] || fail "story.json not found for $next_id: $story_path
  Run: ./ralph-story.sh generate $next_id"

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$next_id" '
    (.stories[] | select(.id == $id) | .status) = "active" |
    .activeStoryId = $id
  ' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Started story: $next_id"

  # Commit the activeStoryId update to the sprint branch before creating story branch
  git -C "$WORKSPACE_ROOT" add "$STORIES_FILE" 2>/dev/null || true
  if ! git -C "$WORKSPACE_ROOT" diff --cached --quiet 2>/dev/null; then
    git -C "$WORKSPACE_ROOT" commit -m "chore(ralph): start $next_id"
  fi

  # Checkout or create story branch from sprint branch
  local story_branch active_sprint sprint_branch
  story_branch="$(jq -r '.branchName // ""' "$story_path" 2>/dev/null || true)"
  if [ -n "$story_branch" ]; then
    active_sprint="$(get_active_sprint 2>/dev/null || echo "")"
    sprint_branch=""
    [ -n "$active_sprint" ] && sprint_branch="ralph/sprint/$active_sprint"
    if git -C "$WORKSPACE_ROOT" show-ref --verify --quiet "refs/heads/$story_branch" 2>/dev/null; then
      git -C "$WORKSPACE_ROOT" checkout "$story_branch"
      if [ -n "$sprint_branch" ] && [ -z "$(branch_parent_from_upstream "$story_branch")" ]; then
        set_branch_parent "$story_branch" "$sprint_branch"
      fi
      echo "Checked out story branch: $story_branch"
    elif [ -n "$sprint_branch" ] && git -C "$WORKSPACE_ROOT" show-ref --verify --quiet "refs/heads/$sprint_branch" 2>/dev/null; then
      git -C "$WORKSPACE_ROOT" checkout -b "$story_branch" "$sprint_branch"
      set_branch_parent "$story_branch" "$sprint_branch"
      echo "Created story branch: $story_branch (from $sprint_branch)"
    else
      git -C "$WORKSPACE_ROOT" checkout -b "$story_branch"
      echo "Created story branch: $story_branch (from current HEAD)"
    fi
  fi

  # Warn if any dependency has no compact story handoff (downstream context will be thin)
  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local dep_raw dep_abs dep_note
    dep_raw="$(jq -r --arg d "$dep_id" '.stories[] | select(.id == $d) | .story_path // ""' "$STORIES_FILE" 2>/dev/null || true)"
    [ -n "$dep_raw" ] || continue
    [[ "$dep_raw" != /* ]] && dep_abs="$WORKSPACE_ROOT/$dep_raw" || dep_abs="$dep_raw"
    [ -f "$dep_abs" ] || continue
    dep_note="$(jq -r 'if (.story_handoff // null) != null then (((.story_handoff.files_touched // []) | join(", ")) + " | " + ((.story_handoff.contracts_added // []) | join(", "))) else "" end' "$dep_abs" 2>/dev/null || true)"
    if [ -z "$dep_note" ]; then
      echo "WARN: Dependency $dep_id has no story_handoff — downstream context for this story will be thin."
    fi
  done < <(jq -r --arg id "$next_id" '.stories[] | select(.id == $id) | .depends_on[]?' "$STORIES_FILE" 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# tasks
# ---------------------------------------------------------------------------

cmd_tasks() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh tasks <ID>"
  resolve_stories_file

  local story_path
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found at: $story_path"

  echo "Tasks for story $story_id:"
  echo ""
  printf "%-8s %-8s %s\n" "ID" "STATUS" "TITLE"
  printf "%-8s %-8s %s\n" "--------" "--------" "-----"
  jq -r '.tasks[] | [.id, .status, .title] | @tsv' "$story_path" \
    | while IFS=$'\t' read -r tid tstatus ttitle; do
      printf "%-8s %-8s %s\n" "$tid" "$tstatus" "$ttitle"
    done
}

# ---------------------------------------------------------------------------
# set-status
# ---------------------------------------------------------------------------

cmd_set_status() {
  local story_id="${1:-}"
  local new_status="${2:-}"
  [ -n "$story_id" ] && [ -n "$new_status" ] || fail "Usage: ralph-story.sh set-status <ID> <STATUS>"
  resolve_stories_file

  local valid_statuses="planned ready active done abandoned blocked"
  printf '%s\n' "$valid_statuses" | tr ' ' '\n' | rg -qx -- "$new_status" || fail "Invalid status '$new_status'. Valid: $valid_statuses"

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$story_id" --arg s "$new_status" \
    '(.stories[] | select(.id == $id) | .status) = $s' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Story $story_id status set to: $new_status"
}

# ---------------------------------------------------------------------------
# abandon
# ---------------------------------------------------------------------------

cmd_abandon() {
  local story_id="${1:-}"
  local reason="${2:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh abandon <ID> [REASON]"
  resolve_stories_file

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$story_id" --arg r "$reason" \
    '(.stories[] | select(.id == $id)) |= . + {"status": "abandoned", "abandonReason": $r}' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Story $story_id marked abandoned."
}

# ---------------------------------------------------------------------------
# health
# ---------------------------------------------------------------------------

_health_story() {
  local story_id="$1"
  local story_path
  story_path="$(resolve_story_path "$story_id")"
  local story_status
  story_status="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .status' "$STORIES_FILE")"
  local issues=0

  echo "[$story_id] $story_status"

  if [ ! -f "$story_path" ]; then
    echo "  [MISSING] story.json not found: $story_path"
    return 1
  fi

  if jq -e '.migration.tasks_recovered == false' "$story_path" >/dev/null 2>&1; then
    if [ "$story_status" = "done" ] || [ "$story_status" = "abandoned" ]; then
      echo "  [INFO] Historical migration placeholder retained (task-level data was not recoverable)"
    else
      echo "  [MIGRATION] task-level data was not recovered; regenerate this story before execution"
      issues=$((issues + 1))
    fi
  fi

  # Validate SpecKit artifacts if .specify/ exists (catches partial SpecKit runs)
  local specify_dir
  specify_dir="$(dirname "$story_path")/.specify"
  if [ -d "$specify_dir" ]; then
    for artifact in spec.md plan.md tasks.md; do
      if [ ! -f "$specify_dir/$artifact" ]; then
        echo "  [SPECKIT] Missing artifact: $artifact (partial run — re-run specify with --force)"
        issues=$((issues + 1))
      elif [ ! -s "$specify_dir/$artifact" ]; then
        echo "  [SPECKIT] Empty artifact: $artifact"
        issues=$((issues + 1))
      fi
    done
  fi

  local task_count
  task_count="$(jq '.tasks | length' "$story_path")"
  if [ "$task_count" -eq 0 ]; then
    echo "  [WARN] No tasks defined"
    issues=$((issues + 1))
  fi

  # Per-task checks: missing checks, empty context, dead depends_on
  while IFS= read -r tid; do
    local check_count
    check_count="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .checks | length' "$story_path")"
    if [ "$check_count" -eq 0 ]; then
      echo "  [WARN] $tid: no acceptance checks"
      issues=$((issues + 1))
    fi

    local ctx
    ctx="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .context // ""' "$story_path")"
    if [ -z "$ctx" ] || [ "$ctx" = "null" ]; then
      echo "  [WARN] $tid: empty context"
      issues=$((issues + 1))
    fi

    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      local dep_exists
      dep_exists="$(jq -r --arg d "$dep" '.tasks[] | select(.id == $d) | .id' "$story_path")"
      if [ -z "$dep_exists" ]; then
        echo "  [DEAD] $tid: depends_on '$dep' not found in story"
        issues=$((issues + 1))
      fi
    done < <(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .depends_on[]?' "$story_path")
  done < <(jq -r '.tasks[].id' "$story_path")

  # Duplicate checks within the same task's checks array
  while IFS= read -r tid; do
    local self_dups
    self_dups="$(jq -r --arg id "$tid" '
      (.tasks[] | select(.id == $id) | .checks // []) |
      group_by(.) | map(select(length > 1) | .[0]) | .[]
    ' "$story_path" 2>/dev/null || true)"
    if [ -n "$self_dups" ]; then
      while IFS= read -r dup; do
        [ -z "$dup" ] && continue
        echo "  [DUP]  $tid: check listed more than once: $dup"
        issues=$((issues + 1))
      done <<< "$self_dups"
    fi
  done < <(jq -r '.tasks[].id' "$story_path")

  # Tasks with identical check sets — only flag when titles are also similar
  # (same checks + similar titles = likely copy-paste error)
  local dup_task_sets
  dup_task_sets="$(jq -r '
    .tasks |
    map({id: .id, title: (.title // ""), checks: (.checks // [] | sort)}) |
    group_by(.checks) |
    map(select(length > 1)) |
    map(
      . as $group |
      [
        range($group | length) as $i |
        range($i + 1; $group | length) as $j |
        [$group[$i], $group[$j]] |
        select(
          (.[0].title | ascii_downcase) == (.[1].title | ascii_downcase)
          or (.[0].title | ascii_downcase | contains(.[1].title | ascii_downcase))
          or (.[1].title | ascii_downcase | contains(.[0].title | ascii_downcase))
        ) |
        "\(.[0].id), \(.[1].id)"
      ] |
      unique |
      .[]
    ) |
    .[]
  ' "$story_path" 2>/dev/null || true)"
  if [ -n "$dup_task_sets" ]; then
    while IFS= read -r set; do
      [ -z "$set" ] && continue
      echo "  [DUP]  Tasks share identical check sets and similar titles: $set"
      issues=$((issues + 1))
    done <<< "$dup_task_sets"
  fi

  # Self-referencing depends_on
  while IFS= read -r tid; do
    local self_dep
    self_dep="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .depends_on[]? | select(. == $id)' "$story_path" 2>/dev/null || true)"
    if [ -n "$self_dep" ]; then
      echo "  [CYCLE] $tid: depends on itself"
      issues=$((issues + 1))
    fi
  done < <(jq -r '.tasks[].id' "$story_path")

  # Validate checks[] syntax and command reachability
  while IFS= read -r tid; do
    local cnum=0
    while IFS= read -r chk; do
      [ -z "$chk" ] && continue
      cnum=$((cnum + 1))
      if ! bash -n -c "$chk" 2>/dev/null; then
        echo "  [SYNTAX] $tid check[$cnum]: syntax error: $chk"
        issues=$((issues + 1))
      else
        local first_word
        first_word="$(printf '%s' "$chk" | awk '{print $1}')"
        case "$first_word" in
          test|'['|echo|true|false|printf|:) ;;
          grep|find|cat|ls|mkdir|rm|cp|mv|sed|awk|sort|head|tail|wc|cut|tr) ;;
          git|bash|sh|cd|source|.) ;;
          *)
            if ! command -v "$first_word" >/dev/null 2>&1; then
              echo "  [CMD?]  $tid check[$cnum]: '$first_word' not on PATH: $chk"
              issues=$((issues + 1))
            fi
            ;;
        esac
      fi
    done < <(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .checks[]?' "$story_path")
  done < <(jq -r '.tasks[].id' "$story_path")

  if [ "$issues" -eq 0 ]; then
    echo "  OK"
    return 0
  fi
  return 1
}

cmd_health() {
  resolve_stories_file

  local story_id="${1:-}"

  if [ -n "$story_id" ]; then
    _health_story "$story_id"
    return $?
  fi

  local any_issues=0
  while IFS= read -r sid; do
    _health_story "$sid" || any_issues=1
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  echo ""
  if [ "$any_issues" -eq 0 ]; then
    echo "All stories healthy."
  else
    echo "Issues found. Review warnings above."
    return 1
  fi
}

# health-all: full audit sweep including done/abandoned stories
cmd_health_all() {
  resolve_stories_file

  local any_issues=0
  while IFS= read -r sid; do
    _health_story "$sid" || any_issues=1
  done < <(jq -r '.stories[].id' "$STORIES_FILE")

  echo ""
  if [ "$any_issues" -eq 0 ]; then
    echo "All stories healthy (full audit)."
  else
    echo "Issues found. Review warnings above."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------

cmd_add() {
  resolve_stories_file

  local new_title=""
  local new_id=""
  local new_priority=""
  local new_effort=3
  local new_status="planned"
  local -a new_depends=()
  local new_goal=""
  local new_prompt_context=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)             new_id="${2:-}"; shift 2 ;;
      --title)          new_title="${2:-}"; shift 2 ;;
      --priority)       new_priority="${2:-}"; shift 2 ;;
      --effort)         new_effort="${2:-3}"; shift 2 ;;
      --status)         new_status="${2:-planned}"; shift 2 ;;
      --depends-on)     new_depends+=("${2:-}"); shift 2 ;;
      --goal)           new_goal="${2:-}"; shift 2 ;;
      --prompt-context) new_prompt_context="${2:-}"; shift 2 ;;
      *) fail "Unknown add option: $1" ;;
    esac
  done

  [ -n "$new_title" ] || fail "--title is required"

  # Auto-assign ID
  if [ -z "$new_id" ]; then
    local max_n=0
    while IFS= read -r existing_id; do
      n="${existing_id#S-}"
      n="${n#0}"
      [ "$n" -gt "$max_n" ] 2>/dev/null && max_n="$n"
    done < <(jq -r '.stories[].id' "$STORIES_FILE")
    new_id="$(printf 'S-%03d' $((max_n + 1)))"
  fi

  # Auto-assign priority
  if [ -z "$new_priority" ]; then
    new_priority="$(jq '[.stories[].priority] | max + 1' "$STORIES_FILE")"
  fi

  # Build depends_on array
  local deps_json
  deps_json="$(parse_depends_on_args "$new_id" "${new_depends[@]}")"

  # Determine active sprint for story_path
  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint."
  local dest_rel="${SCRIPT_DIR#${WORKSPACE_ROOT}/}"
  local story_path="$dest_rel/sprints/$active_sprint/stories/$new_id/story.json"

  local tmp
  tmp="$(mktemp)"
  jq \
    --arg id "$new_id" \
    --arg title "$new_title" \
    --arg sprint "$active_sprint" \
    --argjson priority "$new_priority" \
    --argjson effort "$new_effort" \
    --arg status "$new_status" \
    --argjson depends "$deps_json" \
    --arg goal "$new_goal" \
    --arg ctx "$new_prompt_context" \
    --arg path "$story_path" \
    '.stories += [{
      "id": $id,
      "title": $title,
      "priority": $priority,
      "effort": $effort,
      "planningSource": "local",
      "status": $status,
      "sprint": $sprint,
      "depends_on": $depends,
      "story_path": $path,
      "goal": $goal,
      "promptContext": $ctx
    }]' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Added story: $new_id — $new_title"
}

cmd_import_story() {
  local story_id="${1:-}"
  local source_path="${2:-}"
  [ -n "$story_id" ] && [ -n "$source_path" ] || fail "Usage: ralph-story.sh import-story <ID> <PATH|-> [--force]"
  shift 2 || true
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) fail "Unknown import-story option: $1" ;;
    esac
  done

  resolve_stories_file
  story_exists_in_backlog "$story_id" || fail "Story $story_id not found in $STORIES_FILE"

  local story_meta raw_path story_path_abs sprint expected_path tmp_input
  story_meta="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE")"
  raw_path="$(printf '%s' "$story_meta" | jq -r '.story_path // empty')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  [ -n "$raw_path" ] || fail "story_path not set for $story_id"
  [ -n "$sprint" ] || fail "sprint not set for $story_id"
  story_path_abs="$(resolve_repo_relative_path "$raw_path")"

  if [ -f "$story_path_abs" ] && [ "$force" -ne 1 ]; then
    fail "story.json already exists: $story_path_abs (use --force to overwrite)"
  fi

  mkdir -p "$(dirname "$story_path_abs")"
  if [ "$source_path" = "-" ]; then
    tmp_input="$(mktemp)"
    cat > "$tmp_input"
    source_path="$tmp_input"
  fi
  [ -f "$source_path" ] || fail "Import source not found: $source_path"

  cp "$source_path" "$story_path_abs"
  normalize_story_container "$story_path_abs"
  validate_story_container_file "$story_path_abs" "$story_id" "$sprint"

  if [ -n "${tmp_input:-}" ] && [ -f "$tmp_input" ]; then
    rm -f "$tmp_input"
  fi

  echo "Imported story container for $story_id: $raw_path"
}

# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

cmd_generate() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh generate <ID> [--dry-run] [--force]"
  shift || true
  local dry_run=0
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --force)   force=1;   shift ;;
      *) fail "Unknown generate option: $1" ;;
    esac
  done

  resolve_stories_file

  local story_meta
  story_meta="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE")"
  [ -n "$story_meta" ] || fail "Story $story_id not found in $STORIES_FILE"

  local raw_path
  raw_path="$(printf '%s' "$story_meta" | jq -r '.story_path // empty')"
  [ -n "$raw_path" ] || fail "story_path not set for $story_id in $STORIES_FILE"

  local story_path_abs
  story_path_abs="$(resolve_repo_relative_path "$raw_path")"

  local placeholder_recovery=0 existing_branch_name="" existing_prd_ref="" existing_prd_abs=""
  if [ -f "$story_path_abs" ]; then
    existing_branch_name="$(jq -r '.branchName // empty' "$story_path_abs" 2>/dev/null || true)"
    existing_prd_ref="$(jq -r '.spec.prdRef // empty' "$story_path_abs" 2>/dev/null || true)"
    if story_is_unrecovered_migration_placeholder "$story_path_abs"; then
      placeholder_recovery=1
      if [ -n "$existing_prd_ref" ]; then
        existing_prd_abs="$(resolve_repo_relative_path "$existing_prd_ref")"
      fi
    fi
  fi

  local title goal prompt_context effort sprint priority depends_on_arr
  title="$(printf '%s' "$story_meta" | jq -r '.title // ""')"
  goal="$(printf '%s' "$story_meta" | jq -r '.goal // ""')"
  prompt_context="$(printf '%s' "$story_meta" | jq -r '.promptContext // ""')"
  effort="$(printf '%s' "$story_meta" | jq -r '.effort // 3')"
  priority="$(printf '%s' "$story_meta" | jq -r '.priority // 1')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint" "$story_id"
  depends_on_arr="$(printf '%s' "$story_meta" | jq -c '.depends_on // []')"
  ensure_prep_run_dir "$sprint" "generate" >/dev/null

  local branch_name="ralph/$sprint/story-$story_id"
  [ -n "$existing_branch_name" ] && branch_name="$existing_branch_name"
  local project_name
  project_name="$(jq -r '.project // empty' "$STORIES_FILE")"
  [ -n "$project_name" ] || project_name="$(basename "$WORKSPACE_ROOT")"
  local story_dir specify_dir has_speckit
  story_dir="$(dirname "$story_path_abs")"
  specify_dir="$story_dir/.specify"
  has_speckit=0
  local command_map_json command_map_text prep_context_path prep_fingerprint existing_prep_fingerprint existing_generate_fingerprint
  command_map_json="$(build_project_command_map_json "$WORKSPACE_ROOT")"
  command_map_text="$(format_command_map_for_prompt "$command_map_json")"
  prep_context_path="$(story_prep_context_path "$story_dir")"
  prep_fingerprint="$(compute_story_prep_fingerprint \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "" \
    "$command_map_json" \
    "$depends_on_arr" \
    "" \
    "")"
  existing_prep_fingerprint="$(read_story_prep_fingerprint "$prep_context_path")"
  existing_generate_fingerprint="$(read_story_generate_fingerprint "$prep_context_path")"
  if [ -n "$existing_prep_fingerprint" ]; then
    prep_fingerprint="$existing_prep_fingerprint"
  fi

  if [ ! -f "$prep_context_path" ]; then
    write_story_prep_context \
      "$prep_context_path" \
      "$story_id" \
      "$sprint" \
      "$title" \
      "$goal" \
      "$prompt_context" \
      "" \
      "$command_map_json" \
      "$depends_on_arr" \
      "" \
      "" \
      "$prep_fingerprint" \
      '[]'
  fi
  if [ ! -f "$(story_prep_bundle_context_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_commands_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_dependencies_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_schema_path "$story_dir")" ]; then
    write_story_prep_bundle \
      "$story_dir" \
      "$story_id" \
      "$sprint" \
      "$title" \
      "$goal" \
      "$prompt_context" \
      "" \
      "$command_map_json" \
      "$depends_on_arr" \
      '[]' \
      "$(jq -c '.dependencyStories // []' "$prep_context_path" 2>/dev/null || printf '[]')" \
      "$prep_fingerprint"
  fi

  if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ] && [ -n "$existing_generate_fingerprint" ] && [ "$existing_generate_fingerprint" = "$prep_fingerprint" ]; then
    echo "story.json up to date for $story_id (prep fingerprint match)"
    prep_record_stage "$story_id" "generate" "skipped" "story.json up to date (prep fingerprint match)" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
    return 0
  fi
  if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
    fail "story.json already exists: $story_path_abs
  Use --force to overwrite."
  fi

  # Check for SpecKit artifacts (.specify/ in story directory)
  [ -f "$specify_dir/spec.md" ] && [ -f "$specify_dir/tasks.md" ] && has_speckit=1

  # Pull compact dependency handoff from the prep bundle when available.
  local dependency_bundle_json dep_context=""
  dependency_bundle_json="$(jq -c '.dependencyStories // []' "$prep_context_path" 2>/dev/null || printf '[]')"
  dep_context="$(
    printf '%s\n' "$dependency_bundle_json" | jq -r '
      .[]?
      | "Prior story \(.storyId) (\(.title)):\n"
        + (if (.files // []) | length > 0 then "  Files: " + ((.files // []) | join(", ")) + "\n" else "" end)
        + (if (.invariants // "") != "" then "  Invariants: " + .invariants + "\n" else "" end)
        + (if (.notes // "") != "" then "  Notes: " + .notes + "\n" else "" end)
    ' 2>/dev/null || true
  )"

  local dep_section=""
  [ -n "$dep_context" ] && dep_section="Prior story results (dependencies):
$dep_context"

  local skill_instruction
  if [ "$has_speckit" -eq 1 ]; then
    skill_instruction="Use the SpecKit artifacts as the primary source:
- $specify_dir/spec.md
- $specify_dir/plan.md
- $specify_dir/tasks.md"
  elif [ "$placeholder_recovery" -eq 1 ]; then
    if [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
      skill_instruction="Legacy migration placeholder detected — recover the story plan from the preserved PRD markdown.
Primary source PRD markdown: $existing_prd_abs

Use the story-generate skill and replace the placeholder entirely with a real story.json plan."
    else
      skill_instruction="Legacy migration placeholder detected, but the preserved PRD markdown is unavailable.
Recover the story plan from the backlog metadata below, using goal and planning context as the primary source.

Use the story-generate skill and replace the placeholder entirely with a real story.json plan."
    fi
  else
    skill_instruction="No SpecKit artifacts found.
Use the story-generate skill for schema and task design rules."
  fi

  local placeholder_section=""
  if [ "$placeholder_recovery" -eq 1 ]; then
    placeholder_section="Migration recovery:
- Existing story.json is a migration placeholder and should be fully replaced.
- Preserve storyId: $story_id
- Preserve branchName: $branch_name"
    if [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
      placeholder_section="$placeholder_section
- Primary source markdown: $existing_prd_ref"
    else
      placeholder_section="$placeholder_section
- Primary source markdown unavailable; recover from goal and planning context."
    fi
  fi

  local prompt
  prompt="$(cat <<GENPROMPT
Generate story.json for $story_id.

Backlog: $project_name / $story_id / $title / sprint=$sprint / priority=$priority / effort=$effort
Goal: $goal
Context: $prompt_context
Depends on: $depends_on_arr

$dep_section
$placeholder_section
$skill_instruction

Write the completed story.json to: $story_path_abs
Prep context: $prep_context_path
Prep bundle context: $(story_prep_bundle_context_path "$story_dir")
Prep bundle dependencies: $(story_prep_bundle_dependencies_path "$story_dir")
Prep bundle commands: $(story_prep_bundle_commands_path "$story_dir")
Prep bundle schema: $(story_prep_bundle_schema_path "$story_dir")

Verification commands:
$command_map_text

Requirements:
1. Use verification commands above; do not rediscover.
2. Prep bundle schema is authoritative for story.json shape. Keep exact top-level shape.
3. Set project=$project_name, sprint=$sprint, priority=$priority, depends_on=$depends_on_arr, status=planned, passes=false, branchName=$branch_name.
4. spec.scope is concise string. Task scope[] has repo-relative file paths. Task acceptance is single string. context is self-contained for fresh Codex session.
5. Create parent directory if needed. Do not commit.
6. Do not read Ralph framework docs or scripts for schema unless prep bundle schema is missing a required fact.
7. Do not read .prep-context.json, package.json, jest.config.ts, or tsconfig.json when prep bundle and SpecKit artifacts already provide schema, commands, and dependency handoff.
8. Do not narrate your plan or summarize your work.
GENPROMPT
)"

  if [ "$dry_run" -eq 1 ]; then
    if [ "$placeholder_recovery" -eq 1 ] && [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
      echo "=== DRY RUN: deterministic migration recovery for $story_id ==="
      echo "Markdown source: $existing_prd_abs"
      echo "Output path:      $story_path_abs"
      echo "Branch name:      $branch_name"
      echo "Fallback:         guided Codex generation if markdown structure is unsupported"
      return 0
    fi
    echo "=== DRY RUN: generate prompt for $story_id ==="
    printf '%s\n' "$prompt"
    echo "=== Would write to: $story_path_abs ==="
    return 0
  fi

  local stage_started_at stage_duration_ms
  stage_started_at="$(epoch_seconds)"
  echo "Generating story.json for $story_id..."
  prep_record_stage "$story_id" "generate" "running" "Generating story container" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
  mkdir -p "$(dirname "$story_path_abs")"
  local deterministic_recovery=0 prd_bridge_recovery=0 fallback_reason="" temp_bridge_prd=""
  if [ "$placeholder_recovery" -eq 1 ] && [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
    if parse_legacy_markdown_story_json \
      "$existing_prd_abs" \
      "$story_path_abs" \
      "$story_id" \
      "$title" \
      "$goal" \
      "$branch_name" \
      "$sprint" \
      "$priority" \
      "$depends_on_arr" \
      "$project_name"; then
      deterministic_recovery=1
      echo "Recovered migration placeholder for $story_id from legacy PRD markdown."
    else
      echo "WARN: deterministic markdown recovery could not parse $existing_prd_ref; trying temporary prd.json bridge."
      temp_bridge_prd="$(mktemp "${TMPDIR:-/tmp}/ralph-prd-bridge.XXXXXX.json")"
      if bridge_markdown_to_prd_json \
        "$existing_prd_abs" \
        "$temp_bridge_prd" \
        "$branch_name" \
        "$project_name" \
        "$title" \
        "$goal" \
        && build_story_json_from_prd_json \
          "$temp_bridge_prd" \
          "$story_path_abs" \
          "$story_id" \
          "$title" \
          "$goal" \
          "$branch_name" \
          "$sprint" \
          "$priority" \
          "$depends_on_arr" \
          "$project_name" \
          "$existing_prd_abs"; then
        prd_bridge_recovery=1
        echo "Recovered migration placeholder for $story_id through temporary prd.json bridge."
      else
        fallback_reason="Preserved PRD markdown could not be deterministically parsed or bridged through prd.json; guided fallback recovery was used."
        echo "WARN: temporary prd.json bridge recovery could not complete for $existing_prd_ref; falling back to guided generation."
      fi
    fi
  elif [ "$placeholder_recovery" -eq 1 ]; then
    fallback_reason="Preserved PRD markdown was unavailable; guided fallback recovery was used."
  fi

  if [ "$deterministic_recovery" -eq 0 ] && [ "$prd_bridge_recovery" -eq 0 ]; then
    codex_exec_prompt "$prompt" "$WORKSPACE_ROOT"
  fi

  if [ ! -f "$story_path_abs" ]; then
    fail "story.json was not written to: $story_path_abs"
  fi
  normalize_story_container "$story_path_abs"
  validate_story_container_file "$story_path_abs" "$story_id" "$sprint"
  if ! jq -e '.tasks | length > 0' "$story_path_abs" >/dev/null 2>&1; then
    fail "Generated story.json has no tasks: $story_path_abs"
  fi
  if ! jq -e '.storyId' "$story_path_abs" >/dev/null 2>&1; then
    fail "Generated story.json is missing storyId: $story_path_abs"
  fi

  if [ -n "$temp_bridge_prd" ] && [ -f "$temp_bridge_prd" ]; then
    rm -f "$temp_bridge_prd"
  fi

  if [ "$placeholder_recovery" -eq 1 ] && [ "$prd_bridge_recovery" -eq 1 ]; then
    mark_prd_bridge_migration_recovery "$story_path_abs" "$existing_prd_ref"
    echo "Annotated $story_id with temporary prd.json bridge provenance."
  elif [ "$placeholder_recovery" -eq 1 ] && [ "$deterministic_recovery" -eq 0 ]; then
    mark_guided_migration_recovery "$story_path_abs" "$fallback_reason" "$existing_prd_ref"
    echo "Annotated $story_id with guided migration recovery provenance."
  fi

  if [ "$placeholder_recovery" -eq 1 ]; then
    local tmp
    tmp="$(mktemp)"
    jq --arg id "$story_id" '
      .stories = (
        .stories
        | map(
            if .id == $id and .status == "blocked" then
              .status = "planned"
            else
              .
            end
          )
      )
    ' "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"
    echo "Recovered migration placeholder for $story_id; story status reset to planned."
  fi

  local task_count
  task_count="$(jq '.tasks | length' "$story_path_abs")"
  stage_duration_ms="$(( ($(epoch_seconds) - stage_started_at) * 1000 ))"
  write_story_generate_provenance "$prep_context_path" "$prep_fingerprint" "story.json" "$raw_path"
  prep_record_stage "$story_id" "generate" "passed" "Generated $task_count tasks" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" "$stage_duration_ms"
  echo "Generated: $raw_path ($task_count tasks)"
  echo "Run './ralph-story.sh health $story_id' to validate."
}

# ---------------------------------------------------------------------------
# import-prd
# ---------------------------------------------------------------------------

cmd_import_prd() {
  resolve_stories_file

  local prd_path="${1:-}"
  [ -n "$prd_path" ] || prd_path="$SCRIPT_DIR/prd.json"
  [ -f "$prd_path" ] || fail "PRD file not found: $prd_path"

  jq -e '.userStories | length > 0' "$prd_path" >/dev/null 2>&1 || \
    fail "No userStories[] found in $prd_path"

  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint."

  local imported=0 skipped=0

  while IFS= read -r us_json; do
    local us_id us_title us_desc us_ac us_priority us_passes
    us_id="$(printf '%s' "$us_json" | jq -r '.id')"
    us_title="$(printf '%s' "$us_json" | jq -r '.title // ""')"
    us_desc="$(printf '%s' "$us_json" | jq -r '.description // ""')"
    us_ac="$(printf '%s' "$us_json" | jq -r '(.acceptanceCriteria // []) | join(". ")')"
    us_priority="$(printf '%s' "$us_json" | jq -r '.priority // 99')"
    us_passes="$(printf '%s' "$us_json" | jq -r '.passes // false')"

    if [ "$us_passes" = "true" ]; then
      echo "SKIP $us_id (passes=true): $us_title"
      skipped=$((skipped + 1))
      continue
    fi

    # Auto-assign next S-NNN from current max
    local max_n=0
    while IFS= read -r existing_id; do
      local raw_n="${existing_id#S-}"
      if [[ "$raw_n" =~ ^[0-9]+$ ]]; then
        local n=$(( 10#$raw_n ))
        [ "$n" -gt "$max_n" ] && max_n="$n"
      fi
    done < <(jq -r '.stories[].id' "$STORIES_FILE")
    local new_id
    new_id="$(printf 'S-%03d' $((max_n + 1)))"
    local dest_rel="${SCRIPT_DIR#${WORKSPACE_ROOT}/}"
    local story_path="$dest_rel/sprints/$active_sprint/stories/$new_id/story.json"

    local tmp
    tmp="$(mktemp)"
    jq \
      --arg id "$new_id" \
      --arg title "$us_title" \
      --argjson priority "$us_priority" \
      --arg status "planned" \
      --arg goal "$us_desc" \
      --arg ctx "$us_ac" \
      --arg path "$story_path" \
      '.stories += [{
        "id": $id,
        "title": $title,
        "priority": $priority,
        "effort": 3,
        "planningSource": "prd-import",
        "status": $status,
        "depends_on": [],
        "story_path": $path,
        "goal": $goal,
        "promptContext": $ctx
      }]' \
      "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"

    echo "Imported $us_id → $new_id: $us_title"
    imported=$((imported + 1))
  done < <(jq -c '.userStories[]' "$prd_path")

  echo ""
  echo "Imported: $imported  Skipped (done): $skipped"
  if [ "$imported" -gt 0 ]; then
    echo "Next: run './ralph-story.sh specify <ID>' for each story to run SpecKit analysis and create task containers."
  fi
}

# ---------------------------------------------------------------------------
# specify
# ---------------------------------------------------------------------------

cmd_specify() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh specify <ID> [--dry-run] [--force] [--no-generate]"
  shift || true
  local dry_run=0 force=0 no_generate=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     dry_run=1;     shift ;;
      --force)       force=1;       shift ;;
      --no-generate) no_generate=1; shift ;;
      *) fail "Unknown specify option: $1" ;;
    esac
  done

  resolve_stories_file

  local story_meta
  story_meta="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE")"
  [ -n "$story_meta" ] || fail "Story $story_id not found in $STORIES_FILE"

  local raw_path
  raw_path="$(printf '%s' "$story_meta" | jq -r '.story_path // empty')"
  [ -n "$raw_path" ] || fail "story_path not set for $story_id"

  local story_path_abs story_dir specify_dir
  [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"
  story_dir="$(dirname "$story_path_abs")"
  specify_dir="$story_dir/.specify"
  local repo_briefing_abs repo_briefing_rel
  repo_briefing_abs="$(ensure_repo_briefing "$WORKSPACE_ROOT")"
  repo_briefing_rel="${repo_briefing_abs#$WORKSPACE_ROOT/}"
  local story_focus_text story_focus_hints=""

  # Detect specify binary — required, no fallback
  local specify_bin=""
  specify_bin="$(find_specify_bin)" || fail "'specify' CLI not found and 'npx specify' unavailable.
  Install the CLI: uv tool install git+https://github.com/github/spec-kit.git
  Or use:          npx --yes specify version
  Or re-run: bash install.sh --install-speckit"
  echo "SpecKit: $specify_bin"

  # Extract story metadata
  local title goal prompt_context effort sprint priority depends_on_arr
  title="$(printf '%s' "$story_meta" | jq -r '.title // ""')"
  goal="$(printf '%s' "$story_meta" | jq -r '.goal // ""')"
  prompt_context="$(printf '%s' "$story_meta" | jq -r '.promptContext // ""')"
  effort="$(printf '%s' "$story_meta" | jq -r '.effort // 3')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint" "$story_id"
  priority="$(printf '%s' "$story_meta" | jq -r '.priority // 1')"
  depends_on_arr="$(printf '%s' "$story_meta" | jq -c '.depends_on // []')"
  story_focus_text="$(printf '%s\n%s\n%s\n' "$title" "$goal" "$prompt_context")"
  story_focus_hints="$(collect_story_focus_hints "$WORKSPACE_ROOT" "$story_focus_text" || true)"
  ensure_prep_run_dir "$sprint" "specify" >/dev/null

  # Pull dependency context (spec fields + compact story handoff) for SpecKit input
  local dep_context="" dependency_bundle_json='[]'
  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local dep_raw_path dep_abs_path dep_title dep_scope dep_invariants dep_files dep_note dep_entry
    dep_raw_path="$(jq -r --arg d "$dep_id" '.stories[] | select(.id == $d) | .story_path // ""' "$STORIES_FILE" 2>/dev/null || true)"
    [ -n "$dep_raw_path" ] || continue
    [[ "$dep_raw_path" != /* ]] && dep_abs_path="$WORKSPACE_ROOT/$dep_raw_path" || dep_abs_path="$dep_raw_path"
    [ -f "$dep_abs_path" ] || continue
    dep_title="$(jq -r '.title // ""' "$dep_abs_path" 2>/dev/null || true)"
    dep_scope="$(jq -r '.spec.scope // ""' "$dep_abs_path" 2>/dev/null || true)"
    dep_invariants="$(jq -r '(.spec.preserved_invariants // []) | join("; ")' "$dep_abs_path" 2>/dev/null || true)"
    dep_files="$(jq -r 'if (.story_handoff // null) != null then ((.story_handoff.files_touched // []) | join(", ")) else ([.tasks[].scope[]?] | unique | join(", ")) end' "$dep_abs_path" 2>/dev/null || true)"
    dep_files="$(sanitize_dep_file_list "$dep_files")"
    dep_note="$(jq -r '
      if (.story_handoff // null) != null then
        "Contracts added: " + ((.story_handoff.contracts_added // []) | join(", ")) + "\n" +
        "Residual risks: " + ((.story_handoff.residual_risks // []) | join("; "))
      else
        ""
      end
    ' "$dep_abs_path" 2>/dev/null || true)"
    dep_entry=""
    dep_scope="$(compact_text "$dep_scope" 180)"
    dep_files="$(compact_list "$dep_files" 4)"
    dep_invariants="$(compact_text "$dep_invariants" 180)"
    dep_note="$(compact_text "$dep_note" 160)"
    if [ -n "$dep_scope" ]; then dep_entry="${dep_entry}  Scope: $dep_scope"$'\n'; fi
    if [ -n "$dep_files" ]; then dep_entry="${dep_entry}  Files: $dep_files"$'\n'; fi
    if [ -n "$dep_invariants" ]; then dep_entry="${dep_entry}  Invariants: $dep_invariants"$'\n'; fi
    if [ -n "$dep_note" ]; then dep_entry="${dep_entry}  Notes: $dep_note"$'\n'; fi
    [ -n "$dep_entry" ] || continue
    dependency_bundle_json="$(
      jq -nc \
        --arg id "$dep_id" \
        --arg title "$dep_title" \
        --arg scope "$dep_scope" \
        --arg files "$dep_files" \
        --arg invariants "$dep_invariants" \
        --arg notes "$dep_note" \
        --argjson current "$dependency_bundle_json" \
        '$current + [{
          storyId: $id,
          title: $title,
          scope: $scope,
          files: ($files | split(", ") | map(select(length > 0 and . != "..."))),
          invariants: $invariants,
          notes: $notes
        }]'
    )"
    dep_context="${dep_context}
Prior story $dep_id ($dep_title):
$dep_entry"
  done < <(printf '%s' "$story_meta" | jq -r '.depends_on[]?' 2>/dev/null)

  local command_map_json prep_context_path
  command_map_json="$(build_project_command_map_json "$WORKSPACE_ROOT")"
  prep_context_path="$(story_prep_context_path "$story_dir")"
  local prep_fingerprint existing_fingerprint
  prep_fingerprint="$(compute_story_prep_fingerprint \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_abs" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$story_focus_hints" \
    "$dep_context")"
  existing_fingerprint="$(read_story_prep_fingerprint "$prep_context_path")"

  if [ "$dry_run" -eq 1 ]; then
    echo "=== DRY RUN: specify for $story_id ==="
    echo "Binary:      $specify_bin"
    echo "Specify dir: $specify_dir"
    echo "Title:       $title"
    echo "Goal:        $goal"
    echo "Fingerprint: $prep_fingerprint"
    return 0
  fi

  local stage_started_at stage_duration_ms
  stage_started_at="$(epoch_seconds)"

  # Short-circuit if artifacts already exist and prep inputs are unchanged
  if specify_artifacts_complete "$specify_dir" && [ "$force" -eq 0 ] && [ -n "$existing_fingerprint" ] && [ "$existing_fingerprint" = "$prep_fingerprint" ]; then
    if [ ! -f "$(story_prep_bundle_context_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_commands_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_dependencies_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_schema_path "$story_dir")" ]; then
      write_story_prep_bundle \
        "$story_dir" \
        "$story_id" \
        "$sprint" \
        "$title" \
        "$goal" \
        "$prompt_context" \
        "$repo_briefing_rel" \
        "$command_map_json" \
        "$depends_on_arr" \
        "$(focus_hints_to_json "$story_focus_hints")" \
        "$(jq -c '.dependencyStories // []' "$prep_context_path" 2>/dev/null || printf '[]')" \
        "$prep_fingerprint"
    fi
    echo "SpecKit artifacts up to date for $story_id (fingerprint match)"
    prep_record_stage "$story_id" "specify" "skipped" "Artifacts up to date (fingerprint match)" "$(jq -nc --arg dir "$specify_dir" --arg prep "$prep_context_path" '[$dir, $prep]')" 0
    if [ "$no_generate" -eq 0 ]; then
      if [ ! -f "$story_path_abs" ]; then
        local gen_args=()
        [ "$dry_run" -eq 1 ] && gen_args+=(--dry-run)
        cmd_generate "$story_id" "${gen_args[@]}"
      else
        if [ "$(read_story_generate_fingerprint "$prep_context_path")" = "$prep_fingerprint" ]; then
          echo "story.json up to date for $story_id (prep fingerprint match)"
          prep_record_stage "$story_id" "generate" "skipped" "story.json up to date (prep fingerprint match)" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
        else
          echo "story.json already exists for $story_id — skipping generate."
        fi
      fi
    fi
    return 0
  fi

  # Clear existing artifacts when --force is set
  if [ "$force" -eq 1 ] && [ -d "$specify_dir" ]; then
    rm -rf "$specify_dir"
    echo "Cleared existing SpecKit artifacts for $story_id"
  fi

  mkdir -p "$specify_dir"
  write_story_prep_context \
    "$prep_context_path" \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_rel" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$story_focus_hints" \
    "$dep_context" \
    "$prep_fingerprint" \
    "$dependency_bundle_json"
  write_story_prep_bundle \
    "$story_dir" \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_rel" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$(focus_hints_to_json "$story_focus_hints")" \
    "$dependency_bundle_json" \
    "$prep_fingerprint"

  # Write SpecKit feature input file
  cat > "$specify_dir/input.md" <<SPECIN
# Feature: $title

## What to Build
$goal

## Context and Constraints
$prompt_context

## Story Metadata
- Story ID: $story_id
- Sprint: $sprint
- Priority: $priority
- Effort (story points): $effort
- Depends on: $depends_on_arr

## Repo Briefing
- Start with: $repo_briefing_rel

## Resolved Verification Commands
$(format_command_map_for_prompt "$command_map_json")
SPECIN

  if [ -n "$dep_context" ]; then
    printf '\n## Prior Story Results\n%s\n' "$dep_context" >> "$specify_dir/input.md"
  fi

  if [ -n "$story_focus_hints" ]; then
    printf '\n## Likely Implementation Files\n%s\n' "$story_focus_hints" >> "$specify_dir/input.md"
  fi

  local word_count
  word_count=$(wc -w < "$specify_dir/input.md")
  if [ "$word_count" -lt 30 ]; then
    echo "WARN: input.md is thin ($word_count words) — consider adding more detail to story goal and promptContext."
  fi

  # Trim dep_context to avoid unbounded prep bundle growth
  local trimmed_dep_context="$dep_context"
  if [ "${#trimmed_dep_context}" -gt 1800 ]; then
    trimmed_dep_context="$(printf '%s' "$trimmed_dep_context" | head -c 1800)"
    trimmed_dep_context="$trimmed_dep_context"$'\n... (truncated)'
  fi

  local speckit_prompt
  speckit_prompt="$(cat <<SKPROMPT
Run the SpecKit workflow for this story and complete all three phases without pausing.

Feature input file: $specify_dir/input.md
Repo briefing file: $repo_briefing_rel
Prep bundle context: $(story_prep_bundle_context_path "$story_dir")
Prep bundle dependencies: $(story_prep_bundle_dependencies_path "$story_dir")
Prep bundle commands: $(story_prep_bundle_commands_path "$story_dir")

Use the repo briefing, input.md, and prep bundle as the primary context.
Do not read Ralph framework files such as scripts/ralph/README-local.md, scripts/ralph/doctor.sh, or scripts/ralph/lib/specify.sh unless the prep bundle is missing a required fact.
Do not reread package.json, jest.config.ts, or tsconfig.json when the repo briefing and prep bundle already provide the needed commands, aliases, or project shape. Only inspect them when this story needs exact config semantics.
Do not inspect node_modules, bundled framework docs, or generated framework documentation unless local source files and config still leave a required framework rule ambiguous.
Keep any extra file inspection tightly scoped to the likely implementation area, nearest tests, and directly relevant config.
Do not narrate your plan, summarize your work, or restate constraints.

Phase 1 — Specify:
Write output to: $specify_dir/spec.md

Phase 2 — Plan:
Write output to: $specify_dir/plan.md

Phase 3 — Tasks:
Write output to: $specify_dir/tasks.md

All three files must be written before finishing. Avoid repeated repo summaries. Do not commit.
SKPROMPT
)"

  echo "Running SpecKit analysis for $story_id (phases: specify → plan → tasks)..."
  prep_record_stage "$story_id" "specify" "running" "Running SpecKit workflow" "$(jq -nc --arg dir "$specify_dir" --arg prep "$prep_context_path" '[$dir, $prep]')" 0
  codex_exec_prompt "$speckit_prompt" "$WORKSPACE_ROOT"

  # Validate artifacts
  local missing=0
  for artifact in spec.md plan.md tasks.md; do
    [ -f "$specify_dir/$artifact" ] || { echo "WARN: SpecKit did not produce $artifact"; missing=$((missing + 1)); }
  done

  if [ "$missing" -gt 0 ]; then
    fail "SpecKit did not produce all required artifacts ($missing missing). Check the Codex session log and re-run with --force."
  fi

  stage_duration_ms="$(( ($(epoch_seconds) - stage_started_at) * 1000 ))"
  prep_record_stage "$story_id" "specify" "passed" "SpecKit artifacts created" "$(jq -nc --arg spec "$specify_dir/spec.md" --arg plan "$specify_dir/plan.md" --arg tasks "$specify_dir/tasks.md" --arg prep "$prep_context_path" '[$spec, $plan, $tasks, $prep]')" "$stage_duration_ms"
  echo "SpecKit artifacts written: $specify_dir/{spec.md,plan.md,tasks.md}"

  if [ "$no_generate" -eq 0 ]; then
    local gen_args=()
    [ "$force" -eq 1 ] && gen_args+=(--force)
    cmd_generate "$story_id" "${gen_args[@]}"
  fi
}

# ---------------------------------------------------------------------------
# specify-all / generate-all / health-all / prepare-all
# ---------------------------------------------------------------------------

cmd_specify_all() {
  resolve_stories_file
  local force=0 jobs=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --jobs)  jobs="${2:-1}"; shift 2 ;;
      *) fail "Unknown specify-all option: $1" ;;
    esac
  done
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint_name" "specify-all"
  ensure_prep_run_dir "$sprint_name" "specify-all" >/dev/null

  local force_flag=()
  [ "$force" -eq 1 ] && force_flag+=(--force)

  local pending=() skipped=0
  while IFS= read -r sid; do
    local raw_path story_path_abs specify_dir
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"
    specify_dir="$(dirname "$story_path_abs")/.specify"
    if story_is_unrecovered_migration_placeholder "$story_path_abs"; then
      echo "SKIP $sid: migration placeholder (recover in generate phase)"
      prep_record_stage "$sid" "specify" "skipped" "Migration placeholder deferred to generate phase" "$(jq -nc --arg dir "$specify_dir" '[$dir]')" 0
      skipped=$((skipped + 1))
      continue
    fi
    if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
      echo "SKIP $sid: story.json exists"
      prep_record_stage "$sid" "specify" "skipped" "story.json already exists" "$(jq -nc --arg path "$raw_path" '[$path]')" 0
      skipped=$((skipped + 1))
      continue
    fi
    pending+=("$sid")
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  local count=0 failed=0 total="${#pending[@]}"
  if [ "$total" -eq 0 ]; then
    echo "specify-all: nothing to do ($skipped skipped)."; return 0
  fi

  local i=0
  while [ "$i" -lt "$total" ]; do
    local batch_end=$(( i + jobs ))
    [ "$batch_end" -gt "$total" ] && batch_end="$total"
    local batch=("${pending[@]:$i:$(( batch_end - i ))}")

    if [ "$jobs" -le 1 ]; then
      local sid="${batch[0]}"
      local logf
      logf="$(prep_stage_log_path "$sid" "specify")"
      echo "=== specify $sid ==="
      if cmd_specify "$sid" "${force_flag[@]+"${force_flag[@]}"}" > "$logf" 2>&1; then
        count=$((count + 1))
      else
        echo "WARN: specify failed for $sid"; failed=$((failed + 1))
      fi
      cat "$logf"
    else
      local pids=() logs=() sids=()
      for sid in "${batch[@]}"; do
        local logf; logf="$(prep_stage_log_path "$sid" "specify")"
        ( cmd_specify "$sid" "${force_flag[@]+"${force_flag[@]}"}" ) > "$logf" 2>&1 &
        pids+=($!); logs+=("$logf"); sids+=("$sid")
      done
      local j rc
      for j in "${!pids[@]}"; do
        wait "${pids[$j]}" && rc=0 || rc=$?
        echo "=== specify ${sids[$j]} ==="
        cat "${logs[$j]}"; rm -f "${logs[$j]}"
        [ "$rc" -eq 0 ] && count=$((count + 1)) \
          || { echo "WARN: specify failed for ${sids[$j]}"; failed=$((failed + 1)); }
      done
    fi
    i="$batch_end"
  done

  echo ""
  echo "specify-all: $count processed, $skipped skipped, $failed failed."
  [ "$failed" -eq 0 ] || return 1
}

cmd_generate_all() {
  resolve_stories_file
  local force=0 jobs=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --jobs)  jobs="${2:-1}"; shift 2 ;;
      *) fail "Unknown generate-all option: $1" ;;
    esac
  done
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint_name" "generate-all"
  ensure_prep_run_dir "$sprint_name" "generate-all" >/dev/null

  local force_flag=()
  [ "$force" -eq 1 ] && force_flag+=(--force)

  local pending=() placeholder_pending=() skipped=0
  while IFS= read -r sid; do
    local raw_path story_path_abs specify_dir prep_context_path prep_fingerprint generate_fingerprint
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    story_path_abs="$(resolve_repo_relative_path "$raw_path")"
    specify_dir="$(dirname "$story_path_abs")/.specify"
    prep_context_path="$(story_prep_context_path "$(dirname "$story_path_abs")")"
    prep_fingerprint="$(read_story_prep_fingerprint "$prep_context_path")"
    generate_fingerprint="$(read_story_generate_fingerprint "$prep_context_path")"

    if [ ! -f "$specify_dir/spec.md" ] && ! { [ "$force" -eq 1 ] && story_is_unrecovered_migration_placeholder "$story_path_abs"; }; then
      echo "SKIP $sid: no SpecKit artifacts (run specify-all first)"
      prep_record_stage "$sid" "generate" "skipped" "No SpecKit artifacts available" "$(jq -nc --arg dir "$specify_dir" '[$dir]')" 0
      skipped=$((skipped + 1))
      continue
    fi

    if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
      if [ -n "$prep_fingerprint" ] && [ "$prep_fingerprint" = "$generate_fingerprint" ]; then
        echo "SKIP $sid: story.json up to date (prep fingerprint match)"
        prep_record_stage "$sid" "generate" "skipped" "story.json up to date (prep fingerprint match)" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
      else
        echo "SKIP $sid: story.json exists (use --force to overwrite)"
        prep_record_stage "$sid" "generate" "skipped" "story.json already exists" "$(jq -nc --arg path "$raw_path" '[$path]')" 0
      fi
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$force" -eq 1 ] && story_is_unrecovered_migration_placeholder "$story_path_abs"; then
      placeholder_pending+=("$sid")
    else
      pending+=("$sid")
    fi
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  local count=0 failed=0 total=$(( ${#pending[@]} + ${#placeholder_pending[@]} ))
  if [ "$total" -eq 0 ]; then
    echo "generate-all: nothing to do ($skipped skipped)."
    return 0
  fi

  if [ "${#placeholder_pending[@]}" -gt 0 ]; then
    echo "generate-all: processing ${#placeholder_pending[@]} migration placeholder(s) serially to keep stories.json updates safe."
    local sid
    for sid in "${placeholder_pending[@]}"; do
      local logf
      logf="$(prep_stage_log_path "$sid" "generate")"
      echo "=== generate $sid ==="
      if cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}" > "$logf" 2>&1; then
        count=$((count + 1))
      else
        echo "WARN: generate failed for $sid"
        failed=$((failed + 1))
      fi
      cat "$logf"
    done
  fi

  total="${#pending[@]}"
  if [ "$total" -eq 0 ]; then
    echo ""
    echo "generate-all: $count generated, $skipped skipped, $failed failed."
    [ "$failed" -eq 0 ] || return 1
    return 0
  fi

  local i=0
  while [ "$i" -lt "$total" ]; do
    local batch_end=$(( i + jobs ))
    [ "$batch_end" -gt "$total" ] && batch_end="$total"
    local batch=("${pending[@]:$i:$(( batch_end - i ))}")

    if [ "$jobs" -le 1 ]; then
      local sid="${batch[0]}"
      local logf
      logf="$(prep_stage_log_path "$sid" "generate")"
      echo "=== generate $sid ==="
      if cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}" > "$logf" 2>&1; then
        count=$((count + 1))
      else
        echo "WARN: generate failed for $sid"
        failed=$((failed + 1))
      fi
      cat "$logf"
    else
      local pids=() logs=() sids=()
      for sid in "${batch[@]}"; do
        local logf
        logf="$(prep_stage_log_path "$sid" "generate")"
        ( cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}" ) > "$logf" 2>&1 &
        pids+=($!)
        logs+=("$logf")
        sids+=("$sid")
      done
      local j=0
      for pid in "${pids[@]}"; do
        local sid="${sids[$j]}" logf="${logs[$j]}"
        echo "=== generate ${sid} ==="
        if wait "$pid"; then
          count=$((count + 1))
        else
          echo "WARN: generate failed for ${sid}"
          failed=$((failed + 1))
        fi
        cat "$logf"
        rm -f "$logf"
        j=$((j + 1))
      done
    fi

    i="$batch_end"
  done

  echo ""
  echo "generate-all: $count generated, $skipped skipped, $failed failed."
  [ "$failed" -eq 0 ] || return 1
}

cmd_prepare_all() {
  local force_flag=() jobs=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force_flag+=(--force); shift ;;
      --jobs)  jobs="${2:-1}"; shift 2 ;;
      *) fail "Unknown prepare-all option: $1" ;;
    esac
  done

  resolve_stories_file
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint_name" "prepare-all"
  ensure_prep_run_dir "$sprint_name" "prepare-all" >/dev/null

  local specify_failed=0 generate_failed=0
  echo "=== prepare-all: specify ==="
  if ! cmd_specify_all "${force_flag[@]+"${force_flag[@]}"}" --jobs "$jobs"; then
    specify_failed=1
  fi
  echo ""
  echo "=== prepare-all: generate ==="
  if ! cmd_generate_all "${force_flag[@]+"${force_flag[@]}"}" --jobs "$jobs"; then
    generate_failed=1
  fi
  echo ""
  echo "=== prepare-all: health + promote ==="
  local promoted=0 health_failed=0
  while IFS= read -r sid; do
    local raw_path story_path_abs
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"

    if _health_story "$sid"; then
      # Only promote planned stories that have a valid story.json
      local cur_status
      cur_status="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .status' "$STORIES_FILE")"
      if [ "$cur_status" = "planned" ] && [ -f "$story_path_abs" ] \
          && jq -e '.tasks | length > 0' "$story_path_abs" >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg id "$sid" '(.stories[] | select(.id == $id) | .status) = "ready"' "$STORIES_FILE" > "$tmp"
        mv "$tmp" "$STORIES_FILE"
        promoted=$((promoted + 1))
      fi
    else
      health_failed=$((health_failed + 1))
    fi
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  echo ""
  [ "$promoted" -gt 0 ]      && echo "Promoted $promoted story/stories to ready."
  [ "$health_failed" -gt 0 ] && echo "WARN: $health_failed story/stories have health issues — fix before mark-ready."

  # Auto-mark sprint ready when all active stories are ready
  local not_ready_count
  not_ready_count="$(jq '[.stories[] | select((.status != "done") and (.status != "abandoned") and (.status != "ready"))] | length' "$STORIES_FILE")"
  local current_sprint_status
  current_sprint_status="$(jq -r '.status // "planned"' "$STORIES_FILE")"
  if [ "$not_ready_count" -eq 0 ] && [ "$current_sprint_status" = "planned" ]; then
    local tmp
    tmp="$(mktemp)"
    jq '.status = "ready"' "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"
    echo "All stories ready — sprint automatically marked ready."
    echo "To activate: ./ralph-sprint.sh use <sprint-name>"
  fi

  local final_status="passed"
  if [ "$specify_failed" -ne 0 ] || [ "$generate_failed" -ne 0 ] || [ "$health_failed" -ne 0 ]; then
    final_status="failed"
  fi
  prep_finalize_summary "$final_status"
  echo "Prep summary: $(prep_summary_path)"
  [ "$final_status" = "passed" ] || return 1
}

cmd_prep_status() {
  resolve_stories_file
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"

  local requested_sprint="" story_id="" details=0 story_limit=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sprint)
        requested_sprint="${2:-}"
        [ -n "$requested_sprint" ] || fail "Missing value for --sprint"
        shift 2
        ;;
      --story)
        story_id="${2:-}"
        [ -n "$story_id" ] || fail "Missing value for --story"
        shift 2
        ;;
      --details)
        details=1
        shift
        ;;
      --story-limit)
        story_limit="${2:-}"
        [ -n "$story_limit" ] || fail "Missing value for --story-limit"
        [[ "$story_limit" =~ ^[1-9][0-9]*$ ]] || fail "--story-limit must be a positive integer"
        shift 2
        ;;
      *)
        fail "Unknown prep-status option: $1"
        ;;
    esac
  done

  [ -n "$requested_sprint" ] && sprint_name="$requested_sprint"
  require_story_sprint "$sprint_name" "prep-status"

  local summary_path
  summary_path="$(latest_prep_summary_for_sprint "$sprint_name" || true)"
  [ -n "$summary_path" ] && [ -f "$summary_path" ] || fail "No prep run journal found for sprint '$sprint_name'."

  local mode status started_at finished_at story_count passed_count failed_count skipped_count running_count total_duration_ms
  mode="$(jq -r '.mode // "prep"' "$summary_path" 2>/dev/null || echo "prep")"
  status="$(jq -r '.status // "running"' "$summary_path" 2>/dev/null || echo "running")"
  started_at="$(jq -r '.started_at // ""' "$summary_path" 2>/dev/null || true)"
  finished_at="$(jq -r '.finished_at // ""' "$summary_path" 2>/dev/null || true)"
  story_count="$(jq -r '(.stories // {}) | length' "$summary_path" 2>/dev/null || echo 0)"
  passed_count="$(jq -r '.metrics.passed_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  failed_count="$(jq -r '.metrics.failed_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  skipped_count="$(jq -r '.metrics.skipped_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  running_count="$(jq -r '.metrics.running_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  total_duration_ms="$(jq -r '.metrics.total_duration_ms // 0' "$summary_path" 2>/dev/null || echo 0)"

  echo "Prep sprint: $sprint_name"
  echo "Prep mode: $mode"
  echo "Prep status: $status"
  [ -n "$started_at" ] && echo "Prep started: $started_at"
  [ -n "$finished_at" ] && echo "Prep finished: $finished_at"
  echo "Prep stories: $story_count"
  echo "Prep metrics: passed=$passed_count failed=$failed_count skipped=$skipped_count running=$running_count duration-ms=$total_duration_ms"
  echo "Prep journal: $summary_path"

  local story_filter_json='null'
  if [ -n "$story_id" ]; then
    story_filter_json="$(jq -nc --arg story "$story_id" '$story')"
  fi

  jq -r \
    --argjson limit "$story_limit" \
    --argjson details "$details" \
    --argjson story_filter "$story_filter_json" '
    def selected_stories:
      (.stories // {})
      | to_entries
      | sort_by(.key)
      | if $story_filter == null then . else map(select(.key == $story_filter)) end
      | .[:$limit];
    selected_stories[]
    | .key as $story_id
    | .value as $stages
    | ($stages | to_entries | sort_by(.key) | map("\(.key)=\(.value.status // "unknown")") | join(", ")) as $compact
    | "Prep story " + $story_id + ": " + (if $compact == "" then "(no stages recorded)" else $compact end),
      (if $details == 1 then
         ($stages
          | to_entries
          | sort_by(.key)
          | .[]
          | "Prep detail " + $story_id + " " + .key + ": "
            + (.value.status // "unknown")
            + (if (.value.detail // "") == "" then "" else " - " + .value.detail end)
            + " (duration-ms=" + ((.value.duration_ms // 0) | tostring) + ", updated=" + (.value.updated_at // "unknown") + ")")
       else empty end)
  ' "$summary_path"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
  list)         cmd_list ;;
  show)         cmd_show "$@" ;;
  next)         cmd_next ;;
  next-id)      cmd_next_id ;;
  use)          cmd_use "$@" ;;
  start-next)   cmd_start_next ;;
  tasks)        cmd_tasks "$@" ;;
  set-status)   cmd_set_status "$@" ;;
  abandon)      cmd_abandon "$@" ;;
  health)       cmd_health "$@" ;;
  specify)      cmd_specify "$@" ;;
  specify-all)  cmd_specify_all "$@" ;;
  generate)     cmd_generate "$@" ;;
  generate-all) cmd_generate_all "$@" ;;
  health-all)   cmd_health_all ;;
  prepare-all)  cmd_prepare_all "$@" ;;
  prep-status)  cmd_prep_status "$@" ;;
  import-prd)   cmd_import_prd "$@" ;;
  import-story) cmd_import_story "$@" ;;
  add)          cmd_add "$@" ;;
  -h|--help|"") usage; exit 0 ;;
  *) fail "Unknown command: $CMD. Use --help for usage." ;;
esac
