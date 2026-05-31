'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')

const REPO_ROOT = path.resolve(__dirname, '..')
const RUNTIME_ROOT = path.join(REPO_ROOT, 'scripts', 'ralph')

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
  fs.cpSync(RUNTIME_ROOT, frameworkRoot, {
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

test('doctor accepts a repo-local specify wrapper installed under scripts/ralph/bin', () => {
  const repoDir = initTempRepo()
  const localSpecifyPath = path.join(repoDir, 'scripts/ralph/bin/specify')

  writeExecutable(
    localSpecifyPath,
    `#!/bin/bash
set -euo pipefail
if [ "\${1:-}" = "version" ]; then
  echo "specify test stub"
  exit 0
fi
exit 0
`
  )

  const output = run('./scripts/ralph/doctor.sh', [], {
    cwd: repoDir,
    env: {
      CODEX_BIN: path.join(REPO_ROOT, 'scripts/smoke/mock-codex.sh'),
    },
  })

  assert.match(output, /OK: specify available via the repo-local wrapper/)
})

test('doctor reports the repo-local specify wrapper when it resolves via fallback', () => {
  const repoDir = initTempRepo()
  const localSpecifyPath = path.join(repoDir, 'scripts/ralph/bin/specify')
  const fakeGlobalPath = path.join(repoDir, 'fake-global')

  fs.mkdirSync(fakeGlobalPath, { recursive: true })
  writeExecutable(
    path.join(fakeGlobalPath, 'specify'),
    `#!/bin/bash
set -euo pipefail
if [ "\${1:-}" = "version" ]; then
  echo "global specify stub"
  exit 0
fi
exit 0
`
  )

  writeExecutable(
    localSpecifyPath,
    `#!/bin/bash
set -euo pipefail
exec "${path.join(fakeGlobalPath, 'specify')}" "$@"
`
  )

  const output = run('./scripts/ralph/doctor.sh', [], {
    cwd: repoDir,
    env: {
      CODEX_BIN: path.join(REPO_ROOT, 'scripts/smoke/mock-codex.sh'),
      PATH: `${fakeGlobalPath}:${process.env.PATH}`,
    },
  })

  assert.match(output, /OK: specify available via the repo-local wrapper/)
  assert.match(output, /global specify only as a last resort/)
})

test('install auto-configures verify.local.sh for a detected Node/TypeScript repo', () => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-install-node-'))

  writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({
      name: 'node-target',
      private: true,
      scripts: {
        lint: 'eslint .',
        test: 'jest',
        typecheck: 'tsc --noEmit',
      },
    }, null, 2) + '\n'
  )
  writeFile(path.join(repoDir, 'tsconfig.json'), JSON.stringify({ compilerOptions: {} }, null, 2) + '\n')
  writeFile(path.join(repoDir, 'src/index.ts'), 'export const ok = true\n')

  run('bash', [
    path.join(REPO_ROOT, 'install.sh'),
    '--project', repoDir,
    '--skip-git-check',
    '--no-install-speckit',
    '--verify-setup', 'detect-only',
  ])

  const verifyLocal = fs.readFileSync(path.join(repoDir, 'scripts/ralph/verify.local.sh'), 'utf8')
  assert.match(verifyLocal, /printf 'node\\n'/)
  assert.match(verifyLocal, /collect_scope_files/)
  assert.match(verifyLocal, /ralph_verify_run_scoped_typecheck_or_workspace_fallback/)
  assert.match(verifyLocal, /npm test -- --runInBand --runTestsByPath/)
})

test('install scaffolds Nx typecheck targets and generates an Nx-aware verify.local.sh', () => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-install-node-nx-'))

  writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({
      name: 'node-nx-target',
      private: true,
      scripts: {
        lint: 'eslint .',
        test: 'jest',
        typecheck: 'tsc --noEmit',
      },
    }, null, 2) + '\n'
  )
  writeFile(path.join(repoDir, 'tsconfig.json'), JSON.stringify({ compilerOptions: {} }, null, 2) + '\n')
  writeFile(path.join(repoDir, 'nx.json'), JSON.stringify({ plugins: [] }, null, 2) + '\n')
  writeFile(
    path.join(repoDir, 'src/lib/project.json'),
    JSON.stringify({
      name: 'example-lib',
      root: 'src/lib',
      sourceRoot: 'src/lib',
      projectType: 'library',
      targets: {
        lint: {
          executor: 'nx:run-commands',
          options: {
            command: 'eslint .',
          },
        },
      },
    }, null, 2) + '\n'
  )
  writeFile(path.join(repoDir, 'src/lib/index.ts'), 'export const ok = true\n')

  run('bash', [
    path.join(REPO_ROOT, 'install.sh'),
    '--project', repoDir,
    '--skip-git-check',
    '--no-install-speckit',
    '--verify-setup', 'detect-only',
  ])

  const verifyLocal = fs.readFileSync(path.join(repoDir, 'scripts/ralph/verify.local.sh'), 'utf8')
  const projectConfig = JSON.parse(fs.readFileSync(path.join(repoDir, 'src/lib/project.json'), 'utf8'))
  const typecheckConfig = fs.readFileSync(path.join(repoDir, 'src/lib/tsconfig.typecheck.json'), 'utf8')

  assert.match(verifyLocal, /ralph_verify_resolve_nx_affected_typecheck_projects/)
  assert.match(verifyLocal, /npx nx show projects --affected --withTarget=typecheck/)
  assert.equal(projectConfig.targets.typecheck.options.command, 'tsc -p src/lib/tsconfig.typecheck.json --noEmit')
  assert.match(typecheckConfig, /"extends": "\.\.\/\.\.\/tsconfig\.json"/)
  assert.match(typecheckConfig, /"\.\/\*\*\/\*\.ts"/)
})

