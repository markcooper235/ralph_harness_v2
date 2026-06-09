#!/bin/bash
# Generic Ralph framework self-test runner.
#
# This script is intended to remain framework-generic so it can be backported
# to the install repo. Repo-specific routing tests should live in a separate
# wrapper script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
SELFTEST_SPRINT="sprint-framework-selftest"
TEMP_ROOT=""
WORKTREE_DIR=""
WORKTREE_BRANCH=""
WORKTREE_BASE_BRANCH=""
ARTIFACT_DIR=""
SELFTEST_TMP_BASE="${RALPH_SELFTEST_TMP_BASE:-$HOME/.cache}"
KEEP_WORKTREE=0
EXERCISE_PREP=0
HEARTBEAT_INTERVAL="${RALPH_HEARTBEAT_INTERVAL_SECONDS:-5}"
RALPH_FREE_MODE="${RALPH_FREE_MODE:-0}"
SELFTEST_LOOP_DISABLE_COMPOSITES="${RALPH_SELFTEST_LOOP_DISABLE_COMPOSITES:-0}"
export RALPH_FREE_MODE

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-framework-selftest.sh [options]

Runs a disposable end-to-end Ralph framework self-test in a temporary git
worktree. Validates:
  - doctor/profile preview truthfulness
  - deterministic explicit generic agent routing
  - composite strategy prompt injection
  - project-local runtime home isolation
  - live status/runtime observability
  - loop execution, merge-back, and sprint closeout

Options:
  --exercise-prepare   Also run prepare-all on a generated micro sprint
  --disable-composites-loop Disable composite orchestration during the live loop
  --keep-worktree      Keep the temporary worktree for inspection
  -h, --help           Show help
EOF
}

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

cleanup() {
  local exit_code=$?
  set +e
  if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ] && [ "$KEEP_WORKTREE" -eq 0 ]; then
    git -C "$REPO_ROOT" worktree remove -f "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORKTREE_BRANCH" ] && git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
    git -C "$REPO_ROOT" branch -D "$WORKTREE_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORKTREE_BASE_BRANCH" ] && git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$WORKTREE_BASE_BRANCH"; then
    git -C "$REPO_ROOT" branch -D "$WORKTREE_BASE_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ] && [ "$KEEP_WORKTREE" -eq 0 ]; then
    rm -rf "$TEMP_ROOT"
  fi
  exit "$exit_code"
}

run() {
  log "+ $*"
  "$@"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    fail "$label missing expected text: $pattern"
  fi
}

assert_json_value() {
  local file="$1"
  local expr="$2"
  local label="$3"
  if ! jq -e "$expr" "$file" >/dev/null 2>&1; then
    fail "$label failed JSON assertion: $expr"
  fi
}

copy_project_env_if_present() {
  if [ -f "$SCRIPT_DIR/.ralph-env" ]; then
    cp "$SCRIPT_DIR/.ralph-env" "$WORKTREE_DIR/scripts/ralph/.ralph-env"
    return 0
  fi
  if [ -f "$HOME/.ralph-env" ]; then
    cp "$HOME/.ralph-env" "$WORKTREE_DIR/scripts/ralph/.ralph-env"
    return 0
  fi
  fail "No .ralph-env available for framework self-test."
}

prune_stale_selftest_worktrees() {
  local worktree_path branch_ref
  while IFS=$'\t' read -r worktree_path branch_ref; do
    [ -n "$worktree_path" ] || continue
    case "$worktree_path" in
      */ralph-framework-selftest.*)
        log "Pruning stale self-test worktree: $worktree_path"
        git -C "$REPO_ROOT" worktree remove -f "$worktree_path" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(
    git -C "$REPO_ROOT" worktree list --porcelain \
      | awk '
          /^worktree / { worktree=$2; branch="" }
          /^branch / { branch=$2 }
          /^$/ { if (worktree != "") { print worktree "\t" branch } worktree=""; branch="" }
          END { if (worktree != "") { print worktree "\t" branch } }
        '
  )
}

