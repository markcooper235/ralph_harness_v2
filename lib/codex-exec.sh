#!/bin/bash
# lib/codex-exec.sh — Shared Codex exec helper (sourced, not executed directly)
#
# Provides codex_exec_prompt() for consistent --yolo / approval-bypass behaviour
# across ralph scripts. Respects CODEX_BIN and RALPH_CODEX_PROFILE env vars.

codex_timeout_available() {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

codex_timeout_prefix() {
  local timeout_seconds="${RALPH_CODEX_TIMEOUT_SEC:-0}"
  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -le 0 ]; then
    return 0
  fi

  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout --foreground %ss\n' "$timeout_seconds"
    return 0
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout --foreground %ss\n' "$timeout_seconds"
    return 0
  fi
}

codex_common_exec_flags() {
  local -a flags=()
  [ "${RALPH_CODEX_DISABLE_PLUGINS:-1}" = "1" ] && flags+=(--disable plugins)
  [ "${RALPH_CODEX_IGNORE_RULES:-1}" = "1" ] && flags+=(--ignore-rules)
  [ "${RALPH_CODEX_IGNORE_USER_CONFIG:-0}" = "1" ] && flags+=(--ignore-user-config)
  [ "${RALPH_CODEX_EPHEMERAL:-0}" = "1" ] && flags+=(--ephemeral)
  printf '%s\n' "${flags[@]}"
}

run_codex_exec() {
  local prompt="$1"
  shift

  local timeout_prefix
  timeout_prefix="$(codex_timeout_prefix)"

  local -a cmd=()
  if [ -n "$timeout_prefix" ]; then
    # shellcheck disable=SC2206
    cmd=( $timeout_prefix )
  fi

  local -a codex_flags=()
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    codex_flags+=("$flag")
  done < <(codex_common_exec_flags)

  printf '%s\n' "$prompt" | "${cmd[@]+"${cmd[@]}"}" "${CODEX_BIN:-codex}" "$@" "${codex_flags[@]+"${codex_flags[@]}"}" -
}

_supports_codex_yolo() {
  local out
  out="$("${CODEX_BIN:-codex}" --yolo exec --help 2>&1 || true)"
  echo "$out" | grep -qi "unexpected argument '--yolo'" && return 1
  echo "$out" | grep -qi "Run Codex non-interactively" && return 0
  return 1
}

# codex_exec_prompt <prompt> <workspace_root> [extra_codex_flags...]
#
# Pipes <prompt> to codex via stdin using --yolo if available, falling back to
# --dangerously-bypass-approvals-and-sandbox. Always passes -C <workspace_root>
# so the session runs from the repo root regardless of caller's cwd.
codex_exec_prompt() {
  local prompt="$1"
  local workspace="${2:-$PWD}"
  shift 2 || true
  local profile_args=()
  [ -n "${RALPH_CODEX_PROFILE:-}" ] && profile_args=(--profile "$RALPH_CODEX_PROFILE")
  if _supports_codex_yolo; then
    run_codex_exec "$prompt" --yolo exec "${profile_args[@]+"${profile_args[@]}"}" -C "$workspace" "$@"
  else
    run_codex_exec "$prompt" exec --dangerously-bypass-approvals-and-sandbox "${profile_args[@]+"${profile_args[@]}"}" -C "$workspace" "$@"
  fi
}
