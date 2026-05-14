'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')

const REPO_ROOT = path.resolve(__dirname, '..')

function run(cmd, args, { cwd, env } = {}) {
  return execFileSync(cmd, args, {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: 'pipe',
  })
}

function tryRun(cmd, args, { cwd, env } = {}) {
  return spawnSync(cmd, args, {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: 'pipe',
  })
}

function writeFile(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true })
  fs.writeFileSync(targetPath, contents)
}

function writeExecutable(targetPath, contents) {
  writeFile(targetPath, contents)
  fs.chmodSync(targetPath, 0o755)
}

function chmodScripts(rootDir) {
  const stack = [rootDir]
  while (stack.length > 0) {
    const current = stack.pop()
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name)
      if (entry.isDirectory()) { stack.push(fullPath); continue }
      if (entry.name.endsWith('.sh')) fs.chmodSync(fullPath, 0o755)
    }
  }
}

function initTempRepo({ branch = 'master' } = {}) {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-test-'))
  const frameworkRoot = path.join(repoDir, 'scripts', 'ralph')
  fs.mkdirSync(path.dirname(frameworkRoot), { recursive: true })
  fs.cpSync(REPO_ROOT, frameworkRoot, {
    recursive: true,
    filter: (src) =>
      !src.includes(`${path.sep}.git${path.sep}`) &&
      !src.endsWith(`${path.sep}.git`),
  })
  chmodScripts(frameworkRoot)

  run('git', ['init', '-b', branch], { cwd: repoDir })
  run('git', ['config', 'user.name', 'Ralph Test'], { cwd: repoDir })
  run('git', ['config', 'user.email', 'ralph-test@example.com'], { cwd: repoDir })
  run('git', ['add', '.'], { cwd: repoDir })
  run('git', ['commit', '-m', 'init'], { cwd: repoDir })
  return repoDir
}

function storiesJson(sprint, { status = 'planned', stories = [], activeStoryId = null } = {}) {
  return JSON.stringify(
    {
      version: 1,
      project: 'tmp-ralph-test',
      sprint,
      status,
      capacityTarget: 8,
      capacityCeiling: 10,
      activeStoryId,
      stories,
    },
    null,
    2
  )
}

function storyRecord(id, { title = 'Test story', status = 'ready', storyPath = null } = {}) {
  const entry = { id, title, priority: 1, effort: 1, status }
  if (storyPath) entry.story_path = storyPath
  return entry
}

// ---------------------------------------------------------------------------
// ralph-sprint next — sprint selection
// ---------------------------------------------------------------------------

test('ralph-sprint next returns the first ready sprint in sorted order', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'closed',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-10/stories.json'),
    storiesJson('sprint-10', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-2')
})

