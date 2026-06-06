#!/bin/bash
# lib/harness-exec.sh — Shared harness exec helper (sourced, not executed directly)
#
# Provides a dispatcher for executing prompts via different harnesses (Codex, PI Agent)
# Respects RALPH_HARNESS, RALPH_HARNESS_OVERRIDE, RALPH_MODEL, RALPH_AGENT env vars.
# Also provides automatic agent selection based on story content.

# Default harness if none specified
RALPH_HARNESS_DEFAULT="${RALPH_HARNESS_DEFAULT:-${RALPH_HARNISH_DEFAULT:-codex}}"

# Model and agent selection (if supported by harness)
# Paths to configuration files (relative to this library directory)
HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_RUNTIME_BASE_DIR="$(cd "$HARNESS_LIB_DIR/.." && pwd)"
AGENT_PROFILES_FILE="$HARNESS_LIB_DIR/agent-profiles.json"
COMPOSITE_PROFILES_FILE="$HARNESS_LIB_DIR/composite-profiles.json"
LABEL_MAPPING_FILE="$HARNESS_LIB_DIR/label-to-agent-mapping.json"
HARNESS_CAPABILITIES_FILE="$HARNESS_LIB_DIR/harness-capabilities.json"
RALPH_RUNTIME_HOME_DIR="${RALPH_HOME_DIR:-$RALPH_RUNTIME_BASE_DIR/runtime/home}"
RALPH_REPO_ROOT="$(cd "$HARNESS_LIB_DIR/../../.." && pwd)"
RALPH_RUNTIME_HOME_CONFIG_FILE="$RALPH_RUNTIME_HOME_DIR/.codex/config.toml"
RALPH_RUNTIME_PI_AGENT_DIR="$RALPH_RUNTIME_HOME_DIR/.pi/agent"
RALPH_RUNTIME_PI_SETTINGS_FILE="$RALPH_RUNTIME_PI_AGENT_DIR/settings.json"
RALPH_RUNTIME_PI_MODELS_FILE="$RALPH_RUNTIME_PI_AGENT_DIR/models.json"

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

