#!/bin/bash
# lib/specify.sh — Shared SpecKit CLI discovery helpers (sourced)

specify_repo_bin() {
  printf '%s/bin/specify\n' "$SCRIPT_DIR"
}

find_specify_bin() {
  local repo_bin
  repo_bin="$(specify_repo_bin)"
  if [ -x "$repo_bin" ]; then
    echo "$repo_bin"
    return 0
  fi

  if command -v specify >/dev/null 2>&1; then
    command -v specify
    return 0
  fi

  if command -v npx >/dev/null 2>&1 && npx --yes specify version >/dev/null 2>&1; then
    echo "npx --yes specify"
    return 0
  fi

  return 1
}

describe_specify_bin() {
  local specify_bin="$1"
  local repo_bin
  repo_bin="$(specify_repo_bin)"

  if [ "$specify_bin" = "$repo_bin" ]; then
    if [ -x "$SCRIPT_DIR/.venv-specify/bin/specify" ]; then
      echo "repo-local persistent install"
    else
      echo "repo-local wrapper"
    fi
    return 0
  fi

  if [ "$specify_bin" = "npx --yes specify" ]; then
    echo "npx fallback"
    return 0
  fi

  echo "global install"
}