test('install auto-configures verify.local.sh for a detected Python repo', () => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-install-python-'))

  writeFile(
    path.join(repoDir, 'pyproject.toml'),
    '[project]\nname = "python-target"\nversion = "0.1.0"\n'
  )
  writeFile(path.join(repoDir, 'app.py'), 'print("ok")\n')
  writeFile(path.join(repoDir, 'tests/test_app.py'), 'def test_ok():\n    assert True\n')

  run('bash', [
    path.join(REPO_ROOT, 'install.sh'),
    '--project', repoDir,
    '--skip-git-check',
    '--no-install-speckit',
    '--verify-setup', 'detect-only',
  ])

  const verifyLocal = fs.readFileSync(path.join(repoDir, 'scripts/ralph/verify.local.sh'), 'utf8')
  assert.match(verifyLocal, /printf 'python\\n'/)
  assert.match(verifyLocal, /default_run_base_checks/)
  assert.match(verifyLocal, /default_run_full_suite/)
})

test('install uses Codex fallback to configure verify.local.sh when repo type is unknown', () => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-install-ai-'))
  const promptLog = path.join(repoDir, 'mock-codex-verify-setup.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-verify-setup.sh')

  writeFile(path.join(repoDir, 'README.md'), '# Unknown target\n')
  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "\${1:-}" = "--yolo" ] && [ "\${2:-}" = "exec" ] && [ "\${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
prompt="$(cat)"
printf '%s' "$prompt" > "${promptLog}"
cat <<'EOF'
#!/usr/bin/env bash

ralph_verify_adapter_name() {
  printf 'custom\\n'
}

ralph_verify_run_base_checks() {
  echo "[ralph-verify] running custom base checks"
}

ralph_verify_discover_targeted_tests() {
  return 0
}

ralph_verify_run_targeted_tests() {
  ralph_verify_run_full_suite
}

ralph_verify_run_full_suite() {
  echo "[ralph-verify] running custom full suite"
}
EOF
`
  )

  run('bash', [
    path.join(REPO_ROOT, 'install.sh'),
    '--project', repoDir,
    '--skip-git-check',
    '--no-install-speckit',
    '--verify-setup', 'auto',
  ], {
    env: { CODEX_BIN: mockCodexPath },
  })

  const verifyLocal = fs.readFileSync(path.join(repoDir, 'scripts/ralph/verify.local.sh'), 'utf8')
  assert.match(verifyLocal, /printf 'custom\\n'/)
  assert.match(fs.readFileSync(promptLog, 'utf8'), /Create a Ralph verification adapter for this repository/)
})

test('specify helper joins sanitized path lists with readable separators', () => {
  const repoDir = initTempRepo()
  const output = run(
    'bash',
    [
      '-lc',
      'SCRIPT_DIR="$PWD/scripts/ralph"; source "$SCRIPT_DIR/lib/specify.sh"; printf "%s\\n" "src/app.js" "docs/guide.md" "tests/app.test.js" "scripts/ralph/runtime/log.json" | sanitize_specify_paths | join_with_comma_space',
    ],
    { cwd: repoDir }
  )

  assert.equal(output.trim(), 'src/app.js, tests/app.test.js')
})

test('ralph-story-run completes a simple story in one primary Codex cycle and syncs backlog state', () => {
  const repoDir = initTempRepo()
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json')
  const mockCodexPath = path.join(repoDir, 'mock-story-run-codex.sh')
  const promptLog = path.join(repoDir, 'mock-story-run-prompt.log')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(path.join(repoDir, 'app.txt'), 'Hello World\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      activeStoryId: 'S-001',
      stories: [
        {
          id: 'S-001',
          title: 'Update greeting',
          priority: 1,
          effort: 1,
          status: 'active',
          passes: false,
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
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
        storyId: 'S-001',
        title: 'Update greeting',
        description: 'Change app.txt to say Hello Ralph.',
        branchName: '',
        sprint: 'sprint-1',
        priority: 1,
        depends_on: [],
        status: 'active',
        spec: {
          scope: 'app.txt',
          preserved_invariants: ['Only app.txt should change'],
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Update greeting text',
            context: 'Replace Hello World with Hello Ralph in app.txt.',
            scope: ['app.txt', 'node_modules/example/docs.md', 'scripts/ralph/runtime/story-runs/run-1/log.json', 'dist-docs/index.html'],
            acceptance: 'app.txt contains Hello Ralph.',
            checks: ["grep -q 'Hello Ralph' app.txt"],
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
if [ "\${1:-}" = "--yolo" ] && [ "\${2:-}" = "exec" ] && [ "\${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "\${1:-}" = "exec" ] && [ "\${2:-}" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "\${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
cat >"$PROMPT_LOG"
repo_root="$(git rev-parse --show-toplevel)"
manifest_path="$repo_root/scripts/ralph/sprints/sprint-1/stories/S-001/.story-execution.json"
runtime_manifest_path="$(find "$repo_root/scripts/ralph/runtime/story-runs" -path '*/stories/S-001/.story-execution.json' -type f | head -n 1)"
[ -f "$runtime_manifest_path" ] || { echo "missing runtime execution manifest" >&2; exit 1; }
if grep -q 'node_modules/example/docs.md' "$runtime_manifest_path"; then
  echo "execution manifest leaked vendor scope" >&2
  exit 1
fi
if grep -q 'scripts/ralph/runtime/story-runs/run-1/log.json' "$runtime_manifest_path"; then
  echo "execution manifest leaked runtime scope" >&2
  exit 1
fi
if grep -q 'dist-docs/index.html' "$runtime_manifest_path"; then
  echo "execution manifest leaked generated docs scope" >&2
  exit 1
fi
runtime_bundle_dir="$(find "$repo_root/scripts/ralph/runtime/story-runs" -path '*/stories/S-001/.exec' -type d | head -n 1)"
[ -d "$runtime_bundle_dir" ] || { echo "missing execution bundle" >&2; exit 1; }
[ -f "$runtime_bundle_dir/context.json" ] || { echo "missing context.json" >&2; exit 1; }
[ -f "$runtime_bundle_dir/commands.json" ] || { echo "missing commands.json" >&2; exit 1; }
[ -f "$runtime_bundle_dir/files.json" ] || { echo "missing files.json" >&2; exit 1; }
[ -f "$runtime_bundle_dir/dependencies.json" ] || { echo "missing dependencies.json" >&2; exit 1; }
[ -f "$runtime_bundle_dir/checks.json" ] || { echo "missing checks.json" >&2; exit 1; }
[ -f "$runtime_bundle_dir/summary.md" ] || { echo "missing summary.md" >&2; exit 1; }
printf 'Hello Ralph\\n' > "$repo_root/app.txt"
story_file="$MOCK_STORY_FILE"
tmp="$(mktemp)"
jq '.tasks[0].handoff = {
  "changed_files": ["app.txt", "scripts/ralph/runtime/story-runs/run-1/log.json", "dist-docs/index.html"],
  "artifacts": ["greeting"],
  "checks_passed": ["grep -q '\\''Hello Ralph'\\'' app.txt"],
  "remaining_risks": []
}' "$story_file" > "$tmp"
mv "$tmp" "$story_file"
git -C "$repo_root" add app.txt "$story_file"
git -C "$repo_root" commit -m "feat: story cycle update" >/dev/null 2>&1 || true
`
  )

  const output = run('./scripts/ralph/ralph-story-run.sh', ['--story', storyPath], {
    cwd: repoDir,
    env: {
      CODEX_BIN: mockCodexPath,
      MOCK_STORY_FILE: storyPath,
      PROMPT_LOG: promptLog,
    },
  })

  assert.match(output, /Story S-001 COMPLETE/)

  const storyData = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(storyData.status, 'done')
  assert.equal(storyData.passes, true)
  assert.equal(storyData.tasks[0].status, 'done')
  assert.equal(storyData.tasks[0].passes, true)
  assert.deepEqual(storyData.tasks[0].handoff.changed_files, ['app.txt'])
  assert.deepEqual(storyData.story_handoff.completed_tasks, ['T-01'])
  assert.deepEqual(storyData.story_handoff.files_touched, ['app.txt'])
  const promptText = fs.readFileSync(promptLog, 'utf8')
  assert.match(promptText, /execution-baseline\.md/)
  assert.match(promptText, /\.exec\/summary\.md/)
  assert.match(promptText, /The framework will persist pass\/fail bookkeeping/)

  const backlog = JSON.parse(
    fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8')
  )
  assert.equal(backlog.activeStoryId, null)
  assert.equal(backlog.stories[0].status, 'done')
  assert.equal(backlog.stories[0].passes, true)
})