_get_harness_selection_source() {
  if [ -n "${RALPH_HARNESS_SELECTION_SOURCE:-}" ]; then
    echo "$RALPH_HARNESS_SELECTION_SOURCE"
  elif [ -n "${RALPH_HARNESS_OVERRIDE:-}" ]; then
    echo "override"
  elif [ -n "${RALPH_HARNESS:-}" ]; then
    echo "explicit"
  else
    echo "default"
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

_story_input_json() {
  local input="${1:-}"
  [ -n "$input" ] || return 0
  if [ -f "$input" ]; then
    cat "$input"
  else
    printf '%s' "$input"
  fi
}

_normalize_story_metadata_json() {
  local input="${1:-}"
  _story_input_json "$input" | jq -c '
    {
      storyId: (.storyId // .id // ""),
      title: (.title // ""),
      description: (.description // ""),
      goal: (.goal // ""),
      promptContext: (.promptContext // ""),
      agent: (.agent // ""),
      labels: (.labels // []),
      tags: (.tags // []),
      tasks: (
        (.tasks // [])
        | map(
            if type == "object" then
              (.title // .context // .acceptance // "")
            else
              ""
            end
          )
      )
    }
  ' 2>/dev/null
}

# Get a field from an agent profile for a specific harness
_get_agent_profile_field() {
  local agent_name="$1"
  local harness_name="$2"  # e.g., "codex" or "piagent"
  local profile_key="${3:-}"   # e.g., ".models.codex" or ".system_prompt_addition"

  if [ ! -f "$AGENT_PROFILES_FILE" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  jq -cr --arg agent_name "$agent_name" --arg harness_name "$harness_name" --arg profile_key "$profile_key" '
    .profiles[$agent_name]
    | if . == null then empty else . end
    | if $profile_key == ".models" then
        if has("models") then .models[$harness_name] // empty else empty end
      elif $profile_key == ".lite_models" then
        if has("lite_models") then .lite_models[$harness_name] // empty else empty end
      elif $profile_key == "." then
        .
      else
        getpath(($profile_key | ltrimstr(".") | split("."))) // empty
      end
  ' "$AGENT_PROFILES_FILE" 2>/dev/null
}

# Backwards-compatible model lookup for agent profiles
_get_agent_profile() {
  _get_agent_profile_field "$1" "$2" ".models"
}

# Get a field from a static composite profile
_get_composite_profile_field() {
  local composite_name="$1"
  local field_path="${2:-}"

  if [ ! -f "$COMPOSITE_PROFILES_FILE" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  jq -cr --arg composite_name "$composite_name" --arg field_path "$field_path" '
    .profiles[$composite_name]
    | if . == null then empty else . end
    | if $field_path == "" then . else getpath(($field_path | ltrimstr(".") | split("."))) // empty end
  ' "$COMPOSITE_PROFILES_FILE" 2>/dev/null
}

_get_composite_profile() {
  local composite_name="$1"
  [ -n "$composite_name" ] || return 0
  _get_composite_profile_field "$composite_name" ""
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
    opencode/*|openrouter/*|anthropic/*|google/*|openai/*)
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
        claude-3-opus|claude-opus-4-8|claude-opus-4.8)
          printf '%s\n' "openrouter/anthropic/claude-opus-4.8"
          return
          ;;
      esac
      ;;
  esac

  printf '%s\n' "$requested_model"
}

_resolve_model_for_harness() {
  local requested_model="$1"
  local harness_name="$2"

  case "$harness_name" in
    codex)
      _resolve_codex_model "$requested_model"
      ;;
    piagent)
      _resolve_piagent_model "$requested_model"
      ;;
    *)
      printf '%s\n' "$requested_model"
      ;;
  esac
}

_model_family_name() {
  local model="$1"
  local lower
  lower="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  lower="${lower##*/}"
  printf '%s\n' "$lower"
}

_ensure_ralph_runtime_home() {
  mkdir -p \
    "$RALPH_RUNTIME_HOME_DIR" \
    "$RALPH_RUNTIME_HOME_DIR/.config" \
    "$RALPH_RUNTIME_HOME_DIR/.cache" \
    "$RALPH_RUNTIME_HOME_DIR/.local/state" \
    "$RALPH_RUNTIME_HOME_DIR/.local/share" \
    "$RALPH_RUNTIME_HOME_DIR/.codex" \
    "$RALPH_RUNTIME_PI_AGENT_DIR"
}

_resolve_codex_runtime_profile_name() {
  if [ -n "${RALPH_CODEX_PROFILE:-}" ]; then
    printf '%s\n' "$RALPH_CODEX_PROFILE"
    return 0
  fi

  if [ -n "${OPENAI_BASE_URL:-}" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
    printf '%s\n' "ralph_primary"
    return 0
  fi

  if [ -n "${OPENAI_API_BASE_NATIVE:-}" ] && [ -n "${OPENAI_API_KEY_NATIVE:-}" ]; then
    printf '%s\n' "ralph_openai_native"
    return 0
  fi
}

_seed_ralph_runtime_home_config() {
  _ensure_ralph_runtime_home

  cat > "$RALPH_RUNTIME_HOME_CONFIG_FILE" <<EOF
model = 'gpt-5.4'
model_reasoning_effort = 'medium'

[model_providers.ralph_primary]
name = "Ralph Primary Provider"
base_url = "${OPENAI_BASE_URL:-https://api.openai.com/v1}"
env_key = "OPENAI_API_KEY"
wire_api = "responses"

[profiles.ralph_primary]
model_provider = "ralph_primary"

[model_providers.ralph_openai_native]
name = "Ralph OpenAI Native"
base_url = "${OPENAI_API_BASE_NATIVE:-https://api.openai.com/v1}"
env_key = "OPENAI_API_KEY_NATIVE"
wire_api = "responses"

[profiles.ralph_openai_native]
model_provider = "ralph_openai_native"

[projects."$RALPH_REPO_ROOT"]
trust_level = "trusted"

[notice]
hide_full_access_warning = true
EOF
}

_seed_ralph_runtime_pi_config() {
  _ensure_ralph_runtime_home

  cat > "$RALPH_RUNTIME_PI_SETTINGS_FILE" <<'EOF'
{
  "lastChangelogVersion": "0.76.0",
  "defaultProvider": "openai-native",
  "defaultModel": "gpt-5.4",
  "defaultThinkingLevel": "medium",
  "packages": [
    "npm:pi-subagents"
  ]
}
EOF

  cat > "$RALPH_RUNTIME_PI_MODELS_FILE" <<'EOF'
{
  "providers": {
    "openai-native": {
      "baseUrl": "https://api.openai.com/v1",
      "api": "openai-responses",
      "apiKey": "OPENAI_API_KEY",
      "models": [
        { "id": "gpt-5.4" },
        { "id": "gpt-5.5" }
      ]
    }
  }
}
EOF
}

_story_complexity_text() {
  local story_json
  story_json="$(_normalize_story_metadata_json "${1:-}")"
  [ -n "$story_json" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  printf '%s' "$story_json" | jq -r '
    [
      (.title // ""),
      (.description // ""),
      (.goal // ""),
      (.promptContext // ""),
      (.agent // ""),
      (.storyId // ""),
      (.labels[]?),
      (.tags[]?),
      (.tasks[]?)
    ]
    | map(select(length > 0))
    | join(" ")
  ' 2>/dev/null
}

_story_complexity_score() {
  local story_json="${1:-}"
  local text task_count label_count word_count path_count score=0
  local complexity_tier

  text="$(_story_complexity_text "$story_json")"
  [ -n "$text" ] || { echo 0; return 0; }

  task_count="$(printf '%s' "$story_json" | jq -r '((.tasks // []) | length) // 0' 2>/dev/null || echo 0)"
  label_count="$(printf '%s' "$story_json" | jq -r '((.labels // []) | length) + ((.tags // []) | length)' 2>/dev/null || echo 0)"
  word_count="$(printf '%s' "$text" | tr -cs '[:alnum:]/._-' '\n' | sed '/^$/d' | wc -l | awk '{print $1}')"
  path_count="$(printf '%s' "$text" | rg -o '[[:alnum:]_.-]+(/[[:alnum:]_.-]+)+' 2>/dev/null | awk 'END { print NR + 0 }')"

  task_count="${task_count:-0}"
  label_count="${label_count:-0}"
  word_count="${word_count:-0}"
  path_count="${path_count:-0}"

  score=$((score + ((task_count > 1 ? task_count - 1 : 0) * 4)))
  score=$((score + (label_count > 4 ? 12 : label_count * 2)))
  score=$((score + (path_count > 4 ? 12 : path_count * 3)))

  if [ "$word_count" -ge 280 ]; then
    score=$((score + 12))
  elif [ "$word_count" -ge 160 ]; then
    score=$((score + 8))
  elif [ "$word_count" -ge 80 ]; then
    score=$((score + 4))
  fi

  if printf '%s' "$text" | rg -q "(security|vulnerability|vulnerabilities|exploit|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|oauth|password|secret|key|cert|certificate|ssl|tls|xss|csrf|injection|xxe|rce|privilege|escalation|compliance)"; then
    score=$((score + 18))
  fi

  if printf '%s' "$text" | rg -q "(refactor|refactoring|restructure|architecture|architectural|design|scalability|scalable|performance|optimize|optimization|efficiency|algorithm|algorithms|database|db|sql|nosql|api|microservice|microservices|backend|system|systems|migration|integration|concurrency)"; then
    score=$((score + 12))
  fi

  if printf '%s' "$text" | rg -q "(debug|debugging|investigate|investigation|research|analyze|analysis|troubleshoot|troubleshooting|diagnose|diagnosis|root cause|explore|exploration|intermittent|unknown)"; then
    score=$((score + 12))
  fi

  if printf '%s' "$text" | rg -q "(code review|peer review|review comments|review feedback|review findings|reviewer|regression risk|change assessment|risk assessment)"; then
    score=$((score + 10))
  fi

  if printf '%s' "$text" | rg -q "(test|testing|unit test|integration test|e2e|end-to-end|validation|verify|verification|assert|assertion|mock|mocks|stub|stubs|fixture|fixtures|test case|test cases|test suite|tdd|bdd)"; then
    score=$((score + 8))
  fi

  if printf '%s' "$text" | rg -q "(typo|typos|text|string|label|labels|button|buttons|ui|ux|frontend|minor|minors|small|trivial|spelling|grammar|style|styling|css|theme|theming|color|colors|font|fonts|icon|icons|image|images|logo|logos|documentation|doc|readme|guide|tutorial|walkthrough|faq|wiki|markdown|md)"; then
    score=$((score - 6))
  fi

  [ "$score" -gt 0 ] || score=0

  complexity_tier="low"
  if [ "$score" -ge 60 ]; then
    complexity_tier="extreme"
  elif [ "$score" -ge 40 ]; then
    complexity_tier="high"
  elif [ "$score" -ge 20 ]; then
    complexity_tier="medium"
  fi

  printf '%s\n' "$score:$complexity_tier"
}

_story_complexity_tier_from_score() {
  local score="${1:-0}"
  case "$score" in
    ''|*[!0-9]*)
      echo "low"
      return
      ;;
  esac
  if [ "$score" -ge 60 ]; then
    echo "extreme"
  elif [ "$score" -ge 40 ]; then
    echo "high"
  elif [ "$score" -ge 20 ]; then
    echo "medium"
  else
    echo "low"
  fi
}

_model_is_lite_like() {
  local model="${1:-}"
  local lower

  [ -n "$model" ] || { echo 0; return; }
  lower="$(_model_family_name "$model")"
  case "$lower" in
    *gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*|*gpt-mini*|*gpt-4.1-nano*|*gpt-5-nano*|*haiku*|*flash-lite*|*mini*|*nano*)
      echo 1
      ;;
    *)
      echo 0
      ;;
  esac
}

_execution_tier_for_profile() {
  local model="${1:-}"
  local composite_profile="${2:-}"

  if [ -z "$composite_profile" ]; then
    echo "simple"
  elif [ "$(_model_is_lite_like "$model")" = "1" ]; then
    echo "composite-lite"
  else
    echo "full-composite"
  fi
}

_agent_selection_priority() {
  local agent_name="$1"
  case "$agent_name" in
    researcher|security)
      echo "heavy"
      ;;
    senior-dev|reviewer)
      echo "advanced"
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
  local priority lower score=0 complexity_tier

  priority="$(_agent_selection_priority "$agent_name")"
  lower="$(_model_family_name "$model")"
  complexity_tier="$(_story_complexity_tier_from_score "${RALPH_STORY_COMPLEXITY_SCORE:-0}")"

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
  esac

  case "$priority" in
    heavy)
      case "$lower" in
        *claude-opus*)
          score=$((score + 180))
          ;;
        *claude-sonnet*)
          score=$((score + 100))
          ;;
        *gpt-5.5*)
          score=$((score + 180))
          ;;
        *gpt-5.5*|*gpt-5.4-pro*|*gpt-5.4*|*gpt-5.2-codex*|*gpt-5.1-codex*|*gpt-5-codex*|*gpt-5.2*|*gpt-5.1*|*gpt-5-pro*|*gpt-5*|*gpt-4.1*|*gpt-4o*|*gpt-4-turbo*|*claude-opus*|*claude-sonnet-4*|*claude-sonnet-latest*|*deepseek-r1*|*deepseek-v4-pro*)
          score=$((score + 120))
          ;;
        *gpt-5.4-mini*|*gpt-mini*|*mini*|*nano*|*haiku*|*flash-lite*|*:free)
          score=$((score - 40))
          ;;
      esac
      ;;
    advanced)
      case "$lower" in
        *claude-sonnet*)
          score=$((score + 150))
          ;;
        *claude-opus*)
          score=$((score + 80))
          ;;
        *gpt-5.4*)
          score=$((score + 160))
          ;;
        *gpt-5.5*)
          score=$((score + 110))
          ;;
        *gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*)
          score=$((score + 80))
          ;;
        *gpt-5*|*gpt-4.1*|*gpt-4o*|*gpt-4-turbo*|*claude-sonnet*|*claude-opus*|*deepseek-v4*|*codestral*|*devstral*)
          score=$((score + 90))
          ;;
      esac
      ;;
    strong)
      case "$lower" in
        *claude-sonnet*)
          score=$((score + 140))
          ;;
        *claude-opus*)
          score=$((score + 40))
          ;;
        *gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*)
          score=$((score + 120))
          ;;
        *gpt-5.5*)
          score=$((score - 20))
          ;;
        *gpt-5.4*|*gpt-5*|*gpt-4.1*|*gpt-4o*|*gpt-4-turbo*|*claude-sonnet*|*claude-opus*|*deepseek-v4*|*codestral*|*devstral*)
          score=$((score + 90))
          ;;
        *mini*|*nano*|*haiku*|*flash-lite*)
          score=$((score - 20))
          ;;
      esac
      ;;
    economy)
      case "$lower" in
        *claude-haiku*)
          score=$((score + 180))
          ;;
        *claude-sonnet*|*claude-opus*)
          score=$((score - 40))
          ;;
        *gpt-5.4-mini*)
          score=$((score + 180))
          ;;
        *gpt-mini-latest*|*gpt-4o-mini*|*gpt-4.1-mini*|*gpt-4.1-nano*|*gpt-5-mini*|*gpt-5-nano*|*haiku*|*mini*|*nano*|*flash-lite*|*:free)
          score=$((score + 140))
          ;;
        *gpt-3.5-turbo*|*gpt-5.5*|*opus*|*pro*|*large*|*gpt-5.4*|*gpt-5.2*|*gpt-5.1*|*gpt-5-codex*)
          score=$((score - 35))
          ;;
      esac
      ;;
  esac

  case "$complexity_tier" in
    medium)
      case "$lower" in
        *claude-sonnet*|*gpt-5.4*|*gpt-5.5*|*gpt-5-pro*|*gpt-5.4-pro*|*deepseek-v4*|*codestral*|*devstral*)
          score=$((score + 20))
          ;;
      esac
      ;;
    high|extreme)
      case "$lower" in
        *claude-opus*|*gpt-5.5*|*gpt-5.4-pro*)
          score=$((score + 80))
          ;;
        *claude-sonnet*|*gpt-5.4*|*deepseek-v4*|*codestral*|*devstral*)
          score=$((score + 35))
          ;;
        *gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*|*haiku*|*nano*|*flash-lite*|*:free)
          score=$((score - 25))
          ;;
      esac
      ;;
  esac

  case "$agent_name" in
    documentation)
      ;;
    reviewer)
      case "$lower" in
        *gpt-5.4*)
          score=$((score + 50))
          ;;
        *gpt-5.5*)
          score=$((score - 10))
          ;;
      esac
      ;;
    qa-test|devops|documentation)
      case "$complexity_tier" in
        medium)
          case "$lower" in
            *claude-sonnet*|*gpt-5.4*|*gpt-5.5*|*gpt-5-pro*|*gpt-5.4-pro*|*deepseek-v4*|*codestral*|*devstral*)
              score=$((score + 80))
              ;;
            *claude-haiku*|*gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*|*haiku*|*nano*|*flash-lite*|*:free)
              score=$((score - 20))
              ;;
          esac
          ;;
        high|extreme)
          case "$lower" in
            *claude-sonnet*|*gpt-5.4*|*gpt-5.5*|*gpt-5-pro*|*gpt-5.4-pro*|*deepseek-v4*|*codestral*|*devstral*)
              score=$((score + 140))
              ;;
            *claude-opus*)
              score=$((score + 60))
              ;;
            *claude-haiku*|*gpt-5.4-mini*|*gpt-5-mini*|*gpt-4.1-mini*|*gpt-4o-mini*|*haiku*|*nano*|*flash-lite*|*:free)
              score=$((score - 60))
              ;;
          esac
          ;;
      esac
      ;;
    *)
      case "$lower" in
        *gpt-5.1-codex-mini*|*gpt-5-codex*)
          score=$((score - 60))
          ;;
        *codestral*|*devstral*|*coder*)
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
  local story_input="$1"
  local story_json explicit_agent labels_json tags_json all_labels_json content

  story_json="$(_normalize_story_metadata_json "$story_input")"
  [ -n "$story_json" ] || { echo "default"; return; }

  explicit_agent="$(printf '%s' "$story_json" | jq -r '.agent // empty' 2>/dev/null)"
  if [ -n "$explicit_agent" ]; then
    echo "$explicit_agent"
    return
  fi

  labels_json="$(printf '%s' "$story_json" | jq -c '.labels // []' 2>/dev/null || echo '[]')"
  tags_json="$(printf '%s' "$story_json" | jq -c '.tags // []' 2>/dev/null || echo '[]')"
  all_labels_json="$(jq -cn --argjson labels "$labels_json" --argjson tags "$tags_json" '$labels + $tags')"

  if [ -f "$LABEL_MAPPING_FILE" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      local mapped_agent
      mapped_agent="$(_load_json_value "$LABEL_MAPPING_FILE" ".label_mappings.\"$label\" // empty")"
      if [ -n "$mapped_agent" ]; then
        echo "$mapped_agent"
        return
      fi
    done < <(printf '%s' "$all_labels_json" | jq -r '.[]? | ascii_downcase' 2>/dev/null)
  fi

  content="$(
    printf '%s' "$story_json" | jq -r '
      [
        .title,
        .description,
        .goal,
        .promptContext,
        (.tasks[]?)
      ]
      | map(select(type == "string" and length > 0))
      | join(" ")
    ' 2>/dev/null | tr '[:upper:]' '[:lower:]'
  )"

  if printf '%s' "$content" | rg -q "(debug|debugging|investigate|investigation|research|analyze|analysis|troubleshoot|troubleshooting|diagnose|diagnosis|root cause|explore|exploration)"; then
    echo "researcher"
    return
  fi

  if printf '%s' "$content" | rg -q "(refactor|refactoring|restructure|restructuring|architecture|architectural|design pattern|design patterns|scalability|performance|optimize|optimization|efficiency|algorithm|data structure|database|db|sql|nosql|api|microservice|backend|system|systems|enterprise)"; then
    echo "senior-dev"
    return
  fi

  if printf '%s' "$content" | rg -q '(^|[^a-zA-Z0-9_])(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|xxe|rce|privilege|escalation|compliance)([^a-zA-Z0-9_]|$)' \
    || printf '%s' "$content" | rg -q "(sql injection|security audit)"; then
    echo "security"
    return
  fi

  if printf '%s' "$content" | rg -q "(code review|peer review|review comments|review feedback|review findings|reviewer|regression risk|change assessment)"; then
    echo "reviewer"
    return
  fi

  if printf '%s' "$content" | rg -q "(test|testing|unit test|unit-test|integration test|integration-test|e2e|end-to-end|end to end|validation|valid|verify|verification|assert|assertion|mock|mocks|stub|stubs|fixture|fixtures|test case|test cases|test suite|test driven|tdd|bdd)"; then
    echo "qa-test"
    return
  fi

  if printf '%s' "$content" | rg -q "(deploy|deployment|deploying|infrastructure|docker|kubernetes|k8s|aws|azure|gcp|cloud|server|servers|network|networking|ci|ci/cd|continuous integration|continuous delivery|continuous deployment|pipeline|pipelines|terraform|ansible|monitoring|logging|logs|metrics|alerting)"; then
    echo "devops"
    return
  fi

  if printf '%s' "$content" | rg -q "(doc|documentation|comment|comments|explain|explanation|readme|guide|tutorial|walkthrough|faq|wiki|markdown)"; then
    echo "documentation"
    return
  fi

  if printf '%s' "$content" | rg -q "(typo|typos|text|string|label|labels|button|buttons|ui|ux|frontend|minor|minors|small|trivial|spelling|grammar|style|styling|css|theme|theming|color|colors|font|fonts|icon|icons|image|images|logo|logos)"; then
    echo "junior-dev"
    return
  fi

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

