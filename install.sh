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

PROJECT_DIR="$(pwd)"
DEST_DIR_REL="scripts/ralph"
DEST_PARENT_REL="$(dirname "$DEST_DIR_REL")"
FORCE=0
INSTALL_SKILLS=0
INSTALL_PROMPTS=0
INSTALL_SPECKIT=0
SKIP_GIT_CHECK=0

usage() {
  cat <<'EOF'
Install Ralph into a target project.

Options:
  --project DIR         Project directory (default: current directory)
  --dest RELDIR         Install path relative to project (default: scripts/ralph)
  --force               Force overwrite of existing files
  --install-skills      Copy skills into ~/.codex/skills
  --install-prompts     Copy /command prompts to Global prompts directory
  --install-speckit     Install the SpecKit CLI (specify) via uv, pip, or npx
  --skip-git-check      Allow installing outside a git repo
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
    --skip-git-check)
      SKIP_GIT_CHECK=1; shift;;
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
mkdir -p "$DEST_DIR_REL/lib" "$DEST_DIR_REL/templates"

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

# Core story-task workflow
copy_file "$SOURCE_DIR/ralph.sh" "$DEST_DIR_REL/ralph.sh"
copy_file "$SOURCE_DIR/doctor.sh" "$DEST_DIR_REL/doctor.sh"
copy_file "$SOURCE_DIR/ralph-sprint.sh" "$DEST_DIR_REL/ralph-sprint.sh"
copy_file "$SOURCE_DIR/ralph-sprint-commit.sh" "$DEST_DIR_REL/ralph-sprint-commit.sh"
copy_file "$SOURCE_DIR/ralph-sprint-migrate.sh" "$DEST_DIR_REL/ralph-sprint-migrate.sh"
copy_file "$SOURCE_DIR/ralph-story.sh" "$DEST_DIR_REL/ralph-story.sh"
copy_file "$SOURCE_DIR/ralph-task.sh" "$DEST_DIR_REL/ralph-task.sh"
copy_file "$SOURCE_DIR/ralph-fallow.sh" "$DEST_DIR_REL/ralph-fallow.sh"
copy_file "$SOURCE_DIR/ralph-roadmap.sh" "$DEST_DIR_REL/ralph-roadmap.sh"
copy_file "$SOURCE_DIR/ralph-status.sh" "$DEST_DIR_REL/ralph-status.sh"
copy_file "$SOURCE_DIR/ralph-cleanup.sh" "$DEST_DIR_REL/ralph-cleanup.sh"
copy_file "$SOURCE_DIR/ralph-verify.sh" "$DEST_DIR_REL/ralph-verify.sh"
copy_file "$SOURCE_DIR/ralph-sprint-test.sh.example" "$DEST_DIR_REL/ralph-sprint-test.sh.example"
copy_file "$SOURCE_DIR/lib/codex-exec.sh" "$DEST_DIR_REL/lib/codex-exec.sh"
copy_file "$SOURCE_DIR/lib/editor-intake.sh" "$DEST_DIR_REL/lib/editor-intake.sh"
copy_file "$SOURCE_DIR/lib/search.sh" "$DEST_DIR_REL/lib/search.sh"
copy_file "$SOURCE_DIR/templates/prd-intake.md" "$DEST_DIR_REL/templates/prd-intake.md"
copy_file "$SOURCE_DIR/README-local.md" "$DEST_DIR_REL/README-local.md"
copy_file "$SOURCE_DIR/new-local-extension.sh.example" "$DEST_DIR_REL/new-local-extension.sh.example"
copy_file "$SOURCE_DIR/known-test-baseline-failures.txt" "$DEST_DIR_REL/known-test-baseline-failures.txt"
copy_file "$SOURCE_DIR/story.json.example" "$DEST_DIR_REL/story.json.example"
copy_file "$SOURCE_DIR/stories.json.example" "$DEST_DIR_REL/stories.json.example"
chmod +x \
  "$DEST_DIR_REL/ralph.sh" \
  "$DEST_DIR_REL/doctor.sh" \
  "$DEST_DIR_REL/ralph-sprint.sh" \
  "$DEST_DIR_REL/ralph-sprint-commit.sh" \
  "$DEST_DIR_REL/ralph-sprint-migrate.sh" \
  "$DEST_DIR_REL/ralph-story.sh" \
  "$DEST_DIR_REL/ralph-task.sh" \
  "$DEST_DIR_REL/ralph-fallow.sh" \
  "$DEST_DIR_REL/ralph-roadmap.sh" \
  "$DEST_DIR_REL/ralph-status.sh" \
  "$DEST_DIR_REL/ralph-cleanup.sh" \
  "$DEST_DIR_REL/ralph-verify.sh" \
  "$DEST_DIR_REL/lib/editor-intake.sh"


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
  echo "Installing SpecKit (specify CLI)..."
  if command -v uv >/dev/null 2>&1; then
    uv tool install "git+https://github.com/github/spec-kit.git" && echo "SpecKit installed via uv."
  elif command -v pip >/dev/null 2>&1; then
    pip install "git+https://github.com/github/spec-kit.git" && echo "SpecKit installed via pip."
  elif command -v npx >/dev/null 2>&1; then
    echo "SpecKit available via npx (no persistent install required)."
    echo "  Run: npx specify init <PROJECT>"
  else
    echo "WARN: Cannot install SpecKit — uv, pip, and npx not found."
    echo "      Install uv (recommended): https://docs.astral.sh/uv/getting-started/installation/"
    echo "      Then re-run: bash install.sh --install-speckit"
  fi
fi

# Commit installed files into the target repo so they are versioned from day one.
if [ "$SKIP_GIT_CHECK" -ne 1 ]; then
  git add "$DEST_DIR_REL" "$GITIGNORE_DEST"
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
echo ""
echo "  Sprint activation (previous sprint must be closed):"
echo "    ./$DEST_DIR_REL/ralph-sprint.sh use <sprint-name>"
echo ""
echo "  Sprint execution (runs all stories automatically):"
echo "    ./$DEST_DIR_REL/ralph.sh"
echo ""
echo "  Sprint closeout (after all stories done):"
echo "    ./$DEST_DIR_REL/ralph-sprint-commit.sh"
