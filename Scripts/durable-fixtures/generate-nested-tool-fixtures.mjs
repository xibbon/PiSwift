// Record nested-call wire values with the unmodified v1.4.0 Session and adapters.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdtemp, mkdir, copyFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';
import { readRecordedCalls, compareRecordedReads, jsonResult } from './sqlite-fixtures.mjs';
import { compareJsonl, jsonlSize } from './jsonl-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const check = process.argv.includes('--check');
const fixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));
const source = await mirror({ dependencies: ['typebox@1.3.27'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-nested-tool-fixtures-'));
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { AssistantEntry } = await source.import('packages/durable/src/entries.ts');
  const { ToolTask, NestedCallDoc } = await source.import('packages/durable/src/harness/tool.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const storage = new MemoryStorage();
  const batches = [];
  const checkpoints = [];
  const checkpoint = async (parent, keys) => {
    const reads = [];
    for (const key of keys) {
      const address = { kind: 'pi.tool.nested-call', scope: { kind: 'task', taskId: parent }, key };
      const record = await storage.findDocument(address, 'current', context);
      reads.push({ method: 'document', arguments: [record.id, 'current'], result: jsonResult(await storage.document(record.id, 'current', context)) });
    }
    checkpoints.push({ seq: batches.at(-1).seq, reads });
  };
  const commit = storage.commit.bind(storage);
  storage.commit = async (writes, ctx) => {
    const seq = await commit(writes, ctx);
    batches.push({ seq, writes: JSON.parse(JSON.stringify(writes)) });
    return seq;
  };
  const session = createSession(storage, { now: () => 1700000000000 });
  await session.commitWith(tx => tx.createRootConversation(), context);
  const conversation = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
  const usage = { input: 1, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 10,
    cost: { input: 0.01, output: 0.02, cacheRead: 0.03, cacheWrite: 0.04, total: 0.1 } };
  const parents = await session.commit(async tx => {
    const assistant = await tx.appendEntry(AssistantEntry, conversation.id, { model: [{
      role: 'assistant', content: ['safe', 'unsafe'].map(id => ({ type: 'toolCall', id, name: 'fixture.parent', arguments: {} })),
      api: 'openai-completions', provider: 'fixture', model: 'fixture', usage,
      stopReason: 'toolUse', timestamp: 1700000000000,
    }] });
    const ids = [];
    for (const callId of ['safe', 'unsafe']) ids.push(await tx.createTask(ToolTask,
      { kind: 'model', assistant: assistant.id, callId },
      { ownership: { kind: 'conversation' }, conversationId: conversation.id }));
    return ids;
  }, context);
  const definitions = [
    { parent: parents[0], parentCallId: 'safe', key: '1', name: 'fixture.success', abandon: false },
    { parent: parents[0], parentCallId: 'safe', key: 'waiting', name: 'fixture.waiting', abandon: false },
    { parent: parents[1], parentCallId: 'unsafe', key: '1', name: 'fixture.running', abandon: true },
    { parent: parents[1], parentCallId: 'unsafe', key: 'gated', name: 'fixture.gated', abandon: true, progress: false },
  ];
  const children = await session.commit(async tx => {
    const ids = [];
    for (const item of definitions) {
      const state = await tx.doc(NestedCallDoc, item.parent, item.key, null);
      const call = { type: 'toolCall', id: `${item.parentCallId}/${item.key}`, name: item.name,
        arguments: { text: item.key, object: { b: 2, a: 1 } } };
      const id = await tx.createTask(ToolTask, { kind: 'nested', parent: item.parent,
        parentCallId: item.parentCallId, key: item.key, call,
        ...(item.progress === false ? { progress: false } : {}) },
      { ownership: { kind: 'task', taskId: item.parent }, abandonOnRestart: item.abandon });
      state.taskId = id;
      ids.push(id);
    }
    return ids;
  }, context);
  const deep = await session.commit(async tx => {
    const state = await tx.doc(NestedCallDoc, children[2], 'deep', null);
    const id = await tx.createTask(ToolTask, { kind: 'nested', parent: children[2],
      parentCallId: 'unsafe/1', key: 'deep', call: { type: 'toolCall', id: 'unsafe/1/deep', name: 'fixture.deep', arguments: {} } },
    { ownership: { kind: 'task', taskId: children[2] }, abandonOnRestart: true });
    state.taskId = id;
    return id;
  }, context);
  await session.commitWith(async tx => {
    const intents = [[parents[0], 'safe'], [parents[1], 'unsafe'], [children[2], 'safe'], [deep, 'safe']];
    const tasks = await Promise.all(intents.map(([id]) => tx.task(id)));
    for (const [index, [id, replay]] of intents.entries()) {
      tx.setTask({ ...tasks[index], ...(id === parents[0] ? { memos: { 'pi.tool.madeNestedCalls': true } } : {}),
        state: { status: 'running', checkpoint: { phase: 'execute', arguments: {}, replay } } });
    }
  }, context);
  const success = { taskId: children[0], structuredOutput: { answer: 42, nested: ['value', null] }, isError: false,
    details: { step: 2 }, diagnostics: [{ severity: 'info', code: 'fixture', message: 'Complete' }], usage, durationMs: 12 };
  await session.commitWith(async tx => {
    (await tx.doc(NestedCallDoc, parents[0], '1', null)).result = success;
    const task = await tx.task(children[0]);
    tx.setTask({ ...task, state: { status: 'terminal', outcome: { status: 'completed', result: { kind: 'nested' } } } });
  }, context);
  await session.commitWith(async tx => {
    const tasks = await Promise.all([children[2], children[3], deep].map(id => tx.task(id)));
    for (const task of tasks) tx.setTask({ ...task, abortRequested: true, abortReason: 'restart' });
  }, context);
  const failure = (id, code, message) => ({ taskId: id, isError: true, details: { step: 1 },
    diagnostics: [{ severity: 'error', code, message }] });
  await session.commitWith(async tx => {
    (await tx.doc(NestedCallDoc, children[2], 'deep', null)).result = failure(deep, 'interrupted', 'The deep call was interrupted');
    const task = await tx.task(deep);
    tx.setTask({ ...task, state: { status: 'terminal', outcome: { status: 'aborted', result: { kind: 'nested' } } } });
  }, context);
  const deepResultSeq = batches.at(-1).seq;
  await checkpoint(children[2], ['deep']);
  await session.commitWith(async tx => {
    const tasks = await Promise.all([children[2], children[3]].map(id => tx.task(id)));
    for (const [index, code] of [[2, 'interrupted'], [3, 'abandoned']]) {
      (await tx.doc(NestedCallDoc, parents[1], definitions[index].key, null)).result = failure(children[index], code, `The call was ${code}`);
      const task = tasks[index - 2];
      tx.setTask({ ...task, state: { status: 'terminal', outcome: { status: 'aborted', result: { kind: 'nested' } } } });
    }
  }, context);
  const parentResultSeq = batches.at(-1).seq;
  await checkpoint(parents[1], ['1', 'gated']);
  await session.commitWith(async tx => {
    const task = await tx.task(parents[1]);
    tx.setTask({ ...task, state: { status: 'terminal', outcome: { status: 'failed', error: { message: 'The caller was interrupted' } } } });
  }, context);
  const reads = [];
  const read = async (method, args) => reads.push({ method, arguments: args,
    result: jsonResult(await storage[method](...args.map(value => value === null ? undefined : value), context)) });
  for (const id of [...parents, ...children, deep]) await read('task', [id]);
  await read('scanTasks', [{ conversationId: conversation.id, kind: 'pi.tool', order: 'ascending' }, 20, null]);
  const members = [];
  for (const [parent, key, at] of [[parents[0], '1', 'current'], [parents[0], 'waiting', 'current'],
    [parents[1], '1', parentResultSeq], [parents[1], 'gated', parentResultSeq], [children[2], 'deep', deepResultSeq]]) {
    const address = { kind: 'pi.tool.nested-call', scope: { kind: 'task', taskId: parent }, key };
    const record = await storage.findDocument(address, at, context);
    members.push({ parent, key, id: record.id, at, retired: at !== 'current' });
    await read('findDocument', [address, at]);
    await read('document', [record.id, 'current']);
    if (at !== 'current') {
      await read('findDocument', [address, 'current']);
    }
  }
  for (const parent of [parents[0], parents[1], children[2]]) await read('scanDocuments', [
    { kind: 'pi.tool.nested-call', scope: { kind: 'task', taskId: parent }, at: 'current' }, 20, null]);
  await session.close(context);
  const result = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'unmodified v1.4.0 Session, ToolTask, NestedCallDoc, and storage adapters',
    construction: 'Session transactions construct schema examples; they do not execute ToolTask handlers or prove restart scheduling',
    sourcePaths: ['packages/durable/src/harness/tool.ts:59-108', 'packages/durable/src/harness/tool.ts:589-735', 'packages/durable/src/session/transaction.ts:775-803'],
    retirement: 'Session emits family document retirement when the calling task becomes terminal',
    history: 'Task-scoped documents keep current content only; checkpoints read results before parent retirement',
  }, cases: { parents, children, deep, members, deepResultSeq, parentResultSeq }, batches, checkpoints, reads }, null, 2) + '\n';
  await mkdir(fixtures, { recursive: true });
  const recordPath = join(fixtures, 'nested-tool-records-v140.json');
  if (check) {
    if (await readFile(recordPath, 'utf8') !== result) throw new Error('Nested tool record fixtures differ');
  } else await writeFile(recordPath, result);
  const replay = async storage => {
    try {
      for (const batch of batches) {
        if (await storage.commit(batch.writes, context) !== batch.seq) throw new Error('Commit sequence differs');
        for (const step of checkpoints.filter(step => step.seq === batch.seq))
          compareRecordedReads(await readRecordedCalls(storage, step.reads, context), step.reads);
      }
      compareRecordedReads(await readRecordedCalls(storage, reads, context), reads);
    } finally { await storage.close(context); }
  };
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const sqlite = join(temporary, 'nested.sqlite');
  await replay(await openNodeSqliteStorage(sqlite));
  const sqliteFixture = join(fixtures, 'nested-tool-upstream-v140.sqlite');
  if (check) {
    const checked = join(temporary, 'checked.sqlite');
    await copyFile(sqliteFixture, checked);
    const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
    const stored = await openNodeSqliteStorage(checked);
    try { compareRecordedReads(await readRecordedCalls(stored, reads, context), reads); }
    finally { await stored.close(context); }
  } else await copyFile(sqlite, sqliteFixture);
  const jsonl = join(temporary, 'jsonl');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  await replay(await openNodeJsonlStorage(jsonl, context));
  await compareJsonl(source, jsonl, reads, context);
  const jsonlFixture = join(fixtures, 'nested-tool-upstream-jsonl-v140');
  if (check) {
    const checked = join(temporary, 'checked-jsonl');
    await cp(jsonlFixture, checked, { recursive: true });
    await compareJsonl(source, checked, reads, context);
  } else {
    await rm(jsonlFixture, { recursive: true, force: true });
    await cp(jsonl, jsonlFixture, { recursive: true });
  }
  const size = await jsonlSize(jsonl);
  console.log(`Nested tool fixtures ${check ? 'match' : 'written'}: ${batches.length} batches, ${reads.length} reads, ${size.files} JSONL files, ${size.bytes} JSONL bytes.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
