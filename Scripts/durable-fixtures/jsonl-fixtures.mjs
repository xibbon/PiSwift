// Use unmodified v1.1.0 JSONL source to write and read the recorded scenario.
import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

export async function compareJsonl(source, directory, reads, context) {
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const storage = await openNodeJsonlStorage(directory, context);
  try {
    compareRecordedReads(await readRecordedCalls(storage, reads, context), reads, 'JSONL');
  } finally { await storage.close(context); }
}

export async function replayJsonl(source, directory, batches, reads, context) {
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const storage = await openNodeJsonlStorage(directory, context);
  try {
    for (const batch of batches) {
      const seq = await storage.commit(batch.writes, context);
      if (seq !== batch.seq) throw new Error(`JSONL commit sequence differs: ${seq} != ${batch.seq}`);
    }
    compareRecordedReads(await readRecordedCalls(storage, reads, context), reads, 'JSONL');
  } finally { await storage.close(context); }
  // Compare recovered reads as well as reads from the writer.
  await compareJsonl(source, directory, reads, context);
}

export async function jsonlSize(directory) {
  const names = (await readdir(directory)).sort();
  if (!names.includes('main.jsonl')) throw new Error('JSONL fixture lacks main.jsonl');
  let bytes = 0;
  for (const name of names) {
    if (!/^(?:main|(?:doc|task)-(?:0|[1-9]\d*))\.jsonl$/.test(name)) {
      throw new Error(`JSONL fixture has an unexpected file: ${name}`);
    }
    const info = await stat(join(directory, name));
    if (!info.isFile()) throw new Error(`JSONL fixture path is not a file: ${name}`);
    bytes += info.size;
  }
  if (bytes >= 1_000_000) throw new Error(`JSONL fixture exceeds 1 MB: ${bytes} bytes`);
  return { files: names.length, bytes };
}
