#!/bin/bash
# e2e-profile-benchmark.sh — Compare baseline harnesses against composite-enabled runs.
#
# Phase 1 (baseline): codex + claude_code with composites disabled.
# Phase 2 (composite): piagent with composites enabled.
#
# Each run executes the fixed daily-work benchmark corpus from
# e2e-profile-corpus.sh so we compare the same representative stories across
# harnesses and phases.
#
# The suite writes a consolidated TSV at scripts/smoke/.benchmarks/e2e-profile-benchmark.tsv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-profile-benchmark.tsv"
WORK_DIR="$(mktemp -d /tmp/ralph-profile-benchmark.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

KEEP=0
PHASE="all"
ANY_FAIL=0

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/e2e-profile-benchmark.sh [--keep] [--phase baseline|composite|all]

Phases:
  baseline    Run codex and claude_code with composites disabled.
  composite   Run piagent with composites enabled.
  all         Run both phases (default).
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
  baseline|composite|all) ;;
  *) echo "Unknown phase: $PHASE (expected baseline|composite|all)" >&2; exit 1 ;;
esac

benchmark_init "profile-benchmark" "$PHASE" "$BENCH_FILE"

log() { echo "[profile-benchmark] $*"; }
warn() { echo "[profile-benchmark] WARN: $*" >&2; }
fail() { echo "[profile-benchmark] FAIL: $*" >&2; exit 1; }

run_smoke_suite() {
  local suite_script="$1"
  local suite_name="$2"
  local harness="$3"
  local composite_enabled="$4"
  local child_log="$LOG_DIR/${suite_name}-${harness}.log"
  local child_bench_file="$BENCH_DIR/e2e-profile-corpus.tsv"
  local status="pass"
  local before_count after_count
  local row schema ts source_scenario source_mode source_status planning execution remediation total stories story_cycles remediation_cycles retries notes
  local summary_notes=""
  local suite_args=(--keep)

  [ "$KEEP" -eq 1 ] || suite_args=()

  log "running $suite_name with harness=$harness composites=$composite_enabled"

  before_count=0
  [ -f "$child_bench_file" ] && before_count="$(wc -l < "$child_bench_file" | tr -d ' ')"

  if ! (
    cd "$REPO_ROOT" && \
    RALPH_ENABLE_COMPOSITES="$composite_enabled" \
    RALPH_HARNESS="$harness" \
    SMOKE_HARNESS="$harness" \
    SMOKE_MODEL="" \
    SMOKE_AGENT="" \
    bash "$suite_script" "${suite_args[@]}"
  ) > "$child_log" 2>&1; then
    status="fail"
    ANY_FAIL=1
    warn "$suite_name/$harness exited non-zero; see $child_log"
  fi

  after_count="$before_count"
  [ -f "$child_bench_file" ] && after_count="$(wc -l < "$child_bench_file" | tr -d ' ')"
  row=""
  if [ "$after_count" -gt "$before_count" ]; then
    row="$(tail -n 1 "$child_bench_file" 2>/dev/null || true)"
  fi
  if [ -n "$row" ]; then
    IFS=$'\t' read -r schema ts source_scenario source_mode source_status planning execution remediation total stories story_cycles remediation_cycles retries notes <<< "$row"
    benchmark_init "profile-benchmark" "$suite_name/$harness/composites-$composite_enabled" "$BENCH_FILE"
    benchmark_set_planning_tokens "${planning:-0}"
    benchmark_set_execution_tokens "${execution:-0}"
    benchmark_set_remediation_tokens "${remediation:-0}"
    benchmark_set_tokens "${total:-0}"
    benchmark_set_stories "${stories:-0}"
    benchmark_set_story_cycles "${story_cycles:-0}"
    benchmark_set_remediation_cycles "${remediation_cycles:-0}"
    benchmark_set_retries "${retries:-0}"
    summary_notes="suite=$suite_name;harness=$harness;composites=$composite_enabled;source=$source_scenario/$source_mode;source_status=$source_status;source_notes=${notes:-}"
    benchmark_set_notes "$summary_notes"
    benchmark_append_row "$status"
    log "  wrote summary row: suite=$suite_name harness=$harness total=${total:-0} status=$status"
  else
    benchmark_init "profile-benchmark" "$suite_name/$harness/composites-$composite_enabled" "$BENCH_FILE"
    benchmark_set_notes "suite=$suite_name;harness=$harness;composites=$composite_enabled;source_row_missing=1"
    benchmark_append_row "$status"
    warn "no benchmark row found in $child_bench_file"
  fi
}

run_phase() {
  local phase="$1"
  case "$phase" in
    baseline)
      run_smoke_suite "$SCRIPT_DIR/e2e-profile-corpus.sh" "corpus" "codex" "0"
      run_smoke_suite "$SCRIPT_DIR/e2e-profile-corpus.sh" "corpus" "claude_code" "0"
      ;;
    composite)
      run_smoke_suite "$SCRIPT_DIR/e2e-profile-corpus.sh" "corpus" "piagent" "1"
      ;;
    all)
      run_phase baseline
      run_phase composite
      ;;
  esac
}

trap 'code=$?; if [ "$KEEP" -eq 1 ] || [ "$ANY_FAIL" -eq 1 ] || [ "$code" -ne 0 ]; then echo "[profile-benchmark] work dir retained: $WORK_DIR"; else rm -rf "$WORK_DIR"; fi' EXIT

log "work dir: $WORK_DIR"
log "benchmark file: $BENCH_FILE"
run_phase "$PHASE"
log "done"
