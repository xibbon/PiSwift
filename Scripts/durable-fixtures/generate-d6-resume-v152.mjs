// Tagged v1.5.2 tool task pre/post images. Nine saved boundaries on SQLite and JSONL.
import { spawnSync } from 'node:child_process';
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const output = fileURLToPath(new URL('./d6-resume-v152/', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d6-resume-'));
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { defineExtension, defineTool, hook } = await source.import('packages/durable/src/harness/define.ts');
const { ToolTask, NestedCallDoc } = await source.import('packages/durable/src/harness/tool.ts');
const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
const { defineTask } = await source.import('packages/durable/src/tasks.ts');
const { UserEntry, AssistantEntry } = await source.import('packages/durable/src/entries.ts');
const { createModels } = await source.import('packages/ai/src/models.ts');
const { fauxAssistantMessage, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
const clock = 1700000000000;
const oldDateNow = Date.now;
const oldPerformanceNow = Object.getOwnPropertyDescriptor(performance, 'now');
const oldMathRandom = Math.random, oldGetRandomValues = crypto.getRandomValues;
Date.now = () => clock;
Object.defineProperty(performance, 'now', { value: () => 0, configurable: true });
Math.random = () => 0.5;
crypto.getRandomValues = value => value.fill(0x42);
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    const result = Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item)]));
    if (result.role === 'assistant' && result.api !== undefined) result.api = '<faux-api>';
    if (result.role === 'toolResult' && result.details === null) delete result.details;
    return result;
  }
  return value;
}
async function snapshot(store, rootId) {
  const tasks = json((await store.scanTasks({ order: 'ascending' }, 100, undefined, context)).items);
  const submissions = json((await store.scanSubmissions({ order: 'ascending' }, 100, undefined, context)).items);
  const entries = json((await store.scanEntries({ conversationId: rootId, order: 'ascending' }, 100, undefined, context)).items);
  const documents = json((await store.scanDocuments({ scope: { kind: 'conversation', conversationId: rootId }, at: 'current' }, 100, undefined, context)).items);
  const values = [];
  for (const doc of documents) {
    const value = json(await store.document(doc.id, 'current', context));
    if (doc.kind === 'pi.provider') value.value.sessionId = '<provider-session-id>';
    values.push(value);
  }
  const nested = [];
  for (const task of tasks) {
    const docs = json((await store.scanDocuments({ scope: { kind: 'task', taskId: task.id }, at: 'current' }, 100, undefined, context)).items);
    for (const doc of docs) nested.push({ document: doc, value: json(await store.document(doc.id, 'current', context)) });
  }
  return normalize({ tasks, submissions, entries, documents, values, ...(nested.length ? { nested } : {}) });
}
const scenarios = ['unoffered', 'missing', 'invalid', 'blocked', 'safe-replay', 'unsafe-replay', 'restart-limit', 'afterRun-cutoff', 'nested-restart'];
const CutoffChild = defineTask({ name: 'd6.after-run-cutoff', version: 1, initial: () => ({ phase: 'run' }),
  phases: { run: async () => { throw new Error('Cutoff child must not run'); } },
  abort: async () => { throw new Error('Cutoff child abort must not run'); },
});
function registryFor(scenario) {
  const registry = createRegistry();
  if (scenario === 'nested-restart') {
    registry.install(defineExtension({ name: 'd6-nested-restart', tools: [
      defineTool({ name: 'leaf', description: 'Leaf', replay: 'safe', parameters: { type: 'object', properties: {} },
        execute: async () => ({ output: [{ type: 'text', text: 'leaf reran' }] }) }),
      defineTool({ name: 'batch', description: 'Batch', replay: 'safe', parameters: { type: 'object', properties: {} },
        execute: async (_args, api, callContext) => {
          const child = await api.executeTool('leaf', {}, callContext);
          return { output: [{ type: 'text', text: `batch ${child.structuredOutput}` }] };
        } }),
    ] }));
    return registry;
  }
  if (scenario === 'afterRun-cutoff') {
    registry.install(defineExtension({ name: 'd6-cutoff', tasks: [CutoffChild] }));
    return registry;
  }
  if (!['unoffered', 'missing'].includes(scenario)) {
    const replay = scenario === 'safe-replay' ? 'safe' : 'unsafe';
    registry.install(defineExtension({ name: 'd6-resume', tools: [defineTool({
      name: 'echo', description: 'Echo', replay,
      parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
      execute: async () => ({ output: [{ type: 'text', text: 'ran' }] }),
    })], hooks: [hook(ToolTask, {
      beforeTool: async () => scenario === 'blocked' ? { block: 'fixture block' } : undefined,
      afterTool: async (_call, result) => ({ ...result, output: [{ type: 'text', text: `hooked ${scenario}` }] }),
    })] }));
  } else {
    registry.install(defineExtension({ name: 'd6-resume', hooks: [hook(ToolTask, {
      afterTool: async (_call, result) => ({ ...result, output: [{ type: 'text', text: `hooked ${scenario}` }] }),
    })] }));
  }
  return registry;
}
const storage = (backend, path) => backend === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
async function copy(backend, from, to) {
  if (backend === 'sqlite') await copyFile(from, to);
  else await cp(from, to, { recursive: true });
}
async function seed(backend, path, scenario) {
  const store = await storage(backend, path);
  const harness = await Harness.open(store, { models: createModels(), registry: registryFor(scenario), now: () => clock,
    settings: scenario === 'afterRun-cutoff' ? { restartLimit: 1 } : {} }, context);
  const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
  if (scenario === 'nested-restart') {
    const ids = await root.commit(async tx => {
      const assistant = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([
        fauxToolCall('batch', {}, { id: 'call-d6' }),
      ], { stopReason: 'toolUse' })] });
      const taskId = await tx.createTask(ToolTask, { kind: 'model', assistant: assistant.id, callId: 'call-d6' },
        { ownership: { kind: 'conversation' }, conversationId: root.id });
      const call = { type: 'toolCall', id: 'call-d6/1', name: 'leaf', arguments: {} };
      const member = await tx.doc(NestedCallDoc, taskId, '1', null);
      const childId = await tx.createTask(ToolTask,
        { kind: 'nested', parent: taskId, parentCallId: 'call-d6', key: '1', call },
        { ownership: { kind: 'task', taskId }, conversationId: root.id, abandonOnRestart: false });
      member.taskId = childId;
      const live = await tx.doc(LiveDoc, root.id);
      live.tools = [{ callId: 'call-d6', name: 'batch', taskId, status: 'running' }];
      live.nestedTools = [{ callId: 'call-d6/1', parentCallId: 'call-d6', parentTaskId: taskId,
        name: 'leaf', taskId: childId, arguments: {}, status: 'running' }];
      return { assistant: assistant.id, taskId, childId };
    }, context);
    await root.commit(async tx => {
      const parent = await tx.task(ids.taskId), child = await tx.task(ids.childId);
      tx.setTask({ ...parent, state: { status: 'running', checkpoint: { phase: 'execute', arguments: {}, replay: 'safe' } },
        memos: { 'pi.tool.madeNestedCalls': true } });
      tx.setTask({ ...child, state: { status: 'running', checkpoint: { phase: 'execute', arguments: {}, replay: 'safe' } } });
    }, context);
    const pre = await snapshot(store, root.id);
    await harness.close(context);
    return { rootId: root.id, ids, pre };
  }
  if (scenario === 'afterRun-cutoff') {
    const ids = await root.commit(async tx => {
      const user = await tx.appendEntry(UserEntry, root.id, { model: [{ role: 'user', content: 'go', timestamp: clock }] });
      const answer = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([{ type: 'text', text: 'answered' }])] });
      await tx.createSubmission({ type: 'continue', status: 'done', conversationId: root.id, answer: answer.id });
      const taskId = await tx.createTask(GenerationTask, {}, { ownership: { kind: 'conversation' }, conversationId: root.id });
      const childId = await tx.createTask(CutoffChild, null, { ownership: { kind: 'task', taskId }, conversationId: root.id });
      const live = await tx.doc(LiveDoc, root.id);
      live.run = { taskId, inputs: [], turns: 0, first: user.id, afterRun: { tasks: [childId] } };
      return { user: user.id, answer: answer.id, taskId, childId };
    }, context);
    await root.commit(async tx => {
      const generation = await tx.task(ids.taskId), child = await tx.task(ids.childId);
      tx.setTask({ ...generation, state: { status: 'waiting',
        checkpoint: { phase: 'drain', answer: ids.answer, tasks: [ids.childId] },
        on: [ids.childId], policy: 'allSettled' } });
      tx.setTask({ ...child, state: { status: 'running', checkpoint: { phase: 'run' } }, restarts: 1 });
    }, context);
    const pre = await snapshot(store, root.id);
    await harness.close(context);
    return { rootId: root.id, ids, pre };
  }
  const args = scenario === 'invalid' ? { text: 42 } : { text: 'ok' };
  const ids = await root.commit(async tx => {
    const assistant = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([
      fauxToolCall(scenario === 'missing' || scenario === 'unoffered' ? 'ghost' : 'echo', args, { id: 'call-d6' }),
    ], { stopReason: 'toolUse' })] });
    const input = { kind: 'model', assistant: assistant.id, callId: 'call-d6',
      ...(scenario === 'unoffered' ? { unoffered: true } : {}) };
    const taskId = await tx.createTask(ToolTask, input, { ownership: { kind: 'conversation' }, conversationId: root.id });
    const live = await tx.doc(LiveDoc, root.id);
    live.tools = [{ callId: 'call-d6', name: scenario === 'missing' || scenario === 'unoffered' ? 'ghost' : 'echo',
      taskId, status: 'pending', ...(scenario === 'unoffered' ? { unoffered: true } : {}) }];
    return { assistant: assistant.id, taskId };
  }, context);
  if (scenario.endsWith('replay') || scenario === 'restart-limit') {
    await root.commit(async tx => {
      const saved = await tx.task(ids.taskId);
      tx.setTask({ ...saved, state: { status: 'running', checkpoint: { phase: 'execute', arguments: args,
        replay: scenario === 'safe-replay' ? 'safe' : 'unsafe' } },
        ...(scenario === 'restart-limit' ? { restarts: 7 } : {}) });
    }, context);
  }
  const pre = await snapshot(store, root.id);
  await harness.close(context);
  return { rootId: root.id, ids, pre };
}
async function resume(backend, path, scenario, ids, rootId) {
  const store = await storage(backend, path);
  const harness = await Harness.open(store, { models: createModels(), registry: registryFor(scenario), now: () => clock,
    settings: scenario === 'afterRun-cutoff' ? { restartLimit: 1 } : {} }, context);
  harness.resume();
  let timeout;
  try {
    await Promise.race([harness.waitForTask(ids.taskId, context), new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error(`${scenario} did not settle`)), 10_000);
    })]);
  } finally { clearTimeout(timeout); }
  const post = await snapshot(store, rootId);
  await harness.close(context);
  return post;
}