test('ralph-story-run reconciles successful work even when Codex exits non-zero after editing', () => {
  const repoDir = initTempRepo()
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json')
  const mockCodexPath = path.join(repoDir, 'mock-story-run-timeout-codex.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(path.join(repoDir, 'app.txt'), 'Hello World\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      activeStoryId: 'S-001',
      stories: [
        {
          id: 'S-001',
          title: 'Update greeting after non-zero Codex exit',
          priority: 1,
          effort: 1,
          status: 'active',
          passes: false,
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
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
        storyId: 'S-001',
        title: 'Update greeting after non-zero Codex exit',
        description: 'Change app.txt to say Hello Ralph even if Codex exits non-zero.',
        branchName: '',
        sprint: 'sprint-1',
        priority: 1,
        depends_on: [],
        status: 'active',
        spec: {
          scope: 'app.txt',
          preserved_invariants: ['Only app.txt should change'],
        },
        tasks: [
          {
            id: 'T-01',
            title: 'Update greeting text',
            context: 'Replace Hello World with Hello Ralph in app.txt.',
            scope: ['app.txt'],
            acceptance: 'app.txt contains Hello Ralph.',
            checks: ["grep -q 'Hello Ralph' app.txt"],
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
if [ "\${1:-}" = "--yolo" ] && [ "\${2:-}" = "exec" ] && [ "\${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
if [ "\${1:-}" = "exec" ] && [ "\${2:-}" = "--dangerously-bypass-approvals-and-sandbox" ] && [ "\${3:-}" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
cat >/dev/null
repo_root="$(git rev-parse --show-toplevel)"
printf 'Hello Ralph\\n' > "$repo_root/app.txt"
exit 124
`
  )

  const output = run('./scripts/ralph/ralph-story-run.sh', ['--story', storyPath], {
    cwd: repoDir,
    env: {
      CODEX_BIN: mockCodexPath,
      RALPH_CODEX_TIMEOUT_SEC: '1',
    },
  })

  assert.match(output, /WARN: Story cycle timed out/)
  assert.match(output, /Story S-001 COMPLETE/)

  const storyData = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(storyData.status, 'done')
  assert.equal(storyData.passes, true)
  assert.equal(storyData.tasks[0].status, 'done')
  assert.equal(storyData.tasks[0].passes, true)
  assert.deepEqual(storyData.story_handoff.files_touched, ['app.txt'])

  const backlog = JSON.parse(
    fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8')
  )
  assert.equal(backlog.activeStoryId, null)
  assert.equal(backlog.stories[0].status, 'done')
  assert.equal(backlog.stories[0].passes, true)
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

test('ralph-story generate --force can bridge valid markdown-only recovery through temporary prd.json into three tasks', () => {
  const repoDir = initTempRepo()
  const prdPath = 'scripts/ralph/tasks/prds/prd-epic-010.md'
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-010/story.json')
  const promptLog = path.join(repoDir, 'mock-codex-prd-bridge.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-prd-bridge.sh')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-010',
          title: 'Bridge markdown recovery epic',
          priority: 6,
          effort: 3,
          status: 'blocked',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-010/story.json',
          goal: 'Recover a valid markdown-only legacy PRD by bridging through temporary prd.json',
          promptContext: 'Prefer prd.json bridge recovery before direct guided story generation.',
        },
      ],
    })
  )
  writeFile(
    path.join(repoDir, prdPath),
    `# Legacy PRD

## Scope
Recover a valid markdown-only legacy PRD through a temporary prd.json bridge.

## Out of Scope
- rewriting the main framework flow

## First Slice Expectations
- exact source: scripts/ralph/tasks/prds/prd-epic-010.md
- destination: scripts/ralph/sprints/sprint-1/stories/S-010/story.json
- entrypoint: ./scripts/ralph/ralph-story.sh generate S-010 --force

## Allowed Supporting Files
- src/bridge-helper.ts
- scripts/ralph/ralph-story.sh

## Preserved Invariants
- Preserve branch naming
- Preserve placeholder-only recovery behavior

## Definition of Done
- npm run typecheck succeeds
- npm test succeeds

## User Stories
#### Story Alpha
**Description:** Rebuild the first portion of the plan from markdown-only legacy content.
**Acceptance Criteria:**
- Typecheck passes
- Tests pass

#### Story Beta
**Description:** Preserve verification context and scope decisions.
**Acceptance Criteria:**
- Lint passes

#### Story Gamma
**Description:** Keep the normal framework path unchanged.
**Acceptance Criteria:**
- Tests pass
`
  )
  writeFile(
    storyPath,
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        storyId: 'S-010',
        title: 'Bridge markdown recovery epic',
        description: 'Recover a valid markdown-only legacy PRD by bridging through temporary prd.json',
        branchName: 'ralph/sprint-1/epic-010',
        sprint: 'sprint-1',
        priority: 6,
        depends_on: [],
        status: 'blocked',
        spec: {
          scope: 'Recover a valid markdown-only legacy PRD by bridging through temporary prd.json',
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
target="$(printf '%s' "$prompt" | sed -n 's|^Write the temporary prd.json to: ||p' | head -n 1)"
if [ -z "$target" ]; then
  echo "Unexpected prompt: no temporary prd.json target" >&2
  exit 94
fi
mkdir -p "$(dirname "$target")"
cat > "$target" <<'JSON'
{
  "project": "tmp-ralph-test",
  "branchName": "ralph/sprint-1/epic-010",
  "description": "Recovered through temporary prd.json bridge",
  "userStories": [
    {
      "id": "US-001",
      "title": "Bridge task one",
      "description": "Recover the first portion of the plan",
      "acceptanceCriteria": ["Typecheck passes", "Tests pass"],
      "scopePaths": ["src/bridge-helper.ts"],
      "priority": 1,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Bridge task two",
      "description": "Preserve verification context",
      "acceptanceCriteria": ["Lint passes", "Typecheck passes"],
      "scopePaths": ["scripts/ralph/ralph-story.sh"],
      "priority": 2,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Bridge task three",
      "description": "Keep the normal framework path unchanged",
      "acceptanceCriteria": ["Tests pass", "Typecheck passes"],
      "scopePaths": ["__tests__/ralph-run-state.test.js"],
      "priority": 3,
      "passes": false,
      "notes": ""
    }
  ]
}
JSON
`
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate', 'S-010', '--force'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /trying temporary prd\.json bridge/)
  assert.match(output, /Recovered migration placeholder for S-010 through temporary prd\.json bridge/)
  assert.match(output, /Annotated S-010 with temporary prd\.json bridge provenance/)

  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.branchName, 'ralph/sprint-1/epic-010')
  assert.equal(story.spec.prdRef, prdPath)
  assert.equal(story.migration.source, 'legacy-prd-json-bridge')
  assert.equal(story.migration.tasks_recovered, true)
  assert.equal(story.migration.recoveryMode, 'guided-prd-json-bridge')
  assert.equal(story.tasks.length, 3)
  assert.deepEqual(story.tasks.map((task) => task.id), ['T-01', 'T-02', 'T-03'])
  assert.deepEqual(story.tasks[1].depends_on, ['T-01'])
  assert.deepEqual(story.tasks[2].depends_on, ['T-02'])
  assert.deepEqual(story.tasks[0].checks.sort(), ['npm run typecheck', 'npm test'])
  assert.deepEqual(story.tasks[1].checks.sort(), ['npm run lint', 'npm run typecheck'])
  assert.match(story.spec.verification.join(' '), /temporary prd\.json bridge/i)

  const stories = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'), 'utf8'))
  assert.equal(stories.stories[0].status, 'planned')
  const promptText = fs.readFileSync(promptLog, 'utf8')
  assert.match(promptText, /Use the PRD skill to normalize the markdown structure/)
  assert.match(promptText, /use the Ralph PRD converter rules to produce a valid temporary prd\.json/i)
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

test('ralph-story specify skips when prep fingerprint matches existing artifacts', () => {
  const repoDir = initTempRepo()
  const promptLog = path.join(repoDir, 'mock-codex-specify.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-specify.sh')
  const storyDir = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-001')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({
      name: 'tmp-ralph-test',
      private: true,
      scripts: {
        typecheck: 'echo typecheck',
        lint: 'echo lint',
        test: 'echo test',
        build: 'echo build',
      },
    }, null, 2)
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-001',
          title: 'Prep Story',
          priority: 1,
          effort: 1,
          status: 'planned',
          sprint: 'sprint-1',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
          goal: 'Create lib/example.ts and test it.',
          promptContext: 'Touch lib/example.ts and __tests__/example.test.ts.',
        },
      ],
    })
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
printf '%s\\n---\\n' "$prompt" >> "${promptLog}"
while IFS= read -r target; do
  [ -n "$target" ] || continue
  mkdir -p "$(dirname "$target")"
  case "$target" in
    *.md) printf '# artifact\\n\\ncontent\\n' > "$target" ;;
  esac
done < <(printf '%s' "$prompt" | sed -n 's|^Write output to: ||p')
`
  )

  const first = run('./scripts/ralph/ralph-story.sh', ['specify', 'S-001', '--no-generate'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })
  assert.match(first, /SpecKit artifacts written:/)
  assert.ok(fs.existsSync(path.join(storyDir, '.specify', 'spec.md')))
  assert.ok(fs.existsSync(path.join(storyDir, '.prep-context.json')))
  assert.ok(fs.existsSync(path.join(storyDir, '.prep', 'context.json')))
  assert.ok(fs.existsSync(path.join(storyDir, '.prep', 'commands.json')))
  assert.ok(fs.existsSync(path.join(storyDir, '.prep', 'dependencies.json')))
  assert.ok(fs.existsSync(path.join(storyDir, '.prep', 'schema.json')))

  const second = run('./scripts/ralph/ralph-story.sh', ['specify', 'S-001', '--no-generate'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })
  assert.match(second, /SpecKit artifacts up to date for S-001 \(fingerprint match\)/)

  const promptInvocations = fs.readFileSync(promptLog, 'utf8').split('\n---\n').filter(Boolean)
  assert.equal(promptInvocations.length, 1)
  const prepContext = JSON.parse(fs.readFileSync(path.join(storyDir, '.prep-context.json'), 'utf8'))
  assert.ok(prepContext.fingerprint)
  const prepBundleContext = JSON.parse(fs.readFileSync(path.join(storyDir, '.prep', 'context.json'), 'utf8'))
  assert.equal(prepBundleContext.storyId, 'S-001')
  assert.deepEqual(prepBundleContext.likelyFiles, ['lib/example.ts', '__tests__/example.test.ts'])
})

test('ralph-story generate skips when story.json matches recorded prep fingerprint', () => {
  const repoDir = initTempRepo()
  const promptLog = path.join(repoDir, 'mock-codex-generate.log')
  const mockCodexPath = path.join(repoDir, 'mock-codex-generate.sh')
  const storyDir = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-001')
  const prepContextPath = path.join(storyDir, '.prep-context.json')
  const storyPath = path.join(storyDir, 'story.json')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({
      name: 'tmp-ralph-test',
      private: true,
      scripts: {
        typecheck: 'echo typecheck',
        lint: 'echo lint',
        test: 'echo test',
        build: 'echo build',
      },
    }, null, 2)
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-001',
          title: 'Prep Story',
          priority: 1,
          effort: 1,
          status: 'planned',
          sprint: 'sprint-1',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
          goal: 'Create lib/example.ts and test it.',
          promptContext: 'Touch lib/example.ts and __tests__/example.test.ts.',
        },
      ],
    })
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
printf '%s\\n---\\n' "$prompt" >> "${promptLog}"
while IFS= read -r target; do
  [ -n "$target" ] || continue
  mkdir -p "$(dirname "$target")"
  case "$target" in
    *.md) printf '# artifact\\n\\ncontent\\n' > "$target" ;;
    */story.json)
      cat > "$target" <<'JSON'
{
  "storyId": "S-001",
  "title": "Prep Story",
  "status": "planned",
  "branchName": "ralph/sprint-1/story-S-001",
  "spec": {
    "asA": "developer",
    "iWant": "a prepared story",
    "soThat": "prep can skip deterministically",
    "scope": "Create lib/example.ts and test it.",
    "verification": ["npm test"]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create example file",
      "context": "Implement example",
      "scope": ["lib/example.ts"],
      "acceptance": "Example file exists.",
      "checks": ["test -f lib/example.ts"],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
JSON
      ;;
  esac
done < <(printf '%s' "$prompt" | sed -n 's|^Write output to: ||p')
`
  )

  run('./scripts/ralph/ralph-story.sh', ['specify', 'S-001', '--no-generate'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })
  const prepContext = JSON.parse(fs.readFileSync(prepContextPath, 'utf8'))
  prepContext.generation = {
    generatedFromFingerprint: prepContext.fingerprint,
    sourceType: 'story.json',
    storyPath: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
    generatedAt: '2026-05-22T00:00:30Z',
  }
  writeFile(prepContextPath, JSON.stringify(prepContext, null, 2))
  writeFile(
    storyPath,
    JSON.stringify({
      storyId: 'S-001',
      title: 'Prep Story',
      status: 'planned',
      branchName: 'ralph/sprint-1/story-S-001',
      spec: {
        asA: 'developer',
        iWant: 'a prepared story',
        soThat: 'prep can skip deterministically',
        scope: 'Create lib/example.ts and test it.',
        verification: ['npm test'],
      },
      tasks: [
        {
          id: 'T-01',
          title: 'Create example file',
          context: 'Implement example',
          scope: ['lib/example.ts'],
          acceptance: 'Example file exists.',
          checks: ['test -f lib/example.ts'],
          depends_on: [],
          status: 'pending',
          passes: false,
        },
      ],
      passes: false,
    }, null, 2)
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['generate', 'S-001'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /story\.json up to date for S-001 \(prep fingerprint match\)/)
  const promptInvocations = fs.readFileSync(promptLog, 'utf8').split('\n---\n').filter(Boolean)
  assert.equal(promptInvocations.length, 1)
})

test('ralph-status reports latest prep journal for the active sprint', () => {
  const repoDir = initTempRepo()
  const prepRunDir = path.join(repoDir, 'scripts/ralph/runtime/prep-runs/20260522T000000Z-sprint-1-prepare-all')
  const prepSummaryPath = path.join(prepRunDir, 'prepare-run.json')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-001',
          title: 'Prep Story',
          priority: 1,
          effort: 1,
          status: 'planned',
          sprint: 'sprint-1',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
          goal: 'Create lib/example.ts and test it.',
          promptContext: 'Touch lib/example.ts and __tests__/example.test.ts.',
        },
      ],
    })
  )
  writeFile(
    prepSummaryPath,
    JSON.stringify({
      version: 1,
      mode: 'prepare-all',
      sprint: 'sprint-1',
      started_at: '2026-05-22T00:00:00Z',
      finished_at: '2026-05-22T00:01:00Z',
      status: 'passed',
      metrics: {
        stage_count: 2,
        passed_stages: 1,
        skipped_stages: 1,
        failed_stages: 0,
        running_stages: 0,
        total_duration_ms: 1200,
      },
      stories: {
        'S-001': {
          specify: { status: 'passed', detail: 'SpecKit artifacts created', artifacts: [], duration_ms: 700, updated_at: '2026-05-22T00:00:30Z' },
          generate: { status: 'skipped', detail: 'story.json already exists', artifacts: [], duration_ms: 0, updated_at: '2026-05-22T00:00:50Z' },
        },
      },
    }, null, 2)
  )

  const output = run('./scripts/ralph/ralph-status.sh', [], { cwd: repoDir })
  assert.match(output, /Prep: passed \(prepare-all, stories=1, passed-stages=1, failed-stages=0, skipped-stages=1, duration-ms=1200\)/)
  assert.match(output, /Prep updated: 2026-05-22T00:01:00Z/)
  assert.match(output, /Prep story S-001: generate=skipped, specify=passed/)
  assert.match(output, new RegExp(prepSummaryPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
})

