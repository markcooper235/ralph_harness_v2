#!/bin/bash

extract_tokens_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }

  awk '
    function add_tokens_from_line(lower_line,    sub_str) {
      if (match(lower_line, /tokens used[[:space:]]*[:=]?[[:space:]]*[0-9]+/)) {
        sub_str = substr(lower_line, RSTART, RLENGTH)
        match(sub_str, /[0-9]+$/)
        sum += substr(sub_str, RSTART, RLENGTH) + 0
        return 1
      }
      if (match(lower_line, /"total_tokens"[[:space:]]*:[[:space:]]*[0-9]+/)) {
        sub_str = substr(lower_line, RSTART, RLENGTH)
        match(sub_str, /[0-9]+$/)
        sum += substr(sub_str, RSTART, RLENGTH) + 0
        return 1
      }
      if (match(lower_line, /total tokens[[:space:]]*[:=]?[[:space:]]*[0-9]+/)) {
        sub_str = substr(lower_line, RSTART, RLENGTH)
        match(sub_str, /[0-9]+$/)
        sum += substr(sub_str, RSTART, RLENGTH) + 0
        return 1
      }
      return 0
    }
    {
      lower = tolower($0)
      gsub(/,/, "", lower)

      if (pending_tokens_used == 1) {
        if (match(lower, /[0-9]+/)) {
          sum += substr(lower, RSTART, RLENGTH) + 0
        }
        pending_tokens_used = 0
        next
      }

      if (add_tokens_from_line(lower)) {
        next
      }
      if (lower ~ /tokens used/) {
        pending_tokens_used = 1
        next
      }
    }
    END {
      print sum + 0
    }
  ' "$log_file"
}

extract_preloop_tokens_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }

  awk '
    function add_tokens_from_line(lower_line,    sub_str) {
      if (match(lower_line, /tokens used[[:space:]]*[:=]?[[:space:]]*[0-9]+/)) {
        sub_str = substr(lower_line, RSTART, RLENGTH)
        match(sub_str, /[0-9]+$/)
        sum += substr(sub_str, RSTART, RLENGTH) + 0
        return 1
      }
      if (match(lower_line, /"total_tokens"[[:space:]]*:[[:space:]]*[0-9]+/)) {
        sub_str = substr(lower_line, RSTART, RLENGTH)
        match(sub_str, /[0-9]+$/)
        sum += substr(sub_str, RSTART, RLENGTH) + 0
        return 1
      }
      if (match(lower_line, /total tokens[[:space:]]*[:=]?[[:space:]]*[0-9]+/)) {
        sub_str = substr(lower_line, RSTART, RLENGTH)
        match(sub_str, /[0-9]+$/)
        sum += substr(sub_str, RSTART, RLENGTH) + 0
        return 1
      }
      return 0
    }
    /Ralph Iteration [0-9]+ of [0-9]+/ { exit }
    {
      lower = tolower($0)
      gsub(/,/, "", lower)

      if (pending_tokens_used == 1) {
        if (match(lower, /[0-9]+/)) {
          sum += substr(lower, RSTART, RLENGTH) + 0
        }
        pending_tokens_used = 0
        next
      }

      if (add_tokens_from_line(lower)) {
        next
      }
      if (lower ~ /tokens used/) {
        pending_tokens_used = 1
        next
      }
    }
    END {
      print sum + 0
    }
  ' "$log_file"
}
