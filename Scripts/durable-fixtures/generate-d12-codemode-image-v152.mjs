// A persisted v1.5.2 model turn calls codemode, which calls read and emits a PNG.
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152 } from './mirror-v152.mjs';
import { mirrorV160 } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const v160 = process.argv.includes('--v160');
const root = fileURLToPath(new URL('../../', import.meta.url));
const output = fileURLToPath(new URL(v160 ? './d12-codemode-image-v160.json' : './d12-codemode-image-v152.json', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d12-image-'));
let source;
const oldDateNow = Date.now, oldMathRandom = Math.random, oldGetRandomValues = crypto.getRandomValues;
const oldPerformanceNow = Object.getOwnPropertyDescriptor(performance, 'now');
const clock = 1_700_000_000_000;
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==';
const code = "image(await tools.read({path:'pixel.png'}))";
const json = value => JSON.parse(JSON.stringify(value));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    const result = Object.fromEntries(Object.entries(value).map(([key, member]) => [key, normalize(member)]));
    if (result.role === 'assistant' && result.api !== undefined) result.api = '<faux-api>';
    if (result.role === 'toolResult' && result.details === null) delete result.details;
    delete result.durationMs;
    return result;
  }
  return typeof value === 'string' ? value.replaceAll(temporary, '<fixture-cwd>')
    .replaceAll('in a QuickJS sandbox', 'in the <sandbox>')
    .replaceAll('in an injected sandbox', 'in the <sandbox>')
    .replace(/\/[^\s]*\/pi-codemode-[^/\s]+\/image-\d+\.png/g, '<saved-image>') : value;
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
  source = await (v160 ? mirrorV160 : mirrorV152)({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4', 'quickjs-wasi@3.6.2'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { createCodemodeTool } = await source.import('packages/durable/src/codemode/codemode.ts');
  const { CodemodeSandbox } = await source.import('packages/codemode/src/index.ts');
  const { createReadTool } = await source.import('packages/durable/src/tools/read.ts');
  const { NodeExecutionEnv } = await source.import('packages/durable/src/env/node.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  Date.now = () => clock;
  Object.defineProperty(performance, 'now', { configurable: true, value: () => 0 });
  Math.random = () => 0.5;
  crypto.getRandomValues = value => value.fill(0x42);
  await writeFile(join(temporary, 'pixel.png'), Buffer.from(png, 'base64'));
  async function run(backend) {
    const path = join(temporary, `store-${backend}${backend === 'sqlite' ? '.sqlite' : ''}`);
    const store = backend === 'sqlite' ? await openNodeSqliteStorage(path) : await openNodeJsonlStorage(path, context);
    const sandbox = new CodemodeSandbox({ memoryLimitBytes: 64 * 1024 * 1024 });
    const registry = createRegistry();
    registry.install({ name: 'd12-codemode', tools: [createCodemodeTool({ sandbox }), createReadTool()] });
    const faux = fauxProvider(), models = createModels();
    models.setProvider(faux.provider);
    const harness = await Harness.open(store, { models, registry, now: () => clock,
      env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? temporary }),
      settings: { retry: { enabled: false } } }, context);
    const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' }, cwd: temporary } });
    faux.setResponses([fauxAssistantMessage([fauxToolCall('codemode', { code }, { id: 'image-code' })],
      { stopReason: 'toolUse' }), fauxAssistantMessage([fauxText('done')])]);
    const receipt = await (await root.submit({ type: 'input', content: 'show image' }, context)).wait(context);
    if (receipt.status !== 'done') throw new Error(`${backend} codemode submission: ${JSON.stringify(receipt)}`);
    await root.waitForIdle(context);
    const tasks = (await store.scanTasks({ order: 'ascending' }, 100, undefined, context)).items;
    const submissions = (await store.scanSubmissions({ order: 'ascending' }, 100, undefined, context)).items;
    const entries = (await store.scanEntries({ conversationId: root.id, order: 'ascending' }, 100, undefined, context)).items;
    const documents = (await store.scanDocuments({ scope: { kind: 'conversation', conversationId: root.id }, at: 'current' }, 100, undefined, context)).items;
    const values = [];
    for (const doc of documents) {
      const value = json(await store.document(doc.id, 'current', context));
      if (doc.kind === 'pi.provider') value.value.sessionId = '<provider-session-id>';
      values.push(value);
    }
    const records = normalize(json({ tasks, submissions, entries, documents, values }));
    if (!records.entries.some(entry => entry.kind === 'pi.tool-result' &&
      JSON.stringify(entry.model).includes(png))) throw new Error(`${backend} did not persist codemode image`);
    await harness.close(context);
    return records;
  }
  const sqlite = await run('sqlite'), jsonl = await run('jsonl');
  if (!isDeepStrictEqual(sqlite, jsonl)) throw new Error(`Tagged image records differ by storage: ${difference(sqlite, jsonl)}`);
  const serialized = JSON.stringify({ tag: v160 ? 'v1.6.0' : 'v1.5.2', code, png, records: sqlite }) + '\n';
  if (check) {
    if (await readFile(output, 'utf8') !== serialized) throw new Error('Tagged codemode image fixture differs');
    const child = spawnSync('swift', ['test', '--skip-build', '--filter', 'D12CodemodeImageTests'], {
      cwd: root, stdio: 'inherit', timeout: 90_000,
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift JSC image test exited ${child.status}`);
  } else await writeFile(output, serialized);
  console.log('D12 persisted codemode read image matches: tagged SQLite and JSONL, Swift JavaScriptCore replay.');
} finally {
  Date.now = oldDateNow;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  Math.random = oldMathRandom;
  crypto.getRandomValues = oldGetRandomValues;
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
