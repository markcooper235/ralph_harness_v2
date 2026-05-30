# Ralph Harness Switching Implementation Summary

## Overview

This document summarizes the implementation of harness switching capability in the Ralph framework, allowing users to switch between different AI backends (Codex, Opencode, PI Agent, Claude Code) at both install time and runtime, along with model and agent selection.

## Problem Statement

The original Ralph framework was tightly coupled to the Codex CLI, making it difficult to experiment with or switch to other AI harnesses. Users needed a way to:
1. Choose their preferred AI harness when installing Ralph
2. Switch harnesses dynamically at runtime
3. Specify models and agents for each harness (where supported)
4. Maintain consistent behavior across all harnesses

## Solution Implemented

### Core Components

1. **`scripts/ralph/lib/harness-exec.sh`** - New shared library
   - Provides `harness_exec_prompt()` dispatcher function
   - Implements executors for all four harnesses:
     - Codex (original functionality preserved)
     - Opencode (uses `opencode run` with `--dangerously-skip-permissions`)
     - PI Agent (uses `pi -p` with `PI_PERMISSION_LEVEL=bypassed`)
     - Claude Code (uses `claude -p` with `--permission-mode dontAsk`)
   - Handles model and agent selection for each harness
   - Includes shared helper functions (like Codex's `--yolo` support check)
   - Exports configuration variables for subprocesses

2. **`scripts/ralph/ralph-story-run.sh`** - Modified
   - Replaced direct `codex_exec_prompt` calls with `harness_exec_prompt`
   - Added `--harness`, `--model`, and `--agent` command-line options
   - Exports configuration variables for subprocesses
   - Updated log messages to show active harness
   - Maintains all existing functionality (dry-run, retries, etc.)

3. **`scripts/ralph/install.sh`** - Enhanced
   - Added `--harness HARNESS` option (codex|opencode|piagent|claude_code, default: codex)
   - Added `--model MODEL` option (default: harness-specific)
   - Added `--agent AGENT` option (default: harness-specific)
   - Sets `RALPH_HARNESS`, `RALPH_MODEL`, `RALPH_AGENT` environment variables in installed copies
   - Copies harness-exec.sh library during installation
   - Updated documentation and help text

4. **`scripts/ralph/ralph.sh`** - Enhanced
   - Added `--harness`, `--model`, and `--agent` command-line options
   - Exports these as environment variables for subprocesses (especially ralph-story-run.sh)
   - Updated help text and documentation
   - Maintains all existing sprint execution functionality

## Usage Patterns

### 1. Install-Time Selection (Persistent Default)

```bash
# Install with Opencode as the default harness
bash install.sh --harness opencode

# Install with specific model and agent
bash install.sh --harness opencode --model gpt-4 --agent coding

# Install with Claude Code
bash install.sh --harness claude_code --model claude-3-opus
```

These settings become the default for all Ralph commands in that installation unless overridden at runtime.

### 2. Runtime Selection via Environment Variables (Flexible Override)

```bash
# Use Pi Agent for this specific Ralph execution
RALPH_HARNESS=piagent ./scripts/ralph/ralph.sh

# Use Claude Code with a specific model
RALPH_HARNESS=claude_code RALPH_MODEL=claude-3-sonnet ./scripts/ralph/ralph.sh

# Combine with other Ralph options
RALPH_HARNESS=opencode RALPH_MODEL=gpt-4-turbo ./scripts/ralph/ralph.sh --max-stories 10 --continue-on-failure

# Set for multiple commands in a session
export RALPH_HARNESS=piagent
export RALPH_MODEL=gpt-4
export RALPH_AGENT=assistant
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-story-run.sh --story path/to/story.json
```

### 3. Runtime Selection via Command-Line Options (Per-Invocation Control)

```bash
# Execute a specific story with Opencode
./scripts/ralph/ralph-story-run.sh --harness opencode --story path/to/story.json

# Execute with Claude Code and specific model/agent
./scripts/ralph/ralph-story-run.sh --harness claude_code --model claude-3-opus --agent research --story path/to/story.json

# Combine with other ralph-story-run.sh options
./scripts/ralph/ralph-story-run.sh --harness piagent --model gpt-3.5 --agent assistant --story path/to/story.json --max-retries 3 --dry-run
```

## Priority Order (Highest to Lowest)

1. **Command-line options** (`--harness`, `--model`, `--agent` on the specific command)
2. **Environment variables** (`RALPH_HARNESS`, `RALPH_MODEL`, `RALPH_AGENT`)
3. **Install-time defaults** (values set during `install.sh`)
4. **Built-in defaults** (`codex` harness, harness-specific model/agent defaults)

## Harness-Specific Details

### Codex Executor (Default)
- Command: `codex exec` or `codex --yolo exec`
- Permission bypass: `--yolo` (preferred) or `--dangerously-bypass-approvals-and-sandbox`
- Model selection: `--model` flag (when available)
- Agent selection: `--agent` flag (when available)
- Profile support: `RALPH_CODEX_PROFILE` environment variable
- Working directory: Changed via `-C` flag

### Opencode Executor
- Command: `opencode run`
- Permission bypass: `--dangerously-skip-permissions`
- Model selection: `--model` flag (when available)
- Agent selection: `--agent` flag (when available)
- Additional flags: Passthrough of all additional arguments
- Working directory: Changed via internal `cd` command
- Input: Prompt provided via stdin

### PI Agent Executor
- Command: `pi -p` (print/non-interactive mode)
- Permission bypass: `PI_PERMISSION_LEVEL=bypassed` environment variable
- Model selection: `--model` flag (when available)
- Agent selection: `--agent` flag (when available)
- Additional flags: Passthrough of all additional arguments
- Working directory: Changed via internal `cd` command

### Claude Code Executor
- Command: `claude -p` (print/non-interactive mode)
- Permission bypass: `--permission-mode dontAsk` (avoids initial interactive dialog)
- Model selection: `--model` flag (when available)
- Agent selection: Not directly supported (Claude Code uses permission modes instead)
- Additional flags: Passthrough of all additional arguments (like `--max-turns`)
- Working directory: Changed via internal `cd` command

## Benefits

### 1. Zero Downtime Switching
Users can switch between AI harnesses without reinstalling or reconfiguring the Ralph framework.

### 2. Consistent Workflow
All Ralph commands (`ralph.sh`, `ralph-story-run.sh`, `ralph-sprint.sh`, etc.) work identically regardless of the underlying harness.

### 3. Flexible Experimentation
Teams can easily compare performance, capabilities, and costs of different AI backends for the same workloads.

### 4. Team Accommodation
Different team members can use their preferred AI harnesses without conflict.

### 5. Future-Proof Design
Adding new harnesses requires only adding a new executor function to `harness-exec.sh`.

### 6. Backward Compatibility
Existing Ralph installations and workflows continue to work exactly as before when no options are specified.

## Verification and Testing

The implementation has been verified through:

1. **Unit Testing**: Direct testing of harness selection logic and argument passing
2. **Integration Testing**: Verification that command-line options are properly processed and exported
3. **Backward Compatibility Testing**: Confirmation that existing workflows remain functional
4. **Help Documentation**: Verification that new options appear correctly in command help
5. **Environment Variable Handling**: Confirmation that variables are properly propagated to subprocesses

## Example Workflows

### CI/CD Pipeline Integration
```bash
# In your CI/CD configuration
export RALPH_HARNESS=claude_code
export RALPH_MODEL=claude-3-opus
export RALPH_AGENT=research
./scripts/ralph/ralph.sh --max-stories 5
```

### A/B Testing Harnesses
```bash
# Run sprint with Codex (baseline)
RALPH_HARNESS=codex ./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh

# Run next sprint with Opencode (comparison)
RALPH_HARNESS=opencode ./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh
```

### Specialized Task Execution
```bash
# Use a coding-optimized model for implementation stories
RALPH_MODEL=gpt-4-turbo ./scripts/ralph/ralph-story-run.sh --story implementation-story.json

# Use a research-oriented model for exploration stories
RALPH_MODEL=claude-3-opus ./scripts/ralph/ralph-story-run.sh --story exploration-story.json

# Use a debugging-specialized agent for bug-fixing stories
RALPH_AGENT=debugger ./scripts/ralph/ralph-story-run.sh --story bugfix-story.json
```

## Maintenance and Extensibility

### Adding a New Harness

To add support for a new AI harness:

1. Add a new executor function to `scripts/ralph/lib/harness-exec.sh`:
   ```bash
   _mynewharness_exec_prompt() {
     local prompt="$1"
     local workspace="${2:-$PWD}"
     shift 2 || true
     
     # Harness-specific implementation
     # ...
   }
   ```

2. Add the new harness to the case statement in `harness_exec_prompt()`:
   ```bash
   mynewharness)
     _mynewharness_exec_prompt "$prompt" "$workspace" "$@"
     ;;
   ```

3. Update the help text in `install.sh` and `ralph.sh` to include the new harness option.

### Supported Features Matrix

| Feature | Codex | Opencode | PI Agent | Claude Code |
|---------|-------|----------|----------|-------------|
| Permission Bypass | ✓ | ✓ | ✓ | ✓ |
| Model Selection | ✓ | ✓ | ✓ | ✓ |
| Agent Selection | ✓ | ✓ | ✓ | △* |
| Non-Interactive Mode | ✓ | ✓ | ✓ | ✓ |
| Additional Args Passthrough | ✓ | ✓ | ✓ | ✓ |
| Working Directory Control | ✓ | ✓ | ✓ | ✓ |

*Claude Code uses permission modes rather than explicit agent selection

## Conclusion

This implementation provides a robust, flexible, and backward-compatible solution for harness switching in the Ralph framework. Users can now seamlessly switch between different AI backends, experiment with various models and agents, and maintain consistent workflows regardless of their underlying AI infrastructure choices.

The design prioritizes:
- **Simplicity**: Clear, intuitive command-line interface
- **Flexibility**: Multiple ways to configure harness/model/agent selection
- **Reliability**: Consistent behavior across all harnesses
- **Extensibility**: Easy to add new harnesses as they become available
- **Compatibility**: Full backward compatibility with existing installations