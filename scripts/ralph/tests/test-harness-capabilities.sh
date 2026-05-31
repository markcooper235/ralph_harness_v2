#!/bin/bash
# Test script for harness capabilities

echo "Running harness capabilities test..."

# Test that the harness-capabilities.sh library loads without error
source scripts/ralph/lib/harness-capabilities.sh
echo "✓ harness-capabilities.sh loaded successfully"

# Test that we can check if a harness supports model selection
# We'll test with a known harness (codex) and an unknown one
if harness_supports_model_selection "codex"; then
  echo "✓ codex supports model selection (as expected)"
else
  echo "✗ codex should support model selection"
fi

if ! harness_supports_model_selection "unknown_harness"; then
  echo "✓ unknown_harness does not support model selection (as expected)"
else
  echo "✗ unknown_harness should not support model selection"
fi

# Test agent selection support
if harness_supports_agent_selection "codex"; then
  echo "✓ codex supports agent selection (as expected)"
else
  echo "✗ codex should support agent selection"
fi

if ! harness_supports_agent_selection "unknown_harness"; then
  echo "✓ unknown_harness does not support agent selection (as expected)"
else
  echo "✗ unknown_harness should not support agent selection"
fi

# Test getting default model for a harness
DEFAULT_MODEL=$(get_harness_default_model "codex")
if [ -n "$DEFAULT_MODEL" ]; then
  echo "✓ codex default model: $DEFAULT_MODEL"
else
  echo "✗ codex default model should be set"
fi

# Test getting default agent for a harness
DEFAULT_AGENT=$(get_harness_default_agent "codex")
if [ -n "$DEFAULT_AGENT" ]; then
  echo "✓ codex default agent: $DEFAULT_AGENT"
else
  echo "✗ codex default agent should be set"
fi

echo "Harness capabilities test completed."
exit 0