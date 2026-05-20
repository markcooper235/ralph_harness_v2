#!/bin/bash
# lib/specify.sh — Shared SpecKit CLI discovery helpers (sourced)

specify_repo_bin() {
  printf '%s/bin/specify\n' "$SCRIPT_DIR"
}

find_specify_bin() {
  local repo_bin
  repo_bin="$(specify_repo_bin)"
  if [ -x "$repo_bin" ]; then
    echo "$repo_bin"
    return 0
  fi

  if command -v specify >/dev/null 2>&1; then
    command -v specify
    return 0
  fi

  if command -v npx >/dev/null 2>&1 && npx --yes specify version >/dev/null 2>&1; then
    echo "npx --yes specify"
    return 0
  fi

  return 1
}

describe_specify_bin() {
  local specify_bin="$1"
  local repo_bin
  repo_bin="$(specify_repo_bin)"

  if [ "$specify_bin" = "$repo_bin" ]; then
    if [ -x "$SCRIPT_DIR/.venv-specify/bin/specify" ]; then
      echo "repo-local persistent install"
    else
      echo "repo-local wrapper"
    fi
    return 0
  fi

  if [ "$specify_bin" = "npx --yes specify" ]; then
    echo "npx fallback"
    return 0
  fi

  echo "global install"
}

specify_cache_dir() {
  printf '%s/.cache/specify\n' "$SCRIPT_DIR"
}

repo_briefing_path() {
  printf '%s/repo-briefing.md\n' "$(specify_cache_dir)"
}

collect_repo_briefing_sources() {
  local workspace_root="${1:-$PWD}"
  local candidates=()
  local pattern file

  for file in \
    "$workspace_root/package.json" \
    "$workspace_root/README.md" \
    "$workspace_root/angular.json" \
    "$workspace_root/tsconfig.json" \
    "$workspace_root/jsconfig.json"
  do
    [ -f "$file" ] && candidates+=("$file")
  done

  for pattern in \
    "$workspace_root/tsconfig.*.json" \
    "$workspace_root/next.config.*" \
    "$workspace_root/vite.config.*" \
    "$workspace_root/jest.config.*" \
    "$workspace_root/vitest.config.*" \
    "$workspace_root/playwright.config.*" \
    "$workspace_root/eslint.config.*" \
    "$workspace_root/.eslintrc*" \
    "$workspace_root/.prettierrc*" \
    "$workspace_root/tailwind.config.*"
  do
    while IFS= read -r file; do
      [ -f "$file" ] && candidates+=("$file")
    done < <(compgen -G "$pattern" || true)
  done

  if [ "${#candidates[@]}" -gt 0 ]; then
    printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
  fi
}