prune_stale_selftest_story_branches() {
  local stories_root="$WORKTREE_DIR/scripts/ralph/backlog/$SELFTEST_SPRINT/stories"
  [ -d "$stories_root" ] || return 0

  local story_file story_branch
  while IFS= read -r story_file; do
    [ -n "$story_file" ] || continue
    story_branch="$(jq -r '.branchName // empty' "$story_file" 2>/dev/null || true)"
    [ -n "$story_branch" ] || continue
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$story_branch"; then
      log "Dropping stale self-test story branch before activation: $story_branch"
      git -C "$REPO_ROOT" branch -D "$story_branch" >/dev/null 2>&1 || true
    fi
  done < <(find "$stories_root" -mindepth 2 -maxdepth 2 -name story.json | sort)
}

overlay_local_framework_tree() {
  rsync -a \
    --exclude 'runtime/' \
    --exclude '.active-sprint' \
    --exclude '.last-*' \
    --exclude '.ralph-env' \
    "$REPO_ROOT/scripts/ralph/" \
    "$WORKTREE_DIR/scripts/ralph/"

  for config_file in eslint.config.js jest.config.js jest.utility.config.js; do
    if [ -f "$REPO_ROOT/$config_file" ]; then
      cp "$REPO_ROOT/$config_file" "$WORKTREE_DIR/$config_file"
    fi
  done

  if [ -d "$REPO_ROOT/node_modules" ] && [ ! -e "$WORKTREE_DIR/node_modules" ]; then
    cp -a "$REPO_ROOT/node_modules" "$WORKTREE_DIR/"
  fi

  if [ -d "$REPO_ROOT/data" ]; then
    mkdir -p "$WORKTREE_DIR/data"
    find "$REPO_ROOT/data" -maxdepth 1 -name '*.db' -exec cp -a {} "$WORKTREE_DIR/data/" \;
  fi
}

seed_fixture_files() {
  mkdir -p "$WORKTREE_DIR/scripts/ralph/selftest-fixtures"
  cat > "$WORKTREE_DIR/scripts/ralph/selftest-fixtures/framework-report.md" <<'EOF'
# Framework Self-Test Report

This report is generated by the disposable Ralph framework self-test sprint.
EOF
  cat > "$WORKTREE_DIR/scripts/ralph/selftest-fixtures/state-sample.json" <<'EOF'
{
  "status": "todo",
  "owner": "nobody"
}
EOF
  cat > "$WORKTREE_DIR/scripts/ralph/selftest-fixtures/quality-notes.md" <<'EOF'
# Quality Notes

Pending findings will be written here during the self-test.
EOF
}

