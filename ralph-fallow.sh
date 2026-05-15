#!/bin/bash
# ralph-fallow.sh — Code-quality acceptance gate for stories.
#
# Uses the Fallow CLI (fallow.tools) to check dead code, duplicates, and code
# health. When the branch diff is fully inside the story scope, Ralph can use
# "fallow audit" safely. Otherwise it falls back to exact-file analyzers so the
# gate cannot broaden a story branch accidentally.
#
# Broad auto-fix is disabled by default. Exact scoped auto-fix can be re-enabled
# later once the workflow is tightened further.
#
# For non-JS/TS projects (no package.json / tsconfig.json) a lightweight
# grep-based heuristic fallback is used instead.
#
# Exit 0 = clean.  Exit 1 = issues remain — story cannot be marked done.
#
# Usage:
#   ./ralph-fallow.sh [--story PATH] [--dry-run] [--no-autofix] [--quiet]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
source "$SCRIPT_DIR/lib/codex-exec.sh"

STORY_FILE=""
DRY_RUN=0
NO_AUTOFIX=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: ./ralph-fallow.sh [options]

Code-quality acceptance gate (powered by fallow.tools). Runs "fallow audit"
only when the branch diff is fully within the story scope. Otherwise it uses
exact-file fallback analyzers to avoid broad cleanup drift.

Broad auto-fix is disabled by default. Set the environment flags below to
re-enable scoped fallback auto-fix or Codex auto-fix while this workflow is
being revisited. The story cannot be marked done if issues remain.

For non-JS/TS projects, a built-in grep-based heuristic is used.

Options:
  --story PATH    Path to story.json (default: active story from sprint)
  --dry-run       Report issues without auto-fixing or failing
  --no-autofix    Report and fail without attempting auto-fix
  --quiet         Suppress verbose output
  -h, --help      Show help

Environment:
  CODEX_BIN             Codex binary (default: codex)
  RALPH_CODEX_PROFILE   Profile flag passed to codex exec
  RALPH_FALLOW_EXACT_AUTOFIX  Set to 1 to allow fallback exact-file auto-fix
  RALPH_FALLOW_CODEX_AUTOFIX  Set to 1 to allow Codex follow-up auto-fix
EOF
}

fail()  { echo "ERROR: $1" >&2; exit 1; }
log()   { [ "$QUIET" -eq 0 ] && echo "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)      STORY_FILE="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-autofix) NO_AUTOFIX=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq
require_cmd git

# ---------------------------------------------------------------------------
# Resolve story file
# ---------------------------------------------------------------------------

