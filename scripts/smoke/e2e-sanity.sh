#!/bin/bash

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# macOS does not ship 'timeout'; provide a portable fallback via gtimeout or perl alarm
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { local t=$1; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$t" "$@"; }
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"
# shellcheck source=./lib/token-parser.sh
source "$SCRIPT_DIR/lib/token-parser.sh"
# shellcheck source=./lib/benchmark.sh
source "$SCRIPT_DIR/lib/benchmark.sh"

CI_MODE=0
KEEP_REPO=0
FORCE_REAL_CODEX=0
FORCE_MOCK_CODEX=0
WITH_LOOP=0
APP_MODE="${APP_MODE:-console}"
LOOP_RETRY_MAX="${LOOP_RETRY_MAX:-2}"
BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-history.tsv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci)
      CI_MODE=1
      shift
      ;;
    --keep)
      KEEP_REPO=1
      shift
      ;;
    --real-codex)
      FORCE_REAL_CODEX=1
      shift
      ;;
    --mock-codex)
      FORCE_MOCK_CODEX=1
      shift
      ;;
    --with-loop)
      WITH_LOOP=1
      shift
      ;;
    --app-mode)
      [ $# -ge 2 ] || {
        echo "Missing value for --app-mode (expected: console|ui)" >&2
        exit 1
      }
      APP_MODE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/smoke/e2e-sanity.sh [--ci] [--keep] [--real-codex] [--mock-codex] [--with-loop] [--app-mode console|ui]

Runs disposable install-repo E2E sanity checks.

Options:
  --ci          CI-friendly mode (uses mock codex by default; no-op for loop phase which always uses real codex)
  --keep        Keep temp repo for debugging
  --real-codex  Force real codex binary
  --mock-codex  Force mock codex binary
  --with-loop   Run the sprint story-task loop with real codex
  --app-mode    App profile: console (default) or ui
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$APP_MODE" in
  console|ui) ;;
  *)
    echo "Invalid --app-mode '$APP_MODE' (expected console|ui)" >&2
    exit 1
    ;;
esac

BENCH_MODE="$APP_MODE"
[ "$WITH_LOOP" -eq 1 ] && BENCH_MODE="${APP_MODE}-loop"
benchmark_init "sanity" "$BENCH_MODE" "$BENCH_FILE"

WORK_DIR="$(mktemp -d /tmp/ralph-smoke-XXXXXX)"
TMP_HOME="$WORK_DIR/home"
TEST_REPO="$WORK_DIR/project"
mkdir -p "$TMP_HOME" "$TEST_REPO"

cleanup() {
  local exit_code=$?
  local status="pass"
  [ "$exit_code" -eq 0 ] || status="fail"
  if ! benchmark_any_tokens; then
    benchmark_set_notes "tokens-unavailable"
  fi
  benchmark_append_row "$status"

  if [ "$KEEP_REPO" -eq 1 ]; then
    echo "Smoke temp repo retained: $TEST_REPO"
    return
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "[smoke] run failed; retaining temp repo for post-run reporting: $TEST_REPO"
    return
  fi

  find "$WORK_DIR" -mindepth 1 -maxdepth 5 -type f >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

extract_story_complete_count_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || { echo 0; return 0; }
  awk '/=== Story .* COMPLETE ===/ { count += 1 } END { print count + 0 }' "$log_file"
}

resolve_latest_runtime_sprint_log() {
  local repo_root="$1"
  local runs_dir="$repo_root/scripts/ralph/runtime/sprint-runs"
  [ -d "$runs_dir" ] || return 1

  local manifest_path log_path
  manifest_path="$(find "$runs_dir" -type f -name sprint-run.json | sort | tail -n1)"
  [ -n "$manifest_path" ] || return 1
  log_path="$(jq -r '.log_file // empty' "$manifest_path" 2>/dev/null || true)"
  [ -n "$log_path" ] && [ -f "$log_path" ] || return 1
  printf '%s\n' "$log_path"
}

