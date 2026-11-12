// Combine the tagged Harness run and migration variants in one tagged storage image.
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
const sourceFixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));
const fixtures = outputIndex < 0
  ? sourceFixtures
  : process.argv[outputIndex + 1];
if (!fixtures) throw new Error('--output-dir needs a path');
const harnessFixture = JSON.parse(await readFile(join(sourceFixtures, 'harness-records-v152.json'), 'utf8'));
const migrationFixture = JSON.parse(await readFile(join(sourceFixtures, 'migration-records-v152.json'), 'utf8'));
if (harnessFixture.tag !== upstreamTag || migrationFixture.tag !== upstreamTag) throw new Error('Source fixture tag differs');
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-v152-combined-'));
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
async function compare(storage, reads, context) {
  for (const [index, call] of reads.entries()) {
    const actual = json(await storage[call.method](...call.arguments.map(value => value === null ? undefined : value), context));
    if (!isDeepStrictEqual(actual, call.result)) throw new Error(`Combined read ${index + 1} differs: ${call.method}`);
  }
}
async function replay(storage, batches, reads, context) {
  for (const batch of batches) {
    const seqs = [];
    const result = await storage.commit([batch.writes], (_index, seq) => seqs.push(seq), context);
    if (result.stored !== 1 || seqs[0] !== batch.seq) throw new Error(`Combined commit ${batch.seq} differs`);
  }
  await compare(storage, reads, context);
}
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const storage = new MemoryStorage();
  const batches = [];
  const originalCommit = storage.commit.bind(storage);
  storage.commit = async (writes, receive, ctx) => {
    const seqs = [];
    const result = await originalCommit(writes, (index, seq) => { seqs[index] = seq; receive(index, seq); }, ctx);
    for (let index = 0; index < result.stored; index++) batches.push({ seq: seqs[index], writes: json(writes[index]) });
    return result;
  };
  for (const batch of harnessFixture.batches) {
    const seqs = [];
    const result = await storage.commit([batch.writes], (_index, seq) => seqs.push(seq), context);
    if (result.stored !== 1 || seqs[0] !== batch.seq) throw new Error('Tagged Harness replay differs');
  }
  const session = createSession(storage, { now: () => 1700000000000 });
  const conversation = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
  const entries = await session.commit(async tx => [
    (await tx.appendEntry(conversation.id, { kind: 'fixture.user', data: { text: 'question' } })).id,
    (await tx.appendEntry(conversation.id, { kind: 'fixture.answer', data: { text: 'answer' } })).id,
  ], context);
  const originalEntries = migrationFixture.batches.flatMap(batch => batch.writes)
    .filter(write => write.type === 'entry').map(write => write.value.id).slice(0, 2);
  const entryIDs = new Map(originalEntries.map((id, index) => [id, entries[index]]));
  const submissions = new Map();
  for (const id of migrationFixture.submissions) {
    const old = migrationFixture.reads.find(call => call.method === 'submission' && call.arguments[0] === id).result;
    const created = await session.commit(tx => tx.createSubmission({ type: 'continue', status: old.status,
      conversationId: conversation.id, requestId: old.requestId,
      ...(old.answer === undefined ? {} : { answer: entryIDs.get(old.answer) }),
      ...(old.reason === undefined ? {} : { reason: old.reason }),
      ...(old.detail === undefined ? {} : { detail: old.detail }),
    }), context);
    submissions.set(id, created.id);
  }
  const oldTasks = migrationFixture.taskIDs.map(id => migrationFixture.reads.find(call =>
    call.method === 'task' && call.arguments[0] === id).result);
  const tasks = new Map();
  for (const old of oldTasks) {
    const definition = { name: old.kind, version: old.version, initial: () => old.state.checkpoint ?? { phase: 'call' }, phases: {}, abort() {} };
    const input = json(old.input);
    if (input?.assistant !== undefined) input.assistant = entryIDs.get(input.assistant);
    const id = await session.commit(tx => tx.createTask({ definition }, input, {
      ownership: { kind: 'conversation' }, conversationId: conversation.id,
    }), context);
    tasks.set(old.id, id);
  }
  const rewrite = (value, key) => {
    if (Array.isArray(value)) return value.map(item => rewrite(item, key));
    if (value === null || typeof value !== 'object') {
      if (['assistant', 'cutoff', 'first', 'answer', 'last', 'entry'].includes(key)) return entryIDs.get(value) ?? value;
      if (['taskId', 'parentTaskId'].includes(key)) return tasks.get(value) ?? value;
      if (key === 'inputs') return submissions.get(value) ?? value;
      if (['tasks', 'tools', 'on'].includes(key)) return tasks.get(value) ?? value;
      return value;
    }
    return Object.fromEntries(Object.entries(value).map(([field, item]) => [field, rewrite(item, field)]));
  };
  await session.commitWith(async tx => {
    const current = await Promise.all([...tasks.values()].map(id => tx.task(id)));
    for (const [index, old] of oldTasks.entries()) tx.setTask({ ...current[index], state: rewrite(old.state) });
  }, context);
  const liveCases = [];
  for (const old of migrationFixture.liveCases) {
    const target = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
    const id = await storage.mintId();
    const value = rewrite(old.stored);
    const seqs = [];
    const result = await storage.commit([[{ type: 'document.create', record: { id, kind: 'pi.live',
      scope: { kind: 'conversation', conversationId: target.id }, history: 'latest', fork: 'initial' },
      content: { kind: 'base', version: old.version, value } }]], (_index, seq) => seqs.push(seq), context);
    if (result.stored !== 1 || seqs.length !== 1) throw new Error('Combined live document write failed');
    liveCases.push({ id, conversationId: target.id, version: old.version, withRunFailure: old.withRunFailure });
  }
  const reads = [];
  for (const call of harnessFixture.reads) reads.push(call);
  reads.push({ method: 'conversation', arguments: [conversation.id], result: json(await storage.conversation(conversation.id, context)) });
  for (const id of submissions.values()) reads.push({ method: 'submission', arguments: [id], result: json(await storage.submission(id, context)) });
  for (const id of tasks.values()) reads.push({ method: 'task', arguments: [id], result: json(await storage.task(id, context)) });
  for (const item of liveCases) reads.push({ method: 'document', arguments: [item.id, 'current'],
    result: json(await storage.document(item.id, 'current', context)) });
  await session.close(context);
  const fixture = { tag: upstreamTag, provenance: 'tagged Harness batches, then tagged Session and Storage in one image',
    harnessConversationId: harnessFixture.conversationId, conversationId: conversation.id,
    submissions: Object.fromEntries(submissions), taskIDs: Object.fromEntries(tasks), liveCases,
    phaseCases: Object.fromEntries(Object.entries(migrationFixture.phaseCases).map(([name, oldId]) => [name, tasks.get(oldId)])),
    batches, reads };
  const recordPath = join(fixtures, 'combined-records-v152.json');
  const text = JSON.stringify(fixture) + '\n';
  if (check) {
    if (await readFile(recordPath, 'utf8') !== text) throw new Error('Combined record fixture differs');
  } else {
    await mkdir(fixtures, { recursive: true });
    await writeFile(recordPath, text);
  }
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const sqlite = join(temporary, 'combined.sqlite');
  const sqliteStorage = await openNodeSqliteStorage(sqlite);
  try { await replay(sqliteStorage, batches, reads, context); }
  finally { await sqliteStorage.close(context); }
  const sqliteFixture = join(fixtures, 'combined-upstream-v152.sqlite');
  if (check) {
    const copy = join(temporary, 'check.sqlite');
    await copyFile(sqliteFixture, copy);
    const stored = await openNodeSqliteStorage(copy);
    try { await compare(stored, reads, context); }
    finally { await stored.close(context); }
  } else await copyFile(sqlite, sqliteFixture);
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const jsonl = join(temporary, 'combined-jsonl');
  const jsonlStorage = await openNodeJsonlStorage(jsonl, context);
  try { await replay(jsonlStorage, batches, reads, context); }
  finally { await jsonlStorage.close(context); }
  const jsonlFixture = join(fixtures, 'combined-upstream-jsonl-v152');
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
  console.log(`Combined fixtures ${check ? 'match' : 'written'}: ${batches.length} batches, ${reads.length} reads.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
