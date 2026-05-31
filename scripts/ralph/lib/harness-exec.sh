#!/bin/bash
# lib/harness-exec.sh — Shared harness exec helper (sourced, not executed directly)
#
# Provides a dispatcher for executing prompts via different harnesses (Codex, Opencode, etc.)
# Respects RALPH_HARNESS, RALPH_HARNESS_OVERRIDE, RALPH_MODEL, RALPH_AGENT env vars.
# Also provides automatic agent selection based on story content.

# Default harness if none specified
RALPH_HARNESS_DEFAULT="${RALPH_HARNISH_DEFAULT:-codex}"

# Model and agent selection (if supported by harness)
# Paths to configuration files (relative to this library directory)
HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PROFILES_FILE="$HARNESS_LIB_DIR/agent-profiles.json"
LABEL_MAPPING_FILE="$HARNESS_LIB_DIR/label-to-agent-mapping.json"
HARNESS_CAPABILITIES_FILE="$HARNESS_LIB_DIR/harness-capabilities.json"

# Source harness capabilities helpers
source "$HARNESS_LIB_DIR/harness-capabilities.sh"

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
  local profile_key="${3:-}"   # e.g., ".models.codex" or ".system_prompt_addition"

  if [ ! -f "$AGENT_PROFILES_FILE" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  jq -r --arg agent_name "$agent_name" --arg harness_name "$harness_name" '
    .profiles[$agent_name]
    | if . == null then empty else . end
    | if has("models") then .models[$harness_name] // empty else empty end
  ' "$AGENT_PROFILES_FILE" 2>/dev/null
}

_resolve_opencode_model() {
  local requested_model="$1"
  [ -n "$requested_model" ] || return 0

  case "$requested_model" in
    */*)
      echo "$requested_model"
      return
      ;;
  esac

  local provider_base="${OPENCODE_BASE_URL:-${OPENAI_BASE_URL:-}}"
  case "$provider_base" in
    *openrouter.ai*)
      case "$requested_model" in
        gpt-3.5-turbo|gpt-4|gpt-4-turbo|gpt-4o|gpt-4.1|gpt-4.1-mini|gpt-4.1-nano|gpt-5|gpt-5-mini|gpt-5-nano|gpt-5-pro|gpt-5-codex|gpt-5.1-codex|gpt-5.1-codex-mini|gpt-5.2-codex)
          echo "openrouter/openai/$requested_model"
          return
          ;;
        claude-3-haiku|claude-haiku-4-5|claude-haiku-4.5)
          echo "openrouter/anthropic/claude-haiku-4.5"
          return
          ;;
        claude-3-sonnet|claude-sonnet-4-6|claude-sonnet-4.6)
          echo "openrouter/anthropic/claude-sonnet-4.6"
          return
          ;;
        claude-3-opus|claude-opus-4-7|claude-opus-4.7)
          echo "openrouter/anthropic/claude-opus-4.7"
          return
          ;;
      esac
      ;;
  esac

  echo "$requested_model"
}

_resolve_codex_model() {
  local requested_model="$1"
  [ -n "$requested_model" ] || return 0

  case "$requested_model" in
    openai/*)
      printf '%s\n' "${requested_model#openai/}"
      return
      ;;
    openrouter/openai/*)
      printf '%s\n' "${requested_model#openrouter/openai/}"
      return
      ;;
    openrouter/*|anthropic/*)
      printf '%s\n' "${requested_model#*/}"
      return
      ;;
  esac

  printf '%s\n' "$requested_model"
}

