// Build the tests first. Read the Swift-written prefix file with unmodified v1.4.0 code.
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror } from './mirror.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

async function run(command, args, options = {}) {
  const child = spawn(command, args, { ...options, stdio: 'inherit' });
  await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)));
  });
}
if (!process.execArgv.includes('--experimental-strip-types')) {
  await run(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)]);
} else {
  const temporary = await mkdtemp(join(tmpdir(), 'piswift-prefix-exports-'));
  const source = await mirror();
  try {
    const path = join(temporary, 'swift.sqlite');
    await run('swift', ['test', '--skip-build', '--filter', 'sqlitePrefixExportForUpstreamRead'], {
      cwd: fileURLToPath(new URL('../../', import.meta.url)),
      env: { ...process.env, PI_DURABLE_PREFIX_SQLITE_EXPORT: path },
    });
    const { reads } = JSON.parse(await readFile(new URL('../../Tests/PiSwiftDurableTests/Fixtures/records.json', import.meta.url), 'utf8'));
    const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
    const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
    for (let index = 0; index < 2; index++) {
      const storage = await openNodeSqliteStorage(path, { prefix: 'pi_' });
      try { compareRecordedReads(await readRecordedCalls(storage, reads, context), reads, 'Swift prefixed SQLite'); }
      finally { await storage.close(context); }
    }
    console.log(`Upstream v1.4.0 reads match Swift prefixed SQLite export: ${reads.length} reads before and after reopen.`);
  } finally {
    await source.close();
    await rm(temporary, { recursive: true, force: true });
  }
}