test('ralph-sprint next skips planned and closed sprints, returning only ready ones', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [storyRecord('S-001', { status: 'planned' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-2')
})

test('ralph-sprint next skips historic blocked-only sprints before the roadmap baseline', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/roadmap.json'),
    JSON.stringify({ sprints: [{ name: 'sprint-3' }, { name: 'sprint-4' }] }, null, 2)
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [storyRecord('S-001', { status: 'blocked' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-3/stories.json'),
    storiesJson('sprint-3', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-3')
})

// ---------------------------------------------------------------------------
// ralph-sprint next --activate — activation via find_next_sprint
// ---------------------------------------------------------------------------

test('ralph-sprint next --activate activates the next ready sprint and checks out its branch', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'closed',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next', '--activate'], { cwd: repoDir })
  assert.match(output, /^sprint-2$/m)
  assert.match(output, /Active sprint set to: sprint-2/)
  assert.match(output, /Checked out sprint branch: ralph\/sprint\/sprint-2/)
  assert.equal(
    fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'utf8'),
    'sprint-2\n'
  )
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-2')
})

// ---------------------------------------------------------------------------
// ralph-sprint mark-ready — sprint readiness gate
// ---------------------------------------------------------------------------

test('ralph-sprint mark-ready fails when stories are not ready', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'planned',
      stories: [
        storyRecord('S-001', { status: 'ready' }),
        storyRecord('S-002', { status: 'planned' }),
      ],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['mark-ready', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /S-002/)
})

test('ralph-sprint mark-ready succeeds when all active stories are ready', () => {
  const repoDir = initTempRepo()

  const sprintFile = path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json')
  writeFile(
    sprintFile,
    storiesJson('sprint-user-auth', {
      status: 'planned',
      stories: [
        storyRecord('S-001', { status: 'ready' }),
        storyRecord('S-002', { status: 'done' }),
        storyRecord('S-003', { status: 'abandoned' }),
      ],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['mark-ready', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.match(output, /marked ready/)
  const data = JSON.parse(fs.readFileSync(sprintFile, 'utf8'))
  assert.equal(data.status, 'ready')
})

test('ralph-sprint mark-ready rejects already-active or closed sprints', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'active',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['mark-ready', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /already active/)
})

// ---------------------------------------------------------------------------
// ralph-sprint use — activation gate
// ---------------------------------------------------------------------------

test('ralph-sprint use fails when sprint status is not ready', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'planned',
      stories: [storyRecord('S-001', { status: 'planned' })],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /not ready/)
})

test('ralph-sprint use fails when another sprint is still active', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-2'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /still active/)
})

test('ralph-sprint use succeeds when sprint is ready and previous sprint is closed', () => {
  const repoDir = initTempRepo()

  const sprint2File = path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'closed',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    sprint2File,
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-2'], { cwd: repoDir })
  assert.match(output, /Active sprint set to: sprint-2/)
  assert.equal(
    fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'utf8'),
    'sprint-2\n'
  )
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-2')
  const data = JSON.parse(fs.readFileSync(sprint2File, 'utf8'))
  assert.equal(data.status, 'active')
})

test('ralph-sprint use succeeds for the first sprint with no previous sprint', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.match(output, /Active sprint set to: sprint-user-auth/)
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-user-auth')
})

test('ralph-story generate --force recovers a migration placeholder from PRD markdown and unblocks the story', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-003.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json')
  const promptLog = path.join(repoDir, 'mock-codex-prompt.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      stories: [
        {
          id: 'S-003',
          title: 'Markdown-only epic',
          priority: 3,
          effort: 1,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json',
          goal: 'Recover from markdown',
          promptContext: 'legacy prompt context',
        },
      ],
    })
  )
  writeFile(path.join(repoDir, prdPath), '# PRD\n\nRecover this story from markdown.\n')
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-003',
        title: 'Markdown-only epic',
        description: 'Recover from markdown',
        branchName: 'ralph/sprint-1/epic-003',
        sprint: 'sprint-1',
        priority: 3,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from markdown',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: prdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )

  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "$1" = "exec" ] && [ "$2" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
printf '%s' "$prompt" > "${promptLog}"
target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "version": 1,
  "project": "tmp-ralph-test",
  "storyId": "S-003",
  "title": "Markdown-only epic",
  "description": "Recovered story",
  "branchName": "ralph/sprint-1/epic-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": [],
  "status": "planned",
  "spec": {
    "scope": "Recovered from PRD markdown",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": [],
    "prdRef": "${prdPath}"
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Recovered task",
      "context": "Implement from recovered markdown",
      "scope": ["src/recovered.ts"],
      "acceptance": "Tests pass.",
      "checks": ["npm test"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate', 'S-003', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /Recovered migration placeholder for S-003; story status reset to planned/)
  assert.equal(JSON.parse(fs.readFileSync(storyPath, 'utf8')).tasks[0].title, 'Recovered task')
  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.stories[0].status, 'planned')
  const promptText = fs.readFileSync(promptLog, 'utf8')
  assert.match(promptText, /Legacy migration placeholder detected/)
  assert.match(promptText, /Primary source markdown: scripts\/ralph\/tasks\/prds\/prd-epic-003\.md/)
})

