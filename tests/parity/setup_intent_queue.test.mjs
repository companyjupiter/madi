import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SetupIntentQueue } from '../../apps/desktop/src/SetupIntentQueue.ts';

test('file admission waits for every earlier preference commit', async () => {
  const commits = [Promise.withResolvers(), Promise.withResolvers()];
  const observed = [];
  let language = 'Auto';
  let overlap = true;
  const queue = new SetupIntentQueue(reason => { throw reason; });
  void queue.enqueue(async () => { await commits[0].promise; language = 'English'; });
  void queue.enqueue(async () => { await commits[1].promise; overlap = false; });
  const admitted = queue.enqueue(() => { observed.push({ language, overlap }); });
  commits[1].resolve();
  await Promise.resolve();
  assert.deepEqual(observed, []);
  commits[0].resolve();
  await admitted;
  assert.deepEqual(observed, [{ language: 'English', overlap: false }]);
});

test('failed commit cancels queued admission and later intents, including picker cleanup', async () => {
  const commit = Promise.withResolvers();
  const errors = [];
  const effects = [];
  const failure = new Error('disk commit failed');
  const queue = new SetupIntentQueue(reason => errors.push(reason));
  void queue.enqueue(() => commit.promise);
  const pick = queue.enqueue(() => { effects.push('picker'); }).finally(() => { effects.push('picker cleanup'); });
  const start = queue.enqueue(() => { effects.push('start'); });
  commit.reject(failure);
  await Promise.all([pick, start]);
  await queue.enqueue(() => { effects.push('later start'); });
  assert.deepEqual(errors, [failure]);
  assert.deepEqual(effects, ['picker cleanup']);
});
