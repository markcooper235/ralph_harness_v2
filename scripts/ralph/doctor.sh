#!/bin/bash
# Ralph doctor - sanity checks for running Ralph in a project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
source "$SCRIPT_DIR/lib/specify.sh"
ROADMAP_FILE="$SCRIPT_DIR/roadmap.json"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
LEGACY_TRANSIENT_FILES=(
  "$SCRIPT_DIR/prd.json"
  "$SCRIPT_DIR/progress.txt"
  "$SCRIPT_DIR/.completion-state.json"
  "$SCRIPT_DIR/.active-prd"
)

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

echo "Ralph doctor"
echo "ralph dir: $SCRIPT_DIR"

require_cmd git
require_cmd jq
require_cmd "$CODEX_BIN"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Not inside a git repository. Run this from within your project repo."
fi

SPRINT_TEST_FILE="$SCRIPT_DIR/ralph-sprint-test.sh"
if [ ! -f "$SPRINT_TEST_FILE" ]; then
  echo "WARN: ralph-sprint-test.sh not found — ralph-sprint-commit.sh will fail without it."
  echo "      Copy $SCRIPT_DIR/ralph-sprint-test.sh.example to ralph-sprint-test.sh and customize."
fi

# SpecKit artifacts should be committed with the sprint, not gitignored
SAMPLE_SPECIFY_PATH="$SCRIPT_DIR/sprints/sprint-1/stories/S-001/.specify/spec.md"
if git check-ignore -q "$SAMPLE_SPECIFY_PATH" 2>/dev/null; then
  echo "WARN: SpecKit .specify/ artifacts appear to be gitignored — spec files will not be committed."
  echo "      Check .gitignore for patterns matching '.specify' and remove them."
else
  echo "OK: .specify/ artifacts are not gitignored"
fi

echo "OK: Ralph uses story-local SpecKit artifacts under each story's .specify/ directory"
echo "    Project-level 'specify init' is optional and not required for Ralph workflows."

if specify_bin="$(find_specify_bin)"; then
  specify_source="$(describe_specify_bin "$specify_bin")"
  case "$specify_source" in
    "repo-local persistent install")
      echo "OK: specify available via repo-local persistent install"
      ;;
    "repo-local wrapper")
      echo "WARN: specify is available via the repo-local wrapper only"
      echo "      This repo can run SpecKit, but it is relying on a runtime fallback (uv/uvx preferred, global specify last resort)."
      echo "      For a self-contained repo-local install, ensure Python venv support or uv is available, then re-run install.sh."
      ;;
    "uvx fallback")
      echo "WARN: specify is available via uv/uvx fallback"
      echo "      This works, but it is not a durable repo-local install and may depend on network/tooling at runtime."
      echo "      For a self-contained repo-local install, ensure Python venv support or uv is available, then re-run install.sh."
      ;;
    *)
      echo "OK: specify CLI found via global install"
      ;;
  esac
else
  fail "'specify' CLI not found — required for story specification.
  Install the CLI: uv tool install git+https://github.com/github/spec-kit.git
  Or use:          npx --yes specify version
  Or:      bash install.sh --install-speckit"
fi

if [ ! -f "$ROADMAP_FILE" ]; then
  echo "WARN: Missing $ROADMAP_FILE"
  echo "      Run: $SCRIPT_DIR/ralph-roadmap.sh to define your product roadmap."
fi

if [ -f "$ACTIVE_SPRINT_FILE" ]; then
  ACTIVE_SPRINT="$(awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE" || true)"
  if [ -n "${ACTIVE_SPRINT:-}" ]; then
    STORIES_FILE="$SPRINTS_DIR/$ACTIVE_SPRINT/stories.json"
    if [ -f "$STORIES_FILE" ]; then
      echo "OK: active sprint '$ACTIVE_SPRINT' has stories.json"
    else
      echo "WARN: active sprint '$ACTIVE_SPRINT' has no stories.json: $STORIES_FILE"
    fi
  fi
fi

tracked_legacy=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  tracked_legacy+="$path"$'\n'
done < <(git ls-files -- "${LEGACY_TRANSIENT_FILES[@]}" 2>/dev/null || true)
if [ -n "$tracked_legacy" ]; then
  echo "WARN: legacy transient Ralph files are still tracked in git:"
  printf '%s' "$tracked_legacy" | sed 's/^/      /'
  echo "      Remove them from git tracking after migration if they are no longer needed."
fi

if ! "$CODEX_BIN" exec --help >/dev/null 2>&1; then
  fail "Codex exec help failed. Check your Codex installation."
fi

if "$CODEX_BIN" --yolo exec --help 2>&1 | rg -qi "unexpected argument '--yolo'"; then
  echo "WARN: Your Codex does not support --yolo; ralph.sh will use a safe fallback."
else
  echo "OK: codex --yolo available"
fi

echo "OK: prerequisites present"