resolve_story_file() {
  if [ -n "$STORY_FILE" ]; then
    [ -f "$STORY_FILE" ] || fail "Story file not found: $STORY_FILE"
    return
  fi

  local active_sprint_file="$SCRIPT_DIR/.active-sprint"
  [ -f "$active_sprint_file" ] || fail "No --story given and no .active-sprint found."
  local sprint
  sprint="$(awk 'NF {print; exit}' "$active_sprint_file")"

  local stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  [ -f "$stories_file" ] || fail "No stories.json for sprint $sprint: $stories_file"

  local active_id
  active_id="$(jq -r '.activeStoryId // empty' "$stories_file")"
  [ -n "$active_id" ] || fail "No activeStoryId set. Run ralph-story.sh use <id> first."

  local story_path
  story_path="$(jq -r --arg id "$active_id" '.stories[] | select(.id == $id) | .story_path // empty' "$stories_file")"
  [ -n "$story_path" ] || fail "Story $active_id not found in $stories_file"

  if [[ "$story_path" != /* ]]; then
    story_path="$WORKSPACE_ROOT/$story_path"
  fi
  [ -f "$story_path" ] || fail "Story file not found: $story_path"
  STORY_FILE="$story_path"
}

resolve_story_file

STORY_DIR="$(dirname "$STORY_FILE")"
STORY_ID="$(jq -r '.storyId' "$STORY_FILE")"
STORY_TITLE="$(jq -r '.title' "$STORY_FILE")"
REPORT_FILE="$STORY_DIR/.fallow-report.json"
ALLOW_EXACT_AUTOFIX="${RALPH_FALLOW_EXACT_AUTOFIX:-0}"
ALLOW_CODEX_AUTOFIX="${RALPH_FALLOW_CODEX_AUTOFIX:-0}"

# ---------------------------------------------------------------------------
# Scope resolution (for reporting and fallback only)
# ---------------------------------------------------------------------------

SCOPE_FILES=()
SCOPE_PATTERNS=()
_scope_seen=""
_scope_pattern_seen=""
BASE_REF=""
CHANGED_FILES=()
CHANGED_SCOPE_FILES=()
OUT_OF_SCOPE_CHANGED_FILES=()

_scope_add() {
  local f="$1"
  [ -z "$f" ] && return
  printf '%s\n' "$_scope_seen" | grep -qxF "$f" 2>/dev/null && return
  _scope_seen="${_scope_seen}${f}"$'\n'
  SCOPE_FILES+=("$f")
}

_scope_pattern_add() {
  local pattern="$1"
  [ -z "$pattern" ] && return
  printf '%s\n' "$_scope_pattern_seen" | grep -qxF "$pattern" 2>/dev/null && return
  _scope_pattern_seen="${_scope_pattern_seen}${pattern}"$'\n'
  SCOPE_PATTERNS+=("$pattern")
}

_scope_entry_add() {
  local entry="$1"
  [ -z "$entry" ] && return

  if [ -f "$WORKSPACE_ROOT/$entry" ]; then
    _scope_add "$entry"
    return
  fi
  if [ -f "$entry" ]; then
    _scope_add "${entry#$WORKSPACE_ROOT/}"
    return
  fi

  case "$entry" in
    *"*"*|*"?"*|*"/**"*|src/*|libs/*|tests/*|scripts/*|data/*|docs/*|package.json|project.json|nx.json)
      _scope_pattern_add "$entry"
      ;;
  esac
}

_scope_extract_patterns_from_text() {
  local text="$1"
  [ -n "$text" ] || return

  while IFS= read -r token; do
    [ -n "$token" ] || continue
    _scope_entry_add "$token"
  done < <(printf '%s\n' "$text" | grep -oE '`[^`]+`' | tr -d '`')

  if printf '%s\n' "$text" | grep -qiE 'jest|browser tests|playwright|targeted .*tests'; then
    _scope_pattern_add 'src/**/__tests__/**'
    _scope_pattern_add 'src/**/*.test.*'
    _scope_pattern_add 'tests/**'
  fi
}

resolve_scope_files() {
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    _scope_entry_add "$f"
  done < <(jq -r '.tasks[].scope[]?' "$STORY_FILE" 2>/dev/null | sort -u)

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    _scope_entry_add "$f"
  done < <(jq -r '(.spec.scope_paths // .spec.scopePaths // .scopePaths // [])[]?' "$STORY_FILE" 2>/dev/null | sort -u)

  while IFS= read -r text; do
    [ -z "$text" ] && continue
    _scope_extract_patterns_from_text "$text"
  done < <(jq -r '.spec.scope // empty, .tasks[].description // empty, .tasks[].scope[]?' "$STORY_FILE" 2>/dev/null)
}

resolve_scope_files

# ---------------------------------------------------------------------------
# Diff scope resolution
# ---------------------------------------------------------------------------

resolve_analysis_base_ref() {
  if git rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    BASE_REF='@{upstream}'
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/main; then
    BASE_REF='main'
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/master; then
    BASE_REF='master'
    return 0
  fi
  BASE_REF='HEAD~1'
}

resolve_changed_scope_files() {
  resolve_analysis_base_ref

  local changed=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    changed+=("$f")
  done < <(cd "$WORKSPACE_ROOT" && git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || true)

  CHANGED_FILES=()
  CHANGED_SCOPE_FILES=()
  OUT_OF_SCOPE_CHANGED_FILES=()

  local f
  for f in "${changed[@]}"; do
    CHANGED_FILES+=("$f")
    if printf '%s\n' "$_scope_seen" | grep -qxF "$f" 2>/dev/null; then
      CHANGED_SCOPE_FILES+=("$f")
      continue
    fi

    local pattern matched=0
    for pattern in "${SCOPE_PATTERNS[@]}"; do
      case "$f" in
        $pattern)
          CHANGED_SCOPE_FILES+=("$f")
          matched=1
          break
          ;;
      esac
    done

    if [ "$matched" -eq 0 ]; then
      OUT_OF_SCOPE_CHANGED_FILES+=("$f")
    fi
  done
}

resolve_changed_scope_files

# ---------------------------------------------------------------------------
# Detect Fallow + project type
# ---------------------------------------------------------------------------

FALLOW_BIN=""
IS_JS_PROJECT=0

detect_fallow() {
  [ -f "$WORKSPACE_ROOT/package.json" ] || [ -f "$WORKSPACE_ROOT/tsconfig.json" ] && IS_JS_PROJECT=1 || true

  [ "$IS_JS_PROJECT" -eq 1 ] || return 0

  # 1. Local project install (fastest, version-locked)
  if [ -x "$WORKSPACE_ROOT/node_modules/.bin/fallow" ]; then
    FALLOW_BIN="$WORKSPACE_ROOT/node_modules/.bin/fallow"
    return 0
  fi

  # 2. Already installed globally
  if command -v fallow >/dev/null 2>&1; then
    FALLOW_BIN="fallow"
    return 0
  fi

  # 3. Install globally so subsequent runs are fast
  if command -v npm >/dev/null 2>&1; then
    log "  Installing fallow globally (npm install -g fallow)..."
    if npm install -g fallow --quiet --no-fund --no-audit 2>/dev/null \
        && command -v fallow >/dev/null 2>&1; then
      FALLOW_BIN="fallow"
      log "  Fallow installed globally."
      return 0
    fi
    log "  Global install failed (permissions?) — falling back to npx"
  fi

  # 4. npx fallback — slower but always works if Node is present
  if command -v npx >/dev/null 2>&1; then
    FALLOW_BIN="npx fallow"
    log "  Using npx fallow (run 'npm i -g fallow' once for faster startup)"
    return 0
  fi

  log "  fallow unavailable (npm/npx not found) — using built-in heuristics"
}

detect_fallow

# ---------------------------------------------------------------------------
# Fallow audit (JS/TS projects)
# ---------------------------------------------------------------------------

FALLOW_VERDICT=""
FALLOW_ISSUES=""
FALLOW_ISSUE_COUNT=0

_fallow_run() {
  # Run fallow with args, capture output, return last JSON object.
  # Fallow may emit two JSON blobs (progress + result); we want the last.
  local cmd_args=("$@")
  local raw
  # shellcheck disable=SC2086
  raw="$(cd "$WORKSPACE_ROOT" && $FALLOW_BIN "${cmd_args[@]}" 2>&1 || true)"
  # Extract last valid JSON object from output
  printf '%s\n' "$raw" | python3 -c '
import sys, json
buf = ""
for line in sys.stdin:
    buf += line
    try:
        obj = json.loads(buf)
        last = obj
        buf = ""
    except:
        pass
if "last" in dir():
    print(json.dumps(last))
' 2>/dev/null || printf '%s\n' "$raw" | jq -s 'last' 2>/dev/null || echo "{}"
}

_jq_extract() {
  # Run a single jq filter on $1 (json string), safe against parse errors
  printf '%s\n' "$1" | jq -r "$2" 2>/dev/null | head -40 || true
}

_extract_fallow_issues() {
  local json="$1"
  local lines=""

  # Dead code — separate jq call per category avoids nested-quote issues
  local t
  t="$(_jq_extract "$json" '(.dead_code.unused_files // [])[] | "unused-file: \(.)"')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  t="$(_jq_extract "$json" '(.dead_code.unused_exports // [])[] | "unused-export: \(.file // ".") — \(.name // "?")"')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  t="$(_jq_extract "$json" '(.dead_code.unused_types // [])[] | "unused-type: \(.file // ".") — \(.name // "?")"')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  t="$(_jq_extract "$json" '(.dead_code.unused_dependencies // [])[] | "unused-dep: \(.)"')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  t="$(_jq_extract "$json" '(.dead_code.circular_dependencies // [])[] | "circular-dep: \(. | tostring)"')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  # Duplication
  t="$(_jq_extract "$json" '(.duplication.clone_groups // [])[] | "duplicate-block (\(.instances | length) instances): " + ((.instances // []) | map(.file + ":" + (.start_line | tostring)) | join(", "))')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  # Complexity
  t="$(_jq_extract "$json" '(.complexity.findings // [])[] | "complexity: \(.file) \(.name // "") cyclomatic=\(.cyclomatic // "?")"')"
  [ -n "$t" ] && lines="${lines}${t}"$'\n'

  printf '%s' "$lines" | grep -v '^[[:space:]]*$' || true
}

run_fallow_audit() {
  FALLOW_VERDICT=""
  FALLOW_ISSUES=""
  FALLOW_ISSUE_COUNT=0
  [ -n "$FALLOW_BIN" ] || return 1   # signal: use fallback

  log "  [fallow audit] Analyzing branch diff vs $BASE_REF..."
  local json
  json="$(_fallow_run audit --format json)"

  FALLOW_VERDICT="$(printf '%s\n' "$json" | jq -r '.verdict // "unknown"' 2>/dev/null || echo "unknown")"

  if [ "$FALLOW_VERDICT" = "pass" ]; then
    return 0
  fi

  FALLOW_ISSUES="$(_extract_fallow_issues "$json")"
  FALLOW_ISSUE_COUNT="$(printf '%s\n' "$FALLOW_ISSUES" | awk 'NF{c++}END{print c+0}')"
  [ "$FALLOW_ISSUE_COUNT" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Language detection
# ---------------------------------------------------------------------------

DEAD_CODE_ISSUES=""
DETECTED_LANG=""

detect_language() {
  DETECTED_LANG="unknown"
  [ "${#CHANGED_SCOPE_FILES[@]}" -gt 0 ] || return 0

  local ts_count=0 js_count=0 py_count=0 go_count=0 rb_count=0 rs_count=0

  for f in "${CHANGED_SCOPE_FILES[@]}"; do
    case "$f" in
      *.ts|*.tsx) ts_count=$((ts_count + 1)) ;;
      *.js|*.jsx|*.mjs|*.cjs) js_count=$((js_count + 1)) ;;
      *.py)       py_count=$((py_count + 1)) ;;
      *.go)       go_count=$((go_count + 1)) ;;
      *.rb)       rb_count=$((rb_count + 1)) ;;
      *.rs)       rs_count=$((rs_count + 1)) ;;
    esac
  done

  local max=0 lang="unknown"
  for pair in "ts:$ts_count" "js:$js_count" "py:$py_count" "go:$go_count" "rb:$rb_count" "rs:$rs_count"; do
    local l="${pair%%:*}" c="${pair##*:}"
    if [ "$c" -gt "$max" ]; then max="$c"; lang="$l"; fi
  done

  # ts and js both route to eslint
  [ "$lang" = "js" ] && lang="ts"
  DETECTED_LANG="$lang"
}

