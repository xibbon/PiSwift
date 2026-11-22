// Read Swift-written v1.6.0 records with the unmodified tagged adapters.
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV160 } from './mirror-v160.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}

const root = fileURLToPath(new URL('../../', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d1-v160-exports-'));
let source;
try {
  const sqlite = join(temporary, 'swift.sqlite');
  const jsonl = join(temporary, 'swift-jsonl');
  const fixture = JSON.parse(await readFile(join(root,
    'Tests/PiSwiftDurableTests/Fixtures/v160-record-records-v160.json'), 'utf8'));
  source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const exported = spawnSync('swift', ['test', '--skip-build', '--filter',
    'D1V160FixtureTests.swiftV160ExportForUpstreamRead'], {
    cwd: root, stdio: 'inherit', timeout: 120_000,
    env: { ...process.env, PI_DURABLE_V160_SQLITE_EXPORT: sqlite,
      PI_DURABLE_V160_JSONL_EXPORT: jsonl },
  });
  if (exported.error) throw exported.error;
  if (exported.status !== 0) throw new Error(`Swift v1.6.0 export exited ${exported.status}`);
  for (const [backend, open] of [
    ['sqlite', () => openNodeSqliteStorage(sqlite)],
    ['jsonl', () => openNodeJsonlStorage(jsonl, context)],
  ]) {
    const storage = await open();
    try {
      const reads = await readRecordedCalls(storage, fixture.reads, context);
      compareRecordedReads(reads, fixture.reads, `${backend}/v1.6.0 Swift export`);
      console.log(`Tagged v1.6.0 reads Swift ${backend}: ${reads.length} exact reads.`);
    } finally { await storage.close(context); }
  }
} finally {
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
