#!/bin/bash
# lib/harness-exec.sh — Shared harness exec helper (sourced, not executed directly)
#
# Provides a dispatcher for executing prompts via different harnesses (Codex, Opencode, etc.)
# Respects RALPH_HARNESS, RALPH_HARNESS_OVERRIDE, RALPH_MODEL, RALPH_AGENT env vars.
# Also provides automatic agent selection based on story content.

# Default harness if none specified
RALPH_HARNESS_DEFAULT="${RALPH_HARNISH_DEFAULT:-codex}"

# Model and agent selection (if supported by harness)
RALPH_MODEL="${RALPH_MODEL:-}"
RALPH_AGENT="${RALPH_AGENT:-}"

# Paths to configuration files (relative to script directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PROFILES_FILE="$SCRIPT_DIR/agent-profiles.json"
LABEL_MAPPING_FILE="$SCRIPT_DIR/label-to-agent-mapping.json"
HARNESS_CAPABILITIES_FILE="$SCRIPT_DIR/harness-capabilities.json"

# Source harness capabilities helpers
source "$SCRIPT_DIR/harness-capabilities.sh"

# Determine which harness to use
_get_harness() {
  if [ -n "${RALPH_HARNESS_OVERRIDE:-}" ]; then
    echo "$RALPH_HARNESS_OVERRIDE"
  elif [ -n "${RALPH_HARNESS:-}" ]; then
    echo "$RALPH_HARNESS"
  else
    echo "$RALPH_HARNESS_DEFAULT"
  fi
}

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

# Get agent profile suggestion (model, system_prompt, etc.) for a specific harness
_get_agent_profile() {
  local agent_name="$1"
  local harness_name="$2"  # e.g., "codex", "opencode", etc.
  local profile_key="$3"   # e.g., ".models.codex" or ".system_prompt_addition"
  
  _load_json_value "$AGENT_PROFILES_FILE" ".profiles.${agent_name}${profile_key}.${harness_name}"
}

