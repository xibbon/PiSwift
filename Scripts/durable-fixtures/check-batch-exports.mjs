// Build Swift tests first. The tagged adapter checks each Swift batch export twice.
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
async function run(command, args, options = {}) {
  const child = spawn(command, args, { ...options, stdio: 'inherit' });
  await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)));
  });
}
const directory = await mkdtemp(join(tmpdir(), 'piswift-batch-exports-'));
try {
  const sqlite = join(directory, 'swift.sqlite');
  const prefixed = join(directory, 'swift-prefixed.sqlite');
  const jsonl = join(directory, 'jsonl');
  await run('swift', ['test', '--skip-build', '--filter', 'batchExportForUpstreamRead'], {
    cwd: fileURLToPath(new URL('../../', import.meta.url)),
    env: { ...process.env, PI_DURABLE_BATCH_SQLITE_EXPORT: sqlite,
      PI_DURABLE_BATCH_PREFIX_SQLITE_EXPORT: prefixed, PI_DURABLE_BATCH_JSONL_EXPORT: jsonl },
  });
  const generator = fileURLToPath(new URL('generate-batch-fixtures.mjs', import.meta.url));
  for (const args of [['--verify-sqlite', sqlite], ['--verify-sqlite', prefixed, '--prefix', 'batch_'], ['--verify-jsonl', jsonl]]) {
    await run(process.execPath, ['--experimental-strip-types', generator, ...args]);
  }
  console.log('Tagged batch export matrix passed: SQLite default and batch_ prefix, JSONL, each before and after reopen.');
} finally { await rm(directory, { recursive: true, force: true }); }