write_story_files() {
  local sprint_dir="$WORKTREE_DIR/scripts/ralph/backlog/$SELFTEST_SPRINT"
  mkdir -p \
    "$sprint_dir/stories/S-901" \
    "$sprint_dir/stories/S-902" \
    "$sprint_dir/stories/S-903" \
    "$sprint_dir/stories/S-904" \
    "$sprint_dir/stories/S-905"

  cat > "$sprint_dir/stories.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "sprint": "sprint-framework-selftest",
  "title": "Framework Self-Test",
  "status": "planned",
  "capacityTarget": 8,
  "capacityCeiling": 10,
  "activeStoryId": null,
  "stories": [
    {
      "id": "S-901",
      "title": "Researcher smoke story",
      "priority": 1,
      "effort": 1,
      "planningSource": "selftest",
      "sourceRef": "framework-selftest",
      "status": "planned",
      "agent": "researcher",
      "depends_on": [],
      "story_path": "scripts/ralph/backlog/sprint-framework-selftest/stories/S-901/story.json",
      "goal": "Exercise the researcher profile deterministically.",
      "promptContext": "Research and investigation smoke validation for the Ralph framework."
    },
    {
      "id": "S-902",
      "title": "Senior developer smoke story",
      "priority": 2,
      "effort": 1,
      "planningSource": "selftest",
      "sourceRef": "framework-selftest",
      "status": "planned",
      "agent": "senior-dev",
      "depends_on": [
        "S-901"
      ],
      "story_path": "scripts/ralph/backlog/sprint-framework-selftest/stories/S-902/story.json",
      "goal": "Exercise the senior-dev profile deterministically.",
      "promptContext": "Architecture and refactor smoke validation for the Ralph framework."
    },
    {
      "id": "S-903",
      "title": "QA test smoke story",
      "priority": 3,
      "effort": 1,
      "planningSource": "selftest",
      "sourceRef": "framework-selftest",
      "status": "planned",
      "agent": "qa-test",
      "depends_on": [
        "S-902"
      ],
      "story_path": "scripts/ralph/backlog/sprint-framework-selftest/stories/S-903/story.json",
      "goal": "Exercise the qa-test profile deterministically.",
      "promptContext": "Test, verification, and acceptance smoke validation for the Ralph framework."
    },
    {
      "id": "S-904",
      "title": "Reviewer smoke story",
      "priority": 4,
      "effort": 1,
      "planningSource": "selftest",
      "sourceRef": "framework-selftest",
      "status": "planned",
      "agent": "reviewer",
      "depends_on": [
        "S-903"
      ],
      "story_path": "scripts/ralph/backlog/sprint-framework-selftest/stories/S-904/story.json",
      "goal": "Exercise the reviewer profile deterministically.",
      "promptContext": "Code review and regression risk smoke validation for the Ralph framework."
    },
    {
      "id": "S-905",
      "title": "Documentation smoke story",
      "priority": 5,
      "effort": 1,
      "planningSource": "selftest",
      "sourceRef": "framework-selftest",
      "status": "planned",
      "agent": "documentation",
      "depends_on": [
        "S-904"
      ],
      "story_path": "scripts/ralph/backlog/sprint-framework-selftest/stories/S-905/story.json",
      "goal": "Exercise the documentation profile deterministically.",
      "promptContext": "Documentation and explanation smoke validation for the Ralph framework."
    }
  ]
}
EOF

  cat > "$sprint_dir/stories/S-901/story.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "storyId": "S-901",
  "title": "Researcher smoke story",
  "description": "Create tiny research artifacts so the researcher profile and fanout strategy can be exercised end-to-end.",
  "branchName": "ralph/sprint-framework-selftest/story-S-901",
  "sprint": "sprint-framework-selftest",
  "priority": 1,
  "depends_on": [],
  "agent": "researcher",
  "status": "planned",
  "spec": {
    "scope": "Touch only self-test fixture artifacts under scripts/ralph/selftest-fixtures.",
    "preserved_invariants": [
      "Do not change application source files during the framework self-test."
    ],
    "out_of_scope": [
      "Any product behavior changes."
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Seed a tiny research note",
      "context": "Append a new section titled '## Research notes' to scripts/ralph/selftest-fixtures/framework-report.md and include one sentence mentioning investigation findings.",
      "scope": [
        "scripts/ralph/selftest-fixtures/framework-report.md"
      ],
      "acceptance": "The framework report includes the research notes section and mentions investigation findings.",
      "checks": [
        "rg -q '^## Research notes$' scripts/ralph/selftest-fixtures/framework-report.md",
        "rg -q 'investigation findings' scripts/ralph/selftest-fixtures/framework-report.md"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
EOF

  cat > "$sprint_dir/stories/S-902/story.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "storyId": "S-902",
  "title": "Senior developer smoke story",
  "description": "Correct a tiny self-test state sample so the senior-dev profile and implement-verify workflow are exercised end-to-end.",
  "branchName": "ralph/sprint-framework-selftest/story-S-902",
  "sprint": "sprint-framework-selftest",
  "priority": 2,
  "depends_on": [
    "S-901"
  ],
  "agent": "senior-dev",
  "status": "planned",
  "spec": {
    "scope": "Touch only the self-test state sample and report artifacts.",
    "preserved_invariants": [
      "No application code changes."
    ],
    "out_of_scope": [
      "Any real feature work."
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Correct the tiny state sample",
      "context": "Update scripts/ralph/selftest-fixtures/state-sample.json so status is done and owner is framework-selftest.",
      "scope": [
        "scripts/ralph/selftest-fixtures/state-sample.json"
      ],
      "acceptance": "The tiny state sample shows status done and owner framework-selftest.",
      "checks": [
        "jq -e '.status == \"done\" and .owner == \"framework-selftest\"' scripts/ralph/selftest-fixtures/state-sample.json"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
EOF

  cat > "$sprint_dir/stories/S-903/story.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "storyId": "S-903",
  "title": "QA test smoke story",
  "description": "Create a tiny verification artifact so the qa-test profile is exercised end-to-end.",
  "branchName": "ralph/sprint-framework-selftest/story-S-903",
  "sprint": "sprint-framework-selftest",
  "priority": 3,
  "depends_on": [
    "S-902"
  ],
  "agent": "qa-test",
  "status": "planned",
  "spec": {
    "scope": "Touch only self-test verification artifacts.",
    "preserved_invariants": [
      "No application code changes."
    ],
    "out_of_scope": [
      "Real test harness changes."
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create a tiny verification snapshot",
      "context": "Create scripts/ralph/selftest-fixtures/verification-snapshot.json with verified set to true and scope set to selftest.",
      "scope": [
        "scripts/ralph/selftest-fixtures/verification-snapshot.json"
      ],
      "acceptance": "A tiny verification snapshot exists with verified true and scope selftest.",
      "checks": [
        "test -f scripts/ralph/selftest-fixtures/verification-snapshot.json",
        "jq -e '.verified == true and .scope == \"selftest\"' scripts/ralph/selftest-fixtures/verification-snapshot.json"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
EOF

  cat > "$sprint_dir/stories/S-904/story.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "storyId": "S-904",
  "title": "Reviewer smoke story",
  "description": "Create a tiny review artifact so the reviewer profile is exercised end-to-end.",
  "branchName": "ralph/sprint-framework-selftest/story-S-904",
  "sprint": "sprint-framework-selftest",
  "priority": 4,
  "depends_on": [
    "S-903"
  ],
  "agent": "reviewer",
  "status": "planned",
  "spec": {
    "scope": "Touch only self-test review artifacts.",
    "preserved_invariants": [
      "No application code changes."
    ],
    "out_of_scope": [
      "Real code review findings."
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Write a tiny review note",
      "context": "Append a line to scripts/ralph/selftest-fixtures/quality-notes.md mentioning regression risk and missing tests.",
      "scope": [
        "scripts/ralph/selftest-fixtures/quality-notes.md"
      ],
      "acceptance": "The quality notes mention both regression risk and missing tests.",
      "checks": [
        "rg -qi 'regression risk' scripts/ralph/selftest-fixtures/quality-notes.md",
        "rg -qi 'missing tests' scripts/ralph/selftest-fixtures/quality-notes.md"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
EOF

  cat > "$sprint_dir/stories/S-905/story.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "storyId": "S-905",
  "title": "Documentation smoke story",
  "description": "Create a tiny workflow summary so the documentation profile is exercised end-to-end.",
  "branchName": "ralph/sprint-framework-selftest/story-S-905",
  "sprint": "sprint-framework-selftest",
  "priority": 5,
  "depends_on": [
    "S-904"
  ],
  "agent": "documentation",
  "status": "planned",
  "spec": {
    "scope": "Touch only self-test documentation artifacts.",
    "preserved_invariants": [
      "No application code changes."
    ],
    "out_of_scope": [
      "Real docs updates."
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create a tiny workflow summary",
      "context": "Create scripts/ralph/selftest-fixtures/workflow-summary.json with documented true and profile documentation.",
      "scope": [
        "scripts/ralph/selftest-fixtures/workflow-summary.json"
      ],
      "acceptance": "The workflow summary JSON exists with documented true and profile documentation.",
      "checks": [
        "test -f scripts/ralph/selftest-fixtures/workflow-summary.json",
        "jq -e '.documented == true and .profile == \"documentation\"' scripts/ralph/selftest-fixtures/workflow-summary.json"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
EOF
}

write_prepare_smoke_sprint() {
  local prep_sprint="sprint-framework-prepare-selftest"
  local sprint_dir="$WORKTREE_DIR/scripts/ralph/backlog/$prep_sprint"
  mkdir -p "$sprint_dir"
  cat > "$sprint_dir/stories.json" <<'EOF'
{
  "version": 1,
  "project": "framework-selftest",
  "sprint": "sprint-framework-prepare-selftest",
  "title": "Framework Prepare Self-Test",
  "status": "planned",
  "capacityTarget": 8,
  "capacityCeiling": 10,
  "activeStoryId": null,
  "stories": [
    {
      "id": "S-991",
      "title": "Research prepare smoke",
      "priority": 1,
      "effort": 1,
      "planningSource": "selftest",
      "sourceRef": "framework-selftest",
      "status": "planned",
      "agent": "researcher",
      "depends_on": [],
      "story_path": "scripts/ralph/backlog/sprint-framework-prepare-selftest/stories/S-991/story.json",
      "goal": "Exercise prepare-all while preserving an explicit researcher assignment.",
      "promptContext": "Research and investigation prepare smoke test for deterministic agent routing."
    }
  ]
}
EOF
}

run_prepare_smoke_if_requested() {
  [ "$EXERCISE_PREP" -eq 1 ] || return 0
  log "Running optional prepare-all smoke..."
  write_prepare_smoke_sprint
  (
    cd "$WORKTREE_DIR"
    RALPH_HEARTBEAT_INTERVAL_SECONDS="$HEARTBEAT_INTERVAL" ./scripts/ralph/ralph-story.sh prepare-all --sprint sprint-framework-prepare-selftest --jobs 1
  )
  local story_path="$WORKTREE_DIR/scripts/ralph/backlog/sprint-framework-prepare-selftest/stories/S-991/story.json"
  [ -f "$story_path" ] || fail "prepare-all did not generate story.json for S-991"
  assert_json_value "$story_path" '.agent == "researcher"' "prepare-all preserved explicit agent"

  rm -rf "$WORKTREE_DIR/scripts/ralph/backlog/sprint-framework-prepare-selftest"
  rm -rf "$WORKTREE_DIR/scripts/ralph/runtime/prep-runs"
}

snapshot_worktree_for_loop() {
  if [ -n "$(git -C "$WORKTREE_DIR" status --short 2>/dev/null || true)" ]; then
    log "Snapshotting disposable worktree before loop start."
    git -C "$WORKTREE_DIR" add -A
    git -C "$WORKTREE_DIR" commit -m "chore(selftest): snapshot framework under test" >/dev/null
  fi
  WORKTREE_BASE_BRANCH="framework-selftest-base-$(date +%Y%m%d%H%M%S)"
  git -C "$WORKTREE_DIR" checkout -b "$WORKTREE_BASE_BRANCH" >/dev/null
  log "Created temporary self-test base branch: $WORKTREE_BASE_BRANCH"
}

validate_doctor_output() {
  local output="$ARTIFACT_DIR/doctor.out"
  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/doctor.sh > "$output"
  )
  assert_contains "$output" "OK: runtime home is project-local" "doctor output"
  assert_contains "$output" "composites: enabled" "doctor output"
}

validate_complexity_and_tier_matrix() {
  (
    cd "$WORKTREE_DIR"
    source ./scripts/ralph/lib/harness-exec.sh

    case "$(_story_complexity_tier_from_score 0)" in
      low) ;;
      *) fail "complexity tier mapping failed for score 0" ;;
    esac
    case "$(_story_complexity_tier_from_score 20)" in
      medium) ;;
      *) fail "complexity tier mapping failed for score 20" ;;
    esac
    case "$(_story_complexity_tier_from_score 40)" in
      high) ;;
      *) fail "complexity tier mapping failed for score 40" ;;
    esac
    case "$(_story_complexity_tier_from_score 60)" in
      extreme) ;;
      *) fail "complexity tier mapping failed for score 60" ;;
    esac

    local profile_json

    unset RALPH_HARNESS_OVERRIDE RALPH_HARNESS_SELECTION_SOURCE RALPH_PIAGENT_ROLE \
      RALPH_MODEL RALPH_MODEL_SELECTION_SOURCE RALPH_EXECUTION_TIER \
      RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
      RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
      RALPH_COMPOSITE_STEPS_JSON STORY_COMPLEXITY_SCORE STORY_COMPLEXITY_TIER \
      RALPH_STORY_COMPLEXITY_SCORE
    RALPH_STORY_COMPLEXITY_SCORE=0
    STORY_COMPLEXITY_SCORE=0
    STORY_COMPLEXITY_TIER=low
    _apply_agent_profile documentation
    profile_json="$(get_execution_profile_json documentation)"
    printf '%s' "$profile_json" | jq -e '
      .execution_tier == "simple"
      and .model == "gpt-5.4-mini"
      and .model_source == "agent-profile"
      and .composite_profile == null
    ' >/dev/null || fail "simple tier routing failed for documentation profile"

    unset RALPH_HARNESS_OVERRIDE RALPH_HARNESS_SELECTION_SOURCE RALPH_PIAGENT_ROLE \
      RALPH_MODEL RALPH_MODEL_SELECTION_SOURCE RALPH_EXECUTION_TIER \
      RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
      RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
      RALPH_COMPOSITE_STEPS_JSON STORY_COMPLEXITY_SCORE STORY_COMPLEXITY_TIER \
      RALPH_STORY_COMPLEXITY_SCORE
    RALPH_STORY_COMPLEXITY_SCORE=0
    STORY_COMPLEXITY_SCORE=0
    STORY_COMPLEXITY_TIER=low
    _apply_agent_profile reviewer
    profile_json="$(get_execution_profile_json reviewer)"
    printf '%s' "$profile_json" | jq -e '
      .harness == "piagent"
      and .harness_source == "composite-auto"
      and .execution_tier == "composite-lite"
      and .model == "gpt-5.4-mini"
      and .model_source == "agent-profile-lite"
      and .piagent_role == "reviewer"
      and .composite_profile == "chain_review_v1"
    ' >/dev/null || fail "composite-lite tier routing failed for reviewer low-complexity profile"

    unset RALPH_HARNESS_OVERRIDE RALPH_HARNESS_SELECTION_SOURCE RALPH_PIAGENT_ROLE \
      RALPH_MODEL RALPH_MODEL_SELECTION_SOURCE RALPH_EXECUTION_TIER \
      RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
      RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
      RALPH_COMPOSITE_STEPS_JSON STORY_COMPLEXITY_SCORE STORY_COMPLEXITY_TIER \
      RALPH_STORY_COMPLEXITY_SCORE
    RALPH_STORY_COMPLEXITY_SCORE=40
    STORY_COMPLEXITY_SCORE=40
    STORY_COMPLEXITY_TIER=high
    _apply_agent_profile reviewer
    profile_json="$(get_execution_profile_json reviewer)"
    printf '%s' "$profile_json" | jq -e '
      .harness == "piagent"
      and .harness_source == "composite-auto"
      and .execution_tier == "full-composite"
      and .model == "gpt-5.4"
      and .model_source == "complexity-tier-high"
      and .piagent_role == "reviewer"
      and .composite_profile == "chain_review_v1"
    ' >/dev/null || fail "full-composite tier routing failed for reviewer high-complexity profile"

    unset RALPH_HARNESS_OVERRIDE RALPH_HARNESS_SELECTION_SOURCE RALPH_PIAGENT_ROLE \
      RALPH_MODEL RALPH_MODEL_SELECTION_SOURCE RALPH_EXECUTION_TIER \
      RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
      RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
      RALPH_COMPOSITE_STEPS_JSON STORY_COMPLEXITY_SCORE STORY_COMPLEXITY_TIER \
      RALPH_STORY_COMPLEXITY_SCORE
    RALPH_STORY_COMPLEXITY_SCORE=60
    STORY_COMPLEXITY_SCORE=60
    STORY_COMPLEXITY_TIER=extreme
    _apply_agent_profile researcher
    profile_json="$(get_execution_profile_json researcher)"
    printf '%s' "$profile_json" | jq -e '
      .harness == "piagent"
      and .harness_source == "composite-auto"
      and .execution_tier == "full-composite"
      and .model == "gpt-5.5"
      and .model_source == "complexity-tier-extreme"
      and .piagent_role == "researcher"
      and .composite_profile == "fanout_research_v1"
    ' >/dev/null || fail "full-composite tier routing failed for researcher extreme-complexity profile"
  )
}

validate_dry_run_prompt() {
  local story_path="$1"
  local expect_profile_fragment="$2"
  local expect_composite="$3"
  local output_file="$4"
  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/ralph-story-run.sh --story "$story_path" --dry-run > "$output_file" 2>&1 || true
  )
  assert_contains "$output_file" "Execution profile:" "dry-run output"
  assert_contains "$output_file" "$expect_profile_fragment" "dry-run output"
  assert_contains "$output_file" "$expect_composite" "dry-run prompt"
  assert_contains "$output_file" "Composite strategy:" "dry-run prompt"
}

wait_for_live_status_and_isolation() {
  local status_file="$ARTIFACT_DIR/status-live.out"
  local env_file="$ARTIFACT_DIR/codex-env.out"
  local manifest_file=""
  local timeout_epoch=$(( $(date +%s) + 240 ))
  local harness_pid=""

  while [ "$(date +%s)" -lt "$timeout_epoch" ]; do
    (
      cd "$WORKTREE_DIR"
      ./scripts/ralph/ralph-status.sh > "$status_file" || true
    )
    manifest_file="$(find "$WORKTREE_DIR/scripts/ralph/runtime/story-runs" -name story-summary.json -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)"
    if [ -n "$manifest_file" ] && jq -e '.execution_profile.harness == "piagent" and .execution_profile.composites_enabled == true and (.execution_profile.runtime_home | type == "string")' "$manifest_file" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  [ -n "$manifest_file" ] || fail "Could not find live story summary in self-test worktree."
  assert_json_value "$manifest_file" '.execution_profile.harness == "piagent"' "live story summary"
  assert_json_value "$manifest_file" '.execution_profile.composites_enabled == true' "live story summary"
  assert_json_value "$manifest_file" '.execution_profile.runtime_home | type == "string"' "live story summary"

  if ! grep -q "Execution profile:" "$status_file" 2>/dev/null; then
    log "Live status did not surface Execution profile: before timeout; runtime manifest remains authoritative."
  fi

  timeout_epoch=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$timeout_epoch" ]; do
    harness_pid="$(pgrep -f "pi -p" | head -n1 || true)"
    [ -n "$harness_pid" ] && break
    sleep 1
  done
  if [ -n "$harness_pid" ] && [ -r "/proc/$harness_pid/environ" ]; then
    tr '\0' '\n' < "/proc/$harness_pid/environ" > "$env_file"
    assert_contains "$env_file" "HOME=$WORKTREE_DIR/scripts/ralph/runtime/home" "piagent child env"
    assert_contains "$env_file" "PI_CODING_AGENT_DIR=$WORKTREE_DIR/scripts/ralph/runtime/home/.pi/agent" "piagent child env"
  else
    log "Live piagent pid was not available before timeout; runtime manifest and prep output already confirm isolated runtime-home routing."
  fi
}

run_loop_and_closeout() {
  local selftest_stories_json="$WORKTREE_DIR/scripts/ralph/backlog/$SELFTEST_SPRINT/stories.json"
  if [ ! -f "$selftest_stories_json" ]; then
    log "Self-test sprint backlog missing; re-seeding $SELFTEST_SPRINT before loop start."
    write_story_files
  fi
  [ -f "$selftest_stories_json" ] || fail "Missing self-test sprint backlog: $selftest_stories_json"

  local selftest_sprint_branch="ralph/sprint/$SELFTEST_SPRINT"
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$selftest_sprint_branch"; then
    log "Dropping stale self-test sprint branch before activation: $selftest_sprint_branch"
    git -C "$REPO_ROOT" branch -D "$selftest_sprint_branch" >/dev/null 2>&1 || true
  fi

  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/ralph-sprint.sh mark-ready "$SELFTEST_SPRINT"
  )

  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/ralph-sprint.sh use "$SELFTEST_SPRINT"
  )

  (
    cd "$WORKTREE_DIR"
    RALPH_HEARTBEAT_INTERVAL_SECONDS="$HEARTBEAT_INTERVAL" \
    RALPH_DISABLE_COMPOSITES="$SELFTEST_LOOP_DISABLE_COMPOSITES" \
    ./scripts/ralph/ralph.sh > "$ARTIFACT_DIR/loop.out" 2>&1
  ) &
  local loop_pid=$!

  wait_for_live_status_and_isolation
  wait "$loop_pid"

  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/ralph-status.sh > "$ARTIFACT_DIR/status-final.out"
  )
  assert_contains "$ARTIFACT_DIR/status-final.out" "Loop: stopped" "final status"

  local stories_json="$WORKTREE_DIR/scripts/ralph/sprints/$SELFTEST_SPRINT/stories.json"
  assert_json_value "$stories_json" 'all(.stories[]; .status == "done")' "all self-test stories done"

  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/ralph-sprint-commit.sh > "$ARTIFACT_DIR/closeout.out" 2>&1
  )

  local closeout_status="$ARTIFACT_DIR/closeout-status.out"
  (
    cd "$WORKTREE_DIR"
    ./scripts/ralph/ralph-status.sh > "$closeout_status"
  )
  assert_contains "$closeout_status" "Active sprint: (none)" "post-closeout status"
  assert_contains "$closeout_status" "Loop: stopped" "post-closeout status"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --exercise-prepare) EXERCISE_PREP=1; shift ;;
      --disable-composites-loop) SELFTEST_LOOP_DISABLE_COMPOSITES=1; shift ;;
      --full-composite-loop) SELFTEST_LOOP_DISABLE_COMPOSITES=0; shift ;;
      --keep-worktree) KEEP_WORKTREE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_cmd git
  require_cmd jq
  require_cmd rg
  require_cmd mktemp
  require_cmd rsync

  mkdir -p "$SELFTEST_TMP_BASE"
  TEMP_ROOT="$(mktemp -d "$SELFTEST_TMP_BASE/ralph-framework-selftest.XXXXXX")"
  WORKTREE_DIR="$TEMP_ROOT/worktree"
  WORKTREE_BRANCH="ralph/framework-selftest-$(date +%Y%m%d%H%M%S)"
  ARTIFACT_DIR="$TEMP_ROOT/artifacts"
  mkdir -p "$ARTIFACT_DIR"
  trap cleanup EXIT

  prune_stale_selftest_worktrees
  run git -C "$REPO_ROOT" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_DIR" HEAD
  overlay_local_framework_tree
  copy_project_env_if_present
  seed_fixture_files
  write_story_files
  prune_stale_selftest_story_branches
  run_prepare_smoke_if_requested
  validate_doctor_output
  validate_complexity_and_tier_matrix
  validate_dry_run_prompt \
    "$WORKTREE_DIR/scripts/ralph/backlog/$SELFTEST_SPRINT/stories/S-901/story.json" \
    "\"agent\":\"researcher\"" \
    "profile: fanout_research_v1" \
    "$WORKTREE_DIR/.selftest-researcher-dryrun.out"
  validate_dry_run_prompt \
    "$WORKTREE_DIR/scripts/ralph/backlog/$SELFTEST_SPRINT/stories/S-902/story.json" \
    "\"agent\":\"senior-dev\"" \
    "profile: chain_implement_verify_v1" \
    "$WORKTREE_DIR/.selftest-senior-dryrun.out"
  snapshot_worktree_for_loop
  run_loop_and_closeout

  log "Framework self-test passed."
  log "Disposable worktree: $WORKTREE_DIR"
  if [ "$KEEP_WORKTREE" -eq 0 ]; then
    log "Temporary worktree will be cleaned up."
  else
    log "Keeping worktree for inspection."
  fi
  log "Diagnostics stored at: $ARTIFACT_DIR"
}

main "$@"
