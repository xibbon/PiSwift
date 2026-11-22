// Swift-written v1.5.2 restart images, resumed by the unmodified tagged runtime.
// Run without arguments to write fixtures; --check verifies fresh Swift files and saved files.
import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { gzipSync, gunzipSync } from 'node:zlib';
import { mirrorV152 } from './mirror-v152.mjs';
import { mirrorV160 } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const v160 = process.argv.includes('--v160');
const tag = v160 ? 'v1.6.0' : 'v1.5.2';
const output = fileURLToPath(new URL(v160 ? './d5b-reverse-v160/' : './d5b-reverse-v152/', import.meta.url));
const root = fileURLToPath(new URL('../../', import.meta.url));
const check = process.argv.includes('--check');
const verifyIndex = process.argv.indexOf('--verify-swift');
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d5b-reverse-'));
let source;
const oldDateNow = Date.now, oldMathRandom = Math.random, oldGetRandomValues = crypto.getRandomValues;
const oldPerformanceNow = Object.getOwnPropertyDescriptor(performance, 'now');
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
function difference(actual, expected, path = '$') {
  if (isDeepStrictEqual(actual, expected)) return undefined;
  if (actual && expected && typeof actual === 'object' && typeof expected === 'object') {
    for (const key of new Set([...Object.keys(actual), ...Object.keys(expected)])) {
      const mismatch = difference(actual[key], expected[key], `${path}.${key}`);
      if (mismatch) return mismatch;
    }
  }
  return `${path}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`;
}
function equal(actual, expected, description) {
  const mismatch = difference(actual, expected);
  if (mismatch) throw new Error(`${description}: ${mismatch}`);
}
try {
  let generated;
  if (verifyIndex >= 0) {
    generated = process.argv[verifyIndex + 1];
    if (!generated) throw new Error('--verify-swift needs a fixture directory');
  } else if (check && !v160) {
    // Keep checking the frozen v1.5.2 files with their own tagged runtime.
    // A new Swift export now writes v1.6.0 task versions.
    generated = output;
  } else {
    generated = join(temporary, 'swift');
    await mkdir(generated);
    const child = spawnSync('swift', ['test', '--filter', 'D5bReverseFixtureTests'], {
      cwd: root, env: { ...process.env, PISWIFT_D5B_REVERSE_EXPORT: generated }, stdio: 'inherit', timeout: 240_000,
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift fixture export exited ${child.status}`);
  }
  const manifest = JSON.parse(await readFile(join(generated, 'manifest.json'), 'utf8'));
  const expectedNames = ['continue', 'turn-limit', 'model-error-retry', 'host-death-request', 'interrupted-poll', 'handoff']
    .flatMap(scenario => ['sqlite', 'jsonl'].map(backend => `${scenario}-${backend}`)).sort();
  if (manifest.tag !== tag || !isDeepStrictEqual(Object.keys(manifest.cases).sort(), expectedNames)) {
    throw new Error('Expected six scenarios on two backends');
  }
  source = await (v160 ? mirrorV160 : mirrorV152)({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineTool } = await source.import('packages/durable/src/harness/define.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  Date.now = () => manifest.resumeClock;
  Object.defineProperty(performance, 'now', { configurable: true, value: () => 0 });
  Math.random = () => 0.5;
  crypto.getRandomValues = value => value.fill(0x42);
  const storage = (backend, path) => backend === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
  async function snapshot(store, rootId) {
    const tasks = await store.scanTasks({ order: 'ascending' }, 100, undefined, context);
    const submissions = await store.scanSubmissions({ order: 'ascending' }, 100, undefined, context);
    const entries = await store.scanEntries({ conversationId: rootId, order: 'ascending' }, 100, undefined, context);
    const documents = await store.scanDocuments({ scope: { kind: 'conversation', conversationId: rootId }, at: 'current' }, 100, undefined, context);
    if ([tasks, submissions, entries, documents].some(page => page.next)) throw new Error('Snapshot exceeded its page limit');
    const values = [];
    for (const doc of documents.items) {
      const value = json(await store.document(doc.id, 'current', context));
      if (doc.kind === 'pi.provider') value.value.sessionId = '<provider-session-id>';
      values.push(value);
    }
    return normalize(json({ conversation: await store.conversation(rootId, context), tasks: tasks.items,
      submissions: submissions.items, entries: entries.items, documents: documents.items, values }));
  }
  async function writeTaggedPre(item, path) {
    const store = await storage(item.backend, path);
    try {
      const pre = item.pre;
      // The JSONL journal records the original batch sequence and document
      // history. Replay it through the tagged adapter for both backends.
      // Old task sidecars are compacted after terminal writes, so their
      // current record is enough: task history is not read on restart.
      const journal = join(output, `${item.scenario}-jsonl`, 'pre');
      const lines = (await readFile(join(journal, 'main.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
      const content = new Map();
      for (const document of pre.documents.filter(document => document.kind === 'pi.agent')) {
        const sidecar = (await readFile(join(journal, `doc-${document.id}.jsonl`), 'utf8')).trim().split('\n').map(JSON.parse);
        for (const record of sidecar) content.set(`${record.seq}:${record.ordinal}`, record.payload.content);
      }
      const tasks = new Map(pre.tasks.map(task => [task.id, task]));
      const batches = lines.map(line => line.writes.map(write => {
        if (write.type === 'task.sidecar') {
          const value = tasks.get(write.id);
          if (!value) throw new Error(`Missing saved task ${write.id}`);
          return { type: 'task', value };
        }
        if (write.type === 'document.create' || write.type === 'document.change') {
          const id = write.record?.id ?? write.id;
          const index = pre.documents.findIndex(document => document.id === id);
          if (index < 0) throw new Error(`Missing document ${id}`);
          const saved = pre.values[index];
          const value = pre.documents[index].kind === 'pi.agent'
            ? content.get(`${line.seq}:${write.ordinal}`)
            : { kind: 'base', version: saved.version, value: saved.value };
          if (!value) throw new Error(`Missing agent history ${line.seq}:${write.ordinal}`);
          const { ordinal, ...withoutOrdinal } = write;
          return { ...withoutOrdinal, content: value };
        }
        return write;
      }));
      const result = await store.commit(batches, () => {}, context);
      if (result.stored !== batches.length || result.refused) throw new Error(`Tagged pre-file write refused: ${result.refused}`);
      equal(await snapshot(store, item.rootId), pre, `${item.scenario} tagged pre records`);
    } finally { await store.close(context); }
  }
  async function verify(directory, name, item, suffix) {
    const file = item.backend === 'sqlite' ? 'pre.sqlite' : 'pre';
    const path = join(temporary, `${name}-${suffix}${item.backend === 'sqlite' ? '.sqlite' : ''}`);
    if (item.backend === 'sqlite') {
      let data;
      try { data = await readFile(join(directory, name, file)); }
      catch (error) {
        if (error.code !== 'ENOENT') throw error;
        data = gunzipSync(await readFile(join(directory, name, `${file}.gz`)));
      }
      await writeFile(path, data);
    } else { await cp(join(directory, name, file), path, { recursive: true }); }
    const store = await storage(item.backend, path);
    equal(await snapshot(store, item.rootId), item.pre, `${name} Swift pre records`);
    const faux = fauxProvider(), models = createModels(), registry = createRegistry();
    models.setProvider(faux.provider);
    if (['turn-limit', 'handoff'].includes(item.scenario)) {
      registry.install({ name: 'reverse-tools', tools: [defineTool({ name: 'echo', description: 'Echo',
        parameters: { type: 'object', properties: {} }, execute: async () => ({
          output: [{ type: 'text', text: 'tool output' }],
          ...(item.scenario === 'handoff' ? { control: { handoff: 'fresh-16' } } : {}),
        }) })] });
    }
    const answer = fauxAssistantMessage([fauxText('answer')]);
    faux.setResponses(item.scenario === 'handoff'
      ? [fauxAssistantMessage([fauxToolCall('echo', {}, { id: 'call-reverse' })], { stopReason: 'toolUse' }), answer] : [answer]);
    const harness = await Harness.open(store, { models, registry, now: () => manifest.resumeClock,
      settings: { retry: { enabled: item.scenario === 'model-error-retry', maxRetries: 1, baseDelayMs: 1000 } } }, context);
    try {
      const root = await harness.root(context);
      let timeout;
      const result = await Promise.race([
        (async () => {
          let result;
          if (['continue', 'turn-limit'].includes(item.scenario)) result = await (await root.submit({ type: 'continue' }, context)).wait(context);
          else {
            harness.resume();
            result = await (await harness.submission(item.submissionId, context)).wait(context);
          }
          await root.waitForIdle(context);
          return result;
        })(),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error(`${name} did not settle`)), 10_000); }),
      ]).finally(() => clearTimeout(timeout));
      equal(normalize(json(result)), item.result, `${name} final submission`);
      equal(await snapshot(store, root.id), item.post, `${name} tagged continuation vs Swift continuation`);
    } finally { await harness.close(context); }
  }
  for (const [name, item] of Object.entries(manifest.cases)) await verify(generated, name, item, 'fresh');
  if (check) {
    const saved = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8'));
    equal(manifest, saved, 'Fresh Swift records vs saved fixture records');
    for (const [name, item] of Object.entries(saved.cases)) await verify(output, name, item, 'saved');
    const taggedPre = join(temporary, 'tagged-pre');
    await mkdir(taggedPre);
    for (const scenario of ['continue', 'turn-limit', 'handoff']) {
      for (const backend of ['sqlite', 'jsonl']) {
        const name = `${scenario}-${backend}`, directory = join(taggedPre, name);
        await mkdir(directory);
        await writeTaggedPre(manifest.cases[name], join(directory, backend === 'sqlite' ? 'pre.sqlite' : 'pre'));
      }
    }
    if (v160) {
    const resumed = spawnSync('swift', ['test', '--skip-build', '--filter',
      'D5bReverseFixtureTests.swiftContinuesTagWrittenPreEvents'], {
      cwd: root, stdio: 'inherit', timeout: 120_000,
      env: { ...process.env, PISWIFT_D12_TAGGED_PRE_EVENTS: taggedPre },
    });
    if (resumed.error) throw resumed.error;
    if (resumed.status !== 0) throw new Error(`Swift tagged pre-event continuation exited ${resumed.status}`);
    }
  } else if (verifyIndex < 0) {
    for (const [name, item] of Object.entries(manifest.cases)) {
      const destination = join(output, name), file = item.backend === 'sqlite' ? 'pre.sqlite' : 'pre';
      await mkdir(destination, { recursive: true });
      await rm(join(destination, file), { recursive: true, force: true });
      if (item.backend === 'sqlite') {
        await writeFile(join(destination, `${file}.gz`), gzipSync(await readFile(join(generated, name, file)), { level: 9 }));
      } else { await cp(join(generated, name, file), join(destination, file), { recursive: true }); }
    }
    await writeFile(join(output, 'manifest.json'), JSON.stringify(manifest) + '\n');
  }
  console.log(`D5b ${tag} reverse fixtures ${check || verifyIndex >= 0 ? 'match' : 'written'}: six Swift scenarios, SQLite and JSONL${v160 ? ', plus three tag-written pre-events resumed by Swift in check mode' : ''}.`);
} finally {
  Date.now = oldDateNow; Math.random = oldMathRandom; crypto.getRandomValues = oldGetRandomValues;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
