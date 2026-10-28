// Build the tests first. Check Swift-written files with the unmodified v1.4.0 adapters.
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror } from './mirror.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const temporary = await mkdtemp(join(tmpdir(), 'piswift-restart-exports-'));
const source = await mirror();
try {
  const sqlitePath = join(temporary, 'swift.sqlite');
  const jsonlPath = join(temporary, 'swift-jsonl');
  const test = spawnSync('swift', ['test', '--skip-build', '--filter', 'RestartRecordTests'], {
    cwd: fileURLToPath(new URL('../../', import.meta.url)),
    env: { ...process.env, PI_DURABLE_RESTART_SQLITE_EXPORT: sqlitePath, PI_DURABLE_RESTART_JSONL_EXPORT: jsonlPath },
    stdio: 'inherit',
  });
  if (test.status !== 0) throw new Error(`Swift restart record tests exited ${test.status}`);
  const { reads } = JSON.parse(await readFile(new URL('../../Tests/PiSwiftDurableTests/Fixtures/restart-records-v130.json', import.meta.url), 'utf8'));
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const sqlite = await openNodeSqliteStorage(sqlitePath);
  try { compareRecordedReads(await readRecordedCalls(sqlite, reads, context), reads); }
  finally { await sqlite.close(context); }
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const jsonl = await openNodeJsonlStorage(jsonlPath, context);
  try { compareRecordedReads(await readRecordedCalls(jsonl, reads, context), reads, 'JSONL'); }
  finally { await jsonl.close(context); }
  console.log(`Upstream v1.4.0 reads match Swift restart exports: ${reads.length} SQLite reads and ${reads.length} JSONL reads.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
