#!/bin/bash

choose_editor_cmd() {
  local editor="${RALPH_EDITOR:-${VISUAL:-${EDITOR:-}}}"
  if [ -n "$editor" ]; then
    printf '%s\n' "$editor"
    return 0
  fi
  if command -v nano >/dev/null 2>&1; then
    printf 'nano\n'
    return 0
  fi
  if command -v vi >/dev/null 2>&1; then
    printf 'vi\n'
    return 0
  fi
  return 1
}

run_editor_on_file() {
  local file="$1"
  local editor_cmd

  if [ ! -t 0 ] && [ ! -t 1 ]; then
    echo "Error: editor intake requires an interactive terminal." >&2
    return 1
  fi

  editor_cmd="$(choose_editor_cmd)" || {
    echo "Error: no editor found. Set RALPH_EDITOR, VISUAL, or EDITOR." >&2
    return 1
  }

  if [[ "$editor_cmd" =~ [[:space:]] ]]; then
    bash -lc "$editor_cmd \"\$1\"" _ "$file"
  else
    "$editor_cmd" "$file"
  fi
}

extract_marked_block() {
  local file="$1"
  local begin_marker="$2"
  local end_marker="$3"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 ~ begin { in_block=1; next }
    $0 ~ end { in_block=0; exit }
    in_block { print }
  ' "$file"
}

trim_whitespace() {
  sed -E 's|^[[:space:]]+||; s|[[:space:]]+$||'
}

kv_from_block() {
  local key="$1"
  awk -v key="$key" '
    index($0, key ":") == 1 {
      sub("^" key ":[[:space:]]*", "")
      print
      exit
    }
  '
}

lines_to_json_array() {
  jq -Rsc 'split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))'
}
