#!/bin/bash
# Test script for integrated harness switching features

echo "Running integrated features test..."

# Test that the harness-exec.sh library loads without error
source scripts/ralph/lib/harness-exec.sh
echo "✓ harness-exec.sh loaded successfully"

# Test that harness-capabilities.sh loads without error
source scripts/ralph/lib/harness-capabilities.sh
echo "✓ harness-capabilities.sh loaded successfully"

# Test that we can determine agent from a sample story
# Create a temporary story file for testing
cat > /tmp/test-story.json << 'EOF'
{
  "storyId": "S-TEST-001",
  "title": "Fix typo in user profile",
  "description": "Correct a spelling mistake in the user profile display name",
  "tasks": [
    {
      "id": "T-TEST-001",
      "title": "Change 'proifle' to 'profile' in the header"
    }
  ]
}
EOF

# Test agent determination
AGENT=$(_determine_agent_from_story "/tmp/test-story.json")
echo "Determined agent for typo story: $AGENT"
if [ "$AGENT" = "junior-dev" ]; then
  echo "✓ Correctly identified junior-dev agent for typo story"
else
  echo "✗ Expected junior-dev agent, got $AGENT"
fi

# Test label-based agent determination
cat > /tmp/test-story-labels.json << 'EOF'
{
  "storyId": "S-TEST-002",
  "title": "Add new feature",
  "labels": ["security", "backend"],
  "tasks": [
    {
      "id": "T-TEST-002",
      "title": "Implement authentication endpoint"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/test-story-labels.json")
echo "Determined agent for security-labeled story: $AGENT"
if [ "$AGENT" = "security" ]; then
  echo "✓ Correctly identified security agent from labels"
else
  echo "✗ Expected security agent, got $AGENT"
fi

# Test explicit agent in story
cat > /tmp/test-story-explicit.json << 'EOF'
{
  "storyId": "S-TEST-003",
  "title": "Explicit agent test",
  "agent": "senior-dev",
  "tasks": [
    {
      "id": "T-TEST-003",
      "title": "Do something complex"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/test-story-explicit.json")
echo "Determined agent for explicit agent story: $AGENT"
if [ "$AGENT" = "senior-dev" ]; then
  echo "✓ Correctly identified explicit senior-dev agent"
else
  echo "✗ Expected senior-dev agent, got $AGENT"
fi

# Test composite profile attachment only when explicitly enabled
unset RALPH_MODEL RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE
unset RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON RALPH_COMPOSITE_STEPS_JSON
unset RALPH_ENABLE_COMPOSITES RALPH_DISABLE_COMPOSITES
RALPH_HARNESS=codex
export RALPH_HARNESS
_apply_agent_profile researcher
if [ -z "${RALPH_COMPOSITE_PROFILE:-}" ] && [ -z "${RALPH_COMPOSITE_PROFILE_JSON:-}" ]; then
  echo "✓ Composite profiles stay off by default"
else
  echo "✗ Composite profiles should be off by default, got ${RALPH_COMPOSITE_PROFILE:-<none>}"
fi

export RALPH_ENABLE_COMPOSITES=1
_apply_agent_profile researcher
echo "Composite profile for researcher: ${RALPH_COMPOSITE_PROFILE:-<none>}"
if [ "${RALPH_COMPOSITE_PROFILE:-}" = "fanout_research_v1" ] && [ "${RALPH_COMPOSITE_SHAPE:-}" = "fanout" ]; then
  echo "✓ Correctly attached fanout_research_v1 composite profile"
else
  echo "✗ Expected fanout_research_v1 composite profile, got ${RALPH_COMPOSITE_PROFILE:-<none>}"
fi

unset RALPH_MODEL RALPH_AGENT RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE
unset RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON RALPH_COMPOSITE_STEPS_JSON
unset RALPH_ENABLE_COMPOSITES RALPH_DISABLE_COMPOSITES
RALPH_HARNESS=piagent
export RALPH_HARNESS
_apply_agent_profile researcher
if [ "${RALPH_PIAGENT_ROLE:-}" = "researcher" ]; then
  echo "✓ Pi harness derives role hint from the researcher profile"
else
  echo "✗ Expected piagent researcher role hint, got ${RALPH_PIAGENT_ROLE:-<none>}"
fi

unset RALPH_MODEL RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE
unset RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON RALPH_COMPOSITE_STEPS_JSON
export RALPH_DISABLE_COMPOSITES=1
_apply_agent_profile researcher
if [ -z "${RALPH_COMPOSITE_PROFILE:-}" ] && [ -z "${RALPH_COMPOSITE_PROFILE_JSON:-}" ]; then
  echo "✓ Composite profiles are suppressed when RALPH_DISABLE_COMPOSITES=1"
else
  echo "✗ Composite profiles should be suppressed, got ${RALPH_COMPOSITE_PROFILE:-<none>}"
fi
unset RALPH_ENABLE_COMPOSITES RALPH_DISABLE_COMPOSITES

# Clean up temporary files
rm -f /tmp/test-story.json /tmp/test-story-labels.json /tmp/test-story-explicit.json

echo "Integrated features test completed."
exit 0
