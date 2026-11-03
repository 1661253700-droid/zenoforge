import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

// Execute the real shared functions and the actual advisor dispatch block,
// while replacing only model/remote side effects. No paid call or live HOME
// is used.
//
// Exercise the current advisor dispatch and polling contract with isolated local fixtures.
const here = dirname(fileURLToPath(import.meta.url));
const lib = join(here, 'lib.sh');
const advisorCore = join(here, 'advisor-core.sh');
// Load real shared helpers with isolated state and replace only model/remote
// effects. The full shell suites cover production entrypoint initialization.
const advisor = readFileSync(join(here, 'run-advisor.sh'), 'utf8');
const begin = advisor.indexOf('\nPENDING_VERDICT_RESULT="$(advisor_resume_check');
const end = advisor.indexOf('\nVERDICT="$(echo "$RESULT"', begin);
assert.ok(begin >= 0 && end > begin, 'the executable advisor dispatch block must be found');
const dispatchBlock = advisor.slice(begin, end);
const testJqHome = process.env.ADVISOR_CONVERGENCE_JQ_HOME || process.env.HOME;
const testJqBin = process.env.ADVISOR_CONVERGENCE_JQ_BIN || (() => {
  const testJq = spawnSync('sh', ['-c', 'command -v jq'], { encoding: 'utf8' });
  assert.equal(testJq.status, 0, testJq.stderr);
  return testJq.stdout.trim();
})();

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'zf-advisor-contract-'));
  const repo = spawnSync('git', ['init', '--quiet', root], { encoding: 'utf8' });
  assert.equal(repo.status, 0, repo.stderr);
  const fakeBin = join(root, 'fake-bin');
  mkdirSync(fakeBin, { recursive: true });
  writeFileSync(join(fakeBin, 'jq'), [
    '#!/usr/bin/env bash',
    'HOME="$ADVISOR_CONVERGENCE_JQ_HOME" LD_LIBRARY_PATH="$ADVISOR_CONVERGENCE_JQ_HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$ADVISOR_CONVERGENCE_JQ_BIN" "$@"',
    '',
  ].join('\n'));
  chmodSync(join(fakeBin, 'jq'), 0o755);
  const env = { ...process.env, LC_ALL: 'C', HOME: root, AGENT_HOME: join(root, 'agent'), AGENT_DRY_RUN: '0', ZF_REPO: 'fixture/repo', ZF_REPO_DIR: root, ZF_GCLOUD_BIN: '/nonexistent/gcloud', PATH: `${fakeBin}:${process.env.PATH}`, ADVISOR_CONVERGENCE_JQ_HOME: testJqHome, ADVISOR_CONVERGENCE_JQ_BIN: testJqBin, ADVISOR_CONVERGENCE_LIB: lib, ADVISOR_CONVERGENCE_ADVISOR_CORE: advisorCore, ADVISOR_CONVERGENCE_ADVISOR_CONFIG: join(here, 'advisor-config.sh') };
  mkdirSync(join(root, 'agent/state'), { recursive: true });
  writeFileSync(join(root, 'agent/state/90042.json'), '{"attempts":2,"advisor_ruled_at":"prior"}');
  const policy = JSON.parse(readFileSync(join(here, 'model-policy.default.json'), 'utf8'));
  policy.roles.advisor.disabled = false; // This fixture exercises the advisor path even with the generic engine policy.
  policy.switches['roadmap-order'] = false; // This fixture tests advisor transitions, not tree placement.
  writeFileSync(join(root, 'agent/model-policy.json'), JSON.stringify(policy));
  const functions = join(root, 'functions.sh');
  writeFileSync(functions, [
    'source "$ADVISOR_CONVERGENCE_LIB"',
    'source "$ADVISOR_CONVERGENCE_ADVISOR_CORE"',
    'source "$ADVISOR_CONVERGENCE_ADVISOR_CONFIG"',
    'gh() {',
    '  # Lane routing reads live labels first (7bc93004); the fixture issue is a product ticket.',
    '  if [ "$1" = api ] && [[ "$*" == *"/issues/90042/comments?"* ]]; then printf \'%s\\n\' \'[[]]\'; return 0; fi',
    '  if [ "$*" = "issue view 90042 --repo fixture/repo --json number,labels" ]; then printf \'%s\\n\' \'{"number":90042,"labels":[]}\'; return 0; fi',
    '  if [ "$*" = "issue view 90042 --repo fixture/repo --json labels -q .labels[].name" ]; then return 0; fi',
    '  [ "$*" = "issue view 90042 --repo fixture/repo --json state,labels" ] || { echo "unexpected gh call: $*" >&2; return 64; }',
    "  printf '%s\\n' '{\"state\":\"OPEN\",\"labels\":[]}'",
    '}',
    'record_advisor_lease_decision() { :; }',
    '',
  ].join('\n'));
  return { root, env, functions, close: () => rmSync(root, { recursive: true, force: true }) };
}
function run(f, body, extra = {}) {
  return spawnSync('bash', ['-c', `set -euo pipefail\nsource "$1"\n${body}`, 'fixture', f.functions, here], {
    // Bound hung fixtures; shared-host cold startup exceeded 27s at load 82, without a protocol failure.
    env: { ...f.env, ...extra }, encoding: 'utf8', timeout: 60000,
  });
}
function text(f, relative) {
  const p = join(f.root, relative);
  return existsSync(p) ? readFileSync(p, 'utf8') : '';
}


export { fixture, run, text, dispatchBlock, here };
