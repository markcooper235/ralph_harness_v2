#!/bin/bash
# lib/search.sh — file-search utilities
#
# rg (ripgrep) is the search tool used by Ralph.
#
# Source this file to get has_rg(), rg_or_grep(), and list_test_files().

# has_rg: returns 0 if ripgrep (rg) is available on PATH
has_rg() {
  command -v rg >/dev/null 2>&1
}

# rg_or_grep PATTERN [FILE_OR_DIR...]: search for PATTERN with rg in quiet mode
# (exit code only: 0 on match, 1 on no match).
rg_or_grep() {
  rg -q "$@"
}

# list_test_files DIR...: list test/spec source files under DIR using
# rg --files. Prints one path per line.
list_test_files() {
  rg --files "$@" 2>/dev/null \
    | rg '(^|/)(__tests__/.*|.*\.(test|spec)\.[^.]+)$' || true
}
