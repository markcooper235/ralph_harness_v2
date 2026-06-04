#!/bin/bash
# Install Ralph into a target project.
#
# Usage (from your target project root):
#   bash /path/to/ralph/install.sh
#
# Or specify a project directory:
#   bash /path/to/ralph/install.sh --project /path/to/project

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SOURCE_DIR="$SOURCE_DIR/scripts/ralph"
source "$RUNTIME_SOURCE_DIR/lib/codex-exec.sh"

PROJECT_DIR="$(pwd)"
DEST_DIR_REL="scripts/ralph"
DEST_PARENT_REL="$(dirname "$DEST_DIR_REL")"
FORCE=0
INSTALL_SKILLS=0
INSTALL_PROMPTS=0
INSTALL_SPECKIT=1
MIGRATE_LEGACY=1
SKIP_GIT_CHECK=0
VERIFY_SETUP_MODE="auto"
CODEX_BIN="${CODEX_BIN:-codex}"
RALPH_HARNISH="${RALPH_HARNISH:-codex}"
RALPH_MODEL="${RALPH_MODEL:-}"
RALPH_AGENT="${RALPH_AGENT:-}"

usage() {
  cat <<'EOF'
Install Ralph into a target project.

Options:
  --project DIR         Project directory (default: current directory)
  --dest RELDIR         Install path relative to project (default: scripts/ralph)
  --force               Force overwrite of existing files
   --install-skills      Copy skills into ~/.codex/skills
   --install-prompts     Copy /command prompts to Global prompts directory
   --install-speckit     Ensure the repo-local SpecKit CLI (specify) is installed
   --no-install-speckit  Skip SpecKit bootstrap during install
   --migrate-legacy      Migrate any legacy epics.json sprints to stories.json (default)
   --no-migrate-legacy   Skip automatic legacy sprint migration during install
   --verify-setup MODE   Configure verify.local.sh: auto|detect-only|ai|skip (default: auto)
   --skip-git-check      Allow installing outside a git repo
    --harness HARNESS     Specify harness to use (codex|piagent) (default: codex)
    --model MODEL         Specify model to use with the harness (default: harness-specific)
    --agent AGENT         Specify agent/subagent type to use (default: harness-specific)
  -h, --help            Show help

Examples:
  bash /path/to/ralph/install.sh
  bash /path/to/ralph/install.sh --project ~/code/myapp --install-skills --install-prompts
EOF
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_DIR="${2:-}"; shift 2;;
    --dest)
      DEST_DIR_REL="${2:-}"
      DEST_PARENT_REL="$(dirname "$DEST_DIR_REL")"
      shift 2
      ;;
    --force)
      FORCE=1; shift;;
    --install-skills)
      INSTALL_SKILLS=1; shift;;
      --install-prompts)
      INSTALL_PROMPTS=1; shift;;
    --install-speckit)
      INSTALL_SPECKIT=1; shift;;
    --no-install-speckit)
      INSTALL_SPECKIT=0; shift;;
    --migrate-legacy)
      MIGRATE_LEGACY=1; shift;;
    --no-migrate-legacy)
      MIGRATE_LEGACY=0; shift;;
    --verify-setup)
      VERIFY_SETUP_MODE="${2:-}"; shift 2;;
     --skip-git-check)
       SKIP_GIT_CHECK=1; shift;;
     --harness)
       RALPH_HARNESS="${2:-}"; shift 2;;
     -h|--help)
       usage; exit 0;;
     *)
       fail "Unknown argument: $1";;
  esac
done

require_cmd cp
require_cmd chmod
require_cmd grep
require_cmd mkdir
require_cmd cat
require_cmd find

case "$VERIFY_SETUP_MODE" in
  auto|detect-only|ai|skip) ;;
  *) fail "--verify-setup must be one of: auto, detect-only, ai, skip" ;;
esac

if [ -z "$PROJECT_DIR" ]; then
  fail "--project requires a directory"
fi

if [ -z "$DEST_DIR_REL" ]; then
  fail "--dest requires a relative directory"
fi

