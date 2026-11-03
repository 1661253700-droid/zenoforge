import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

import { fixture, run, text, dispatchBlock, here } from './test-advisor-convergence-helpers.mjs';

test('fixture keeps jq usable after HOME isolation', () => {
  const f = fixture();
  try {
    const r = run(f, 'jq -n 0');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), '0');
  } finally { f.close(); }
});

for (const [name, output, status, expected] of [
  ['valid zero usage is data', '{"is_error":false,"tokens_used":0}', '0', 'none'],
  ['a successful semantic quota mention is not an outage', '{"is_error":false,"result":"explain quota"}', '0', 'none'],
  ['structured rate limit', '{"is_error":true,"api_error_status":429}', '0', 'quota'],
  ['CLI usage refusal', "ERROR: You've hit your usage limit.", '1', 'quota'],
  ['provider 503', '{"is_error":true,"api_error_status":503}', '0', 'transient'],
  ['timeout status', '', '124', 'transient'],
  ['configuration error is not capacity', '{"is_error":true,"api_error_status":400}', '0', 'execution'],
  ['structured configuration error outranks incidental quota text', '{"is_error":true,"api_error_status":400,"result":"invalid quota field"}', '1', 'execution'],
  ['unauthorized is not capacity', '{"is_error":true,"api_error_status":401}', '1', 'execution'],
  ['string error flag cannot become a success', '{"is_error":"true"}', '0', 'execution'],
  ['zero as entire response is invalid', '0', '0', 'malformed'],
  ['null as entire response is invalid', 'null', '0', 'malformed'],
  ['empty response is not success', '', '0', 'malformed'],
]) {
  test(name, () => {
    const f = fixture();
    try {
      const r = run(f, 'model_call_failure_kind "$REPLY" "$EXIT_STATUS"', { REPLY: output, EXIT_STATUS: status });
      assert.equal(r.status, 0, r.stderr);
      assert.equal(r.stdout.trim(), expected);
    } finally { f.close(); }
  });
}

for (const attempts of [0, 3, 4, 9]) {
  test(`shared admission enforces cap at ${attempts} attempts without caller guards`, () => {
    const f = fixture();
    try {
      writeFileSync(join(f.root, 'agent/state/90042.json'), JSON.stringify({ attempts, advisor_ruled_at: 'prior' }));
      const r = run(f, `
loop_break_check() { LOOP_BREAK_ESCALATED=0; }
guarded_write() { echo label >> "$HOME/actions"; }
record_run_decision() { echo decision >> "$HOME/actions"; }
conclude_run() { echo conclude >> "$HOME/actions"; }
route_to_advisor 90042
`);
      assert.equal(r.status, 0, r.stderr);
      const state = JSON.parse(text(f, 'agent/state/90042.json'));
      assert.equal(state.attempts, attempts, 'routing must not reset attempts');
      assert.equal(text(f, 'actions').includes('label'), attempts < 4);
      assert.equal(text(f, 'actions').includes('conclude'), attempts >= 4);
      assert.equal('advisor_ruled_at' in state, attempts >= 4, 'exhausted episode is not reopened');
    } finally { f.close(); }
  });
}

test('failed conclusion cannot move the issue or clear the previous ruling', () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, 'agent/state/90042.json'), '{"attempts":4,"advisor_ruled_at":"prior"}');
    const r = run(f, `
loop_break_check() { echo forbidden >> "$HOME/actions"; }
guarded_write() { echo forbidden >> "$HOME/actions"; }
record_run_decision() { return 0; }
conclude_run() { echo reached > "$HOME/conclusion-reached"; return 1; }
route_to_advisor 90042
`);
    assert.equal(r.status, 1);
    assert.equal(text(f, 'conclusion-reached').trim(), 'reached', 'a setup failure cannot satisfy this negative test');
    assert.equal(text(f, 'actions'), '');
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).attempts, 4);
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).advisor_ruled_at, 'prior');
  } finally { f.close(); }
});

for (const failure of ['state', 'edit', 'comment']) {
  test(`real conclusion stops at ${failure} failure even inside a shell conditional`, () => {
    const f = fixture();
    try {
      writeFileSync(join(f.root, 'agent/state/90042.json'), JSON.stringify({ attempts: 4, advisor_ruled_at: 'prior', acceptor: 'none', run: { evidence: { pr_number: 42 } } }));
      const r = run(f, `
ALL_STATE_LABELS=(needs-advisor concluded)
BOT_DISCLAIMER=fixture
if [ "$FAIL_AT" = state ]; then
  state_merge() { echo reached > "$HOME/state-failure"; return 1; }
fi
ensure_state_labels() { :; }
guarded_write() {
  echo "$3" >> "$HOME/actions"
  [ "$3" != "$FAIL_AT" ]
}
if conclude_run 90042 merged "fixture"; then echo success; else echo failed; fi
`, { FAIL_AT: failure });
      assert.equal(r.status, 0, r.stderr);
      assert.equal(r.stdout.trim(), 'failed');
      assert.equal(text(f, 'actions').trim(), { state: '', edit: 'edit', comment: 'edit\ncomment' }[failure]);
      if (failure === 'state') assert.equal(text(f, 'state-failure').trim(), 'reached');
      const state = JSON.parse(text(f, 'agent/state/90042.json'));
      assert.equal(state.attempts, 4, 'failed conclusion must preserve attempts');
      assert.equal(state.advisor_ruled_at, 'prior', 'failed conclusion must preserve prior advisor ruling');
      assert.equal(state.closed_by_pipeline, undefined);
    } finally { f.close(); }
  });
}

test('invalid attempt state stands aside: admission neither concludes nor refuses, the caller guard owns the failure', () => {
  const f = fixture();
  try {
    const r = run(f, 'state_attempts() { echo broken; }; advisor_retry_admission 90042; echo "admission=$?"');
    assert.equal(r.status, 0);
    assert.match(r.stdout, /admission=0/);
    assert.doesNotMatch(r.stdout, /admission=10/);
    assert.doesNotMatch(r.stderr, /Advisor retry admission exhausted/);
    assert.doesNotMatch(r.stderr, /No further advisor episode was admitted/);
  } finally { f.close(); }
});