# ---------------------------------------------------------------------------
# Language-specific analysis runners
# ---------------------------------------------------------------------------

_scope_file_args() {
  local files=()
  for f in "${CHANGED_SCOPE_FILES[@]}"; do
    [ -f "$WORKSPACE_ROOT/$f" ] && files+=("$WORKSPACE_ROOT/$f")
  done
  printf '%s\n' "${files[@]}"
}

run_eslint_analysis() {
  command -v eslint >/dev/null 2>&1 || { log "  [fallback] eslint not found — using grep heuristics"; _grep_fallback; return; }
  local issues=""
  local args=()
  while IFS= read -r fpath; do args+=("$fpath"); done < <(_scope_file_args)
  [ "${#args[@]}" -gt 0 ] || return 0

  local raw
  raw="$(cd "$WORKSPACE_ROOT" && eslint --format json "${args[@]}" 2>/dev/null || true)"
  issues="$(printf '%s' "$raw" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
except Exception:
  sys.exit(0)
for r in data:
  f = r.get('filePath','')
  for m in r.get('messages',[]):
    sev = m.get('severity',0)
    if sev >= 1:
      rule = m.get('ruleId','lint') or 'lint'
      line = m.get('line','?')
      msg  = m.get('message','')
      print(f'{f}:{line}: [{rule}] {msg}')
" 2>/dev/null || true)"
  if [ -n "$issues" ]; then
    DEAD_CODE_ISSUES="$issues"
    return 1
  fi
  return 0
}

