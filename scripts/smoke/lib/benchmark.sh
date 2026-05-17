#!/bin/bash

benchmark_init() {
  BENCHMARK_SCENARIO="$1"
  BENCHMARK_MODE="$2"
  BENCHMARK_FILE="$3"
  BENCHMARK_SCHEMA_VERSION=2
  BENCHMARK_PLANNING_TOKENS=0
  BENCHMARK_EXECUTION_TOKENS=0
  BENCHMARK_REMEDIATION_TOKENS=0
  BENCHMARK_TOTAL_TOKENS=0
  BENCHMARK_STORIES=0
  BENCHMARK_STORY_CYCLES=0
  BENCHMARK_REMEDIATION_CYCLES=0
  BENCHMARK_RETRIES=0
  BENCHMARK_NOTES=""
}

benchmark_set_tokens() {
  BENCHMARK_EXECUTION_TOKENS="${1:-0}"
  BENCHMARK_TOTAL_TOKENS="${1:-0}"
}

benchmark_add_tokens() {
  BENCHMARK_EXECUTION_TOKENS=$(( ${BENCHMARK_EXECUTION_TOKENS:-0} + ${1:-0} ))
  BENCHMARK_TOTAL_TOKENS=$(( ${BENCHMARK_TOTAL_TOKENS:-0} + ${1:-0} ))
}

benchmark_set_planning_tokens() {
  BENCHMARK_PLANNING_TOKENS="${1:-0}"
}

benchmark_add_planning_tokens() {
  BENCHMARK_PLANNING_TOKENS=$(( ${BENCHMARK_PLANNING_TOKENS:-0} + ${1:-0} ))
}

benchmark_set_execution_tokens() {
  BENCHMARK_EXECUTION_TOKENS="${1:-0}"
}

benchmark_add_execution_tokens() {
  BENCHMARK_EXECUTION_TOKENS=$(( ${BENCHMARK_EXECUTION_TOKENS:-0} + ${1:-0} ))
}

benchmark_set_remediation_tokens() {
  BENCHMARK_REMEDIATION_TOKENS="${1:-0}"
}

benchmark_add_remediation_tokens() {
  BENCHMARK_REMEDIATION_TOKENS=$(( ${BENCHMARK_REMEDIATION_TOKENS:-0} + ${1:-0} ))
}

benchmark_set_story_cycles() {
  BENCHMARK_STORY_CYCLES="${1:-0}"
}

benchmark_add_story_cycles() {
  BENCHMARK_STORY_CYCLES=$(( ${BENCHMARK_STORY_CYCLES:-0} + ${1:-0} ))
}

benchmark_set_remediation_cycles() {
  BENCHMARK_REMEDIATION_CYCLES="${1:-0}"
}

benchmark_add_remediation_cycles() {
  BENCHMARK_REMEDIATION_CYCLES=$(( ${BENCHMARK_REMEDIATION_CYCLES:-0} + ${1:-0} ))
}

benchmark_set_retries() {
  BENCHMARK_RETRIES="${1:-0}"
}

benchmark_add_retries() {
  BENCHMARK_RETRIES=$(( ${BENCHMARK_RETRIES:-0} + ${1:-0} ))
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

benchmark_any_tokens() {
  [ $(( ${BENCHMARK_PLANNING_TOKENS:-0} + ${BENCHMARK_EXECUTION_TOKENS:-0} + ${BENCHMARK_REMEDIATION_TOKENS:-0} + ${BENCHMARK_TOTAL_TOKENS:-0} )) -gt 0 ]
}

benchmark_append_row() {
  local status="$1"
  local file="${2:-$BENCHMARK_FILE}"
  local notes="${BENCHMARK_NOTES:-}"
  local planning="${BENCHMARK_PLANNING_TOKENS:-0}"
  local execution="${BENCHMARK_EXECUTION_TOKENS:-0}"
  local remediation="${BENCHMARK_REMEDIATION_TOKENS:-0}"
  local total="${BENCHMARK_TOTAL_TOKENS:-0}"
  local phase_sum

  phase_sum=$(( planning + execution + remediation ))
  if [ "$total" -eq 0 ] && [ "$phase_sum" -gt 0 ]; then
    total="$phase_sum"
  fi

  mkdir -p "$(dirname "$file")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${BENCHMARK_SCHEMA_VERSION:-2}" \
    "$(date -Iseconds)" \
    "${BENCHMARK_SCENARIO:-unknown}" \
    "${BENCHMARK_MODE:-default}" \
    "$status" \
    "$planning" \
    "$execution" \
    "$remediation" \
    "$total" \
    "${BENCHMARK_STORIES:-0}" \
    "${BENCHMARK_STORY_CYCLES:-0}" \
    "${BENCHMARK_REMEDIATION_CYCLES:-0}" \
    "${BENCHMARK_RETRIES:-0}" \
    "$notes" \
    >>"$file"
}