get_execution_profile_json() {
  local effective_agent="${1:-${RALPH_AGENT:-default}}"
  local effective_harness model_value composite_value codex_profile
  effective_harness="$(_get_harness)"
  model_value="${RALPH_MODEL:-}"
  composite_value="${RALPH_COMPOSITE_PROFILE:-}"
  codex_profile="$(_resolve_codex_runtime_profile_name)"

  jq -nc \
    --arg harness "$effective_harness" \
    --arg harness_source "$(_get_harness_selection_source)" \
    --arg model "$model_value" \
    --arg model_source "${RALPH_MODEL_SELECTION_SOURCE:-}" \
    --arg agent "$effective_agent" \
    --arg agent_source "${RALPH_AGENT_SELECTION_SOURCE:-}" \
    --arg composite_profile "$composite_value" \
    --arg codex_profile "$codex_profile" \
    --arg pi_role "${RALPH_PIAGENT_ROLE:-}" \
    --arg execution_tier "${RALPH_EXECUTION_TIER:-}" \
    --arg runtime_home "$RALPH_RUNTIME_HOME_DIR" \
    --argjson composites_enabled "$(if _composites_enabled; then printf 'true'; else printf 'false'; fi)" \
    --arg complexity_tier "${STORY_COMPLEXITY_TIER:-}" \
    --argjson complexity_score "${STORY_COMPLEXITY_SCORE:-0}" \
    '{
      harness: $harness,
      harness_source: $harness_source,
      model: (if $model == "" then null else $model end),
      model_source: (if $model_source == "" then null else $model_source end),
      agent: (if $agent == "" then null else $agent end),
      agent_source: (if $agent_source == "" then null else $agent_source end),
      composite_profile: (if $composite_profile == "" then null else $composite_profile end),
      composites_enabled: $composites_enabled,
      codex_profile: (if $codex_profile == "" then null else $codex_profile end),
      piagent_role: (if $pi_role == "" then null else $pi_role end),
      execution_tier: (if $execution_tier == "" then null else $execution_tier end),
      runtime_home: (if $runtime_home == "" then null else $runtime_home end),
      complexity_tier: (if $complexity_tier == "" then null else $complexity_tier end),
      complexity_score: (if $complexity_tier == "" then null else $complexity_score end)
    }'
}

