// Run the tagged and Swift tool schedulers against both file formats.
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
if (!process.argv.includes('--check')) throw new Error('Use --check to run the tool park cases on temporary files');

const repository = fileURLToPath(new URL('../../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'piswift-v160-tool-parks-'));
const start = 1_000;
const finish = scenario => scenario === 'duration' ? 3_500 : start;
const callId = 'park-call';
const name = 'fixture.park';
const rootId = 1;
const key = 'ready';
const checkpoint = { cursor: 2 };
const payload = { text: 'ready' };
let source;
try {
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context, withAbortSignal } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineExtension, defineTool } = await source.import('packages/durable/src/harness/define.ts');
  const { defineTask } = await source.import('packages/durable/src/tasks.ts');
  const { defineSignal } = await source.import('packages/durable/src/signals.ts');
  const { AssistantEntry } = await source.import('packages/durable/src/entries.ts');
  const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxAssistantMessage, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { obj, str } = await source.import('packages/schema/src/index.ts');

  const answer = defineSignal({ name: 'fixture.park-ready', version: 1, schema: obj({ text: str() }) });
  const child = defineTask({
    name: 'fixture.park-child', version: 1, initial: () => ({ phase: 'sleep' }),
    phases: {
      sleep: (_task, runtime, ctx) => runtime.commit(() => ({
        status: 'sleeping', checkpoint: { phase: 'finish' }, signals: [answer.key(key)],
      }), ctx),
      finish: (_task, runtime, ctx) => runtime.commit(() => ({
        status: 'terminal', outcome: { status: 'completed', result: 'child' },
      }), ctx),
    },
    abort: (_task, runtime, ctx) => runtime.commit(() => ({
      status: 'terminal', outcome: { status: 'aborted', reason: 'fixture' },
    }), ctx),
  });

  function registryFor(scenario, runs, cancels) {
    const registry = createRegistry();
    const tool = defineTool({
      name, description: name, replay: 'safe', parameters: obj({}),
      execute: async (_args, api, ctx) => {
        runs.push({ wake: api.wake, checkpoint: api.checkpoint });
        if (api.wake === undefined) {
          if (scenario === 'cancel') await api.details({ stage: 'parked' }, ctx);
          if (scenario === 'any') {
            const options = { ownership: { kind: 'task', taskId: api.taskId } };
            const on = [await api.createTask(child, null, options, ctx), await api.createTask(child, null, options, ctx)];
            return { wait: { on, policy: 'any', checkpoint: { on } } };
          }
          return { sleep: { signals: [answer.key(key)], checkpoint } };
        }
        let text;
        if (scenario === 'any') {
          assert.deepEqual(api.wake, { reason: 'tasks', ended: [api.checkpoint.on[1]] });
          const other = await api.getTask(api.checkpoint.on[0], ctx);
          assert.equal(other.state.status, 'sleeping');
          assert.equal(other.abortRequested, false);
          text = 'joined';
        } else {
          assert.deepEqual(api.wake, { reason: 'signal', ...answer.key(key) });
          assert.deepEqual(api.checkpoint, checkpoint);
          const signal = await api.readSignal(answer, key, ctx);
          assert.deepEqual(signal, { value: payload });
          text = signal.value.text;
        }
        return { output: [{ type: 'text', text }], details: { checkpoint: api.checkpoint, wake: api.wake } };
      },
      cancel: async (_args, api) => {
        cancels.push({ wake: api.wake, checkpoint: api.checkpoint });
      },
    });
    registry.install(defineExtension({ name: 'fixture.tool-parks', tasks: [child], tools: [tool] }));
    return registry;
  }

  const open = ({ backend, path }) => backend === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
  const readTool = async store => {
    const page = await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context);
    assert.equal(page.items.length, 1);
    return page.items[0];
  };
  const parkedStatus = scenario => scenario === 'any' ? 'waiting' : 'sleeping';
  async function eventually(check, label) {
    const end = performance.now() + 10_000;
    while (!(await check())) {
      if (performance.now() > end) throw new Error(`${label}: condition did not arrive`);
      await delay(1);
    }
  }

  async function taggedStep(item, step) {
    const store = await open(item);
    const { scenario } = item;
    const runs = [], cancels = [], reports = [];
    let harness;
    try {
      harness = await Harness.open(store, {
        registry: registryFor(scenario, runs, cancels), models: createModels(),
        now: () => step === 'finish' ? finish(scenario) : start,
        onWake: () => {}, onReport: report => reports.push(report.error),
      }, context);
      if (step === 'prepare') {
        const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
        assert.equal(root.id, rootId);
        await root.commit(async tx => {
          const assistant = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([
            fauxToolCall(name, {}, { id: callId }),
          ], { stopReason: 'toolUse', timestamp: start })] });
          const taskId = await tx.createTask(ToolTask, { kind: 'model', assistant: assistant.id, callId },
            { ownership: { kind: 'conversation' }, conversationId: root.id });
          const live = await tx.doc(LiveDoc, root.id);
          live.tools = [{ callId, name, taskId, status: 'pending' }];
        }, context);
      } else if (step === 'park') {
        const { id } = await readTool(store);
        harness.resume();
        await eventually(async () => (await harness.getTask(id, context)).state.status === parkedStatus(scenario)
          && !harness.wake().active, `${item.backend}/${scenario} park`);
        const slot = (await harness.snapshot(LiveDoc, rootId, context)).tools[0];
        assert.equal(slot.status, parkedStatus(scenario));
        assert.equal(slot.output, undefined);
        assert.deepEqual(runs, [{ wake: undefined, checkpoint: undefined }]);
      } else {
        const { id, state } = await readTool(store);
        assert.equal(state.status, parkedStatus(scenario));
        harness.resume();
        await eventually(() => !harness.wake().active, `${item.backend}/${scenario} reopen`);
        assert.deepEqual(runs, []);
        if (scenario === 'cancel') {
          await harness.abortTask(id, context);
        } else if (scenario === 'any') {
          const [first, second] = state.on;
          assert.equal(state.on.length, 2);
          assert.equal(await harness.signal(second, answer, key, payload, context), 'delivered');
          await eventually(async () => (await harness.getTask(id, context)).state.status === 'completing',
            `${item.backend}/${scenario} wakes on the second child`);
          assert.equal(await harness.signal(first, answer, key, payload, context), 'delivered');
        } else {
          assert.equal(await harness.signal(id, answer, key, payload, context), 'delivered');
        }
        const receipt = await harness.waitForTask(id, withAbortSignal(AbortSignal.timeout(10_000), context));
        assert.equal(receipt.state.outcome.status, scenario === 'cancel' ? 'aborted' : 'completed');
        const { entry } = await store.entry(receipt.state.outcome.result.entryId, context);
        assert.equal(entry.model[0].durationMs, finish(scenario) - start);
        if (scenario === 'cancel') {
          assert.deepEqual(runs, []);
          assert.deepEqual(cancels, [{ wake: undefined, checkpoint }]);
        } else {
          assert.equal(runs.length, 1);
          assert.deepEqual(cancels, []);
        }
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
      const tasks = (await store.scanTasks({ order: 'ascending' }, 20, undefined, context)).items;
      const entries = (await store.scanEntries({ conversationId: rootId, order: 'ascending' }, 20, undefined, context)).items;
      const document = await store.findDocument({ kind: 'pi.live', scope: { kind: 'conversation', conversationId: rootId } }, 'current', context);
      const { value: live } = await store.document(document.id, 'current', context);
      return JSON.parse(JSON.stringify({ tasks, entries, live }));
    } finally {
      await store.close(context);
    }
  }

  const plan = [];
  const checks = [];
  for (const backend of ['sqlite', 'jsonl']) {
    for (const scenario of ['signal', 'any', 'cancel', 'duration']) {
      const item = direction => ({ backend, scenario, path: join(directory, `${backend}-${scenario}-${direction}`) });
      const oracle = item('oracle'), swiftPark = item('swift-park'), tagPark = item('tag-park');
      const copy = { recursive: backend === 'jsonl' };
      await taggedStep(oracle, 'prepare');
      await cp(oracle.path, swiftPark.path, copy);
      await taggedStep(oracle, 'park');
      const parked = await snapshot(oracle);
      await cp(oracle.path, tagPark.path, copy);
      await taggedStep(oracle, 'finish');
      const settled = await snapshot(oracle);
      plan.push({ ...swiftPark, step: 'park' }, { ...tagPark, step: 'finish' });
      checks.push({ swiftPark, tagPark, parked, settled });
    }
  }

  const planPath = join(directory, 'swift-plan.json');
  await writeFile(planPath, JSON.stringify(plan));
  const swift = spawnSync('swift', ['test', '--skip-build', '--filter', 'D3aToolParkFixtureTests.crossLanguageToolParkFiles'], {
    cwd: repository, env: { ...process.env, PISWIFT_D3A_PARK_PLAN: planPath }, stdio: 'inherit', timeout: 120_000,
  });
  if (swift.error) throw swift.error;
  if (swift.status !== 0) throw new Error(`Swift tool park fixture checks exited ${swift.status}`);
  for (const { swiftPark, tagPark, parked, settled } of checks) {
    const label = `${swiftPark.backend}/${swiftPark.scenario}`;
    assert.deepEqual(await snapshot(swiftPark), parked, `${label}: park made by Swift`);
    await taggedStep(swiftPark, 'finish');
    assert.deepEqual(await snapshot(swiftPark), settled, `${label}: Swift to tag continuation`);
    assert.deepEqual(await snapshot(tagPark), settled, `${label}: tag to Swift continuation`);
  }
  console.log(`Tool park fixtures passed: ${upstreamTag} and Swift, four cases in each direction on SQLite and JSONL.`);
} finally {
  await source?.close();
  await rm(directory, { recursive: true, force: true });
}