if [[ "$DEST_DIR_REL" = /* ]]; then
  fail "--dest must be a path relative to the project (got absolute path: $DEST_DIR_REL)"
fi

if [ ! -d "$PROJECT_DIR" ]; then
  fail "Project directory does not exist: $PROJECT_DIR"
fi

cd "$PROJECT_DIR"

if [ "$SKIP_GIT_CHECK" -ne 1 ]; then
  require_cmd git
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "Not inside a git repo. Re-run with --skip-git-check if intentional."
  fi
fi

mkdir -p "$DEST_DIR_REL"
mkdir -p "$DEST_DIR_REL/bin" "$DEST_DIR_REL/lib" "$DEST_DIR_REL/templates"

copy_file() {
  local src="$1"
  local dst="$2"
  [ -f "$src" ] || fail "Missing source file: $src"
  if [ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" = "$(cd "$(dirname "$dst")" && pwd)/$(basename "$dst")" ]; then
    return 0
  fi
  cp "$src" "$dst"
}

copy_file_if_missing() {
  local src="$1"
  local dst="$2"
  [ -f "$src" ] || fail "Missing source file: $src"
  if [ -f "$dst" ]; then
    return 0
  fi
  copy_file "$src" "$dst"
}

collect_legacy_sprints() {
  [ -d "$DEST_DIR_REL/sprints" ] || return 0
  find "$DEST_DIR_REL/sprints" -mindepth 2 -maxdepth 2 -type f -name epics.json 2>/dev/null \
    | while IFS= read -r epics_file; do
        local sprint_dir sprint_name
        sprint_dir="$(dirname "$epics_file")"
        sprint_name="$(basename "$sprint_dir")"
        if [ ! -f "$sprint_dir/stories.json" ]; then
          printf '%s\n' "$sprint_name"
        fi
      done \
    | sort -u
}

# Core story-task workflow
copy_file "$RUNTIME_SOURCE_DIR/ralph.sh" "$DEST_DIR_REL/ralph.sh"
copy_file "$RUNTIME_SOURCE_DIR/doctor.sh" "$DEST_DIR_REL/doctor.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-sprint.sh" "$DEST_DIR_REL/ralph-sprint.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-sprint-commit.sh" "$DEST_DIR_REL/ralph-sprint-commit.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-story.sh" "$DEST_DIR_REL/ralph-story.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-story-run.sh" "$DEST_DIR_REL/ralph-story-run.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-fallow.sh" "$DEST_DIR_REL/ralph-fallow.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-fallow-run.sh" "$DEST_DIR_REL/ralph-fallow-run.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-roadmap.sh" "$DEST_DIR_REL/ralph-roadmap.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-status.sh" "$DEST_DIR_REL/ralph-status.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-cleanup.sh" "$DEST_DIR_REL/ralph-cleanup.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-verify.sh" "$DEST_DIR_REL/ralph-verify.sh"
copy_file "$RUNTIME_SOURCE_DIR/ralph-sprint-test.sh.example" "$DEST_DIR_REL/ralph-sprint-test.sh.example"
copy_file "$RUNTIME_SOURCE_DIR/execution-baseline.md" "$DEST_DIR_REL/execution-baseline.md"
copy_file "$RUNTIME_SOURCE_DIR/lib/codex-exec.sh" "$DEST_DIR_REL/lib/codex-exec.sh"
copy_file "$RUNTIME_SOURCE_DIR/lib/agent-profiles.json" "$DEST_DIR_REL/lib/agent-profiles.json"
copy_file "$RUNTIME_SOURCE_DIR/lib/composite-profiles.json" "$DEST_DIR_REL/lib/composite-profiles.json"
copy_file "$RUNTIME_SOURCE_DIR/lib/harness-capabilities.json" "$DEST_DIR_REL/lib/harness-capabilities.json"
copy_file "$RUNTIME_SOURCE_DIR/lib/harness-capabilities.sh" "$DEST_DIR_REL/lib/harness-capabilities.sh"
copy_file "$RUNTIME_SOURCE_DIR/lib/harness-exec.sh" "$DEST_DIR_REL/lib/harness-exec.sh"
copy_file "$RUNTIME_SOURCE_DIR/lib/label-to-agent-mapping.json" "$DEST_DIR_REL/lib/label-to-agent-mapping.json"
copy_file "$RUNTIME_SOURCE_DIR/lib/editor-intake.sh" "$DEST_DIR_REL/lib/editor-intake.sh"
copy_file "$RUNTIME_SOURCE_DIR/lib/search.sh" "$DEST_DIR_REL/lib/search.sh"
copy_file "$RUNTIME_SOURCE_DIR/lib/specify.sh" "$DEST_DIR_REL/lib/specify.sh"
copy_file "$RUNTIME_SOURCE_DIR/bin/specify" "$DEST_DIR_REL/bin/specify"
copy_file "$RUNTIME_SOURCE_DIR/templates/prd-intake.md" "$DEST_DIR_REL/templates/prd-intake.md"
copy_file "$RUNTIME_SOURCE_DIR/README-local.md" "$DEST_DIR_REL/README-local.md"
copy_file "$RUNTIME_SOURCE_DIR/known-test-baseline-failures.txt" "$DEST_DIR_REL/known-test-baseline-failures.txt"
copy_file "$RUNTIME_SOURCE_DIR/story.json.example" "$DEST_DIR_REL/story.json.example"
copy_file "$RUNTIME_SOURCE_DIR/stories.json.example" "$DEST_DIR_REL/stories.json.example"
copy_file "$RUNTIME_SOURCE_DIR/verify.local.sh.example" "$DEST_DIR_REL/verify.local.sh.example"
copy_file "$RUNTIME_SOURCE_DIR/.ralph-env.example" "$DEST_DIR_REL/.ralph-env.example"
rm -f \
  "$DEST_DIR_REL/ralph-task.sh" \
  "$DEST_DIR_REL/ralph-prd.sh" \
  "$DEST_DIR_REL/ralph-prime.sh" \
  "$DEST_DIR_REL/ralph-epic.sh" \
  "$DEST_DIR_REL/ralph-commit.sh" \
  "$DEST_DIR_REL/ralph-archive.sh" \
  "$DEST_DIR_REL/ralph-spec-check.sh" \
  "$DEST_DIR_REL/ralph-spec-strengthen.sh"
rm -rf "$DEST_DIR_REL/__tests__"
chmod +x \
  "$DEST_DIR_REL/ralph.sh" \
  "$DEST_DIR_REL/doctor.sh" \
  "$DEST_DIR_REL/ralph-sprint.sh" \
  "$DEST_DIR_REL/ralph-sprint-commit.sh" \
  "$DEST_DIR_REL/ralph-story.sh" \
  "$DEST_DIR_REL/ralph-story-run.sh" \
  "$DEST_DIR_REL/ralph-fallow.sh" \
  "$DEST_DIR_REL/ralph-fallow-run.sh" \
  "$DEST_DIR_REL/ralph-roadmap.sh" \
  "$DEST_DIR_REL/ralph-status.sh" \
  "$DEST_DIR_REL/ralph-cleanup.sh" \
  "$DEST_DIR_REL/ralph-verify.sh" \
  "$DEST_DIR_REL/lib/editor-intake.sh" \
  "$DEST_DIR_REL/bin/specify"

# Prevent rg from scanning node_modules and .next during Codex sessions.
# Without this, rg scans node_modules/next/dist/docs and inflates
# session size 3-4x.
if [ ! -f ".rgignore" ] || [ "$FORCE" -eq 1 ]; then
  cat > .rgignore << 'EOF'
node_modules/
.next/
EOF
  echo "Created .rgignore (node_modules/, .next/)"
fi

# ── Sprint regression gate auto-generation ───────────────────────────────────
# Generate a project-type-aware ralph-sprint-test.sh instead of a generic
# npm-based template. Falls back to the example for unknown or ambiguous types.

npm_has_script() {
  local script_name="$1"
  [ -f package.json ] || return 1
  node -e '
    const fs = require("fs");
    const scriptName = process.argv[1];
    try {
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      process.exit(pkg.scripts && pkg.scripts[scriptName] ? 0 : 1);
    } catch {
      process.exit(1);
    }
  ' "$script_name" 2>/dev/null
}

write_sprint_test_profile() {
  local profile="$1"
  local target="$2"
  local cmds=""

  case "$profile" in
    node)
      # Build a dynamic gate from available npm scripts
      local parts=()
      if npm_has_script "build"; then
        parts+=("npm run build")
      fi
      if npm_has_script "typecheck"; then
        parts+=("npm run typecheck")
      elif npm_has_script "lint"; then
        parts+=("npm run lint")
      fi
      if npm_has_script "test"; then
        parts+=("npm test")
      fi
      if [ "${#parts[@]}" -eq 0 ]; then
        # No recognizable scripts — fall back to generic
        return 1
      fi
      # Join with && using printf (avoids IFS scoping issues in case blocks)
      cmds="$(printf '%s && ' "${parts[@]}")"
      cmds="${cmds% && }"
      ;;
    python)
      cmds="python -m pytest && python -m mypy ."
      ;;
    go)
      cmds="go build ./... && go test ./... && go vet ./..."
      ;;
    rust)
      cmds="cargo build --release && cargo test && cargo clippy --all-targets --all-features -- -D warnings"
      ;;
    *)
      return 1
      ;;
  esac

  cat > "$target" <<EOF
#!/bin/bash
# ralph-sprint-test.sh — Sprint regression gate.
#
# Auto-generated by install.sh for detected repo profile: $profile
# Exit 0 = sprint is clean and ready to merge.
# Exit non-zero = regression found — fix before committing.
#
# Customize these commands for your project if needed.

set -euo pipefail
cd "\$(git rev-parse --show-toplevel)"

$cmds
EOF
  chmod +x "$target"
}

repo_has_files() {
  local pattern="$1"
  find . \
    -path "./.git" -prune -o \
    -path "./node_modules" -prune -o \
    -path "./.next" -prune -o \
    -path "./dist" -prune -o \
    -path "./build" -prune -o \
    -path "./coverage" -prune -o \
    -path "./vendor" -prune -o \
    -type f -name "$pattern" -print -quit 2>/dev/null | grep -q .
}

repo_has_nx_workspace() {
  [ -f nx.json ] || return 1
  find . \
    -path "./.git" -prune -o \
    -path "./node_modules" -prune -o \
    -type f -name project.json -print -quit 2>/dev/null | grep -q .
}

select_json_runtime() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3\n'
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf 'python\n'
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    printf 'node\n'
    return 0
  fi
  return 1
}

json_relpath() {
  local from_dir="$1"
  local to_path="$2"
  local runtime=""
  runtime="$(select_json_runtime)" || return 1

  case "$runtime" in
    python3|python)
      "$runtime" - "$from_dir" "$to_path" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
      ;;
    node)
      "$runtime" -e 'const path = require("node:path"); console.log(path.relative(process.argv[1], process.argv[2]));' "$from_dir" "$to_path"
      ;;
  esac
}

nx_typecheck_target_exists() {
  local project_json="$1"
  local runtime=""
  runtime="$(select_json_runtime)" || return 1

  case "$runtime" in
    python3|python)
      "$runtime" - "$project_json" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf8') as handle:
    data = json.load(handle)
sys.exit(0 if isinstance(data.get('targets', {}).get('typecheck'), dict) else 1)
PY
      ;;
    node)
      "$runtime" -e 'const fs=require("node:fs"); const data=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.exit(data.targets && data.targets.typecheck ? 0 : 1);' "$project_json"
      ;;
  esac
}

nx_project_root_from_config() {
  local project_json="$1"
  local runtime=""
  runtime="$(select_json_runtime)" || return 1

  case "$runtime" in
    python3|python)
      "$runtime" - "$project_json" <<'PY'
import json
import os
import sys
project_json = sys.argv[1]
with open(project_json, 'r', encoding='utf8') as handle:
    data = json.load(handle)
root = data.get('root') or os.path.dirname(project_json)
print(root)
PY
      ;;
    node)
      "$runtime" -e 'const fs=require("node:fs"); const path=require("node:path"); const file=process.argv[1]; const data=JSON.parse(fs.readFileSync(file, "utf8")); console.log(data.root || path.dirname(file));' "$project_json"
      ;;
  esac
}

write_nx_typecheck_tsconfig() {
  local project_root="$1"
  local tsconfig_target="$PROJECT_DIR/$project_root/tsconfig.typecheck.json"
  local base_config=""
  local next_env=""
  local project_dir_abs="$PROJECT_DIR/$project_root"
  local extend_rel=""
  local next_env_rel=""
  local src_types_rel=""

  [ -f "$tsconfig_target" ] && return 0

  if [ -f "$PROJECT_DIR/tsconfig.json" ]; then
    base_config="$PROJECT_DIR/tsconfig.json"
  elif [ -f "$PROJECT_DIR/tsconfig.base.json" ]; then
    base_config="$PROJECT_DIR/tsconfig.base.json"
  else
    echo "WARN: Skipping Nx typecheck tsconfig for $project_root (no root tsconfig found)"
    return 0
  fi

  extend_rel="$(json_relpath "$project_dir_abs" "$base_config")" || {
    echo "WARN: Skipping Nx typecheck tsconfig for $project_root (could not compute relative path)"
    return 0
  }

  if [ -f "$PROJECT_DIR/next-env.d.ts" ]; then
    next_env="$PROJECT_DIR/next-env.d.ts"
    next_env_rel="$(json_relpath "$project_dir_abs" "$next_env")"
  fi

  if [ -d "$PROJECT_DIR/src/types" ]; then
    src_types_rel="$(json_relpath "$project_dir_abs" "$PROJECT_DIR/src/types")"
  fi

  mkdir -p "$project_dir_abs"
  {
    echo '{'
    printf '  "extends": "%s",\n' "$extend_rel"
    echo '  "include": ['
    local first_entry=1
    if [ -n "$next_env_rel" ]; then
      printf '    "%s"' "$next_env_rel"
      first_entry=0
    fi
    if [ -n "$src_types_rel" ]; then
      if [ "$first_entry" -eq 0 ]; then
        echo ','
      fi
      printf '    "%s/**/*.d.ts"' "$src_types_rel"
      first_entry=0
    fi
    if [ "$first_entry" -eq 0 ]; then
      echo ','
    fi
    cat <<'EOF'
    "./**/*.ts",
    "./**/*.tsx"
  ],
  "exclude": [
    "./node_modules",
    "./**/__tests__/**",
    "./**/*.test.ts",
    "./**/*.test.tsx",
    "./**/*.spec.ts",
    "./**/*.spec.tsx",
    "./utility-tests/**"
  ]
}
EOF
  } > "$tsconfig_target"
}