_composites_enabled() {
  [ "${RALPH_DISABLE_COMPOSITES:-0}" != "1" ] && [ "${RALPH_ENABLE_COMPOSITES:-1}" = "1" ]
}

# Apply agent profile settings (model, etc.)
_apply_agent_profile() {
  local agent_name="$1"
  local profile_json composite_profile composite_shape composite_required_extensions composite_subagent_roles composite_steps piagent_role
  local model_was_explicit=0

  # Determine effective harness (same logic as in harness_exec_prompt)
  local effective_harness
  effective_harness="$(_get_harness)"

  if [ -n "${RALPH_MODEL:-}" ]; then
    model_was_explicit=1
  fi

  profile_json="$(_get_agent_profile_field "$agent_name" "$effective_harness" ".")"
  if [ -n "$profile_json" ]; then
    piagent_role="$(printf '%s' "$profile_json" | jq -r '.piagent_agent // empty' 2>/dev/null)"
    if [ "$effective_harness" = "piagent" ] && [ -n "$piagent_role" ]; then
      RALPH_PIAGENT_ROLE="$piagent_role"
      export RALPH_PIAGENT_ROLE
    else
      unset RALPH_PIAGENT_ROLE
    fi
    composite_profile="$(printf '%s' "$profile_json" | jq -r '.composite_profile // empty' 2>/dev/null)"
    if _composites_enabled; then
      if [ -n "$composite_profile" ]; then
        composite_shape="$( _get_composite_profile_field "$composite_profile" ".shape" )"
        composite_required_extensions="$( _get_composite_profile_field "$composite_profile" ".required_extensions" )"
        composite_subagent_roles="$( _get_composite_profile_field "$composite_profile" ".subagent_roles" )"
        composite_steps="$( _get_composite_profile_field "$composite_profile" ".steps" )"

        RALPH_COMPOSITE_PROFILE="$composite_profile"
        RALPH_COMPOSITE_PROFILE_JSON="$(_get_composite_profile "$composite_profile")"
        RALPH_COMPOSITE_SHAPE="$composite_shape"
        RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON="$composite_required_extensions"
        RALPH_COMPOSITE_SUBAGENT_ROLES_JSON="$composite_subagent_roles"
        RALPH_COMPOSITE_STEPS_JSON="$composite_steps"
        export RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
          RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
          RALPH_COMPOSITE_STEPS_JSON
      else
        unset RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
          RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
          RALPH_COMPOSITE_STEPS_JSON
      fi
    else
      unset RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
        RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
        RALPH_COMPOSITE_STEPS_JSON
    fi
  else
    unset RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
      RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
      RALPH_COMPOSITE_STEPS_JSON
  fi

  # Only override model if not explicitly set via command line/environment
  if [ -z "${RALPH_MODEL:-}" ]; then
    local suggested_model="" preferred_model lite_model dynamic_model tier_model complexity_tier allow_lite=0
    complexity_tier="$(_story_complexity_tier_from_score "${RALPH_STORY_COMPLEXITY_SCORE:-0}")"
    case "$complexity_tier" in
      low|medium) allow_lite=1 ;;
    esac

    preferred_model="$(_get_agent_profile "$agent_name" "$effective_harness" '.models')"
    if [ -n "$preferred_model" ]; then
      preferred_model="$(_resolve_model_for_harness "$preferred_model" "$effective_harness")"
      if ! is_model_supported_by_harness "$effective_harness" "$preferred_model"; then
        preferred_model=""
      fi
    fi

    lite_model="$(_get_agent_profile_field "$agent_name" "$effective_harness" '.lite_models')"
    if [ -n "$lite_model" ]; then
      lite_model="$(_resolve_model_for_harness "$lite_model" "$effective_harness")"
      if ! is_model_supported_by_harness "$effective_harness" "$lite_model"; then
        lite_model=""
      fi
    fi

    dynamic_model="$(_select_dynamic_model_for_agent "$agent_name" "$effective_harness")"
    if [ -n "$dynamic_model" ] && ! is_model_supported_by_harness "$effective_harness" "$dynamic_model"; then
      dynamic_model=""
    fi

    if [ -n "$composite_profile" ]; then
      case "$complexity_tier" in
        high)
          tier_model="$(_resolve_model_for_harness "gpt-5.4" "$effective_harness")"
          if ! is_model_supported_by_harness "$effective_harness" "$tier_model"; then
            tier_model=""
          fi
          ;;
        extreme)
          tier_model="$(_resolve_model_for_harness "gpt-5.5" "$effective_harness")"
          if ! is_model_supported_by_harness "$effective_harness" "$tier_model"; then
            tier_model=""
          fi
          ;;
        *)
          tier_model=""
          ;;
      esac
    else
      tier_model=""
    fi

    if [ "$allow_lite" -eq 1 ] && [ -n "$lite_model" ]; then
      suggested_model="$lite_model"
      RALPH_MODEL_SELECTION_SOURCE="agent-profile-lite"
    elif [ -n "$tier_model" ]; then
      suggested_model="$tier_model"
      RALPH_MODEL_SELECTION_SOURCE="complexity-tier-$complexity_tier"
    elif [ -n "$preferred_model" ]; then
      suggested_model="$preferred_model"
      RALPH_MODEL_SELECTION_SOURCE="agent-profile"
    elif [ -n "$dynamic_model" ]; then
      suggested_model="$dynamic_model"
      RALPH_MODEL_SELECTION_SOURCE="dynamic"
    else
      RALPH_MODEL_SELECTION_SOURCE="default"
    fi

    if [ -n "$suggested_model" ]; then
      RALPH_MODEL="$suggested_model"
      export RALPH_MODEL
    fi
  elif [ "$model_was_explicit" -eq 1 ]; then
    RALPH_MODEL_SELECTION_SOURCE="explicit"
  fi
  export RALPH_MODEL_SELECTION_SOURCE
  RALPH_EXECUTION_TIER="$(_execution_tier_for_profile "${RALPH_MODEL:-}" "${RALPH_COMPOSITE_PROFILE:-}")"
  export RALPH_EXECUTION_TIER

  case "${RALPH_AGENT_SELECTION_SOURCE:-}" in
    explicit|inferred|default) ;;
    *)
      if [ -n "${RALPH_AGENT:-}" ]; then
        RALPH_AGENT_SELECTION_SOURCE="explicit"
      elif [ "$agent_name" != "default" ]; then
        RALPH_AGENT_SELECTION_SOURCE="inferred"
      else
        RALPH_AGENT_SELECTION_SOURCE="default"
      fi
      ;;
  esac
  export RALPH_AGENT_SELECTION_SOURCE
  
}