build_repo_briefing() {
  local workspace_root="${1:-$PWD}"
  local output_path="${2:-$(repo_briefing_path)}"
  local package_json="$workspace_root/package.json"
  local tsconfig_json="$workspace_root/tsconfig.json"
  local project_name framework_summary package_manager rel_output
  local source_dirs config_sources
  local scripts_block alias_block config_block

  mkdir -p "$(dirname "$output_path")"

  project_name="$(basename "$workspace_root")"
  framework_summary="None detected"
  package_manager="unknown"
  scripts_block="Not detected"
  alias_block="None detected"
  config_block="None detected"
  source_dirs=""

  if [ -f "$package_json" ]; then
    project_name="$(jq -r '.name // empty' "$package_json" 2>/dev/null || true)"
    [ -n "$project_name" ] || project_name="$(basename "$workspace_root")"

    framework_summary="$(jq -r '
      [
        if (.dependencies.next // .devDependencies.next) then "Next.js" else empty end,
        if (.dependencies.react // .devDependencies.react) then "React" else empty end,
        if (.dependencies["@angular/core"] // .devDependencies["@angular/core"]) then "Angular" else empty end,
        if (.dependencies.vue // .devDependencies.vue) then "Vue" else empty end,
        if (.dependencies.svelte // .devDependencies.svelte) then "Svelte" else empty end,
        if (.dependencies.typescript // .devDependencies.typescript) then "TypeScript" else empty end,
        if (.dependencies.jest // .devDependencies.jest) then "Jest" else empty end,
        if (.dependencies.vitest // .devDependencies.vitest) then "Vitest" else empty end,
        if (.dependencies.playwright // .devDependencies.playwright) then "Playwright" else empty end
      ] | unique | join(", ")
    ' "$package_json" 2>/dev/null || true)"
    [ -n "$framework_summary" ] || framework_summary="No common framework marker detected"

    scripts_block="$(jq -r '
      (.scripts // {})
      | to_entries
      | map(select(.key | test("^(dev|build|test|lint|typecheck|check|verify)$")))
      | if length == 0 then "Not detected"
        else map("- `" + .key + "`: `" + .value + "`") | join("\n")
        end
    ' "$package_json" 2>/dev/null || true)"

    if [ -f "$workspace_root/pnpm-lock.yaml" ]; then
      package_manager="pnpm"
    elif [ -f "$workspace_root/yarn.lock" ]; then
      package_manager="yarn"
    elif [ -f "$workspace_root/package-lock.json" ]; then
      package_manager="npm"
    fi
  fi

  if [ -f "$tsconfig_json" ]; then
    alias_block="$(jq -r '
      (.compilerOptions.paths // {})
      | to_entries
      | if length == 0 then "None detected"
        else map("- `" + .key + "` -> `" + (.value | join(", ")) + "`") | join("\n")
        end
    ' "$tsconfig_json" 2>/dev/null || true)"
  fi

  source_dirs="$(
    for dir in src app pages components lib server tests test __tests__ e2e packages; do
      [ -d "$workspace_root/$dir" ] && printf '%s\n' "$dir"
    done | awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 } END { printf "\n" }'
  )"
  [ -n "$source_dirs" ] || source_dirs="No common source/test roots detected"

  config_sources="$(collect_repo_briefing_sources "$workspace_root" || true)"
  if [ -n "$config_sources" ]; then
    config_block="$(
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        printf -- '- `%s`\n' "${file#$workspace_root/}"
      done <<< "$config_sources"
    )"
  fi

  rel_output="${output_path#$workspace_root/}"
  cat > "$output_path" <<EOF
# Repo Briefing

This file is a compact cached project summary for SpecKit preparation. Use it instead of broad repo rediscovery when possible.

## Project Snapshot
- Name: $project_name
- Package manager: $package_manager
- Frameworks/tooling: $framework_summary
- Likely source/test roots: $source_dirs

## Primary Commands
$scripts_block

## Path Aliases
$alias_block

## Notable Config Files
$config_block

## Guidance For Story Prep
- Read this briefing first before opening broad project docs or scaffold files.
- Inspect additional files only when they are directly relevant to the current story.
- Prefer nearest implementation files, tests, and config over repo-wide exploration.
- If this briefing is missing something essential, read only the smallest supporting file needed and continue.
EOF

  printf '%s\n' "$rel_output"
}

ensure_repo_briefing() {
  local workspace_root="${1:-$PWD}"
  local output_path source
  local rebuild=0

  output_path="$(repo_briefing_path)"
  if [ ! -f "$output_path" ]; then
    rebuild=1
  else
    while IFS= read -r source; do
      [ -n "$source" ] || continue
      if [ "$source" -nt "$output_path" ]; then
        rebuild=1
        break
      fi
    done < <(collect_repo_briefing_sources "$workspace_root" || true)
  fi

  if [ "$rebuild" -eq 1 ]; then
    build_repo_briefing "$workspace_root" "$output_path" >/dev/null
  fi

  printf '%s\n' "$output_path"
}

specify_is_noise_path() {
  local candidate="${1:-}"
  [ -n "$candidate" ] || return 0

  case "$candidate" in
    node_modules/*|*/node_modules/*|.next/*|*/.next/*|coverage/*|*/coverage/*|dist/*|*/dist/*|build/*|*/build/*|vendor/*|*/vendor/*|tmp/*|*/tmp/*|temp/*|*/temp/*|output/*|*/output/*|playwright-report/*|*/playwright-report/*|test-results/*|*/test-results/*|scripts/ralph/runtime/*|*/scripts/ralph/runtime/*|.cache/*|*/.cache/*)
      return 0
      ;;
  esac

  case "$candidate" in
    *.log|*.tmp|*.temp|*.cache)
      return 0
      ;;
  esac

  case "$candidate" in
    */docs/*|docs/*|*/doc/*|doc/*)
      return 0
      ;;
  esac

  case "$candidate" in
    */dist-docs/*|dist-docs/*)
      return 0
      ;;
  esac

  return 1
}

sanitize_specify_paths() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    specify_is_noise_path "$path" && continue
    printf '%s\n' "$path"
  done | awk '!seen[$0]++'
}

specify_story_keywords() {
  local text="${1:-}"
  printf '%s\n' "$text" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs '[:alnum:]/._-' '\n' \
    | awk '
        length($0) < 4 { next }
        $0 ~ /^[0-9]+$/ { next }
        $0 ~ /^(that|this|with|from|into|onto|over|under|then|than|only|also|such|some|more|most|less|very|just|have|has|had|were|been|being|make|made|build|using|used|create|implement|write|story|sprint|task|phase|file|files|component|service|class|module|types|type|test|tests|spec|specs|goal|context|constraints|priority|effort|depends|input|default|project|briefing|avoid)$/ { next }
        !seen[$0]++ { print }
      ' \
    | head -n 12
}

collect_story_focus_hints() {
  local workspace_root="${1:-$PWD}"
  local story_text="${2:-}"
  local path_hints="" keyword candidate literal
  local -a candidates=()

  [ -n "$story_text" ] || return 0

  while IFS= read -r literal; do
    [ -n "$literal" ] || continue
    while [[ "$literal" =~ [\.\,\:\;\!\?\"\'\`\)]+$ ]]; do
      literal="${literal%?}"
    done
    case "$literal" in
      */|*.*|*/*)
        [[ "$literal" =~ \.[A-Za-z0-9]+$ ]] || continue
        case "$literal" in
          @*)
            continue
            ;;
        esac
        case "$literal" in
          *[0-9]/[0-9]*)
            continue
            ;;
        esac
        specify_is_noise_path "$literal" && continue
        candidates+=("$literal")
        ;;
    esac
  done < <(
    printf '%s\n' "$story_text" \
      | tr ' ' '\n' \
      | sed 's/^[`"'"'"'([]*//; s/[`"'"'"')],:;.!?]*$//' \
      | awk '
          length($0) >= 4 &&
          ($0 ~ /\// || $0 ~ /\.[A-Za-z0-9]+$/) &&
          $0 !~ /^[0-9./-]+$/ &&
          $0 !~ /\/[0-9]/ &&
          !seen[$0]++
        '
  )

  command -v rg >/dev/null 2>&1 || {
    [ "${#candidates[@]}" -eq 0 ] && return 0
    printf '%s\n' "${candidates[@]}" \
      | awk '!seen[$0]++' \
      | head -n 8 \
      | while IFS= read -r candidate; do
          [ -n "$candidate" ] || continue
          printf -- '- `%s`\n' "$candidate"
        done
    return 0
  }

  while IFS= read -r keyword; do
    [ -n "$keyword" ] || continue
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      case "$candidate" in
        node_modules/*|.git/*|dist/*|build/*|coverage/*|tmp/*|temp/*|output/*|playwright-report/*|test-results/*)
          continue
          ;;
      esac
      candidates+=("$candidate")
        done < <(rg --files "$workspace_root" -g "*${keyword}*" 2>/dev/null | sed "s#^$workspace_root/##" | head -n 4)
  done < <(specify_story_keywords "$story_text")

  if [ "${#candidates[@]}" -eq 0 ]; then
    return 0
  fi

  path_hints="$(
    printf '%s\n' "${candidates[@]}" \
      | sanitize_specify_paths \
      | head -n 8 \
      | while IFS= read -r candidate; do
          [ -n "$candidate" ] || continue
          printf -- '- `%s`\n' "$candidate"
        done
  )"

  [ -n "$path_hints" ] && printf '%s\n' "$path_hints"
}
