#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.benchmarks"

# Suite name → benchmark TSV. Keep these two lists in sync (parallel arrays so
# this works on Bash 3.2, which macOS ships by default).
SUITE_NAMES=(sanity specify calendar worst-case-ui)
SUITE_FILES=(
  "$BENCH_DIR/e2e-history.tsv"
  "$BENCH_DIR/e2e-specify.tsv"
  "$BENCH_DIR/e2e-calendar.tsv"
  "$BENCH_DIR/worst-case-ui.tsv"
)

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/bench-history.sh [latest|tail [N]] [--suite NAME]
       scripts/smoke/bench-history.sh list

Commands:
  latest      Show the most recent benchmark row (default)
  tail [N]    Show the last N rows (default: 10)
  list        List all known benchmark files and whether they exist

Options:
  --suite NAME   Which suite to query: sanity (default), specify, calendar, worst-case-ui
USAGE
}

resolve_bench_file() {
  local suite="$1"
  local i
  for i in "${!SUITE_NAMES[@]}"; do
    if [ "${SUITE_NAMES[$i]}" = "$suite" ]; then
      local file="${SUITE_FILES[$i]}"
      if [ ! -f "$file" ]; then
        echo "No benchmark history found for suite '$suite' at $file" >&2
        exit 1
      fi
      echo "$file"
      return 0
    fi
  done
  echo "Unknown suite: $suite (try: ${SUITE_NAMES[*]})" >&2
  exit 1
}

cmd="latest"
count=10
suite="sanity"

while [[ $# -gt 0 ]]; do
  case "$1" in
    latest|list) cmd="$1"; shift ;;
    tail)        cmd="tail"; shift; if [[ "${1:-}" =~ ^[0-9]+$ ]]; then count="$1"; shift; fi ;;
    --suite)     suite="${2:?--suite requires a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$cmd" in
  list)
    i=0
    for s in "${SUITE_NAMES[@]}"; do
      f="${SUITE_FILES[$i]}"
      if [ -f "$f" ]; then
        rows="$(wc -l < "$f" | tr -d ' ')"
        printf '%s\t%s\trows=%s\n' "$s" "$f" "$rows"
      else
        printf '%s\t%s\t(missing)\n' "$s" "$f"
      fi
      i=$((i + 1))
    done
    ;;
  latest)
    file="$(resolve_bench_file "$suite")"
    tail -n 1 "$file"
    ;;
  tail)
    file="$(resolve_bench_file "$suite")"
    tail -n "$count" "$file"
    ;;
esac
