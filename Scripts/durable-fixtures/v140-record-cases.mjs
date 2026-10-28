// Run the tag's Harness and store its records without changing upstream source.
import { readFile, writeFile, mkdtemp, copyFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { upstreamTag } from './mirror.mjs';
import { replaySqlite, readRecordedCalls, compareRecordedReads, jsonResult } from './sqlite-fixtures.mjs';
import { replayJsonl, compareJsonl } from './jsonl-fixtures.mjs';

const fixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));

async function eventually(check, label) {
  for (let turn = 0; turn < 2000; turn++) {
    if (await check()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  throw new Error(`Lifecycle condition was not reached: ${label}`);
}

export async function generateLifecycleFixtures(source, { check = false } = {}) {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineTask } = await source.import('packages/durable/src/tasks.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage } = await source.import('packages/ai/src/providers/faux.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  // Faux uses these host inputs for timestamps and deferred IDs. The source stays unchanged.
  const originalDateNow = Date.now, originalRandom = Math.random, originalGetRandomValues = crypto.getRandomValues;
  Date.now = () => 1700000000000;
  Math.random = () => 0.5;
  crypto.getRandomValues = value => value.fill(0x42);
  const raw = new MemoryStorage();
  const batches = [], cases = {}, checkpoints = [], reports = [];
  const commit = raw.commit.bind(raw);
  raw.commit = async (writes, ctx) => {
    const seq = await commit(writes, ctx);
    batches.push({ seq, writes: jsonResult(writes) });
    return seq;
  };
  const observe = async (name, point) => {
    const record = jsonResult(await raw.task(cases[name].taskId, context));
    const seq = batches.at(-1).seq;
    cases[name].snapshots[point] = { seq, record };
    let checkpoint = checkpoints.find(item => item.seq === seq);
    if (!checkpoint) checkpoints.push(checkpoint = { seq, reads: [] });
    checkpoint.reads.push({ method: 'task', arguments: [record.id], result: record });
    return record;
  };
  const addCase = (name, taskId, metadata = {}) => { cases[name] = { taskId, ...metadata, snapshots: {} }; };
  const block = signal => new Promise(resolve => {
    if (signal.aborted) resolve();
    else signal.addEventListener('abort', resolve, { once: true });
  });
  const Nap = defineTask({ name: 'fixture.nap', version: 1, initial: () => ({ phase: 'start' }), phases: {
    start: async (task, runtime, ctx) => runtime.sleepUntil(runtime.now() + task.input.delay, { phase: 'after', slept: task.input.delay }, ctx),
    after: async (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: runtime.now() } }), ctx),
  }, abort: async (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted', reason: 'fixture' } }), ctx) });
  let loopStarts = 0, stepStarts = 0, progress = false;
  const Loop = defineTask({ name: 'fixture.crash-loop', version: 1, initial: () => ({ phase: 'run' }), phases: {
    run: async (_task, runtime) => { loopStarts++; await block(runtime.signal); },
  }, abort: async () => {} });
  const Steps = defineTask({ name: 'fixture.steps', version: 1, initial: () => ({ phase: 'one' }), phases: {
    one: async (_task, runtime, ctx) => {
      stepStarts++;
      if (!progress) await block(runtime.signal);
      else await runtime.commit(() => ({ status: 'running', checkpoint: { phase: 'two' } }), ctx);
    },
    two: async (_task, runtime) => { stepStarts++; await block(runtime.signal); },
  }, abort: async () => {} });
  const faux = fauxProvider({ api: 'fixture-faux', deferred: { pollAfterMs: 60000 }, tokenSize: { min: 3, max: 3 } });
  const models = createModels();
  models.setProvider(faux.provider);
  const settings = { restartLimit: 3, retry: { enabled: true, maxRetries: 2, baseDelayMs: 60000 } };
  let opened;
  const open = async (includeSteps = true) => {
    let dead = false;
    // A killed facade admits no further storage operation. A close leaves raw open for observation.
    const storage = new Proxy(raw, { get(target, property) {
      if (property === 'close') return async () => {};
      const value = Reflect.get(target, property, target);
      return typeof value !== 'function' ? value : (...args) => dead ? new Promise(() => {}) : value.apply(target, args);
    } });
    const registry = createRegistry();
    registry.install({ name: 'fixture', tasks: [Nap, Loop, ...(includeSteps ? [Steps] : [])] });
    const harness = await Harness.open(storage, { models, registry, settings, now: () => 1000,
      onWake: () => {}, onReport: (_error, info) => reports.push(jsonResult(info)), setTimer: () => undefined }, context);
    opened = { harness, kill: () => { dead = true; } };
    return opened;
  };
  const temporary = await mkdtemp(join(tmpdir(), 'piswift-lifecycle-v140-'));
  try {
    await open();
    let root = await opened.harness.root(context);
    const make = async (name, token, input, options = {}) => {
      const taskId = await root.commit(tx => tx.createTask(token, input, { ownership: { kind: 'conversation' }, ...options }), context);
      addCase(name, taskId);
      return taskId;
    };
    await make('integerSleep', Nap, { delay: 1000 });
    await make('fractionalSleep', Nap, { delay: 0.125 });
    await make('parked', Loop, null);
    await make('retried', Loop, null);
    await make('progress', Steps, null);
    const carrier = JSON.parse('{"traceparent":"opaque-parent","vendor":"a,b=opaque","__proto__":"kept","é":"composed","é":"decomposed"}');
    await make('carriers', Nap, { delay: 2000 }, { trace: carrier, links: [carrier, {}, { vendor: 'second' }] });
    opened.harness.resume();
    await eventually(async () => loopStarts === 2 && stepStarts === 1 && (await raw.task(cases.carriers.taskId, context)).state.status === 'sleeping', 'first run');
    await observe('integerSleep', 'sleeping');
    await observe('fractionalSleep', 'sleeping');
    await observe('carriers', 'sleeping');
    opened.kill();
    await open();
    await observe('progress', 'cutoff');
    progress = true;
    opened.harness.resume();
    await eventually(() => loopStarts === 4 && stepStarts === 3, 'progress to phase two');
    await observe('progress', 'progressed');
    opened.kill();
    await open(false);
    await observe('progress', 'cutoffAfterProgress');
    opened.harness.resume();
    await eventually(() => loopStarts === 6, 'third run');
    opened.kill();
    await open(false);
    await observe('parked', 'parked');
    await observe('retried', 'parked');
    // Capture the retry transaction's write before the scheduler can run it again.
    const retryStart = batches.length;
    await opened.harness.retryTask(cases.retried.taskId, context);
    const retryBatch = batches.slice(retryStart).find(batch => batch.writes.some(write => write.type === 'task' && write.value.id === cases.retried.taskId && write.value.state.status === 'pending'));
    if (!retryBatch) throw new Error('retryTask did not write a pending task');
    const retried = retryBatch.writes.find(write => write.type === 'task' && write.value.id === cases.retried.taskId).value;
    cases.retried.snapshots.cleared = { seq: retryBatch.seq, record: retried };
    checkpoints.push({ seq: retryBatch.seq, reads: [{ method: 'task', arguments: [retried.id], result: retried }] });
    await eventually(() => loopStarts === 7, 'retried invocation');
    root = await opened.harness.root(context);
    await make('cleanClose', Loop, null);
    await eventually(() => loopStarts === 8, 'clean-close invocation');

    const agent = { model: { provider: 'faux', modelId: 'faux-1' } };
    const chat = async () => opened.harness.createConversation({ ownership: { kind: 'ownerless' }, agent }, context);
    const run = async (name, conversation, response) => {
      faux.setResponses([response]);
      const submission = await conversation.submit({ type: 'input', content: 'hi' }, context);
      let taskId;
      await eventually(async () => {
        const live = await opened.harness.snapshot(LiveDoc, conversation.id, context);
        taskId = live?.run?.taskId;
        return taskId !== undefined && (await raw.task(taskId, context)).state.status === 'sleeping';
      }, name);
      addCase(name, taskId, { conversationId: conversation.id, submissionId: submission.id });
      await observe(name, 'sleeping');
    };
    const failure = () => fauxAssistantMessage([], { stopReason: 'error', errorMessage: '503 Service Unavailable' });
    await run('retrySleep', await chat(), failure());
    settings.stream = { deferred: true };
    await run('pollSleep', await chat(), fauxAssistantMessage('deferred answer'));
    settings.stream = { deferred: false };
    await run('legacyRunningRetry', await chat(), failure());
    await opened.harness.close(context);
    await observe('cleanClose', 'closed');
    await observe('retried', 'closed');
    const legacy = await raw.task(cases.legacyRunningRetry.taskId, context);
    // Match harness-generation-recovery.test.ts:212-258: an older host kept retry running during backoff.
    // This is direct v1.3-style record construction from v1.4 output, not a v1.3 producer fixture.
    await raw.commit([{ type: 'task', value: { ...legacy, state: { status: 'running', checkpoint: legacy.state.checkpoint } } }], context);
    await observe('legacyRunningRetry', 'legacyRunning');
    // Admission through the tag's transaction retains opaque submission carriers as well.
    const { createSession } = await source.import('packages/durable/src/session/session.ts');
    const session = createSession(new Proxy(raw, { get(target, property) {
      if (property === 'close') return async () => {};
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    } }), { now: () => 1000, setTimer: () => undefined });
    cases.carriers.submissionIds = await session.commit(async tx => {
      const ids = [];
      for (const type of ['input', 'write']) ids.push((await tx.createSubmission({ type, status: 'queued', conversationId: root.id, trace: carrier, requestId: `carrier-${type}` })).id);
      return ids;
    }, context);
    await session.close(context);
    const reads = [];
    const read = async (method, ...args) => {
      const result = jsonResult(await raw[method](...args.map(value => value === null ? undefined : value), context));
      reads.push({ method, arguments: args, result });
      return reads.length - 1;
    };
    for (const [name, value] of Object.entries(cases)) {
      value.readIndex = await read('task', value.taskId);
      value.final = reads[value.readIndex].result;
      for (const id of value.submissionIds ?? []) await read('submission', id);
    }
    for (const order of ['ascending', 'descending']) {
      await read('scanTasks', { order }, 100, null);
      for (const status of ['sleeping', 'pending', 'running']) await read('scanTasks', { status, order }, 100, null);
    }
    for (const value of Object.values(cases).filter(value => value.submissionId !== undefined)) {
      await read('submission', value.submissionId);
      const documents = await raw.scanDocuments({ scope: { kind: 'conversation', conversationId: value.conversationId }, at: 'current' }, 100, undefined, context);
      for (const document of documents.items) await read('document', document.id, 'current');
    }
    // A snapshot taken after a task read can share a sequence with another observation.
    const merged = new Map();
    for (const checkpoint of checkpoints) {
      const prior = merged.get(checkpoint.seq) ?? [];
      for (const read of checkpoint.reads) if (!prior.some(item => item.arguments[0] === read.arguments[0])) prior.push(read);
      merged.set(checkpoint.seq, prior);
    }
    const checkpointList = [...merged].sort(([a], [b]) => a - b).map(([seq, reads]) => ({ seq, reads }));
    // Keep the selected task's conversation and the root. Each seed is replayed below by upstream storage.
    // Sequence numbers are new because empty filtered batches are omitted. Task record fields are unchanged.
    const seedPoints = { integerSleep: 'sleeping', fractionalSleep: 'sleeping', parked: 'parked', retried: 'cleared',
      progress: 'cutoffAfterProgress', carriers: 'sleeping', cleanClose: 'closed', retrySleep: 'sleeping',
      pollSleep: 'sleeping', legacyRunningRetry: 'legacyRunning' };
    for (const [name, value] of Object.entries(cases)) {
      const snapshot = value.snapshots[seedPoints[name]];
      const conversationId = snapshot.record.conversationId;
      const keptDocuments = new Set();
      const keep = write => {
        if (write.type === 'task') return write.value.id === value.taskId;
        if (write.type === 'conversation') return [1, conversationId].includes(write.value.id);
        if (write.type === 'entry' || write.type === 'submission') return write.value.conversationId === conversationId;
        if (write.type === 'document.create' || write.type === 'document.copy') {
          const scope = write.record.scope;
          const kept = scope.kind === 'session' || (scope.kind === 'task' ? scope.taskId === value.taskId : [1, conversationId].includes(scope.conversationId));
          if (kept) keptDocuments.add(write.record.id);
          return kept;
        }
        return keptDocuments.has(write.id);
      };
      value.seedPoint = seedPoints[name];
      value.seedSeq = snapshot.seq;
      value.seedBatches = batches.filter(batch => batch.seq <= snapshot.seq).map(batch => ({ writes: batch.writes.filter(keep) }))
        .filter(batch => batch.writes.length !== 0).map((batch, index) => ({ seq: index + 1, ...batch }));
      value.seedReads = [{ method: 'task', arguments: [value.taskId], result: snapshot.record }];
      const seed = new MemoryStorage();
      try {
        for (const batch of value.seedBatches) {
          if (await seed.commit(batch.writes, context) !== batch.seq) throw new Error(`Seed sequence differs: ${name}`);
        }
        compareRecordedReads(await readRecordedCalls(seed, value.seedReads, context), value.seedReads, `seed/${name}`);
        const dueClock = { integerSleep: 2000, fractionalSleep: 1001, carriers: 3000 }[name];
        if (dueClock !== undefined) {
          const registry = createRegistry();
          registry.install({ name: 'fixture', tasks: [Nap] });
          const dueHarness = await Harness.open(seed, { models, registry, now: () => dueClock,
            onWake: () => {}, setTimer: () => undefined }, context);
          dueHarness.resume();
          await dueHarness.waitForTask(value.taskId, context);
          value.dueClock = dueClock;
          value.terminalDue = jsonResult(await seed.task(value.taskId, context));
          await dueHarness.close(context);
        }
      } finally { await seed.close(context); }
    }
    const fixture = { tag: upstreamTag, provenance: {
      source: 'unmodified v1.4.0 Harness, Session, MemoryStorage, FauxProvider, SQLite, and JSONL storage',
      clock: 1000, dateNow: 1700000000000, random: 0.5, cryptoRandomByte: 66,
      crash: 'storage facade blocks all later operations after kill; no clean-close writes',
      legacy: 'direct v1.3-style running retry construction from v1.4 sleeping output, as in upstream harness-generation-recovery.test.ts:212-258; not a v1.3 producer',
      seeds: 'isolated original writes through the selected snapshot; keep its task, its conversation, root conversation and root documents; omit empty batches and number remaining batches from 1; replay and read with upstream MemoryStorage',
      upstreamTests: ['harness-sleep.test.ts:30-138', 'harness-blocked.test.ts:135-199,368-408', 'harness-generation-recovery.test.ts:165-285'],
    }, batches, reads, cases, checkpoints: checkpointList };
    const recordPath = join(fixtures, 'lifecycle-records-v140.json');
    const text = JSON.stringify(fixture, null, 2) + '\n';
    if (check) {
      if (await readFile(recordPath, 'utf8') !== text) {
        await writeFile(fileURLToPath(new URL('../../.build/D4-lifecycle-actual.json', import.meta.url)), text);
        throw new Error('Lifecycle fixtures differ; actual output is in .build/D4-lifecycle-actual.json');
      }
    } else await writeFile(recordPath, text);
    const sqlite = join(temporary, 'generated.sqlite');
    await replaySqlite(source, sqlite, batches, reads, context);
    const sqliteFixture = join(fixtures, 'lifecycle-upstream-v140.sqlite');
    if (check) {
      const checked = join(temporary, 'checked.sqlite');
      await copyFile(sqliteFixture, checked);
      const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
      const stored = await openNodeSqliteStorage(checked);
      try { compareRecordedReads(await readRecordedCalls(stored, reads, context), reads); }
      finally { await stored.close(context); }
    } else await copyFile(sqlite, sqliteFixture);
    const jsonl = join(temporary, 'jsonl');
    await replayJsonl(source, jsonl, batches, reads, context);
    const jsonlFixture = join(fixtures, 'lifecycle-upstream-jsonl-v140');
    if (check) {
      const checked = join(temporary, 'checked-jsonl');
      await cp(jsonlFixture, checked, { recursive: true });
      await compareJsonl(source, checked, reads, context);
    } else {
      await rm(jsonlFixture, { recursive: true, force: true });
      await cp(jsonl, jsonlFixture, { recursive: true });
    }
    console.log(`Lifecycle fixtures ${check ? 'match' : 'written'}: ${batches.length} batches, ${reads.length} reads, ${Object.keys(cases).length} cases, ${checkpointList.length} checkpoints.`);
  } finally {
    Date.now = originalDateNow;
    Math.random = originalRandom;
    crypto.getRandomValues = originalGetRandomValues;
    await raw.close(context);
    await rm(temporary, { recursive: true, force: true });
  }
}