run_with_retries_logged() {
  local retries="$1"
  local log_file="$2"
  local repo_root="$3"
  shift 3

  local attempt=0
  : >"$log_file"
  while true; do
    {
      echo "[smoke] attempt $((attempt + 1))/$((retries + 1))"
      echo "[smoke] cmd: $*"
    } >>"$log_file"

    if "$@" >/dev/null 2>&1; then
      return 0
    fi

    if [ "$attempt" -ge "$retries" ]; then
      echo "[smoke] command failed after $((attempt + 1)) attempt(s)" >>"$log_file"
      return 1
    fi

    clear_stale_workflow_lock_if_safe "$repo_root" "$log_file"
    attempt=$((attempt + 1))
    echo "[smoke] retrying..." >>"$log_file"
  done
}

clear_stale_workflow_lock_if_safe() {
  local repo_root="$1"
  local log_file="$2"
  local lock_dir="$repo_root/scripts/ralph/.workflow-lock"

  [ -d "$lock_dir" ] || return 0

  if ps -eo args= | grep -F -- "$repo_root" | grep -v grep >/dev/null 2>&1; then
    echo "[smoke] workflow lock still has active repo-scoped processes; leaving lock in place" >>"$log_file"
    return 0
  fi

  rm -rf "$lock_dir"
  echo "[smoke] removed stale workflow lock: $lock_dir" >>"$log_file"
}

assert_commit_range_small_and_simple() {
  local repo_root="$1"
  local from_ref="$2"
  local to_ref="$3"
  local label="$4"
  shift 4
  local allowed_patterns=("$@")

  local changed
  changed="$(git -C "$repo_root" diff --name-only "$from_ref..$to_ref" 2>/dev/null | sed '/^$/d' || true)"
  [ -n "$changed" ] || fail "$label produced no committed file changes."

  local bad=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local ok=0
    local p
    for p in "${allowed_patterns[@]}"; do
      case "$f" in
        $p)
          ok=1
          break
          ;;
      esac
    done
    if [ "$ok" -eq 0 ]; then
      bad+="$f"$'\n'
    fi
  done <<<"$changed"

  if [ -n "$bad" ]; then
    fail "$label changed files outside strict allowlist:
$bad"
  fi
}

commit_framework_baseline() {
  local repo_root="$1"
  local commit_msg="$2"

  (
    cd "$repo_root"
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "$commit_msg" >/dev/null
    fi
  )
}

if [ "$FORCE_REAL_CODEX" -eq 1 ] && [ "$FORCE_MOCK_CODEX" -eq 1 ]; then
  echo "Cannot pass both --real-codex and --mock-codex" >&2
  exit 1
fi

CODEX_BIN_VALUE="codex"
if [ "$CI_MODE" -eq 1 ]; then
  CODEX_BIN_VALUE="$REPO_ROOT/scripts/smoke/mock-codex.sh"
fi
if [ "$FORCE_REAL_CODEX" -eq 1 ]; then
  CODEX_BIN_VALUE="codex"
fi
if [ "$FORCE_MOCK_CODEX" -eq 1 ]; then
  CODEX_BIN_VALUE="$REPO_ROOT/scripts/smoke/mock-codex.sh"
fi

echo "[smoke] work dir: $WORK_DIR"
echo "[smoke] codex: $CODEX_BIN_VALUE"
echo "[smoke] app mode: $APP_MODE"

echo "[smoke] running framework run-state regression test"
node --test "$REPO_ROOT/__tests__/ralph-run-state.test.js" >/dev/null

cd "$TEST_REPO"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

if [ "$APP_MODE" = "ui" ]; then
cat > package.json <<'JSON'
{
  "name": "ralph-smoke-ui",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint": "node -e \"console.log('lint ok')\"",
    "test": "node scripts/run-tests.mjs",
    "browser:check": "node scripts/browser-check.mjs"
  },
  "devDependencies": {
    "typescript": "^5.9.2",
    "playwright": "^1.53.0"
  }
}
JSON
else
cat > package.json <<'JSON'
{
  "name": "ralph-smoke-hello",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint": "node -e \"console.log('lint ok')\"",
    "test": "node scripts/run-tests.mjs"
  },
  "devDependencies": {
    "typescript": "^5.9.2"
  }
}
JSON
fi

