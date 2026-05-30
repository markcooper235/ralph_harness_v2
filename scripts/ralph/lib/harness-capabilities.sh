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