test('ralph-story generate --force deterministically recovers supported legacy PRD markdown without Codex', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-004.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-004/story.json')
  const mockCodexPath = path.join(repoDir, 'mock-codex-should-not-run.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      stories: [
        {
          id: 'S-004',
          title: 'Recover a structured legacy PRD',
          priority: 2,
          effort: 2,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-004/story.json',
          goal: 'Migrate a legacy PRD into story tasks',
          promptContext: 'Preserve the old branch naming and infer checks safely.',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, prdPath),
    `# Legacy PRD

## Scope
Convert the legacy sprint into a real story plan while preserving upgrade safety.

## Out of Scope
- redesigning the framework

## First Slice Expectations
- exact source: scripts/ralph/tasks/prds/prd-epic-004.md
- destination: scripts/ralph/sprints/sprint-1/stories/S-004/story.json
- entrypoint: ./ralph-story.sh generate S-004 --force

## Allowed Supporting Files
- scripts/ralph/lib/codex-exec.sh

## Preserved Invariants
- Keep the migration isolated to placeholder recovery

## Definition of Done
- npm run typecheck succeeds
- npm test succeeds

## User Stories
### Story 1: Rebuild the task container
Create a deterministic task container from markdown and write story.json to scripts/ralph/sprints/sprint-1/stories/S-004/story.json.
Acceptance Criteria
- story.json includes migration metadata
- npm run typecheck succeeds

Proof Obligations
- npm test succeeds

### Story 2: Protect normal generation
Keep standard story generation unchanged for non-placeholder stories in ralph-story.sh and __tests__/ralph-run-state.test.js.
Acceptance Criteria
- regular generation still uses Codex when needed
- npm run lint succeeds
`
  )
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-004',
        title: 'Recover a structured legacy PRD',
        description: 'Migrate a legacy PRD into story tasks',
        branchName: 'ralph/sprint-1/epic-004',
        sprint: 'sprint-1',
        priority: 2,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Migrate a legacy PRD into story tasks',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: prdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )
  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
echo "Codex should not run for deterministic markdown recovery" >&2
exit 91
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate', 'S-004', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /Recovered migration placeholder for S-004 from legacy PRD markdown/)
  assert.match(output, /Recovered migration placeholder for S-004; story status reset to planned/)

  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.branchName, 'ralph/sprint-1/epic-004')
  assert.equal(story.migration.source, 'legacy-prd-markdown')
  assert.equal(story.migration.tasks_recovered, true)
  assert.equal(story.spec.prdRef, prdPath)
  assert.equal(story.tasks.length, 2)
  assert.equal(story.tasks[0].title, 'Rebuild the task container')
  assert.deepEqual(story.tasks[1].depends_on, ['T-01'])
  assert.deepEqual(story.tasks[0].checks, ['npm run typecheck', 'npm test'])
  assert.deepEqual(story.tasks[1].checks, ['npm run lint'])
  assert.deepEqual(story.tasks[1].scope.sort(), ['__tests__/ralph-run-state.test.js', 'ralph-story.sh'])

  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.stories[0].status, 'planned')
})

