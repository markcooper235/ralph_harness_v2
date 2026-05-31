#!/bin/bash
# lib/harness-capabilities.sh — Helper functions for harness capability validation

# Load JSON value safely (handles missing files or invalid JSON)
_load_json_value() {
  local file="$1"
  local key="$2"
  local default="${3:-}"
  
  if [ ! -f "$file" ]; then
    echo "$default"
    return
  fi
  
  if command -v jq >/dev/null 2>&1; then
    jq -r "$key // empty" "$file" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

# Get harness capabilities file path
_get_capabilities_file() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$script_dir/harness-capabilities.json"
}

# Check if a harness supports model selection
harness_supports_model_selection() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local supported
  supported="$(_load_json_value "$capabilities_file" ".harnesses.$harness.supports_model_selection // false")"
  [ "$supported" = "true" ]
}

# Check if a harness supports agent selection
harness_supports_agent_selection() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local supported
  supported="$(_load_json_value "$capabilities_file" ".harnesses.$harness.supports_agent_selection // false")"
  [ "$supported" = "true" ]
}

# Get default model for a harness
get_harness_default_model() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local default_model
  default_model="$(_load_json_value "$capabilities_file" ".harnesses.$harness.default_model // empty")"
  echo "$default_model"
}

# Get available models for a harness
get_harness_available_models() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local models_json
  models_json="$(_load_json_value "$capabilities_file" ".harnesses.$harness.available_models // []")"
  echo "$models_json"
}

# Validate if a model is supported by a harness
is_model_supported_by_harness() {
  local harness="$1"
  local model="$2"
  local capabilities_file="$(_get_capabilities_file)"
  local models_json
  models_json="$(_load_json_value "$capabilities_file" ".harnesses.$harness.available_models // []")"
  
  if [ -z "$models_json" ] || [ "$models_json" = "[]" ]; then
    return 1
  fi
  
  echo "$models_json" | jq -e --arg model "$model" 'index($model) // empty' >/dev/null 2>&1
}

# Get model parameter name for a harness
get_harness_model_parameter() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local param
  param="$(_load_json_value "$capabilities_file" ".harnesses.$harness.model_parameter // empty")"
  echo "$param"
}

# Get agent parameter name for a harness
get_harness_agent_parameter() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local param
  param="$(_load_json_value "$capabilities_file" ".harnesses.$harness.agent_parameter // empty")"
  echo "$param"
}

# Get provider for a harness
get_harness_provider() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local provider
  provider="$(_load_json_value "$capabilities_file" ".harnesses.$harness.provider // empty")"
  echo "$provider"
}

# Get access method for a harness
get_harness_access_method() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local method
  method="$(_load_json_value "$capabilities_file" ".harnesses.$harness.access_method // empty")"
  echo "$method"
}
# Get default agent for a harness
get_harness_default_agent() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  local default_agent
  default_agent="$(_load_json_value "$capabilities_file" ".harnesses.$harness.default_agent // empty")"
  echo "$default_agent"
}

_model_cache_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/../runtime/model-cache\n' "$script_dir"
}

_model_cache_path() {
  local harness="$1"
  printf '%s/%s.json\n' "$(_model_cache_dir)" "$harness"
}

_file_mtime_epoch() {
  local path="$1"
  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
  else
    stat -f %m "$path"
  fi
}

_model_cache_is_fresh() {
  local path="$1"
  local max_age="${2:-86400}"
  [ -f "$path" ] || return 1
  local now mtime
  now="$(date +%s)"
  mtime="$(_file_mtime_epoch "$path" 2>/dev/null || echo 0)"
  [ $((now - mtime)) -lt "$max_age" ]
}

_write_model_cache_json() {
  local harness="$1"
  local models_json="$2"
  local cache_dir cache_path tmp
  cache_dir="$(_model_cache_dir)"
  cache_path="$(_model_cache_path "$harness")"
  mkdir -p "$cache_dir"
  tmp="$(mktemp)"
  jq -n --arg harness "$harness" --argjson models "$models_json" --arg fetched_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
    {
      harness: $harness,
      fetched_at: $fetched_at,
      models: $models
    }' > "$tmp" 2>/dev/null || {
      rm -f "$tmp"
      return 1
    }
  mv "$tmp" "$cache_path"
}