add_nx_typecheck_target() {
  local project_json="$1"
  local project_root="$2"
  local runtime=""
  runtime="$(select_json_runtime)" || {
    echo "WARN: Skipping Nx typecheck target for $project_json (no JSON runtime available)"
    return 0
  }

  case "$runtime" in
    python3|python)
      "$runtime" - "$project_json" "$project_root" <<'PY'
import json
import sys
project_json = sys.argv[1]
project_root = sys.argv[2]
with open(project_json, 'r', encoding='utf8') as handle:
    data = json.load(handle)
targets = data.setdefault('targets', {})
if 'typecheck' not in targets:
    targets['typecheck'] = {
        'executor': 'nx:run-commands',
        'options': {
            'command': f'tsc -p {project_root}/tsconfig.typecheck.json --noEmit'
        }
    }
with open(project_json, 'w', encoding='utf8') as handle:
    json.dump(data, handle, indent=2)
    handle.write('\n')
PY
      ;;
    node)
      "$runtime" -e 'const fs=require("node:fs"); const file=process.argv[1]; const root=process.argv[2]; const data=JSON.parse(fs.readFileSync(file, "utf8")); data.targets ||= {}; if (!data.targets.typecheck) { data.targets.typecheck = { executor: "nx:run-commands", options: { command: `tsc -p ${root}/tsconfig.typecheck.json --noEmit` } }; } fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");' "$project_json" "$project_root"
      ;;
  esac
}

