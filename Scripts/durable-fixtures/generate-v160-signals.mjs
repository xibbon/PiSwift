// Run each signal case on the unmodified tag. Compare those stored records
// with the records from the files that both languages open and change.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cp, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { mirrorV160, upstreamTag } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  if (child.error) throw child.error;
  process.exit(child.status ?? 1);
}
if (!process.argv.includes('--check')) throw new Error('Use --check to run the signal cases on temporary files');
const root = fileURLToPath(new URL('../../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'piswift-v160-signals-'));
const key = 'answer';
const payload = { text: 'yes' };
const start = 1_000;
const deadline = 2_000;
let source;
try {
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context, withAbortSignal } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineExtension, defineTask } = await source.import('packages/durable/src/index.ts');
  const { defineSignal } = await source.import('packages/durable/src/signals.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { obj, str } = await source.import('packages/schema/src/index.ts');

  const answer = defineSignal({ name: 'fixture.answer', version: 1, schema: obj({ text: str() }) });
  const ask = defineTask({
    name: 'fixture.ask',
    version: 1,
    initial: () => ({ phase: 'ask' }),
    phases: {
      ask: (task, runtime, ctx) => runtime.commit(() => ({
        status: 'sleeping', checkpoint: { phase: 'answered' }, signals: [answer.key(key)],
        ...(task.input.until === undefined ? {} : { until: task.input.until }),
      }), ctx),
      answered: async (task, runtime, ctx) => {
        const signal = await runtime.readSignal(answer, key, ctx);
        const record = await runtime.getTask(runtime.taskId, ctx);
        const memo = task.input.until === undefined ? { version: 1, consumed: true, value: payload } : { expired: true };
        assert.deepEqual(record.memos, { [`pi.signal.${answer.name}/${key}`]: memo });
        await runtime.commit(() => ({
          status: 'terminal', outcome: { status: 'completed', result: { wake: task.state.wake, signal } },
        }), ctx);
      },
    },
    abort: (_task, runtime, ctx) => runtime.commit(() => ({
      status: 'terminal', outcome: { status: 'aborted', reason: 'fixture' },
    }), ctx),
  });
  const open = item => item.backend === 'sqlite'
    ? openNodeSqliteStorage(item.path) : openNodeJsonlStorage(item.path, context);
  const readTasks = async storage => (await storage.scanTasks({ kind: ask.definition.name }, 10, undefined, context)).items;
  function outcome(item) {
    return item.scenario === 'expiry'
      ? { wake: { reason: 'expired' }, signal: { expired: true } }
      : { wake: { reason: 'signal', ...answer.key(key) }, signal: { value: payload } };
  }

  async function taggedStep(item) {
    const registry = createRegistry();
    registry.install(defineExtension({ name: 'fixture.signals', tasks: [ask] }));
    const store = await open(item);
    const reports = [];
    let harness;
    let clock = start;
    try {
      harness = await Harness.open(store, {
        registry, models: createModels(), now: () => clock,
        onWake: () => {}, onReport: report => reports.push(report.error),
      }, context);
      if (item.step === 'seed') {
        const rootConversation = await harness.root(context);
        const input = item.scenario === 'expiry' ? { until: deadline } : {};
        const id = await rootConversation.commit(tx => tx.createTask(ask, input, { ownership: { kind: 'conversation' } }), context);
        if (item.scenario === 'early-tag') {
          assert.equal(await harness.commit(tx => tx.signal(id, answer, key, payload), context), 'delivered');
          assert.equal((await harness.getTask(id, context)).state.status, 'pending');
        } else {
          harness.resume();
          const end = performance.now() + 10_000;
          for (;;) {
            const state = (await harness.getTask(id, context)).state;
            if (state.status === 'sleeping' && !harness.wake().active) break;
            if (state.status === 'terminal' || performance.now() > end) {
              throw new Error(`${item.scenario} did not sleep: ${JSON.stringify(state)}`);
            }
            await delay(1);
          }
        }
      } else {
        const tasks = await readTasks(store);
        assert.equal(tasks.length, 1);
        const [{ id, state }] = tasks;
        assert.equal(state.status, item.scenario === 'early-tag' ? 'pending' : 'sleeping');
        if (item.scenario === 'expiry') {
          clock = deadline;
          assert.equal(await harness.commit(tx => tx.signal(id, answer, key, payload), context), 'closed');
        } else if (item.scenario !== 'early-tag') {
          assert.equal(await harness.signal(id, answer, key, payload, context), 'delivered');
        }
        const settled = await harness.waitForTask(id, withAbortSignal(AbortSignal.timeout(10_000), context));
        assert.deepEqual(settled.state.outcome, { status: 'completed', result: outcome(item) });
      }
      assert.deepEqual(reports, []);
    } finally {
      if (harness) await harness.close(context);
      else await store.close(context);
    }
  }

  async function snapshot(item) {
    const store = await open(item);
    try {
      const tasks = await readTasks(store);
      assert.equal(tasks.length, 1, `${item.backend}/${item.scenario}: task count`);
      return JSON.parse(JSON.stringify(tasks[0]));
    } finally {
      await store.close(context);
    }
  }
  const cases = [];
  for (const backend of ['sqlite', 'jsonl']) {
    for (const scenario of ['parked-tag', 'early-tag', 'parked-swift', 'expiry']) {
      const extension = backend === 'sqlite' ? '.sqlite' : '';
      const path = join(directory, `${backend}-${scenario}${extension}`);
      const oracle = join(directory, `${backend}-${scenario}-tag${extension}`);
      cases.push({ backend, scenario, path, oracle });
    }
  }
  const seedingInSwift = item => item.scenario === 'parked-swift';
  const seedRecords = new Map();
  const finalRecords = new Map();
  for (const item of cases) {
    await taggedStep({ ...item, path: item.oracle, step: 'seed' });
    seedRecords.set(item.path, await snapshot({ ...item, path: item.oracle }));
    if (!seedingInSwift(item)) await cp(item.oracle, item.path, { recursive: item.backend === 'jsonl' });
    await taggedStep({ ...item, path: item.oracle, step: 'finish' });
    finalRecords.set(item.path, await snapshot({ ...item, path: item.oracle }));
  }

  const plan = join(directory, 'swift-plan.json');
  await writeFile(plan, JSON.stringify({ cases: cases.map(({ oracle, ...item }) => ({
    ...item, step: seedingInSwift(item) ? 'seed' : 'finish',
  })) }));
  const child = spawnSync('swift', ['test', '--skip-build', '--filter', 'D2SignalFixtureTests.crossLanguageSignalFiles'], {
    cwd: root, env: { ...process.env, PISWIFT_D2_SIGNAL_PLAN: plan }, stdio: 'inherit', timeout: 120_000,
  });
  if (child.error) throw child.error;
  if (child.status !== 0) throw new Error(`Swift signal fixture checks exited ${child.status}`);
  for (const item of cases) {
    const label = `${item.backend}/${item.scenario}`;
    if (seedingInSwift(item)) {
      assert.deepEqual(await snapshot(item), seedRecords.get(item.path), `${label}: stored sleep`);
      await taggedStep({ ...item, step: 'finish' });
    }
    assert.deepEqual(await snapshot(item), finalRecords.get(item.path), `${label}: settled task`);
  }
  console.log(`Signal fixtures passed: ${upstreamTag} and Swift, four cases each on SQLite and JSONL.`);
} finally {
  await source?.close();
  await rm(directory, { recursive: true, force: true });
}
