// Read Swift-written v1.5.2 records with the unmodified tagged adapters.
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV152 } from './mirror-v152.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}

const root = fileURLToPath(new URL('../../', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d12-v152-exports-'));
let source;
try {
  const sqlite = join(temporary, 'swift.sqlite');
  const jsonl = join(temporary, 'swift-jsonl');
  const taggedPrefix = join(temporary, 'tagged-prefix.sqlite');
  const swiftPrefix = join(temporary, 'swift-prefix.sqlite');
  const fixture = JSON.parse(await readFile(join(root,
    'Tests/PiSwiftDurableTests/Fixtures/migration-records-v152.json'), 'utf8'));
  source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const tagWriter = await openNodeSqliteStorage(taggedPrefix, { prefix: 'pi_' });
  try {
    for (const batch of fixture.batches) {
      const result = await tagWriter.commit([batch.writes], () => {}, context);
      if (result.stored !== 1 || result.refused) throw new Error('Tagged prefixed write refused');
    }
  } finally { await tagWriter.close(context); }
  const exported = spawnSync('swift', ['test', '--skip-build', '--filter',
    'D1V152FixtureTests.swiftV152ExportForUpstreamRead|D12PrefixRecordTests'], {
    cwd: root, stdio: 'inherit', timeout: 120_000,
    env: { ...process.env, PI_DURABLE_V152_SQLITE_EXPORT: sqlite,
      PI_DURABLE_V152_JSONL_EXPORT: jsonl, PI_D12_TAGGED_PREFIX: taggedPrefix,
      PI_D12_SWIFT_PREFIX: swiftPrefix },
  });
  if (exported.error) throw exported.error;
  if (exported.status !== 0) throw new Error(`Swift v1.5.2 export exited ${exported.status}`);
  for (const [backend, path, open] of [
    ['sqlite', sqlite, () => openNodeSqliteStorage(sqlite)],
    ['jsonl', jsonl, () => openNodeJsonlStorage(jsonl, context)],
    ['prefix', swiftPrefix, () => openNodeSqliteStorage(swiftPrefix, { prefix: 'pi_' })],
  ]) {
    const storage = await open();
    try {
      const reads = await readRecordedCalls(storage, fixture.reads, context);
      compareRecordedReads(reads, fixture.reads, `${backend}/v1.5.2 Swift export`);
      console.log(`Tagged v1.5.2 reads Swift ${backend}: ${reads.length} exact reads.`);
    } finally { await storage.close(context); }
  }
} finally {
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