_read_model_cache_json() {
  local harness="$1"
  local cache_path
  cache_path="$(_model_cache_path "$harness")"
  [ -f "$cache_path" ] || return 1
  jq -c '.models // []' "$cache_path" 2>/dev/null
}

_get_static_models_json() {
  local harness="$1"
  local capabilities_file="$(_get_capabilities_file)"
  jq -c --arg harness "$harness" '.harnesses[$harness].available_models // []' "$capabilities_file" 2>/dev/null || echo "[]"
}

_normalize_model_list_json() {
  jq -Rsc 'split("\n") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)) | unique'
}

_models_endpoint_for_base_url() {
  local base_url="$1"
  case "$base_url" in
    */models)
      printf '%s\n' "$base_url"
      ;;
    */v1|*/api/v1)
      printf '%s/models\n' "$base_url"
      ;;
    *)
      printf '%s/v1/models\n' "${base_url%/}"
      ;;
  esac
}

_fetch_openai_compatible_models_json() {
  local base_url="${1:-}"
  local api_key="${2:-}"
  [ -n "$base_url" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local endpoint curl_args
  endpoint="$(_models_endpoint_for_base_url "$base_url")"
  curl_args=(-fsSL "$endpoint")
  [ -n "$api_key" ] && curl_args+=(-H "Authorization: Bearer $api_key")

  curl "${curl_args[@]}" 2>/dev/null \
    | jq -c '[.data[]?.id?] | map(select(type == "string" and length > 0)) | unique' 2>/dev/null
}

_fetch_opencode_models_json() {
  command -v opencode >/dev/null 2>&1 || return 1
  opencode models 2>/dev/null | _normalize_model_list_json 2>/dev/null
}

_fetch_models_for_harness_json() {
  local harness="$1"
  local models_json=""

  case "$harness" in
    codex)
      models_json="$(_fetch_openai_compatible_models_json "${OPENAI_BASE_URL:-https://api.openai.com/v1}" "${OPENAI_API_KEY:-}")" || true
      ;;
    opencode)
      models_json="$(_fetch_opencode_models_json)" || true
      if [ -z "$models_json" ] || [ "$models_json" = "[]" ]; then
        models_json="$(_fetch_openai_compatible_models_json "${OPENCODE_BASE_URL:-${OPENAI_BASE_URL:-}}" "${OPENCODE_API_KEY:-${OPENAI_API_KEY:-}}")" || true
      fi
      ;;
    piagent)
      models_json="$(_fetch_openai_compatible_models_json "${PI_BASE_URL:-}" "${PI_API_KEY:-}")" || true
      ;;
    claude_code)
      models_json=""
      ;;
  esac

  if [ -n "$models_json" ] && [ "$models_json" != "[]" ]; then
    printf '%s\n' "$models_json"
    return 0
  fi
  return 1
}

get_harness_models_inventory() {
  local harness="$1"
  local cache_path cache_json live_json
  cache_path="$(_model_cache_path "$harness")"

  if _model_cache_is_fresh "$cache_path"; then
    cache_json="$(_read_model_cache_json "$harness" || true)"
    if [ -n "$cache_json" ] && [ "$cache_json" != "[]" ]; then
      printf '%s\n' "$cache_json"
      return 0
    fi
  fi

  live_json="$(_fetch_models_for_harness_json "$harness" || true)"
  if [ -n "$live_json" ] && [ "$live_json" != "[]" ]; then
    _write_model_cache_json "$harness" "$live_json" >/dev/null 2>&1 || true
    printf '%s\n' "$live_json"
    return 0
  fi

  cache_json="$(_read_model_cache_json "$harness" || true)"
  if [ -n "$cache_json" ] && [ "$cache_json" != "[]" ]; then
    printf '%s\n' "$cache_json"
    return 0
  fi

  _get_static_models_json "$harness"
}
