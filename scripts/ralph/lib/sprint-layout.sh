#!/bin/bash
# Shared sprint/backlog/archive layout helpers for Ralph.

ralph_backlog_root() {
  printf '%s/backlog\n' "$SCRIPT_DIR"
}

ralph_sprints_root() {
  printf '%s/sprints\n' "$SCRIPT_DIR"
}

ralph_archive_root() {
  printf '%s/archive\n' "$(ralph_sprints_root)"
}

_path_rewrite_files() {
  local dir="$1"
  local old_prefix="$2"
  local new_prefix="$3"

  [ -d "$dir" ] || return 0

  find "$dir" -type f \
    ! -name 'archive-manifest.txt' \
    ! -name '*.zip' \
    -print0 \
    | xargs -0 perl -0pi -e "s|\Q$old_prefix\E|$new_prefix|g" 2>/dev/null || true
}

_unique_existing_sprint_dir() {
  local sprint="$1"
  local -a matches=()
  local candidate

  for candidate in \
    "$(ralph_backlog_root)/$sprint" \
    "$(ralph_sprints_root)/$sprint"
  do
    if [ -d "$candidate" ]; then
      matches+=("$candidate")
    fi
  done

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    matches+=("$candidate")
  done < <(
    find "$(ralph_archive_root)" -mindepth 1 -maxdepth 1 -type d \
      \( -name "*-$sprint" -o -name "$sprint" \) 2>/dev/null | sort
  )

  case "${#matches[@]}" in
    0) return 1 ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *)
      printf 'ERROR: duplicate sprint directories found for %s:\n' "$sprint" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 2
      ;;
  esac
}

sprint_dir_for_name() {
  _unique_existing_sprint_dir "$1"
}

sprint_stories_file() {
  local sprint="$1"
  local sprint_dir
  sprint_dir="$(sprint_dir_for_name "$sprint")" || return 1
  printf '%s/stories.json\n' "$sprint_dir"
}

sprint_backlog_dir() {
  local sprint="$1"
  printf '%s/%s\n' "$(ralph_backlog_root)" "$sprint"
}

sprint_live_dir() {
  local sprint="$1"
  printf '%s/%s\n' "$(ralph_sprints_root)" "$sprint"
}

sprint_archive_dir() {
  local sprint="$1"
  local archive_root
  archive_root="$(ralph_archive_root)"
  find "$archive_root" -mindepth 1 -maxdepth 1 -type d \
    \( -name "*-$sprint" -o -name "$sprint" \) 2>/dev/null | sort | tail -n1
}

sprint_story_path() {
  local sprint="$1"
  local story_id="$2"
  local sprint_dir
  sprint_dir="$(sprint_dir_for_name "$sprint")" || return 1
  printf '%s/stories/%s/story.json\n' "$sprint_dir" "$story_id"
}

ensure_sprint_backlog_structure() {
  local sprint="$1"
  local sprint_dir
  sprint_dir="$(sprint_backlog_dir "$sprint")"
  mkdir -p "$sprint_dir/stories"

  if [ ! -f "$sprint_dir/stories.json" ]; then
    jq -n \
      --argjson version 1 \
      --arg project "$(basename "$WORKSPACE_ROOT")" \
      --arg sprint "$sprint" \
      '{
        "version": $version,
        "project": $project,
        "sprint": $sprint,
        "status": "planned",
        "capacityTarget": 8,
        "capacityCeiling": 10,
        "activeStoryId": null,
        "stories": []
      }' > "$sprint_dir/stories.json"
  fi
}

ensure_sprint_live_structure() {
  local sprint="$1"
  local sprint_dir
  sprint_dir="$(sprint_live_dir "$sprint")"
  mkdir -p "$sprint_dir/stories"
}

move_sprint_dir() {
  local sprint="$1"
  local from_dir="$2"
  local to_dir="$3"
  local old_prefix="$4"
  local new_prefix="$5"

  [ -d "$from_dir" ] || return 0
  [ ! -e "$to_dir" ] || return 1
  mkdir -p "$(dirname "$to_dir")"
  mv "$from_dir" "$to_dir"
  _path_rewrite_files "$to_dir" "$old_prefix" "$new_prefix"
}