configure_nx_typecheck_support() {
  local runtime=""
  local project_json=""
  local project_root=""

  repo_has_nx_workspace || return 0
  runtime="$(select_json_runtime)" || {
    echo "WARN: Nx workspace detected, but no Python/Node JSON runtime is available for typecheck scaffolding."
    return 0
  }

  while IFS= read -r project_json; do
    [ -n "$project_json" ] || continue
    project_root="$(nx_project_root_from_config "$project_json" 2>/dev/null || true)"
    [ -n "$project_root" ] || continue
    [ "$project_root" = "." ] && continue

    if nx_typecheck_target_exists "$project_json"; then
      continue
    fi

    write_nx_typecheck_tsconfig "$project_root"
    add_nx_typecheck_target "$project_json" "$project_root"
    echo "Scaffolded Nx typecheck target for $project_root"
  done < <(
    find . \
      -path "./.git" -prune -o \
      -path "./node_modules" -prune -o \
      -type f -name project.json -print 2>/dev/null \
      | sed 's#^\./##' \
      | sort
  )
}

detect_repo_verification_profile() {
  local node_score=0 python_score=0 go_score=0 rust_score=0 max_score=0 max_kind="" tie=0

  [ -f package.json ] && node_score=$((node_score + 4))
  repo_has_nx_workspace && node_score=$((node_score + 2))
  [ -f tsconfig.json ] && node_score=$((node_score + 2))
  repo_has_files "*.ts" && node_score=$((node_score + 1))
  repo_has_files "*.tsx" && node_score=$((node_score + 1))
  repo_has_files "*.js" && node_score=$((node_score + 1))

  [ -f pyproject.toml ] && python_score=$((python_score + 4))
  [ -f requirements.txt ] && python_score=$((python_score + 2))
  [ -f setup.py ] && python_score=$((python_score + 2))
  [ -f setup.cfg ] && python_score=$((python_score + 1))
  repo_has_files "*.py" && python_score=$((python_score + 1))

  [ -f go.mod ] && go_score=$((go_score + 4))
  repo_has_files "*.go" && go_score=$((go_score + 1))

  [ -f Cargo.toml ] && rust_score=$((rust_score + 4))
  repo_has_files "*.rs" && rust_score=$((rust_score + 1))

  for kind in node python go rust; do
    local score=0
    case "$kind" in
      node) score="$node_score" ;;
      python) score="$python_score" ;;
      go) score="$go_score" ;;
      rust) score="$rust_score" ;;
    esac
    if [ "$score" -gt "$max_score" ]; then
      max_score="$score"
      max_kind="$kind"
      tie=0
    elif [ "$score" -gt 0 ] && [ "$score" -eq "$max_score" ]; then
      tie=1
    fi
  done

  if [ "$max_score" -eq 0 ] || [ "$tie" -eq 1 ]; then
    return 1
  fi

  printf '%s\n' "$max_kind"
}

# Create ralph-sprint-test.sh — auto-detect project type when possible
if [ ! -f "$DEST_DIR_REL/ralph-sprint-test.sh" ] || [ "$FORCE" -eq 1 ]; then
  if profile="$(detect_repo_verification_profile 2>/dev/null)"; then
    if write_sprint_test_profile "$profile" "$DEST_DIR_REL/ralph-sprint-test.sh"; then
      echo "Created ralph-sprint-test.sh for detected repo profile: $profile"
    else
      cp "$DEST_DIR_REL/ralph-sprint-test.sh.example" "$DEST_DIR_REL/ralph-sprint-test.sh"
      echo "Created ralph-sprint-test.sh from example (repo profile: $profile, no specific scripts found)"
    fi
  else
    cp "$DEST_DIR_REL/ralph-sprint-test.sh.example" "$DEST_DIR_REL/ralph-sprint-test.sh"
    echo "Created ralph-sprint-test.sh from example (customize for your project)"
  fi
fi

write_verify_local_profile() {
  local profile="$1"
  local target="$2"

  case "$profile" in
    node)
      cat > "$target" <<'EOF'
#!/usr/bin/env bash

ralph_verify_adapter_name() {
  printf 'node\n'
}

ralph_verify_scope_files() {
  collect_scope_files \
    | sed '/^$/d' \
    | sort -u
}

ralph_verify_code_files() {
  ralph_verify_scope_files \
    | awk '/\.(js|jsx|ts|tsx)$/'
}

ralph_verify_has_code_scope() {
  [ -n "$(ralph_verify_code_files)" ]
}

ralph_verify_repo_has_eslint_config() {
  find . \
    -path "./.git" -prune -o \
    -path "./node_modules" -prune -o \
    -maxdepth 2 \
    -type f \
    \( -name "eslint.config.js" -o -name "eslint.config.mjs" -o -name "eslint.config.cjs" -o -name ".eslintrc" -o -name ".eslintrc.js" -o -name ".eslintrc.cjs" -o -name ".eslintrc.json" -o -name ".eslintrc.yaml" -o -name ".eslintrc.yml" \) \
    -print -quit 2>/dev/null | grep -q .
}

ralph_verify_repo_has_nx_workspace() {
  [ -f nx.json ]
}