_resolve_piagent_model() {
  local requested_model="$1"
  [ -n "$requested_model" ] || return 0

  local provider_base="${PI_BASE_URL:-${OPENAI_BASE_URL:-}}"

  if [[ "$provider_base" == *openrouter.ai* ]]; then
    case "$requested_model" in
      openrouter/*)
        printf '%s\n' "$requested_model"
        return
        ;;
      openai/*)
        printf 'openrouter/%s\n' "$requested_model"
        return
        ;;
      anthropic/*)
        printf 'openrouter/%s\n' "$requested_model"
        return
        ;;
    esac
  fi

  case "$requested_model" in
    openrouter/*|anthropic/*|google/*|openai/*)
      printf '%s\n' "$requested_model"
      return
      ;;
  esac

  case "$provider_base" in
    *openrouter.ai*)
      case "$requested_model" in
        gpt-*|o1|o3|o4-*)
          printf 'openrouter/openai/%s\n' "$requested_model"
          return
          ;;
        claude-3-haiku|claude-haiku-4-5|claude-haiku-4.5)
          printf '%s\n' "openrouter/anthropic/claude-haiku-4.5"
          return
          ;;
        claude-3-sonnet|claude-sonnet-4-6|claude-sonnet-4.6)
          printf '%s\n' "openrouter/anthropic/claude-sonnet-4.6"
          return
          ;;
        claude-3-opus|claude-opus-4-7|claude-opus-4.7)
          printf '%s\n' "openrouter/anthropic/claude-opus-4.7"
          return
          ;;
      esac
      ;;
  esac

  printf '%s\n' "$requested_model"
}

_model_family_name() {
  local model="$1"
  local lower
  lower="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  lower="${lower##*/}"
  printf '%s\n' "$lower"
}

_agent_selection_priority() {
  local agent_name="$1"
  case "$agent_name" in
    researcher|senior-dev|security)
      echo "heavy"
      ;;
    qa-test|devops)
      echo "strong"
      ;;
    documentation|junior-dev|default|*)
      echo "economy"
      ;;
  esac
}

