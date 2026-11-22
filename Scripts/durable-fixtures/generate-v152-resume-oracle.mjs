// Resume an isolated D4 v1.4.0 generation seed with the unmodified v1.5.2 Harness.
// Only temporary copies are opened; the frozen lifecycle fixture stays untouched.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { mirror } from './mirror.mjs';
import { mirrorV152 } from './mirror-v152.mjs';
import { mirrorV160 } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const check = process.argv.includes('--check');
const v160 = process.argv.includes('--v160');
const caseIndex = process.argv.indexOf('--case');
const caseName = caseIndex < 0 ? 'retrySleep' : process.argv[caseIndex + 1];
if (!caseName || (!v160 && caseName !== 'retrySleep')) throw new Error('Unsupported resume oracle case');
const outputIndex = process.argv.indexOf('--output-dir');
const fixtures = outputIndex < 0
  ? fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url))
  : process.argv[outputIndex + 1];
if (!fixtures) throw new Error('--output-dir needs a path');
const frozen = JSON.parse(await readFile(fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/lifecycle-records-v140.json', import.meta.url)), 'utf8'));
const seed = frozen.cases[caseName];
if (!seed) throw new Error(`Missing frozen D4 case ${caseName}`);
if (frozen.tag !== 'v1.4.0' || seed.seedReads[0].result.version !== 1) throw new Error('Unexpected frozen D4 generation seed');
const oldSource = await mirror({ dependencies: ['typebox@1.3.27'] });
const newSource = await (v160 ? mirrorV160 : mirrorV152)({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
const temporary = await mkdtemp(join(tmpdir(), 'piswift-v152-resume-oracle-'));
const recordText = path => {
  const db = new DatabaseSync(path, { readOnly: true });
  try { return db.prepare('SELECT record FROM tasks WHERE id = ?').get(seed.taskId)?.record; }
  finally { db.close(); }
};
try {
  const path = join(temporary, 'v140.sqlite');
  const copy = join(temporary, 'v152.sqlite');
  const { BACKGROUND_CONTEXT: oldContext } = await oldSource.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage: openOld } = await oldSource.import('packages/durable/src/storage/sqlite/node.ts');
  const writer = await openOld(path);
  try {
    for (const batch of seed.seedBatches) {
      const seq = await writer.commit(batch.writes, oldContext);
      if (seq !== batch.seq) throw new Error(`v1.4.0 seed sequence differs: ${seq}`);
    }
    const task = await writer.task(seed.taskId, oldContext);
    if (JSON.stringify(task) !== JSON.stringify(seed.seedReads[0].result)) throw new Error('Frozen D4 seed read differs');
  } finally { await writer.close(oldContext); }
  await copyFile(path, copy);
  const beforeText = recordText(copy);
  const { BACKGROUND_CONTEXT: context } = await newSource.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage: openNew } = await newSource.import('packages/durable/src/storage/sqlite/node.ts');
  const { Harness } = await newSource.import('packages/durable/src/harness/harness.ts');
  const { createRegistry } = await newSource.import('packages/durable/src/harness/registry.ts');
  const { createModels } = await newSource.import('packages/ai/src/models.ts');
  const { fauxProvider, fauxAssistantMessage, fauxText } = await newSource.import('packages/ai/src/providers/faux.ts');
  let sleeping;
  if (v160) {
    const interimPath = join(temporary, `${caseName}-sleeping.sqlite`);
    await copyFile(path, interimPath);
    const interimStore = await openNew(interimPath);
    const interimHarness = await Harness.open(interimStore, { models: createModels(), registry: createRegistry(),
      settings: { retry: { enabled: true, maxRetries: 2, baseDelayMs: 60000 } },
      now: () => 1000, onWake: () => {}, setTimer: () => undefined,
    }, context);
    interimHarness.resume();
    for (let attempt = 0; attempt < 100; attempt++) {
      sleeping = await interimStore.task(seed.taskId, context);
      if (sleeping?.state.status === 'sleeping') break;
      await new Promise(resolve => setTimeout(resolve, 0));
    }
    if (sleeping?.state.status !== 'sleeping') throw new Error(`${caseName} did not reach the saved sleep`);
    await interimHarness.close(context);
  }
  const faux = fauxProvider();
  faux.setResponses([fauxAssistantMessage([fauxText('resumed')])]);
  const models = createModels();
  models.setProvider(faux.provider);
  if (v160 && caseName === 'pollSleep') {
    models.fetchDeferred = async () => fauxAssistantMessage([fauxText('resumed')]);
  }
  const storage = await openNew(copy);
  const harness = await Harness.open(storage, { models, registry: createRegistry(),
    settings: { retry: { enabled: true, maxRetries: 2, baseDelayMs: 60000 } },
    now: () => 61000, onWake: () => {}, setTimer: () => undefined,
  }, context);
  harness.resume();
  const receipt = await harness.waitForTask(seed.taskId, context);
  const after = await storage.task(seed.taskId, context);
  await harness.close(context);
  const afterText = recordText(copy);
  const targetVersion = v160 ? 3 : 2;
  const targetTag = v160 ? 'v1.6.0' : 'v1.5.2';
  if (after.version !== targetVersion || after.state.status !== 'terminal') throw new Error(`Tagged ${targetTag} Harness did not migrate and finish the generation`);
  const oracle = { sourceTag: 'v1.4.0', targetTag, case: `D4SharedFileResume.${caseName}`,
    seedTaskId: seed.taskId, before: { record: JSON.parse(beforeText), recordText: beforeText },
    ...(v160 ? { sleeping } : {}),
    after: { record: after, recordText: afterText, receipt: receipt.record },
  };
  const suffix = v160 && caseName !== 'retrySleep' ? `-${caseName}` : '';
  const target = join(fixtures, `generation-resume-oracle-${v160 ? 'v160' : 'v152'}${suffix}.json`);
  const text = JSON.stringify(oracle) + '\n';
  if (check) {
    if (await readFile(target, 'utf8') !== text) throw new Error('v1.5.2 generation resume oracle differs');
  } else {
    await mkdir(fixtures, { recursive: true });
    await writeFile(target, text);
  }
  console.log(`Generation resume oracle ${check ? 'matches' : 'written'}: task ${seed.taskId}, version ${oracle.before.record.version} to ${after.version}.`);
} finally {
  await oldSource.close();
  await newSource.close();
  await rm(temporary, { recursive: true, force: true });
}
