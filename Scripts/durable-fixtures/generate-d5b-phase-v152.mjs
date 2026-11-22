// Tagged v1.5.2 pre/post files for the generation phases D1 kept blocked.
import { spawnSync } from 'node:child_process';
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';
import { mirrorV160 } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const v160 = process.argv.includes('--v160');
const output = fileURLToPath(new URL('./d5b-phase-v152/', import.meta.url));
const oracleOutput = fileURLToPath(new URL('./d5b-phase-v160/manifest.json', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d5b-phase-'));
const source = await (v160 ? mirrorV160 : mirrorV152)({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
const { UserEntry, AssistantEntry } = await source.import('packages/durable/src/entries.ts');
const { createModels } = await source.import('packages/ai/src/models.ts');
const { fauxAssistantMessage, fauxText } = await source.import('packages/ai/src/providers/faux.ts');
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
async function seed(kind, path, phase) {
  const store = await storage(kind, path);
  const harness = await Harness.open(store, { models: createModels(), registry: createRegistry(), now: () => clock }, context);
  const root = await harness.root(context);
  const ids = await root.commit(async tx => {
    const user = await tx.appendEntry(UserEntry, root.id, { model: [{ role: 'user', content: 'go', timestamp: clock }] });
    const answer = phase === 'retryPoll' ? undefined : await tx.appendEntry(AssistantEntry, root.id,
      { model: [fauxAssistantMessage([fauxText('answered')])] });
    const submission = await tx.createSubmission(phase === 'retryPoll'
      ? { type: 'continue', status: 'placed', conversationId: root.id }
      : { type: 'continue', status: 'done', conversationId: root.id, answer: answer.id });
    const taskId = await tx.createTask(GenerationTask, {}, { ownership: { kind: 'conversation' }, conversationId: root.id });
    const live = await tx.doc(LiveDoc, root.id);
    live.run = phase === 'retryPoll'
      ? { taskId, inputs: [submission.id], turns: 0, first: user.id }
      : { taskId, inputs: [], turns: 0, first: user.id, afterRun: {} };
    return { user: user.id, answer: answer?.id, submission: submission.id, taskId };
  }, context);
  const checkpoint = phase === 'finish'
    ? { phase, run: { reason: 'answer', first: ids.user, answer: ids.answer, last: ids.answer } }
    : phase === 'drain' ? { phase, answer: ids.answer, tasks: [] }
      : { phase: 'retry', attempt: 1, until: clock,
        poll: { model: { provider: 'faux', modelId: 'faux-1' }, thinkingLevel: 'off', cutoff: ids.user,
          handle: { provider: 'faux', modelId: 'faux-1', api: 'fixture-faux', id: 'deferred:d5b' } } };
  await root.commit(async tx => {
    const record = await tx.task(ids.taskId);
    tx.setTask({ ...record, state: { status: 'pending', checkpoint } });
  }, context);
  const pre = await snapshot(store, root.id);
  await harness.close(context);
  return { ids, rootId: root.id, pre };
}
async function resume(kind, path, ids, rootId) {
  const store = await storage(kind, path);
  const harness = await Harness.open(store, { models: createModels(), registry: createRegistry(), now: () => clock }, context);
  harness.resume();
  let deadline;
  try {
    await Promise.race([harness.waitForTask(ids.taskId, context),
      new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error('Phase did not settle')), 10000); })]);
  } finally { clearTimeout(deadline); }
  const post = await snapshot(store, rootId);
  await harness.close(context);
  return post;
}
try {
  if (v160) {
    const reverse = process.argv.indexOf('--resume-swift');
    if (reverse >= 0) {
      const name = process.argv[reverse + 1], path = process.argv[reverse + 2];
      const item = JSON.parse(await readFile(oracleOutput, 'utf8')).cases[name];
      if (!item || !path) throw new Error('--v160 --resume-swift needs CASE and PATH');
      const copied = join(temporary, `${name}-swift${item.backend === 'sqlite' ? '.sqlite' : ''}`);
      await copy(item.backend, path, copied);
      const store = await storage(item.backend, copied);
      const before = await snapshot(store, item.rootId);
      await store.close(context);
      if (!isDeepStrictEqual(before, item.swiftPre)) throw new Error(`${name} Swift v1.6 pre differs`);
      const after = await resume(item.backend, copied, item.ids, item.rootId);
      if (!isDeepStrictEqual(after, item.swiftPost)) throw new Error(`${name} Swift v1.6 post differs`);
      console.log(`Swift ${name} file resumes under v1.6.0 to the tagged final records.`);
    } else {
    const frozen = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8'));
    if (frozen.tag !== 'v1.5.2') throw new Error('Frozen phase manifest differs');
    const manifest = { sourceTag: 'v1.5.2', tag: 'v1.6.0', clock, cases: {} };
    for (const [name, item] of Object.entries(frozen.cases)) {
      const kind = item.backend;
      const sourcePath = join(output, name, `pre${kind === 'sqlite' ? '.sqlite' : ''}`);
      const copied = join(temporary, `${name}-v160${kind === 'sqlite' ? '.sqlite' : ''}`);
      await copy(kind, sourcePath, copied);
      const store = await storage(kind, copied);
      const pre = await snapshot(store, item.rootId);
      await store.close(context);
      if (!isDeepStrictEqual(pre, item.pre)) throw new Error(`${name} frozen pre differs`);
      const post = await resume(kind, copied, item.ids, item.rootId);
      const swiftSeedPath = join(temporary, `${name}-new-seed${kind === 'sqlite' ? '.sqlite' : ''}`);
      const seeded = await seed(kind, swiftSeedPath, item.phase);
      const swiftPostPath = join(temporary, `${name}-new-post${kind === 'sqlite' ? '.sqlite' : ''}`);
      await copy(kind, swiftSeedPath, swiftPostPath);
      const swiftPost = await resume(kind, swiftPostPath, seeded.ids, seeded.rootId);
      manifest.cases[name] = { ...item, post, swiftPre: seeded.pre, swiftPost };
    }
    const text = JSON.stringify(manifest) + '\n';
    if (check) {
      if (await readFile(oracleOutput, 'utf8') !== text) throw new Error('v1.6.0 phase continuation differs');
    } else {
      await mkdir(join(output, '..', 'd5b-phase-v160'), { recursive: true });
      await writeFile(oracleOutput, text);
    }
    console.log(`D5b v1.6.0 frozen phase continuations ${check ? 'match' : 'written'}: ${Object.keys(manifest.cases).length} cases.`);
    }
  } else {
  const reverse = process.argv.indexOf('--resume-swift');
  if (reverse >= 0) {
    const name = process.argv[reverse + 1], path = process.argv[reverse + 2];
    if (!name || !path) throw new Error('--resume-swift needs CASE and PATH');
    const saved = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')).cases[name];
    if (!saved) throw new Error(`Unknown case ${name}`);
    const kind = saved.backend;
    const copied = join(temporary, `swift-${name}${kind === 'sqlite' ? '.sqlite' : ''}`);
    await copy(kind, path, copied);
    const store = await storage(kind, copied);
    const before = await snapshot(store, saved.rootId);
    await store.close(context);
    if (!isDeepStrictEqual(before, saved.pre)) throw new Error(`${name} Swift pre records differ`);
    const after = await resume(kind, copied, saved.ids, saved.rootId);
    if (!isDeepStrictEqual(after, saved.post)) throw new Error(`${name} Swift pre resumes differently under ${upstreamTag}`);
    console.log(`Swift ${name} pre file resumes under ${upstreamTag} to the tagged final records.`);
  } else {
  const manifest = { tag: upstreamTag, clock, cases: {} };
  for (const phase of ['finish', 'drain', 'retryPoll']) for (const kind of ['sqlite', 'jsonl']) {
    const name = `${phase}-${kind}`;
    const prePath = join(temporary, `${name}-pre${kind === 'sqlite' ? '.sqlite' : ''}`);
    const postPath = join(temporary, `${name}-post${kind === 'sqlite' ? '.sqlite' : ''}`);
    const { ids, rootId, pre } = await seed(kind, prePath, phase);
    await copy(kind, prePath, postPath);
    const post = await resume(kind, postPath, ids, rootId);
    manifest.cases[name] = { phase, backend: kind, ids, rootId, pre, post };
    const dest = join(output, name);
    if (check) {
      const savedPre = join(dest, `pre${kind === 'sqlite' ? '.sqlite' : ''}`);
      const savedPost = join(dest, `post${kind === 'sqlite' ? '.sqlite' : ''}`);
      const checkPath = join(temporary, `${name}-check${kind === 'sqlite' ? '.sqlite' : ''}`);
      await copy(kind, savedPre, checkPath);
      const checkStore = await storage(kind, checkPath);
      const checkPre = await snapshot(checkStore, rootId);
      await checkStore.close(context);
      if (!isDeepStrictEqual(checkPre, pre)) throw new Error(`${name} pre differs`);
      const checkPost = await resume(kind, checkPath, ids, rootId);
      if (!isDeepStrictEqual(checkPost, post)) throw new Error(`${name} resumed post differs`);
      const savedStore = await storage(kind, savedPost);
      const saved = await snapshot(savedStore, rootId);
      await savedStore.close(context);
      if (!isDeepStrictEqual(saved, post)) throw new Error(`${name} stored post differs`);
    } else {
      await mkdir(dest, { recursive: true });
      await copy(kind, prePath, join(dest, `pre${kind === 'sqlite' ? '.sqlite' : ''}`));
      await copy(kind, postPath, join(dest, `post${kind === 'sqlite' ? '.sqlite' : ''}`));
    }
  }
  const serialized = JSON.stringify(manifest, null, 2) + '\n';
  if (check) {
    if (await readFile(join(output, 'manifest.json'), 'utf8') !== serialized) throw new Error('Manifest differs');
  } else {
    await mkdir(output, { recursive: true });
    await writeFile(join(output, 'manifest.json'), serialized);
  }
  console.log(`D5b tagged phases ${check ? 'match' : 'written'}: 3 phases, SQLite and JSONL.`);
  }
  }
} finally {
  Date.now = oldDateNow;
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
