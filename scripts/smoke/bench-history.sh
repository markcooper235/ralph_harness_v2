#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.benchmarks"

# Suite name → benchmark TSV. Keep these two lists in sync (parallel arrays so
# this works on Bash 3.2, which macOS ships by default).
SUITE_NAMES=(sanity specify calendar worst-case-ui upgrade)
SUITE_FILES=(
  "$BENCH_DIR/e2e-history.tsv"
  "$BENCH_DIR/e2e-specify.tsv"
  "$BENCH_DIR/e2e-calendar.tsv"
  "$BENCH_DIR/worst-case-ui.tsv"
  "$BENCH_DIR/e2e-upgrade.tsv"
)

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/bench-history.sh [latest|tail [N]|pretty] [--suite NAME]
       scripts/smoke/bench-history.sh list

Commands:
  latest      Show the most recent benchmark row (default)
  tail [N]    Show the last N rows (default: 10)
  pretty      Show the most recent benchmark row with named fields
  list        List all known benchmark files and whether they exist

Options:
  --suite NAME   Which suite to query: sanity (default), specify, calendar, worst-case-ui, upgrade
USAGE
}

print_pretty_row() {
  local row="$1"
  local nf
  nf="$(printf '%s' "$row" | awk -F '\t' '{print NF}')"

  if [ "$nf" -ge 14 ]; then
    local schema ts scenario mode status c6 c7 c8 c9 c10 c11 c12 c13 c14
    IFS=$'\t' read -r schema ts scenario mode status c6 c7 c8 c9 c10 c11 c12 c13 c14 <<< "$row"
    cat <<EOF
schema_version:      ${schema:-2}
timestamp:           $ts
scenario:            $scenario
mode:                $mode
status:              $status
planning_tokens:     ${c6:-0}
execution_tokens:    ${c7:-0}
remediation_tokens:  ${c8:-0}
total_tokens:        ${c9:-0}
stories_completed:   ${c10:-0}
story_cycles:        ${c11:-0}
remediation_cycles:  ${c12:-0}
retries:             ${c13:-0}
notes:               ${c14:-}
EOF
    return 0
  fi

  if [ "$nf" -ge 7 ]; then
    local ts scenario mode status c5 c6 c7
    IFS=$'\t' read -r ts scenario mode status c5 c6 c7 <<< "$row"
    cat <<EOF
schema_version:      legacy-v1
timestamp:           $ts
scenario:            $scenario
mode:                $mode
status:              $status
total_tokens:        ${c5:-0}
stories_completed:   ${c6:-0}
notes:               ${c7:-}
EOF
    return 0
  fi

  local ts status mode c4 c5
  IFS=$'\t' read -r ts status mode c4 c5 <<< "$row"
  cat <<EOF
schema_version:      legacy-v0
timestamp:           $ts
status:              $status
mode:                ${mode:-}
total_tokens:        ${c4:-0}
stories_completed:   ${c5:-0}
EOF
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
    latest|list|pretty) cmd="$1"; shift ;;
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
  pretty)
    file="$(resolve_bench_file "$suite")"
    print_pretty_row "$(tail -n 1 "$file")"
    ;;
  tail)
    file="$(resolve_bench_file "$suite")"
    tail -n "$count" "$file"
    ;;
esac
