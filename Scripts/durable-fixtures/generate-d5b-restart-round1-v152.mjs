// Tagged v1.5.2 restart states and canonical continuation records.
import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { gzipSync, gunzipSync } from 'node:zlib';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const output = fileURLToPath(new URL('./d5b-restart-round1-v152/', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d5b-restart-round1-'));
const swiftSeeds = join(temporary, 'swift-seeds');
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
const { UserEntry, AssistantEntry, ToolResultEntry } = await source.import('packages/durable/src/entries.ts');
const { createModels } = await source.import('packages/ai/src/models.ts');
const { fauxProvider, fauxAssistantMessage } = await source.import('packages/ai/src/providers/faux.ts');
const { commitWrites } = await source.import('packages/durable/src/testing/commit-writes.ts');
const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
const clock = 1700000000000;
let now = clock;
const oldDateNow = Date.now;
Date.now = () => now;
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    const object = Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v)]));
    if (object.role === 'assistant' && object.api !== undefined) object.api = '<faux-api>';
    return object;
  }
  return value;
}
function equal(actual, expected, label) {
  if (!isDeepStrictEqual(actual, expected)) {
    throw new Error(`${label} differs`);
  }
}
async function storage(backend, path) {
  return backend === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
}
async function snapshot(store, rootId) {
  const tasks = await store.scanTasks({ order: 'ascending' }, 100, undefined, context);
  const submissions = await store.scanSubmissions({ order: 'ascending' }, 100, undefined, context);
  const entries = await store.scanEntries({ conversationId: rootId, order: 'ascending' }, 100, undefined, context);
  const documents = await store.scanDocuments({ scope: { kind: 'conversation', conversationId: rootId }, at: 'current' }, 100, undefined, context);
  if ([tasks, submissions, entries, documents].some(page => page.next)) throw new Error('Snapshot page limit');
  const values = [];
  for (const doc of documents.items) {
    const value = json(await store.document(doc.id, 'current', context));
    if (doc.kind === 'pi.provider') value.value.sessionId = '<provider-session-id>';
    values.push(value);
  }
  return normalize(json({ tasks: tasks.items, submissions: submissions.items, entries: entries.items, documents: documents.items, values }));
}
const scenarios = [
  { name: 'request-retry', line: 141, retry: true },
  { name: 'request-backoff', line: 180, retry: true, sleepOnly: true },
  { name: 'request-exhausted', line: 204, attempt: 2, retry: true, maxRetries: 1 },
  { name: 'sleeping-retry', line: 275, retry: true },
  { name: 'waiting-tools', line: 275 },
  { name: 'prepare-limit', line: 330, limit: 1 },
  { name: 'poll-retry', line: 523, retry: true },
  { name: 'poll-cancel', line: 554 },
  { name: 'poll-clock-backward', line: 574 },
  { name: 'crash-clean-close', line: 596, retry: true, cleanClose: true },
  { name: 'charge-limit', line: 621, limit: 1 },
  { name: 'drop-partial', line: 648, limit: 2, restarts: 2 },
  { name: 'abort-limit', line: 671, limit: 2, restarts: 1, abort: true },
];
const settings = scenario => ({ retry: { enabled: !!scenario.retry, maxRetries: scenario.maxRetries ?? 2, baseDelayMs: 60000 },
  ...(scenario.limit ? { restartLimit: scenario.limit } : {}) });
