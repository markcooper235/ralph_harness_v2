#!/bin/bash
# e2e-claude-strengths.sh — Hard-mode corpus tuned to codebase navigation, refactoring, CI, and recovery workflows.
#
# This wrapper reuses the profile corpus runner with a dedicated corpus that
# emphasizes:
# - unfamiliar codebase navigation
# - whole-codebase refactors
# - toolchain / CI execution
# - test and regression recovery
#
# The resulting benchmark is intended to be compared across codex and piagent
# using the same corpus and result-first policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PROFILE_BENCH_CORPUS_FILE="$SCRIPT_DIR/profile-benchmark-claude-strengths.json"
export PROFILE_BENCH_CORPUS_LABEL="profile-benchmark-claude-strengths"
export PROFILE_BENCH_SLUG="claude-strengths"
export PROFILE_BENCH_LABEL="profile-claude-strengths"

exec "$SCRIPT_DIR/e2e-profile-corpus.sh" "$@"
