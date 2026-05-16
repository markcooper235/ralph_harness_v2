#!/bin/bash

benchmark_init() {
  BENCHMARK_SCENARIO="$1"
  BENCHMARK_MODE="$2"
  BENCHMARK_FILE="$3"
  BENCHMARK_TOKENS=0
  BENCHMARK_STORIES=0
  BENCHMARK_NOTES=""
}

benchmark_set_tokens() {
  BENCHMARK_TOKENS="${1:-0}"
}

benchmark_add_tokens() {
  BENCHMARK_TOKENS=$(( ${BENCHMARK_TOKENS:-0} + ${1:-0} ))
}

benchmark_set_stories() {
  BENCHMARK_STORIES="${1:-0}"
}

benchmark_add_stories() {
  BENCHMARK_STORIES=$(( ${BENCHMARK_STORIES:-0} + ${1:-0} ))
}

benchmark_set_notes() {
  BENCHMARK_NOTES="${1:-}"
}

benchmark_append_row() {
  local status="$1"
  local file="${2:-$BENCHMARK_FILE}"
  local notes="${BENCHMARK_NOTES:-}"

  mkdir -p "$(dirname "$file")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" \
    "${BENCHMARK_SCENARIO:-unknown}" \
    "${BENCHMARK_MODE:-default}" \
    "$status" \
    "${BENCHMARK_TOKENS:-0}" \
    "${BENCHMARK_STORIES:-0}" \
    "$notes" \
    >>"$file"
}
