// Two-language D3b continuations on the v1.6.0 tag's SQLite and JSONL files.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cp, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV160, upstreamTag } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  if (child.error) throw child.error;
  process.exit(child.status ?? 1);
}
if (!process.argv.includes('--check')) throw new Error('Use --check for temporary D3b files');

const repository = fileURLToPath(new URL('../../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'piswift-v160-d3b-'));
let source;
try {
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineExtension, defineTool } = await source.import('packages/durable/src/harness/define.ts');
  const { defineTask } = await source.import('packages/durable/src/tasks.ts');
  const { defineSignal, SubmissionSettled } = await source.import('packages/durable/src/signals.ts');
  const { AssistantEntry } = await source.import('packages/durable/src/entries.ts');
  const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxAssistantMessage, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { obj, str } = await source.import('packages/schema/src/index.ts');

  const Done = defineSignal({ name: 'fixture.d3b-done', version: 1, schema: obj({ text: str() }) });
  const waiter = defineTask({
    name: 'fixture.d3b-waiter', version: 1, initial: () => ({ phase: 'sleep' }),
    phases: {
      sleep: (_task, runtime, ctx) => runtime.commit(() => ({
        status: 'sleeping', checkpoint: { phase: 'woke' }, signals: [SubmissionSettled.key('settled')],
      }), ctx),
      woke: async (_task, runtime, ctx) => {
        const signal = await runtime.readSignal(SubmissionSettled, 'settled', ctx);
        assert.equal(signal?.value.status, 'done');
        return runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: 'done' } }), ctx);
      },
    },
    abort: (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), ctx),
  });
  const research = defineTool({
    name: 'research', description: 'research', parameters: obj({ topic: str() }), replay: 'safe',
    async execute({ topic }, api, ctx) {
      const state = await api.readSignal(Done, 'done', ctx);
      if (state?.value) return { output: [{ type: 'text', text: `${topic}: ${state.value.text}` }] };
      return { sleep: { signals: [Done.key('done')] } };
    },
  });
  const parent = (scenario) => defineTool({
    name: 'fixture.d3b-parent', description: 'fixture.d3b-parent', parameters: obj({}),
    ...(scenario === 'nested' ? { replay: 'safe' } : {}),
    async execute(_args, api, ctx) {
      const a = await api.executeTool('research', { topic: 'x' }, ctx, { key: 'a', wait: false });
      if (scenario === 'restart') {
        if (api.wake === undefined) return { wait: { on: [a.taskId], policy: 'allSettled' } };
        return { output: [{ type: 'text', text: String((await a.result(ctx)).structuredOutput) }] };
      }
      const b = await api.executeTool('research', { topic: 'y' }, ctx, { key: 'b', wait: false });
      const open = [];
      for (const call of [a, b]) if ((await api.getTask(call.taskId, ctx))?.state.status !== 'terminal') open.push(call.taskId);
      if (open.length) return { wait: { on: open, policy: 'any' } };
      const [ra, rb] = await Promise.all([a.result(ctx), b.result(ctx)]);
      return { output: [{ type: 'text', text: `${String(ra.structuredOutput)} + ${String(rb.structuredOutput)}` }] };
    },
  });
  const registryFor = scenario => {
    const registry = createRegistry();
    registry.install(defineExtension({ name: 'fixture.d3b',
      tools: scenario === 'notify' ? [] : [research, parent(scenario)], tasks: [waiter] }));
    return registry;
  };
  const openStore = item => item.backend === 'sqlite'
    ? openNodeSqliteStorage(item.path) : openNodeJsonlStorage(item.path, context);
  async function eventually(check, label) {
    const end = performance.now() + 10_000;
    while (!(await check())) {
      if (performance.now() > end) throw new Error(`${label}: condition did not arrive`);
      await new Promise(resolve => setImmediate(resolve));
    }
  }

  async function run(item, step) {
    const store = await openStore(item);
    let harness;
    try {
      harness = await Harness.open(store, { registry: registryFor(item.scenario), models: createModels(),
        now: () => 1_000, onWake: () => {} }, context);
      if (step === 'seed') {
        const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
        if (item.scenario === 'notify') {
          await root.commit(async tx => {
            const id = await tx.createTask(waiter, null, { ownership: { kind: 'conversation' } });
            await tx.createSubmission({ type: 'write', status: 'queued', conversationId: root.id,
              notify: { taskId: id, key: 'settled' } });
          }, context);
        } else {
          await root.commit(async tx => {
            const assistant = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([
              fauxToolCall('fixture.d3b-parent', {}, { id: 'c1' }),
            ], { stopReason: 'toolUse', timestamp: 1_000 })] });
            const id = await tx.createTask(ToolTask, { kind: 'model', assistant: assistant.id, callId: 'c1' },
              { ownership: { kind: 'conversation' }, conversationId: root.id });
            const live = await tx.doc(LiveDoc, root.id);
            live.tools = [{ callId: 'c1', name: 'fixture.d3b-parent', taskId: id, status: 'pending' }];
          }, context);
        }
      } else if (step === 'park') {
        harness.resume();
        if (item.scenario === 'notify') {
          await eventually(async () => (await store.scanTasks({ kind: 'fixture.d3b-waiter' }, 10, undefined, context))
            .items[0]?.state.status === 'sleeping' && !harness.wake().active, 'notify park');
        } else {
          await eventually(async () => {
            const parentTask = (await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context)).items
              .find(task => task.input.kind === 'model');
            const children = (await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context)).items
              .filter(task => task.input.kind === 'nested');
            return parentTask?.state.status === 'waiting' && children.length === (item.scenario === 'nested' ? 2 : 1)
              && children.every(task => task.state.status === 'sleeping') && !harness.wake().active;
          }, 'nested park');
          if (item.scenario === 'nested') {
            const children = (await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context)).items
              .filter(task => task.input.kind === 'nested');
            const b = children.find(task => task.input.key === 'b');
            assert.equal(await harness.signal(b.id, Done, 'done', { text: 'bee' }, context), 'delivered');
            await eventually(async () => {
              const parentTask = (await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context)).items
                .find(task => task.input.kind === 'model');
              return parentTask?.state.status === 'waiting' && parentTask.state.on?.length === 1
                && parentTask.state.on[0] !== b.id && !harness.wake().active;
            }, 'one nested result');
          }
        }
      } else if (item.scenario === 'notify') {
        harness.resume();
        const submission = (await store.scanSubmissions({ order: 'ascending' }, 10, undefined, context)).items[0];
        assert.equal(submission.status, 'queued');
        const root = await harness.root(context);
        await root.commit(async tx => {
          const entry = await tx.appendEntry(root.id, { kind: 'note' });
          tx.placeSubmission(submission.id, entry.id);
        }, context);
        const task = (await store.scanTasks({ kind: 'fixture.d3b-waiter' }, 10, undefined, context)).items[0];
        await harness.waitForTask(task.id, context);
      } else {
        harness.resume();
        const children = (await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context)).items
          .filter(task => task.input.kind === 'nested');
        const a = children.find(task => task.input.key === 'a');
        if (item.scenario === 'restart') {
          await eventually(async () => !harness.wake().active, 'restart recovery');
          assert.equal((await harness.getTask(a.id, context)).abortRequested, false);
        }
        assert.equal(await harness.signal(a.id, Done, 'done', { text: 'ay' }, context), 'delivered');
        const parentTask = (await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context)).items
          .find(task => task.input.kind === 'model');
        await harness.waitForTask(parentTask.id, context);
      }
    } finally {
      if (harness) await harness.close(context);
      else await store.close(context);
    }
  }

  async function snapshot(item) {
    const store = await openStore(item);
    try {
      const tasks = (await store.scanTasks({ order: 'ascending' }, 100, undefined, context)).items;
      const submissions = (await store.scanSubmissions({ order: 'ascending' }, 100, undefined, context)).items;
      const entries = (await store.scanEntries({ conversationId: 1, order: 'ascending' }, 100, undefined, context)).items;
      const liveRecord = await store.findDocument({ kind: 'pi.live', scope: { kind: 'conversation', conversationId: 1 } },
        'current', context);
      const live = liveRecord && (await store.document(liveRecord.id, 'current', context))?.value;
      return JSON.parse(JSON.stringify({ tasks, submissions, entries, live }));
    } finally { await store.close(context); }
  }

  const plan = [];
  const checks = [];
  for (const backend of ['sqlite', 'jsonl']) {
    for (const scenario of ['nested', 'notify', 'restart']) {
      const item = direction => ({ backend, scenario, path: join(directory, `${backend}-${scenario}-${direction}`) });
      const oracle = item('oracle');
      const swiftPark = item('swift-park');
      const tagPark = item('tag-park');
      const copy = { recursive: backend === 'jsonl' };
      await run(oracle, 'seed');
      await cp(oracle.path, swiftPark.path, copy);
      await run(oracle, 'park');
      const parked = await snapshot(oracle);
      await cp(oracle.path, tagPark.path, copy);
      await run(oracle, 'finish');
      const settled = await snapshot(oracle);
      plan.push({ ...swiftPark, step: 'park' }, { ...tagPark, step: 'finish' });
      checks.push({ swiftPark, tagPark, parked, settled });
    }
  }
  const planPath = join(directory, 'swift-plan.json');
  await writeFile(planPath, JSON.stringify(plan));
  const swift = spawnSync('swift', ['test', '--skip-build', '--filter', 'D3bCrossLanguageFixtureTests.continueD3bFiles'], {
    cwd: repository, env: { ...process.env, PISWIFT_D3B_PLAN: planPath }, stdio: 'inherit', timeout: 120_000,
  });
  if (swift.error) throw swift.error;
  if (swift.status !== 0) throw new Error(`Swift D3b fixture checks exited ${swift.status}`);
  function equal(actual, expected, label) {
    if (isDeepStrictEqual(actual, expected)) return;
    const difference = (left, right, path) => {
      if (isDeepStrictEqual(left, right)) return undefined;
      if (left && right && typeof left === 'object' && typeof right === 'object') {
        for (const key of new Set([...Object.keys(left), ...Object.keys(right)])) {
          const found = difference(left[key], right[key], `${path}.${key}`);
          if (found) return found;
        }
      }
      return `${path}: ${JSON.stringify(left)} != ${JSON.stringify(right)}`;
    };
    throw new Error(`${label}: ${difference(actual, expected, '$')}`);
  }
  for (const { swiftPark, tagPark, parked, settled } of checks) {
    const label = `${swiftPark.backend}/${swiftPark.scenario}`;
    equal(await snapshot(swiftPark), parked, `${label}: Swift wrote the parked file`);
    await run(swiftPark, 'finish');
    equal(await snapshot(swiftPark), settled, `${label}: tag continued the Swift file`);
    equal(await snapshot(tagPark), settled, `${label}: Swift continued the tag file`);
  }
  console.log(`D3b child fixtures passed: ${upstreamTag} and Swift, three scenarios both ways on SQLite and JSONL.`);
} finally {
  await source?.close();
  await rm(directory, { recursive: true, force: true });
}
