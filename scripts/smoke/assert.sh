#!/bin/bash

set -euo pipefail

fail() {
  printf 'ASSERT FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  local path="$1"
  [ -e "$path" ] || fail "Expected file to exist: $path"
}

assert_file_not_exists() {
  local path="$1"
  [ ! -e "$path" ] || fail "Expected file to not exist: $path"
}

assert_dir_exists() {
  local path="$1"
  [ -d "$path" ] || fail "Expected directory to exist: $path"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -qE "$pattern" "$file" || fail "Expected pattern '$pattern' in $file"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -qE "$pattern" "$file"; then
    fail "Did not expect pattern '$pattern' in $file"
  fi
}

assert_eq() {
  local got="$1"
  local expected="$2"
  local msg="${3:-values differ}"
  [ "$got" = "$expected" ] || fail "$msg (got='$got' expected='$expected')"
}

assert_json_expr() {
  local file="$1"
  local expr="$2"
  jq -e "$expr" "$file" >/dev/null 2>&1 || fail "jq assertion failed for $file: $expr"
}
