// Twenty deterministic v1.5.2 Harness conversations on both storage backends.
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const output = fileURLToPath(new URL('./d5b-conversations-v152.json', import.meta.url));
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d5b-conversations-'));
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { defineTool } = await source.import('packages/durable/src/harness/define.ts');
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
const kinds = ['simple', 'simple', 'simple', 'continue', 'continue', 'continue',
  'tool', 'tool', 'tool', 'turnLimit', 'turnLimit', 'turnLimit', 'handoff', 'handoff',
  'followUp', 'followUp', 'abort', 'abort', 'compaction', 'compaction'];
const scripts = kinds.map((kind, seed) => ({ seed, kind }));
function gate() {
  let release;
  const promise = new Promise(resolve => { release = resolve; });
  return { promise, release };
}
async function run(kind, script) {
  const path = join(temporary, `${script.seed}-${kind}${kind === 'sqlite' ? '.sqlite' : ''}`);
  const store = kind === 'sqlite' ? await openNodeSqliteStorage(path) : await openNodeJsonlStorage(path, context);
  const faux = fauxProvider(), models = createModels(), registry = createRegistry();
  models.setProvider(faux.provider);
  if (['tool', 'turnLimit', 'handoff'].includes(script.kind)) {
    registry.install({ name: 'fixture-tools', tools: [defineTool({
      name: 'echo', description: 'Echo', parameters: { type: 'object', properties: {} },
      execute: async () => ({ output: [{ type: 'text', text: 'tool output' }],
        ...(script.kind === 'handoff' ? { control: { handoff: `fresh-${script.seed}` } } : {}) }),
    })] });
  }
  const harness = await Harness.open(store, { models, registry, now: () => clock,
    settings: { retry: { enabled: false }, ...(script.kind === 'compaction'
      ? { compaction: { enabled: false, keepRecentTokens: 1 } } : {}) } }, context);
  const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' },
    ...(script.kind === 'turnLimit' ? { maxTurns: 1 } : {}) } });
  const answer = () => fauxAssistantMessage([fauxText(`answer-${script.seed}`)]);
  let first, second, queued;
  if (script.kind === 'simple') {
    faux.setResponses([answer()]);
    first = json(await (await root.submit({ type: 'input', content: `question-${script.seed}` }, context)).wait(context));
  } else if (script.kind === 'continue') {
    faux.setResponses([fauxAssistantMessage([], { stopReason: 'error', errorMessage: `invalid-${script.seed}` })]);
    first = json(await (await root.submit({ type: 'input', content: `question-${script.seed}` }, context)).wait(context));
    faux.setResponses([answer()]);
    second = json(await (await root.submit({ type: 'continue' }, context)).wait(context));
  } else if (script.kind === 'followUp' || script.kind === 'abort') {
    const reached = gate(), held = gate();
    faux.setResponses([async (_transcript, options) => {
      reached.release();
      const signal = options.signal;
      const release = () => held.release();
      signal.addEventListener('abort', release, { once: true });
      try { if (signal.aborted) held.release(); await held.promise; }
      finally { signal.removeEventListener('abort', release); }
      return answer();
    }, answer()]);
    const input = await root.submit({ type: 'input', content: `question-${script.seed}` }, context);
    await reached.promise;
    if (script.kind === 'followUp') {
      const next = await root.submit({ type: 'input', content: `follow-up-${script.seed}` }, context);
      queued = json(await next.status(context));
      if (queued.status !== 'queued') throw new Error('Follow-up was not queued');
      held.release();
      first = json(await input.wait(context));
      second = json(await next.wait(context));
    } else {
      await root.abort(context);
      first = json(await input.wait(context));
      if (first.reason !== 'aborted') throw new Error('Abort did not settle the input');
    }
  } else if (script.kind === 'compaction') {
    faux.setResponses([answer(), answer(), fauxAssistantMessage([fauxText(`summary-${script.seed}`)]), answer()]);
    first = json(await (await root.submit({ type: 'input', content: `question-${script.seed}` }, context)).wait(context));
    await (await root.submit({ type: 'input', content: `history-${script.seed}` }, context)).wait(context);
    await harness.waitForTask(await root.compact(undefined, context), context);
    second = json(await (await root.submit({ type: 'input', content: `after-summary-${script.seed}` }, context)).wait(context));
  } else {
    faux.setResponses([fauxAssistantMessage([fauxToolCall('echo', {}, { id: `call-${script.seed}` })], { stopReason: 'toolUse' }), answer()]);
    first = json(await (await root.submit({ type: 'input', content: `question-${script.seed}` }, context)).wait(context));
    if (script.kind === 'turnLimit') {
      second = json(await (await root.submit({ type: 'continue' }, context)).wait(context));
    }
  }
  await root.waitForIdle(context);
  const records = await snapshot(store, root.id);
  if (script.kind === 'compaction' && !records.entries.some(entry => entry.kind === 'pi.compaction'))
    throw new Error('Compaction did not save a summary entry');
  await harness.close(context);
  return { first, second, queued, records };
}
try {
  const fixture = { tag: upstreamTag, clock, normalization: 'pi.provider.sessionId only: UUID randomness differs by runtime', scripts: [] };
  for (const script of scripts) {
    const sqlite = await run('sqlite', script);
    const jsonl = await run('jsonl', script);
    if (JSON.stringify(sqlite) !== JSON.stringify(jsonl)) {
      for (const key of ['first', 'second', 'queued', 'records']) {
        if (JSON.stringify(sqlite[key]) !== JSON.stringify(jsonl[key])) {
          const left = JSON.stringify(sqlite[key]), right = JSON.stringify(jsonl[key]);
          const at = [...left].findIndex((character, index) => character !== right[index]);
          throw new Error(`Storage differs for seed ${script.seed} in ${key} at ${at}: ${left.slice(at, at + 160)} / ${right.slice(at, at + 160)}`);
        }
      }
    }
    fixture.scripts.push({ ...script, ...sqlite });
  }
  const serialized = JSON.stringify(fixture) + '\n';
  if (check) {
    if (await readFile(output, 'utf8') !== serialized) throw new Error('D5b conversation fixture differs');
  } else {
    await mkdir(fileURLToPath(new URL('./', import.meta.url)), { recursive: true });
    await writeFile(output, serialized);
  }
  console.log(`D5b conversations ${check ? 'match' : 'written'}: 20 scripts, SQLite and JSONL.`);
} finally {
  Date.now = oldDateNow;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  Math.random = oldMathRandom;
  crypto.getRandomValues = oldGetRandomValues;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