# Determine agent from story content (explicit field, labels, or content analysis)
_determine_agent_from_story() {
  local story_file="$1"
  
  if [ ! -f "$story_file" ]; then
    echo "default"
    return
  fi
  
  # Check for explicit agent field in story.json
  local explicit_agent
  explicit_agent="$(_load_json_value "$story_file" '.agent // empty')"
  if [ -n "$explicit_agent" ]; then
    echo "$explicit_agent"
    return
  fi
  
  # Check for labels/tags array and apply mapping
  local labels
  labels="$(_load_json_value "$story_file" '.labels // []')"
  local tags
  tags="$(_load_json_value "$story_file" '.tags // []')"
  
  # Combine labels and tags
  local all_labels="[$(echo "$labels" "$tags" | jq -s 'add' 2>/dev/null || echo "[]")]"
  
  # Check each label against mapping
  if [ -f "$LABEL_MAPPING_FILE" ] && command -v jq >/dev/null 2>&1; then
    local label_count
    label_count="$(echo "$all_labels" | jq 'length' 2>/dev/null)"
    
    if [ "$label_count" -gt 0 ]; then
      local i=0
      while [ $i -lt "$label_count" ]; do
        local label
        label="$(echo "$all_labels" | jq -r ".[$i] | ascii_downcase" 2>/dev/null)"
        if [ -n "$label" ]; then
          local mapped_agent
          mapped_agent="$(_load_json_value "$LABEL_MAPPING_FILE" ".label_mappings.\"$label\" // empty")"
          if [ -n "$mapped_agent" ]; then
            echo "$mapped_agent"
            return
          fi
        fi
        i=$((i + 1))
      done
    fi
  fi
  
  # Content-based inference from title, description, and tasks
  local title description tasks_content
  title="$(_load_json_value "$story_file" '.title // ""' | tr '[:upper:]' '[:lower:]')"
  description="$(_load_json_value "$story_file" '.description // ""' | tr '[:upper:]' '[:lower:]')"
  tasks_content="$(_load_json_value "$story_file" '.tasks[].title // ""' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
  
  local content="$title $description $tasks_content"
  
  # Define keyword patterns for each agent type
  if echo "$content" | grep -qE "(debug|debugging|investigate|investigation|research|analyze|analysis|troubleshoot|troubleshooting|diagnose|diagnosis|root cause|explore|exploration)"; then
    echo "researcher"
    return
  fi
  
  if echo "$content" | grep -qE "(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|sql injection|xxe|rce|privilege|escalation|audit|auditing|compliance)"; then
    echo "security"
    return
  fi
  
  if echo "$content" | grep -qE "(typo|typos|text|string|label|labels|button|buttons|ui|ux|frontend|minor|minors|small|trivial|fix|fixes|fixing|spelling|grammar|style|styling|css|ui/css|theme|theming|color|colors|font|fonts|icon|icons|image|images|logo|logos)"; then
    echo "junior-dev"
    return
  fi
  
  if echo "$content" | grep -qE "(refactor|refactoring|restructure|restructuring|architecture|architectural|design|design pattern|design patterns|pattern|patterns|scalability|scalable|performance|optimize|optimization|efficiency|algorithm|algorithms|data structure|database|db|sql|nosql|api|microservice|microservices|service|services|backend|system|systems|enterprise)"; then
    echo "senior-dev"
    return
  fi
  
  if echo "$content" | grep -qE "(test|testing|unit test|unit-test|integration test|integration-test|e2e|end-to-end|end to end|validation|valid|verify|verification|assert|assertion|mock|mocks|stub|stubs|fixture|fixtures|test case|test cases|test suite|test driven|tdd|bdd)"; then
    echo "qa-test"
    return
  fi
  
  if echo "$content" | grep -qE "(deploy|deployment|deploying|infrastructure|infrastructural|docker|kubernetes|k8s|aws|azure|gcp|cloud|server|servers|network|networking|ci|ci/cd|continuous integration|continuous delivery|continuous deployment|pipeline|pipelines|jenkins|gitlab|github actions|terraform|ansible|puppet|chef|monitoring|logging|logs|metrics|alerting)"; then
    echo "devops"
    return
  fi
  
  if echo "$content" | grep -qE "(doc|documentation|comment|comments|explain|explanation|description|descriptions|readme|readmes|guide|guides|tutorial|tutorials|walkthrough|faq|faqs|wiki|wikis|markdown|md)"; then
    echo "documentation"
    return
  fi
  
  # Fallback to default agent
  echo "default"
}

# Get effective agent (explicit override > story-determined > default)
_get_effective_agent() {
  local story_file="$1"
  
  # Check for explicit override via environment or command line (highest priority)
  if [ -n "${RALPH_AGENT:-}" ]; then
    echo "$RALPH_AGENT"
    return
  fi
  
  # Check for agent determined from story content
  local story_agent
  story_agent="$(_determine_agent_from_story "$story_file")"
  if [ -n "$story_agent" ] && [ "$story_agent" != "default" ]; then
    echo "$story_agent"
    return
  fi
  
  # Fall back to default agent
  echo "default"
}

# Apply agent profile settings (model, etc.)
_apply_agent_profile() {
  local agent_name="$1"
  
  # Determine effective harness (same logic as in harness_exec_prompt)
  local effective_harness
  effective_harness="$(_get_harness)"
  
  # Only override model if not explicitly set via command line/environment
  if [ -z "${RALPH_MODEL:-}" ]; then
    local suggested_model
    suggested_model="$(_get_agent_profile "$agent_name" "$effective_harness" '.models')"
    if [ -n "$suggested_model" ]; then
      RALPH_MODEL="$suggested_model"
      export RALPH_MODEL
    fi
  fi
  
  # Note: System prompt additions would need to be handled by modifying the prompt itself
  # This is more complex and would require changes to the prompt building logic
  # For now, we focus on model selection, but the profile contains system_prompt_addition
  # for future enhancement
}

# Harness-specific execution functions

