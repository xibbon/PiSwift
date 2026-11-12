// Record the unmodified v1.5.2 batch contract and JSONL recovery bytes.
import { spawnSync } from 'node:child_process';
import { copyFile, cp, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const fixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));
const fixturePath = join(fixtures, 'batch-v152.json');
const temporary = await mkdtemp(join(tmpdir(), 'piswift-batch-v152-'));
const source = await mirrorV152();
const entry = id => ({ type: 'entry', value: { id, conversationId: 1, kind: 'batch.entry', data: { id } } });
const document = { id: 20, kind: 'batch.document', scope: { kind: 'conversation', conversationId: 1 }, history: 'rewindable', fork: 'asOf' };
const seed = [[{ type: 'conversation', value: { id: 1 } }]];
const batches = [
  [entry(10), { type: 'document.create', record: document, content: { kind: 'base', version: 1, value: { count: 1 } } }],
  [{ type: 'document.change', id: 20, content: { kind: 'delta', version: 1, ops: [['s', ['count'], 2]] } }],
  [entry(11), { type: 'submission', value: { id: 30, conversationId: 1, requestId: 'batch-continue', type: 'continue', status: 'placed' } }],
];
const refusalBatches = [[entry(12)], [entry(13), entry(10)], [entry(14)]];
const calls = [
  { method: 'conversation', arguments: [1] },
  ...[10, 11, 12, 13, 14].map(id => ({ method: 'entry', arguments: [id] })),
  { method: 'document', arguments: [20, 'current'] },
  { method: 'submission', arguments: [30] },
  { method: 'submissionByRequest', arguments: [1, 'batch-continue'] },
];
try {
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  async function commit(storage, writes) {
    const receipts = [];
    const result = await storage.commit(writes, (index, seq) => receipts.push({ index, seq }), context);
    return { batches: writes, stored: result.stored, refused: result.refused ? String(result.refused) : null, receipts };
  }
  async function replay(storage) {
    const commits = [];
    for (const writes of [seed, batches, refusalBatches]) commits.push(await commit(storage, writes));
    const reads = await readRecordedCalls(storage, calls, context);
    return { commits, reads };
  }
  const memory = new MemoryStorage();
  const expected = await replay(memory);
  await memory.close(context);
  async function verify(storage, label) {
    try { compareRecordedReads(await readRecordedCalls(storage, calls, context), expected.reads, label); }
    finally { await storage.close(context); }
  }
  for (const [flag, kind] of [['--verify-sqlite', 'sqlite'], ['--verify-jsonl', 'jsonl']]) {
    const index = process.argv.indexOf(flag);
    if (index !== -1) {
      const path = process.argv[index + 1];
      if (!path) throw new Error(`${flag} requires a path`);
      const prefixIndex = process.argv.indexOf('--prefix');
      for (let attempt = 0; attempt < 2; attempt++) await verify(kind === 'sqlite'
        ? await openNodeSqliteStorage(path, { prefix: prefixIndex === -1 ? undefined : process.argv[prefixIndex + 1] })
        : await openNodeJsonlStorage(path, context), `Swift ${kind}`);
      console.log(`Tagged ${upstreamTag} reads match Swift ${kind} export twice.`);
      process.exitCode = 0;
      // The finally block still removes the mirror.
      await source.close(); await rm(temporary, { recursive: true, force: true });
      process.exit(0);
    }
  }
  for (const prefix of [undefined, 'batch_']) {
    const path = join(temporary, prefix ? 'prefixed.sqlite' : 'batch.sqlite');
    const storage = await openNodeSqliteStorage(path, { prefix });
    let actual;
    try { actual = await replay(storage); } finally { await storage.close(context); }
    if (!isDeepStrictEqual(actual, expected)) throw new Error(`SQLite ${prefix ?? 'default'} replay differs`);
    await verify(await openNodeSqliteStorage(path, { prefix }), 'Reopened SQLite');
    const destination = join(fixtures, prefix ? 'batch-v152-prefixed.sqlite' : 'batch-v152-upstream.sqlite');
    if (check) {
      const copy = join(temporary, prefix ? 'checked-prefix.sqlite' : 'checked.sqlite');
      await copyFile(destination, copy);
      await verify(await openNodeSqliteStorage(copy, { prefix }), 'Checked-in SQLite');
    } else await copyFile(path, destination);
  }
  const jsonl = join(temporary, 'jsonl');
  const storage = await openNodeJsonlStorage(jsonl, context);
  let actual;
  try { actual = await replay(storage); } finally { await storage.close(context); }
  if (!isDeepStrictEqual(actual, expected)) throw new Error('JSONL replay differs');
  await verify(await openNodeJsonlStorage(jsonl, context), 'Reopened JSONL');
  const destination = join(fixtures, 'batch-v152-jsonl');
  if (check) {
    const copy = join(temporary, 'checked-jsonl'); await cp(destination, copy, { recursive: true });
    await verify(await openNodeJsonlStorage(copy, context), 'Checked-in JSONL');
  } else { await rm(destination, { recursive: true, force: true }); await cp(jsonl, destination, { recursive: true }); }
  // Cut each marker at its start, midpoint, missing newline, and full boundary.
  // Each input retains the complete sidecars, as a torn main append does.
  const main = await readFile(join(jsonl, 'main.jsonl'));
  const boundaries = [0];
  for (let index = 0; index < main.length; index++) if (main[index] === 10) boundaries.push(index + 1);
  const points = new Set([0, main.length]);
  for (let index = 1; index < boundaries.length; index++) {
    const start = boundaries[index - 1], end = boundaries[index];
    points.add(start); points.add(Math.floor((start + end) / 2)); points.add(end - 1); points.add(end);
  }
  const torn = [];
  for (const length of [...points].sort((a, b) => a - b)) {
    const path = join(temporary, `torn-${length}`); await cp(jsonl, path, { recursive: true });
    await writeFile(join(path, 'main.jsonl'), main.subarray(0, length));
    const inputFiles = {};
    for (const name of (await readdir(path)).sort()) inputFiles[name] = (await readFile(join(path, name))).toString('base64');
    const recovered = await openNodeJsonlStorage(path, context);
    let reads;
    try { reads = await readRecordedCalls(recovered, calls, context); } finally { await recovered.close(context); }
    const files = {};
    for (const name of (await readdir(path)).sort()) files[name] = (await readFile(join(path, name))).toString('base64');
    torn.push({ file: 'main.jsonl', length, mainLength: length, inputMain: main.subarray(0, length).toString('base64'), inputFiles, recoveredFiles: files, reads });
  }
  for (const file of (await readdir(jsonl)).filter(name => name !== 'main.jsonl').sort()) {
    const bytes = await readFile(join(jsonl, file));
    const cuts = new Set([0, bytes.length]);
    let start = 0;
    for (let index = 0; index < bytes.length; index++) if (bytes[index] === 10) {
      cuts.add(Math.floor((start + index + 1) / 2)); cuts.add(index); cuts.add(index + 1); start = index + 1;
    }
    for (const length of [...cuts].sort((a, b) => a - b)) {
      const path = join(temporary, `sidecar-${file}-${length}`); await cp(jsonl, path, { recursive: true });
      await writeFile(join(path, file), bytes.subarray(0, length));
      const inputFiles = {};
      for (const name of (await readdir(path)).sort()) inputFiles[name] = (await readFile(join(path, name))).toString('base64');
      let reads, error = null;
      try {
        const recovered = await openNodeJsonlStorage(path, context);
        try { reads = await readRecordedCalls(recovered, calls, context); } finally { await recovered.close(context); }
      } catch (failure) { error = { name: failure.name, message: failure.message }; }
      const recoveredFiles = {};
      for (const name of (await readdir(path)).sort()) recoveredFiles[name] = (await readFile(join(path, name))).toString('base64');
      torn.push({ file, length, inputFiles, recoveredFiles, reads: reads ?? null, error });
    }
  }
  const output = { tag: upstreamTag, ...expected, torn };
  const text = JSON.stringify(output, null, 2) + '\n';
  if (check) {
    if (await readFile(fixturePath, 'utf8') !== text) throw new Error('batch-v152.json differs from tagged oracle');
  } else await writeFile(fixturePath, text);
  console.log(`Batch fixtures ${check ? 'match' : 'written'}: ${expected.commits.length} calls, ${torn.length} torn marker points, tagged ${upstreamTag}.`);
} finally { await source.close(); await rm(temporary, { recursive: true, force: true }); }
