// New document shapes only. Existing task and codemode batches stay in their original fixtures.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';
import { jsonResult } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const source = await mirror({ dependencies: ['typebox@1.3.27'] });
try {
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { createSession } = await source.import('packages/durable/src/session/session.ts');
  const { AgentDoc, resolveAgent, resolveSettings } = await source.import('packages/durable/src/harness/agent.ts');
  const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
  const { InboxDoc } = await source.import('packages/durable/src/harness/inbox.ts');
  const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const storage = new MemoryStorage();
  const batches = [];
  const commit = storage.commit.bind(storage);
  storage.commit = async (writes, ctx) => {
    const seq = await commit(writes, ctx);
    batches.push({ seq, writes: jsonResult(writes) });
    return seq;
  };
  const session = createSession(storage, { now: () => 1700000000000 });
  await session.commitWith(tx => tx.createRootConversation(), context);
  const conversations = [];
  // Exact, remove, and loaded-deferred filters. 'deferred' is registry metadata;
  // modelTools.add is the durable record of a loaded deferred tool.
  const catalog = [
    { name: 'fixture.inline' }, { name: 'fixture.deferred', deferred: true },
    { name: 'fixture.unloaded', deferred: true }, { name: 'fixture.hidden' },
    { name: 'fixture.disabled', deferred: true },
    { name: 'fixture.nested', deferred: true, callers: ['tools'] },
  ];
  const registry = createRegistry();
  registry.install({ name: 'fixture.tools', tools: catalog.map(tool => ({ ...tool,
    description: tool.name, parameters: { type: 'object' }, execute: async () => ({ output: [] }) })) });
  const filters = [];
  const agents = [
    {},
    { tools: ['fixture.inline', 'fixture.deferred'], modelTools: ['fixture.deferred'] },
    { tools: { remove: ['fixture.disabled'] }, modelTools: { remove: ['fixture.hidden'], add: ['fixture.deferred'] } },
    { modelTools: { add: ['fixture.deferred'] } },
    { tools: ['fixture.inline', 'fixture.deferred', 'fixture.nested'], modelTools: ['fixture.disabled', 'fixture.nested', 'fixture.deferred'] },
  ];
  for (const agent of agents) {
    const conversation = await session.commit(tx => tx.createConversation({ ownership: { kind: 'ownerless' } }), context);
    conversations.push(conversation.id);
    const resolved = resolveAgent(agent, registry.snapshot(), resolveSettings(), error => { throw error; });
    filters.push({ conversationId: conversation.id, tools: resolved.tools.map(tool => tool.name),
      callable: resolved.callable.map(tool => tool.name), deferred: resolved.deferred.map(tool => tool.name) });
    await session.commit(async tx => { Object.assign(await tx.doc(AgentDoc, conversation.id), agent); }, context);
  }
  const conversationId = conversations[0];
  const task = { definition: { name: 'fixture.closeout', version: 1, initial: () => ({}), phases: {}, abort() {} } };
  const parent = await session.commit(tx => tx.createTask(task, {}, { ownership: { kind: 'conversation' }, conversationId }), context);
  const child = await session.commit(tx => tx.createTask(task, {}, { ownership: { kind: 'task', taskId: parent } }), context);
  await session.commit(async tx => {
    const input = await tx.createSubmission({ conversationId, requestId: 'custom-input', type: 'input', status: 'queued' });
    const write = await tx.createSubmission({ conversationId, requestId: 'display-write', type: 'write', status: 'queued' });
    const reset = await tx.createSubmission({ conversationId, requestId: 'reset', type: 'write', status: 'queued' });
    (await tx.doc(InboxDoc, conversationId)).items = [
      { id: input.id, mode: 'followUp', content: [{ type: 'text', text: 'User question' }], entry: { kind: 'app.question', data: { source: 'fixture', nullable: null } } },
      { id: reset.id, mode: 'write', entry: { kind: 'app.reset', head: 'self' } },
      { id: write.id, mode: 'write', entry: { kind: 'app.display', data: { text: 'Display only' } } },
    ];
    const entry = await tx.appendEntry(conversationId, { kind: 'app.display', data: { text: 'Already settled' } });
    await tx.createSubmission({ conversationId, requestId: 'settled-display', type: 'write', status: 'done', entry: entry.id });
    await tx.appendEntry(conversationId, { kind: 'app.question', data: { source: 'fixture' }, model: [{ role: 'user', content: 'Placed question', timestamp: 1700000000000 }] });
    Object.assign(await tx.doc(LiveDoc, conversationId), {
      run: { taskId: parent, inputs: [input.id] },
      tools: [{ callId: 'parent', name: 'fixture.parent', taskId: parent, status: 'running' }],
      nestedTools: [{ callId: 'parent/child', parentCallId: 'parent', parentTaskId: parent, taskId: child,
        name: 'fixture.child', arguments: { path: 'a' }, status: 'done', details: null,
        output: 'Nested output', diagnostics: [{ severity: 'info', code: 'fixture', message: 'Complete' }],
        summary: { isError: false, durationMs: 12 } }],
      compactionFailure: { taskId: child, reason: 'manual', error: 'Fixture summary failure' },
    });
  }, context);
  const reads = [];
  const read = async (method, args) => reads.push({ method, arguments: args, result: jsonResult(await storage[method](...args, context)) });
  for (const id of conversations) {
    await read('conversation', [id]);
    const documents = await storage.scanDocuments({ scope: { kind: 'conversation', conversationId: id }, at: 'current' }, 100, undefined, context);
    for (const record of documents.items) {
      await read('findDocument', [{ kind: record.kind, scope: record.scope }, 'current']);
      await read('document', [record.id, 'current']);
    }
  }
  await read('scanEntries', [{ conversationId, order: 'ascending' }, 100, undefined]);
  await read('scanSubmissions', [{ conversationId, order: 'ascending' }, 100, undefined]);
  await session.close(context);
  const encoded = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'Unmodified v1.3.0 Session, AgentDoc, InboxDoc, LiveDoc and MemoryStorage',
    construction: 'Constructed document payloads and settled submission records; no scheduling or model execution',
    deferred: 'Registration metadata is not stored. modelTools.add records loaded deferred names.',
  }, catalog, filters, conversations, batches, reads }, null, 2) + '\n';
  const path = new URL('../../Tests/PiSwiftDurableTests/Fixtures/closeout-documents-v130.json', import.meta.url);
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== encoded) throw new Error('Closeout document fixtures differ');
  } else await writeFile(path, encoded);
  console.log(`Closeout document fixtures ${process.argv.includes('--check') ? 'match' : 'written'}: ${batches.length} batches, ${reads.length} reads.`);
} finally { await source.close(); }
