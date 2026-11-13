// A two-step v1.5.2 Harness writer or passive viewer for the D12 SQLite test.
// Stdout is a small line protocol; stdin advances each step. No pipe EOF is used.
import { spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { mirrorV152 } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const [mode, path, prefix = ''] = process.argv.slice(2);
if (!['write', 'view'].includes(mode) || !path) throw new Error('Expected write|view SQLITE_PATH');
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
const iterator = lines[Symbol.asyncIterator]();
const advance = async () => {
  const next = await iterator.next();
  if (next.done) throw new Error('Caller closed the step protocol');
};
const signal = name => process.stdout.write(`${name}\n`);
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
try {
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const models = createModels(), faux = fauxProvider();
  models.setProvider(faux.provider);
  async function open(readOnly) {
    const storage = await openNodeSqliteStorage(path, prefix ? { prefix } : {});
    const harness = await Harness.open(storage, { models, registry: createRegistry(), readOnly,
      now: () => 1700000000000, settings: { retry: { enabled: false } } }, context);
    return { storage, harness };
  }
  if (mode === 'write') {
    const { harness } = await open(false);
    try {
      const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
      for (let index = 1; index <= 2; index++) {
        faux.setResponses([fauxAssistantMessage([fauxText(`answer-${index}`)])]);
        const receipt = await (await root.submit({ type: 'input', content: `question-${index}` }, context)).wait(context);
        if (receipt.status !== 'done') throw new Error(`Tagged write ${index} did not finish`);
        signal(index === 1 ? 'ready' : 'updated');
        await advance();
      }
    } finally { await harness.close(context); }
  } else {
    for (let index = 1; index <= 2; index++) {
      const { storage, harness } = await open(true);
      try {
        const root = await harness.root(context);
        const page = await storage.scanEntries({ conversationId: root.id, order: 'ascending' }, 100, undefined, context);
        if (page.items.length !== index * 2) throw new Error(`Tagged viewer saw ${page.items.length}, expected ${index * 2}`);
        signal(index === 1 ? 'ready' : 'refreshed');
        await advance();
      } finally { await harness.close(context); }
    }
  }
} finally {
  lines.close();
  await source.close();
}