run_eslint_fix() {
  command -v eslint >/dev/null 2>&1 || return 0
  local args=()
  while IFS= read -r fpath; do args+=("$fpath"); done < <(_scope_file_args)
  [ "${#args[@]}" -gt 0 ] || return 0
  log "  [fallback] eslint --fix"
  cd "$WORKSPACE_ROOT" && eslint --fix "${args[@]}" 2>/dev/null || true
}

run_python_analysis() {
  local issues=""
  local args=()
  while IFS= read -r fpath; do args+=("$fpath"); done < <(_scope_file_args)
  [ "${#args[@]}" -gt 0 ] || return 0

  if command -v flake8 >/dev/null 2>&1; then
    local raw
    raw="$(cd "$WORKSPACE_ROOT" && flake8 --select=F401,F811,F841,W503 "${args[@]}" 2>/dev/null || true)"
    [ -n "$raw" ] && issues="$raw"
  fi

  if command -v vulture >/dev/null 2>&1; then
    local v_raw
    v_raw="$(cd "$WORKSPACE_ROOT" && vulture --min-confidence 80 "${args[@]}" 2>/dev/null | grep -v "^$" || true)"
    [ -n "$v_raw" ] && issues="${issues:+$issues
}$v_raw"
  fi

  if [ -z "$issues" ]; then
    _grep_fallback
    return
  fi

  DEAD_CODE_ISSUES="$issues"
  return 1
}

