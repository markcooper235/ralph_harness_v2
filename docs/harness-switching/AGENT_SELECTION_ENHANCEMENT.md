# Automatic Agent Selection Based on Story Classification

This document describes an enhancement to automatically select the appropriate agent based on story characteristics, eliminating the need to manually specify `--agent` or `RALPH_AGENT` for every story execution.

## Problem Statement

Currently, users must manually specify which agent to use for each story execution:
```bash
./scripts/ralph/ralph-story-run.sh --agent researcher --story path/to/story.json
```

This is tedious and error-prone. Instead, we want Ralph to automatically determine the appropriate agent based on the story's characteristics.

## Solution Overview

We'll implement a multi-layered agent selection system that determines the agent in this order of precedence:

1. **Explicit Override** (Highest Priority)
   - Command-line `--agent` option
   - Environment variable `RALPH_AGENT`
   - Install-time default agent

2. **Story-Defined Agent** (New Feature)
   - `agent` field in story.json
   - `labels`/`tags` array in story.json with mapping to agents

3. **Content-Based Inference** (New Feature)
   - Analyze story title, description, and tasks for keywords
   - Map detected themes to appropriate agents

4. **Default Agent** (Lowest Priority)
   - Harness-specific default agent
   - Falls back to a generic agent if none specified

## Implementation Plan

### 1. Story.json Enhancements

We'll extend the story.json format to support explicit agent specification:

```json
{
  "storyId": "S-001",
  "title": "Implement user authentication system",
  "agent": "senior-dev",  // Explicit agent specification
  
  // OR
  
  "labels": ["security", "backend", "authentication"],  // Label-based approach
  
  // ... rest of story fields
}
```

### 2. Agent Classification System

We'll define a set of standard agent types with their characteristics:

| Agent Type | Best For | Suggested Model | Characteristics |
|------------|----------|-----------------|-----------------|
| `researcher` | Investigation, debugging, exploration | Strong model (gpt-4, claude-3-opus) | Analytical, thorough, curious |
| `junior-dev` | Simple features, bug fixes, typos | Weaker/faster model (gpt-3.5-turbo, claude-3-haiku) | Quick, efficient, focused on small changes |
| `senior-dev` | Complex features, architecture, refactoring | Strong model (gpt-4, claude-3-opus) | Experienced, considers long-term implications |
| `security` | Security patches, vulnerability fixes, audits | Strong model with safety focus | Security-conscious, threat-aware |
| `qa-test` | Test creation, validation, verification | Balanced model | Detail-oriented, systematic |
| `devops` | Infrastructure, deployment, CI/CD | Balanced model | System-focused, automation-oriented |
| `documentation` | Docs, comments, explanations | Balanced model | Clear, explanatory, user-focused |

### 3. Label-to-Agent Mapping

We'll provide a configurable mapping from story labels to agent types:

```json
// In a config file like scripts/ralph/agent-mapping.json
{
  "labels_to_agents": {
    "debug": "researcher",
    "investigate": "researcher",
    "research": "researcher",
    "security": "security",
    "vulnerability": "security",
    "auth": "security",
    "encrypt": "security",
    "typo": "junior-dev",
    "text": "junior-dev",
    "ui": "junior-dev",
    "minor": "junior-dev",
    "refactor": "senior-dev",
    "performance": "senior-dev",
    "optimize": "senior-dev",
    "architecture": "senior-dev",
    "test": "qa-test",
    "validation": "qa-test",
    "verify": "qa-test",
    "deploy": "devops",
    "infrastructure": "devops",
    "ci": "devops",
    "cd": "devops",
    "doc": "documentation",
    "comment": "documentation",
    "explain": "documentation"
  }
}
```

### 4. Content-Based Inference Rules

When no explicit agent or labels are present, we'll analyze:

**Title/Description Keywords:**
- Security: `security`, `vulnerability`, `auth`, `authentication`, `encrypt`, `password`, `token`, `oauth`, `jwt`, `xss`, `csrf`, `injection`
- Debug/Research: `debug`, `investigate`, `research`, `investigation`, `troubleshoot`, `diagnose`, `analyze`, `root cause`
- Junior Dev: `typo`, `text`, `string`, `label`, `button`, `ui`, `ux`, `minor`, `small`, `trivial`, `fix`, `fixes`
- Senior Dev: `refactor`, `restructure`, `architecture`, `performance`, `optimize`, `scale`, `scalability`, `design pattern`, `solid`, `drY`
- QA/Test: `test`, `testing`, `unit test`, `integration test`, `e2e`, `validation`, `verify`, `assert`, `mock`, `stub`
- DevOps: `deploy`, `deployment`, `infrastructure`, `docker`, `kubernetes`, `k8s`, `aws`, `azure`, `gcp`, `ci`, `cd`, `pipeline`, `terraform`, `ansible`
- Documentation: `doc`, `documentation`, `comment`, `explain`, `description`, `readme`, `guide`, `tutorial`, `wiki`

**Task Analysis:**
We can also look at the tasks themselves for more specific clues.

### 5. Implementation Details

We'll add this logic to `scripts/ralph/lib/harness-exec.sh` in a new function `_determine_agent_from_story()` that:

1. Reads the story.json file
2. Checks for explicit `agent` field
3. If not found, checks for `labels`/`tags` array and applies mapping
4. If still not found, performs keyword analysis on title/description/tasks
5. Returns the determined agent name

This function will be called by each harness executor when `RALPH_AGENT` is not already set via more explicit means (command line/environment).

### 6. Configuration Files

We'll add:
- `scripts/ralph/agent-mapping.json` - Label to agent mappings (customizable)
- `scripts/ralph/agent-profiles.json` - Agent definitions with suggested models, etc. (for future enhancement)

## Usage Examples

### Explicit Agent in Story (Most Deterministic)
```json
{
  "storyId": "S-SEC-001",
  "title": "Fix OAuth token validation vulnerability",
  "agent": "security",
  "tasks": [
    {
      "id": "T-SEC-001",
      "title": "Validate OAuth token expiration and signature",
      // ...
    }
  ]
}
```
→ Automatically uses security agent

### Label-Based Agent
```json
{
  "storyId": "S-FEAT-002",
  "title": "Add user profile picture upload",
  "labels": ["feature", "frontend", "ui"],
  "tasks": [/* ... */]
}
```
→ Maps "ui" label → junior-dev agent

### Content-Based Inference
```json
{
  "storyId": "S-DEBUG-003",
  "title": "Investigate intermittent API timeout errors",
  "description": "Users report occasional 504 errors when calling the payment API. Need to investigate logs, trace requests, and identify root cause.",
  "tasks": [
    {
      "id": "T-DEBUG-001",
      "title": "Enable debug logging for payment API",
      // ...
    },
    {
      "id": "T-DEBUG-002",
      "title": "Analyze error patterns in logs over past week",
      // ...
    }
  ]
}
```
→ Keywords: "Investigate", "errors", "logs", "root cause" → researcher agent

### Fallback Behavior
If no agent can be determined through any method:
- Uses harness-specific default agent
- Falls back to a generic "default" agent
- Logs a warning that agent selection fell back to default

## Benefits

1. **Zero Configuration** - Users don't need to manually specify agents for each story
2. **Consistency** - Similar stories get similar agents automatically
3. **Discoverability** - Clear mapping from story content to agent selection
4. **Flexibility** - Still supports explicit override when needed
5. **Deterministic** - Same story always gets same agent (unless explicitly overridden)
6. **Extensible** - Easy to add new agent types and mapping rules

## Implementation Order

1. Add agent detection logic to harness-exec.sh
2. Add story.json field support (agent, labels)
3. Add label-to-agent mapping configuration
4. Add keyword-based inference rules
5. Add logging/feedback when agents are auto-selected
6. Update documentation

This enhancement would work seamlessly with the existing harness switching capabilities - users can still override the auto-selected agent via `--agent` or `RALPH_AGENT` when needed.