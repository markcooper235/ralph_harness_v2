#!/bin/bash
# lib/codex-exec.sh — Shared Codex exec helper (sourced, not executed directly)
#
# Provides codex_exec_prompt() for consistent --yolo / approval-bypass behaviour
# across ralph scripts. Respects CODEX_BIN and RALPH_CODEX_PROFILE env vars.

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
    printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" --yolo exec "${profile_args[@]+"${profile_args[@]}"}" -C "$workspace" "$@" -
  else
    printf '%s\n' "$prompt" | "${CODEX_BIN:-codex}" exec --dangerously-bypass-approvals-and-sandbox "${profile_args[@]+"${profile_args[@]}"}" -C "$workspace" "$@" -
  fi
}