run_python_fix() {
  command -v autoflake >/dev/null 2>&1 || return 0
  local args=()
  while IFS= read -r fpath; do args+=("$fpath"); done < <(_scope_file_args)
  [ "${#args[@]}" -gt 0 ] || return 0
  log "  [fallback] autoflake --remove-all-unused-imports -i"
  cd "$WORKSPACE_ROOT" && autoflake --remove-all-unused-imports --remove-unused-variables -i "${args[@]}" 2>/dev/null || true
}

run_go_analysis() {
  local issues=""
  local pkg_dirs=()
  for f in "${CHANGED_SCOPE_FILES[@]}"; do
    [ -f "$WORKSPACE_ROOT/$f" ] || continue
    local d
    d="$(dirname "$WORKSPACE_ROOT/$f")"
    pkg_dirs+=("$d")
  done
  # unique dirs
  local seen_go=""
  local unique_dirs=()
  for d in "${pkg_dirs[@]}"; do
    case "$seen_go" in *"$d"*) ;; *) seen_go="$seen_go|$d"; unique_dirs+=("$d") ;; esac
  done
  [ "${#unique_dirs[@]}" -gt 0 ] || return 0

  if command -v staticcheck >/dev/null 2>&1; then
    local raw
    raw="$(cd "$WORKSPACE_ROOT" && staticcheck "${unique_dirs[@]}" 2>/dev/null || true)"
    [ -n "$raw" ] && issues="$raw"
  elif command -v go >/dev/null 2>&1; then
    local raw
    raw="$(cd "$WORKSPACE_ROOT" && go vet "${unique_dirs[@]}" 2>&1 || true)"
    [ -n "$raw" ] && issues="$raw"
  fi

  if [ -z "$issues" ]; then
    _grep_fallback
    return
  fi

  DEAD_CODE_ISSUES="$issues"
  return 1
}

run_go_fix() {
  command -v go >/dev/null 2>&1 || return 0
  log "  [fallback] go fix"
  cd "$WORKSPACE_ROOT" && go fix ./... 2>/dev/null || true
}

run_ruby_analysis() {
  command -v rubocop >/dev/null 2>&1 || { _grep_fallback; return; }
  local issues=""
  local args=()
  while IFS= read -r fpath; do args+=("$fpath"); done < <(_scope_file_args)
  [ "${#args[@]}" -gt 0 ] || return 0

  local raw
  raw="$(cd "$WORKSPACE_ROOT" && rubocop --format json "${args[@]}" 2>/dev/null || true)"
  issues="$(printf '%s' "$raw" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
except Exception:
  sys.exit(0)
for f_info in data.get('files',[]):
  path = f_info.get('path','')
  for o in f_info.get('offenses',[]):
    sev = o.get('severity','')
    if sev in ('warning','error','fatal','convention'):
      loc = o.get('location',{})
      line = loc.get('line','?')
      cop  = o.get('cop_name','rubocop')
      msg  = o.get('message','')
      print(f'{path}:{line}: [{cop}] {msg}')
" 2>/dev/null || true)"
  if [ -n "$issues" ]; then
    DEAD_CODE_ISSUES="$issues"
    return 1
  fi
  return 0
}

