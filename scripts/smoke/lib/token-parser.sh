#!/bin/bash

extract_tokens_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }

  if command -v jq >/dev/null 2>&1; then
    local json_sum
    json_sum="$(jq -Rcs '
      split("\n")
      | map(fromjson? | select(. != null))
      | (
          ([ .[] | select(.type == "step_finish") | .part.tokens.total? // empty ] | add // 0)
        + ([ .[] | select(.type == "turn_end") | .message.usage.totalTokens? // empty ] | add // 0)
        + ([ .[] | select(.type == "result") | ((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.output_tokens // 0)) ] | add // 0)
        )' "$log_file" 2>/dev/null || true)"
    if [ -n "$json_sum" ] && [ "$json_sum" != "0" ]; then
      echo "$json_sum"
      return 0
    fi
  fi

  awk '
    function extract_last_number(str,    copy, piece) {
      copy = str
      if (match(copy, /[0-9]+[^0-9]*$/)) {
        piece = substr(copy, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", piece)
        return piece + 0
      }
      return 0
    }
    function extract_json_value(str, key,    pattern, copy) {
      copy = str
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+"
      if (match(copy, pattern)) {
        return extract_last_number(substr(copy, RSTART, RLENGTH))
      }
      return 0
    }
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
      if (index(lower_line, "\"type\":\"step_finish\"") > 0 && index(lower_line, "\"tokens\"") > 0) {
        sub_str = lower_line
        sub(/^.*"tokens"[[:space:]]*:[[:space:]]*\{/, "", sub_str)
        sum += extract_json_value(sub_str, "total")
        return 1
      }
      if (index(lower_line, "\"type\":\"turn_end\"") > 0 && index(lower_line, "\"totaltokens\"") > 0) {
        sum += extract_json_value(lower_line, "totaltokens")
        return 1
      }
      if (index(lower_line, "\"type\":\"result\"") > 0 && index(lower_line, "\"usage\"") > 0) {
        sum += extract_json_value(lower_line, "input_tokens")
        sum += extract_json_value(lower_line, "cache_creation_input_tokens")
        sum += extract_json_value(lower_line, "cache_read_input_tokens")
        sum += extract_json_value(lower_line, "output_tokens")
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

  if command -v jq >/dev/null 2>&1; then
    local json_sum
    json_sum="$(awk '/Ralph Iteration [0-9]+ of [0-9]+/ { exit } { print }' "$log_file" \
      | jq -Rcs '
          split("\n")
          | map(fromjson? | select(. != null))
          | (
              ([ .[] | select(.type == "step_finish") | .part.tokens.total? // empty ] | add // 0)
            + ([ .[] | select(.type == "turn_end") | .message.usage.totalTokens? // empty ] | add // 0)
            + ([ .[] | select(.type == "result") | ((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.output_tokens // 0)) ] | add // 0)
            )' 2>/dev/null || true)"
    if [ -n "$json_sum" ] && [ "$json_sum" != "0" ]; then
      echo "$json_sum"
      return 0
    fi
  fi

  awk '
    function extract_last_number(str,    copy, piece) {
      copy = str
      if (match(copy, /[0-9]+[^0-9]*$/)) {
        piece = substr(copy, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", piece)
        return piece + 0
      }
      return 0
    }
    function extract_json_value(str, key,    pattern, copy) {
      copy = str
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+"
      if (match(copy, pattern)) {
        return extract_last_number(substr(copy, RSTART, RLENGTH))
      }
      return 0
    }
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
      if (index(lower_line, "\"type\":\"step_finish\"") > 0 && index(lower_line, "\"tokens\"") > 0) {
        sub_str = lower_line
        sub(/^.*"tokens"[[:space:]]*:[[:space:]]*\{/, "", sub_str)
        sum += extract_json_value(sub_str, "total")
        return 1
      }
      if (index(lower_line, "\"type\":\"turn_end\"") > 0 && index(lower_line, "\"totaltokens\"") > 0) {
        sum += extract_json_value(lower_line, "totaltokens")
        return 1
      }
      if (index(lower_line, "\"type\":\"result\"") > 0 && index(lower_line, "\"usage\"") > 0) {
        sum += extract_json_value(lower_line, "input_tokens")
        sum += extract_json_value(lower_line, "cache_creation_input_tokens")
        sum += extract_json_value(lower_line, "cache_read_input_tokens")
        sum += extract_json_value(lower_line, "output_tokens")
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