test('ralph-story generate --force supports alternate legacy markdown headings and scope fallback', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-007.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-007/story.json')
  const mockCodexPath = path.join(repoDir, 'mock-codex-should-not-run-variants.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      stories: [
        {
          id: 'S-007',
          title: 'Recover alternate legacy PRD',
          priority: 2,
          effort: 2,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-007/story.json',
          goal: 'Recover from alternate legacy markdown formatting',
          promptContext: 'Support older heading names and safe scope fallback.',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, prdPath),
    `# Legacy PRD

## In Scope
Recover a placeholder from older markdown structure.

## Initial Slice
- exact source: scripts/ralph/tasks/prds/prd-epic-007.md
- destination: src/migrated-recovery.ts

## Supporting Files
- src/fallback.ts
- docs/legacy-notes.md

## Verification
1. npm test succeeds

## Stories
### 1. Rebuild the placeholder
Use the preserved plan and keep the upgrade path safe.
### Acceptance Criteria:
1. npm test succeeds

### 2. Keep normal framework flow unchanged
Preserve the current framework behavior.
### Proof Obligations:
1. npm run lint succeeds
`
  )
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-007',
        title: 'Recover alternate legacy PRD',
        description: 'Recover from alternate legacy markdown formatting',
        branchName: 'ralph/sprint-1/epic-007',
        sprint: 'sprint-1',
        priority: 2,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from alternate legacy markdown formatting',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: prdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )
  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
echo "Codex should not run for alternate deterministic markdown recovery" >&2
exit 92
`
  )

  run('./scripts/ralph/ralph-story.sh', ['generate', 'S-007', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.migration.source, 'legacy-prd-markdown')
  assert.equal(story.tasks.length, 2)
  assert.equal(story.tasks[0].title, 'Rebuild the placeholder')
  assert.equal(story.tasks[1].title, 'Keep normal framework flow unchanged')
  assert.deepEqual(story.tasks[0].scope, ['src/fallback.ts', 'src/migrated-recovery.ts'])
  assert.deepEqual(story.tasks[1].scope, ['src/fallback.ts', 'src/migrated-recovery.ts'])
  assert.deepEqual(story.tasks[0].checks, ['npm test'])
  assert.deepEqual(story.tasks[1].checks, ['npm run lint'])
  assert.deepEqual(story.spec.supporting_files, ['src/fallback.ts', 'docs/legacy-notes.md'])
})

test('ralph-story health flags unrecovered migration placeholders as not ready for execution', () => {
  const repoDir = initTempRepo()

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      stories: [
        {
          id: 'S-003',
          title: 'Markdown-only epic',
          priority: 3,
          effort: 1,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json',
          goal: 'Recover from markdown',
          promptContext: 'legacy prompt context',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-003',
        title: 'Markdown-only epic',
        description: 'Recover from markdown',
        branchName: 'ralph/sprint-1/epic-003',
        sprint: 'sprint-1',
        priority: 3,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from markdown',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: 'scripts/ralph/tasks/prds/prd-epic-003.md',
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )

  const result = tryRun('./scripts/ralph/ralph-story.sh', ['health', 'S-003'], { cwd: repoDir })
  const combinedOutput = `${result.stdout}${result.stderr}`
  assert.equal(result.status, 1)
  assert.match(combinedOutput, /task-level data was not recovered; regenerate this story before execution/)
})

test('ralph-story generate --force falls back to backlog metadata when placeholder prdRef markdown is missing', () => {
  const repoDir = initTempRepo()
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json')
  const promptLog = path.join(repoDir, 'mock-codex-missing-prd.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-missing-prd.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-003',
          title: 'Missing markdown epic',
          priority: 3,
          effort: 1,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json',
          goal: 'Recover from backlog metadata',
          promptContext: 'use promptContext when markdown is gone',
        },
      ],
    })
  )
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-003',
        title: 'Missing markdown epic',
        description: 'Recover from backlog metadata',
        branchName: 'ralph/sprint-1/epic-003',
        sprint: 'sprint-1',
        priority: 3,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from backlog metadata',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: 'scripts/ralph/tasks/prds/missing-prd.md',
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )

  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "$1" = "exec" ] && [ "$2" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
printf '%s' "$prompt" > "${promptLog}"
target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "version": 1,
  "project": "tmp-ralph-test",
  "storyId": "S-003",
  "title": "Missing markdown epic",
  "description": "Recovered without markdown",
  "branchName": "ralph/sprint-1/epic-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": [],
  "status": "planned",
  "spec": {
    "scope": "Recovered from backlog metadata",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": [],
    "prdRef": "scripts/ralph/tasks/prds/missing-prd.md"
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Recovered task without markdown",
      "context": "Use backlog metadata",
      "scope": ["src/recovered-no-markdown.ts"],
      "acceptance": "Tests pass.",
      "checks": ["npm test"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
`
  )

  run('./scripts/ralph/ralph-story.sh', ['generate', 'S-003', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.migration.source, 'legacy-placeholder-guided-recovery')
  assert.equal(story.migration.tasks_recovered, true)
  assert.equal(story.migration.recoveryMode, 'guided-codex-fallback')
  assert.match(story.migration.recoveryWarnings[1], /PRD markdown was unavailable/)
  assert.match(story.spec.verification.join(' '), /legacy migration fallback recovery used guided generation/i)
  const promptText = fs.readFileSync(promptLog, 'utf8')
  assert.match(promptText, /Primary source markdown unavailable; recover from goal and planning context/)
  assert.match(promptText, /use promptContext when markdown is gone/)
})