run_ruby_fix() {
  command -v rubocop >/dev/null 2>&1 || return 0
  local args=()
  while IFS= read -r fpath; do args+=("$fpath"); done < <(_scope_file_args)
  [ "${#args[@]}" -gt 0 ] || return 0
  log "  [fallback] rubocop --auto-correct-all"
  cd "$WORKSPACE_ROOT" && rubocop --auto-correct-all -A "${args[@]}" 2>/dev/null || true
}

run_rust_analysis() {
  command -v cargo >/dev/null 2>&1 || { _grep_fallback; return; }
  local issues=""
  local raw
  raw="$(cd "$WORKSPACE_ROOT" && cargo clippy -- -D warnings 2>&1 || true)"
  issues="$(printf '%s' "$raw" | grep -E '^error|^warning' | grep -v "^warning: unused import" | head -50 || true)"

  if [ -z "$issues" ]; then
    _grep_fallback
    return
  fi

  DEAD_CODE_ISSUES="$issues"
  return 1
}

run_rust_fix() {
  command -v cargo >/dev/null 2>&1 || return 0
  log "  [fallback] cargo fix --allow-dirty"
  cd "$WORKSPACE_ROOT" && cargo fix --allow-dirty 2>/dev/null || true
}

_grep_fallback() {
  local issues=()
  for f in "${CHANGED_SCOPE_FILES[@]}"; do
    local fpath="$WORKSPACE_ROOT/$f"
    [ -f "$fpath" ] || continue

    if [[ "$f" =~ \.(ts|tsx|js|jsx|mjs|cjs)$ ]]; then
      while IFS= read -r name; do
        [ -z "$name" ] && continue
        local uses
        uses="$(grep -v "^import" "$fpath" | grep -cw "$name" 2>/dev/null; true)"
        uses="${uses%%[^0-9]*}"
        if [ "${uses:-0}" -eq 0 ] 2>/dev/null; then
          issues+=("$f: possibly unused import: $name")
        fi
      done < <(
        grep "^import" "$fpath" 2>/dev/null \
          | grep -oE '\{[^}]+\}' | tr -d '{}' | tr ',' '\n' \
          | sed 's/[[:space:]]//g' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
          | sort -u || true
      )
    fi

    local console_count
    console_count="$(grep -c "console\.log" "$fpath" 2>/dev/null; true)"
    console_count="${console_count%%[^0-9]*}"
    if [ "${console_count:-0}" -gt 0 ] 2>/dev/null; then
      issues+=("$f: ${console_count} console.log statement(s)")
    fi

    local todo_count
    todo_count="$(grep -cE "(TODO|FIXME|HACK|XXX)" "$fpath" 2>/dev/null; true)"
    todo_count="${todo_count%%[^0-9]*}"
    if [ "${todo_count:-0}" -gt 0 ] 2>/dev/null; then
      issues+=("$f: ${todo_count} TODO/FIXME marker(s)")
    fi
  done

  if [ "${#issues[@]}" -gt 0 ]; then
    DEAD_CODE_ISSUES="$issues"
    DEAD_CODE_ISSUES="$(printf '%s\n' "${issues[@]}")"
    return 1
  fi
  return 0
}

run_fallback_analysis() {
  DEAD_CODE_ISSUES=""
  [ "${#CHANGED_SCOPE_FILES[@]}" -gt 0 ] || return 0
  detect_language
  log "  [fallback] Detected language: $DETECTED_LANG"
  case "$DETECTED_LANG" in
    ts) run_eslint_analysis ;;
    py) run_python_analysis ;;
    go) run_go_analysis ;;
    rb) run_ruby_analysis ;;
    rs) run_rust_analysis ;;
    *)  _grep_fallback ;;
  esac
}

run_lang_autofix() {
  [ "$USING_FALLOW" -eq 1 ] && return 0
  detect_language
  case "$DETECTED_LANG" in
    ts) run_eslint_fix ;;
    py) run_python_fix ;;
    go) run_go_fix ;;
    rb) run_ruby_fix ;;
    rs) run_rust_fix ;;
  esac
}

# ---------------------------------------------------------------------------
# Build structured report
# ---------------------------------------------------------------------------