ralph_verify_resolve_scoped_typecheck_projects() {
  local code_files
  code_files="$(ralph_verify_code_files)"
  [ -n "$code_files" ] || return 0
  ralph_verify_repo_has_nx_workspace || return 0
  command -v node >/dev/null 2>&1 || return 0

  mapfile -t project_configs < <(
    find . \
      -path "./.git" -prune -o \
      -path "./node_modules" -prune -o \
      -type f -name project.json -print 2>/dev/null \
      | sed 's#^\./##' \
      | sort
  )
  [ "${#project_configs[@]}" -gt 0 ] || return 0

  printf '%s\n' "$code_files" \
    | node - "${project_configs[@]}" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')

const configs = process.argv.slice(2)
const scopedFiles = fs.readFileSync(0, 'utf8')
  .split(/\r?\n/)
  .map((entry) => entry.trim())
  .filter(Boolean)
  .map((entry) => entry.replace(/^\.\//, ''))

const projects = configs
  .map((configPath) => {
    try {
      const data = JSON.parse(fs.readFileSync(configPath, 'utf8'))
      const name = data.name
      const root = String(data.root || path.dirname(configPath)).replace(/^\.\//, '').replace(/\/$/, '')
      const hasTypecheck = !!(data.targets && data.targets.typecheck)
      return name && root && hasTypecheck ? { name, root } : null
    } catch {
      return null
    }
  })
  .filter(Boolean)
  .sort((left, right) => right.root.length - left.root.length)

const matched = new Set()
for (const file of scopedFiles) {
  for (const project of projects) {
    if (file === project.root || file.startsWith(`${project.root}/`)) {
      matched.add(project.name)
      break
    }
  }
}

process.stdout.write([...matched].sort().join('\n'))
NODE
}

ralph_verify_resolve_nx_affected_typecheck_projects() {
  local code_files files_csv raw_projects
  [ "$MODE" = "sprint" ] || return 0
  ralph_verify_repo_has_nx_workspace || return 0

  code_files="$(ralph_verify_code_files)"
  [ -n "$code_files" ] || return 0

  files_csv="$(printf '%s\n' "$code_files" | paste -sd, -)"
  [ -n "$files_csv" ] || return 0

  if ! raw_projects="$(npx nx show projects --affected --withTarget=typecheck --files="$files_csv" --json 2>/dev/null)"; then
    return 0
  fi

  printf '%s\n' "$raw_projects" \
    | node -e 'const fs=require("node:fs"); const data=JSON.parse(fs.readFileSync(0, "utf8")); if (Array.isArray(data)) { process.stdout.write(data.filter((entry) => typeof entry === "string").sort().join("\n")); }'
}

ralph_verify_intersect_project_lists() {
  local first_list="$1"
  local second_list="$2"
  [ -n "$first_list" ] || return 0
  [ -n "$second_list" ] || return 0

  comm -12 \
    <(printf '%s\n' "$first_list" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$second_list" | sed '/^$/d' | sort -u)
}

ralph_verify_run_scoped_typecheck_or_workspace_fallback() {
  local projects affected_projects filtered_affected_projects
  if ! ralph_verify_has_code_scope; then
    echo "[ralph-verify] skipping typecheck (no JS/TS scope files)"
    return 0
  fi

  projects="$(ralph_verify_resolve_scoped_typecheck_projects)"
  affected_projects="$(ralph_verify_resolve_nx_affected_typecheck_projects)"
  filtered_affected_projects="$(ralph_verify_intersect_project_lists "$affected_projects" "$projects")"
  if [ -n "$filtered_affected_projects" ]; then
    echo "[ralph-verify] running Nx affected typecheck for projects:"
    printf '%s\n' "$filtered_affected_projects" | sed 's/^/  - /'
    npx nx run-many -t typecheck --projects="$(printf '%s' "$filtered_affected_projects" | paste -sd, -)"
    QUALITY_CHECKS_RAN=1
    return 0
  fi

  if [ -n "$affected_projects" ]; then
    echo "[ralph-verify] running Nx affected typecheck for projects:"
    printf '%s\n' "$affected_projects" | sed 's/^/  - /'
    npx nx run-many -t typecheck --projects="$(printf '%s' "$affected_projects" | paste -sd, -)"
    QUALITY_CHECKS_RAN=1
    return 0
  fi

  if [ -n "$projects" ]; then
    echo "[ralph-verify] running scoped Nx typecheck for projects:"
    printf '%s\n' "$projects" | sed 's/^/  - /'
    npx nx run-many -t typecheck --projects="$(printf '%s' "$projects" | paste -sd, -)"
    QUALITY_CHECKS_RAN=1
    return 0
  fi

  echo "[ralph-verify] scoped Nx typecheck unavailable for this scope; running workspace typecheck"
  npm run typecheck
  QUALITY_CHECKS_RAN=1
}

ralph_verify_run_scoped_lint() {
  local code_files
  code_files="$(ralph_verify_code_files)"
  if [ -z "$code_files" ]; then
    echo "[ralph-verify] skipping lint (no JS/TS scope files)"
    return 0
  fi

  if ! ralph_verify_repo_has_eslint_config; then
    echo "[ralph-verify] scoped ESLint unavailable (no ESLint config); running workspace lint"
    npm run lint
    QUALITY_CHECKS_RAN=1
    return 0
  fi

  echo "[ralph-verify] running scoped lint:"
  printf '%s\n' "$code_files" | sed 's/^/  - /'
  mapfile -t lint_args < <(printf '%s\n' "$code_files")
  npx eslint --ext .js,.jsx,.ts,.tsx "${lint_args[@]}"
  QUALITY_CHECKS_RAN=1
}

ralph_verify_run_scope_guard_if_needed() {
  case "$MODE" in
    sprint|full-regression)
      if npm_has_script "guard:legacy-runtime"; then
        echo "[ralph-verify] running guard:legacy-runtime"
        npm run guard:legacy-runtime
        QUALITY_CHECKS_RAN=1
      else
        echo "[ralph-verify] skipping guard:legacy-runtime (script not defined)"
      fi
      ;;
  esac
}

ralph_verify_discover_targeted_tests() {
  local scoped tests tmp_tests source_path base stem dirname
  scoped="$(ralph_verify_scope_files)"
  [ -n "$scoped" ] || return 0

  tests=""
  tmp_tests="/tmp/ralph-local-targeted-tests.$$"
  : > "$tmp_tests"

  while IFS= read -r source_path; do
    [ -n "$source_path" ] || continue
    case "$source_path" in
      *test.ts|*test.tsx|*test.js|*test.jsx|*spec.ts|*spec.tsx|*spec.js|*spec.jsx)
        [ -f "$source_path" ] && tests+="$source_path"$'\n'
        continue
        ;;
    esac

    dirname="$(dirname "$source_path")"
    base="$(basename "$source_path")"
    stem="${base%.*}"

    case "$source_path" in
      src/app/*/page.tsx|src/app/*/page.ts|src/app/page.tsx|src/app/page.ts)
        find "$dirname/__tests__" -maxdepth 1 -type f \( -name 'page.test.*' -o -name 'page.spec.*' \) 2>/dev/null || true
        ;;
      src/app/api/*/route.ts|src/app/api/*/route.tsx)
        find "$dirname/__tests__" -maxdepth 1 -type f \( -name 'route.test.*' -o -name 'route.spec.*' \) 2>/dev/null || true
        ;;
      *)
        list_repo_test_files | while IFS= read -r candidate; do
          [ -n "$candidate" ] || continue
          case "$candidate" in
            *"/${stem}.test."*|*"/${stem}.spec."*)
              printf '%s\n' "$candidate"
              ;;
          esac
        done
        ;;
    esac >> "$tmp_tests"
  done <<< "$scoped"

  if [ -s "$tmp_tests" ]; then
    tests+="$(sort -u "$tmp_tests")"$'\n'
  fi
  rm -f "$tmp_tests" || true

  printf '%s' "$tests" | sed '/^$/d' | sort -u
}

