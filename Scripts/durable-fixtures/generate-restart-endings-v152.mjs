// Cross-language restart endings from the unmodified v1.5.2 Harness.
// Each pre file holds a running task one host death before its restart limit.
// --check regenerates in a temporary directory and checks the checked-in records.
import { spawnSync } from 'node:child_process';
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152, upstreamTag } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}

const check = process.argv.includes('--check');
const outputIndex = process.argv.indexOf('--output-dir');
const output = outputIndex < 0
  ? fileURLToPath(new URL('./restart-endings-v152/', import.meta.url))
  : process.argv[outputIndex + 1];
if (!output) throw new Error('--output-dir needs a path');
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-restart-endings-v152-'));
const swiftSeeds = join(temporary, 'swift-seeds');
const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
const { Harness } = await source.import('packages/durable/src/harness/harness.ts');
const { createRegistry } = await source.import('packages/durable/src/harness/registry.ts');
const { defineExtension } = await source.import('packages/durable/src/harness/define.ts');
const { defineTask } = await source.import('packages/durable/src/tasks.ts');
const { createCompaction } = await source.import('packages/durable/src/harness/compaction.ts');
const { LiveDoc } = await source.import('packages/durable/src/harness/live.ts');
const { createModels } = await source.import('packages/ai/src/models.ts');
const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
const json = value => value === undefined ? null : JSON.parse(JSON.stringify(value));

const scenarios = [
  { name: 'extension-run', kind: 'extension', restartLimit: 2 },
  { name: 'extension-abort', kind: 'extension', restartLimit: 2, abortRequested: true },
  { name: 'compaction', kind: 'compaction', restartLimit: 1 },
  { name: 'nested-extension', kind: 'nested', restartLimit: 2 },
];

function registry() {
  const value = createRegistry();
  const Loop = defineTask({ name: 'fixture.restart-loop', version: 1,
    initial: () => ({ phase: 'run' }),
    phases: { run: async () => { throw new Error('A cut-off task ran again'); } },
    abort: async () => { throw new Error('A cut-off abort handler ran again'); },
  });
  value.install(defineExtension({ name: 'fixture', tasks: [Loop] }));
  return { value, Loop };
}

async function openStorage(kind, path) {
  return kind === 'sqlite' ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
}

async function records(storage) {
  const page = await storage.scanTasks({ order: 'ascending' }, 100, undefined, context);
  return json(page.items);
}

async function snapshot(storage, ids, rootId) {
  const tasks = await records(storage);
  const live = json(await storage.scanDocuments({ scope: { kind: 'conversation', conversationId: rootId }, at: 'current' }, 100, undefined, context));
  return { ids, tasks, documents: live.items };
}

async function seed(kind, path, scenario) {
  const storage = await openStorage(kind, path);
  const { value: registered, Loop } = registry();
  const harness = await Harness.open(storage, { models: createModels(), registry: registered,
    settings: { restartLimit: scenario.restartLimit }, now: () => 1700000000000 }, context);
  const root = await harness.root(context);
  let ids;
  if (scenario.kind === 'compaction') {
    const id = await root.commit(tx => createCompaction(tx, root.id, { reason: 'manual' }), context);
    ids = { task: id };
  } else if (scenario.kind === 'nested') {
    ids = await root.commit(async tx => {
      const owner = await tx.createTask(Loop, null, { ownership: { kind: 'conversation' } });
      const task = await tx.createTask(Loop, null, { ownership: { kind: 'task', taskId: owner } });
      return { owner, task };
    }, context);
  } else {
    ids = { task: await root.commit(tx => tx.createTask(Loop, null, { ownership: { kind: 'conversation' } }), context) };
  }
  await root.commit(async tx => {
    const task = await tx.task(ids.task);
    const owner = ids.owner === undefined ? undefined : await tx.task(ids.owner);
    tx.setTask({ ...task, state: { status: 'running', checkpoint: { phase: scenario.kind === 'compaction' ? 'select' : 'run' } },
      restarts: scenario.restartLimit - 1, ...(scenario.abortRequested ? { abortRequested: true } : {}) });
    if (owner !== undefined) {
      tx.setTask({ ...owner, state: { status: 'completing', outcome: { status: 'completed', result: null } } });
    }
  }, context);
  const before = await snapshot(storage, ids, root.id);
  await harness.close(context);
  return { ids, rootId: root.id, before };
}

