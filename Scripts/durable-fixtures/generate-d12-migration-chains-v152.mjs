// Start from copies of frozen v1.3.0 and v1.4.0 files. Each language writes
// one v1.5.2 Harness turn, then the other language opens and writes the next.
import { spawnSync } from 'node:child_process';
import { cp, copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
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
if (!process.argv.includes('--check')) throw new Error('The migration chain only writes temporary copies; use --check');
const v160 = process.argv.includes('--v160');
const root = fileURLToPath(new URL('../../', import.meta.url));
const frozen = join(root, 'Tests/PiSwiftDurableTests/Fixtures');
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d12-migration-'));
let source;
const oldDateNow = Date.now, oldMathRandom = Math.random, oldGetRandomValues = crypto.getRandomValues;
const oldPerformanceNow = Object.getOwnPropertyDescriptor(performance, 'now');
const clock = 1_000;
const json = value => JSON.parse(JSON.stringify(value));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    const result = Object.fromEntries(Object.entries(value).map(([key, member]) => [key, normalize(member)]));
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
try {
  source = await (v160 ? mirrorV160 : mirrorV152)(
    { dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  Date.now = () => clock;
  Object.defineProperty(performance, 'now', { configurable: true, value: () => 0 });
  Math.random = () => 0.5;
  crypto.getRandomValues = value => value.fill(0x42);
  const open = (backend, path) => backend === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
  async function snapshot(item) {
    const store = await open(item.backend, item.path);
    const conversations = (await store.scanConversations({ order: 'ascending' }, 1000, undefined, context)).items;
    const tasks = (await store.scanTasks({ order: 'ascending' }, 1000, undefined, context)).items;
    const submissions = (await store.scanSubmissions({ order: 'ascending' }, 1000, undefined, context)).items;
    const entries = [], documents = [], values = [];
    for (const conversation of conversations) {
      entries.push(...(await store.scanEntries({ conversationId: conversation.id, order: 'ascending' }, 1000, undefined, context)).items);
      const docs = (await store.scanDocuments({ scope: { kind: 'conversation', conversationId: conversation.id }, at: 'current' }, 1000, undefined, context)).items;
      documents.push(...docs);
      for (const doc of docs) {
        const value = json(await store.document(doc.id, 'current', context));
        if (doc.kind === 'pi.provider') value.value.sessionId = '<provider-session-id>';
        values.push(value);
      }
    }
    await store.close(context);
    return normalize(json({ conversations, tasks, submissions, entries, documents, values }));
  }
  async function taggedStep(item) {
    const store = await open(item.backend, item.path);
    const faux = fauxProvider();
    const models = createModels();
    models.setProvider(faux.provider);
    faux.setResponses(Array.from({ length: 20 }, () => fauxAssistantMessage([fauxText(`migration-step-${item.step}`)])));
    const harness = await Harness.open(store, { models, registry: createRegistry(), now: () => clock,
      settings: { retry: { enabled: false } } }, context);
    let conversation;
    if (item.step === 1) {
      conversation = await harness.createConversation({ ownership: { kind: 'ownerless' },
        agent: { model: { provider: 'faux', modelId: 'faux-1' } } }, context);
    } else {
      const page = await store.scanConversations({ order: 'ascending' }, 1000, undefined, context);
      conversation = await harness.conversation(page.items.at(-1).id, context);
    }
    const receipt = await (await conversation.submit({ type: 'input', content: `migration-input-${item.step}` }, context)).wait(context);
    if (receipt.status !== 'done') throw new Error(`${item.name} tag step ${item.step}: ${JSON.stringify(receipt)}`);
    await conversation.waitForIdle(context);
    await harness.close(context);
  }
  const cases = [];
  for (const [tag, base] of [['v130', 'restart-upstream'], ['v140', 'lifecycle-upstream']]) {
    for (const backend of ['sqlite', 'jsonl']) {
      for (const order of ['swift-first', 'tag-first']) {
        const name = `${tag}-${backend}-${order}`;
        const file = backend === 'sqlite' ? `${base}-${tag}.sqlite` : `${base}-jsonl-${tag}`;
        const path = join(temporary, name + (backend === 'sqlite' ? '.sqlite' : ''));
        if (backend === 'sqlite') await copyFile(join(frozen, file), path);
        else await cp(join(frozen, file), path, { recursive: true });
        cases.push({ name, tag, backend, order, path });
      }
    }
  }
  async function swiftStep(items, step) {
    const plan = join(temporary, `plan-${step}.json`);
    await writeFile(plan, JSON.stringify({ cases: items.map(item => ({ path: item.path, backend: item.backend, step })) }));
    const child = spawnSync('swift', ['test', '--skip-build', '--filter', 'D12MigrationChainTests.continuesOlderTagFiles'], {
      cwd: root, env: { ...process.env, PISWIFT_D12_MIGRATION_PLAN: plan }, stdio: 'inherit', timeout: 120_000,
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift migration step ${step} exited ${child.status}`);
  }
  await swiftStep(cases.filter(item => item.order === 'swift-first'), 1);
  for (const item of cases.filter(item => item.order === 'tag-first')) await taggedStep({ ...item, step: 1 });
  const first = new Map();
  for (const item of cases) first.set(item.name, await snapshot(item));
  for (const item of cases.filter(item => item.order === 'swift-first')) await taggedStep({ ...item, step: 2 });
  await swiftStep(cases.filter(item => item.order === 'tag-first'), 2);
  for (const tag of ['v130', 'v140']) for (const backend of ['sqlite', 'jsonl']) {
    const a = cases.find(item => item.tag === tag && item.backend === backend && item.order === 'swift-first');
    const b = cases.find(item => item.tag === tag && item.backend === backend && item.order === 'tag-first');
    for (const [label, left, right] of [['step one', first.get(a.name), first.get(b.name)],
      ['step two', await snapshot(a), await snapshot(b)]]) {
      const mismatch = difference(left, right);
      if (mismatch) throw new Error(`${tag}-${backend} ${label}: ${mismatch}`);
    }
  }
  console.log(`D12 migration chains pass: v1.3.0 and v1.4.0, both language orders, SQLite and JSONL; two stored turns each; tag ${v160 ? 'v1.6.0' : 'v1.5.2'}.`);
} finally {
  Date.now = oldDateNow;
  if (oldPerformanceNow) Object.defineProperty(performance, 'now', oldPerformanceNow);
  else delete performance.now;
  Math.random = oldMathRandom;
  crypto.getRandomValues = oldGetRandomValues;
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