function options(scenario) {
  const models = createModels(), faux = fauxProvider({ api: 'fixture-faux' });
  models.setProvider(faux.provider);
  faux.setResponses([fauxAssistantMessage('answer')]);
  const fetched = [], cancelled = [];
  models.fetchDeferred = async (_model, handle) => { fetched.push(handle.id); return fauxAssistantMessage('deferred answer'); };
  models.cancelDeferred = async (_model, handle) => { cancelled.push(handle.id); };
  return { options: { models, registry: createRegistry(), now: () => now, settings: settings(scenario) }, fetched, cancelled };
}
async function seed(backend, path, scenario) {
  now = clock;
  const store = await storage(backend, path), setup = options(scenario);
  const harness = await Harness.open(store, setup.options, context), root = await harness.root(context,
    { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
  const ids = await root.commit(async tx => {
    const user = await tx.appendEntry(UserEntry, root.id, { model: [{ role: 'user', content: 'hi', timestamp: clock }] });
    if (scenario.attempt === 2) await tx.appendEntry(AssistantEntry, root.id,
      { model: [fauxAssistantMessage('first partial', { stopReason: 'aborted' })] });
    const submission = await tx.createSubmission({ type: 'input', status: 'placed', conversationId: root.id, entry: user.id });
    const taskId = await tx.createTask(GenerationTask, {}, { ownership: { kind: 'conversation' }, conversationId: root.id });
    const live = await tx.doc(LiveDoc, root.id);
    live.run = { taskId, inputs: [submission.id], turns: 0, first: user.id };
    if (!scenario.name.startsWith('poll') && !['prepare-limit', 'abort-limit', 'sleeping-retry', 'waiting-tools'].includes(scenario.name))
      live.generation = { attempt: scenario.attempt ?? 1, message: fauxAssistantMessage(scenario.attempt === 2 ? 'second partial' : 'partial') };
    let assistant, tool, result;
    if (scenario.name === 'waiting-tools') {
      assistant = await tx.appendEntry(AssistantEntry, root.id, { model: [fauxAssistantMessage([{ type: 'toolCall', id: 'c1', name: 'hold', arguments: {} }], { stopReason: 'toolUse' })] });
      result = await tx.appendEntry(ToolResultEntry, root.id, { model: [{ role: 'toolResult', toolCallId: 'c1', toolName: 'hold', content: [], isError: false, timestamp: clock }] });
      tool = await tx.createTask(ToolTask, { kind: 'model', assistant: assistant.id, callId: 'c1' }, { ownership: { kind: 'task', taskId }, conversationId: root.id });
      live.run.turns = 1;
    }
    return { user: user.id, submission: submission.id, taskId, ...(tool ? { tool, assistant: assistant.id, result: result.id } : {}) };
  }, context);
  await harness.close(context);
  // The raw write preserves the pre-loss running state. It cannot invoke a handler.
  const raw = await storage(backend, path), record = await raw.task(ids.taskId, context);
  const poll = scenario.name.startsWith('poll') || scenario.abort;
  let checkpoint = poll ? { phase: 'poll', attempt: 1, model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', cutoff: ids.user,
    handle: { provider: 'faux', modelId: 'faux-1', api: 'fixture-faux', id: 'deferred:d5b-restart' }, pollAt: clock + (scenario.name === 'poll-clock-backward' ? 10 : 0) }
    : { phase: 'request', attempt: scenario.attempt ?? 1, model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', streamOptions: {}, cutoff: ids.user };
  let state = { status: 'running', checkpoint };
  if (scenario.name === 'prepare-limit') state.checkpoint = { phase: 'prepare', attempt: 1 };
  if (scenario.name === 'sleeping-retry') state = { status: 'sleeping', until: clock,
    checkpoint: { phase: 'retry', attempt: 1, until: clock } };
  const writes = [];
  if (scenario.name === 'waiting-tools') {
    state = { status: 'waiting', checkpoint: { phase: 'tools', assistant: ids.assistant, tools: [ids.tool], pending: [] }, on: [ids.tool], policy: 'allSettled' };
    writes.push({ type: 'task', value: { ...await raw.task(ids.tool, context), state: { status: 'terminal', outcome: { status: 'completed', result: { kind: 'model', entryId: ids.result } } } } });
  }
  writes.push({ type: 'task', value: { ...record, state, ...(scenario.restarts ? { restarts: scenario.restarts } : {}), ...(scenario.abort ? { abortRequested: true } : {}) } });
  await commitWrites(raw, writes, context);
  const pre = await snapshot(raw, root.id);
  await raw.close(context);
  return { ids, rootId: root.id, pre };
}
async function waitFor(condition) {
  const end = performance.now() + 10000;
  while (!await condition()) {
    if (performance.now() > end) throw new Error('Restart did not reach its boundary');
    await new Promise(resolve => setTimeout(resolve, 1));
  }
}
async function resume(backend, path, item) {
  now = clock;
  let store = await storage(backend, path), setup = options(item.scenario);
  let harness = await Harness.open(store, setup.options, context);
  if (item.scenario.cleanClose) {
    await harness.close(context);
    store = await storage(backend, path);
    harness = await Harness.open(store, setup.options, context);
  }
  const afterOpen = await snapshot(store, item.rootId);
  harness.resume();
  let sleeping;
  if (item.scenario.retry && item.scenario.name !== 'request-exhausted' && item.scenario.name !== 'sleeping-retry') {
    await waitFor(async () => (await harness.getTask(item.ids.taskId, context))?.state.status === 'sleeping');
    sleeping = await snapshot(store, item.rootId);
    if (!item.scenario.sleepOnly) { now += 60000; harness.resume(); }
  }
  if (!item.scenario.sleepOnly) {
    await waitFor(async () => (await harness.getTask(item.ids.taskId, context))?.state.status === 'terminal');
    await (await harness.submission(item.ids.submission, context)).wait(context);
    await (await harness.root(context)).waitForIdle(context);
  }
  const post = await snapshot(store, item.rootId);
  const calls = { fetched: setup.fetched, cancelled: setup.cancelled };
  await harness.close(context);
  return { afterOpen, ...(sleeping ? { sleeping } : {}), post, calls: json(calls) };
}
try {
  const manifest = { tag: upstreamTag, clock, normalization: 'Provider session UUID and faux assistant API only',
    notApplicable: { '737': 'Normal-path settings resolution count has no restart state. Direct Swift test: normalRoundsDoNotResolveRestartLimitPerTask.' }, cases: {} };
  for (const scenario of scenarios) for (const backend of ['sqlite', 'jsonl']) {
    const name = `${scenario.name}-${backend}`, suffix = backend === 'sqlite' ? '.sqlite' : '';
    const prePath = join(temporary, `${name}-pre${suffix}`), postPath = join(temporary, `${name}-post${suffix}`);
    const seedData = await seed(backend, prePath, scenario);
    await cp(prePath, postPath, { recursive: true });
    const item = { scenario, backend, ...seedData };
    Object.assign(item, await resume(backend, postPath, item));
    manifest.cases[name] = item;
    const destination = join(output, name);
    if (check) {
      for (const stage of ['pre']) {
        const savedPath = join(temporary, `${name}-saved-${stage}${suffix}`);
        if (backend === 'sqlite') await writeFile(savedPath, gunzipSync(await readFile(join(destination, `${stage}.sqlite.gz`))));
        else await cp(join(destination, stage), savedPath, { recursive: true });
        const saved = await storage(backend, savedPath);
        equal(await snapshot(saved, item.rootId), item[stage], `${name} saved ${stage}`);
        await saved.close(context);
        const seed = join(swiftSeeds, name);
        await mkdir(seed, { recursive: true });
        await cp(savedPath, join(seed, backend === 'sqlite' ? 'pre.sqlite' : 'pre'), { recursive: true });
      }
      const checkPath = join(temporary, `${name}-check${suffix}`);
      if (backend === 'sqlite') await writeFile(checkPath, gunzipSync(await readFile(join(destination, 'pre.sqlite.gz'))));
      else await cp(join(destination, 'pre'), checkPath, { recursive: true });
      equal(await resume(backend, checkPath, item), { afterOpen: item.afterOpen, ...(item.sleeping ? { sleeping: item.sleeping } : {}), post: item.post, calls: item.calls }, `${name} saved continuation`);
    } else {
      await mkdir(destination, { recursive: true });
      for (const obsolete of ['post', 'post.sqlite', 'post.sqlite.gz']) await rm(join(destination, obsolete), { recursive: true, force: true });
      for (const stage of ['pre']) {
        await rm(join(destination, `${stage}${suffix}`), { recursive: true, force: true });
        if (backend === 'sqlite') await writeFile(join(destination, `${stage}.sqlite.gz`), gzipSync(await readFile(stage === 'pre' ? prePath : postPath)));
        else await cp(stage === 'pre' ? prePath : postPath, join(destination, stage), { recursive: true });
      }
    }
    console.log(`${name}: tag restart records ${check ? 'match' : 'written'}`);
  }
  const serialized = JSON.stringify(manifest, null, 2) + '\n';
  if (check) {
    equal(gunzipSync(await readFile(join(output, 'manifest.json.gz'))).toString('utf8'), serialized, 'Manifest');
    const swiftExport = join(temporary, 'swift-export');
    await mkdir(swiftExport);
    const child = spawnSync('swift', ['test', '--skip-build', '--filter',
      'D5bRestartMatrixTests.exportsSwiftWrittenRestartPreFiles'], {
      cwd: fileURLToPath(new URL('../../', import.meta.url)), stdio: 'inherit', timeout: 180_000,
      env: { ...process.env, PISWIFT_D12_RESTART_SEEDS: swiftSeeds, PISWIFT_D12_RESTART_EXPORT: swiftExport },
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift restart export exited ${child.status}`);
    for (const [name, item] of Object.entries(manifest.cases)) {
      const suffix = item.backend === 'sqlite' ? '.sqlite' : '';
      const path = join(temporary, `swift-${name}${suffix}`);
      await cp(join(swiftExport, name, item.backend === 'sqlite' ? 'pre.sqlite' : 'pre'), path, { recursive: true });
      const store = await storage(item.backend, path);
      equal(await snapshot(store, item.rootId), item.pre, `${name} Swift-written pre records`);
      await store.close(context);
      const actual = await resume(item.backend, path, item);
      equal(actual, { afterOpen: item.afterOpen, ...(item.sleeping ? { sleeping: item.sleeping } : {}),
        post: item.post, calls: item.calls }, `${name} tagged reverse continuation`);
    }
  } else { await writeFile(join(output, 'manifest.json.gz'), gzipSync(serialized)); await rm(join(output, 'manifest.json'), { force: true }); }
} finally {
  Date.now = oldDateNow;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
