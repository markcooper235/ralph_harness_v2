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

KEEP_REPO=0
WORK_DIR="$(mktemp -d /tmp/ralph-worst-ui-XXXXXX)"
TMP_HOME="$WORK_DIR/home"
TEST_REPO="$WORK_DIR/project"
BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/worst-case-ui.tsv"
LOOP_RETRY_MAX="${LOOP_RETRY_MAX:-2}"
MAX_ITERATIONS="${MAX_ITERATIONS:-8}"
CODEX_BIN_VALUE="${CODEX_BIN:-codex}"

cleanup() {
  local exit_code=$?
  local status="pass"
  [ "$exit_code" -eq 0 ] || status="fail"
  if ! benchmark_any_tokens; then
    benchmark_set_notes "tokens-unavailable"
  fi
  benchmark_append_row "$status"
  if [ "$KEEP_REPO" -eq 1 ] || [ "$exit_code" -ne 0 ]; then
    echo "[worst-ui] retained temp repo: $TEST_REPO"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP_REPO=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/smoke/e2e-worst-case-ui.sh [--keep]

Runs a heavier real-Codex UI sprint smoke scenario with:
- multi-file implementation scope
- multi-task story-task execution
- browser verification requirements
- token and iteration reporting
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$TMP_HOME" "$TEST_REPO"
benchmark_init "worst-case-ui" "ui" "$BENCH_FILE"

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

run_with_retries_logged() {
  local retries="$1"
  local log_file="$2"
  local repo_root="$3"
  shift 3
  local attempt
  : > "$log_file"
  for attempt in $(seq 0 "$retries"); do
    echo "[worst-ui] attempt $((attempt + 1))/$((retries + 1))" >>"$log_file"
    echo "[worst-ui] cmd: $*" >>"$log_file"
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -ge "$retries" ]; then
      echo "[worst-ui] command failed after $((attempt + 1)) attempt(s)" >>"$log_file"
      return 1
    fi
    clear_stale_workflow_lock_if_safe "$repo_root" "$log_file"
    echo "[worst-ui] retrying..." >>"$log_file"
  done
}

clear_stale_workflow_lock_if_safe() {
  local repo_root="$1"
  local log_file="$2"
  local lock_dir="$repo_root/scripts/ralph/.workflow-lock"

  [ -d "$lock_dir" ] || return 0

  if ps -eo args= | grep -F -- "$repo_root" | grep -v grep >/dev/null 2>&1; then
    echo "[worst-ui] workflow lock still has active repo-scoped processes; leaving lock in place" >>"$log_file"
    return 0
  fi

  rm -rf "$lock_dir"
  echo "[worst-ui] removed stale workflow lock: $lock_dir" >>"$log_file"
}

assert_only_allowed_files_changed() {
  local repo="$1"
  local start_ref="$2"
  local end_ref="$3"
  shift 3
  local allowed_file
  local changed
  local unexpected=()

  changed="$(git -C "$repo" diff --name-only "$start_ref" "$end_ref")"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    local allowed=0
    for allowed_file in "$@"; do
      if [ "$changed_file" = "$allowed_file" ]; then
        allowed=1
        break
      fi
    done
    if [ "$allowed" -ne 1 ]; then
      unexpected+=("$changed_file")
    fi
  done <<<"$changed"

  if [ "${#unexpected[@]}" -gt 0 ]; then
    fail "worst-case loop changed files outside strict allowlist:
$(printf '%s\n' "${unexpected[@]}")"
  fi
}

assert_runtime_ui_contract() {
  local repo="$1"
  local headline="$2"
  local status="$3"
  local cta="$4"
  local state="$5"
  local log_file="$6"

  (
    cd "$repo"
    npm run -s build > "$WORK_DIR/build-sprint.log" 2>&1
    npm test > "$WORK_DIR/test-sprint.log" 2>&1
    npm run -s browser:check -- "$headline" "$status" "$cta" "$state" > "$log_file" 2>&1
    if git ls-files --error-unmatch dist/index.js >/dev/null 2>&1; then
      git checkout -- dist/index.js
    fi
  )
}

echo "[worst-ui] work dir: $WORK_DIR"
echo "[worst-ui] codex: $CODEX_BIN_VALUE"

cd "$TEST_REPO"
git init -b main >/dev/null
git config user.name "Ralph Worst Smoke"
git config user.email "ralph-worst@example.com"