test('ralph-status --prep-details shows prep stage detail lines', () => {
  const repoDir = initTempRepo()
  const prepRunDir = path.join(repoDir, 'scripts/ralph/runtime/prep-runs/20260522T000000Z-sprint-1-prepare-all')
  const prepSummaryPath = path.join(prepRunDir, 'prepare-run.json')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-001',
          title: 'Prep Story',
          priority: 1,
          effort: 1,
          status: 'planned',
          sprint: 'sprint-1',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
          goal: 'Create lib/example.ts and test it.',
          promptContext: 'Touch lib/example.ts and __tests__/example.test.ts.',
        },
      ],
    })
  )
  writeFile(
    prepSummaryPath,
    JSON.stringify({
      version: 1,
      mode: 'prepare-all',
      sprint: 'sprint-1',
      started_at: '2026-05-22T00:00:00Z',
      finished_at: '2026-05-22T00:01:00Z',
      status: 'passed',
      metrics: {
        stage_count: 2,
        passed_stages: 1,
        skipped_stages: 1,
        failed_stages: 0,
        running_stages: 0,
        total_duration_ms: 1200,
      },
      stories: {
        'S-001': {
          specify: { status: 'passed', detail: 'SpecKit artifacts created', artifacts: [], duration_ms: 700, updated_at: '2026-05-22T00:00:30Z' },
          generate: { status: 'skipped', detail: 'story.json up to date (prep fingerprint match)', artifacts: [], duration_ms: 0, updated_at: '2026-05-22T00:00:50Z' },
        },
      },
    }, null, 2)
  )

  const output = run('./scripts/ralph/ralph-status.sh', ['--prep-details'], { cwd: repoDir })
  assert.match(output, /Prep detail S-001 generate: skipped - story\.json up to date \(prep fingerprint match\) \(duration-ms=0, updated=2026-05-22T00:00:50Z\)/)
  assert.match(output, /Prep detail S-001 specify: passed - SpecKit artifacts created \(duration-ms=700, updated=2026-05-22T00:00:30Z\)/)
  assert.match(output, new RegExp(prepSummaryPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
})