_count_lines() { printf '%s\n' "$1" | awk 'NF{c++}END{print c+0}'; }

build_report() {
  local issues_json="[]"
  local total=0

  if [ -n "$FALLOW_ISSUES" ]; then
    total=$((total + $(_count_lines "$FALLOW_ISSUES")))
    issues_json="$(printf '%s' "$issues_json" | jq \
      --arg detail "$FALLOW_ISSUES" \
      '. += [{"type": "fallow-audit", "detail": $detail}]')"
  fi

  if [ -n "$DEAD_CODE_ISSUES" ]; then
    total=$((total + $(_count_lines "$DEAD_CODE_ISSUES")))
    issues_json="$(printf '%s' "$issues_json" | jq \
      --arg detail "$DEAD_CODE_ISSUES" \
      '. += [{"type": "dead-code-heuristic", "detail": $detail}]')"
  fi

  local files_json
  if [ "${#CHANGED_SCOPE_FILES[@]}" -gt 0 ]; then
    files_json="$(printf '%s\n' "${CHANGED_SCOPE_FILES[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")"
  else
    files_json="[]"
  fi

  jq -n \
    --arg story_id   "$STORY_ID" \
    --arg timestamp  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson files  "$files_json" \
    --argjson total  "$total" \
    --argjson issues "$issues_json" \
    --argjson passes "$([ "$total" -eq 0 ] && echo true || echo false)" \
    '{
      storyId:    $story_id,
      timestamp:  $timestamp,
      files:      $files,
      issueCount: $total,
      passes:     $passes,
      issues:     $issues
    }' > "$REPORT_FILE"

  echo "$total"
}

print_report() {
  jq -r '
    .issues[] |
    "  [\(.type)]\n\(.detail | split("\n") | map("    " + .) | join("\n"))"
  ' "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Analysis dispatch
# ---------------------------------------------------------------------------

USING_FALLOW=0

run_analysis() {
  FALLOW_ISSUES=""
  DEAD_CODE_ISSUES=""

  if [ "${#CHANGED_SCOPE_FILES[@]}" -eq 0 ]; then
    USING_FALLOW=0
    DEAD_CODE_ISSUES="No in-scope changed files were detected for this story branch diff."
    return 1
  fi

  if [ -n "$FALLOW_BIN" ] && [ "${#OUT_OF_SCOPE_CHANGED_FILES[@]}" -eq 0 ]; then
    if run_fallow_audit; then
      USING_FALLOW=1
      return 0
    fi
    USING_FALLOW=1
    return 1
  fi

  USING_FALLOW=0
  if [ -n "$FALLOW_BIN" ] && [ "${#OUT_OF_SCOPE_CHANGED_FILES[@]}" -gt 0 ]; then
    log "  [scope-guard] Skipping fallow audit because ${#OUT_OF_SCOPE_CHANGED_FILES[@]} changed file(s) fall outside story scope."
  fi
  run_fallback_analysis
}

# ---------------------------------------------------------------------------
# Codex auto-fix for what fallow fix can't handle
# ---------------------------------------------------------------------------

run_codex_fix() {
  local issue_summary
  issue_summary="$(jq -r '.issues[] | "[\(.type)]\n\(.detail)"' "$REPORT_FILE")"

  local files_list=""
  if [ "${#CHANGED_SCOPE_FILES[@]}" -gt 0 ]; then
    files_list="$(printf '  %s\n' "${CHANGED_SCOPE_FILES[@]}")"
  else
    files_list="  (no in-scope changed files detected)"
  fi

  local prompt
  prompt="$(cat <<PROMPT
## Fallow Auto-Fix: Code Quality Issues

Fix ALL remaining code quality issues listed below. Make minimal, surgical
changes — do not refactor beyond what is needed to resolve the issues.

**Files in scope:**
$files_list

**Issues to fix:**
$issue_summary

**Rules:**
- Remove dead code, unused imports, unreachable code paths
- Deduplicate repeated logic (extract helper only when clearly cleaner)
- Fix lint errors and warnings
- Remove console.log and TODO/FIXME markers that are not intentional
- Do NOT break any existing tests, types, or runtime behaviour
- Commit all changes when done
PROMPT
)"

  local log_file="$STORY_DIR/.fallow-autofix.txt"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  [DRY RUN] Would invoke Codex auto-fix"
    return 0
  fi

  log "  Running Codex auto-fix session..."
  codex_exec_prompt "$prompt" "$WORKSPACE_ROOT" 2>&1 | tee "$log_file"
}

# ---------------------------------------------------------------------------
# Main gate
# ---------------------------------------------------------------------------

scope_label=""
if [ "${#CHANGED_SCOPE_FILES[@]}" -gt 0 ]; then
  scope_label="${#CHANGED_SCOPE_FILES[@]} in-scope changed file(s) vs $BASE_REF"
else
  scope_label="no in-scope changed files vs $BASE_REF"
fi

log ""
log "=== ralph-fallow: $STORY_ID — $STORY_TITLE ==="
log "Analysis scope: $scope_label"
if [ "${#OUT_OF_SCOPE_CHANGED_FILES[@]}" -gt 0 ]; then
  log "Scope guard: ${#OUT_OF_SCOPE_CHANGED_FILES[@]} out-of-scope changed file(s) detected; using exact-file fallback analysis."
fi
if [ -n "$FALLOW_BIN" ] && [ "${#OUT_OF_SCOPE_CHANGED_FILES[@]}" -eq 0 ]; then
  log "Analyzer: fallow $(${FALLOW_BIN%% *} --version 2>/dev/null | head -1 || echo "(fallow.tools)")"
else
  detect_language
  case "$DETECTED_LANG" in
    ts) log "Analyzer: eslint (JS/TS fallback; install fallow for full analysis)" ;;
    py) log "Analyzer: flake8 + vulture (Python fallback; install fallow for full analysis)" ;;
    go) log "Analyzer: staticcheck/go vet (Go fallback; install fallow for full analysis)" ;;
    rb) log "Analyzer: rubocop (Ruby fallback; install fallow for full analysis)" ;;
    rs) log "Analyzer: cargo clippy (Rust fallback; install fallow for full analysis)" ;;
    *)  log "Analyzer: grep heuristics (install fallow: npm i -g fallow)" ;;
  esac
