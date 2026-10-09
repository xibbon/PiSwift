// All record JSON below comes from v1.1.0 Session and MemoryStorage results.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}

const source = await mirror();
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { defineDoc, defineDocFamily } = await source.import('packages/durable/src/documents.ts');
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
  // The concrete upstream transaction exposes bootstrap, replacement and attribution.
  await session.commitWith(tx => tx.createRootConversation(), context);
  const chat = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
  const taskToken = { definition: { name: 'fixture.task', version: 2, initial: input => ({ phase: 'start', input }), phases: {}, abort() {} } };
  const taskIDs = [];
  await session.commit(async tx => {
    for (let i = 0; i < 12; i++) {
      taskIDs.push(await tx.createTask(i === 11 ? { definition: { ...taskToken.definition, version: 2.5 } } : taskToken, { index: i, precise: 1.25, nullable: null }, {
        ownership: { kind: 'conversation' }, conversationId: chat.id, background: i === 1,
      }));
    }
    taskIDs.push(await tx.createTask(taskToken, ['child', true], { ownership: { kind: 'task', taskId: taskIDs[0] } }));
  }, context);
  const owned = await session.commit(tx => tx.createConversation({ ownership: { kind: 'task', taskId: taskIDs[0] } }), context);

  const usage = { input: 3, output: 4, cacheRead: 0, cacheWrite: 0, totalTokens: 7, cost: { input: 0.01, output: 0.02, cacheRead: 0, cacheWrite: 0, total: 0.03 } };
  const messages = [
    { role: 'user', content: 'user text', timestamp: 1700000000000 },
    { role: 'user', content: [{ type: 'text', text: 'user blocks' }, { type: 'image', data: 'AQID', mimeType: 'image/png' }], timestamp: 1700000000001 },
    { role: 'assistant', content: [{ type: 'text', text: 'answer' }, { type: 'thinking', thinking: 'reason', thinkingSignature: 'signature' }, { type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'file', nested: [null, true, 1.25] } }], api: 'openai-responses', provider: 'openai', model: 'fixture-model', usage, stopReason: 'toolUse', timestamp: 1700000000002 },
    { role: 'toolResult', toolCallId: 'call-1', toolName: 'read', content: [{ type: 'text', text: 'file content' }], details: { rows: 1 }, isError: false, timestamp: 1700000000003 },
    { role: 'system', content: 'instructions', sections: { zeta: 'first', alpha: null }, toolsAdded: [{ name: 'read', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } }], toolsRemoved: [{ name: 'old' }], timestamp: 1700000000004 },
    { role: 'system', content: [{ type: 'text', text: 'system block' }], timestamp: 1700000000005 },
  ];
  const entryIDs = [];
  await session.commitWith(async tx => {
    for (const [index, kind] of ['pi.user', 'pi.user', 'pi.assistant', 'fixture.tool-result', 'pi.system', 'pi.system'].entries()) {
      const entry = await tx.appendEntry(chat.id, { kind, model: [messages[index]], data: { index, nested: ['payload', null] }, ...(index === 0 ? { head: 'self' } : {}) });
      entryIDs.push(entry.id);
    }
    const reset = await tx.appendEntry(chat.id, { kind: 'pi.reset', head: entryIDs[1], edits: [{ target: entryIDs[0], action: 'omit' }, { target: entryIDs[1], action: 'replace', messages: [messages[0]] }] });
    entryIDs.push(reset.id);
    entryIDs.push((await tx.appendEntry(chat.id, { kind: 'fixture.opaque', data: null, extension: { retained: true } })).id);
  }, context, { conversationId: chat.id, taskId: taskIDs[0] });

  const sessionDoc = defineDoc({ kind: 'fixture.session', version: 1, scope: 'session', initial: () => ({ count: 0, label: 'base' }) });
  const checkpointDoc = defineDoc({ kind: 'fixture.checkpoint', version: 1, scope: 'session', initial: () => ({ count: 0 }), checkpointWhen: () => true });
  const taskDoc = defineDoc({ kind: 'fixture.task-doc', version: 1, scope: 'task', initial: () => ({ count: 0 }) });
  const conversationDocs = [];
  for (const [history, fork] of [['latest', 'initial'], ['latest', 'current'], ['rewindable', 'initial'], ['rewindable', 'current'], ['rewindable', 'asOf']]) {
    conversationDocs.push(defineDoc({ kind: `fixture.${history}.${fork}`, version: 1, scope: 'conversation', history, fork, initial: () => ({ count: 0, items: ['base'] }) }));
  }
  const families = [
    defineDocFamily({ kind: 'fixture.session-family', version: 1, scope: 'session', family: true, initial: seed => ({ seed, count: 0 }) }),
    defineDocFamily({ kind: 'fixture.conversation-family', version: 1, scope: 'conversation', history: 'rewindable', fork: 'asOf', family: true, initial: seed => ({ seed, count: 0 }) }),
    defineDocFamily({ kind: 'fixture.task-family', version: 1, scope: 'task', family: true, initial: seed => ({ seed, count: 0 }) }),
  ];
  await session.commit(async tx => {
    await tx.doc(sessionDoc);
    await tx.doc(checkpointDoc);
    await tx.doc(taskDoc, taskIDs[11]);
    for (const token of conversationDocs) await tx.doc(token, chat.id);
    await tx.doc(families[0], 'key\u0000session', { seed: 'session' });
    await tx.doc(families[1], chat.id, 'key😀', ['conversation']);
    await tx.doc(families[2], taskIDs[11], 'key-task', true);
  }, context);
  // The cutoff is committed with the initial bases so asOf fork copies are valid.
  const cutoff = await session.commit(tx => tx.appendEntry(chat.id, { kind: 'fixture.cutoff' }), context);
  entryIDs.push(cutoff.id);
  await session.commit(async tx => {
    (await tx.doc(sessionDoc)).count = 1;
    (await tx.doc(checkpointDoc)).count = 1;
    for (const token of conversationDocs) (await tx.doc(token, chat.id)).count = 2;
    (await tx.doc(families[1], chat.id, 'key😀', null)).count = 3;
  }, context);
  const forked = await session.commit(tx => tx.forkConversation(chat.id, cutoff.id, { ownership: { kind: 'ownerless' } }), context);
  const ownedFork = await session.commit(tx => tx.forkConversation(chat.id, cutoff.id, { ownership: { kind: 'task', taskId: taskIDs[0] } }), context);
  // Initial-mode documents are created from the definition on first access in the fork.
  await session.commit(async tx => {
    for (const token of conversationDocs) if (token.definition.fork === 'initial') await tx.doc(token, forked.id);
  }, context);
  await session.commit(async tx => { await tx.retireDoc(sessionDoc); await tx.retireDoc(conversationDocs[0], chat.id); }, context);

  const submissions = [];
  await session.commit(async tx => {
    const cases = [
      { type: 'input', status: 'queued' },
      { type: 'input', status: 'placed', entry: entryIDs[0] },
      { type: 'input', status: 'done', entry: entryIDs[0], answer: entryIDs[2] },
      { type: 'input', status: 'unanswered', reason: 'no answer', detail: { retry: false } },
      { type: 'input', status: 'unanswered', entry: entryIDs[1], reason: 'placed but unanswered' },
      { type: 'write', status: 'queued' },
      { type: 'write', status: 'done', entry: entryIDs[4] },
      { type: 'write', status: 'unanswered', reason: 'write failed', detail: ['detail', null] },
    ];
    for (const [index, fields] of cases.entries()) submissions.push((await tx.createSubmission({ conversationId: chat.id, requestId: `request-${index}`, ...fields, ...(index === 0 ? { extension: { retained: 'submission' } } : {}) })).id);
  }, context);
  const outcomes = [
    { status: 'completed', result: { answer: 42 } },
    { status: 'failed', error: { message: 'expected failure', detail: { code: 7 } }, result: ['partial'] },
    { status: 'aborted', reason: 'requested', result: null },
    { status: 'orphaned', reason: 'definition absent' },
    { status: 'faulted', error: { message: 'contract failure' } },
  ];
  await session.commitWith(async tx => {
    // Read all records before the first table write.
    const tasks = await Promise.all(taskIDs.map(id => tx.task(id)));
    tx.setTask({ ...tasks[1], state: { status: 'running', checkpoint: { phase: 'work' } }, memos: { token: [null, 'memo'] }, extension: { retained: 'task' } });
    tx.setTask({ ...tasks[2], abortRequested: true, state: { status: 'waiting', checkpoint: { phase: 'join' }, on: [taskIDs[1]], policy: 'failFast' } });
    tx.setTask({ ...tasks[3], state: { status: 'waiting', checkpoint: { phase: 'join' }, on: [], policy: 'allSettled' } });
    tx.setTask({ ...tasks[4], state: { status: 'completing', outcome: outcomes[0] } });
    for (let i = 0; i < outcomes.length; i++) tx.setTask({ ...tasks[5 + i], state: { status: 'terminal', outcome: outcomes[i] } });
    tx.setTask({ ...tasks[10], state: { status: 'terminal', outcome: { status: 'aborted' } } });
    tx.setTask({ ...tasks[11], state: { status: 'terminal', outcome: { status: 'failed', error: { message: 'without result' } } } });
  }, context);

  const reads = [];
  const read = async (method, ...args) => {
    const result = await storage[method](...args, context);
    reads.push({ method, arguments: args.map(value => value === undefined ? null : value), result: result === undefined ? null : JSON.parse(JSON.stringify(result)) });
    return result;
  };
  const scan = async (method, query) => {
    let cursor;
    do { cursor = (await read(method, query, 2, cursor)).next; } while (cursor !== undefined);
  };
  const conversations = [1, chat.id, owned.id, forked.id, ownedFork.id];
  for (const id of conversations) await read('conversation', id);
  await read('conversation', 900000);
  for (const order of ['ascending', 'descending']) {
    await scan('scanConversations', { order });
    await scan('scanConversations', { ownerConversationId: chat.id, ownerTaskId: taskIDs[0], order });
    for (const conversationId of [chat.id, forked.id]) await scan('scanEntries', { conversationId, order });
    await scan('scanEntries', { conversationId: chat.id, minEntryId: entryIDs[1], maxEntryId: entryIDs[4], order });
    await scan('scanTasks', { order });
    await scan('scanTasks', { conversationId: chat.id, kind: 'fixture.task', status: 'waiting', abortRequested: true, background: false, order });
    await scan('scanSubmissions', { order });
    await scan('scanSubmissions', { conversationId: chat.id, status: 'unanswered', order });
  }
  for (const id of entryIDs) { await read('entry', id); await read('entry', forked.id, id); }
  await read('entry', 900000);
  await read('findLatestHeadMarker', chat.id, undefined);
  await read('findLatestHeadMarker', forked.id, entryIDs[0]);
  await read('findLatestHeadMarker', owned.id, undefined);
  for (const id of taskIDs) await read('task', id);
  await read('task', 900000);
  for (const [index, id] of submissions.entries()) {
    await read('submission', id);
    await read('submissionByRequest', chat.id, `request-${index}`);
  }
  await read('submission', 900000);
  await read('submissionByRequest', chat.id, 'absent');
  const documentCreates = batches.flatMap(batch => batch.writes.filter(write => write.type === 'document.create' || write.type === 'document.copy').map(write => ({ ...write.record, createdAt: batch.seq })));
  for (const record of documentCreates) {
    const address = { kind: record.kind, scope: record.scope, ...(record.key === undefined ? {} : { key: record.key }) };
    for (const at of ['current', record.createdAt]) {
      await read('findDocument', address, at);
      // Only rewindable conversation content has historical materialization.
      if (at === 'current' || record.history === 'rewindable') await read('document', record.id, at);
    }
  }
  // An as-of point includes a retired record only before its retirement.
  await read('document', 900000, 'current');
  await read('findDocument', { kind: 'absent', scope: { kind: 'session' } }, 'current');
  const scopes = [{ kind: 'session' }, ...conversations.map(conversationId => ({ kind: 'conversation', conversationId })), { kind: 'task', taskId: taskIDs[11] }];
  for (const scope of scopes) {
    await scan('scanDocuments', { scope, at: 'current' });
    await scan('scanDocuments', { scope, at: documentCreates[0].createdAt });
  }
  await scan('scanDocuments', { scope: { kind: 'conversation', conversationId: chat.id }, at: 'current', kind: conversationDocs[4].definition.kind });
  await session.close(context);
  const counts = { batches: batches.length, writes: batches.reduce((count, batch) => count + batch.writes.length, 0), reads: reads.length,
    writeTypes: Object.fromEntries([...new Set(batches.flatMap(batch => batch.writes.map(write => write.type)))].sort().map(type => [type, batches.reduce((count, batch) => count + batch.writes.filter(write => write.type === type).length, 0)])) };
  const fixture = JSON.stringify({ tag: upstreamTag, batches, reads, counts }, null, 2) + '\n';
  const path = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/records.json', import.meta.url));
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== fixture) throw new Error('Record fixtures differ. Run this script without --check.');
    console.log(`Durable record fixtures match: ${counts.batches} batches, ${counts.writes} writes, ${counts.reads} reads.`);
  } else {
    await mkdir(fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url)), { recursive: true });
    await writeFile(path, fixture);
    console.log(`Wrote durable record fixtures: ${counts.batches} batches, ${counts.writes} writes, ${counts.reads} reads.`);
  }
} finally {
  await source.close();
}
