const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')

const REPO_ROOT = path.resolve(__dirname, '..')
const RUNTIME_ROOT = path.join(REPO_ROOT, 'scripts', 'ralph')

function run(cmd, args, { cwd, env, stdio = 'pipe' } = {}) {
  return execFileSync(cmd, args, {
    cwd,
    env: {
      ...process.env,
      ...env,
    },
    encoding: 'utf8',
    stdio,
  })
}

function writeFile(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true })
  fs.writeFileSync(targetPath, contents)
}

function chmodScripts(rootDir) {
  const stack = [rootDir]
  while (stack.length > 0) {
    const current = stack.pop()
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name)
      if (entry.isDirectory()) {
        stack.push(fullPath)
        continue
      }
      if (entry.name.endsWith('.sh')) {
        fs.chmodSync(fullPath, 0o755)
      }
    }
  }
}

function initTempRepo() {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-verify-'))
  const frameworkRoot = path.join(repoDir, 'scripts', 'ralph')
  fs.mkdirSync(path.dirname(frameworkRoot), { recursive: true })
  fs.cpSync(RUNTIME_ROOT, frameworkRoot, {
    recursive: true,
    filter: (sourcePath) => !sourcePath.includes(`${path.sep}.git${path.sep}`) && !sourcePath.endsWith(`${path.sep}.git`),
  })
  chmodScripts(frameworkRoot)

  writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify(
      {
        name: 'ralph-verify-regression',
        private: true,
        scripts: {
          typecheck: 'node -e "process.exit(0)"',
          lint: 'node -e "process.exit(0)"',
          test: 'node scripts/run-tests.mjs',
        },
      },
      null,
      2
    ) + '\n'
  )

  writeFile(
    path.join(repoDir, 'scripts/run-tests.mjs'),
    `import { writeFileSync } from "node:fs";
const args = process.argv.slice(2);
const pathFlagIndex = args.indexOf("--runTestsByPath");
const testPaths = pathFlagIndex === -1
  ? ["tests/hello.test.mjs"]
  : args.slice(pathFlagIndex + 1).filter((arg) => !arg.startsWith("--"));
writeFileSync(".selected-tests.txt", testPaths.join("\\n") + "\\n");
`
  )

  writeFile(
    path.join(repoDir, 'src/index.ts'),
    'const greeting = "Hello World";\nconsole.log(greeting);\n'
  )
  writeFile(
    path.join(repoDir, 'tests/hello.test.mjs'),
    `import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("source contains baseline greeting", () => {
  const source = readFileSync("src/index.ts", "utf8");
  assert.match(source, /Hello World/, "Expected baseline greeting in src/index.ts");
});
`
  )

  run('git', ['init', '-b', 'main'], { cwd: repoDir })
  run('git', ['config', 'user.name', 'Ralph Test'], { cwd: repoDir })
  run('git', ['config', 'user.email', 'ralph-test@example.com'], { cwd: repoDir })
  run('git', ['add', '.'], { cwd: repoDir })
  run('git', ['commit', '-m', 'init'], { cwd: repoDir })
  return repoDir
}

test('ralph-verify targeted mode runs related test for a source-only change', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'src/index.ts'),
    'const greeting = "Hello PRD Ralph";\nconsole.log(greeting);\n'
  )

  const result = spawnSync('./scripts/ralph/ralph-verify.sh', ['--targeted'], {
    cwd: repoDir,
    encoding: 'utf8',
    stdio: 'pipe',
  })

  assert.equal(result.status, 0, 'expected targeted verification to complete successfully in the focused regression harness')
  assert.match(result.stdout, /\[ralph-verify\] running targeted tests:/)
  assert.match(result.stdout, /tests\/hello\.test\.mjs/)
  assert.equal(
    fs.readFileSync(path.join(repoDir, '.selected-tests.txt'), 'utf8').trim(),
    'tests/hello.test.mjs'
  )
})

