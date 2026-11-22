// Check kept input abort across the v1.6.0 and Swift file adapters.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cp, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
const directory = await mkdtemp(join(tmpdir(), 'piswift-v160-d4-input-'));
let source;
try {
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { InboxDoc } = await source.import('packages/durable/src/harness/inbox.ts');
  const { admitSubmission } = await source.import('packages/durable/src/harness/submissions.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');

  const open = item => item.backend === 'sqlite' ? openNodeSqliteStorage(item.path)
    : openNodeJsonlStorage(item.path, context);
  const mention = { kind: 'chat.mention', data: { author: 'ann', text: 'k' } };
  async function step(item, action) {
    const store = await open(item);
    let harness;
    try {
      harness = await Harness.open(store, { registry: createRegistry(), models: createModels(),
        now: () => 1_000, onWake: () => {} }, context);
      if (action === 'prepare') {
        const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
        assert.equal(root.id, 1);
        const admit = draft => root.commit(tx => admitSubmission(tx, root.id, draft, 1_000,
          { steeringMode: 'one-at-a-time', followUpMode: 'one-at-a-time' }), context);
        await admit({ type: 'input', content: 'a' });
        await admit({ type: 'input', content: 'w' });
        await admit({ type: 'input', content: 'k', entry: mention, whenBusy: 'followUp', onAbort: 'keep' });
        const inbox = await harness.snapshot(InboxDoc, 1, context);
        assert.equal(inbox.items.length, 2, JSON.stringify(inbox.items));
        assert.equal(inbox.items[1].onAbort, 'keep');
      } else {
        const root = await harness.conversation(1, context);
        assert.ok(root);
        await root.abort(context);
        const inbox = await harness.snapshot(InboxDoc, 1, context);
        const live = await harness.snapshot(LiveDoc, 1, context);
        assert.deepEqual(inbox.items, [{ id: inbox.items[0].id, mode: 'followUp',
          content: 'k', entry: mention, onAbort: 'keep' }]);
        assert.equal(live.run, undefined);
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
      const submissions = (await store.scanSubmissions({ conversationId: 1, order: 'ascending' }, 20, undefined, context)).items;
      const entries = (await store.scanEntries({ conversationId: 1, order: 'ascending' }, 20, undefined, context)).items;
      const values = {};
      for (const kind of ['pi.live', 'pi.inbox']) {
        const record = await store.findDocument({ kind, scope: { kind: 'conversation', conversationId: 1 } }, 'current', context);
        values[kind] = (await store.document(record.id, 'current', context)).value;
      }
      return JSON.parse(JSON.stringify({ tasks, submissions, entries, values }));
    } finally { await store.close(context); }
  }
  const plan = [], checks = [];
  for (const backend of ['sqlite', 'jsonl']) {
    const item = suffix => ({ backend, path: join(directory, `${backend}-${suffix}`) });
    const oracle = item('oracle'), swiftPrepare = item('swift-prepare'), swiftAbort = item('swift-abort');
    await step(oracle, 'prepare');
    const prepared = await snapshot(oracle);
    await cp(oracle.path, swiftAbort.path, { recursive: backend === 'jsonl' });
    await step(oracle, 'abort');
    const aborted = await snapshot(oracle);
    plan.push({ ...swiftPrepare, step: 'prepare' }, { ...swiftAbort, step: 'abort' });
    checks.push({ swiftPrepare, swiftAbort, prepared, aborted });
  }
  const planPath = join(directory, 'swift-plan.json');
  await writeFile(planPath, JSON.stringify(plan));
  const swift = spawnSync('swift', ['test', '--skip-build', '--filter',
    'HarnessInputEntryTests.crossLanguageKeptInputFiles'], { cwd: repository,
    env: { ...process.env, PISWIFT_D4_INPUT_PLAN: planPath }, stdio: 'inherit', timeout: 120_000 });
  if (swift.error) throw swift.error;
  if (swift.status !== 0) throw new Error(`Swift D4 kept input exited ${swift.status}`);
  for (const { swiftPrepare, swiftAbort, prepared, aborted } of checks) {
    assert.deepEqual(await snapshot(swiftPrepare), prepared, `${swiftPrepare.backend}: Swift prepared input`);
    await step(swiftPrepare, 'abort');
    assert.deepEqual(await snapshot(swiftPrepare), aborted, `${swiftPrepare.backend}: Swift to TS abort`);
    assert.deepEqual(await snapshot(swiftAbort), aborted, `${swiftPrepare.backend}: TS to Swift abort`);
  }
  console.log(`D4 kept input passed: ${upstreamTag} and Swift, both directions on SQLite and JSONL.`);
} finally {
  await source?.close();
  await rm(directory, { recursive: true, force: true });
}
