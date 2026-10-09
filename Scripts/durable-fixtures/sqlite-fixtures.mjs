// Replay the recorded v1.1.0 scenario through unmodified upstream SQLite code.
import { isDeepStrictEqual } from 'node:util';

export function jsonResult(value) {
  return value === undefined ? null : JSON.parse(JSON.stringify(value));
}

export async function readRecordedCalls(storage, reads, context) {
  const actual = [];
  for (const call of reads) {
    // The recorder uses null for optional arguments that were undefined.
    const args = call.arguments.map(value => value === null ? undefined : value);
    actual.push({ method: call.method, arguments: call.arguments,
      result: jsonResult(await storage[call.method](...args, context)) });
  }
  return actual;
}

export function compareRecordedReads(actual, expected) {
  if (actual.length !== expected.length) throw new Error(`Read count differs: ${actual.length} != ${expected.length}`);
  for (let index = 0; index < expected.length; index++) {
    if (!isDeepStrictEqual(actual[index], expected[index])) {
      throw new Error(`SQLite read ${index + 1} (${expected[index].method}) differs from Memory: ${JSON.stringify(actual[index])}`);
    }
  }
}

export async function replaySqlite(source, path, batches, reads, context) {
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const storage = await openNodeSqliteStorage(path);
  try {
    for (const batch of batches) {
      const seq = await storage.commit(batch.writes, context);
      if (seq !== batch.seq) throw new Error(`SQLite commit sequence differs: ${seq} != ${batch.seq}`);
    }
    compareRecordedReads(await readRecordedCalls(storage, reads, context), reads);
  } finally {
    // The upstream adapter truncates its WAL checkpoint before closing.
    await storage.close(context);
  }
}
