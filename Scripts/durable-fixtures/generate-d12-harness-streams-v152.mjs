// Tagged Harness provider streams, compared with Swift by stored commit sequence
// and pi.live base/delta content. The partial clock stays fixed until final.
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152 } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const root = fileURLToPath(new URL('../../', import.meta.url));
const output = fileURLToPath(new URL('./d12-harness-streams-v152.json', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d12-streams-'));
let source;
const oldDateNow = Date.now, oldMathRandom = Math.random, oldGetRandomValues = crypto.getRandomValues;
const oldPerformanceNow = Object.getOwnPropertyDescriptor(performance, 'now');
const clock = 1_700_000_000_000;
const scenarios = ['text', 'thinking', 'arguments', 'output', 'crash', 'close'];
const json = value => JSON.parse(JSON.stringify(value));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    const result = Object.fromEntries(Object.entries(value).map(([key, member]) => [key, normalize(member)]));
    if (result.role === 'assistant' && result.api !== undefined) result.api = '<faux-api>';
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
try {
  source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineTool } = await source.import('packages/durable/src/harness/define.ts');
  const { createModels, createProvider } = await source.import('packages/ai/src/models.ts');
  const { createAssistantMessageEventStream } = await source.import('packages/ai/src/utils/event-stream.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  Date.now = () => clock;
  Object.defineProperty(performance, 'now', { configurable: true, value: () => 0 });
  Math.random = () => 0.5;
  crypto.getRandomValues = value => value.fill(0x42);
  async function run(scenario, backend) {
    const path = join(temporary, `${scenario}-${backend}${backend === 'sqlite' ? '.sqlite' : ''}`);
    const base = backend === 'sqlite' ? await openNodeSqliteStorage(path) : await openNodeJsonlStorage(path, context);
    const batches = [], sequences = [];
    const store = new Proxy(base, { get(target, property) {
      if (property === 'commit') return async (parts, receive, commitContext) => {
        const offset = batches.length;
        for (const part of parts) batches.push(json(part));
        return target.commit(parts, (index, seq) => { sequences[offset + index] = seq; receive?.(index, seq); }, commitContext);
      };
      const value = target[property];
      return typeof value === 'function' ? value.bind(target) : value;
    } });
    const manual = scenario === 'crash' || scenario === 'close';
    const faux = fauxProvider({ tokenSize: { min: 100, max: 100 } }), models = createModels(), registry = createRegistry();
    const stream = manual ? createAssistantMessageEventStream() : undefined;
    let reached;
    const seen = new Promise(resolve => { reached = resolve; });
    if (manual) {
      const streaming = (_model, _context, options) => {
        options?.signal?.addEventListener('abort', () => {
          const error = fauxAssistantMessage([], { stopReason: 'aborted' });
          stream.push({ type: 'error', reason: 'aborted', error });
          stream.end(error);
        }, { once: true });
        reached();
        return stream;
      };
      const provider = createProvider({ id: 'faux', models: faux.models,
        auth: { apiKey: { name: 'Faux', resolve: async () => ({ auth: {} }) } },
        api: { stream: streaming, streamSimple: streaming } });
      models.setProvider(provider);
    } else models.setProvider(faux.provider);
    let now = clock;
    const timers = [];
    let partialScheduled, persistScheduled;
    const partialTimer = new Promise(resolve => { partialScheduled = resolve; });
    const persistTimer = new Promise(resolve => { persistScheduled = resolve; });
    const setTimer = (callback, delayMs, { background }) => {
      if (background) return undefined;
      const timer = { callback, at: now + delayMs, armed: true };
      timers.push(timer);
      if (delayMs === 100) partialScheduled();
      if (delayMs === 150) persistScheduled();
      return () => { timer.armed = false; };
    };
    async function advance(ms, harness) {
      now += ms;
      for (const timer of timers) {
        if (!timer.armed || timer.at > now) continue;
        timer.armed = false;
        timer.callback();
      }
      await harness.readOnLine(async () => {});
    }
    if (scenario === 'arguments' || scenario === 'output') registry.install({ name: 'd12-stream-tool', tools: [
      defineTool({ name: 'echo', description: 'Echo', parameters: { type: 'object', properties: {
        text: { type: 'string' } }, required: ['text'] }, execute: async (_args, api) => {
        if (scenario === 'output') { api.output('one\n'); api.output('two\n'); }
        return { output: [{ type: 'text', text: 'tool done' }] };
      } }),
    ] });
    const harness = await Harness.open(store, { models, registry, now: () => now, setTimer,
      settings: { retry: { enabled: false }, progress: { persistWithinMs: manual && scenario === 'crash' ? 150 : Infinity } } }, context);
    const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
    const baseCount = batches.length;
    const live = await base.findDocument({ kind: 'pi.live', scope: { kind: 'conversation', conversationId: root.id } }, 'current', context);
    const answer = fauxAssistantMessage([fauxText('done')]);
    if (scenario === 'text') faux.setResponses([fauxAssistantMessage([fauxText('abcd efgh')])]);
    else if (scenario === 'thinking') faux.setResponses([fauxAssistantMessage([
      { type: 'thinking', thinking: 'why now' }, fauxText('done')])]);
    else if (!manual) faux.setResponses([fauxAssistantMessage([fauxToolCall('echo', { text: 'hello' }, { id: 'call-1' })],
      { stopReason: 'toolUse' }), answer]);
    const submission = await root.submit({ type: 'input', content: 'go' }, context);
    if (manual) {
      let timeout;
      try { await Promise.race([seen, new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`${scenario} provider did not start`)), 5_000);
      })]); } finally { clearTimeout(timeout); }
      stream.push({ type: 'text_delta', contentIndex: 0, delta: 'held',
        partial: fauxAssistantMessage([fauxText('held')], { stopReason: 'pending' }) });
      await partialTimer;
      await advance(100, harness);
      if (scenario === 'crash') {
        await persistTimer;
        await advance(150, harness);
        harness.fail(new Error('fixture crash'));
        await harness.closed;
      } else await harness.close(context);
    } else {
      const receipt = await submission.wait(context);
      if (receipt.status !== 'done') throw new Error(`${scenario}-${backend}: ${JSON.stringify(receipt)}`);
      await root.waitForIdle(context);
    }
    const summary = batches.slice(baseCount).map((writes, index) => ({ seq: sequences[baseCount + index],
      live: writes.filter(write => write.type === 'document.change' && write.id === live.id)
        .map(write => write.content) }));
    if (summary.some(item => item.seq === undefined)) throw new Error(`${scenario}-${backend}: stored batch has no receipt`);
    if (!manual) await harness.close(context);
    return normalize(summary);
  }
  const cases = {};
  for (const scenario of scenarios) {
    const sqlite = await run(scenario, 'sqlite'), jsonl = await run(scenario, 'jsonl');
    const mismatch = difference(sqlite, jsonl);
    if (mismatch) throw new Error(`${scenario} tagged storage: ${mismatch}`);
    cases[scenario] = sqlite;
  }
  const serialized = JSON.stringify({ tag: 'v1.5.2', clock, cases }) + '\n';
  if (check) {
    if (await readFile(output, 'utf8') !== serialized) throw new Error('Harness stream fixture differs');
    const child = spawnSync('swift', ['test', '--skip-build', '--filter', 'D12HarnessStreamTests'], {
      cwd: root, stdio: 'inherit', timeout: 90_000,
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift Harness streams exited ${child.status}`);
  } else await writeFile(output, serialized);
  console.log(`D12 Harness streams match: ${scenarios.length} provider scripts on SQLite and JSONL.`);
} finally {
  Date.now = oldDateNow;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  Math.random = oldMathRandom;
  crypto.getRandomValues = oldGetRandomValues;
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