# Harness-specific execution functions

_codex_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  local runtime_profile=""
  local profile_args=()
  runtime_profile="$(_resolve_codex_runtime_profile_name)"
  [ -n "$runtime_profile" ] && profile_args=(--profile "$runtime_profile")
  local model_args=()
  [ -n "${RALPH_MODEL:-}" ] && harness_supports_model_selection "codex" && model_args=(--model "$RALPH_MODEL")
  local agent_args=()
  [ -n "${RALPH_AGENT:-}" ] && harness_supports_agent_selection "codex" && agent_args=(--agent "$RALPH_AGENT")
  _seed_ralph_runtime_home_config
  
  if _supports_codex_yolo; then
    (
      _ensure_ralph_runtime_home
      export HOME="$RALPH_RUNTIME_HOME_DIR"
      export CODEX_HOME="$RALPH_RUNTIME_HOME_DIR/.codex"
      export XDG_CONFIG_HOME="$RALPH_RUNTIME_HOME_DIR/.config"
      export XDG_CACHE_HOME="$RALPH_RUNTIME_HOME_DIR/.cache"
      export XDG_STATE_HOME="$RALPH_RUNTIME_HOME_DIR/.local/state"
      export XDG_DATA_HOME="$RALPH_RUNTIME_HOME_DIR/.local/share"
      printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" --yolo exec "${profile_args[@]+"${profile_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "${agent_args[@]+"${agent_args[@]}"}" -C "$workspace" "$@"
    )
  else
    (
      _ensure_ralph_runtime_home
      export HOME="$RALPH_RUNTIME_HOME_DIR"
      export CODEX_HOME="$RALPH_RUNTIME_HOME_DIR/.codex"
      export XDG_CONFIG_HOME="$RALPH_RUNTIME_HOME_DIR/.config"
      export XDG_CACHE_HOME="$RALPH_RUNTIME_HOME_DIR/.cache"
      export XDG_STATE_HOME="$RALPH_RUNTIME_HOME_DIR/.local/state"
      export XDG_DATA_HOME="$RALPH_RUNTIME_HOME_DIR/.local/share"
      printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" exec --dangerously-bypass-approvals-and-sandbox "${profile_args[@]+"${profile_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "${agent_args[@]+"${agent_args[@]}"}" -C "$workspace" "$@"
    )
  fi
}

_piagent_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true

  local pi_args=()
  [ "${RALPH_STRUCTURED_OUTPUT:-}" = "1" ] && pi_args+=("--mode" "json")
  if [ -n "${RALPH_PIAGENT_ROLE:-}" ]; then
    local role_hint=""
    case "$RALPH_PIAGENT_ROLE" in
      researcher)
        role_hint="Use the researcher subagent for parallel investigation and synthesis when that improves the result."
        ;;
      reviewer)
        role_hint="Use the reviewer subagent for critique, risk analysis, and regression checks."
        ;;
      oracle)
        role_hint="Use the oracle subagent for a second opinion before making risky decisions."
        ;;
      worker)
        role_hint="Use the worker subagent for implementation, testing, and follow-through."
        ;;
      delegate)
        role_hint="Use the delegate subagent for light orchestration and controlled handoffs."
        ;;
    esac
    [ -n "$role_hint" ] && pi_args+=("--append-system-prompt" "$role_hint")
  fi

  local pi_provider="${PI_PROVIDER:-}"
  local resolved_model="${RALPH_MODEL:-}"
  local pi_provider_base="${PI_BASE_URL:-${OPENAI_BASE_URL:-}}"
  local pi_api_key="${PI_API_KEY:-${OPENROUTER_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_API_KEY:-}}}}"
  _seed_ralph_runtime_home_config
  _seed_ralph_runtime_pi_config
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
  elif [ -z "$pi_provider" ] && [[ "$pi_provider_base" == *api.openai.com* ]]; then
    pi_provider="openai-native"
  fi

  [ -n "$pi_provider" ] && pi_args+=("--provider" "$pi_provider")
  [ -n "$resolved_model" ] && pi_args+=("--model" "$resolved_model")
  [ -n "$pi_api_key" ] && pi_args+=("--api-key" "$pi_api_key")

  pi_args+=("$@")
  pi_args+=("$prompt")

  (
    cd "$workspace"
    _ensure_ralph_runtime_home
    export HOME="$RALPH_RUNTIME_HOME_DIR"
    export PI_CODING_AGENT_DIR="$RALPH_RUNTIME_HOME_DIR/.pi/agent"
    export XDG_CONFIG_HOME="$RALPH_RUNTIME_HOME_DIR/.config"
    export XDG_CACHE_HOME="$RALPH_RUNTIME_HOME_DIR/.cache"
    export XDG_STATE_HOME="$RALPH_RUNTIME_HOME_DIR/.local/state"
    export XDG_DATA_HOME="$RALPH_RUNTIME_HOME_DIR/.local/share"
    PI_PERMISSION_LEVEL=bypassed pi -p "${pi_args[@]}"
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
    piagent)
      _piagent_exec_prompt "$prompt" "$workspace" "$@"
      ;;
    *)
      echo "ERROR: Unknown harness '$harness'. Supported: codex, piagent" >&2
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