try {
  const reverse = process.argv.indexOf('--resume-swift');
  if (reverse >= 0) {
    const name = process.argv[reverse + 1], path = process.argv[reverse + 2];
    if (!name || !path) throw new Error('--resume-swift needs CASE and PATH');
    const item = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')).cases[name];
    if (!item) throw new Error(`Unknown case ${name}`);
    const copied = join(temporary, `swift-${name}${item.backend === 'sqlite' ? '.sqlite' : ''}`);
    await copy(item.backend, path, copied);
    const store = await storage(item.backend, copied);
    const pre = await snapshot(store, item.rootId);
    await store.close(context);
    if (!isDeepStrictEqual(pre, item.pre)) throw new Error(`${name} Swift pre records differ`);
    const post = await resume(item.backend, copied, item.scenario, item.ids, item.rootId);
    if (!isDeepStrictEqual(post, item.post)) throw new Error(`${name} Swift pre resumes differently under ${upstreamTag}`);
    console.log(`Swift ${name} pre resumes under ${upstreamTag} to the tagged final records.`);
  } else {
    const cases = {};
    for (const scenario of scenarios) for (const backend of ['sqlite', 'jsonl']) {
      const name = `${scenario}-${backend}`;
      const prePath = join(temporary, `${name}-pre${backend === 'sqlite' ? '.sqlite' : ''}`);
      const postPath = join(temporary, `${name}-post${backend === 'sqlite' ? '.sqlite' : ''}`);
      const { rootId, ids, pre } = await seed(backend, prePath, scenario);
      await copy(backend, prePath, postPath);
      const post = await resume(backend, postPath, scenario, ids, rootId);
      cases[name] = { scenario, backend, rootId, ids, pre, post };
      const dest = join(output, name), file = backend === 'sqlite' ? 'pre.sqlite' : 'pre';
      if (check) {
        const checkPath = join(temporary, `${name}-check${backend === 'sqlite' ? '.sqlite' : ''}`);
        if (backend === 'sqlite') await copyFile(join(dest, file), checkPath);
        else await copy(backend, join(dest, file), checkPath);
        const store = await storage(backend, checkPath);
        const actual = await snapshot(store, rootId);
        await store.close(context);
        if (!isDeepStrictEqual(actual, pre)) throw new Error(`${name} saved pre differs`);
        const resumed = await resume(backend, checkPath, scenario, ids, rootId);
        if (!isDeepStrictEqual(resumed, post)) throw new Error(`${name} saved post differs`);
      } else {
        await mkdir(dest, { recursive: true });
        if (backend === 'sqlite') await copyFile(prePath, join(dest, file));
        else await copy(backend, prePath, join(dest, file));
      }
    }
    const serialized = JSON.stringify({ tag: upstreamTag, clock, cases }) + '\n';
    if (check) {
      if (await readFile(join(output, 'manifest.json'), 'utf8') !== serialized) throw new Error('Manifest differs');
    } else {
      await mkdir(output, { recursive: true });
      await writeFile(join(output, 'manifest.json'), serialized);
    }
    console.log(`D6 tool resume ${check ? 'matches' : 'written'}: ${scenarios.length} scenarios, SQLite and JSONL.`);
  }
} finally {
  Date.now = oldDateNow;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  Math.random = oldMathRandom;
  crypto.getRandomValues = oldGetRandomValues;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
