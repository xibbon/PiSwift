// Store mixed model-call versions with unmodified v1.3.0 Session and storage code.
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
const temporary = await mkdtemp(join(tmpdir(), 'piswift-tool-task-fixtures-'));
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { AssistantEntry } = await source.import('packages/durable/src/entries.ts');
  const { ToolTask, appendToolResult } = await source.import('packages/durable/src/harness/tool.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
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
  const calls = Array.from({ length: 6 }, (_, index) => ({ type: 'toolCall', id: `mixed-${index + 1}`, name: 'fixture.echo', arguments: { index } }));
  const assistant = await session.commit(tx => tx.appendEntry(AssistantEntry, conversation.id, { model: [{
    role: 'assistant', content: calls, api: 'openai-completions', provider: 'fixture', model: 'fixture',
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: 'toolUse', timestamp: 1700000000000,
  }] }), context);
  // v1 had the same call checkpoint and no input discriminator.
  const legacy = { definition: { name: 'pi.tool', version: 1, initial: () => ({ phase: 'call' }), phases: {}, abort() {} } };
  const ids = await session.commit(async tx => {
    const ids = [];
    for (let index = 0; index < calls.length; index++) {
      const input = { assistant: assistant.id, callId: calls[index].id };
      ids.push(await tx.createTask(index % 2 === 0 ? legacy : ToolTask,
        index % 2 === 0 ? input : { kind: 'model', ...input },
        { ownership: { kind: 'conversation' }, conversationId: conversation.id }));
    }
    return ids;
  }, context);
  const entries = [];
  await session.commitWith(async tx => {
    const tasks = await Promise.all(ids.map(id => tx.task(id)));
    const live = await tx.doc(LiveDoc, conversation.id);
    for (const index of [4, 5]) {
      const entry = await appendToolResult(tx, conversation.id, calls[index], {
        output: [{ type: 'text', text: `result ${index}` }], structuredOutput: { index },
        details: { index }, diagnostics: [{ severity: 'info', message: `detail ${index}` }],
      }, { timestamp: 1700000000000, durationMs: index });
      entries.push(entry.id);
    }
    for (const index of [2, 3]) {
      const task = tasks[index];
      tx.setTask({ ...task, memos: { 'fixture.retained': { index } },
        state: { status: 'running', checkpoint: { phase: 'execute', arguments: { index, prepared: true }, replay: index === 2 ? 'safe' : 'unsafe' } } });
    }
    for (const index of [4, 5]) {
      const task = tasks[index];
      const result = { entryId: entries[index - 4], control: { addTools: ['fixture.extra'] } };
      tx.setTask({ ...task, state: { status: 'completing', outcome: { status: 'completed',
        result: index === 4 ? result : { kind: 'model', ...result } } } });
    }
    live.tools = calls.map((call, index) => ({ callId: call.id, name: call.name, taskId: ids[index],
      status: index < 2 ? 'pending' : index < 4 ? 'running' : 'done',
      ...(index >= 2 && index < 4 ? { output: `partial ${index}`, details: { index }, droppedBytes: 7, droppedLines: 1 } : {}),
      ...(index >= 4 ? { entry: entries[index - 4] } : {}),
    }));
  }, context);
  const reads = [];
  for (const id of ids) reads.push({ method: 'task', arguments: [id], result: await storage.task(id, context) });
  for (const id of [assistant.id, ...entries]) reads.push({ method: 'entry', arguments: [id], result: await storage.entry(id, context) });
  reads.push({ method: 'scanTasks', arguments: [{ conversationId: conversation.id, kind: 'pi.tool', order: 'ascending' }, 20, null],
    result: await storage.scanTasks({ conversationId: conversation.id, kind: 'pi.tool', order: 'ascending' }, 20, undefined, context) });
  const live = await storage.findDocument({ kind: 'pi.live', scope: { kind: 'conversation', conversationId: conversation.id } }, 'current', context);
  reads.push({ method: 'document', arguments: [live.id, 'current'], result: await storage.document(live.id, 'current', context) });
  const migrations = [];
  for (const id of ids.slice(0, 4).filter((_, index) => index % 2 === 0)) {
    const task = await storage.task(id, context);
    migrations.push({ taskId: id, fromVersion: 1, ...ToolTask.definition.migrate(task.input, task.state.checkpoint, 1) });
  }
  await session.close(context);
  const result = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'unmodified v1.3.0 Session, ToolTask migration, appendToolResult, and storage adapters',
    legacy: 'v1 model input has no kind; a v1 completing result keeps its legacy shape',
    transcript: 'ToolExecutionResult.output becomes ToolResultMessage.content; structuredOutput is not transcript content',
  }, batches, reads, migrations }, null, 2) + '\n';
  await mkdir(fixtures, { recursive: true });
  const record = join(fixtures, 'tool-task-records-v130.json');
  if (check) {
    if (await readFile(record, 'utf8') !== result) throw new Error('Tool task record fixtures differ');
  } else await writeFile(record, result);
  const sqlite = join(temporary, 'tool-tasks.sqlite');
  await replaySqlite(source, sqlite, batches, reads, context);
  const sqliteFixture = join(fixtures, 'tool-task-upstream-v130.sqlite');
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
  const jsonlFixture = join(fixtures, 'tool-task-upstream-jsonl-v130');
  if (check) {
    const checked = join(temporary, 'checked-jsonl');
    await cp(jsonlFixture, checked, { recursive: true });
    await compareJsonl(source, checked, reads, context);
  } else {
    await rm(jsonlFixture, { recursive: true, force: true });
    await cp(jsonl, jsonlFixture, { recursive: true });
  }
  const size = await jsonlSize(jsonl);
  console.log(`Tool task fixtures ${check ? 'match' : 'written'}: ${batches.length} batches, ${reads.length} reads, ${migrations.length} migrations, ${size.files} JSONL files, ${size.bytes} JSONL bytes.`);
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