ralph_verify_run_base_checks() {
  TEST_SCRIPT="test"
  TEST_SCRIPT_SUPPORTS_TARGETING=1

  case "$MODE" in
    task|story|sprint)
      ralph_verify_run_scoped_typecheck_or_workspace_fallback
      ralph_verify_run_scoped_lint
      ralph_verify_run_scope_guard_if_needed
      ;;
    full-regression)
      echo "[ralph-verify] running workspace typecheck"
      npm run typecheck
      QUALITY_CHECKS_RAN=1

      echo "[ralph-verify] running full lint"
      npm run lint
      QUALITY_CHECKS_RAN=1

      ralph_verify_run_scope_guard_if_needed
      ;;
    *)
      echo "[ralph-verify] running workspace typecheck"
      npm run typecheck
      QUALITY_CHECKS_RAN=1

      echo "[ralph-verify] running full lint"
      npm run lint
      QUALITY_CHECKS_RAN=1
      ;;
  esac
}

ralph_verify_run_targeted_tests() {
  echo "[ralph-verify] running targeted tests:"
  printf '%s\n' "$@" | sed 's/^/  - /'
  npm test -- --runInBand --runTestsByPath "$@"
}

ralph_verify_run_full_suite() {
  local ignore_re
  echo "[ralph-verify] running full test suite"
  ignore_re="$(build_ignore_regex || true)"
  if [ -n "$ignore_re" ]; then
    echo "[ralph-verify] applying known baseline ignore patterns from $IGNORE_FILE"
    npm test -- --runInBand --testPathIgnorePatterns "$ignore_re"
  else
    npm test -- --runInBand
  fi
}
EOF
      ;;
    python)
      cat > "$target" <<EOF
#!/usr/bin/env bash

ralph_verify_adapter_name() {
  printf '$profile\n'
}

ralph_verify_run_base_checks() {
  default_run_base_checks
}

ralph_verify_discover_targeted_tests() {
  default_discover_targeted_tests
}

ralph_verify_run_targeted_tests() {
  default_run_targeted_tests "\$@"
}

ralph_verify_run_full_suite() {
  default_run_full_suite
}
EOF
      ;;
    go)
      cat > "$target" <<'EOF'
#!/usr/bin/env bash

ralph_verify_adapter_name() {
  printf 'go\n'
}

ralph_verify_run_base_checks() {
  if command -v golangci-lint >/dev/null 2>&1; then
    echo "[ralph-verify] running golangci-lint"
    golangci-lint run ./...
    QUALITY_CHECKS_RAN=1
  else
    echo "[ralph-verify] skipping golangci-lint (tool not available)"
  fi
}

ralph_verify_discover_targeted_tests() {
  local changed_file packages=()

  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    case "$changed_file" in
      *.go)
        packages+=("./$(dirname "$changed_file")")
        ;;
    esac
  done < <(collect_changed_files)

  if [ "${#packages[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${packages[@]}" | sed 's#/\.$#.#' | sort -u
}

ralph_verify_run_targeted_tests() {
  if [ "$#" -eq 0 ]; then
    ralph_verify_run_full_suite
    return 0
  fi

  echo "[ralph-verify] running targeted tests:"
  printf '%s\n' "$@" | sed 's/^/  - /'
  go test "$@"
}

ralph_verify_run_full_suite() {
  echo "[ralph-verify] running full test suite"
  go test ./...
}
EOF
      ;;
    rust)
      cat > "$target" <<'EOF'
#!/usr/bin/env bash

ralph_verify_adapter_name() {
  printf 'rust\n'
}

ralph_verify_run_base_checks() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "[ralph-verify] skipping cargo base checks (cargo not available)"
    return 0
  fi

  echo "[ralph-verify] running cargo fmt --check"
  cargo fmt --check
  QUALITY_CHECKS_RAN=1

  echo "[ralph-verify] running cargo clippy"
  cargo clippy --all-targets --all-features -- -D warnings
  QUALITY_CHECKS_RAN=1
}

ralph_verify_discover_targeted_tests() {
  return 0
}

ralph_verify_run_targeted_tests() {
  echo "[ralph-verify] targeted Rust selection is not configured; falling back to full suite"
  ralph_verify_run_full_suite
}

ralph_verify_run_full_suite() {
  echo "[ralph-verify] running full test suite"
  cargo test --all-features
}
EOF
      ;;
    *)
      return 1
      ;;
  esac

  chmod +x "$target"
}

render_verify_ai_prompt() {
  local target="$1"
  local top_level=""

  top_level="$(find . \
    -maxdepth 2 \
    -path "./.git" -prune -o \
    -path "./node_modules" -prune -o \
    -path "./.next" -prune -o \
    -path "./dist" -prune -o \
    -path "./build" -prune -o \
    -type f -print 2>/dev/null | sort | sed 's#^\./##' | head -n 120)"

  cat <<EOF
Create a Ralph verification adapter for this repository.

Write ONLY the raw shell contents for:
$target

Requirements:
- Output shell only. No markdown fences.
- Define these functions:
  - ralph_verify_adapter_name
  - ralph_verify_run_base_checks
  - ralph_verify_discover_targeted_tests
  - ralph_verify_run_targeted_tests
  - ralph_verify_run_full_suite
- Use the repo's standard verification tools and existing scripts when possible.
- Prefer stable project commands already implied by manifests and config files.
- Use helpers already provided by scripts/ralph/ralph-verify.sh when helpful:
  collect_changed_files, collect_scope_files, list_repo_test_files, default_run_base_checks,
  default_discover_targeted_tests, default_run_targeted_tests, default_run_full_suite,
  build_ignore_regex, npm_has_script, select_node_test_script, run_selected_node_test_script,
  detect_python_bin, python_has_module, run_python_module_or_cmd.
- Keep targeted verification conservative. If precise targeting is unclear, fall back to the full suite.

Repository file sample:
$top_level
EOF
}

