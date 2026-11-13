// Deterministic v1.5.2 conversations with afterTool, afterRun, and atomic submit.
import { spawnSync } from 'node:child_process';
import { cp, copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
import { isDeepStrictEqual } from 'node:util';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const output = fileURLToPath(new URL('./d6-conversations-v152.json', import.meta.url));
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d6-conversations-'));
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { defineExtension, defineTool, hook, runEndTask } = await source.import('packages/durable/src/harness/define.ts');
const { defineTask } = await source.import('packages/durable/src/tasks.ts');
const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
const { createModels } = await source.import('packages/ai/src/models.ts');
const { fauxProvider, fauxAssistantMessage, fauxText, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
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
function normalizeCrossLanguage(value) {
  if (Array.isArray(value)) return value.map(normalizeCrossLanguage);
  if (value && typeof value === 'object') {
    const result = Object.fromEntries(Object.entries(value).map(([key, member]) => [key, normalizeCrossLanguage(member)]));
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
  return { tasks, submissions, entries, documents, values };
}

async function run(backend, seed) {
  const kind = seed < 25 ? 'afterTool' : seed < 30 ? 'afterRun' : seed === 30 ? 'atomicSubmit' : 'afterRunFailed';
  const path = join(temporary, `${seed}-${backend}${backend === 'sqlite' ? '.sqlite' : ''}`);
  const store = backend === 'sqlite' ? await openNodeSqliteStorage(path) : await openNodeJsonlStorage(path, context);
  const faux = fauxProvider(), models = createModels(), registry = createRegistry();
  models.setProvider(faux.provider);
  if (kind === 'afterTool') {
    registry.install(defineExtension({ name: 'd6-hook',
      tools: [defineTool({ name: 'echo', description: 'Echo', parameters: { type: 'object', properties: {} },
        execute: async () => ({ output: [{ type: 'text', text: 'original' }] }) })],
      hooks: [hook(ToolTask, { afterTool: async (_call, result) => ({
        ...result, output: [{ type: 'text', text: `replaced-${seed}` }],
      }) })],
    }));
  } else if (kind === 'afterRun' || kind === 'afterRunFailed') {
    const Child = defineTask({ name: 'd6.after-run', version: 1, initial: () => ({ phase: 'run' }),
      phases: { run: async (task, runtime, ctx) => {
        await runtime.commit(async tx => {
          await tx.appendEntry(runtime.conversationId, { kind: 'd6.after-run', data: task.input.label });
          return { status: 'terminal', outcome: kind === 'afterRunFailed'
            ? { status: 'failed', error: { message: 'child failed' } }
            : { status: 'completed', result: task.input.label } };
        }, ctx);
      } },
    });
    registry.install(defineExtension({ name: 'd6-after-run', tasks: [Child],
      hooks: [hook(GenerationTask, { afterRun: async () => ({
        tasks: [runEndTask(Child, { label: `child-${seed}` })],
      }) })],
    }));
  }
  const harness = await Harness.open(store, { models, registry, now: () => clock,
    settings: { retry: { enabled: false } } }, context);
  const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
  const answer = fauxAssistantMessage([fauxText(`answer-${seed}`)]);
  faux.setResponses(kind === 'afterTool'
    ? [fauxAssistantMessage([fauxToolCall('echo', {}, { id: `call-${seed}` })], { stopReason: 'toolUse' }), answer]
    : [answer]);
  let first;
  if (kind === 'atomicSubmit') {
    const id = await root.commit(async tx => {
      const admitted = await root.submit(tx, { type: 'input', content: `question-${seed}` });
      await tx.appendEntry(root.id, { kind: 'd6.host-write', data: { submission: admitted } });
      return admitted;
    }, context);
    first = json(await (await harness.submission(id, context)).wait(context));
  } else first = json(await (await root.submit({ type: 'input', content: `question-${seed}` }, context)).wait(context));
  await root.waitForIdle(context);
  const records = await snapshot(store, root.id);
  await harness.close(context);
  return { seed, kind, first, records };
}

try {
  const scripts = [];
  for (let seed = 20; seed < 32; seed++) {
    const sqlite = await run('sqlite', seed);
    const jsonl = await run('jsonl', seed);
    if (JSON.stringify(sqlite) !== JSON.stringify(jsonl)) throw new Error(`Backend differs at seed ${seed}`);
    scripts.push(sqlite);
  }
  if (check) {
    for (const backend of ['sqlite', 'jsonl']) {
      const from = join(temporary, `30-${backend}${backend === 'sqlite' ? '.sqlite' : ''}`);
      const to = join(temporary, `tagged-atomic-${backend}`);
      if (backend === 'sqlite') await copyFile(from, to);
      else await cp(from, to, { recursive: true });
    }
    const swift = spawnSync('swift', ['test', '--skip-build', '--filter', 'D6ConversationFixtureTests'], {
      cwd: fileURLToPath(new URL('../../', import.meta.url)),
      env: { ...process.env, PISWIFT_D12_ATOMIC_EXPORT: temporary, PISWIFT_D12_TAGGED_ATOMIC_DIR: temporary },
      stdio: 'inherit', timeout: 180_000,
    });
    if (swift.error) throw swift.error;
    if (swift.status !== 0) throw new Error(`Swift atomic cross-open exited ${swift.status}`);
    for (const backend of ['sqlite', 'jsonl']) {
      const path = join(temporary, `swift-atomic-${backend}`);
      const store = backend === 'sqlite' ? await openNodeSqliteStorage(path) : await openNodeJsonlStorage(path, context);
      const page = await store.scanConversations({}, 2, undefined, context);
      if (page.items.length !== 1) throw new Error(`Swift atomic ${backend}: expected one conversation`);
      const actual = await snapshot(store, page.items[0].id);
      await store.close(context);
      const mismatch = difference(normalizeCrossLanguage(actual), normalizeCrossLanguage(scripts.find(item => item.seed === 30).records));
      if (mismatch) throw new Error(`Swift atomic ${backend}: ${mismatch}`);
    }
  }
  const serialized = JSON.stringify({ tag: upstreamTag, clock, scripts }) + '\n';
  if (check) {
    if (await readFile(output, 'utf8') !== serialized) throw new Error('D6 conversations differ');
  } else await writeFile(output, serialized);
  console.log(`D6 conversations ${check ? 'match' : 'written'}: ${scripts.length} scripts, SQLite and JSONL.`);
} finally {
  Date.now = oldDateNow;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  Math.random = oldMathRandom;
  crypto.getRandomValues = oldGetRandomValues;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
