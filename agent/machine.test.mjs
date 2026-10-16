import assert from 'node:assert/strict';
import { test } from 'node:test';
import { step } from './machine.mjs';

const start = (land = true, attempts = 2) => step({ input: { land, attempts } });
// Every transition crosses the same JSON boundary as the Nushell host.
const send = (run, event) => step(JSON.parse(JSON.stringify({ snapshot: run.snapshot, event })));
const published = (run, head = 'h1') => send(run, { type: 'PUBLISHED', head });
function queued(attempts = 2) {
  let run = published(start(true, attempts));
  run = send(run, { type: 'LANDABLE' });
  return send(run, { type: 'QUEUED' });
}
function cleared(run, head = 'h1') {
  run = send(run, { type: 'REFRESHED', fresh: true });
  return send(run, { type: 'CLEARED', head });
}

test('dispatch stops before any landing operation', () => {
  const run = published(start(false));
  assert.equal(run.state, 'dispatched');
  assert.equal(run.done, true);
  assert.throws(() => send(run, { type: 'LANDABLE' }), /not legal/);
});

test('land requires landability, the queue, and clearance of the published head', () => {
  let run = published(start());
  for (const event of [
    { type: 'QUEUED' }, { type: 'CLEARED', head: 'h1' },
    { type: 'ADVANCED', head: 'h1', landed: true },
  ]) assert.throws(() => send(run, event), /not legal/);
  run = send(run, { type: 'LANDABLE' });
  run = send(run, { type: 'QUEUED' });
  run = send(run, { type: 'REFRESHED', fresh: true });
  assert.throws(() => send(run, { type: 'CLEARED', head: 'old' }), /not legal/);
  run = send(run, { type: 'CLEARED', head: 'h1' });
  assert.throws(() => send(run, { type: 'ADVANCED', head: 'old', landed: true }), /not legal/);
  run = send(run, { type: 'ADVANCED', head: 'h1', landed: true });
  assert.equal(run.state, 'landed');
});

test('trunk movement requires republishing, reproving, and fresh clearance', () => {
  let run = send(queued(), { type: 'REFRESHED', fresh: false });
  assert.equal(run.state, 'republishing');
  assert.equal(run.context.proven, 'h1');
  run = published(run, 'h2');
  assert.equal(run.state, 'proving');
  assert.throws(() => send(run, { type: 'CLEARED', head: 'h2' }), /not legal/);
  run = send(run, { type: 'LANDABLE' });
  assert.throws(() => send(run, { type: 'CLEARED', head: 'h1' }), /not legal/);
  run = send(run, { type: 'CLEARED', head: 'h2' });
  assert.equal(send(run, { type: 'ADVANCED', head: 'h2', landed: true }).state, 'landed');
});

test('only an advance race retries, with a hard attempt limit', () => {
  let run = cleared(queued(2));
  run = send(run, { type: 'ADVANCED', head: 'h1', landed: false });
  assert.equal(run.state, 'refreshing');
  assert.equal(run.context.attempt, 2);
  assert.throws(() => send(run, { type: 'ADVANCED', head: 'h1', landed: true }), /not legal/);
  run = cleared(run);
  run = send(run, { type: 'ADVANCED', head: 'h1', landed: false });
  assert.equal(run.state, 'exhausted');
  assert.equal(run.done, true);
});

test('a failed effect stops; it cannot clear, retry, or land', () => {
  const run = send(queued(), { type: 'FAILED', message: 'conflict' });
  assert.equal(run.state, 'blocked');
  assert.equal(run.context.error, 'conflict');
  assert.throws(() => send(run, { type: 'REFRESHED', fresh: true }), /not legal/);
});

test('invalid input and malformed events fail at the host boundary', () => {
  for (const attempts of [0, -1, 1.5]) assert.throws(() => start(true, attempts));
  assert.throws(() => published(start(), ''), /small/);
  assert.throws(() => send(start(), { type: 'UNKNOWN' }), /Unknown event/);
  assert.throws(() => step({ snapshot: start().snapshot }), /requires an event/);
});
