#!/bin/bash
# e2e-profile-compatibility.sh — Probe cross-harness model compatibility.
#
# This suite reuses the fixed daily-work corpus, but runs it with explicit
# harness/model pairings so we can see whether alternative model families are
# actually tolerated by the harness, and at what cost.
#
# The current focus is:
# - codex with OpenAI tier overrides
# - piagent with OpenAI tier overrides
#
# The suite writes a consolidated TSV at
# scripts/smoke/.benchmarks/e2e-profile-compatibility.tsv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-profile-compatibility.tsv"
WORK_DIR="$(mktemp -d /tmp/ralph-profile-compatibility.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

KEEP=0
PHASE="all"
ANY_FAIL=0

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/e2e-profile-compatibility.sh [--keep] [--phase matrix|provider|all]

Phases:
  matrix   Run the compatibility model matrix.
  provider Run the provider-qualified OpenRouter model matrix.
  all      Run the matrix (default).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --phase) PHASE="${2:-all}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$PHASE" in
  matrix|provider|all) ;;
  *) echo "Unknown phase: $PHASE (expected matrix|provider|all)" >&2; exit 1 ;;
esac

benchmark_init "profile-compatibility" "$PHASE" "$BENCH_FILE"

log() { echo "[profile-compatibility] $*"; }
warn() { echo "[profile-compatibility] WARN: $*" >&2; }

run_case() {
  local harness="$1"
  local model="$2"
  local case_name="$3"
  local suite_script="$SCRIPT_DIR/e2e-profile-corpus.sh"
  local child_log="$LOG_DIR/${case_name}.log"
  local child_bench_file="$BENCH_DIR/e2e-profile-corpus.tsv"
  local before_count after_count row
  local status="pass"
  local schema ts source_scenario source_mode source_status planning execution remediation total stories story_cycles remediation_cycles retries notes
  local summary_notes=""

  log "running case=$case_name harness=$harness model=$model"

  before_count=0
  [ -f "$child_bench_file" ] && before_count="$(wc -l < "$child_bench_file" | tr -d ' ')"

  if ! (
    cd "$REPO_ROOT" && \
    RALPH_HARNESS="$harness" \
    SMOKE_HARNESS="$harness" \
    SMOKE_MODEL="$model" \
    SMOKE_AGENT="" \
    bash "$suite_script" --keep
  ) > "$child_log" 2>&1; then
    status="fail"
    ANY_FAIL=1
    warn "$case_name exited non-zero; see $child_log"
  fi

  after_count="$before_count"
  [ -f "$child_bench_file" ] && after_count="$(wc -l < "$child_bench_file" | tr -d ' ')"
  row=""
  if [ "$after_count" -gt "$before_count" ]; then
    row="$(tail -n 1 "$child_bench_file" 2>/dev/null || true)"
  fi

  benchmark_init "profile-compatibility" "$case_name" "$BENCH_FILE"
  if [ -n "$row" ]; then
    IFS=$'\t' read -r schema ts source_scenario source_mode source_status planning execution remediation total stories story_cycles remediation_cycles retries notes <<< "$row"
    benchmark_set_planning_tokens "${planning:-0}"
    benchmark_set_execution_tokens "${execution:-0}"
    benchmark_set_remediation_tokens "${remediation:-0}"
    benchmark_set_tokens "${total:-0}"
    benchmark_set_stories "${stories:-0}"
    benchmark_set_story_cycles "${story_cycles:-0}"
    benchmark_set_remediation_cycles "${remediation_cycles:-0}"
    benchmark_set_retries "${retries:-0}"
    summary_notes="case=$case_name;harness=$harness;model=$model;source=$source_scenario/$source_mode;source_status=$source_status;source_notes=${notes:-}"
    benchmark_set_notes "$summary_notes"
    benchmark_append_row "$status"
  else
    benchmark_set_notes "case=$case_name;harness=$harness;model=$model;source_row_missing=1"
    benchmark_append_row "$status"
    warn "no benchmark row found in $child_bench_file"
  fi
}

run_phase() {
  local phase="$1"
  case "$phase" in
    matrix)
      run_case "codex" "gpt-5.4" "codex-gpt-5.4"
      run_case "codex" "gpt-5.5" "codex-gpt-5.5"
      run_case "piagent" "gpt-5.4" "piagent-gpt-5.4"
      run_case "piagent" "gpt-5.5" "piagent-gpt-5.5"
      ;;
    provider)
      run_case "piagent" "openrouter/openai/gpt-5.4" "piagent-openrouter-gpt-5.4"
      run_case "piagent" "openrouter/openai/gpt-5.5" "piagent-openrouter-gpt-5.5"
      ;;
    all)
      run_phase matrix
      run_phase provider
      ;;
  esac
}

trap 'code=$?; if [ "$KEEP" -eq 1 ] || [ "$ANY_FAIL" -eq 1 ] || [ "$code" -ne 0 ]; then echo "[profile-compatibility] work dir retained: $WORK_DIR"; else rm -rf "$WORK_DIR"; fi' EXIT

log "work dir: $WORK_DIR"
log "benchmark file: $BENCH_FILE"
run_phase "$PHASE"
log "done"
