// Generate v1.5.2 durable records with the tagged TypeScript implementation.
// --check reads the stored fixtures and never rewrites them.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, copyFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
import { isDeepStrictEqual } from 'node:util';
import { jsonResult } from './sqlite-fixtures.mjs';
import { jsonlSize } from './jsonl-fixtures.mjs';

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
const temporary = await mkdtemp(join(tmpdir(), 'piswift-v152-fixtures-'));
async function replay(storage, batches, reads, context) {
  for (const batch of batches) {
    const sequences = [];
    const result = await storage.commit([batch.writes], (_index, seq) => sequences.push(seq), context);
    if (result.stored !== 1 || sequences[0] !== batch.seq) throw new Error(`Replay sequence differs at ${batch.seq}`);
  }
  await compareReads(storage, reads, context);
}
async function compareReads(storage, reads, context) {
  for (const [index, call] of reads.entries()) {
    const args = call.arguments.map(value => value === null ? undefined : value);
    const actual = jsonResult(await storage[call.method](...args, context));
    if (!isDeepStrictEqual(actual, call.result)) throw new Error(`Read ${index + 1} differs: ${call.method}`);
  }
}
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
  const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
  const storage = new MemoryStorage();
  const batches = [];
  const commit = storage.commit.bind(storage);
  storage.commit = async (writes, receive, ctx) => {
    const sequence = [];
    const result = await commit(writes, (index, seq) => { sequence[index] = seq; receive(index, seq); }, ctx);
    for (let index = 0; index < result.stored; index++) batches.push({ seq: sequence[index], writes: jsonResult(writes[index]) });
    return result;
  };
  const session = createSession(storage, { now: () => 1700000000000 });
  await session.commitWith(tx => tx.createRootConversation(), context);
  const conversation = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
  const entries = await session.commit(async tx => [
    (await tx.appendEntry(conversation.id, { kind: 'fixture.user', data: { text: 'question' } })).id,
    (await tx.appendEntry(conversation.id, { kind: 'fixture.answer', data: { text: 'answer' } })).id,
  ], context);
  const statuses = ['placed', 'done', 'unanswered'];
  const submissions = await session.commit(async tx => {
    const result = [];
    for (const status of statuses) result.push((await tx.createSubmission({
      type: 'continue', status, conversationId: conversation.id, requestId: `continue-${status}`,
      ...(status === 'done' ? { answer: entries[1] } : {}),
      ...(status === 'unanswered' ? { reason: 'nothing_to_answer', detail: 'already answered' } : {}),
    })).id);
    return result;
  }, context);
  const definitions = [
    { name: 'pi.generation', version: 1, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'pi.tool', version: 1, initial: () => ({ phase: 'call' }), phases: {}, abort() {} },
    { name: 'pi.tool', version: 2, initial: () => ({ phase: 'call' }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 2, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'pi.tool', version: 3, initial: () => ({ phase: 'call' }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 2, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 2, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'fixture.future', version: 99, initial: () => ({ phase: 'future' }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 2, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 2, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'pi.tool', version: 3, initial: () => ({ phase: 'call' }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 2, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
    { name: 'pi.generation', version: 99, initial: () => ({ phase: 'prepare', attempt: 1 }), phases: {}, abort() {} },
  ];
  const inputs = [
    {},
    { assistant: entries[1], callId: 'call-old' },
    { kind: 'model', assistant: entries[1], callId: 'call-current' },
    {},
    { kind: 'model', assistant: entries[1], callId: 'call-latest' },
    {},
    {},
    { opaque: true },
    {},
    {},
    { kind: 'model', assistant: entries[1], callId: 'not-offered', unoffered: true },
    {},
    {},
  ];
  const taskIDs = [];
  for (const [index, definition] of definitions.entries()) {
    taskIDs.push(await session.commit(tx => tx.createTask({ definition }, inputs[index], {
      ownership: { kind: 'conversation' }, conversationId: conversation.id,
    }), context));
  }
  await session.commitWith(async tx => {
    const records = await Promise.all(taskIDs.map(id => tx.task(id)));
    tx.setTask({ ...records[0], state: { status: 'running', checkpoint: { phase: 'request', attempt: 2,
      model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', streamOptions: {}, cutoff: entries[0] } } });
    tx.setTask({ ...records[1], state: { status: 'waiting', checkpoint: { phase: 'execute', arguments: {}, replay: 'safe' }, on: [taskIDs[0]], policy: 'allSettled' } });
    tx.setTask({ ...records[2], state: { status: 'sleeping', checkpoint: { phase: 'call' }, until: 1700000000100 } });
    tx.setTask({ ...records[3], state: { status: 'completing', outcome: { status: 'completed', result: { answer: entries[1] } } } });
    tx.setTask({ ...records[4], state: { status: 'terminal', outcome: { status: 'failed', error: { message: 'fixture' } } } });
    tx.setTask({ ...records[5], state: { status: 'pending', checkpoint: { phase: 'finish',
      run: { reason: 'answer', first: entries[0], answer: entries[1], last: entries[1] } } } });
    tx.setTask({ ...records[6], state: { status: 'pending', checkpoint: { phase: 'drain', answer: entries[1], tasks: [taskIDs[4]] } } });
    tx.setTask({ ...records[7], state: { status: 'pending', checkpoint: { phase: 'future', retained: { marker: 'opaque' } } } });
    tx.setTask({ ...records[8], state: { status: 'pending',
      checkpoint: { phase: 'retry', attempt: 2, until: 1700000060000,
        poll: { model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', cutoff: entries[0],
          handle: { provider: 'faux', modelId: 'faux-1', api: 'fixture-faux', id: 'deferred:fixture', pollAfterMs: 60000 } } } } });
    tx.setTask({ ...records[9], state: { status: 'pending', checkpoint: { phase: 'tools', assistant: entries[1],
      tools: [taskIDs[4]], pending: ['pending-call'] } } });
    tx.setTask({ ...records[10], state: { status: 'pending', checkpoint: { phase: 'call' } } });
    tx.setTask({ ...records[11], state: { status: 'pending', checkpoint: { phase: 'future', retained: { marker: 'known-kind' } } } });
    tx.setTask({ ...records[12], state: { status: 'pending', checkpoint: { phase: 'prepare', attempt: 1 } } });
  }, context);
  // Store old pi.live revisions as exact raw writes. A separate document for each
  // source version and runFailure presence keeps each migration case addressable.
  const liveCases = [];
  for (const version of [1, 2, 3]) for (const withRunFailure of [false, true]) {
    const liveConversation = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
    const value = {
      run: { taskId: taskIDs[0], inputs: [submissions[0]], ...(version === 3 ? { turns: 4 } : {}) },
      compactions: [{ taskId: taskIDs[1], ...(version === 1 ? { reason: 'manual' } : { trigger: 'manual' }), blocking: false, attempt: 1 }],
      compactionFailure: { taskId: taskIDs[2], ...(version === 1 ? { reason: 'threshold' } : { trigger: 'threshold' }), error: 'fixture' },
      ...(withRunFailure ? { runFailure: { taskId: taskIDs[0], inputs: [submissions[2]], reason: 'nothing_to_answer' } } : {}),
    };
    const id = await storage.mintId();
    await storage.commit([[{ type: 'document.create',
      record: { id, kind: 'pi.live',
        scope: { kind: 'conversation', conversationId: liveConversation.id }, history: 'latest', fork: 'initial' },
      content: { kind: 'base', version, value },
    }]], () => {}, context);
    liveCases.push({ id, conversationId: liveConversation.id, version, withRunFailure, stored: value,
      migrated: version === 3 ? value : jsonResult(LiveDoc.definition.migrate(value)) });
  }
  const migrateTask = (definition, input, checkpoint, fromVersion) =>
    jsonResult(definition.migrate(input, checkpoint, fromVersion));
  const taskMigrations = [
    { kind: 'pi.generation', fromVersion: 1, toVersion: 2, recordId: taskIDs[0],
      result: migrateTask(GenerationTask.definition, inputs[0], { phase: 'request', attempt: 2,
        model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', streamOptions: {}, cutoff: entries[0] }, 1) },
    { kind: 'pi.tool', fromVersion: 1, toVersion: 3, recordId: taskIDs[1],
      result: migrateTask(ToolTask.definition, inputs[1], { phase: 'execute', arguments: {}, replay: 'safe' }, 1) },
    { kind: 'pi.tool', fromVersion: 2, toVersion: 3, recordId: taskIDs[2],
      result: migrateTask(ToolTask.definition, inputs[2], { phase: 'call' }, 2) },
  ];
  const reads = [];
  for (const id of submissions) reads.push({ method: 'submission', arguments: [id], result: jsonResult(await storage.submission(id, context)) });
  for (const id of taskIDs) reads.push({ method: 'task', arguments: [id], result: jsonResult(await storage.task(id, context)) });
  for (const item of liveCases) reads.push({ method: 'document', arguments: [item.id, 'current'],
    result: jsonResult(await storage.document(item.id, 'current', context)) });
  await session.close(context);
  // A separate tagged Harness produces the new runFailure and tool records.
  // Its own replay files keep the source of each record unambiguous.
  const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { defineTool } = await source.import('packages/durable/src/harness/define.ts');
  const { obj, str } = await source.import('packages/schema/src/index.ts');
  const { createModels } = await source.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
  const originalDateNow = Date.now, originalRandom = Math.random, originalGetRandomValues = crypto.getRandomValues;
  Date.now = () => 1700000000000;
  Math.random = () => 0.5;
  crypto.getRandomValues = value => value.fill(0x42);
  const harnessStorage = new MemoryStorage();
  const harnessBatches = [];
  const harnessCommit = harnessStorage.commit.bind(harnessStorage);
  harnessStorage.commit = async (writes, receive, ctx) => {
    const sequence = [];
    const result = await harnessCommit(writes, (index, seq) => { sequence[index] = seq; receive(index, seq); }, ctx);
    for (let index = 0; index < result.stored; index++) harnessBatches.push({ seq: sequence[index], writes: jsonResult(writes[index]) });
    return result;
  };
  const faux = fauxProvider();
  const models = createModels();
  models.setProvider(faux.provider);
  const registry = createRegistry();
  registry.install({ name: 'fixture-tools', tools: [defineTool({
    name: 'echo', description: 'Echo fixture text', parameters: obj({ text: str() }),
    execute: async args => ({ output: [{ type: 'text', text: args.text }] }),
  })] });
  const harness = await Harness.open(harnessStorage, {
    models, registry, now: () => 1700000000000, settings: { retry: { enabled: false } },
  }, context);
  const root = await harness.root(context, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
  faux.setResponses([fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'fixture model error' })]);
  const failed = await root.submit({ type: 'input', content: 'fail' }, context);
  const failedSettlement = jsonResult(await failed.wait(context));
  const failedLive = jsonResult(await harness.snapshot(LiveDoc, root.id, context));
  faux.setResponses([
    fauxAssistantMessage([fauxToolCall('echo', { text: 'tool output' }, { id: 'fixture-call' })], { stopReason: 'toolUse' }),
    fauxAssistantMessage([fauxText('answered')]),
  ]);
  const answered = await root.submit({ type: 'input', content: 'run tool' }, context);
  const answeredSettlement = jsonResult(await answered.wait(context));
  const harnessTasks = jsonResult((await harnessStorage.scanTasks({ order: 'ascending' }, 100, undefined, context)).items);
  const harnessSubmissions = jsonResult((await harnessStorage.scanSubmissions({ order: 'ascending' }, 100, undefined, context)).items);
  const harnessReads = [];
  for (const record of harnessTasks) harnessReads.push({ method: 'task', arguments: [record.id], result: record });
  for (const record of harnessSubmissions) harnessReads.push({ method: 'submission', arguments: [record.id], result: record });
  const livePage = await harnessStorage.scanDocuments({ scope: { kind: 'conversation', conversationId: root.id }, at: 'current' }, 100, undefined, context);
  for (const record of livePage.items) harnessReads.push({ method: 'document', arguments: [record.id, 'current'],
    result: jsonResult(await harnessStorage.document(record.id, 'current', context)) });
  const harnessFixture = { tag: upstreamTag, provenance: 'unmodified v1.5.2 Harness, FauxProvider, Session, and storage',
    conversationId: root.id, failedSettlement, failedLive, answeredSettlement,
    taskStates: harnessTasks.map(record => ({ id: record.id, kind: record.kind, version: record.version, state: record.state })),
    batches: harnessBatches, reads: harnessReads };
  await harness.close(context);
  Date.now = originalDateNow;
  Math.random = originalRandom;
  crypto.getRandomValues = originalGetRandomValues;
  if (failedSettlement.status !== 'unanswered' || failedLive.runFailure?.reason !== 'model_error' ||
      answeredSettlement.status !== 'done' || !harnessTasks.some(record => record.kind === 'pi.tool')) {
    throw new Error('Tagged Harness did not produce the requested run failure and tool task');
  }
  const fixture = { tag: upstreamTag, provenance: {
    source: 'unmodified tagged Session, MemoryStorage, migration functions, SQLite, and JSONL',
    archive: 'packages/chord, durable, ai, telemetry, schema, and codemode at v1.5.2',
  }, conversationId: conversation.id, submissions, taskIDs,
    phaseCases: { finish: taskIDs[5], drain: taskIDs[6], unsupported: taskIDs[7],
      retryPoll: taskIDs[8], toolsPending: taskIDs[9], unofferedTool: taskIDs[10],
      unsupportedGenerationPhase: taskIDs[11], newerGenerationVersion: taskIDs[12], errorOutcome: taskIDs[4] },
    liveCases, taskMigrations, batches, reads };
  const recordPath = join(fixtures, 'migration-records-v152.json');
  const text = JSON.stringify(fixture) + '\n';
  if (check) {
    if (await readFile(recordPath, 'utf8') !== text) throw new Error('v1.5.2 record fixture differs');
  } else {
    await mkdir(fixtures, { recursive: true });
    await writeFile(recordPath, text);
  }
  const harnessRecordPath = join(fixtures, 'harness-records-v152.json');
  const harnessText = JSON.stringify(harnessFixture) + '\n';
  if (check) {
    if (await readFile(harnessRecordPath, 'utf8') !== harnessText) throw new Error('v1.5.2 Harness fixture differs');
  } else await writeFile(harnessRecordPath, harnessText);
  const sqlitePath = join(temporary, 'generated.sqlite');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const sqlite = await openNodeSqliteStorage(sqlitePath);
  try { await replay(sqlite, batches, reads, context); }
  finally { await sqlite.close(context); }
  const sqliteFixture = join(fixtures, 'migration-upstream-v152.sqlite');
  if (check) {
    const copy = join(temporary, 'checked.sqlite');
    await copyFile(sqliteFixture, copy);
    const stored = await openNodeSqliteStorage(copy);
    try { await compareReads(stored, reads, context); }
    finally { await stored.close(context); }
  } else await copyFile(sqlitePath, sqliteFixture);
  const jsonlPath = join(temporary, 'generated-jsonl');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const jsonl = await openNodeJsonlStorage(jsonlPath, context);
  try { await replay(jsonl, batches, reads, context); }
  finally { await jsonl.close(context); }
  const recovered = await openNodeJsonlStorage(jsonlPath, context);
  try { await compareReads(recovered, reads, context); }
  finally { await recovered.close(context); }
  const jsonlFixture = join(fixtures, 'migration-upstream-jsonl-v152');
  if (check) {
    const copy = join(temporary, 'checked-jsonl');
    await cp(jsonlFixture, copy, { recursive: true });
    const stored = await openNodeJsonlStorage(copy, context);
    try { await compareReads(stored, reads, context); }
    finally { await stored.close(context); }
  } else {
    await rm(jsonlFixture, { recursive: true, force: true });
    await cp(jsonlPath, jsonlFixture, { recursive: true });
  }
  const size = await jsonlSize(jsonlPath);
  const harnessSqlitePath = join(temporary, 'harness.sqlite');
  const harnessSqlite = await openNodeSqliteStorage(harnessSqlitePath);
  try { await replay(harnessSqlite, harnessBatches, harnessReads, context); }
  finally { await harnessSqlite.close(context); }
  const harnessSqliteFixture = join(fixtures, 'harness-upstream-v152.sqlite');
  if (check) {
    const copy = join(temporary, 'checked-harness.sqlite');
    await copyFile(harnessSqliteFixture, copy);
    const stored = await openNodeSqliteStorage(copy);
    try { await compareReads(stored, harnessReads, context); }
    finally { await stored.close(context); }
  } else await copyFile(harnessSqlitePath, harnessSqliteFixture);
  const harnessJsonlPath = join(temporary, 'harness-jsonl');
  const harnessJsonl = await openNodeJsonlStorage(harnessJsonlPath, context);
  try { await replay(harnessJsonl, harnessBatches, harnessReads, context); }
  finally { await harnessJsonl.close(context); }
  const harnessJsonlFixture = join(fixtures, 'harness-upstream-jsonl-v152');
  if (check) {
    const copy = join(temporary, 'checked-harness-jsonl');
    await cp(harnessJsonlFixture, copy, { recursive: true });
    const stored = await openNodeJsonlStorage(copy, context);
    try { await compareReads(stored, harnessReads, context); }
    finally { await stored.close(context); }
  } else {
    await rm(harnessJsonlFixture, { recursive: true, force: true });
    await cp(harnessJsonlPath, harnessJsonlFixture, { recursive: true });
  }
  console.log(`v1.5.2 fixtures ${check ? 'match' : 'written'}: ${batches.length} record batches, ${harnessBatches.length} Harness batches, ${reads.length + harnessReads.length} reads.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
