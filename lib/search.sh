#!/bin/bash
# lib/search.sh — portable file-search utilities
#
# rg (ripgrep) is the primary search tool; grep -E / find are env-level
# fallbacks for environments where rg is not installed.
#
# Source this file to get has_rg(), rg_or_grep(), and list_test_files().

# has_rg: returns 0 if ripgrep (rg) is available on PATH
has_rg() {
  command -v rg >/dev/null 2>&1
}

# rg_or_grep PATTERN [FILE_OR_DIR...]: search for PATTERN using rg when
# available, falling back to grep -E.  Always runs in quiet mode (exit code
# only: 0 on match, 1 on no match).
rg_or_grep() {
  if has_rg; then
    rg -q "$@"
  else
    grep -qE "$@"
  fi
}

# list_test_files DIR...: list test/spec source files under DIR using
# rg --files (fast) or find+grep -E (fallback).  Prints one path per line.
list_test_files() {
  if has_rg; then
    rg --files "$@" 2>/dev/null \
      | rg '(^|/)(__tests__/.*|.*\.(test|spec)\.[^.]+)$' || true
  else
    find "$@" -type f 2>/dev/null \
      | sed 's#^\./##' \
      | grep -E '(^|/)(__tests__/.*|.*\.(test|spec)\.[^.]+)$' || true
  fi
}