strip_markdown_fences() {
  local source_file="$1"
  local target_file="$2"

  if head -n 1 "$source_file" | grep -q '^```'; then
    sed '/^```/d' "$source_file" > "$target_file"
  else
    cp "$source_file" "$target_file"
  fi
}

generate_verify_local_with_ai() {
  local target="$1"
  local raw_tmp cleaned_tmp prompt

  command -v "$CODEX_BIN" >/dev/null 2>&1 || return 1
  raw_tmp="$(mktemp)"
  cleaned_tmp="$(mktemp)"
  prompt="$(render_verify_ai_prompt "$target")"

  if ! codex_exec_prompt "$prompt" "$PROJECT_DIR" > "$raw_tmp"; then
    rm -f "$raw_tmp" "$cleaned_tmp"
    return 1
  fi

  strip_markdown_fences "$raw_tmp" "$cleaned_tmp"
  if ! grep -q 'ralph_verify_run_full_suite' "$cleaned_tmp"; then
    rm -f "$raw_tmp" "$cleaned_tmp"
    return 1
  fi

  mv "$cleaned_tmp" "$target"
  chmod +x "$target"
  rm -f "$raw_tmp"
  return 0
}

configure_verify_local() {
  local target="$PROJECT_DIR/$DEST_DIR_REL/verify.local.sh"
  local profile=""

  if [ "$VERIFY_SETUP_MODE" = "skip" ]; then
    if [ ! -f "$target" ]; then
      copy_file "$RUNTIME_SOURCE_DIR/verify.local.sh.example" "$target"
      chmod +x "$target"
      echo "Installed generic verify.local.sh example (verify setup skipped)."
    fi
    return 0
  fi

  if [ -f "$target" ] && [ "$FORCE" -ne 1 ]; then
    echo "Keeping existing verify.local.sh"
    return 0
  fi

  if [ "$VERIFY_SETUP_MODE" = "ai" ]; then
    if generate_verify_local_with_ai "$target"; then
      echo "Configured verify.local.sh via AI-assisted repo inspection."
      return 0
    fi
    fail "AI verification setup failed. Ensure CODEX_BIN is available or use --verify-setup detect-only."
  fi

  if profile="$(detect_repo_verification_profile)"; then
    if [ "$profile" = "node" ]; then
      configure_nx_typecheck_support
    fi
    write_verify_local_profile "$profile" "$target"
    echo "Configured verify.local.sh for detected repo profile: $profile"
    return 0
  fi

  if [ "$VERIFY_SETUP_MODE" = "auto" ] && generate_verify_local_with_ai "$target"; then
    echo "Configured verify.local.sh via AI-assisted repo inspection."
    return 0
  fi

  copy_file "$RUNTIME_SOURCE_DIR/verify.local.sh.example" "$target"
  chmod +x "$target"
  echo "Installed generic verify.local.sh example (repo profile unknown)."
}

