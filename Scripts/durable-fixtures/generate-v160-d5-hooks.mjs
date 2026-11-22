// Continue the tag's hook checkpoints in Swift and Swift's checkpoints in the tag.
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
if (!process.argv.includes('--check')) throw new Error('Use --check for temporary D5 files');

const repository = fileURLToPath(new URL('../../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'piswift-v160-d5-hooks-'));
const clock = 1_000;
let source;
try {
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context, withAbortSignal } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineExtension, defineTool, hook, hookTask } = await source.import('packages/durable/src/harness/define.ts');
  const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
  const { defineTask } = await source.import('packages/durable/src/tasks.ts');
  const { defineSignal } = await source.import('packages/durable/src/signals.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxAssistantMessage, fauxProvider, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { obj } = await source.import('packages/schema/src/index.ts');

  const decision = defineSignal({ name: 'fixture.d5-decision', version: 1, schema: obj({}) });
  const taskKind = 'fixture.d5-hook';
  const signalKey = 'decision';
  const model = { provider: 'faux', modelId: 'faux-1' };
  const open = item => item.backend === 'sqlite' ? openNodeSqliteStorage(item.path)
    : openNodeJsonlStorage(item.path, context);

  function registryFor({ phase, mode }, hold) {
    const child = defineTask({
      name: taskKind, version: 1, initial: () => ({ phase: mode === 'running' ? 'decide' : 'park' }),
      phases: {
        park: (_task, runtime, ctx) => runtime.commit(() => ({
          status: 'sleeping', checkpoint: { phase: 'decide' }, signals: [decision.key(signalKey)],
        }), ctx),
        decide: async (_task, runtime, ctx) => {
          if (hold) await hold;
          if (mode === 'sleeping') assert.ok((await runtime.readSignal(decision, signalKey, ctx))?.value);
          const result = phase === 'afterTools' ? { terminate: true } : { continue: 'fixture revision' };
          return runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result } }), ctx);
        },
      },
      abort: (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), ctx),
    });
    const step = defineTool({
      name: 'fixture_step', description: 'fixture_step', replay: 'safe', parameters: obj({}),
      execute: () => ({ output: [{ type: 'text', text: 'fixture tool result' }] }),
    });
    const registry = createRegistry();
    const request = () => ({ tasks: [hookTask(child, null)] });
    registry.install(defineExtension({
      name: 'fixture.d5', tasks: [child],
      tools: phase === 'afterTools' ? [step] : [],
      hooks: [hook(GenerationTask, phase === 'afterTools' ? { afterTools: request } : {
        onYield: answer => answer.content.some(part => part.type === 'text' && part.text === 'fixture draft')
          ? request() : undefined,
      })],
    }));
    return registry;
  }

  async function tasksOf(store, kind) {
    const query = kind === undefined ? { order: 'ascending' } : { kind, order: 'ascending' };
    return (await store.scanTasks(query, 20, undefined, context)).items;
  }

  async function waitForBoundary(store, harness, { phase, mode }) {
    const end = performance.now() + 10_000;
    for (;;) {
      const [child] = await tasksOf(store, taskKind);
      if (child?.state.status === mode && (mode === 'running' || !harness.wake().active)) {
        const [generation] = await tasksOf(store, 'pi.generation');
        assert.equal(generation.state.status, 'waiting');
        assert.equal(generation.state.checkpoint.phase, phase);
        assert.deepEqual(generation.state.checkpoint.tasks, [child.id]);
        assert.deepEqual(generation.state.on, [child.id]);
        assert.equal(generation.state.policy, 'allSettled');
        assert.equal(child.owner, generation.id);
        assert.deepEqual(child.state.checkpoint, { phase: 'decide' });
        if (mode === 'sleeping') assert.deepEqual(child.state.signals, [decision.key(signalKey)]);
        return child;
      }
      if (performance.now() > end) throw new Error(`No ${mode} child for ${phase}`);
      await new Promise(resolve => setImmediate(resolve));
    }
  }

  // The captured writer cannot commit until the copy finishes. SQLite rebuilds
  // its shared-memory index from the copied WAL when it opens the snapshot.
  async function copyFiles(source, destination, backend) {
    await cp(source, destination, { recursive: backend === 'jsonl' });
    if (backend === 'sqlite') {
      try {
        await cp(`${source}-wal`, `${destination}-wal`);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  }

  async function run(item, step) {
    const capturing = item.mode === 'running' && step === 'park';
    const hold = capturing ? Promise.withResolvers() : undefined;
    const store = await open(capturing ? { ...item, path: item.workPath } : item);
    const faux = fauxProvider({ api: 'openai-completions' });
    const models = createModels();
    models.setProvider(faux.provider);
    if (step === 'park') {
      faux.setResponses([item.phase === 'afterTools'
        ? fauxAssistantMessage([fauxToolCall('fixture_step', {}, { id: 'c1' })], { stopReason: 'toolUse', timestamp: clock })
        : fauxAssistantMessage('fixture draft', { timestamp: clock })]);
    } else if (step === 'finish' && item.phase === 'yield') {
      faux.setResponses([fauxAssistantMessage('fixture final', { timestamp: clock })]);
    }
    let harness;
    try {
      if (item.mode === 'running' && step === 'finish') {
        const [child] = await tasksOf(store, taskKind);
        assert.equal(child.state.status, 'running');
      }
      harness = await Harness.open(store, { registry: registryFor(item, hold?.promise), models, now: () => clock,
        settings: { retry: { enabled: false } }, onWake: () => {} }, context);
      if (step === 'seed') {
        const root = await harness.root(context, { agent: { model } });
        assert.equal(root.id, 1);
        await root.commit(tx => root.submit(tx, { type: 'input', content: 'fixture question' }), context);
        return;
      }
      if (item.mode === 'running' && step === 'finish') {
        const [child] = await tasksOf(store, taskKind);
        assert.equal(child.state.status, 'pending');
        assert.equal(child.restarts, 1);
      }
      harness.resume();
      if (step === 'park') {
        await waitForBoundary(store, harness, item);
        if (capturing) await copyFiles(item.workPath, item.path, item.backend);
        return;
      }
      if (item.mode === 'sleeping') {
        const child = await waitForBoundary(store, harness, item);
        assert.equal(await harness.signal(child.id, decision, signalKey, {}, context), 'delivered');
      }
      await harness.waitForIdle(withAbortSignal(AbortSignal.timeout(10_000), context));
      const submissions = (await store.scanSubmissions({ conversationId: 1, order: 'ascending' },
        20, undefined, context)).items;
      assert.equal(submissions.length, 1);
      assert.equal(submissions[0].status, 'done');
      assert.equal(faux.state.callCount, item.phase === 'yield' ? 1 : 0);
    } finally {
      hold?.resolve();
      if (harness) await harness.close(context);
      else await store.close(context);
    }
  }

  async function snapshot(item) {
    const store = await open(item);
    try {
      const tasks = await tasksOf(store);
      const entries = (await store.scanEntries({ conversationId: 1, order: 'ascending' },
        20, undefined, context)).items;
      const submissions = (await store.scanSubmissions({ conversationId: 1, order: 'ascending' },
        20, undefined, context)).items;
      const documents = {};
      for (const kind of ['pi.live', 'pi.inbox', 'pi.usage']) {
        const record = await store.findDocument({ kind,
          scope: { kind: 'conversation', conversationId: 1 } }, 'current', context);
        if (record) documents[kind] = (await store.document(record.id, 'current', context)).value;
      }
      return JSON.parse(JSON.stringify({ tasks, entries, submissions, documents }));
    } finally { await store.close(context); }
  }

  const plan = [], checks = [];
  for (const mode of ['sleeping', 'running']) {
    for (const backend of ['sqlite', 'jsonl']) {
      for (const phase of ['afterTools', 'yield']) {
        const item = suffix => ({ backend, phase, mode, path: join(directory, `${mode}-${backend}-${phase}-${suffix}`) });
        const oracle = item('oracle'), swiftPark = item('swift-park'), swiftFinish = item('swift-finish');
        if (mode === 'running') {
          oracle.workPath = item('oracle-live').path;
          swiftPark.workPath = item('swift-live').path;
        }
        const seed = { ...oracle, path: oracle.workPath ?? oracle.path };
        await run(seed, 'seed');
        await copyFiles(seed.path, swiftPark.workPath ?? swiftPark.path, backend);
        await run(oracle, 'park');
        const parked = await snapshot(oracle);
        assert.equal(parked.submissions[0].status, 'placed');
        if (phase === 'yield') {
          const review = parked.documents['pi.live'].run.yield;
          const generation = parked.tasks.find(task => task.kind === 'pi.generation');
          assert.deepEqual(review, {
            answer: generation.state.checkpoint.answer,
            tasks: generation.state.checkpoint.tasks,
          });
        }
        await copyFiles(oracle.path, swiftFinish.path, backend);
        await run(oracle, 'finish');
        const finished = await snapshot(oracle);
        assert.equal(finished.documents['pi.live'].run, undefined);
        if (phase === 'yield') {
          const continued = finished.entries.find(entry => entry.model?.[0]?.content === 'fixture revision');
          assert.equal(continued?.kind, 'pi.user');
          const answer = finished.entries.find(entry => entry.id === finished.submissions[0].answer);
          assert.equal(answer?.model?.[0]?.content[0]?.text, 'fixture final');
        }
        plan.push({ ...swiftPark, step: 'park' }, { ...swiftFinish, step: 'finish' });
        checks.push({ swiftPark, swiftFinish, parked, finished });
      }
    }
  }

  const planPath = join(directory, 'swift-plan.json');
  await writeFile(planPath, JSON.stringify(plan));
  const swift = spawnSync('swift', ['test', '--skip-build', '--filter',
    'D5HookFixtureTests.crossLanguageHookFiles'], { cwd: repository,
    env: { ...process.env, PISWIFT_D5_HOOK_PLAN: planPath }, stdio: 'inherit', timeout: 120_000 });
  if (swift.error) throw swift.error;
  if (swift.status !== 0) throw new Error(`Swift D5 hooks exited ${swift.status}`);
  function equal(actual, expected, label) {
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
    const mismatch = difference(actual, expected, '$');
    if (mismatch) throw new Error(`${label}: ${mismatch}`);
  }
  for (const { swiftPark, swiftFinish, parked, finished } of checks) {
    const cell = `${swiftPark.backend} ${swiftPark.phase} ${swiftPark.mode} child`;
    equal(await snapshot(swiftPark), parked, `${cell}: Swift hook checkpoint`);
    await run(swiftPark, 'finish');
    equal(await snapshot(swiftPark), finished, `${cell}: Swift to TypeScript`);
    equal(await snapshot(swiftFinish), finished, `${cell}: TypeScript to Swift`);
    console.log(`D5 ${cell}: both directions passed`);
  }
  console.log(`D5 hooks passed: ${upstreamTag} and Swift, both phases and directions on SQLite and JSONL.`);
} finally {
  await source?.close();
  await rm(directory, { recursive: true, force: true });
}