test('ralph-story generate --force annotates guided fallback provenance when legacy markdown exists but is too weird to parse', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-008.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-008/story.json')
  const promptLog = path.join(repoDir, 'mock-codex-weird-prd.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-weird-prd.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-008',
          title: 'Weird legacy markdown epic',
          priority: 4,
          effort: 1,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-008/story.json',
          goal: 'Recover from a weird legacy markdown document',
          promptContext: 'The fallback path should stay safe and explicit.',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, prdPath),
    `# Odd Legacy Notes

This file intentionally avoids the supported legacy structure.

### Freeform Notes
Do the thing somehow.
`
  )
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-008',
        title: 'Weird legacy markdown epic',
        description: 'Recover from a weird legacy markdown document',
        branchName: 'ralph/sprint-1/epic-008',
        sprint: 'sprint-1',
        priority: 4,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from a weird legacy markdown document',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: prdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )

  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "$1" = "exec" ] && [ "$2" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
printf '%s' "$prompt" > "${promptLog}"
target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "version": 1,
  "project": "tmp-ralph-test",
  "storyId": "S-008",
  "title": "Weird legacy markdown epic",
  "description": "Recovered through guided fallback",
  "branchName": "ralph/sprint-1/epic-008",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": [],
  "status": "planned",
  "spec": {
    "scope": "Recovered from odd legacy notes",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": []
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Guided fallback task",
      "context": "Use goal and prompt context to rebuild the plan",
      "scope": ["src/weird-fallback.ts"],
      "acceptance": "Tests pass.",
      "checks": ["npm test"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate', 'S-008', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /falling back to guided generation/)
  assert.match(output, /Annotated S-008 with guided migration recovery provenance/)
  assert.match(output, /Recovered migration placeholder for S-008; story status reset to planned/)

  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.branchName, 'ralph/sprint-1/epic-008')
  assert.equal(story.spec.prdRef, prdPath)
  assert.equal(story.migration.source, 'legacy-placeholder-guided-recovery')
  assert.equal(story.migration.tasks_recovered, true)
  assert.equal(story.migration.recoveryMode, 'guided-codex-fallback')
  assert.match(story.migration.recoveryWarnings[1], /could not be deterministically parsed/)
  assert.match(story.spec.verification.join(' '), /review task scope and acceptance checks before execution/i)

  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.stories[0].status, 'planned')
  const promptText = fs.readFileSync(promptLog, 'utf8')
  assert.match(promptText, /Legacy migration placeholder detected/)
  assert.match(promptText, /Primary source markdown: scripts\/ralph\/tasks\/prds\/prd-epic-008\.md/)
})

test('ralph-story generate --force deterministically recovers a rich legacy PRD markdown with three stories', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-009.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-009/story.json')
  const mockCodexPath = path.join(repoDir, 'mock-codex-rich-fallback.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-009',
          title: 'Rich fallback legacy markdown epic',
          priority: 5,
          effort: 3,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-009/story.json',
          goal: 'Recover from a rich legacy PRD markdown file through guided fallback',
          promptContext: 'Preserve branch name and use the PRD markdown as the primary context source.',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, prdPath),
    `# Legacy PRD

## Scope
Recover a legacy story plan without changing the main framework path.

## Out of Scope
- redesign the sprint model

## First Slice Expectations
- exact source: scripts/ralph/tasks/prds/prd-epic-009.md
- destination: scripts/ralph/sprints/sprint-1/stories/S-009/story.json
- entrypoint: ./scripts/ralph/ralph-story.sh generate S-009 --force

## Allowed Supporting Files
- src/migration-helper.ts
- scripts/ralph/ralph-story.sh

## Preserved Invariants
- Keep branch names stable
- Do not alter non-placeholder stories

## Definition of Done
- npm run typecheck succeeds
- npm test succeeds
- npm run lint succeeds

## User Stories
Story A
Description:
Implement guided recovery for the first portion of the migrated plan.
Acceptance Criteria:
1. Branch naming remains stable
2. Tests pass

Story B
Description:
Preserve verification context and fallback provenance.
Acceptance Criteria:
1. Typecheck passes
2. Lint passes

Story C
Description:
Keep the normal framework generation path unchanged.
Acceptance Criteria:
1. Existing flows still work
2. Tests pass
`
  )
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-009',
        title: 'Rich fallback legacy markdown epic',
        description: 'Recover from a rich legacy PRD markdown file through guided fallback',
        branchName: 'ralph/sprint-1/epic-009',
        sprint: 'sprint-1',
        priority: 5,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from a rich legacy PRD markdown file through guided fallback',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: prdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )

  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