async function resume(kind, path, scenario, ids, rootId) {
  const storage = await openStorage(kind, path);
  const { value: registered } = registry();
  const reports = [];
  const harness = await Harness.open(storage, { models: createModels(), registry: registered,
    settings: { restartLimit: scenario.restartLimit }, now: () => 1700000000000,
    onReport: report => reports.push(json(report)) }, context);
  const afterOpen = json(await harness.getTask(ids.task, context));
  harness.resume();
  let deadline;
  let terminal;
  try {
    terminal = await Promise.race([
      harness.waitForTask(ids.task, context),
      new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error(`${scenario.name} did not settle`)), 10000); }),
    ]);
  } finally { clearTimeout(deadline); }
  if (ids.owner !== undefined) await harness.waitForTask(ids.owner, context);
  const after = await snapshot(storage, ids, rootId);
  const live = json(await harness.snapshot(LiveDoc, rootId, context));
  await harness.close(context);
  if (after.tasks.some(task => task.state.status !== 'terminal')) throw new Error(`${scenario.name} left live work`);
  if (afterOpen?.restarts !== scenario.restartLimit) throw new Error(`${scenario.name} did not count the death`);
  return { afterOpen, terminal: json(terminal), after, live, reports };
}

async function copyPath(kind, from, to) {
  if (kind === 'sqlite') await copyFile(from, to);
  else await cp(from, to, { recursive: true });
}

