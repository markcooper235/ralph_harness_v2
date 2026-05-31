#!/bin/bash
# Test script for automatic agent selection logic

echo "Running agent selection test..."

# Source the harness-exec library to get the agent determination functions
source scripts/ralph/lib/harness-exec.sh

# Test cases for different story types

# Test 1: Research/debug story
cat > /tmp/debug-story.json << 'EOF'
{
  "storyId": "S-DEBUG-001",
  "title": "Investigate intermittent API timeout errors",
  "description": "Users report occasional 504 errors when calling the payment API. Need to investigate logs, trace requests, and identify root cause.",
  "tasks": [
    {
      "id": "T-DEBUG-001",
      "title": "Enable debug logging for payment API"
    },
    {
      "id": "T-DEBUG-002",
      "title": "Analyze error patterns in logs over past week"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/debug-story.json")
echo "Debug story agent: $AGENT"
if [ "$AGENT" = "researcher" ]; then
  echo "✓ Correctly identified researcher agent for debug story"
else
  echo "✗ Expected researcher agent, got $AGENT"
fi

# Test 2: Security story
cat > /tmp/security-story.json << 'EOF'
{
  "storyId": "S-SEC-001",
  "title": "Fix OAuth token validation vulnerability",
  "description": "Validate OAuth token expiration and signature to prevent unauthorized access",
  "tasks": [
    {
      "id": "T-SEC-001",
      "title": "Implement proper token validation"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/security-story.json")
echo "Security story agent: $AGENT"
if [ "$AGENT" = "security" ]; then
  echo "✓ Correctly identified security agent for security story"
else
  echo "✗ Expected security agent, got $AGENT"
fi

# Test 3: Junior dev story (typo fix)
cat > /tmp/junior-story.json << 'EOF'
{
  "storyId": "S-JUNIOR-001",
  "title": "Fix typo in user profile",
  "description": "Correct a spelling mistake in the user profile display name",
  "tasks": [
    {
      "id": "T-JUNIOR-001",
      "title": "Change 'proifle' to 'profile' in the header"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/junior-story.json")
echo "Junior dev story agent: $AGENT"
if [ "$AGENT" = "junior-dev" ]; then
  echo "✓ Correctly identified junior-dev agent for typo story"
else
  echo "✗ Expected junior-dev agent, got $AGENT"
fi

# Test 4: Senior dev story (refactor)
cat > /tmp/senior-story.json << 'EOF'
{
  "storyId": "S-SENIOR-001",
  "title": "Refactor authentication service for better performance",
  "description": "Restructure the authentication service to improve scalability and maintainability",
  "tasks": [
    {
      "id": "T-SENIOR-001",
      "title": "Extract password validation into separate service"
    },
    {
      "id": "T-SENIOR-002",
      "title": "Implement caching for user lookups"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/senior-story.json")
echo "Senior dev story agent: $AGENT"
if [ "$AGENT" = "senior-dev" ]; then
  echo "✓ Correctly identified senior-dev agent for refactor story"
else
  echo "✗ Expected senior-dev agent, got $AGENT"
fi

# Test 5: QA/Test story
cat > /tmp/qa-story.json << 'EOF'
{
  "storyId": "S-QA-001",
  "title": "Create unit tests for payment processing",
  "description": "Write comprehensive unit tests for the payment processing module",
  "tasks": [
    {
      "id": "T-QA-001",
      "title": "Create test cases for successful payments"
    },
    {
      "id": "T-QA-002",
      "title": "Create test cases for failed payments"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/qa-story.json")
echo "QA story agent: $AGENT"
if [ "$AGENT" = "qa-test" ]; then
  echo "✓ Correctly identified qa-test agent for test story"
else
  echo "✗ Expected qa-test agent, got $AGENT"
fi

# Test 6: DevOps story
cat > /tmp/devops-story.json << 'EOF'
{
  "storyId": "S-DEVOPS-001",
  "title": "Deploy application to Kubernetes cluster",
  "description": "Set up CI/CD pipeline for deploying to AWS EKS cluster",
  "tasks": [
    {
      "id": "T-DEVOPS-001",
      "title": "Create Dockerfile for application"
    },
    {
      "id": "T-DEVOPS-002",
      "title": "Configure Kubernetes deployment manifests"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/devops-story.json")
echo "DevOps story agent: $AGENT"
if [ "$AGENT" = "devops" ]; then
  echo "✓ Correctly identified devops agent for deployment story"
else
  echo "✗ Expected devops agent, got $AGENT"
fi

# Test 7: Documentation story
cat > /tmp/doc-story.json << 'EOF'
{
  "storyId": "S-DOC-001",
  "title": "Document API endpoints for frontend team",
  "description": "Create comprehensive documentation for all REST API endpoints with examples",
  "tasks": [
    {
      "id": "T-DOC-001",
      "title": "Document user authentication endpoints"
    },
    {
      "id": "T-DOC-002",
      "title": "Document payment processing endpoints"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/doc-story.json")
echo "Documentation story agent: $AGENT"
if [ "$AGENT" = "documentation" ]; then
  echo "✓ Correctly identified documentation agent for doc story"
else
  echo "✗ Expected documentation agent, got $AGENT"
fi

# Test 8: Label-based selection (should override content-based)
cat > /tmp/label-story.json << 'EOF'
{
  "storyId": "S-LABEL-001",
  "title": "Some random title",
  "description": "Some random description that might suggest a different agent",
  "labels": ["security", "performance"],
  "tasks": [
    {
      "id": "T-LABEL-001",
      "title": "Do something"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/label-story.json")
echo "Label-based story agent: $AGENT"
# Should pick security (first match in labels array based on our mapping)
if [ "$AGENT" = "security" ]; then
  echo "✓ Correctly identified security agent from labels (override content)"
else
  echo "✗ Expected security agent from labels, got $AGENT"
fi

# Test 9: Explicit agent field (should override everything)
cat > /tmp/explicit-story.json << 'EOF'
{
  "storyId": "S-EXPLICIT-001",
  "title": "Any title",
  "description": "Any description",
  "agent": "researcher",
  "labels": ["ui", "frontend"],
  "tasks": [
    {
      "id": "T-EXPLICIT-001",
      "title": "Do something"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/explicit-story.json")
echo "Explicit agent story agent: $AGENT"
if [ "$AGENT" = "researcher" ]; then
  echo "✓ Correctly identified explicit researcher agent (override labels and content)"
else
  echo "✗ Expected researcher agent from explicit field, got $AGENT"
fi

# Test 10: Fallback to default when nothing matches
cat > /tmp/default-story.json << 'EOF'
{
  "storyId": "S-DEFAULT-001",
  "title": "Some generic task",
  "description": "Do some generic work that doesn't match any keywords",
  "tasks": [
    {
      "id": "T-DEFAULT-001",
      "title": "Do something generic"
    }
  ]
}
EOF

AGENT=$(_determine_agent_from_story "/tmp/default-story.json")
echo "Default story agent: $AGENT"
if [ "$AGENT" = "default" ]; then
  echo "✓ Correctly fell back to default agent for unmatched story"
else
  echo "✗ Expected default agent, got $AGENT"
fi

# Clean up temporary files
rm -f /tmp/debug-story.json /tmp/security-story.json /tmp/junior-story.json \
      /tmp/senior-story.json /tmp/qa-story.json /tmp/devops-story.json \
      /tmp/doc-story.json /tmp/label-story.json /tmp/explicit-story.json \
      /tmp/default-story.json

echo "Agent selection test completed."
exit 0