cat > package.json <<'JSON'
{
  "name": "ralph-worst-ui",
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
    "playwright": "^1.55.0",
    "typescript": "^5.9.2"
  }
}
JSON

cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "rootDir": "src",
    "outDir": "dist",
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts"]
}
JSON

mkdir -p src scripts tests

cat > src/messages.ts <<'TS'
export const uiCopy = {
  headline: "Hello World",
  status: "Draft mode",
  cta: "Open details",
  state: "draft",
};
TS

cat > src/render.ts <<'TS'
import { uiCopy } from "./messages.js";

export function render() {
  const headline = document.getElementById("app");
  const status = document.getElementById("status");
  const cta = document.getElementById("cta");

  if (headline) headline.textContent = uiCopy.headline;
  if (status) status.textContent = uiCopy.status;
  if (cta) cta.textContent = uiCopy.cta;
}
TS

cat > src/index.ts <<'TS'
import { render } from "./render.js";

render();
TS

cat > index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Ralph Worst Case UI</title>
</head>
<body>
  <main>
    <h1 id="app"></h1>
    <p id="status"></p>
    <button id="cta" type="button"></button>
  </main>
  <script type="module" src="./dist/index.js"></script>
</body>
</html>
HTML

cat > scripts/run-tests.mjs <<'JS'
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function collectTests(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...collectTests(full));
    } else if (/(\.test|\.spec)\.m?js$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

const tests = statSync("tests").isDirectory() ? collectTests("tests") : [];
if (tests.length === 0) throw new Error("No tests found");
for (const testPath of tests) {
  await import(pathToFileURL(path.resolve(testPath)).href);
}
console.log(`PASS ${tests.length} test file(s)`);
console.log("test ok");
JS

cat > scripts/browser-check.mjs <<'JS'
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const expectedHeadline = process.argv[2] || "Hello World";
const expectedStatus = process.argv[3] || "Draft mode";
const expectedCta = process.argv[4] || "Open details";
const expectedState = process.argv[5] || "draft";

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
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${address.port}/index.html`);
await page.waitForFunction(() => {
  const app = document.querySelector("#app");
  const status = document.querySelector("#status");
  const cta = document.querySelector("#cta");
  return [app, status, cta].every((el) => !!el && (el.textContent || "").trim().length > 0);
});
assert.equal((await page.textContent("#app"))?.trim(), expectedHeadline);
assert.equal((await page.textContent("#status"))?.trim(), expectedStatus);
assert.equal((await page.textContent("#cta"))?.trim(), expectedCta);
assert.equal(await page.getAttribute("#status", "data-state"), expectedState);
assert.equal(await page.getAttribute("#cta", "title"), expectedCta);
await browser.close();
server.close();
console.log(`browser ok: ${expectedHeadline} | ${expectedStatus} | ${expectedCta} | ${expectedState}`);
JS

cat > tests/messages.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/messages.ts", "utf8");
assert.match(source, /Hello World/, "Expected baseline headline in src/messages.ts");
assert.match(source, /Draft mode/, "Expected baseline status in src/messages.ts");
assert.match(source, /Open details/, "Expected baseline CTA in src/messages.ts");
assert.match(source, /draft/, "Expected baseline state in src/messages.ts");
JS

cat > tests/render.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/render.ts", "utf8");
assert.match(source, /getElementById\("app"\)/, "Expected render.ts to target #app");
assert.match(source, /getElementById\("status"\)/, "Expected render.ts to target #status");
assert.match(source, /getElementById\("cta"\)/, "Expected render.ts to target #cta");
JS

cat > .gitignore <<'EOF'
dist/
EOF

npm install --silent
npm run build --silent
git add .
git reset dist >/dev/null 2>&1 || true
git commit -m "chore: init worst-case smoke ui" >/dev/null

echo "[worst-ui] refresh skills"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --install-skills > "$WORK_DIR/install-skills.log" 2>&1
assert_contains "$WORK_DIR/install-skills.log" "Installed Codex skill: prd"
assert_file_exists "$TMP_HOME/.codex/skills/ralph-runtime/SKILL.md"

echo "[worst-ui] install framework"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --project "$TEST_REPO" > "$WORK_DIR/install-framework.log" 2>&1
assert_file_exists "$TEST_REPO/scripts/ralph/doctor.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-story.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-story-run.sh"
commit_framework_baseline "$TEST_REPO" "chore: install ralph framework baseline"

SPRINT_REPO="$WORK_DIR/project-loop-sprint"
cp -a "$TEST_REPO" "$SPRINT_REPO"
echo "[worst-ui] isolated repo: sprint=$SPRINT_REPO"

expected_headline="Hello Sprint Ralph"
expected_status="Ready for review"
expected_cta="View release notes"
expected_state="ready"

(
  cd "$SPRINT_REPO/scripts/ralph"
  CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor-sprint.log" 2>&1
  ./ralph-sprint.sh remove sprint-1 --yes --hard > "$WORK_DIR/sprint-reset-sprint.log" 2>&1 || true
  ./ralph-sprint.sh create sprint-1 > "$WORK_DIR/sprint-create-sprint.log" 2>&1 </dev/null
  ./ralph-story.sh add \
    --title "Update UI copy source and tests" \
    --goal "Update src/messages.ts with new headline, status, cta, and state values, and update tests to assert the new values." \
    --prompt-context "Update src/messages.ts to use the new UI copy values and update tests/messages.test.mjs to assert them." \
    > "$WORK_DIR/story-add-S-001.log" 2>&1
  ./ralph-story.sh add \
    --title "Update DOM rendering contract and tests" \
    --goal "Update src/render.ts to set data-state on #status and title on #cta, and update tests/render.test.mjs to assert these attributes." \
    --prompt-context "Extend src/render.ts to set the data-state attribute on #status from uiCopy.state and the title attribute on #cta from uiCopy.cta. Update tests/render.test.mjs accordingly." \
    > "$WORK_DIR/story-add-S-002.log" 2>&1
  ./ralph-story.sh add \
    --title "Add comprehensive Playwright UI test suite and verify" \
    --goal "Create a Playwright test suite in tests/ui.spec.mjs, build, and run full browser verification." \
    --depends-on S-002 \
    --prompt-context "Create tests/ui.spec.mjs using Playwright chromium with a local HTTP server. Assert at least 6 things including #app text, #status text, data-state attr, #cta text, title attr, and that cta is a button. Then build and run browser:check." \
    > "$WORK_DIR/story-add-S-003.log" 2>&1

  ./ralph-story.sh import-story S-001 - <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-001",
  "title": "Update UI copy source and tests",
  "description": "Update src/messages.ts with new headline, status, cta, and state values, and update tests/messages.test.mjs to assert them.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "src/messages.ts, tests/messages.test.mjs",
    "preserved_invariants": [
      "src/messages.ts remains the canonical copy/state source",
      "src/index.ts remains the only runtime entrypoint"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update src/messages.ts with new UI copy values",
      "context": "Update src/messages.ts: set headline to $expected_headline, status to $expected_status, cta to $expected_cta, state to $expected_state. Commit.",
      "scope": ["src/messages.ts"],
      "acceptance": "src/messages.ts has all 4 new values. Typecheck and tests pass.",
      "checks": [
        "grep -q 'Hello Sprint Ralph' src/messages.ts",
        "grep -q 'Ready for review' src/messages.ts",
        "grep -q 'View release notes' src/messages.ts",
        "npm run typecheck",
        "npm run lint",
        "npm test"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update tests/messages.test.mjs to assert all 4 new values",
      "context": "Update tests/messages.test.mjs to assert all 4 new UI copy values: $expected_headline, $expected_status, $expected_cta, and $expected_state. Commit.",
      "scope": ["tests/messages.test.mjs"],
      "acceptance": "tests/messages.test.mjs asserts all 4 new values. All tests pass.",
      "checks": [
        "grep -q 'Hello Sprint Ralph' tests/messages.test.mjs",
        "grep -q 'Ready for review' tests/messages.test.mjs",
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
      "scope": ["src/messages.ts", "tests/messages.test.mjs"],
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
  "title": "Update DOM rendering contract and tests",
  "description": "Update src/render.ts to set data-state on #status and title on #cta, and update tests/render.test.mjs to assert these attributes.",
  "branchName": "ralph/sprint-1/story-S-002",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "src/render.ts, tests/render.test.mjs",
    "preserved_invariants": [
      "src/messages.ts remains the canonical copy/state source",
      "src/index.ts remains the only runtime entrypoint",
      "Existing DOM element text assignments in render.ts remain unchanged"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update src/render.ts to set data-state and title attributes",
      "context": "Update src/render.ts to also set the data-state attribute on the #status element from uiCopy.state, and the title attribute on the #cta element from uiCopy.cta. Commit.",
      "scope": ["src/render.ts"],
      "acceptance": "src/render.ts sets data-state on #status and title on #cta. Typecheck passes.",
      "checks": [
        "grep -q 'data-state' src/render.ts",
        "grep -q 'title' src/render.ts",
        "npm run typecheck",
        "npm run lint"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update tests/render.test.mjs to assert data-state and title attributes",
      "context": "Update tests/render.test.mjs to assert that render.ts sets data-state on #status and title on #cta. Commit.",
      "scope": ["tests/render.test.mjs"],
      "acceptance": "tests/render.test.mjs asserts data-state is set on #status and title is set on #cta. All tests pass.",
      "checks": [
        "grep -q 'data-state' tests/render.test.mjs",
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
      "scope": ["src/render.ts", "tests/render.test.mjs"],
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

  ./ralph-story.sh import-story S-003 - <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-003",
  "title": "Add comprehensive Playwright UI test suite and verify",
  "description": "Create tests/ui.spec.mjs Playwright test suite, build the project, and run full browser verification.",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": ["S-002"],
  "status": "ready",
  "spec": {
    "scope": "tests/ui.spec.mjs, src/render.ts, scripts/browser-check.mjs",
    "preserved_invariants": [
      "All existing tests continue to pass",
      "TypeScript typecheck must pass",
      "Browser contract: #app=$expected_headline, #status=$expected_status with data-state=$expected_state, #cta=$expected_cta with title=$expected_cta"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create tests/ui.spec.mjs Playwright test suite",
      "context": "Create tests/ui.spec.mjs: a comprehensive Playwright test suite. Import chromium from playwright. Create a local HTTP server (like scripts/browser-check.mjs pattern) to serve files from the current directory. Navigate to index.html. Wait for all elements to render. Assert at least 6 things: #app text equals $expected_headline, #status text equals $expected_status, #status data-state attribute equals $expected_state, #cta text equals $expected_cta, #cta title attribute equals $expected_cta, and #cta is a button element. Close browser and server when done. console.log PASS with assertion count. Commit.",
      "scope": ["tests/ui.spec.mjs"],
      "acceptance": "tests/ui.spec.mjs exists, imports chromium, and includes data-state assertions. Typecheck passes. Lint passes.",
      "checks": [
        "test -f tests/ui.spec.mjs",
        "grep -q 'chromium' tests/ui.spec.mjs",
        "grep -q 'data-state' tests/ui.spec.mjs",
        "npm run typecheck",
        "npm run lint"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Verify Playwright spec has all required assertions",
      "context": "Review tests/ui.spec.mjs and ensure it has assertions for all required elements: #app text ($expected_headline), #status text ($expected_status), #status data-state=$expected_state, #cta text ($expected_cta), #cta title=$expected_cta, and that #cta is a button element. Add any missing assertions. Run npm run lint. Commit any changes.",
      "scope": ["tests/ui.spec.mjs"],
      "acceptance": "tests/ui.spec.mjs has all 6+ assertions. Lint passes.",
      "checks": [
        "grep -q '#app' tests/ui.spec.mjs",
        "grep -q 'data-state' tests/ui.spec.mjs",
        "grep -q '#cta' tests/ui.spec.mjs",
        "npm run lint"
      ],
      "depends_on": ["T-01"],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression: build, browser verify, and test suite",
      "context": "Run npm run build to compile the project. Then run npm run -s browser:check -- $expected_headline $expected_status $expected_cta $expected_state to verify the full browser contract. Run npm run lint. Run npm test to execute all tests including the Playwright suite. Fix any issues found and commit any fixes.",
      "scope": ["src/render.ts", "tests/ui.spec.mjs", "scripts/browser-check.mjs"],
      "acceptance": "Build succeeds. Browser check passes for all 4 args. All tests pass including Playwright. Lint passes.",
      "checks": [
        "npm run build",
        "npm run -s browser:check -- 'Hello Sprint Ralph' 'Ready for review' 'View release notes' ready",
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

  ./ralph-story.sh health > "$WORK_DIR/story-health.log" 2>&1
  ./ralph-sprint.sh status > "$WORK_DIR/status-sprint-preloop.log" 2>&1 || true
  ./ralph-sprint.sh restage sprint-1 > "$WORK_DIR/sprint-restage.log" 2>&1
  commit_framework_baseline "$SPRINT_REPO" "chore(worst-ui): pre-loop planning state"
  ./ralph-sprint.sh mark-ready sprint-1 > "$WORK_DIR/sprint-mark-ready.log" 2>&1
  ./ralph-sprint.sh use sprint-1 > "$WORK_DIR/sprint-use.log" 2>&1
  sprint_loop_start_head="$(git -C "$SPRINT_REPO" rev-parse HEAD)"
  run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop.log" "$SPRINT_REPO" timeout 600 env CODEX_BIN="$CODEX_BIN_VALUE" ./ralph.sh --max-stories 3 --max-retries "$LOOP_RETRY_MAX" --continue-on-failure
  sprint_loop_end_head="$(git -C "$SPRINT_REPO" rev-parse HEAD)"

  jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-001/story.json" >/dev/null
  jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-002/story.json" >/dev/null
  jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-003/story.json" >/dev/null
  jq -e 'all(.stories[]; .status == "done" and .passes == true)' "sprints/sprint-1/stories.json" >/dev/null

  assert_only_allowed_files_changed "$SPRINT_REPO" "$sprint_loop_start_head" "$sprint_loop_end_head" \
    "scripts/ralph/sprints/sprint-1/stories.json" \
    "scripts/ralph/sprints/sprint-1/stories/S-001/story.json" \
    "scripts/ralph/sprints/sprint-1/stories/S-002/story.json" \
    "scripts/ralph/sprints/sprint-1/stories/S-003/story.json" \
    "src/messages.ts" "src/render.ts" \
    "tests/messages.test.mjs" "tests/render.test.mjs" "tests/ui.spec.mjs" \
    "scripts/browser-check.mjs" "package.json"

  grep -qF "$expected_headline" "$SPRINT_REPO/src/messages.ts" || fail "messages.ts missing expected headline"
  grep -qF "$expected_status" "$SPRINT_REPO/src/messages.ts" || fail "messages.ts missing expected status"
  grep -qF "$expected_cta" "$SPRINT_REPO/src/messages.ts" || fail "messages.ts missing expected cta"
  grep -qF "$expected_state" "$SPRINT_REPO/src/messages.ts" || fail "messages.ts missing expected state"
  grep -q "data-state" "$SPRINT_REPO/src/render.ts" || fail "render.ts missing data-state attribute assignment"
  grep -q "title" "$SPRINT_REPO/src/render.ts" || fail "render.ts missing title attribute assignment"

  assert_runtime_ui_contract "$SPRINT_REPO" "$expected_headline" "$expected_status" "$expected_cta" "$expected_state" "$WORK_DIR/runtime-sprint.log"
  ./ralph-sprint-commit.sh > "$WORK_DIR/sprint-commit-sprint.log" 2>&1
)

runtime_loop_log="$(resolve_latest_runtime_sprint_log "$SPRINT_REPO")" || fail "Could not resolve Ralph runtime sprint log"

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
assert_contains "$runtime_loop_log" "Story S-001 COMPLETE"
assert_contains "$runtime_loop_log" "Story S-002 COMPLETE"
assert_contains "$runtime_loop_log" "Story S-003 COMPLETE"
assert_contains "$WORK_DIR/test-sprint.log" "test ok"
assert_contains "$WORK_DIR/runtime-sprint.log" "browser ok: $expected_headline \| $expected_status \| $expected_cta \| $expected_state"
assert_contains "$WORK_DIR/sprint-commit-sprint.log" "Sprint regression: PASS"
assert_contains "$WORK_DIR/sprint-commit-sprint.log" "Deleted source sprint branch:"

echo "[worst-ui] running ralph-verify --full post-commit"
(
  cd "$SPRINT_REPO/scripts/ralph"
  ./ralph-verify.sh --full > "$WORK_DIR/verify-full.log" 2>&1
)
assert_contains "$WORK_DIR/verify-full.log" "full verification passed"

loop_tokens="$(extract_tokens_from_log "$runtime_loop_log")"
stories_completed="$(extract_story_complete_count_from_log "$runtime_loop_log")"
retry_count="$(awk '/Retrying\.\.\./{c++} END{print c+0}' "$WORK_DIR/loop.log" 2>/dev/null || echo 0)"
benchmark_set_execution_tokens "$loop_tokens"
benchmark_set_story_cycles "$stories_completed"
benchmark_set_stories "$stories_completed"
benchmark_set_retries "$retry_count"

echo "[worst-ui] token summary: loop=$loop_tokens total=$loop_tokens"
echo "[worst-ui] stories completed: $stories_completed"
echo "[worst-ui] PASS: worst-case UI smoke completed"
