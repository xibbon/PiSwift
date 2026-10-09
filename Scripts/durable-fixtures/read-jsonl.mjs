// Read a Swift or upstream directory with the unmodified v1.1.0 Node adapter.
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror } from './mirror.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}

const [directory, option, comparePath] = process.argv.slice(2);
if (!directory || (option !== undefined && (option !== '--compare' || !comparePath)) || process.argv.length > 5) {
  throw new Error('Usage: node read-jsonl.mjs <directory> [--compare records.json]');
}
const fixturePath = comparePath ?? fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/records.json', import.meta.url));
const { reads } = JSON.parse(await readFile(fixturePath, 'utf8'));
const source = await mirror();
try {
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const storage = await openNodeJsonlStorage(directory, context);
  let actual;
  try { actual = await readRecordedCalls(storage, reads, context); }
  finally { await storage.close(context); }
  if (option === '--compare') {
    compareRecordedReads(actual, reads, 'JSONL');
    console.log(`Upstream JSONL reads match: ${actual.length} reads.`);
  } else {
    console.log(JSON.stringify(actual, null, 2));
  }
} finally { await source.close(); }