test('ralph-story prep-status shows latest prep journal summary and story filter', () => {
  const repoDir = initTempRepo()
  const prepRunDir = path.join(repoDir, 'scripts/ralph/runtime/prep-runs/20260522T000000Z-sprint-1-prepare-all')
  const prepSummaryPath = path.join(prepRunDir, 'prepare-run.json')

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-1\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [
        {
          id: 'S-001',
          title: 'Prep Story',
          priority: 1,
          effort: 1,
          status: 'planned',
          sprint: 'sprint-1',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
          goal: 'Create lib/example.ts and test it.',
          promptContext: 'Touch lib/example.ts and __tests__/example.test.ts.',
        },
        {
          id: 'S-002',
          title: 'Second Story',
          priority: 2,
          effort: 2,
          status: 'planned',
          sprint: 'sprint-1',
          depends_on: [],
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-002/story.json',
          goal: 'Update another file.',
          promptContext: 'Touch lib/second.ts.',
        },
      ],
    })
  )
  writeFile(
    prepSummaryPath,
    JSON.stringify({
      version: 1,
      mode: 'prepare-all',
      sprint: 'sprint-1',
      started_at: '2026-05-22T00:00:00Z',
      finished_at: '2026-05-22T00:01:00Z',
      status: 'passed',
      metrics: {
        stage_count: 4,
        passed_stages: 2,
        skipped_stages: 1,
        failed_stages: 1,
        running_stages: 0,
        total_duration_ms: 2200,
      },
      stories: {
        'S-001': {
          specify: { status: 'passed', detail: 'SpecKit artifacts created', artifacts: [], duration_ms: 700, updated_at: '2026-05-22T00:00:30Z' },
          generate: { status: 'skipped', detail: 'story.json up to date (prep fingerprint match)', artifacts: [], duration_ms: 0, updated_at: '2026-05-22T00:00:50Z' },
        },
        'S-002': {
          specify: { status: 'failed', detail: 'SpecKit did not produce all required artifacts', artifacts: [], duration_ms: 1500, updated_at: '2026-05-22T00:00:55Z' },
          generate: { status: 'passed', detail: 'Generated 3 tasks', artifacts: [], duration_ms: 0, updated_at: '2026-05-22T00:00:58Z' },
        },
      },
    }, null, 2)
  )

  const output = run('./scripts/ralph/ralph-story.sh', ['prep-status', '--story', 'S-002', '--details'], { cwd: repoDir })
  assert.match(output, /Prep sprint: sprint-1/)
  assert.match(output, /Prep mode: prepare-all/)
  assert.match(output, /Prep metrics: passed=2 failed=1 skipped=1 running=0 duration-ms=2200/)
  assert.match(output, /Prep story S-002: generate=passed, specify=failed/)
  assert.doesNotMatch(output, /Prep story S-001:/)
  assert.match(output, /Prep detail S-002 specify: failed - SpecKit did not produce all required artifacts \(duration-ms=1500, updated=2026-05-22T00:00:55Z\)/)
  assert.match(output, new RegExp(prepSummaryPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
})