if [ "$APP_MODE" = "ui" ]; then
cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022", "DOM"],
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
JSON
else
cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
JSON
fi

mkdir -p src
if [ "$APP_MODE" = "ui" ]; then
cat > src/index.ts <<'TS'
const greeting = "Hello World";
const app = document.getElementById("app");
if (app) {
  app.textContent = greeting;
}
console.log(greeting);
TS

cat > index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Ralph Smoke UI</title>
</head>
<body>
  <main>
    <h1 id="app"></h1>
  </main>
  <script type="module" src="./dist/index.js"></script>
</body>
</html>
HTML
else
cat > src/index.ts <<'TS'
console.log("Hello World");
TS
fi

mkdir -p scripts
cat > scripts/run-tests.mjs <<'JS'
import assert from "node:assert/strict";
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const argv = process.argv.slice(2);
let runTestsByPath = [];
let testPathIgnorePatterns = "";

for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === "--runTestsByPath") {
    i += 1;
    while (i < argv.length && !argv[i].startsWith("--")) {
      runTestsByPath.push(argv[i]);
      i += 1;
    }
    i -= 1;
    continue;
  }
  if (arg === "--testPathIgnorePatterns") {
    if (i + 1 < argv.length) {
      testPathIgnorePatterns = argv[i + 1];
      i += 1;
    }
    continue;
  }
}

function collectTests(dir) {
  const entries = readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectTests(full));
      continue;
    }
    if (/(\.test|\.spec)\.m?js$/.test(entry.name)) {
      files.push(full);
    }
  }
  return files;
}

let tests = [];
if (runTestsByPath.length > 0) {
  tests = runTestsByPath.map((p) => path.resolve(p));
} else if (statSync("tests").isDirectory()) {
  tests = collectTests("tests").map((p) => path.resolve(p));
}

if (testPathIgnorePatterns) {
  const ignoreRe = new RegExp(testPathIgnorePatterns);
  tests = tests.filter((p) => !ignoreRe.test(p));
}

assert.ok(tests.length > 0, "No tests discovered");
for (const testPath of tests) {
  await import(pathToFileURL(testPath).href);
}

console.log(`PASS ${tests.length} test file(s)`);
console.log("test ok");
JS

if [ "$APP_MODE" = "ui" ]; then
cat > scripts/browser-check.mjs <<'JS'
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const expected = process.argv[2] || "Hello World";
const MIME_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"]
]);

function contentTypeFor(pathname) {
  const idx = pathname.lastIndexOf(".");
  if (idx === -1) return "text/plain; charset=utf-8";
  return MIME_TYPES.get(pathname.slice(idx)) || "text/plain; charset=utf-8";
}