test('ralph-verify targeted mode falls back to repo regression script when lint and typecheck are absent', () => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-verify-regression-only-'))
  const frameworkRoot = path.join(repoDir, 'scripts', 'ralph')
  fs.mkdirSync(path.dirname(frameworkRoot), { recursive: true })
  fs.cpSync(RUNTIME_ROOT, frameworkRoot, {
    recursive: true,
    filter: (sourcePath) => !sourcePath.includes(`${path.sep}.git${path.sep}`) && !sourcePath.endsWith(`${path.sep}.git`),
  })
  chmodScripts(frameworkRoot)

  writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify(
      {
        name: 'ralph-verify-regression-only',
        private: true,
        scripts: {
          'test:regression': 'node scripts/run-regression.mjs',
        },
      },
      null,
      2
    ) + '\n'
  )

  writeFile(
    path.join(repoDir, 'scripts/run-regression.mjs'),
    `import { writeFileSync } from "node:fs";
writeFileSync(".regression-ran.txt", "ok\\n");
`
  )

  writeFile(path.join(repoDir, 'README.md'), '# temp repo\n')

  run('git', ['init', '-b', 'main'], { cwd: repoDir })
  run('git', ['config', 'user.name', 'Ralph Test'], { cwd: repoDir })
  run('git', ['config', 'user.email', 'ralph-test@example.com'], { cwd: repoDir })
  run('git', ['add', '.'], { cwd: repoDir })
  run('git', ['commit', '-m', 'init'], { cwd: repoDir })

  writeFile(path.join(repoDir, 'README.md'), '# updated temp repo\n')

  const result = spawnSync('./scripts/ralph/ralph-verify.sh', ['--targeted'], {
    cwd: repoDir,
    encoding: 'utf8',
    stdio: 'pipe',
  })

  assert.equal(result.status, 0, 'expected targeted verification to succeed via repo regression script')
  assert.match(result.stdout, /skipping typecheck/)
  assert.match(result.stdout, /skipping lint/)
  assert.match(result.stdout, /relying on test:regression for required verification/)
  assert.match(result.stdout, /no targeted test files inferred from scoped files; falling back to full test suite/)
  assert.equal(fs.readFileSync(path.join(repoDir, '.regression-ran.txt'), 'utf8').trim(), 'ok')
})

test('ralph-verify sources verify.local.sh when a repo defines a custom adapter', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/verify.local.sh'),
    `#!/usr/bin/env bash
ralph_verify_adapter_name() {
  printf 'custom\\n'
}

ralph_verify_run_base_checks() {
  echo "[ralph-verify] running custom base checks"
  printf 'base\\n' > .custom-base.txt
  QUALITY_CHECKS_RAN=1
}

ralph_verify_discover_targeted_tests() {
  printf 'tests/custom.test.txt\\n'
}

ralph_verify_run_targeted_tests() {
  echo "[ralph-verify] running custom targeted tests:"
  printf '%s\\n' "$@" | sed 's/^/  - /'
  printf '%s\\n' "$@" > .custom-targeted.txt
}

ralph_verify_run_full_suite() {
  echo "[ralph-verify] running custom full suite"
  printf 'full\\n' > .custom-full.txt
}
`
  )
  fs.chmodSync(path.join(repoDir, 'scripts/ralph/verify.local.sh'), 0o755)

  const targeted = spawnSync('./scripts/ralph/ralph-verify.sh', ['--targeted'], {
    cwd: repoDir,
    encoding: 'utf8',
    stdio: 'pipe',
  })

  assert.equal(targeted.status, 0)
  assert.match(targeted.stdout, /\[ralph-verify\] running custom base checks/)
  assert.match(targeted.stdout, /\[ralph-verify\] running custom targeted tests:/)
  assert.equal(fs.readFileSync(path.join(repoDir, '.custom-base.txt'), 'utf8').trim(), 'base')
  assert.equal(fs.readFileSync(path.join(repoDir, '.custom-targeted.txt'), 'utf8').trim(), 'tests/custom.test.txt')

  const full = spawnSync('./scripts/ralph/ralph-verify.sh', ['--full'], {
    cwd: repoDir,
    encoding: 'utf8',
    stdio: 'pipe',
  })

  assert.equal(full.status, 0)
  assert.match(full.stdout, /\[ralph-verify\] running custom full suite/)
  assert.equal(fs.readFileSync(path.join(repoDir, '.custom-full.txt'), 'utf8').trim(), 'full')
})