test('ralph loop refreshes sprint-run manifest during live story execution', () => {
  const repoDir = initTempRepo()
  const mockCodexPath = path.join(repoDir, 'mock-codex.sh')
  const storyPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json')
  const storiesPath = path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json')

  writeExecutable(
    mockCodexPath,
    `#!/bin/bash
set -euo pipefail
if [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then
  echo "Run Codex non-interactively"
  exit 0
fi
echo "mock codex"
`
  )

  run('./scripts/ralph/ralph-sprint.sh', ['create', 'sprint-1'], { cwd: repoDir })

  writeFile(
    storiesPath,
    storiesJson('sprint-1', {
      status: 'active',
      stories: [
        {
          id: 'S-001',
          title: 'Live manifest story',
          priority: 1,
          effort: 1,
          status: 'ready',
          sprint: 'sprint-1',
          depends_on: [],
          passes: false,
          story_path: 'scripts/ralph/sprints/sprint-1/stories/S-001/story.json',
          goal: 'Update the manifest during story execution.',
          promptContext: 'Use a mocked story runner to complete one story.',
        },
      ],
    })
  )

  writeFile(
    storyPath,
    JSON.stringify({
      version: 1,
      project: 'tmp-ralph-test',
      storyId: 'S-001',
      title: 'Live manifest story',
      description: 'Update the manifest during story execution.',
      branchName: 'ralph/sprint-1/story-S-001',
      sprint: 'sprint-1',
      priority: 1,
      depends_on: [],
      status: 'planned',
      spec: {
        scope: 'Update one file and verify the manifest is live.',
        out_of_scope: [],
        first_slice: {},
        preserved_invariants: [],
        supporting_files: [],
        verification: ['echo ok'],
      },
      tasks: [
        {
          id: 'T-01',
          title: 'Mock complete the story',
          context: 'A mocked story runner will mark this story done.',
          scope: ['README.md'],
          acceptance: 'The story is marked done.',
          checks: ['echo ok'],
          depends_on: [],
          status: 'pending',
          passes: false,
        },
      ],
      passes: false,
    }, null, 2)
  )

  writeExecutable(
    path.join(repoDir, 'scripts/ralph/ralph-story-run.sh'),
    `#!/bin/bash
set -euo pipefail
repo="$(git rev-parse --show-toplevel)"
manifest="$RALPH_SPRINT_RUN_DIR/sprint-run.json"
stories="$repo/scripts/ralph/sprints/sprint-1/stories.json"
story="$repo/scripts/ralph/sprints/sprint-1/stories/S-001/story.json"

jq -e '.phase == "running-story"' "$manifest" >/dev/null
jq -e '.story_count == 1' "$manifest" >/dev/null
jq -e '.total_story_count == 1' "$manifest" >/dev/null
jq -e '.done_count == 0' "$manifest" >/dev/null
jq -e '.remaining_stories == 1' "$manifest" >/dev/null
jq -e '.active_story_id == "S-001"' "$manifest" >/dev/null
jq -e '.active_story_title == "Live manifest story"' "$manifest" >/dev/null

tmp="$(mktemp)"
jq '(.tasks[] | .status = "done" | .passes = true) | .status = "done" | .passes = true' "$story" > "$tmp"
mv "$tmp" "$story"

tmp="$(mktemp)"
jq '(.stories[] | select(.id == "S-001") | .status) = "done" |
    (.stories[] | select(.id == "S-001") | .passes) = true |
    .activeStoryId = null' "$stories" > "$tmp"
mv "$tmp" "$stories"

git checkout ralph/sprint/sprint-1 >/dev/null 2>&1 || true
`
  )

  run('git', ['add', '.'], { cwd: repoDir })
  run('git', ['commit', '-m', 'setup live manifest test'], { cwd: repoDir })

  const output = run('./scripts/ralph/ralph.sh', ['--max-stories', '1'], {
    cwd: repoDir,
    env: { CODEX_BIN: mockCodexPath },
  })

  assert.match(output, /DONE: S-001 complete/)
  const runDirs = fs.readdirSync(path.join(repoDir, 'scripts/ralph/runtime/sprint-runs'))
  assert.equal(runDirs.length, 1)
  const manifestPath = path.join(repoDir, 'scripts/ralph/runtime/sprint-runs', runDirs[0], 'sprint-run.json')
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  assert.equal(manifest.phase, 'completed')
  assert.equal(manifest.story_count, 1)
  assert.equal(manifest.total_story_count, 1)
  assert.equal(manifest.done_count, 1)
  assert.equal(manifest.failed_count, 0)
  assert.equal(manifest.remaining_stories, 0)
  assert.equal(manifest.active_story_id, null)
})