fi
log ""

# ── Phase 1: Analysis ─────────────────────────────────────────────────────
log "Phase 1 — Analysis"
run_analysis || true
ISSUE_COUNT="$(build_report)"

if [ "$ISSUE_COUNT" -eq 0 ]; then
  log ""
  log "=== Fallow PASS — no issues found ==="
  exit 0
fi

log ""
log "Phase 1 found $ISSUE_COUNT issue(s):"
print_report
log ""
log "Report: $REPORT_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  log ""
  log "=== Fallow DRY RUN — $ISSUE_COUNT issue(s) reported (not failing) ==="
  exit 0
fi

if [ "$NO_AUTOFIX" -eq 1 ]; then
  log ""
  log "=== Fallow FAIL — $ISSUE_COUNT issue(s) (--no-autofix) ==="
  exit 1
fi

# ── Phase 2: Auto-fix ─────────────────────────────────────────────────────
if [ "$ALLOW_EXACT_AUTOFIX" -ne 1 ] && [ "$ALLOW_CODEX_AUTOFIX" -ne 1 ]; then
  log ""
  log "=== Fallow FAIL — $ISSUE_COUNT issue(s); broad auto-fix disabled by default ==="
  log "Manual correction required before re-running ralph-task.sh."
  exit 1
fi

log "Phase 2 — Auto-fix"
[ "$USING_FALLOW" -eq 0 ] && [ "$ALLOW_EXACT_AUTOFIX" -eq 1 ] && run_lang_autofix
[ "$ALLOW_CODEX_AUTOFIX" -eq 1 ] && run_codex_fix

# ── Phase 3: Re-validate ──────────────────────────────────────────────────
log ""
log "Phase 3 — Re-validation"
run_analysis || true
ISSUE_COUNT="$(build_report)"

if [ "$ISSUE_COUNT" -eq 0 ]; then
  log ""
  log "=== Fallow PASS — issues resolved by auto-fix ==="
  exit 0
fi

log ""
log "=== Fallow FAIL — $ISSUE_COUNT issue(s) remain after auto-fix ==="
log "Manual correction required before re-running ralph-task.sh."
log ""
print_report
log ""
log "Report: $REPORT_FILE"
exit 1
