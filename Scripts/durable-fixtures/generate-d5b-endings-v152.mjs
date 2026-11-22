// Tagged v1.5.2 pre-event files and canonical records for each run ending.
// The mirror reads the tag, not the upstream working tree.
import { spawnSync } from 'node:child_process';
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { gzipSync, gunzipSync } from 'node:zlib';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
import { mirrorV160, upstreamTag as upstreamTagV160 } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const v160 = process.argv.includes('--v160');
const output = fileURLToPath(new URL(v160 ? './d5b-endings-v160/' : './d5b-endings-v152/', import.meta.url));
const oldOutput = fileURLToPath(new URL('./d5b-endings-v152/', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d5b-endings-'));
const swiftSeeds = join(temporary, 'swift-seeds');
const source = await (v160 ? mirrorV160 : mirrorV152)({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
const { CompactionTask } = await source.import('packages/durable/src/harness/compaction.ts');
const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
const { InboxDoc } = await source.import('packages/durable/src/harness/inbox.ts');
const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
const { UserEntry, AssistantEntry, ToolResultEntry } = await source.import('packages/durable/src/entries.ts');
const { createModels } = await source.import('packages/ai/src/models.ts');
const { fauxProvider, fauxAssistantMessage, fauxText, fauxToolCall } = await source.import('packages/ai/src/providers/faux.ts');
const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
const clock = 1700000000000;
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const oldDateNow = Date.now;
Date.now = () => clock;

async function storage(kind, path) {
  return kind === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
}
async function copy(kind, from, to) {
  if (kind === 'sqlite') await copyFile(from, to);
  else await cp(from, to, { recursive: true });
}
async function snapshot(store, rootId) {
  const tasks = json((await store.scanTasks({ order: 'ascending' }, 100, undefined, context)).items);
  const submissions = json((await store.scanSubmissions({ order: 'ascending' }, 100, undefined, context)).items);
  const entries = json((await store.scanEntries({ conversationId: rootId, order: 'ascending' }, 100, undefined, context)).items);
  const documents = json((await store.scanDocuments({ scope: { kind: 'conversation', conversationId: rootId }, at: 'current' }, 100, undefined, context)).items);
  const values = [];
  for (const doc of documents) {
    const value = json(await store.document(doc.id, 'current', context));
    // Provider session IDs come from UUID randomness in both runtimes.
    if (doc.kind === 'pi.provider') value.value.sessionId = '<provider-session-id>';
    values.push(value);
  }
  return { tasks, submissions, entries, documents, values };
}
const endings = ['model_error', 'no_model', 'aborted', 'reset', 'faulted', 'orphaned',
  'interrupted', 'restart_limit', 'nothing_to_answer', 'turn_limit', 'answer', 'terminate'];
function options(ending) {
  const models = createModels();
  models.setProvider(fauxProvider().provider);
  return { models: ending === 'faulted' ? () => { throw new Error('Fixture model provider failed'); } : models,
    registry: createRegistry(), now: () => clock, settings: { retry: { enabled: false } } };
}
async function seed(kind, path, ending) {
  const store = await storage(kind, path);
  const harness = await Harness.open(store, options('seed'), context);
  const root = await harness.root(context, { agent: {
    ...(ending === 'no_model' ? {} : { model: { provider: 'faux', modelId: 'faux-1' } }),
    ...(ending === 'turn_limit' ? { maxTurns: 1 } : {}) } });
  const ids = await root.commit(async tx => {
    const user = await tx.appendEntry(UserEntry, root.id, { model: [{ role: 'user', content: 'go', timestamp: clock }] });
    const answer = ['answer', 'terminate', 'reset', 'turn_limit', 'nothing_to_answer'].includes(ending)
      ? await tx.appendEntry(AssistantEntry, root.id, { model: [['terminate', 'reset', 'turn_limit'].includes(ending)
          ? fauxAssistantMessage([fauxToolCall('stop', {}, { id: 'call-stop' })], { stopReason: 'toolUse' })
          : fauxAssistantMessage([fauxText('answered')])] }) : undefined;
    const submission = await tx.createSubmission(ending === 'answer'
      ? { type: 'continue', status: 'done', conversationId: root.id, answer: answer.id }
      : { type: 'continue', status: 'placed', conversationId: root.id });
    const taskId = await tx.createTask(GenerationTask, {}, { ownership: { kind: 'conversation' }, conversationId: root.id });
    const live = await tx.doc(LiveDoc, root.id);
    live.run = { taskId, inputs: ending === 'answer' ? [] : [submission.id], turns: ['terminate', 'reset', 'turn_limit'].includes(ending) ? 1 : 0,
      first: user.id, ...(ending === 'answer' ? { afterRun: {} } : {}) };
    let tool, result, compaction;
    if (['terminate', 'reset', 'turn_limit'].includes(ending)) {
      result = await tx.appendEntry(ToolResultEntry, root.id, { model: [{ role: 'toolResult',
        toolCallId: 'call-stop', toolName: 'stop', content: [{ type: 'text', text: 'done' }], isError: false, timestamp: clock }] });
      tool = await tx.createTask(ToolTask, { kind: 'model', assistant: answer.id, callId: 'call-stop' },
        { ownership: { kind: 'task', taskId }, conversationId: root.id });
      live.tools = [{ callId: 'call-stop', name: 'stop', taskId: tool, status: 'done', entry: result.id }];
    }
    if (ending === 'model_error') {
      compaction = await tx.createTask(CompactionTask, { reason: 'overflow' },
        { ownership: { kind: 'conversation' }, conversationId: root.id });
    }
    if (ending === 'reset') {
      const queued = await tx.createSubmission({ type: 'write', status: 'queued', conversationId: root.id });
      (await tx.doc(InboxDoc, root.id)).items.push({ id: queued.id, mode: 'write', entry: { kind: 'pi.reset', head: 'self' } });
    }
    return { user: user.id, ...(answer ? { answer: answer.id } : {}), submission: submission.id, taskId,
      ...(tool ? { tool, result: result.id } : {}), ...(compaction ? { compaction } : {}) };
  }, context);
  let checkpoint = { phase: 'prepare', attempt: 1 };
  if (ending === 'answer') checkpoint = { phase: 'finish', run: { reason: ending, first: ids.user, answer: ids.answer, last: ids.answer } };
  if (['terminate', 'reset', 'turn_limit'].includes(ending)) checkpoint = { phase: 'tools', assistant: ids.answer,
    tools: ids.tool ? [ids.tool] : [], pending: [] };
  if (ending === 'interrupted') checkpoint = { phase: 'request', attempt: 1, model: { provider: 'faux', modelId: 'faux-1' },
    thinkingLevel: 'off', streamOptions: {}, cutoff: ids.user };
  if (ending === 'model_error') checkpoint = { phase: 'prepare', attempt: 1, compacted: ids.compaction, overflow: 'Fixture context overflow' };
  await root.commit(async tx => {
    const record = await tx.task(ids.taskId);
    const tool = ids.tool ? await tx.task(ids.tool) : undefined;
    const compacted = ids.compaction ? await tx.task(ids.compaction) : undefined;
    tx.setTask({ ...record, ...(ending === 'orphaned' ? { version: 3 } : {}),
      ...(['orphaned', 'aborted'].includes(ending) ? { abortRequested: true } : {}),
      ...(ending === 'restart_limit' ? { restarts: 7 } : {}),
      state: { status: ['interrupted', 'restart_limit'].includes(ending) ? 'running' : 'pending', checkpoint } });
    if (ids.tool) {
      tx.setTask({ ...tool, state: { status: 'terminal', outcome: { status: 'completed',
        result: { kind: 'model', entryId: ids.result, ...(ending === 'terminate' ? { control: { terminate: true } } : {}) } } } });
    }
    if (ids.compaction) {
      tx.setTask({ ...compacted, state: { status: 'terminal', outcome: { status: 'failed', error: { message: 'Fixture compaction failed' } } } });
    }
  }, context);
  // A running record models host loss. A pending record resumes at the saved event.
  const pre = await snapshot(store, root.id);
  await harness.close(context);
  return { ids, rootId: root.id, pre };
}
async function resume(kind, path, ids, rootId, ending) {
  const store = await storage(kind, path);
  const harness = await Harness.open(store, options(ending), context);
  harness.resume();
  let deadline;
  try {
    await Promise.race([harness.waitForTask(ids.taskId, context),
      new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error('Ending did not settle')), 10000); })]);
  } finally { clearTimeout(deadline); }
  const post = await snapshot(store, rootId);
  const live = post.values[post.documents.findIndex(doc => doc.kind === 'pi.live')]?.value;
  if (!['answer', 'terminate'].includes(ending) && live?.runFailure?.reason !== ending)
    throw new Error(`${ending} produced ${JSON.stringify(live)}`);
  if (live?.run !== undefined) throw new Error(`${ending} left an active run`);
  await harness.close(context);
  return post;
}
async function generateV160() {
  const old = JSON.parse(await readFile(join(oldOutput, 'manifest.json'), 'utf8'));
  const manifest = { tag: upstreamTagV160, inputTag: 'v1.5.2', clock,
    normalization: 'pi.provider.sessionId only', cases: {} };
  for (const seedEnding of endings) for (const kind of ['sqlite', 'jsonl']) {
    const name = `${seedEnding}-${kind}`;
    const oldCase = old.cases[`${seedEnding}-sqlite`];
    const input = join(oldOutput, name, kind === 'sqlite' ? 'pre.sqlite.gz' : 'pre');
    const path = join(temporary, `v160-${name}${kind === 'sqlite' ? '.sqlite' : ''}`);
    if (kind === 'sqlite') await writeFile(path, gunzipSync(await readFile(input)));
    else await copy(kind, input, path);
    const store = await storage(kind, path);
    const pre = await snapshot(store, oldCase.rootId);
    await store.close(context);
    if (!isDeepStrictEqual(pre, oldCase.pre)) throw new Error(`${name} frozen input differs`);
    const ending = seedEnding === 'orphaned' ? 'aborted' : seedEnding;
    const post = await resume(kind, path, oldCase.ids, oldCase.rootId, ending);
    manifest.cases[name] = { seedEnding, ending, backend: kind, ids: oldCase.ids,
      rootId: oldCase.rootId, pre, post };
    if (kind === 'jsonl') {
      const sqlite = manifest.cases[`${seedEnding}-sqlite`];
      if (!isDeepStrictEqual(pre, sqlite.pre) || !isDeepStrictEqual(post, sqlite.post))
        throw new Error(`${seedEnding} v1.6.0 records differ between SQLite and JSONL`);
      manifest.cases[name] = { backend: kind, recordsFrom: `${seedEnding}-sqlite` };
    }
  }
  await addV160FutureOrphan(manifest);
  const serialized = JSON.stringify(manifest) + '\n';
  if (check) {
    if (await readFile(join(output, 'manifest.json'), 'utf8') !== serialized) throw new Error('V1.6.0 endings manifest differs');
  } else {
    await mkdir(output, { recursive: true });
    await writeFile(join(output, 'manifest.json'), serialized);
  }
  console.log(`D5b v1.6.0 endings ${check ? 'match' : 'written'}: 12 frozen inputs and one future-version case, SQLite and JSONL.`);
}
async function addV160FutureOrphan(manifest) {
  const old = JSON.parse(await readFile(join(oldOutput, 'manifest.json'), 'utf8'));
  const oldCase = old.cases['orphaned-sqlite'];
  for (const kind of ['sqlite', 'jsonl']) {
    const name = `orphaned-future-${kind}`;
    const frozen = join(oldOutput, `orphaned-${kind}`, kind === 'sqlite' ? 'pre.sqlite.gz' : 'pre');
    const path = join(temporary, `v160-${name}${kind === 'sqlite' ? '.sqlite' : ''}`);
    if (kind === 'sqlite') await writeFile(path, gunzipSync(await readFile(frozen)));
    else await copy(kind, frozen, path);
    const store = await storage(kind, path);
    const { createSession } = await source.import('packages/durable/src/session/session.ts');
    const session = createSession(store, { now: () => clock });
    await session.commitWith(async tx => {
      const record = await tx.task(oldCase.ids.taskId);
      tx.setTask({ ...record, version: 4 });
    }, context);
    const pre = await snapshot(store, oldCase.rootId);
    await session.close(context);
    const dest = join(output, name);
    if (check) {
      const saved = join(dest, kind === 'sqlite' ? 'pre.sqlite.gz' : 'pre');
      const copyPath = join(temporary, `v160-check-${name}${kind === 'sqlite' ? '.sqlite' : ''}`);
      if (kind === 'sqlite') await writeFile(copyPath, gunzipSync(await readFile(saved)));
      else await copy(kind, saved, copyPath);
      const savedStore = await storage(kind, copyPath);
      const savedPre = await snapshot(savedStore, oldCase.rootId);
      await savedStore.close(context);
      if (!isDeepStrictEqual(savedPre, pre)) throw new Error(`${name} future input differs`);
    } else {
      await rm(dest, { recursive: true, force: true });
      await mkdir(dest, { recursive: true });
      if (kind === 'sqlite') await writeFile(join(dest, 'pre.sqlite.gz'), gzipSync(await readFile(path), { level: 9 }));
      else await copy(kind, path, join(dest, 'pre'));
    }
    const post = await resume(kind, path, oldCase.ids, oldCase.rootId, 'orphaned');
    manifest.cases[name] = { ending: 'orphaned', backend: kind, ids: oldCase.ids,
      rootId: oldCase.rootId, pre, post };
    if (kind === 'jsonl') {
      const sqlite = manifest.cases['orphaned-future-sqlite'];
      if (!isDeepStrictEqual(pre, sqlite.pre) || !isDeepStrictEqual(post, sqlite.post))
        throw new Error('Future orphaned records differ between SQLite and JSONL');
      manifest.cases[name] = { backend: kind, recordsFrom: 'orphaned-future-sqlite' };
    }
  }
}
try {
  if (v160) {
    await generateV160();
  } else {
  const reverse = process.argv.indexOf('--resume-swift');
  if (reverse >= 0) {
    const name = process.argv[reverse + 1], path = process.argv[reverse + 2];
    if (!name || !path) throw new Error('--resume-swift needs CASE and PATH');
    const cases = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')).cases;
    let saved = cases[name];
    if (saved?.recordsFrom) saved = { ...cases[saved.recordsFrom], ...saved };
    if (!saved) throw new Error(`Unknown case ${name}`);
    const kind = saved.backend;
    const copied = join(temporary, `swift-${name}${kind === 'sqlite' ? '.sqlite' : ''}`);
    await copy(kind, path, copied);
    const store = await storage(kind, copied);
    const before = await snapshot(store, saved.rootId);
    await store.close(context);
    if (!isDeepStrictEqual(before, saved.pre)) throw new Error(`${name} Swift pre records differ`);
    const after = await resume(kind, copied, saved.ids, saved.rootId, saved.ending);
    if (!isDeepStrictEqual(after, saved.post)) throw new Error(`${name} Swift pre resumes differently under ${upstreamTag}`);
    console.log(`Swift ${name} pre file resumes under ${upstreamTag} to the tagged final records.`);
  } else {
  const manifest = { tag: upstreamTag, clock, normalization: 'pi.provider.sessionId only', cases: {} };
  for (const ending of endings) for (const kind of ['sqlite', 'jsonl']) {
    const name = `${ending}-${kind}`;
    const prePath = join(temporary, `${name}-pre${kind === 'sqlite' ? '.sqlite' : ''}`);
    const postPath = join(temporary, `${name}-post${kind === 'sqlite' ? '.sqlite' : ''}`);
    const { ids, rootId, pre } = await seed(kind, prePath, ending);
    await copy(kind, prePath, postPath);
    const post = await resume(kind, postPath, ids, rootId, ending);
    manifest.cases[name] = { ending, backend: kind, ids, rootId, pre, post };
    if (kind === 'jsonl') {
      const sqlite = manifest.cases[`${ending}-sqlite`];
      if (!isDeepStrictEqual(pre, sqlite.pre) || !isDeepStrictEqual(post, sqlite.post))
        throw new Error(`${ending} records differ between SQLite and JSONL`);
      // Both backends have the same records. Store one canonical copy.
      manifest.cases[name] = { backend: kind, recordsFrom: `${ending}-sqlite` };
    }
    const dest = join(output, name);
    if (check) {
      const savedPre = join(dest, kind === 'sqlite' ? 'pre.sqlite.gz' : 'pre');
      const checkPath = join(temporary, `${name}-check${kind === 'sqlite' ? '.sqlite' : ''}`);
      if (kind === 'sqlite') await writeFile(checkPath, gunzipSync(await readFile(savedPre)));
      else await copy(kind, savedPre, checkPath);
      const checkStore = await storage(kind, checkPath);
      const checkPre = await snapshot(checkStore, rootId);
      await checkStore.close(context);
      if (!isDeepStrictEqual(checkPre, pre)) throw new Error(`${name} pre differs`);
      const swiftSeed = join(swiftSeeds, name);
      await mkdir(swiftSeed, { recursive: true });
      await copy(kind, checkPath, join(swiftSeed, kind === 'sqlite' ? 'pre.sqlite' : 'pre'));
      const checkPost = await resume(kind, checkPath, ids, rootId, ending);
      if (!isDeepStrictEqual(checkPost, post)) throw new Error(`${name} resumed post differs`);
    } else {
      await rm(dest, { recursive: true, force: true });
      await mkdir(dest, { recursive: true });
      if (kind === 'sqlite') await writeFile(join(dest, 'pre.sqlite.gz'), gzipSync(await readFile(prePath), { level: 9 }));
      else await copy(kind, prePath, join(dest, 'pre'));
    }
  }
  const serialized = JSON.stringify(manifest) + '\n';
  if (check) {
    if (await readFile(join(output, 'manifest.json'), 'utf8') !== serialized) throw new Error('Manifest differs');
    const swiftExport = join(temporary, 'swift-export');
    await mkdir(swiftExport);
    const child = spawnSync('swift', ['test', '--skip-build', '--filter',
      'D5bReverseFixtureTests.exportsSwiftWrittenEndingFiles'], {
      cwd: fileURLToPath(new URL('../../', import.meta.url)), stdio: 'inherit', timeout: 180_000,
      env: { ...process.env, PISWIFT_D12_ENDING_SEEDS: swiftSeeds, PISWIFT_D12_ENDING_EXPORT: swiftExport },
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift ending export exited ${child.status}`);
    for (const ending of endings) for (const kind of ['sqlite', 'jsonl']) {
      const name = `${ending}-${kind}`;
      const original = manifest.cases[`${ending}-sqlite`];
      const copied = join(temporary, `swift-check-${name}${kind === 'sqlite' ? '.sqlite' : ''}`);
      await copy(kind, join(swiftExport, name, kind === 'sqlite' ? 'pre.sqlite' : 'pre'), copied);
      const store = await storage(kind, copied);
      const before = await snapshot(store, original.rootId);
      await store.close(context);
      if (!isDeepStrictEqual(before, original.pre)) throw new Error(`${name} Swift-written pre records differ: ${JSON.stringify(before)}`);
      const after = await resume(kind, copied, original.ids, original.rootId, ending);
      if (!isDeepStrictEqual(after, original.post)) throw new Error(`${name} Swift-written file resumes differently under ${upstreamTag}`);
    }
  } else {
    await mkdir(output, { recursive: true });
    await writeFile(join(output, 'manifest.json'), serialized);
  }
  console.log(`D5b tagged endings ${check ? 'match (including Swift-written reverse files)' : 'written'}: 12 endings, SQLite and JSONL.`);
  }
  }
} finally {
  Date.now = oldDateNow;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
