#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force|-f|--yes)
      FORCE=1
      ;;
    -h|--help)
      echo "Usage: ./scripts/ralph/ralph-cleanup.sh [--force]"
      echo "  --force    Skip confirmation prompt"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

if [ "$FORCE" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "Refusing non-interactive destructive cleanup without --force." >&2
    exit 1
  fi
  read -r -p "Cleanup will reset scripts/ralph/prd.json and clear active Ralph markers. Runtime journals under scripts/ralph/runtime are preserved. Continue? [y/N]: " reply
  case "${reply,,}" in
    y|yes)
      ;;
    *)
      echo "Canceled."
      exit 1
      ;;
  esac
fi

: > "$SCRIPT_DIR/prd.json"

rm -f \
  "$SCRIPT_DIR/progress.txt" \
  "$SCRIPT_DIR/.completion-state.json" \
  "$SCRIPT_DIR/.active-prd" \
  "$SCRIPT_DIR/.active-sprint" \
  "$SCRIPT_DIR/.last-branch" \
  "$SCRIPT_DIR/.iteration-log-latest.txt" \
  "$SCRIPT_DIR/.iteration-log-iter-"*.txt \
  "$SCRIPT_DIR/.iteration-handoff-latest.json" \
  "$SCRIPT_DIR/.iteration-handoff-iter-"*.json
rm -rf "$PLAYWRIGHT_CLI_DIR"

echo "Ralph cleanup complete (no archive created, prd.json reset, active markers cleared, runtime journals preserved, .playwright-cli cleared)."
