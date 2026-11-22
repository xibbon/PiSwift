// Check the v1.6.0 beforeTool gate across SQLite and JSONL in both directions.
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
if (!process.argv.includes('--check')) throw new Error('Use --check');

const repository = fileURLToPath(new URL('../../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'piswift-v160-d4-gate-'));
let source;
try {
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context, withAbortSignal } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineExtension, defineTool, hook } = await source.import('packages/durable/src/harness/define.ts');
  const { defineSignal } = await source.import('packages/durable/src/signals.ts');
  const { AssistantEntry } = await source.import('packages/durable/src/entries.ts');
  const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxAssistantMessage, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { obj, str, bool } = await source.import('packages/schema/src/index.ts');

  const approval = defineSignal({ name: 'fixture.approval', version: 1, schema: obj({ allow: bool() }) });
  const key = 'rm_-rf_build';
  const command = 'rm -rf build';
  const open = item => item.backend === 'sqlite' ? openNodeSqliteStorage(item.path)
    : openNodeJsonlStorage(item.path, context);
  const registryFor = runs => {
    const registry = createRegistry();
    registry.install(defineExtension({ name: 'fixture.gate', tools: [defineTool({
      name: 'bash', description: 'bash', replay: 'safe', parameters: obj({ command: str() }),
      execute: async ({ command }) => {
        runs.push(command);
        return { output: [{ type: 'text', text: `ran ${command}` }] };
      },
    })], hooks: [hook(ToolTask, { beforeTool: async (call, api, ctx) => {
      const signalKey = String(call.arguments.command).replaceAll(' ', '_');
      const state = await api.readSignal(approval, signalKey, ctx);
      return state === undefined ? { sleep: { signals: [approval.key(signalKey)] } }
        : state.value.allow ? undefined : { block: 'Not approved' };
    } })] }));
    return registry;
  };
  async function eventually(check, label) {
    const end = performance.now() + 10_000;
    while (!(await check())) {
      if (performance.now() > end) throw new Error(`${label}: condition did not arrive`);
      await delay(1);
    }
  }
  const readTool = async store => {
    const page = await store.scanTasks({ kind: 'pi.tool' }, 10, undefined, context);
    assert.equal(page.items.length, 1);
    return page.items[0];
  };
  async function step(item, action) {
    const store = await open(item);
    const runs = [];
    let harness;
    try {
      harness = await Harness.open(store, { registry: registryFor(runs), models: createModels(),
        now: () => 1_000, onWake: () => {} }, context);
      if (action === 'prepare') {
        const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
        assert.equal(root.id, 1);
        await root.commit(async tx => {
          const assistant = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([
            fauxToolCall('bash', { command }, { id: 'c1' }),
          ], { stopReason: 'toolUse', timestamp: 1_000 })] });
          const taskId = await tx.createTask(ToolTask, { kind: 'model', assistant: assistant.id, callId: 'c1' },
            { ownership: { kind: 'conversation' }, conversationId: root.id });
          const live = await tx.doc(LiveDoc, root.id);
          live.tools = [{ callId: 'c1', name: 'bash', taskId, status: 'pending' }];
        }, context);
      } else if (action === 'park') {
        const { id } = await readTool(store);
        harness.resume();
        await eventually(async () => (await harness.getTask(id, context))?.state.status === 'sleeping'
          && !harness.wake().active, `${item.backend} gate park`);
        const task = await harness.getTask(id, context);
        assert.deepEqual(task.state.checkpoint, { phase: 'call' });
        assert.deepEqual(task.state.signals, [approval.key(key)]);
        assert.deepEqual(runs, []);
      } else {
        const { id, state } = await readTool(store);
        assert.equal(state.status, 'sleeping');
        harness.resume();
        await eventually(() => !harness.wake().active, `${item.backend} gate reopen`);
        assert.equal(await harness.signal(id, approval, key, { allow: true }, context), 'delivered');
        const receipt = await harness.waitForTask(id, withAbortSignal(AbortSignal.timeout(10_000), context));
        assert.equal(receipt.state.outcome.status, 'completed');
        assert.deepEqual(runs, [command]);
      }
    } finally {
      if (harness) await harness.close(context);
      else await store.close(context);
    }
  }
  async function snapshot(item) {
    const store = await open(item);
    try {
      const tasks = (await store.scanTasks({ order: 'ascending' }, 20, undefined, context)).items;
      const entries = (await store.scanEntries({ conversationId: 1, order: 'ascending' }, 20, undefined, context)).items;
      const record = await store.findDocument({ kind: 'pi.live',
        scope: { kind: 'conversation', conversationId: 1 } }, 'current', context);
      const live = (await store.document(record.id, 'current', context)).value;
      return JSON.parse(JSON.stringify({ tasks, entries, live }));
    } finally { await store.close(context); }
  }
  const plan = [], checks = [];
  for (const backend of ['sqlite', 'jsonl']) {
    const item = suffix => ({ backend, path: join(directory, `${backend}-${suffix}`) });
    const oracle = item('oracle'), swiftPark = item('swift-park'), swiftFinish = item('swift-finish');
    await step(oracle, 'prepare');
    await cp(oracle.path, swiftPark.path, { recursive: backend === 'jsonl' });
    await step(oracle, 'park');
    const parked = await snapshot(oracle);
    await cp(oracle.path, swiftFinish.path, { recursive: backend === 'jsonl' });
    await step(oracle, 'finish');
    const finished = await snapshot(oracle);
    plan.push({ ...swiftPark, step: 'park' }, { ...swiftFinish, step: 'finish' });
    checks.push({ swiftPark, swiftFinish, parked, finished });
  }
  const planPath = join(directory, 'swift-plan.json');
  await writeFile(planPath, JSON.stringify(plan));
  const swift = spawnSync('swift', ['test', '--skip-build', '--filter',
    'HarnessToolGateTests.crossLanguageGateFiles'], { cwd: repository,
    env: { ...process.env, PISWIFT_D4_GATE_PLAN: planPath }, stdio: 'inherit', timeout: 120_000 });
  if (swift.error) throw swift.error;
  if (swift.status !== 0) throw new Error(`Swift D4 gate exited ${swift.status}`);
  for (const { swiftPark, swiftFinish, parked, finished } of checks) {
    assert.deepEqual(await snapshot(swiftPark), parked, `${swiftPark.backend}: Swift gate sleep`);
    await step(swiftPark, 'finish');
    assert.deepEqual(await snapshot(swiftPark), finished, `${swiftPark.backend}: Swift to TS gate`);
    assert.deepEqual(await snapshot(swiftFinish), finished, `${swiftPark.backend}: TS to Swift gate`);
  }
  console.log(`D4 gate passed: ${upstreamTag} and Swift, both directions on SQLite and JSONL.`);
} finally {
  await source?.close();
  await rm(directory, { recursive: true, force: true });
}
