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

fail() { echo "ERROR: $1" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq

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

find_specify_bin() {
  if command -v specify >/dev/null 2>&1; then
    echo "specify"; return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    if npx --yes specify version >/dev/null 2>&1; then
      echo "npx --yes specify"; return 0
    fi
  fi
  return 1
}

resolve_stories_file() {
  if [ -n "$STORIES_FILE" ]; then
    [ -f "$STORIES_FILE" ] || fail "Stories file not found: $STORIES_FILE"
    return
  fi

  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint. Use ralph-sprint.sh use <sprint-name>."

  STORIES_FILE="$SPRINTS_DIR/$active_sprint/stories.json"
  [ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$active_sprint'. Run ralph-sprint-migrate.sh or ralph-roadmap.sh first."
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
  import-prd [PATH]          Import prd.json userStories into sprint backlog
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

Import-prd options:
  PATH                       Path to prd.json (default: scripts/ralph/prd.json)

Add options:
  --id S-XXX                 Explicit story ID (default: next sequential)
  --title TEXT               Story title (required)
  --priority N               Priority (default: next available)
  --effort N                 Effort: 1, 2, 3, or 5 (default: 3)
  --status STATUS            planned|ready (default: planned)
  --depends-on IDS           Comma-separated dependency IDs
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

story_is_unrecovered_migration_placeholder() {
  local story_path="$1"
  [ -f "$story_path" ] || return 1
  jq -e '.migration.tasks_recovered == false' "$story_path" >/dev/null 2>&1
}

infer_checks_from_text() {
  local text="$1"
  local checks="[]"

  if printf '%s\n' "$text" | grep -Eqi '(^|[^[:alnum:]_])(typecheck|tsc|type check|type-check)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run typecheck"]')"
  fi
  if printf '%s\n' "$text" | grep -Eqi '(^|[^[:alnum:]_])(test|tests|jest|vitest|pytest|go test)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm test"]')"
  fi
  if printf '%s\n' "$text" | grep -Eqi '(^|[^[:alnum:]_])(lint|eslint)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run lint"]')"
  fi
  if printf '%s\n' "$text" | grep -Eqi '(^|[^[:alnum:]_])(build)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run build"]')"
  fi
  if printf '%s\n' "$text" | grep -Eqi 'verify in browser|playwright|cypress|verification'; then
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
    printf '%s\n' "$text" | grep -oE '`[^`]+`' | tr -d '`' || true
    printf '%s\n' "$text" | grep -oE '([A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+' || true
    printf '%s\n' "$text" | grep -oE '([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+' || true
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

  if ! printf '%s\n' "$user_stories_body" | grep -Eq '^(### ([Ss]tory[[:space:]]+[0-9]+:|[0-9]+[.)][[:space:]]+|[^#].+)|[Ss]tory[[:space:]]+[[:alnum:]]+([:.-][[:space:]].*)?)'; then
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

  # Warn if any dependency has no done_note (downstream task context will be thin)
  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local dep_raw dep_abs dep_note
    dep_raw="$(jq -r --arg d "$dep_id" '.stories[] | select(.id == $d) | .story_path // ""' "$STORIES_FILE" 2>/dev/null || true)"
    [ -n "$dep_raw" ] || continue
    [[ "$dep_raw" != /* ]] && dep_abs="$WORKSPACE_ROOT/$dep_raw" || dep_abs="$dep_raw"
    [ -f "$dep_abs" ] || continue
    dep_note="$(jq -r '.done_note // ""' "$dep_abs" 2>/dev/null || true)"
    if [ -z "$dep_note" ]; then
      echo "WARN: Dependency $dep_id has no done_note — task context for this story will be thin."
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
  echo "$valid_statuses" | grep -qw "$new_status" || fail "Invalid status '$new_status'. Valid: $valid_statuses"

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

  # Tasks with identical check sets (likely redundant)
  local dup_task_sets
  dup_task_sets="$(jq -r '
    .tasks |
    map({id: .id, checks: (.checks // [] | sort)}) |
    group_by(.checks) |
    map(select(length > 1) | map(.id) | join(", ")) |
    .[]
  ' "$story_path" 2>/dev/null || true)"
  if [ -n "$dup_task_sets" ]; then
    while IFS= read -r set; do
      [ -z "$set" ] && continue
      echo "  [DUP]  Tasks share identical check sets: $set"
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
  local new_depends=""
  local new_goal=""
  local new_prompt_context=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)             new_id="${2:-}"; shift 2 ;;
      --title)          new_title="${2:-}"; shift 2 ;;
      --priority)       new_priority="${2:-}"; shift 2 ;;
      --effort)         new_effort="${2:-3}"; shift 2 ;;
      --status)         new_status="${2:-planned}"; shift 2 ;;
      --depends-on)     new_depends="${2:-}"; shift 2 ;;
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
  local deps_json="[]"
  if [ -n "$new_depends" ]; then
    deps_json="$(echo "$new_depends" | tr ',' '\n' | jq -R . | jq -s .)"
  fi

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
      "depends_on": $depends,
      "story_path": $path,
      "goal": $goal,
      "promptContext": $ctx
    }]' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Added story: $new_id — $new_title"
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

  if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
    fail "story.json already exists: $story_path_abs
  Use --force to overwrite."
  fi

  local title goal prompt_context effort sprint priority depends_on_arr
  title="$(printf '%s' "$story_meta" | jq -r '.title // ""')"
  goal="$(printf '%s' "$story_meta" | jq -r '.goal // ""')"
  prompt_context="$(printf '%s' "$story_meta" | jq -r '.promptContext // ""')"
  effort="$(printf '%s' "$story_meta" | jq -r '.effort // 3')"
  priority="$(printf '%s' "$story_meta" | jq -r '.priority // 1')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  [ -n "$sprint" ] || sprint="$(get_active_sprint 2>/dev/null || echo "sprint-1")"
  depends_on_arr="$(printf '%s' "$story_meta" | jq -c '.depends_on // []')"

  local branch_name="ralph/$sprint/story-$story_id"
  [ -n "$existing_branch_name" ] && branch_name="$existing_branch_name"
  local project_name
  project_name="$(jq -r '.project // empty' "$STORIES_FILE")"
  [ -n "$project_name" ] || project_name="$(basename "$WORKSPACE_ROOT")"

  # Check for SpecKit artifacts (.specify/ in story directory)
  local story_dir specify_dir has_speckit
  story_dir="$(dirname "$story_path_abs")"
  specify_dir="$story_dir/.specify"
  has_speckit=0
  [ -f "$specify_dir/spec.md" ] && [ -f "$specify_dir/tasks.md" ] && has_speckit=1

  # Pull done_notes from dependent stories for context injection
  local dep_context=""
  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local dep_raw_path dep_abs_path dep_title dep_note
    dep_raw_path="$(jq -r --arg d "$dep_id" '.stories[] | select(.id == $d) | .story_path // ""' "$STORIES_FILE" 2>/dev/null || true)"
    [ -n "$dep_raw_path" ] || continue
    [[ "$dep_raw_path" != /* ]] && dep_abs_path="$WORKSPACE_ROOT/$dep_raw_path" || dep_abs_path="$dep_raw_path"
    [ -f "$dep_abs_path" ] || continue
    dep_title="$(jq -r '.title // ""' "$dep_abs_path" 2>/dev/null || true)"
    dep_note="$(jq -r '.done_note // ""' "$dep_abs_path" 2>/dev/null || true)"
    [ -n "$dep_note" ] || continue
    dep_context="${dep_context}
Prior story $dep_id ($dep_title):
$dep_note
"
  done < <(printf '%s' "$story_meta" | jq -r '.depends_on[]?' 2>/dev/null)

  local dep_section=""
  [ -n "$dep_context" ] && dep_section="Prior story results (dependencies):
$dep_context"

  local skill_instruction
  if [ "$has_speckit" -eq 1 ]; then
    skill_instruction="SpecKit analysis artifacts are available — use them as the primary source:
  spec.md:  $specify_dir/spec.md
  plan.md:  $specify_dir/plan.md
  tasks.md: $specify_dir/tasks.md

Use the story-specify skill to convert these artifacts into story.json."
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
## Generate story.json for $story_id

Story backlog entry:
- ID: $story_id
- Title: $title
- Sprint: $sprint
- Priority: $priority
- Effort: $effort
- Goal: $goal
- Planning context: $prompt_context
- depends_on: $depends_on_arr

$dep_section
$placeholder_section
$skill_instruction

Write the completed story.json to: $story_path_abs

Requirements:
1. Read package.json to find real script names for typecheck, lint, test, and build.
2. scope[] must contain real file paths (verify they exist or will be created).
3. context must be self-contained for a fresh isolated Codex session.
4. branchName: $branch_name
5. Create the parent directory if needed.
6. Do not commit.
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

  echo "Generating story.json for $story_id..."
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

  # Detect specify binary — required, no fallback
  local specify_bin=""
  specify_bin="$(find_specify_bin)" || fail "'specify' CLI not found and 'npx specify' unavailable.
  Install: uvx --from git+https://github.com/github/spec-kit.git specify init <PROJECT>
  Or:      npx specify init <PROJECT>
  Or re-run: bash install.sh --install-speckit"
  echo "SpecKit: $specify_bin"

  # Short-circuit if artifacts already exist and --force not set
  if [ -f "$specify_dir/spec.md" ] && [ -f "$specify_dir/tasks.md" ] && [ "$force" -eq 0 ]; then
    echo "SpecKit artifacts already exist for $story_id (use --force to regenerate)"
    if [ "$no_generate" -eq 0 ]; then
      if [ ! -f "$story_path_abs" ]; then
        local gen_args=()
        [ "$dry_run" -eq 1 ] && gen_args+=(--dry-run)
        cmd_generate "$story_id" "${gen_args[@]}"
      else
        echo "story.json already exists for $story_id — skipping generate."
      fi
    fi
    return 0
  fi

  # Extract story metadata
  local title goal prompt_context effort sprint priority depends_on_arr
  title="$(printf '%s' "$story_meta" | jq -r '.title // ""')"
  goal="$(printf '%s' "$story_meta" | jq -r '.goal // ""')"
  prompt_context="$(printf '%s' "$story_meta" | jq -r '.promptContext // ""')"
  effort="$(printf '%s' "$story_meta" | jq -r '.effort // 3')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  [ -n "$sprint" ] || sprint="$(get_active_sprint 2>/dev/null || echo "sprint-1")"
  priority="$(printf '%s' "$story_meta" | jq -r '.priority // 1')"
  depends_on_arr="$(printf '%s' "$story_meta" | jq -c '.depends_on // []')"

  # Pull dependency context (spec fields + done_notes) for SpecKit input
  local dep_context=""
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
    dep_files="$(jq -r '([.tasks[].scope[]?] | unique | join(", "))' "$dep_abs_path" 2>/dev/null || true)"
    dep_note="$(jq -r '.done_note // ""' "$dep_abs_path" 2>/dev/null || true)"
    dep_entry=""
    if [ -n "$dep_scope" ]; then dep_entry="${dep_entry}  Scope: $dep_scope"$'\n'; fi
    if [ -n "$dep_files" ]; then dep_entry="${dep_entry}  Files changed: $dep_files"$'\n'; fi
    if [ -n "$dep_invariants" ]; then dep_entry="${dep_entry}  Preserved invariants: $dep_invariants"$'\n'; fi
    if [ -n "$dep_note" ]; then dep_entry="${dep_entry}  Completion summary: $dep_note"$'\n'; fi
    [ -n "$dep_entry" ] || continue
    dep_context="${dep_context}
Prior story $dep_id ($dep_title):
$dep_entry"
  done < <(printf '%s' "$story_meta" | jq -r '.depends_on[]?' 2>/dev/null)

  if [ "$dry_run" -eq 1 ]; then
    echo "=== DRY RUN: specify for $story_id ==="
    echo "Binary:      $specify_bin"
    echo "Specify dir: $specify_dir"
    echo "Title:       $title"
    echo "Goal:        $goal"
    return 0
  fi

  # Clear existing artifacts when --force is set
  if [ "$force" -eq 1 ] && [ -d "$specify_dir" ]; then
    rm -rf "$specify_dir"
    echo "Cleared existing SpecKit artifacts for $story_id"
  fi

  mkdir -p "$specify_dir"

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
SPECIN

  if [ -n "$dep_context" ]; then
    printf '\n## Prior Story Results\n%s\n' "$dep_context" >> "$specify_dir/input.md"
  fi

  local word_count
  word_count=$(wc -w < "$specify_dir/input.md")
  if [ "$word_count" -lt 30 ]; then
    echo "WARN: input.md is thin ($word_count words) — consider adding more detail to story goal and promptContext."
  fi

  local speckit_prompt
  speckit_prompt="$(cat <<SKPROMPT
Run the SpecKit specification workflow for this story. No human approval gates — proceed automatically through all three phases in sequence.

Feature input file: $specify_dir/input.md

Phase 1 — Specify:
Use the SpecKit specify skill to analyse the feature input and produce a structured specification.
Write output to: $specify_dir/spec.md

Phase 2 — Plan:
Use the SpecKit plan skill on spec.md to produce a technical implementation plan with file decisions.
Write output to: $specify_dir/plan.md

Phase 3 — Tasks:
Use the SpecKit tasks skill on spec.md and plan.md to produce an executable, phased task list.
Write output to: $specify_dir/tasks.md

All three files must be written before finishing. Do not commit.
SKPROMPT
)"

  echo "Running SpecKit analysis for $story_id (phases: specify → plan → tasks)..."
  codex_exec_prompt "$speckit_prompt" "$WORKSPACE_ROOT"

  # Validate artifacts
  local missing=0
  for artifact in spec.md plan.md tasks.md; do
    [ -f "$specify_dir/$artifact" ] || { echo "WARN: SpecKit did not produce $artifact"; missing=$((missing + 1)); }
  done

  if [ "$missing" -gt 0 ]; then
    fail "SpecKit did not produce all required artifacts ($missing missing). Check the Codex session log and re-run with --force."
  fi

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
      skipped=$((skipped + 1))
      continue
    fi
    if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
      echo "SKIP $sid: story.json exists"
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
      echo "=== specify $sid ==="
      if cmd_specify "$sid" "${force_flag[@]+"${force_flag[@]}"}"; then
        count=$((count + 1))
      else
        echo "WARN: specify failed for $sid"; failed=$((failed + 1))
      fi
    else
      local pids=() logs=() sids=()
      for sid in "${batch[@]}"; do
        local logf; logf="$(mktemp)"
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

  local force_flag=()
  [ "$force" -eq 1 ] && force_flag+=(--force)

  local pending=() placeholder_pending=() skipped=0
  while IFS= read -r sid; do
    local raw_path story_path_abs specify_dir
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    story_path_abs="$(resolve_repo_relative_path "$raw_path")"
    specify_dir="$(dirname "$story_path_abs")/.specify"

    if [ ! -f "$specify_dir/spec.md" ] && ! { [ "$force" -eq 1 ] && story_is_unrecovered_migration_placeholder "$story_path_abs"; }; then
      echo "SKIP $sid: no SpecKit artifacts (run specify-all first)"
      skipped=$((skipped + 1))
      continue
    fi

    if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
      echo "SKIP $sid: story.json exists (use --force to overwrite)"
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
      echo "=== generate $sid ==="
      if cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}"; then
        count=$((count + 1))
      else
        echo "WARN: generate failed for $sid"
        failed=$((failed + 1))
      fi
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
      echo "=== generate $sid ==="
      if cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}"; then
        count=$((count + 1))
      else
        echo "WARN: generate failed for $sid"
        failed=$((failed + 1))
      fi
    else
      local pids=() logs=() sids=()
      for sid in "${batch[@]}"; do
        local logf
        logf="$(mktemp)"
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

  echo "=== prepare-all: specify ==="
  cmd_specify_all "${force_flag[@]+"${force_flag[@]}"}" --jobs "$jobs" || true
  echo ""
  echo "=== prepare-all: generate ==="
  cmd_generate_all "${force_flag[@]+"${force_flag[@]}"}" --jobs "$jobs" || true
  echo ""
  echo "=== prepare-all: health + promote ==="
  resolve_stories_file
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
  [ "$health_failed" -eq 0 ] || return 1

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
  import-prd)   cmd_import_prd "$@" ;;
  add)          cmd_add "$@" ;;
  -h|--help|"") usage; exit 0 ;;
  *) fail "Unknown command: $CMD. Use --help for usage." ;;
esac
