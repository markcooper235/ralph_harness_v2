# Ralph Harness Switching Guide

This guide explains how to switch between different AI harnesses (Codex, PI Agent, Claude Code) in the Ralph framework, along with model and agent selection capabilities.

## Overview

The Ralph framework has been enhanced to support seamless switching between different AI backends at both install time and runtime. This allows users to:

1. Choose their preferred AI harness when installing Ralph
2. Switch harnesses dynamically at runtime using command-line options or environment variables
3. Specify models and agents for each harness (where supported)
4. Maintain consistent behavior across all harnesses

## Implementation Details

### Core Changes

1. **Added `scripts/ralph/lib/harness-exec.sh`**:
   - Central dispatcher that selects the appropriate harness based on configuration
   - Implements executors for all four harnesses:
     - Codex (original functionality preserved)
     - PI Agent (uses `pi -p` with `PI_PERMISSION_LEVEL=bypassed`)
     - Claude Code (uses `claude -p` with `--permission-mode dontAsk`)
   - Handles model and agent selection for each harness
   - Provides consistent argument passing and environment variable handling

2. **Modified `scripts/ralph/ralph-story-run.sh`**:
   - Replaced direct `codex_exec_prompt` calls with `harness_exec_prompt`
   - Added command-line options for harness/model/agent selection
   - Exports configuration variables for subprocesses

3. **Updated `scripts/ralph/install.sh`**:
   - Added `--harness`, `--model`, and `--agent` options
   - Sets default values that can be overridden at runtime
   - Copies the new harness-exec.sh library during installation

4. **Enhanced `scripts/ralph/ralph.sh`**:
   - Added `--harness`, `--model`, and `--agent` command-line options
   - Exports these as environment variables for subprocesses

## Usage Instructions

### Install-Time Selection

Choose your default harness, model, and agent when installing Ralph:

```bash
# Install with Claude Code
bash install.sh --harness claude_code --model claude-3-opus
```

### Runtime Selection (Recommended for Flexibility)

Override the install-time defaults at runtime using command-line options or environment variables:

#### Using ralph.sh (sprint execution loop)

```bash
# Use Pi Agent for this sprint execution
RALPH_HARNESS=piagent ./scripts/ralph/ralph.sh

# Use Claude Code with specific model
RALPH_HARNESS=claude_code RALPH_MODEL=claude-3-sonnet ./scripts/ralph/ralph.sh

# Combine with other ralph.sh options
RALPH_HARNESS=piagent RALPH_MODEL=gpt-4-turbo ./scripts/ralph/ralph.sh --max-stories 10 --continue-on-failure
```

#### Using ralph-story-run.sh (direct story execution)

```bash
# Execute with Claude Code and specific model/agent
./scripts/ralph/ralph-story-run.sh --harness claude_code --model claude-3-opus --agent research --story path/to/story.json

# Combine with other ralph-story-run.sh options
./scripts/ralph/ralph-story-run.sh --harness piagent --model gpt-3.5 --agent assistant --story path/to/story.json --max-retries 3
```

#### Environment Variable Overrides

For maximum flexibility, you can also use environment variables directly:

```bash
# Temporary override for a single command
RALPH_HARNESS=piagent RALPH_MODEL=gpt-4 RALPH_AGENT=coding ./scripts/ralph/ralph.sh

# Set for multiple commands in a session
export RALPH_HARNESS=piagent
export RALPH_MODEL=gpt-4
export RALPH_AGENT=assistant
./scripts/ralph/ralph.sh
./scripts/ralph/ralph-story-run.sh --story path/to/story.json
```

### Priority Order

The system follows this priority order for determining which harness/model/agent to use:

1. **Command-line options** (highest priority)
   - `--harness`, `--model`, `--agent` on the specific command
2. **Environment variables**
   - `RALPH_HARNESS`, `RALPH_MODEL`, `RALPH_AGENT`
3. **Install-time defaults**
   - Values set during `install.sh`
4. **Built-in defaults**
   - `codex` harness, harness-specific model/agent defaults

When `RALPH_AGENT` is not explicitly set, Ralph can infer an agent automatically:

1. **Explicit story field**
   - `story.json` `agent`
2. **Labels/tags**
   - Mapped through `label-to-agent-mapping.json`
3. **Content inference**
   - Based on story title, description, and task titles
4. **Fallback**
   - Uses the default agent behavior

### Harness-Specific Notes

#### Codex
- Supports `--model` and `--agent` flags (standard Codex functionality)
- Uses `--yolo` when available, falls back to `--dangerously-bypass-approvals-and-sandbox`
- Profile support via `RALPH_CODEX_PROFILE` environment variable

#### PI Agent
- Uses `pi -p` for print/non-interactive mode
- Permission bypass: `PI_PERMISSION_LEVEL=bypassed` environment variable
- Supports `--model` and `--agent` flags (if available in your PI Agent version)
- Accepts additional PI Agent-specific flags

#### Claude Code
- Uses `claude -p` for print/non-interactive mode
- Permission bypass: `--permission-mode dontAsk` (avoids initial interactive dialog)
- Supports `--model` flag
- Note: Claude Code doesn't have explicit agent selection like Codex, but supports different behaviors via permission modes

## Provider Configuration

Ralph does not manage provider selection or API keys—it merely passes the model string and relies on the harness to interpret it. To use OpenRouter (or any custom provider), you would:

1. Set the appropriate environment variables for the harness (e.g., `OPENAI_BASE_URL=https://openrouter.ai/api/v1` and `OPENAI_API_KEY=<your‑openrouter‑key>` for Codex‑like harnesses, or the equivalent for PI‑Agent/Claude‑Code).
2. Provide the full model identifier that the harness expects when targeting OpenRouter (often `openrouter/<provider>/<model>` or similar—check the harness’s documentation).

