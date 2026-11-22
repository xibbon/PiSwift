// Write isolated v1.6.0 pending task files for Swift scheduler preservation checks.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, copyFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV160, upstreamTag } from './mirror-v160.mjs';

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
const source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-v160-v160-record-'));
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
async function compare(storage, reads, context) {
  for (const [index, call] of reads.entries()) {
    const actual = json(await storage[call.method](...call.arguments.map(value => value === null ? undefined : value), context));
    if (!isDeepStrictEqual(actual, call.result)) throw new Error(`V1.6 record read ${index + 1} differs: ${call.method}`);
  }
}
async function replay(storage, batches, reads, context) {
  for (const batch of batches) {
    const seqs = [];
    const result = await storage.commit([batch.writes], (_index, seq) => seqs.push(seq), context);
    if (result.stored !== 1 || seqs[0] !== batch.seq) throw new Error(`V1.6 record commit ${batch.seq} differs`);
  }
  await compare(storage, reads, context);
}
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
  const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
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
  const tool = callId => ({ kind: 'model', assistant: 102, callId });
  const key = { signal: 'fixture.answer', key: 'request-1' };
  const descriptions = [
    { name: 'parkedTool', kind: 'pi.tool', version: 4, input: tool('parked'),
      state: { status: 'sleeping', checkpoint: { phase: 'parked', arguments: { text: 'parked' }, replay: 'safe',
        checkpoint: { nested: { step: 2 } } }, signals: [key] } },
    { name: 'executeTool', kind: 'pi.tool', version: 4, input: tool('execute'),
      state: { status: 'pending', checkpoint: { phase: 'execute', arguments: {}, replay: 'unsafe',
        wake: { reason: 'signal', ...key }, checkpoint: { cursor: 3 } } } },
    { name: 'callTool', kind: 'pi.tool', version: 4, input: tool('call'),
      state: { status: 'pending', checkpoint: { phase: 'call' } } },
    { name: 'signalOnlySleep', kind: 'pi.tool', version: 4, input: tool('signal-only'),
      state: { status: 'sleeping', checkpoint: { phase: 'parked', arguments: {}, replay: 'safe' }, signals: [key] } },
    { name: 'timedSignalSleep', kind: 'pi.tool', version: 4, input: tool('timed-signal'),
      state: { status: 'sleeping', checkpoint: { phase: 'parked', arguments: {}, replay: 'safe' }, until: 1700000001000, signals: [key] } },
    { name: 'anyWait', kind: 'pi.generation', version: 3, input: {},
      state: { status: 'waiting', checkpoint: { phase: 'tools', assistant: 102, tools: [], pending: [] }, on: [], policy: 'any' } },
    ...[
      ['time', { reason: 'time' }], ['expired', { reason: 'expired' }],
      ['signal', { reason: 'signal', ...key }], ['tasks', { reason: 'tasks', ended: [] }],
    ].map(([name, wake]) => ({ name: `wake${name[0].toUpperCase()}${name.slice(1)}`,
      kind: 'pi.generation', version: 3, input: {},
      state: { status: 'pending', checkpoint: { phase: 'prepare', attempt: 1 }, wake } })),
    { name: 'afterTools', kind: 'pi.generation', version: 3, input: {},
      state: { status: 'waiting', checkpoint: { phase: 'afterTools', assistant: 102, tools: [], tasks: [] },
        on: [], policy: 'allSettled' } },
    { name: 'yield', kind: 'pi.generation', version: 3, input: {},
      state: { status: 'waiting', checkpoint: { phase: 'yield', answer: 102, tasks: [] },
        on: [], policy: 'allSettled' } },
    { name: 'oldGenerationPhase', kind: 'pi.generation', version: 3, input: {},
      state: { status: 'pending', checkpoint: { phase: 'prepare', attempt: 1 } } },
    { name: 'oldToolVersion', kind: 'pi.tool', version: 3, input: tool('old'),
      state: { status: 'pending', checkpoint: { phase: 'call' } } },
    { name: 'completedTool', kind: 'pi.tool', version: 4, input: tool('completed'),
      state: { status: 'terminal', outcome: { status: 'completed', result: { kind: 'model', entryId: 102 } } } },
  ];
  const cases = {};
  for (const item of descriptions) {
    const definition = { name: item.kind, version: item.version, initial: () => item.state.checkpoint ?? { phase: 'ready' }, phases: {}, abort() {} };
    const id = await session.commit(tx => tx.createTask({ definition }, item.input, {
      ownership: { kind: 'conversation' }, conversationId: root.id,
    }), context);
    cases[item.name] = id;
  }
  await session.commitWith(async tx => {
    const records = await Promise.all(descriptions.map(item => tx.task(cases[item.name])));
    for (const [index, item] of descriptions.entries()) {
      const record = records[index];
      tx.setTask({ ...record, state: item.state,
        ...(item.name === 'parkedTool' ? { startedAt: 1700000000000,
          memos: { 'pi.signal.fixture.answer/request-1': { version: 1, value: { accepted: true }, consumed: true },
            'pi.signal.fixture.answer/expired-1': { expired: true } } } : {}) });
    }
  }, context);
  const notify = await session.commit(tx => tx.createSubmission({ type: 'input', status: 'queued',
    conversationId: root.id, requestId: 'notify', notify: { taskId: cases.parkedTool, key: 'settled' } }), context);
  const inboxId = await storage.mintId();
  await storage.commit([[{ type: 'document.create', record: { id: inboxId, kind: 'pi.inbox',
    scope: { kind: 'conversation', conversationId: root.id }, history: 'latest', fork: 'initial' },
    content: { kind: 'base', version: 1, value: { items: [
      { id: notify.id, mode: 'followUp', content: 'answer later', onAbort: 'keep' },
    ] } } }]], () => {}, context);
  const reads = [{ method: 'conversation', arguments: [root.id], result: json(await storage.conversation(root.id, context)) }];
  for (const id of Object.values(cases)) reads.push({ method: 'task', arguments: [id], result: json(await storage.task(id, context)) });
  reads.push({ method: 'submission', arguments: [notify.id], result: json(await storage.submission(notify.id, context)) });
  reads.push({ method: 'document', arguments: [inboxId, 'current'], result: json(await storage.document(inboxId, 'current', context)) });
  const page = json(await storage.scanTasks({ order: 'ascending' }, 100, undefined, context));
  reads.push({ method: 'scanTasks', arguments: [{ order: 'ascending' }, 100, null], result: page });
  if (page.items.length !== descriptions.length) {
    throw new Error('V1.6 record source has an unexpected task count');
  }
  const migrations = [
    { kind: 'pi.tool', fromVersion: 1, input: { assistant: 102, callId: 'old-1' },
      checkpoint: { phase: 'execute', arguments: {}, replay: 'safe' }, definition: ToolTask.definition },
    { kind: 'pi.tool', fromVersion: 2, input: tool('old-2'),
      checkpoint: { phase: 'call' }, definition: ToolTask.definition },
    { kind: 'pi.tool', fromVersion: 3, input: tool('old-3'),
      checkpoint: { phase: 'execute', arguments: {}, replay: 'unsafe' }, definition: ToolTask.definition },
    { kind: 'pi.generation', fromVersion: 1, input: {},
      checkpoint: { phase: 'prepare', attempt: 1 }, definition: GenerationTask.definition },
    { kind: 'pi.generation', fromVersion: 2, input: {},
      checkpoint: { phase: 'tools', assistant: 102, tools: [], pending: [] }, definition: GenerationTask.definition },
  ].map(({ definition, ...item }) => ({ ...item, toVersion: definition.version,
    result: json(definition.migrate(item.input, item.checkpoint, item.fromVersion)) }));
  await session.close(context);
  const fixture = { tag: upstreamTag, provenance: 'tagged v1.6.0 Session, SQLite, and JSONL', rootConversationId: root.id,
    cases, notifySubmissionId: notify.id, inboxDocumentId: inboxId, migrations, batches, reads };
  const recordPath = join(fixtures, 'v160-record-records-v160.json');
  const text = JSON.stringify(fixture) + '\n';
  if (check) {
    if (await readFile(recordPath, 'utf8') !== text) throw new Error('V1.6 record record fixture differs');
  } else {
    await mkdir(fixtures, { recursive: true });
    await writeFile(recordPath, text);
  }
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const sqlite = join(temporary, 'v160.sqlite');
  const sqliteStorage = await openNodeSqliteStorage(sqlite);
  try { await replay(sqliteStorage, batches, reads, context); }
  finally { await sqliteStorage.close(context); }
  const sqliteFixture = join(fixtures, 'v160-record-upstream-v160.sqlite');
  if (check) {
    const copy = join(temporary, 'check.sqlite');
    await copyFile(sqliteFixture, copy);
    const stored = await openNodeSqliteStorage(copy);
    try { await compare(stored, reads, context); }
    finally { await stored.close(context); }
  } else await copyFile(sqlite, sqliteFixture);
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const jsonl = join(temporary, 'v160-jsonl');
  const jsonlStorage = await openNodeJsonlStorage(jsonl, context);
  try { await replay(jsonlStorage, batches, reads, context); }
  finally { await jsonlStorage.close(context); }
  const jsonlFixture = join(fixtures, 'v160-record-upstream-jsonl-v160');
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
  console.log(`V1.6 record fixtures ${check ? 'match' : 'written'}: root ${root.id}, ${page.items.length} tasks.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