const server = createServer(async (req, res) => {
  const pathname = req.url === "/" ? "/index.html" : (req.url || "/index.html");
  const filePath = `.${pathname}`;
  try {
    const body = await readFile(filePath);
    res.writeHead(200, { "content-type": contentTypeFor(pathname) });
    res.end(body);
  } catch {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("not found");
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const address = server.address();
if (!address || typeof address === "string") {
  throw new Error("Failed to resolve local server address");
}
const baseUrl = `http://127.0.0.1:${address.port}`;

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
await page.goto(`${baseUrl}/index.html`);
await page.waitForFunction(() => {
  const el = document.querySelector("#app");
  return !!el && (el.textContent || "").trim().length > 0;
});
const text = await page.textContent("#app");
assert.equal((text || "").trim(), expected, `Expected #app to equal '${expected}'`);
await browser.close();
server.close();
console.log(`browser ok: ${expected}`);
JS
fi

mkdir -p tests
cat > tests/hello.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/index.ts", "utf8");
assert.match(source, /Hello World/, "Expected baseline greeting in src/index.ts");
JS

cat > .gitignore <<'EOF'
dist/
EOF

npm install --silent
npm run build --silent

git add .
git reset dist >/dev/null 2>&1 || true
git commit -m "chore: init smoke hello world" >/dev/null

echo "[smoke] refresh skills"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --install-skills > "$WORK_DIR/install-skills.log" 2>&1
assert_contains "$WORK_DIR/install-skills.log" "Installed Codex skill: prd"
assert_file_exists "$TMP_HOME/.codex/skills/prd/SKILL.md"
assert_file_exists "$TMP_HOME/.codex/skills/ralph/SKILL.md"
assert_file_exists "$TMP_HOME/.codex/skills/setup/SKILL.md"


echo "[smoke] install framework"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --project "$TEST_REPO" > "$WORK_DIR/install-framework.log" 2>&1
assert_file_exists "$TEST_REPO/scripts/ralph/doctor.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-story.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-story-run.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-sprint.sh"
commit_framework_baseline "$TEST_REPO" "chore: install ralph framework baseline"


echo "[smoke] doctor"
if [ "$WITH_LOOP" -eq 0 ]; then
  (
    cd "$TEST_REPO/scripts/ralph"
    CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor.log" 2>&1
  )
  assert_contains "$WORK_DIR/doctor.log" "OK: prerequisites present"
else
  echo "[smoke] skipping global doctor in loop mode (mode-specific doctors run in isolated repos)"
fi

if [ "$WITH_LOOP" -eq 1 ]; then
  echo "[smoke] sprint story-task loop"
  LOOP_CODEX_BIN="codex"

  SPRINT_REPO="$WORK_DIR/project-loop-sprint"
  cp -a "$TEST_REPO" "$SPRINT_REPO"
  echo "[smoke] isolated sprint repo: $SPRINT_REPO"

  sprint_tokens=0
  sprint_stories_completed=0

  if [ "$APP_MODE" = "ui" ]; then
    sprint_s001_title="Update greeting to Hello Sprint Ralph"
    sprint_s001_goal="Update the app greeting to Hello Sprint Ralph and update tests accordingly."
    sprint_s001_context="Change the greeting string in src/index.ts and update the assertion in tests/hello.test.mjs."
    sprint_s001_t01_context="Update src/index.ts UI greeting constant to exactly Hello Sprint Ralph. The current value is Hello World. Change only the greeting string, keep all other code unchanged. Commit the change."
    sprint_s001_t01_acceptance="src/index.ts contains Hello Sprint Ralph as the greeting value. Typecheck passes."
    sprint_s001_t02_context="Update tests/hello.test.mjs assertion to expect Hello Sprint Ralph instead of Hello World. Change only the assertion string. Commit the change."
    sprint_s001_t02_acceptance="tests/hello.test.mjs asserts Hello Sprint Ralph. All tests pass."
    sprint_s002_title="Add app identifier output"
    sprint_s002_goal="Add a console.log line for the app identifier sprint-smoke to src/index.ts and update tests."
    sprint_s002_context="Add console.log for app identifier after existing output in src/index.ts and update test to verify the identifier is present in source."
    sprint_s002_t01_context="Add console.log('App: sprint-smoke') line to src/index.ts after the existing console.log. Change only what is needed. Commit the change."
    sprint_s002_t01_acceptance="src/index.ts contains App: sprint-smoke. Typecheck passes."
    sprint_s002_t02_context="Update tests/hello.test.mjs to also assert that src/index.ts contains sprint-smoke. Commit the change."
    sprint_s002_t02_acceptance="tests/hello.test.mjs asserts sprint-smoke is present in src/index.ts. All tests pass."
    sprint_s003_title="Add document title and verify browser"
    sprint_s003_goal="Add document.title assignment to src/index.ts and run browser verification."
    sprint_s003_context="Add document.title assignment in src/index.ts and update test, then build and verify browser output."
    sprint_s003_t01_context="Add document.title = 'Sprint Ralph' to src/index.ts. Keep all other code unchanged. Commit the change."
    sprint_s003_t01_acceptance="src/index.ts contains document.title assignment for Sprint Ralph. Typecheck passes. Lint passes."
    sprint_s003_t02_context="Update tests/hello.test.mjs to also assert that src/index.ts contains Sprint Ralph. Commit the change."
    sprint_s003_t02_acceptance="tests/hello.test.mjs asserts Sprint Ralph is present in src/index.ts. Lint passes. Tests pass."
    sprint_s003_t03_context="Build the project with npm run build. Then run npm run -s browser:check -- Hello Sprint Ralph to verify the browser shows Hello Sprint Ralph in the #app element. Run npm test. Fix any issues and commit any fixes needed."
    sprint_s003_t03_acceptance="Build succeeds. Browser check passes for Hello Sprint Ralph. Tests pass. Lint passes."
    sprint_expected_msg="Hello Sprint Ralph"
  else
    sprint_s001_title="Update greeting to Hello Sprint Ralph"
    sprint_s001_goal="Update the app greeting to Hello Sprint Ralph and update tests accordingly."
    sprint_s001_context="Change the greeting string in src/index.ts and update the assertion in tests/hello.test.mjs."
    sprint_s001_t01_context="Update src/index.ts to print exactly Hello Sprint Ralph instead of Hello World. Change only the greeting string in the console.log call. Commit the change."
    sprint_s001_t01_acceptance="src/index.ts contains Hello Sprint Ralph in the console.log statement. Typecheck passes."
    sprint_s001_t02_context="Update tests/hello.test.mjs assertion to expect Hello Sprint Ralph instead of Hello World. Change only the assertion string. Commit the change."
    sprint_s001_t02_acceptance="tests/hello.test.mjs asserts Hello Sprint Ralph. All tests pass."
    sprint_s002_title="Add app identifier output"
    sprint_s002_goal="Add a console.log line for the app identifier sprint-smoke to src/index.ts and update tests."
    sprint_s002_context="Add console.log for app identifier after existing output in src/index.ts and update test to verify the identifier is present in source."
    sprint_s002_t01_context="Add console.log('App: sprint-smoke') line to src/index.ts after the existing console.log. Change only what is needed. Commit the change."
    sprint_s002_t01_acceptance="src/index.ts contains App: sprint-smoke. Typecheck passes."
    sprint_s002_t02_context="Update tests/hello.test.mjs to also assert that src/index.ts contains sprint-smoke. Commit the change."
    sprint_s002_t02_acceptance="tests/hello.test.mjs asserts sprint-smoke is present in src/index.ts. All tests pass."
    sprint_s003_title="Add status message output"
    sprint_s003_goal="Add a console.log line for Status: ready to src/index.ts and update tests."
    sprint_s003_context="Add console.log for status after existing output in src/index.ts and update test to verify status message is present in source."
    sprint_s003_t01_context="Add console.log('Status: ready') line to src/index.ts after the existing output. Change only what is needed. Commit the change."
    sprint_s003_t01_acceptance="src/index.ts contains Status: ready. Typecheck passes."
    sprint_s003_t02_context="Update tests/hello.test.mjs to also assert that src/index.ts contains Status: ready. Commit the change."
    sprint_s003_t02_acceptance="tests/hello.test.mjs asserts Status: ready is present in src/index.ts. All tests pass."
    sprint_expected_msg="Hello Sprint Ralph"
    sprint_expected_status="Status: ready"
    sprint_expected_app="App: sprint-smoke"
  fi

  (
    cd "$SPRINT_REPO/scripts/ralph"
    CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor-sprint.log" 2>&1
    ./ralph-sprint.sh remove sprint-1 --yes --hard > "$WORK_DIR/sprint-reset-sprint.log" 2>&1 || true
    ./ralph-sprint.sh create sprint-1 > "$WORK_DIR/sprint-create-sprint.log" 2>&1
    ./ralph-story.sh add \
      --title "$sprint_s001_title" \
      --goal "$sprint_s001_goal" \
      --prompt-context "$sprint_s001_context" \
      > "$WORK_DIR/story-add-S-001.log" 2>&1
    ./ralph-story.sh add \
      --title "$sprint_s002_title" \
      --goal "$sprint_s002_goal" \
      --prompt-context "$sprint_s002_context" \
      > "$WORK_DIR/story-add-S-002.log" 2>&1
    ./ralph-story.sh add \
      --title "$sprint_s003_title" \
      --goal "$sprint_s003_goal" \
      --prompt-context "$sprint_s003_context" \
      > "$WORK_DIR/story-add-S-003.log" 2>&1

    ./ralph-story.sh import-story S-001 - <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-001",
  "title": "$sprint_s001_title",
  "description": "Update greeting in src/index.ts to Hello Sprint Ralph and update tests accordingly.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "Update greeting string in src/index.ts and test assertion in tests/hello.test.mjs.",
    "preserved_invariants": [
      "All existing tests must pass after changes",
      "TypeScript typecheck must pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update greeting in src/index.ts",
      "context": "$sprint_s001_t01_context",
      "scope": ["src/index.ts"],
      "acceptance": "$sprint_s001_t01_acceptance",
      "checks": [
        "grep -q 'Hello Sprint Ralph' src/index.ts",
        "npm run typecheck",
        "npm run lint"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update test assertion in tests/hello.test.mjs",
      "context": "$sprint_s001_t02_context",
      "scope": ["tests/hello.test.mjs"],
      "acceptance": "$sprint_s001_t02_acceptance",
      "checks": [
        "grep -q 'Hello Sprint Ralph' tests/hello.test.mjs",
        "npm run lint",
        "npm test"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression verification",
      "context": "Run npm run build to compile, npm run lint to check code quality, and npm test to run the full test suite. If any issues are found, fix them and commit. If everything passes, nothing needs to be committed.",
      "scope": ["src/index.ts", "tests/hello.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

    ./ralph-story.sh import-story S-002 - <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-002",
  "title": "$sprint_s002_title",
  "description": "Add console.log for the app identifier sprint-smoke to src/index.ts and update tests.",
  "branchName": "ralph/sprint-1/story-S-002",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "Add app identifier output to src/index.ts and update tests/hello.test.mjs.",
    "preserved_invariants": [
      "All existing tests must pass after changes",
      "TypeScript typecheck must pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Add app identifier console.log to src/index.ts",
      "context": "$sprint_s002_t01_context",
      "scope": ["src/index.ts"],
      "acceptance": "$sprint_s002_t01_acceptance",
      "checks": [
        "grep -q 'sprint-smoke' src/index.ts",
        "npm run typecheck",
        "npm run lint"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update test to verify app identifier in source",
      "context": "$sprint_s002_t02_context",
      "scope": ["tests/hello.test.mjs"],
      "acceptance": "$sprint_s002_t02_acceptance",
      "checks": [
        "grep -q 'sprint-smoke' tests/hello.test.mjs",
        "npm run lint",
        "npm test"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression verification",
      "context": "Run npm run build to compile, npm run lint to check code quality, and npm test to run the full test suite. If any issues are found, fix them and commit. If everything passes, nothing needs to be committed.",
      "scope": ["src/index.ts", "tests/hello.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

    if [ "$APP_MODE" = "ui" ]; then
      ./ralph-story.sh import-story S-003 - <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-003",
  "title": "$sprint_s003_title",
  "description": "$sprint_s003_goal",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "Add document.title to src/index.ts, update tests/hello.test.mjs, build, and verify browser.",
    "preserved_invariants": [
      "All existing tests must pass after changes",
      "TypeScript typecheck must pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Add document.title assignment to src/index.ts",
      "context": "$sprint_s003_t01_context",
      "scope": ["src/index.ts"],
      "acceptance": "$sprint_s003_t01_acceptance",
      "checks": [
        "grep -q 'document.title' src/index.ts",
        "npm run typecheck",
        "npm run lint"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update tests/hello.test.mjs to assert document.title",
      "context": "$sprint_s003_t02_context",
      "scope": ["tests/hello.test.mjs"],
      "acceptance": "$sprint_s003_t02_acceptance",
      "checks": [
        "grep -q 'Sprint Ralph' tests/hello.test.mjs",
        "npm run lint",
        "npm test"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Build and browser regression verification",
      "context": "$sprint_s003_t03_context",
      "scope": ["src/index.ts", "tests/hello.test.mjs"],
      "acceptance": "$sprint_s003_t03_acceptance",
      "checks": [
        "npm run build",
        "npm run -s browser:check -- 'Hello Sprint Ralph'",
        "npm run lint",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON
    else
      ./ralph-story.sh import-story S-003 - <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-003",
  "title": "$sprint_s003_title",
  "description": "$sprint_s003_goal",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "Add status message output to src/index.ts and update tests/hello.test.mjs.",
    "preserved_invariants": [
      "All existing tests must pass after changes",
      "TypeScript typecheck must pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Add status message console.log to src/index.ts",
      "context": "$sprint_s003_t01_context",
      "scope": ["src/index.ts"],
      "acceptance": "$sprint_s003_t01_acceptance",
      "checks": [
        "grep -q 'Status: ready' src/index.ts",
        "npm run typecheck",
        "npm run lint"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update test to verify status message in source",
      "context": "$sprint_s003_t02_context",
      "scope": ["tests/hello.test.mjs"],
      "acceptance": "$sprint_s003_t02_acceptance",
      "checks": [
        "grep -q 'Status: ready' tests/hello.test.mjs",
        "npm run lint",
        "npm test"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression verification",
      "context": "Run npm run build to compile, npm run lint to check code quality, and npm test to run the full test suite. If any issues are found, fix them and commit. If everything passes, nothing needs to be committed.",
      "scope": ["src/index.ts", "tests/hello.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON
    fi

    cat > "ralph-sprint-test.sh" <<'SPRSH'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
npm run build && npm run lint && npm test
SPRSH
    chmod +x "ralph-sprint-test.sh"

    ./ralph-story.sh health > "$WORK_DIR/story-health.log" 2>&1
    ./ralph-sprint.sh restage sprint-1 > "$WORK_DIR/sprint-restage.log" 2>&1
    commit_framework_baseline "$SPRINT_REPO" "chore(smoke): pre-loop planning state (sprint)"
    ./ralph-sprint.sh mark-ready sprint-1 > "$WORK_DIR/sprint-mark-ready.log" 2>&1
    ./ralph-sprint.sh use sprint-1 > "$WORK_DIR/sprint-use.log" 2>&1
    sprint_loop_start_head="$(git -C "$SPRINT_REPO" rev-parse HEAD)"
    run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop.log" "$SPRINT_REPO" timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph.sh --max-stories 3 --max-retries "$LOOP_RETRY_MAX" --continue-on-failure
    sprint_loop_end_head="$(git -C "$SPRINT_REPO" rev-parse HEAD)"

    jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-001/story.json" >/dev/null
    jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-002/story.json" >/dev/null
    jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-003/story.json" >/dev/null
    jq -e 'all(.stories[]; .status == "done" and .passes == true)' "sprints/sprint-1/stories.json" >/dev/null

    if [ "$APP_MODE" = "ui" ]; then
      assert_commit_range_small_and_simple "$SPRINT_REPO" "$sprint_loop_start_head" "$sprint_loop_end_head" "sprint loop" \
        "scripts/ralph/sprints/sprint-1/stories.json" \
        "scripts/ralph/sprints/sprint-1/stories/*/story.json" \
        "src/index.ts" "tests/hello.test.mjs" "scripts/browser-check.mjs"
    else
      assert_commit_range_small_and_simple "$SPRINT_REPO" "$sprint_loop_start_head" "$sprint_loop_end_head" "sprint loop" \
        "scripts/ralph/sprints/sprint-1/stories.json" \
        "scripts/ralph/sprints/sprint-1/stories/*/story.json" \
        "src/index.ts" "tests/hello.test.mjs"
    fi

    if [ "$APP_MODE" = "ui" ]; then
      grep -qF "const greeting = \"$sprint_expected_msg\";" "$SPRINT_REPO/src/index.ts" || fail "sprint src/index.ts does not contain expected UI greeting assignment: $sprint_expected_msg"
    else
      grep -qF "console.log(\"$sprint_expected_msg\");" "$SPRINT_REPO/src/index.ts" || fail "sprint src/index.ts does not contain expected greeting: $sprint_expected_msg"
    fi
    grep -qF "$sprint_expected_msg" "$SPRINT_REPO/tests/hello.test.mjs" || fail "sprint tests/hello.test.mjs missing expected greeting: $sprint_expected_msg"
    grep -q "sprint-smoke" "$SPRINT_REPO/src/index.ts" || fail "sprint src/index.ts missing expected app identifier: sprint-smoke"
    grep -q "sprint-smoke" "$SPRINT_REPO/tests/hello.test.mjs" || fail "sprint tests/hello.test.mjs missing expected app identifier assertion: sprint-smoke"

    (
      cd "$SPRINT_REPO"
      npm run -s build > "$WORK_DIR/build-sprint.log" 2>&1
      npm test > "$WORK_DIR/test-sprint.log" 2>&1
      if [ "$APP_MODE" = "ui" ]; then
        npm run -s browser:check -- "$sprint_expected_msg" > "$WORK_DIR/runtime-sprint.log" 2>&1
      else
        node dist/index.js > "$WORK_DIR/runtime-sprint.log" 2>&1
      fi
      if git ls-files --error-unmatch dist/index.js >/dev/null 2>&1; then
        git checkout -- dist/index.js
      fi
    )
    ./ralph-sprint-commit.sh > "$WORK_DIR/sprint-commit-sprint.log" 2>&1
  )
  assert_contains "$WORK_DIR/doctor-sprint.log" "OK: prerequisites present"
  assert_contains "$WORK_DIR/sprint-create-sprint.log" "Created sprint: sprint-1"
  assert_contains "$WORK_DIR/sprint-create-sprint.log" "Active sprint set to: sprint-1"
  assert_contains "$WORK_DIR/story-add-S-001.log" "Added story: S-001"
  assert_contains "$WORK_DIR/story-add-S-002.log" "Added story: S-002"
  assert_contains "$WORK_DIR/story-add-S-003.log" "Added story: S-003"
  assert_contains "$WORK_DIR/story-health.log" "\\[S-001\\]"
  assert_contains "$WORK_DIR/sprint-restage.log" "Sprint 'sprint-1' restaged to planned."
  assert_contains "$WORK_DIR/sprint-mark-ready.log" "Sprint 'sprint-1' marked ready."
  assert_contains "$WORK_DIR/sprint-use.log" "Active sprint set to: sprint-1"
  assert_contains "$WORK_DIR/sprint-use.log" "Checked out sprint branch: ralph/sprint/sprint-1"
  runtime_loop_log="$(resolve_latest_runtime_sprint_log "$SPRINT_REPO")" || fail "Could not resolve Ralph runtime sprint log"
  assert_contains "$runtime_loop_log" "Story S-001 COMPLETE"
  assert_contains "$runtime_loop_log" "Story S-002 COMPLETE"
  assert_contains "$runtime_loop_log" "Story S-003 COMPLETE"
  assert_not_contains "$runtime_loop_log" "node: bad option: --runInBand"
  if [ "$APP_MODE" = "ui" ]; then
    assert_contains "$WORK_DIR/runtime-sprint.log" "browser ok: $sprint_expected_msg"
  else
    assert_contains "$WORK_DIR/runtime-sprint.log" "^$sprint_expected_msg$"
  fi
  assert_contains "$WORK_DIR/test-sprint.log" "test ok"
  assert_contains "$WORK_DIR/sprint-commit-sprint.log" "Sprint regression: PASS"
  assert_contains "$WORK_DIR/sprint-commit-sprint.log" "Deleted source sprint branch:"

  sprint_tokens="$(extract_tokens_from_log "$runtime_loop_log")"
  sprint_stories_completed="$(extract_story_complete_count_from_log "$runtime_loop_log")"
  sprint_retries="$(awk '/retrying\.\.\./{c++} END{print c+0}' "$WORK_DIR/loop.log" 2>/dev/null || echo 0)"
  benchmark_set_execution_tokens "$sprint_tokens"
  benchmark_set_story_cycles "$sprint_stories_completed"
  benchmark_set_stories "$sprint_stories_completed"
  benchmark_set_retries "$sprint_retries"

  if [ "$sprint_tokens" -eq 0 ]; then
    echo "[smoke] token summary: unavailable (no 'tokens used' markers in codex output)"
  else
    echo "[smoke] token summary: app_mode=$APP_MODE sprint=$sprint_tokens stories_completed=$sprint_stories_completed"
  fi
fi


echo "[smoke] PASS: install-repo E2E sanity checks completed"