Ralph also supports automatic fallback to native provider API keys when the primary provider fails:

### Automatic Fallback Mechanism

If you set `*_API_KEY_NATIVE` environment variables (e.g., `OPENAI_API_KEY_NATIVE`, `ANTHROPIC_API_KEY_NATIVE`), Ralph will automatically attempt one fallback on failure:

1. **First attempt**: Uses the configured provider (e.g., OpenRouter via `OPENAI_BASE_URL`)
2. **On failure** (non-zero exit):
   - Unsets `OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL` (harnesses use default endpoints)
   - Sets API keys to the matching `*_NATIVE` values
   - Does not fall back to stored harness OAuth/account authentication
3. **Second attempt**: Runs with the fallback configuration

### Examples

To fall back to native OpenAI/Anthropic API keys:
```bash
export OPENAI_API_KEY_NATIVE="sk-..."
export ANTHROPIC_API_KEY_NATIVE="sk-ant-..."
```

If you leave the matching `*_NATIVE` variable unset, Ralph will stop after the first failure instead of using stored harness auth.

If you want Ralph to validate or document provider‑specific requirements, you could extend `harness-capabilities.json` with a `provider` field and perhaps a `requires_base_url` flag, but that is optional; the current capability model already lets you specify which models are available per harness, and you can simply add the OpenRouter‑qualified model strings to the `available_models` list.

In short: No code change is strictly required—just configure the harness environment and model string as you would outside Ralph. If you want Ralph to be aware of provider‑specific needs, update `harness-capabilities.json` accordingly.

## Verification

To verify your configuration is working correctly:

```bash
# Test harness selection with dry-run
RALPH_HARNESS=piagent ./scripts/ralph/ralph-story-run.sh --story path/to/story.json --dry-run

# Check that the correct harness is reported in the output
# You should see: "Running story cycle via piagent: primary"

# Test argument passing
RALPH_MODEL=gpt-4 RALPH_AGENT=coding ./scripts/ralph/ralph-story-run.sh --story path/to/story.json --dry-run 2>&1 | rg "\--model gpt\-4|\--agent coding"
```

## End-to-End Testing

For actual end-to-end testing with AI execution:

1. **Ensure your target harness is installed and authenticated**:
   - PI Agent: `pi login` (or equivalent)
   - Claude Code: `claude auth login`

2. **Run a simple test story**:
   ```bash
   # Create a minimal test story
   cat > test-story.json <<'EOF'
   {
     "version": 1,
     "project": "Test",
     "storyId": "S-TEST",
     "title": "Simple verification test",
     "description": "Create a verification file to test harness execution.",
     "branchName": "ralph/sprint-1/test",
     "sprint": "sprint-1",
     "priority": 1,
     "depends_on": [],
     "status": "active",
     "spec": {
       "scope": "Create a simple verification file.",
       "out_of_scope": [],
       "first_slice": {
         "source": "",
         "destination": "verification.txt",
         "entrypoint": ""
       },
       "preserved_invariants": [],
       "supporting_files": [],
       "verification": [
         "File verification.txt exists",
         "File verification.txt contains 'Harness test successful'"
       ]
     },
     "tasks": [
       {
         "id": "T-TEST-01",
         "title": "Create verification file",
         "context": "Create a file named verification.txt with the content 'Harness test successful'.",
         "scope": ["verification.txt"],
         "acceptance": "File exists with correct content.",
         "checks": [
           "test -f verification.txt",
           "rg -q 'Harness test successful' verification.txt"
         ],
         "depends_on": [],
         "status": "pending",
         "passes": false
       }
     ],
     "passes": false
   }
   EOF

   # Execute with your chosen harness
   RALPH_HARNESS=piagent ./scripts/ralph/ralph-story-run.sh --story test-story.json
   ```

## Troubleshooting

1. **Harness not found**: Ensure the harness CLI is installed and in your PATH
   - PI Agent: `which pi`
   - Claude Code: `which claude`

2. **Permission errors**: Verify the permission bypass flags are correct for your harness version

3. **Model/agent not supported**: Some older versions may not support `--model` or `--agent` flags
   - Try running the harness CLI with `--help` to see available options
   - The system will gracefully ignore unsupported flags

4. **Authentication issues**: Ensure you're logged into the respective AI service
   - Each harness has its own authentication mechanism

## Benefits

1. **Zero Downtime Switching**: Change harnesses without reinstalling or reconfiguring
2. **Consistent Workflow**: Same Ralph commands work with any harness
3. **Flexible Experimentation**: Easily compare performance and capabilities of different AI backends
4. **Team Accommodation**: Different team members can use their preferred harnesses
5. **Future-Proof**: Easy to add new harnesses as they become available

## Example Workflows

### CI/CD Pipeline
```bash
# In your CI script
export RALPH_HARNESS=claude_code
export RALPH_MODEL=claude-3-opus
./scripts/ralph/ralph.sh --max-stories 5
```

### A/B Testing Harnesses
```bash
# Run sprint 1 with Codex
RALPH_HARNESS=codex ./scripts/ralph/ralph.sh
./scripts/ralph/ralph-sprint-commit.sh

```

### Specialized Agent Usage
```bash
# Use a coding-specialized agent for implementation stories
RALPH_AGENT=coding ./scripts/ralph/ralph-story-run.sh --story implementation-story.json

# Use a research-oriented agent for exploration stories
RALPH_AGENT=research ./scripts/ralph/ralph-story-run.sh --story exploration-story.json
```

---

**Note**: This implementation maintains full backward compatibility. Existing Ralph installations and workflows continue to work exactly as before when no harness/model/agent options are specified.