echo "Codex should not run for rich deterministic markdown recovery" >&2
exit 93
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate', 'S-009', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /Recovered migration placeholder for S-009 from legacy PRD markdown/)
  assert.match(output, /Recovered migration placeholder for S-009; story status reset to planned/)

  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.branchName, 'ralph/sprint-1/epic-009')
  assert.equal(story.spec.prdRef, prdPath)
  assert.equal(story.migration.source, 'legacy-prd-markdown')
  assert.equal(story.migration.tasks_recovered, true)
  assert.equal(story.tasks.length, 3)
  assert.deepEqual(story.tasks[1].depends_on, ['T-01'])
  assert.deepEqual(story.tasks[2].depends_on, ['T-02'])
  assert.deepEqual(story.tasks.map((task) => task.id), ['T-01', 'T-02', 'T-03'])
  assert.deepEqual(story.tasks.map((task) => task.title), ['Story A', 'Story B', 'Story C'])
  assert.deepEqual(story.tasks[0].checks, ['npm test'])
  assert.deepEqual(story.tasks[1].checks.sort(), ['npm run lint', 'npm run typecheck'])
  assert.deepEqual(story.tasks[2].checks, ['npm test'])

  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.stories[0].status, 'planned')
})

test('ralph-story generate-all --force handles placeholders serially while still generating normal stories', () => {
  const repoDir = initTempRepo()
  const placeholderPrdPath = 'scripts/ralph/tasks/prds/prd-epic-005.md'
  const placeholderStoryPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-005/story.json')
  const regularStoryPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-006/story.json')
  const promptLog = path.join(repoDir, 'mock-codex-generate-all.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-generate-all.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-005',
          title: 'Recover placeholder safely',
          priority: 1,
          effort: 1,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-005/story.json',
          goal: 'Recover placeholder from markdown',
          promptContext: 'Use deterministic recovery first.',
        },
        {
          id: 'S-006',
          title: 'Generate regular story',
          priority: 2,
          effort: 1,
          status: 'planned',
          depends_on: ['S-005'],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-006/story.json',
          goal: 'Generate a normal story from SpecKit artifacts',
          promptContext: 'Regular path should still use Codex.',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, placeholderPrdPath),
    `# Legacy PRD

## Scope
Recover a placeholder story during generate-all.

## Definition of Done
- npm test succeeds

## User Stories
### Story 1: Recover placeholder
Write scripts/ralph/sprints/sprint-1/stories/S-005/story.json from markdown.
Acceptance Criteria
- npm test succeeds
`
  )
  writeFile(
    placeholderStoryPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-005',
        title: 'Recover placeholder safely',
        description: 'Recover placeholder from markdown',
        branchName: 'ralph/sprint-1/epic-005',
        sprint: 'sprint-1',
        priority: 1,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover placeholder from markdown',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: placeholderPrdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-006/.specify/spec.md'), '# Spec\n')
  writeFile(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-006/.specify/tasks.md'), '# Tasks\n')
  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "$1" = "exec" ] && [ "$2" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
printf '%s\n---\n' "$prompt" >> "${promptLog}"
target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "version": 1,
  "project": "tmp-ralph-test",
  "storyId": "S-006",
  "title": "Generate regular story",
  "description": "Generated normally",
  "branchName": "ralph/sprint-1/story-S-006",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": ["S-005"],
  "status": "planned",
  "spec": {
    "scope": "Generated from SpecKit",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": []
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Regular generated task",
      "context": "Use the SpecKit artifacts",
      "scope": ["src/regular.ts"],
      "acceptance": "Tests pass.",
      "checks": ["npm test"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate-all', '--force', '--jobs', '2'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /processing 1 migration placeholder\(s\) serially/)
  assert.match(output, /Recovered migration placeholder for S-005 from legacy PRD markdown/)
  assert.match(output, /=== generate S-006 ===/)

  const promptText = fs.readFileSync(promptLog, 'utf8')
  assert.doesNotMatch(promptText, /Generate story\.json for S-005/)
  assert.match(promptText, /Generate story.json for S-006/)

  const placeholderStory = JSON.parse(fs.readFileSync(placeholderStoryPath, 'utf8'))
  const regularStory = JSON.parse(fs.readFileSync(regularStoryPath, 'utf8'))
  assert.equal(placeholderStory.migration.source, 'legacy-prd-markdown')
  assert.equal(regularStory.tasks[0].title, 'Regular generated task')

  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.stories[0].status, 'planned')
})