try {
  // Reverse proof: Swift writes a pre-restart file, then this tagged Node Harness resumes its copy.
  // The caller chooses an existing manifest case and backend, so IDs and every record are compared.
  const reverseIndex = process.argv.indexOf('--resume-swift');
  if (reverseIndex >= 0) {
    const name = process.argv[reverseIndex + 1];
    const swiftPath = process.argv[reverseIndex + 2];
    if (!name || !swiftPath) throw new Error('--resume-swift needs CASE and PATH');
    const expected = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')).cases[name];
    if (!expected) throw new Error(`Unknown restart case ${name}`);
    const scenario = scenarios.find(value => value.name === expected.scenario);
    const copy = join(temporary, `swift-${name}${expected.backend === 'sqlite' ? '.sqlite' : ''}`);
    await copyPath(expected.backend, swiftPath, copy);
    const storage = await openStorage(expected.backend, copy);
    const before = await snapshot(storage, expected.ids, expected.rootId);
    await storage.close(context);
    if (!isDeepStrictEqual(before, expected.pre)) throw new Error(`${name} Swift pre file differs from tagged pre records`);
    const after = await resume(expected.backend, copy, scenario, expected.ids, expected.rootId);
    if (!isDeepStrictEqual(after.after, expected.post.after)) throw new Error(`${name} Swift pre file resumes differently under tagged Node`);
    console.log(`Swift ${name} pre file resumes under ${upstreamTag} to the tagged final records.`);
  } else {
  const manifest = { tag: upstreamTag, source: 'unmodified tagged Harness and storage', cases: {} };
  for (const scenario of scenarios) {
    for (const kind of ['sqlite', 'jsonl']) {
      const name = `${scenario.name}-${kind}`;
      const pre = join(temporary, `${name}-pre${kind === 'sqlite' ? '.sqlite' : ''}`);
      const post = join(temporary, `${name}-post${kind === 'sqlite' ? '.sqlite' : ''}`);
      const { ids, rootId, before } = await seed(kind, pre, scenario);
      await copyPath(kind, pre, post);
      const resumed = await resume(kind, post, scenario, ids, rootId);
      manifest.cases[name] = { scenario: scenario.name, backend: kind, restartLimit: scenario.restartLimit,
        rootId, ids, pre: before, post: resumed };
      const destination = join(output, name);
      if (check) {
        const original = join(destination, `pre${kind === 'sqlite' ? '.sqlite' : ''}`);
        const checked = join(temporary, `${name}-checked${kind === 'sqlite' ? '.sqlite' : ''}`);
        await copyPath(kind, original, checked);
        const stored = await openStorage(kind, checked);
        const actual = await snapshot(stored, ids, rootId);
        await stored.close(context);
        if (!isDeepStrictEqual(actual, before)) throw new Error(`${name} checked-in pre file differs`);
        const seed = join(swiftSeeds, name);
        await mkdir(seed, { recursive: true });
        await copyPath(kind, checked, join(seed, kind === 'sqlite' ? 'pre.sqlite' : 'pre'));
        const checkedPost = await resume(kind, checked, scenario, ids, rootId);
        if (!isDeepStrictEqual(checkedPost.after, resumed.after)) throw new Error(`${name} checked-in pre file resumes differently`);
        const originalPost = join(destination, `post${kind === 'sqlite' ? '.sqlite' : ''}`);
        const postCopy = join(temporary, `${name}-post-checked${kind === 'sqlite' ? '.sqlite' : ''}`);
        await copyPath(kind, originalPost, postCopy);
        const postStorage = await openStorage(kind, postCopy);
        const actualPost = await snapshot(postStorage, ids, rootId);
        await postStorage.close(context);
        if (!isDeepStrictEqual(actualPost, resumed.after)) throw new Error(`${name} checked-in post file differs`);
      } else {
        await mkdir(destination, { recursive: true });
        await copyPath(kind, pre, join(destination, `pre${kind === 'sqlite' ? '.sqlite' : ''}`));
        await copyPath(kind, post, join(destination, `post${kind === 'sqlite' ? '.sqlite' : ''}`));
      }
    }
  }
  const text = JSON.stringify(manifest, null, 2) + '\n';
  const path = join(output, 'manifest.json');
  if (check) {
    if (await readFile(path, 'utf8') !== text) throw new Error('Restart ending manifest differs');
    const swiftExport = join(temporary, 'swift-export');
    await mkdir(swiftExport);
    const child = spawnSync('swift', ['test', '--skip-build', '--filter',
      'D5aRestartFixtureTests.exportsSwiftWrittenRestartPreFiles'], {
      cwd: fileURLToPath(new URL('../../', import.meta.url)), stdio: 'inherit', timeout: 120_000,
      env: { ...process.env, PISWIFT_D12_D5A_SEEDS: swiftSeeds, PISWIFT_D12_D5A_EXPORT: swiftExport },
    });
    if (child.error) throw child.error;
    if (child.status !== 0) throw new Error(`Swift D5a restart export exited ${child.status}`);
    for (const [name, item] of Object.entries(manifest.cases)) {
      const scenario = scenarios.find(value => value.name === item.scenario);
      const copied = join(temporary, `swift-export-${name}${item.backend === 'sqlite' ? '.sqlite' : ''}`);
      await copyPath(item.backend, join(swiftExport, name, item.backend === 'sqlite' ? 'pre.sqlite' : 'pre'), copied);
      const store = await openStorage(item.backend, copied);
      const before = await snapshot(store, item.ids, item.rootId);
      await store.close(context);
      if (!isDeepStrictEqual(before, item.pre)) throw new Error(`${name} Swift-written pre records differ`);
      const after = await resume(item.backend, copied, scenario, item.ids, item.rootId);
      if (!isDeepStrictEqual(after.after, item.post.after)) throw new Error(`${name} Swift-written pre resumes differently under tag`);
    }
  } else {
    await mkdir(output, { recursive: true });
    await writeFile(path, text);
  }
  console.log(`Restart endings ${check ? 'match' : 'written'}: ${scenarios.length} cases, SQLite and JSONL, tagged pre/post records.`);
  }
} finally {
  await source.close();
  await rm(temporary, { recursive: true, force: true });
}