# Original Codex executor (from codex-exec.sh)
_codex_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  local profile_args=()
  [ -n "${RALPH_CODEX_PROFILE:-}" ] && profile_args=(--profile "$RALPH_CODEX_PROFILE")
  local model_args=()
  [ -n "${RALPH_MODEL:-}" ] && harness_supports_model_selection "codex" && model_args=(--model "$RALPH_MODEL")
  local agent_args=()
  [ -n "${RALPH_AGENT:-}" ] && harness_supports_agent_selection "codex" && agent_args=(--agent "$RALPH_AGENT")
  
  if _supports_codex_yolo; then
    printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" --yolo exec "${profile_args[@]+"${profile_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "${agent_args[@]+"${agent_args[@]}"}" -C "$workspace" "$@" -
  else
    printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" exec --dangerously-bypass-approvals-and-sandbox "${profile_args[@]+"${profile_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "${agent_args[@]+"${agent_args[@]}"}" -C "$workspace" "$@" -
  fi
}

# Opencode executor
_opencode_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  
  # Opencode uses `opencode run` for non-interactive execution
  # --dangerously-skip-permissions to bypass approvals
  local opencode_args=("--dangerously-skip-permissions")
  
  # Add model selection if specified
  [ -n "${RALPH_MODEL:-}" ] && opencode_args+=("--model" "$RALPH_MODEL")
  
  # Add agent selection if specified
  [ -n "${RALPH_AGENT:-}" ] && opencode_args+=("--agent" "$RALPH_AGENT")
  
  # Pass through any additional arguments (like -c/--continue, etc.)
  opencode_args+=("$@")
  
  # Change to workspace directory and run opencode with prompt via stdin
  (
    cd "$workspace"
    printf '%s\n' "$prompt" | opencode run "${opencode_args[@]}" -
  )
}

# PI Agent executor
_piagent_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  
  # PI Agent uses `pi -p` for print/non-interactive mode
  # Permission bypass via PI_PERMISSION_LEVEL=bypassed
  local pi_env=(PI_PERMISSION_LEVEL=bypassed)
  
  # Build arguments array
  local pi_args=("$prompt")
  
  # Add model selection if specified (if supported by PI Agent)
  [ -n "${RALPH_MODEL:-}" ] && pi_args+=("--model" "$RALPH_MODEL")
  
  # Add agent selection if specified (if supported by PI Agent)
  [ -n "${RALPH_AGENT:-}" ] && pi_args+=("--agent" "$RALPH_AGENT")
  
  # Pass through any additional arguments
  pi_args+=("$@")
  
  # Change to workspace directory and run pi with prompt
  (
    cd "$workspace"
    "${pi_env[@]}" pi -p "${pi_args[@]}"
  )
}

# Claude Code executor
_claude_code_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  
  # Claude Code uses `claude -p` for print/non-interactive mode
  # For fully non-interactive/CI use, --permission-mode dontAsk is better
  # than --dangerously-skip-permissions which may show initial dialog
  local claude_args=("--permission-mode" "dontAsk")
  
   # Add model selection if specified and supported
   if [ -n "${RALPH_MODEL:-}" ] && harness_supports_model_selection "claude_code"; then
       claude_args+=("--model" "$RALPH_MODEL")
   fi
  
  # Note: Claude Code doesn't have explicit agent selection like Codex/Opencode
  # Agent behavior is controlled via permission modes and system prompt
  
  # Pass through any additional arguments (like --max-turns, etc.)
  claude_args+=("$@")
  
  # Change to workspace directory and run claude with prompt
  (
    cd "$workspace"
    claude -p "$prompt" "${claude_args[@]}"
  )
}

# Harness-specific execution functions

