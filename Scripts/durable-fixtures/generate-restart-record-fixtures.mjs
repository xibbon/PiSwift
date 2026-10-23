// Generate a separate restart-field oracle with unmodified v1.3.0 sources.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdtemp, mkdir, copyFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';
import { replaySqlite, readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';
import { replayJsonl, compareJsonl, jsonlSize } from './jsonl-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const check = process.argv.includes('--check');
const fixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));
const source = await mirror({ dependencies: ['typebox@1.3.27'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-restart-fixtures-'));
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const storage = new MemoryStorage();
  const batches = [];
  const commit = storage.commit.bind(storage);
  storage.commit = async (writes, ctx) => {
    const seq = await commit(writes, ctx);
    batches.push({ seq, writes: JSON.parse(JSON.stringify(writes)) });
    return seq;
  };
  const session = createSession(storage, { now: () => 1700000000000 });
  await session.commitWith(tx => tx.createRootConversation(), context);
  const conversation = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
  const definition = { name: 'fixture.restart', version: 1, initial: input => ({ phase: 'ready', input }), phases: {}, abort() {} };
  const ids = await session.commit(async tx => {
    const ids = [];
    for (const abandonOnRestart of [undefined, false, true, true, true, true]) {
      ids.push(await tx.createTask({ definition }, { index: ids.length }, {
        ownership: { kind: 'conversation' }, conversationId: conversation.id,
        ...(abandonOnRestart === undefined ? {} : { abandonOnRestart }),
      }));
    }
    ids.push(await tx.createTask({ definition }, { child: true }, {
      ownership: { kind: 'task', taskId: ids[2] }, abandonOnRestart: true,
    }));
    return ids;
  }, context);
  await session.commitWith(async tx => {
    const tasks = await Promise.all(ids.map(id => tx.task(id)));
    tx.setTask({ ...tasks[2], abortRequested: true, abortReason: 'restart', extension: { retained: true } });
    tx.setTask({ ...tasks[3], abortRequested: true, abortReason: 'restart', state: { status: 'running', checkpoint: { phase: 'cleanup' } } });
    tx.setTask({ ...tasks[4], abortRequested: true, abortReason: 'restart', state: { status: 'terminal', outcome: { status: 'aborted', reason: 'restart' } } });
    // Raw records are copied without schema checks. Preserve an explicit false.
    tx.setTask({ ...tasks[5], abandonOnRestart: false });
    tx.setTask({ ...tasks[6], abortRequested: true, abortReason: 'restart' });
  }, context);
  await session.commitWith(async tx => {
    const task = await tx.task(ids[3]);
    const { abortReason, ...withoutReason } = task;
    tx.setTask({ ...withoutReason, abortRequested: true });
  }, context);
  const reads = [];
  for (const id of ids) reads.push({ method: 'task', arguments: [id], result: await storage.task(id, context) });
  reads.push({ method: 'scanTasks', arguments: [{ conversationId: conversation.id, order: 'ascending' }, 20, null],
    result: await storage.scanTasks({ conversationId: conversation.id, order: 'ascending' }, 20, undefined, context) });
  await session.close(context);
  const result = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'unmodified v1.3.0 Session and MemoryStorage',
    rawFalse: 'TaskRecord types declare true only; raw Session and storage copies also preserve false',
  }, batches, reads }, null, 2) + '\n';
  const recordPath = join(fixtures, 'restart-records-v130.json');
  await mkdir(fixtures, { recursive: true });
  if (check) {
    if (await readFile(recordPath, 'utf8') !== result) throw new Error('Restart record fixtures differ');
  } else await writeFile(recordPath, result);
  const sqlite = join(temporary, 'restart.sqlite');
  await replaySqlite(source, sqlite, batches, reads, context);
  const sqliteFixture = join(fixtures, 'restart-upstream-v130.sqlite');
  if (check) {
    const checked = join(temporary, 'checked.sqlite');
    await copyFile(sqliteFixture, checked);
    const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
    const stored = await openNodeSqliteStorage(checked);
    try { compareRecordedReads(await readRecordedCalls(stored, reads, context), reads); }
    finally { await stored.close(context); }
  } else await copyFile(sqlite, sqliteFixture);
  const jsonl = join(temporary, 'jsonl');
  await replayJsonl(source, jsonl, batches, reads, context);
  const jsonlFixture = join(fixtures, 'restart-upstream-jsonl-v130');
  if (check) {
    const checked = join(temporary, 'checked-jsonl');
    await cp(jsonlFixture, checked, { recursive: true });
    await compareJsonl(source, checked, reads, context);
  } else {
    await rm(jsonlFixture, { recursive: true, force: true });
    await cp(jsonl, jsonlFixture, { recursive: true });
  }
  const size = await jsonlSize(jsonl);
  console.log(`Restart fixtures ${check ? 'match' : 'written'}: ${batches.length} batches, ${reads.length} reads, ${size.files} JSONL files, ${size.bytes} JSONL bytes.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
