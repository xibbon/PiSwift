// Run unmodified v1.3.0 document definitions and Session in a temporary mirror.
import { spawnSync, execFileSync } from 'node:child_process';
import { readFile, writeFile, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag, upstreamRepository } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const source = await mirror({ dependencies: ['typebox@1.3.27', 'quickjs-wasi@3.6.2'] });
try {
  // The shared mirror has no codemode package. Add the exact tag source in /tmp.
  const archive = execFileSync('git', ['-C', upstreamRepository, 'archive', upstreamTag, 'packages/codemode/src'], { maxBuffer: 32 * 1024 * 1024 });
  execFileSync('tar', ['-x', '-C', source.directory], { input: archive });
  await writeFile(join(source.directory, 'packages/codemode/package.json'), JSON.stringify({ type: 'module', exports: {
    './portable': './src/portable.ts', './source': './src/source.ts', './declarations': './src/declarations.ts',
  } }));
  await symlink(join(source.directory, 'packages/codemode'), join(source.directory, 'node_modules/@earendil-works/pi-codemode'));
  const { CodemodeRunDoc, CodemodeJournalDoc, CodemodeStoreDoc, CODEMODE_MODULE_VERSION } = await source.import('packages/durable/src/codemode/codemode.ts');
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
  const task = { definition: { name: 'fixture.codemode', version: 1, initial: () => ({}), phases: {}, abort() {} } };
  const taskId = await session.commit(tx => tx.createTask(task, {}, { ownership: { kind: 'conversation' }, conversationId: conversation.id }), context);
  const definitions = [CodemodeRunDoc, CodemodeJournalDoc, CodemodeStoreDoc].map(token => {
    const { kind, version, scope, history, fork, initial } = token.definition;
    return { kind, version, scope, ...(history === undefined ? {} : { history }), ...(fork === undefined ? {} : { fork }), initial: initial() };
  });
  const snapshots = [];
  const snapshot = async name => {
    const values = await session.commit(async tx => ({
      run: JSON.parse(JSON.stringify(await tx.doc(CodemodeRunDoc, taskId))),
      journal: JSON.parse(JSON.stringify(await tx.doc(CodemodeJournalDoc, taskId))),
      store: JSON.parse(JSON.stringify(await tx.doc(CodemodeStoreDoc, conversation.id))),
    }), context);
    snapshots.push({ name, seq: batches.at(-1).seq, ...values });
  };
  await snapshot('initial');
  const start = { version: CODEMODE_MODULE_VERSION, startedAt: 1700000000000, seed: 123456,
    fingerprint: 'fixture-engine-v1', deadline: 1700000030000,
    tools: [{ name: 'read-file', jsName: 'read_file', description: 'Read a file.', structured: true },
      { name: 'pi.codemode.models.classify', jsName: 'pi_codemode_models_classify', description: 'Classify.', structured: true, hidden: true }],
    namespaces: [{ name: 'files', description: 'File tools', instructions: 'Use paths.', tools: ['read-file'] }],
    globals: [{ name: 'fixtureGlobal', spread: false }], maxOutputTokens: 2000, store: { old: null, count: 1 } };
  await session.commit(async tx => {
    (await tx.doc(CodemodeRunDoc, taskId)).start = start;
    (await tx.doc(CodemodeJournalDoc, taskId)).firstIssued = 3;
    (await tx.doc(CodemodeStoreDoc, conversation.id)).values = { old: null, count: 1 };
  }, context);
  const cutoff = await session.commit(tx => tx.appendEntry(conversation.id, { kind: 'fixture.codemode.cutoff' }), context);
  await snapshot('started');
  await session.commit(async tx => {
    const journal = await tx.doc(CodemodeJournalDoc, taskId);
    journal.entries.push({ id: 2, at: 1700000000005, issuedAfter: 3, global: { name: 'fixtureGlobal', args: ['key', null], outcome: { ok: true } } });
    journal.entries.push({ id: 1, at: 1700000000006, issuedAfter: 4 });
    journal.entries.push({ id: 3, at: 1700000000007, global: { name: 'fixtureGlobal', outcome: { ok: false, message: 'Fixture failure', properties: { retry: false } } } });
  }, context);
  await snapshot('journaled');
  await session.commit(async tx => {
    (await tx.doc(CodemodeRunDoc, taskId)).result = { output: [{ type: 'text', text: 'Done' }], details: { calls: [{ id: 1, name: 'read-file', args: '{"path":"file"}', status: 'ok', durationMs: 6 }] } };
    (await tx.doc(CodemodeRunDoc, taskId)).outputDir = '/fixture/codemode-output';
    (await tx.doc(CodemodeStoreDoc, conversation.id)).values = { count: 2, nested: { list: [true, null, 1.25] } };
    (await tx.doc(CodemodeJournalDoc, taskId)).entries[2].issuedAfter = 4;
  }, context);
  await snapshot('decided');
  const forked = await session.commit(tx => tx.forkConversation(conversation.id, cutoff.id, { ownership: { kind: 'ownerless' } }), context);
  const forkStore = await session.commit(async tx => JSON.parse(JSON.stringify(await tx.doc(CodemodeStoreDoc, forked.id))), context);
  await session.close(context);
  const result = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'unmodified packages/durable/src/codemode/codemode.ts, session/session.ts, storage/memory.ts at v1.3.0',
    construction: 'Real upstream document tokens and Session commits. Payloads are constructed host records. No JavaScript sandbox runs.',
  }, moduleVersion: CODEMODE_MODULE_VERSION, conversationId: conversation.id, taskId, forkId: forked.id, cutoffId: cutoff.id, definitions, snapshots, forkStore, batches }, null, 2) + '\n';
  const path = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/codemode-v130.json', import.meta.url));
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== result) throw new Error('Codemode fixtures differ');
  } else await writeFile(path, result);
  console.log(`Codemode fixtures ${process.argv.includes('--check') ? 'match' : 'written'}: ${snapshots.length} snapshots.`);
} finally { await source.close(); }
