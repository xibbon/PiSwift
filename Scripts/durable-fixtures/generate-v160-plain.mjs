// Tag oracle for the two-turn plain Harness operation in D5bPlainByteProbeTests.
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV160, upstreamTag } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const output = fileURLToPath(new URL('./d5b-plain-v160.json', import.meta.url));
const source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-v160-plain-'));
const clock = 1_700_000_000_000;
const originalNow = Date.now;
Date.now = () => clock;
try {
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText } = await source.import('packages/ai/src/providers/faux.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const cases = [];
  for (const backend of ['sqlite', 'jsonl']) {
    const path = join(temporary, backend === 'sqlite' ? 'plain.sqlite' : 'plain-jsonl');
    const storage = backend === 'sqlite' ? await openNodeSqliteStorage(path) : await openNodeJsonlStorage(path, context);
    const faux = fauxProvider(), models = createModels();
    models.setProvider(faux.provider);
    const harness = await Harness.open(storage, { models, registry: createRegistry(), now: () => clock,
      settings: { retry: { enabled: false } } }, context);
    const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
    faux.setResponses([
      fauxAssistantMessage([fauxText('first answer')]),
      fauxAssistantMessage([fauxText('second answer')]),
    ]);
    for (const input of ['first question', 'second question']) {
      const settled = await (await root.submit({ type: 'input', content: input }, context)).wait(context);
      if (settled.status !== 'done') throw new Error(`${backend} ${input} did not settle`);
    }
    await root.waitForIdle(context);
    const tasks = (await storage.scanTasks({ order: 'ascending' }, 100, undefined, context)).items;
    cases.push({ backend, tasks: tasks.map(task => ({ id: task.id, kind: task.kind,
      version: task.version, status: task.state.status })) });
    await harness.close(context);
  }
  const text = JSON.stringify({ tag: upstreamTag, operation: 'two plain answer turns', cases }) + '\n';
  if (check) {
    if (await readFile(output, 'utf8') !== text) throw new Error('v1.6 plain oracle differs');
  } else await writeFile(output, text);
  console.log(`v1.6 plain oracle ${check ? 'matches' : 'written'}: ${cases.length} backends.`);
} finally {
  Date.now = originalNow;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