test('ralph-story prepare-all --force recovers a placeholder during generate phase and marks sprint ready', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-003.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json')
  const promptLog = path.join(repoDir, 'mock-codex-prepare.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-prepare.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-003',
          title: 'Markdown-only epic',
          priority: 3,
          effort: 1,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-003/story.json',
          goal: 'Recover from markdown',
          promptContext: 'legacy prompt context',
        },
      ],
    })
  )
  writeFile(path.join(repoDir, prdPath), '# PRD\n\nRecover this story from markdown.\n')
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-003',
        title: 'Markdown-only epic',
        description: 'Recover from markdown',
        branchName: 'ralph/sprint-1/epic-003',
        sprint: 'sprint-1',
        priority: 3,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover from markdown',
          out_of_scope: [],
          first_slice: {},
          preserved_invariants: [],
          supporting_files: [],
          verification: ['Migration placeholder only; regenerate story plan before running this story.'],
          prdRef: prdPath,
        },
        migration: {
          source: 'legacy-epic',
          tasks_recovered: false,
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Recover legacy story plan',
            context: 'Legacy migration could not recover task-level data.',
            scope: [],
            acceptance: 'Regenerate before execution.',
            checks: ['test -n "legacy-migration-placeholder"'],
            depends_on: [],
            status: 'pending',
            passes: false,
          },
        ],
        passes: false,
      },
      null,
      2
    )
  )

  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "$1" = "exec" ] && [ "$2" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
printf '%s' "$prompt" > "${promptLog}"
target="$(printf '%s' "$prompt" | sed -n 's|^Write the completed story.json to: ||p' | head -n 1)"
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "version": 1,
  "project": "tmp-ralph-test",
  "storyId": "S-003",
  "title": "Markdown-only epic",
  "description": "Recovered story",
  "branchName": "ralph/sprint-1/epic-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": [],
  "status": "planned",
  "spec": {
    "scope": "Recovered from PRD markdown",
    "out_of_scope": [],
    "first_slice": {},
    "preserved_invariants": [],
    "supporting_files": [],
    "verification": [],
    "prdRef": "${prdPath}"
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Recovered task",
      "context": "Implement from recovered markdown",
      "scope": ["src/recovered.ts"],
      "acceptance": "Tests pass.",
      "checks": ["npm test"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['prepare-all', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /SKIP S-003: migration placeholder \(recover in generate phase\)/)
  assert.match(output, /Recovered migration placeholder for S-003; story status reset to planned/)
  assert.match(output, /Promoted 1 story\/stories to ready\./)
  assert.match(output, /All stories ready — sprint automatically marked ready\./)

  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.status, 'ready')
  assert.equal(stories.stories[0].status, 'ready')
})
