// Write isolated v1.5.2 pending task files for Swift scheduler preservation checks.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, copyFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const check = process.argv.includes('--check');
const outputIndex = process.argv.indexOf('--output-dir');
const fixtures = outputIndex < 0
  ? fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url))
  : process.argv[outputIndex + 1];
if (!fixtures) throw new Error('--output-dir needs a path');
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-v152-phase-only-'));
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
async function compare(storage, reads, context) {
  for (const [index, call] of reads.entries()) {
    const actual = json(await storage[call.method](...call.arguments.map(value => value === null ? undefined : value), context));
    if (!isDeepStrictEqual(actual, call.result)) throw new Error(`Phase-only read ${index + 1} differs: ${call.method}`);
  }
}
async function replay(storage, batches, reads, context) {
  for (const batch of batches) {
    const seqs = [];
    const result = await storage.commit([batch.writes], (_index, seq) => seqs.push(seq), context);
    if (result.stored !== 1 || seqs[0] !== batch.seq) throw new Error(`Phase-only commit ${batch.seq} differs`);
  }
  await compare(storage, reads, context);
}
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const storage = new MemoryStorage();
  const originalCommit = storage.commit.bind(storage);
  const batches = [];
  storage.commit = async (writes, receive, ctx) => {
    const seqs = [];
    const result = await originalCommit(writes, (index, seq) => { seqs[index] = seq; receive(index, seq); }, ctx);
    for (let index = 0; index < result.stored; index++) batches.push({ seq: seqs[index], writes: json(writes[index]) });
    return result;
  };
  const session = createSession(storage, { now: () => 1700000000000 });
  const root = await session.commitWith(tx => tx.createRootConversation(), context);
  const descriptions = [
    { name: 'finish', kind: 'pi.generation', version: 2, input: {}, checkpoint: { phase: 'finish',
      run: { reason: 'answer', first: 101, answer: 102, last: 102 } } },
    { name: 'drain', kind: 'pi.generation', version: 2, input: {}, checkpoint: { phase: 'drain', answer: 102, tasks: [103] } },
    { name: 'retryPoll', kind: 'pi.generation', version: 2, input: {}, checkpoint: { phase: 'retry', attempt: 2, until: 1700000060000,
      poll: { model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', cutoff: 101,
        handle: { provider: 'faux', modelId: 'faux-1', api: 'fixture-faux', id: 'deferred:phase-only', pollAfterMs: 60000 } } } },
    { name: 'toolsPending', kind: 'pi.generation', version: 2, input: {}, checkpoint: { phase: 'tools',
      assistant: 102, tools: [], pending: ['later-call'] } },
    { name: 'unofferedTool', kind: 'pi.tool', version: 3,
      input: { kind: 'model', assistant: 102, callId: 'not-offered', unoffered: true }, checkpoint: { phase: 'call' } },
    { name: 'newerGenerationVersion', kind: 'pi.generation', version: 99, input: {}, checkpoint: { phase: 'prepare', attempt: 1 } },
  ];
  const cases = {};
  for (const item of descriptions) {
    const definition = { name: item.kind, version: item.version, initial: () => item.checkpoint, phases: {}, abort() {} };
    const id = await session.commit(tx => tx.createTask({ definition }, item.input, {
      ownership: { kind: 'conversation' }, conversationId: root.id,
    }), context);
    cases[item.name] = id;
  }
  const reads = [{ method: 'conversation', arguments: [root.id], result: json(await storage.conversation(root.id, context)) }];
  for (const id of Object.values(cases)) reads.push({ method: 'task', arguments: [id], result: json(await storage.task(id, context)) });
  const page = json(await storage.scanTasks({ order: 'ascending' }, 100, undefined, context));
  reads.push({ method: 'scanTasks', arguments: [{ order: 'ascending' }, 100, null], result: page });
  if (page.items.length !== descriptions.length || page.items.some(item => item.state.status !== 'pending')) {
    throw new Error('Phase-only source contains a non-pending or extra task');
  }
  await session.close(context);
  const fixture = { tag: upstreamTag, provenance: 'tagged v1.5.2 Session, SQLite, and JSONL', rootConversationId: root.id,
    cases, batches, reads };
  const recordPath = join(fixtures, 'phase-only-records-v152.json');
  const text = JSON.stringify(fixture) + '\n';
  if (check) {
    if (await readFile(recordPath, 'utf8') !== text) throw new Error('Phase-only record fixture differs');
  } else {
    await mkdir(fixtures, { recursive: true });
    await writeFile(recordPath, text);
  }
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const sqlite = join(temporary, 'phase.sqlite');
  const sqliteStorage = await openNodeSqliteStorage(sqlite);
  try { await replay(sqliteStorage, batches, reads, context); }
  finally { await sqliteStorage.close(context); }
  const sqliteFixture = join(fixtures, 'phase-only-upstream-v152.sqlite');
  if (check) {
    const copy = join(temporary, 'check.sqlite');
    await copyFile(sqliteFixture, copy);
    const stored = await openNodeSqliteStorage(copy);
    try { await compare(stored, reads, context); }
    finally { await stored.close(context); }
  } else await copyFile(sqlite, sqliteFixture);
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const jsonl = join(temporary, 'phase-jsonl');
  const jsonlStorage = await openNodeJsonlStorage(jsonl, context);
  try { await replay(jsonlStorage, batches, reads, context); }
  finally { await jsonlStorage.close(context); }
  const jsonlFixture = join(fixtures, 'phase-only-upstream-jsonl-v152');
  if (check) {
    const copy = join(temporary, 'check-jsonl');
    await cp(jsonlFixture, copy, { recursive: true });
    const stored = await openNodeJsonlStorage(copy, context);
    try { await compare(stored, reads, context); }
    finally { await stored.close(context); }
  } else {
    await rm(jsonlFixture, { recursive: true, force: true });
    await cp(jsonl, jsonlFixture, { recursive: true });
  }
  console.log(`Phase-only fixtures ${check ? 'match' : 'written'}: root ${root.id}, ${page.items.length} pending tasks.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