ensure_repo_local_speckit() {
  local repo_specify="$PROJECT_DIR/$DEST_DIR_REL/bin/specify"
  local python_bin=""

  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  fi

  find_uvx_bin_for_install() {
    local candidate user_base
    if command -v uvx >/dev/null 2>&1; then
      command -v uvx
      return 0
    fi
    for candidate in "${HOME:-}/.local/bin/uvx"; do
      [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    for candidate in python3 python; do
      if command -v "$candidate" >/dev/null 2>&1; then
        user_base="$("$candidate" -m site --user-base 2>/dev/null || true)"
        [ -n "$user_base" ] && [ -x "$user_base/bin/uvx" ] && { printf '%s\n' "$user_base/bin/uvx"; return 0; }
      fi
    done
    return 1
  }

  find_uv_bin_for_install() {
    local candidate user_base
    if command -v uv >/dev/null 2>&1; then
      command -v uv
      return 0
    fi
    for candidate in "${HOME:-}/.local/bin/uv"; do
      [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    for candidate in python3 python; do
      if command -v "$candidate" >/dev/null 2>&1; then
        user_base="$("$candidate" -m site --user-base 2>/dev/null || true)"
        [ -n "$user_base" ] && [ -x "$user_base/bin/uv" ] && { printf '%s\n' "$user_base/bin/uv"; return 0; }
      fi
    done
    return 1
  }

  ensure_uv_runner_available() {
    local installer_python="$1"
    local uv_log=""

    if find_uvx_bin_for_install >/dev/null 2>&1 || find_uv_bin_for_install >/dev/null 2>&1; then
      return 0
    fi

    [ -n "$installer_python" ] || return 1
    if ! "$installer_python" -m pip --version >/dev/null 2>&1; then
      return 1
    fi

    echo "Bootstrapping uv tool runner for SpecKit wrapper fallback..."
    uv_log="$(mktemp)"
    if "$installer_python" -m pip install --user uv >"$uv_log" 2>&1; then
      if find_uvx_bin_for_install >/dev/null 2>&1 || find_uv_bin_for_install >/dev/null 2>&1; then
        rm -f "$uv_log"
        echo "Installed uv tool runner for wrapper-based SpecKit fallback."
        return 0
      fi
    fi

    echo "WARN: Could not auto-install uv for SpecKit wrapper fallback."
    if [ -s "$uv_log" ]; then
      echo "      uv bootstrap output:"
      sed 's/^/        /' "$uv_log"
    fi
    rm -f "$uv_log"
    return 1
  }

  if [ -d "$PROJECT_DIR/$DEST_DIR_REL/.venv-specify" ]; then
    echo "Removing deprecated SpecKit virtualenv at $DEST_DIR_REL/.venv-specify"
    rm -rf "$PROJECT_DIR/$DEST_DIR_REL/.venv-specify"
  fi

  ensure_uv_runner_available "$python_bin" || true

  if "$repo_specify" version >/dev/null 2>&1; then
    echo "SpecKit ready via repo-local wrapper: $DEST_DIR_REL/bin/specify"
    return 0
  fi

  if find_uvx_bin_for_install >/dev/null 2>&1 || find_uv_bin_for_install >/dev/null 2>&1; then
    echo "WARN: Repo-local SpecKit wrapper is installed, but could not resolve specify right now."
    echo "      uv/uvx is available, so this may be a transient tool or network issue."
    return 0
  fi

  if command -v specify >/dev/null 2>&1; then
    echo "WARN: Repo-local uv bootstrap was unavailable; $DEST_DIR_REL/bin/specify will fall back to global specify as a last resort."
    echo "      The repo is usable, but uv is not available for the preferred wrapper path."
    return 0
  fi

  echo "WARN: Could not make the repo-local SpecKit wrapper usable."
  echo "      Install uv, then re-run: bash install.sh --project $PROJECT_DIR"
  echo "      Global specify remains a last-resort fallback only."
}


# Sprint-aware bootstrap directories (sprints and tasks created by ralph-roadmap.sh).
mkdir -p \
  "$DEST_DIR_REL/sprints" \
  "$DEST_DIR_REL/tasks" \
  "$DEST_DIR_REL/tasks/archive/sprints" \
  "$DEST_DIR_REL/tasks/archive/prds"

# Keep generated files out of git noise.
GITIGNORE_SOURCE="$SOURCE_DIR/.gitignore"
GITIGNORE_DEST=".gitignore"
[ -f "$GITIGNORE_SOURCE" ] || fail "Missing source file: $GITIGNORE_SOURCE"

if [ ! -f "$GITIGNORE_DEST" ]; then
  copy_file "$GITIGNORE_SOURCE" "$GITIGNORE_DEST"
else
  while IFS= read -r line || [ -n "$line" ]; do
    if ! grep -qxF "$line" "$GITIGNORE_DEST"; then
      printf "%s\n" "$line" >> "$GITIGNORE_DEST"
    fi
  done < "$GITIGNORE_SOURCE"
fi

if [ "$INSTALL_SKILLS" -eq 1 ]; then
  if [ -z "${HOME:-}" ]; then
    fail "HOME is not set; cannot install skills"
  fi
  CODEX_SKILLS_DIR="${HOME}/.codex/skills"
  mkdir -p "$CODEX_SKILLS_DIR"
  [ -d "$SOURCE_DIR/skills" ] || fail "Missing skills directory: $SOURCE_DIR/skills"

  while IFS= read -r -d '' dir; do
    name="$(basename "$dir")"
    [ -f "$dir/SKILL.md" ] || continue
    cp -r "$dir" "$CODEX_SKILLS_DIR/"
    echo "Installed Codex skill: $name"
  done < <(find "$SOURCE_DIR/skills" -mindepth 1 -maxdepth 1 -type d -print0)
fi

if [ "$INSTALL_PROMPTS" -eq 1 ]; then
  if [ -z "${HOME:-}" ]; then
    fail "HOME is not set; cannot install prompts"
  fi
  CODEX_GLOBAL_PROMPTS_DIR="${HOME}/.codex/prompts"
  mkdir -p "$CODEX_GLOBAL_PROMPTS_DIR"
  [ -d "$SOURCE_DIR/prompts" ] || fail "Missing command_prompts directory: $SOURCE_DIR/prompts"

  while IFS= read -r -d '' file; do
    name="$(basename "$file")"
    [ -f "$file" ] || continue
    cp "$file" "$CODEX_GLOBAL_PROMPTS_DIR/"
    echo "Installed Codex prompt: $name"
  done < <(find "$SOURCE_DIR/prompts" -type f -print0)
fi

if [ "$INSTALL_SPECKIT" -eq 1 ]; then
  ensure_repo_local_speckit
fi

configure_verify_local

legacy_sprints=()
while IFS= read -r sprint_name; do
  [ -n "$sprint_name" ] || continue
  legacy_sprints+=("$sprint_name")
done < <(collect_legacy_sprints)

if [ "${#legacy_sprints[@]}" -gt 0 ]; then
  echo "Detected legacy Ralph sprint(s) that still use epics.json:"
  printf '  %s\n' "${legacy_sprints[@]}"
  if [ "$MIGRATE_LEGACY" -eq 1 ]; then
    require_cmd jq
    for sprint_name in "${legacy_sprints[@]}"; do
      echo "Migrating legacy sprint: $sprint_name"
      (
        cd "$DEST_DIR_REL"
        ./ralph-sprint-migrate.sh --sprint "$sprint_name"
      )
    done
  else
    echo "Re-run with default migration enabled, or migrate manually with:"
    echo "  cd $DEST_DIR_REL && ./ralph-sprint-migrate.sh --sprint <sprint-name>"
  fi
fi

# Commit installed files into the target repo so they are versioned from day one.
if [ "$SKIP_GIT_CHECK" -ne 1 ]; then
  git add -A "$DEST_DIR_REL" "$GITIGNORE_DEST"
  if ! git diff --cached --quiet; then
    git commit -m "chore: install Ralph workflow tooling into $DEST_DIR_REL"
    echo "Committed Ralph scripts to git."
  else
    echo "(No git changes — files already up to date.)"
  fi
fi

echo "Installed Ralph into: $PROJECT_DIR/$DEST_DIR_REL"
echo "Next:"
echo "  1) ./$DEST_DIR_REL/doctor.sh"
echo ""
echo "  Define your product roadmap (creates sprints + stories):"
echo "    ./$DEST_DIR_REL/ralph-roadmap.sh"
echo ""
echo "  Per-sprint preparation (after roadmap creates a sprint):"
echo "    ./$DEST_DIR_REL/ralph-story.sh prepare-all --jobs 2"
echo "    ./$DEST_DIR_REL/ralph-sprint.sh mark-ready <sprint-name>"
if [ "${#legacy_sprints[@]}" -gt 0 ] && [ "$MIGRATE_LEGACY" -eq 0 ]; then
echo ""
echo "  Legacy sprint upgrade detected:"
echo "    bash install.sh --project $PROJECT_DIR --migrate-legacy"
fi
echo ""
echo "  Sprint activation (previous sprint must be closed):"
echo "    ./$DEST_DIR_REL/ralph-sprint.sh use <sprint-name>"
echo ""
echo "  Sprint execution (runs all stories automatically):"
echo "    ./$DEST_DIR_REL/ralph.sh"
echo ""
echo "  Sprint closeout (after all stories done):"
echo "    ./$DEST_DIR_REL/ralph-sprint-commit.sh"