_score_model_for_agent() {
  local agent_name="$1"
  local harness_name="$2"
  local model="$3"
  local priority lower score=0 provider_base

  priority="$(_agent_selection_priority "$agent_name")"
  lower="$(_model_family_name "$model")"
  provider_base="${OPENCODE_BASE_URL:-${OPENAI_BASE_URL:-}}"

  case "$lower" in
    *embedding*|*moderation*|*realtime*|*audio*|*transcribe*|*tts*|*image*|*search-preview*)
      echo -1000
      return
      ;;
  esac

  case "$harness_name" in
    codex)
      case "$model" in
        openai/*|gpt-*|o1|o3|o4-*)
          score=$((score + 300))
          ;;
        anthropic/*|openrouter/anthropic/*|claude-*)
          score=$((score - 250))
          ;;
        */*)
          score=$((score - 75))
          ;;
      esac
      ;;
    opencode)
      case "$provider_base" in
        *openrouter.ai*)
          case "$model" in
            openrouter/*) score=$((score + 400)) ;;
            opencode/*)   score=$((score - 200)) ;;
          esac
          ;;
      esac
      ;;
  esac

  case "$priority" in
    heavy)
      case "$lower" in
        *gpt-5.2-codex*|*gpt-5.1-codex*|*gpt-5-codex*|*gpt-5.2*|*gpt-5.1*|*gpt-5-pro*|*gpt-5*|*gpt-4.1*|*gpt-4o*|*gpt-4-turbo*|*claude-opus*|*claude-sonnet-4*|*claude-sonnet-latest*|*deepseek-r1*|*deepseek-v4-pro*)
          score=$((score + 120))
          ;;
        *gpt-mini*|*mini*|*nano*|*haiku*|*flash-lite*|*:free)
          score=$((score - 40))
          ;;
      esac
      ;;
    strong)
      case "$lower" in
        *gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*)
          score=$((score + 120))
          ;;
        *gpt-5*|*gpt-4.1*|*gpt-4o*|*gpt-4-turbo*|*claude-sonnet*|*claude-opus*|*deepseek-v4*|*codestral*|*devstral*)
          score=$((score + 90))
          ;;
        *mini*|*nano*|*haiku*|*flash-lite*)
          score=$((score - 20))
          ;;
      esac
      ;;
    economy)
      case "$lower" in
        *gpt-mini-latest*|*gpt-4o-mini*|*gpt-4.1-mini*|*gpt-4.1-nano*|*gpt-5-mini*|*gpt-5-nano*|*gpt-3.5-turbo*|*haiku*|*mini*|*nano*|*flash-lite*|*:free)
          score=$((score + 100))
          ;;
        *opus*|*pro*|*large*|*gpt-5.2*|*gpt-5.1*|*gpt-5-codex*)
          score=$((score - 35))
          ;;
      esac
      ;;
  esac

  case "$agent_name" in
    documentation)
      ;;
    qa-test|devops)
      case "$lower" in
        *gpt-5.4-mini*)
          score=$((score + 40))
          ;;
        *gpt-5-codex*)
          score=$((score - 30))
          ;;
      esac
      ;;
    *)
      case "$lower" in
        *codex*|*codestral*|*devstral*|*coder*)
          score=$((score + 15))
          ;;
      esac
      ;;
  esac

  echo "$score"
}

_select_dynamic_model_for_agent() {
  local agent_name="$1"
  local harness_name="$2"
  local inventory_json best_model="" best_score=-10000
  local model score

  inventory_json="$(get_harness_models_inventory "$harness_name" 2>/dev/null || echo "[]")"
  [ -n "$inventory_json" ] || return 0
  [ "$inventory_json" != "[]" ] || return 0

  while IFS= read -r model; do
    [ -n "$model" ] || continue
    score="$(_score_model_for_agent "$agent_name" "$harness_name" "$model")"
    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_model="$model"
    fi
  done < <(printf '%s' "$inventory_json" | jq -r '.[]')

  [ -n "$best_model" ] || return 0
  printf '%s\n' "$best_model"
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
  if echo "$content" | rg -q "(debug|debugging|investigate|investigation|research|analyze|analysis|troubleshoot|troubleshooting|diagnose|diagnosis|root cause|explore|exploration)"; then
    echo "researcher"
    return
  fi

  if echo "$content" | rg -q "(refactor|refactoring|restructure|restructuring|architecture|architectural|design|design pattern|design patterns|pattern|patterns|scalability|scalable|performance|optimize|optimization|efficiency|algorithm|algorithms|data structure|database|db|sql|nosql|api|microservice|microservices|service|services|backend|system|systems|enterprise)"; then
    echo "senior-dev"
    return
  fi

  # Security terms with word boundaries for single words, and substring for multi-word term
  if echo "$content" | rg -q '(^|[^a-zA-Z0-9_])(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|xxe|rce|privilege|escalation|audit|auditing|compliance)([^a-zA-Z0-9_]|$)' || echo "$content" | rg -q "sql injection"; then
    echo "security"
    return
  fi

  if echo "$content" | rg -q "(typo|typos|text|string|label|labels|button|buttons|ui|ux|frontend|minor|minors|small|trivial|fix|fixes|fixing|spelling|grammar|style|styling|css|ui/css|theme|theming|color|colors|font|fonts|icon|icons|image|images|logo|logos)"; then
    echo "junior-dev"
    return
  fi

  if echo "$content" | rg -q "(test|testing|unit test|unit-test|integration test|integration-test|e2e|end-to-end|end to end|validation|valid|verify|verification|assert|assertion|mock|mocks|stub|stubs|fixture|fixtures|test case|test cases|test suite|test driven|tdd|bdd)"; then
    echo "qa-test"
    return
  fi

  if echo "$content" | rg -q "(deploy|deployment|deploying|infrastructure|infrastructural|docker|kubernetes|k8s|aws|azure|gcp|cloud|server|servers|network|networking|ci|ci/cd|continuous integration|continuous delivery|continuous deployment|pipeline|pipelines|jenkins|gitlab|github actions|terraform|ansible|puppet|chef|monitoring|logging|logs|metrics|alerting)"; then
    echo "devops"
    return
  fi

  if echo "$content" | rg -q "(doc|documentation|comment|comments|explain|explanation|description|descriptions|readme|readmes|guide|guides|tutorial|tutorials|walkthrough|faq|faqs|wiki|wikis|markdown|md)"; then
    echo "documentation"
    return
  fi
  if echo "$content" | rg -q "(doc|documentation|comment|comments|explain|explanation|description|descriptions|readme|readmes|guide|guides|tutorial|tutorials|walkthrough|faq|faqs|wiki|wikis|markdown|md)"; then
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
    suggested_model="$(_select_dynamic_model_for_agent "$agent_name" "$effective_harness")"
    if [ -z "$suggested_model" ]; then
      suggested_model="$(_get_agent_profile "$agent_name" "$effective_harness" '.models')"
    fi
    if [ -n "$suggested_model" ]; then
      case "$effective_harness" in
        codex)
          suggested_model="$(_resolve_codex_model "$suggested_model")"
          ;;
        opencode)
          suggested_model="$(_resolve_opencode_model "$suggested_model")"
          ;;
        piagent)
          suggested_model="$(_resolve_piagent_model "$suggested_model")"
          ;;
      esac
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

  # PI Agent uses `pi -p` for print/non-interactive mode.
  # Set the permission mode as an environment variable for the command.

  # Build arguments array
  local pi_args=("$prompt")

  local pi_provider="${PI_PROVIDER:-}"
  local resolved_model="${RALPH_MODEL:-}"
  local pi_provider_base="${PI_BASE_URL:-${OPENAI_BASE_URL:-}}"
  if [ -z "$pi_provider" ] && [ -n "$resolved_model" ]; then
    case "$resolved_model" in
      openrouter/*)
        pi_provider="openrouter"
        resolved_model="${resolved_model#openrouter/}"
        ;;
      anthropic/*)
        pi_provider="anthropic"
        resolved_model="${resolved_model#anthropic/}"
        ;;
      openai/*)
        pi_provider="openai"
        resolved_model="${resolved_model#openai/}"
        ;;
      google/*)
        pi_provider="google"
        resolved_model="${resolved_model#google/}"
        ;;
    esac
  fi

  if [ -z "$pi_provider" ] && [[ "$pi_provider_base" == *openrouter.ai* ]]; then
    pi_provider="openrouter"
  fi

  # Add model selection if specified (if supported by PI Agent)
  [ -n "$pi_provider" ] && pi_args+=("--provider" "$pi_provider")
  [ -n "$resolved_model" ] && pi_args+=("--model" "$resolved_model")

  # Add agent selection if specified (if supported by PI Agent)
  [ -n "${RALPH_AGENT:-}" ] && pi_args+=("--agent" "$RALPH_AGENT")

  # Pass through any additional arguments
  pi_args+=("$@")

  # Change to workspace directory and run pi with prompt
  (
    cd "$workspace"
    PI_PERMISSION_LEVEL=bypassed pi -p "${pi_args[@]}"
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

  # PI Agent uses `pi -p` for print/non-interactive mode.
  # Set the permission mode as an environment variable for the command.

  # Build arguments array
  local pi_args=("$prompt")

  local pi_provider="${PI_PROVIDER:-}"
  local resolved_model="${RALPH_MODEL:-}"
  local pi_provider_base="${PI_BASE_URL:-${OPENAI_BASE_URL:-}}"
  if [ -z "$pi_provider" ] && [ -n "$resolved_model" ]; then
    case "$resolved_model" in
      openrouter/*)
        pi_provider="openrouter"
        resolved_model="${resolved_model#openrouter/}"
        ;;
      anthropic/*)
        pi_provider="anthropic"
        resolved_model="${resolved_model#anthropic/}"
        ;;
      openai/*)
        pi_provider="openai"
        resolved_model="${resolved_model#openai/}"
        ;;
      google/*)
        pi_provider="google"
        resolved_model="${resolved_model#google/}"
        ;;
    esac
  fi

  if [ -z "$pi_provider" ] && [[ "$pi_provider_base" == *openrouter.ai* ]]; then
    pi_provider="openrouter"
  fi

  # Add model selection if specified (if supported by PI Agent)
  [ -n "$pi_provider" ] && pi_args+=("--provider" "$pi_provider")
  [ -n "$resolved_model" ] && pi_args+=("--model" "$resolved_model")

  # Add agent selection if specified (if supported by PI Agent)
  [ -n "${RALPH_AGENT:-}" ] && pi_args+=("--agent" "$RALPH_AGENT")

  # Pass through any additional arguments
  pi_args+=("$@")

  # Change to workspace directory and run pi with prompt
  (
    cd "$workspace"
    PI_PERMISSION_LEVEL=bypassed pi -p "${pi_args[@]}"
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
  echo "$out" | rg -qi "unexpected argument '--yolo'" && return 1
  echo "$out" | rg -qi "Run Codex non-interactively" && return 0
  return 1
}