# Original Codex executor (from codex-exec.sh)
_codex_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  local profile_args=()
  [ -n "${RALPH_CODEX_PROFILE:-}" ] && profile_args=(--profile "$RALPH_CODEX_PROFILE")
  local model_args=()
  [ -n "${RALPH_MODEL:-}" ] && harness_supports_model_selection "codex" && model_args=(--model "$RALPH_MODEL")
  local agent_args=()
  [ -n "${RALPH_AGENT:-}" ] && harness_supports_agent_selection "codex" && agent_args=(--agent "$RALPH_AGENT")
  
  if _supports_codex_yolo; then
    printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" --yolo exec "${profile_args[@]+"${profile_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "${agent_args[@]+"${agent_args[@]}"}" -C "$workspace" "$@" -
  else
    printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" exec --dangerously-bypass-approvals-and-sandbox "${profile_args[@]+"${profile_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "${agent_args[@]+"${agent_args[@]}"}" -C "$workspace" "$@" -
  fi
}

# Opencode executor
_opencode_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  
  # Opencode uses `opencode run` for non-interactive execution
  # --dangerously-skip-permissions to bypass approvals
  local opencode_args=("--dangerously-skip-permissions")
  
  # Add model selection if specified
  [ -n "${RALPH_MODEL:-}" ] && opencode_args+=("--model" "$RALPH_MODEL")
  
  # Add agent selection if specified
  [ -n "${RALPH_AGENT:-}" ] && opencode_args+=("--agent" "$RALPH_AGENT")
  
  # Pass through any additional arguments (like -c/--continue, etc.)
  opencode_args+=("$@")
  
  # Change to workspace directory and run opencode with prompt via stdin
  (
    cd "$workspace"
    printf '%s\n' "$prompt" | opencode run "${opencode_args[@]}" -
  )
}

# PI Agent executor
_piagent_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  
  # PI Agent uses `pi -p` for print/non-interactive mode
  # Permission bypass via PI_PERMISSION_LEVEL=bypassed
  local pi_env=(PI_PERMISSION_LEVEL=bypassed)
  
  # Build arguments array
  local pi_args=("$prompt")
  
  # Add model selection if specified (if supported by PI Agent)
  [ -n "${RALPH_MODEL:-}" ] && pi_args+=("--model" "$RALPH_MODEL")
  
  # Add agent selection if specified (if supported by PI Agent)
  [ -n "${RALPH_AGENT:-}" ] && pi_args+=("--agent" "$RALPH_AGENT")
  
  # Pass through any additional arguments
  pi_args+=("$@")
  
  # Change to workspace directory and run pi with prompt
  (
    cd "$workspace"
    "${pi_env[@]}" pi -p "${pi_args[@]}"
  )
}

# Claude Code executor
_claude_code_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  
  # Claude Code uses `claude -p` for print/non-interactive mode
  # For fully non-interactive/CI use, --permission-mode dontAsk is better
  # than --dangerously-skip-permissions which may show initial dialog
  local claude_args=("--permission-mode" "dontAsk")
  
   # Add model selection if specified and supported
   if [ -n "${RALPH_MODEL:-}" ] && harness_supports_model_selection "claude_code"; then
     claude_args+=("--model" "$RALPH_MODEL")
   fi
  
  # Pass through any additional arguments (like --max-turns, etc.)
  claude_args+=("$@")
  
  # Change to workspace directory and run claude with prompt
  (
    cd "$workspace"
    claude -p "$prompt" "${claude_args[@]}"
  )
}

# Dispatcher function
harness_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  local harness="$(_get_harness)"
  case "$harness" in
    codex)
      _codex_exec_prompt "$prompt" "$workspace" "$@"
      ;;
    opencode)
      _opencode_exec_prompt "$prompt" "$workspace" "$@"
      ;;
    piagent)
      _piagent_exec_prompt "$prompt" "$workspace" "$@"
      ;;
    claude_code)
      _claude_code_exec_prompt "$prompt" "$workspace" "$@"
      ;;
    *)
      echo "ERROR: Unknown harness '$harness'. Supported: codex, opencode, piagent, claude_code" >&2
      return 1
      ;;
  esac
}

# Helper to check if Codex supports --yolo (moved from codex-exec.sh for sharing)
_supports_codex_yolo() {
  local out
  out="$("${CODEX_BIN:-codex}" --yolo exec --help 2>&1 || true)"
  echo "$out" | grep -qi "unexpected argument '--yolo'" && return 1
  echo "$out" | grep -qi "Run Codex non-interactively" && return 0
  return 1
}