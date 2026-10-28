// Use the unmodified v1.4.0 SQLite adapter. Keep the default-prefix fixtures unchanged.
import { spawnSync } from 'node:child_process';
import { copyFile, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const check = process.argv.includes('--check');
const fixture = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/prefix-upstream-v140.sqlite', import.meta.url));
const records = JSON.parse(await readFile(new URL('../../Tests/PiSwiftDurableTests/Fixtures/records.json', import.meta.url), 'utf8'));
if (records.tag !== upstreamTag) throw new Error(`Prefix input tag differs: ${records.tag} != ${upstreamTag}`);
const { batches, reads } = records;
const temporary = await mkdtemp(join(tmpdir(), 'piswift-prefix-fixtures-'));
const source = await mirror();
try {
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const path = join(temporary, 'prefix.sqlite');
  if (check) await copyFile(fixture, path);
  const storage = await openNodeSqliteStorage(path, { prefix: 'pi_' });
  try {
    if (!check) {
      for (const batch of batches) {
        const seq = await storage.commit(batch.writes, context);
        if (seq !== batch.seq) throw new Error(`Prefix commit sequence differs: ${seq} != ${batch.seq}`);
      }
    }
    compareRecordedReads(await readRecordedCalls(storage, reads, context), reads, 'Prefixed SQLite');
  } finally { await storage.close(context); }
  const reopened = await openNodeSqliteStorage(path, { prefix: 'pi_' });
  try { compareRecordedReads(await readRecordedCalls(reopened, reads, context), reads, 'Prefixed SQLite after reopen'); }
  finally { await reopened.close(context); }
  if (!check) await copyFile(path, fixture);
  console.log(`Prefixed SQLite fixture ${check ? 'matches' : 'written'}: ${batches.length} batches, ${reads.length} reads, prefix pi_, upstream ${upstreamTag}.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
