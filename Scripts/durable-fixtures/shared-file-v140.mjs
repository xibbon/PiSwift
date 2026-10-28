// Run v1.4.0 shared-file checks only in the caller's temporary directory.
import { readFile, writeFile, mkdir, cp } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { isDeepStrictEqual } from 'node:util';
import { mirror } from './mirror.mjs';
import { readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

const [mode, directory, backend] = process.argv.slice(2);
if (!directory || !['sqlite', 'prefix', 'jsonl'].includes(backend)) throw new Error('Invalid v1.4.0 matrix arguments');
const fixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));
const load = async name => JSON.parse(await readFile(join(fixtures, name), 'utf8'));
const prefix = backend === 'prefix' ? 'pi_' : '';
const source = await mirror({ tag: 'v1.4.0' });
try {
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const open = path => backend === 'jsonl' ? openNodeJsonlStorage(path, context) : openNodeSqliteStorage(path, prefix ? { prefix } : {});
  const manifestPath = join(directory, `manifest-v140-${backend}.json`);
  const equal = (actual, expected, label) => {
    if (!isDeepStrictEqual(actual, expected)) throw new Error(`${label} differs`);
  };
  // Snapshot only temporary copies. Never open a checked-in fixture handle.
  const snapshot = path => {
    const db = new DatabaseSync(path, { readOnly: true });
    try {
      const tables = ['conversations', 'entries', 'tasks', 'submissions', 'documents', 'document_revisions', 'record_ids', 'durable_metadata'];
      const rows = Object.fromEntries(tables.map(table => [table, db.prepare(`SELECT * FROM ${prefix}${table} ORDER BY 1, 2`).all()]));
      const indexes = db.prepare("SELECT name, sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = ? ORDER BY name").all(`${prefix}tasks`);
      const version = db.prepare(`SELECT version FROM ${prefix}durable_schema`).get().version;
      const temporary = db.prepare("SELECT name FROM sqlite_schema WHERE name = ?").all(`${prefix}tasks_v2`);
      return JSON.parse(JSON.stringify({ rows, indexes, version, temporary }));
    } finally { db.close(); }
  };
  // Add a direct read for every stored record, not only the scenario's selected reads.
  const allCalls = batches => {
    const calls = new Map();
    const add = (method, args) => calls.set(JSON.stringify([method, args]), { method, arguments: args });
    for (const batch of batches) for (const write of batch.writes) {
      if (['conversation', 'entry', 'task', 'submission'].includes(write.type)) add(write.type, [write.value.id]);
      if (write.type === 'document.create' || write.type === 'document.copy') {
        add('document', [write.record.id, 'current']);
        const { kind, scope, key } = write.record;
        add('findDocument', [{ kind, scope, ...(key === undefined ? {} : { key }) }, 'current']);
      }
    }
    return [...calls.values()];
  };
  const readAll = async (storage, batches, selected = []) => {
    const calls = new Map();
    for (const call of [...selected, ...allCalls(batches)]) calls.set(JSON.stringify([call.method, call.arguments]), call);
    return readRecordedCalls(storage, [...calls.values()], context);
  };
  const existingFiles = {
    'tool-task-records': ['tool-task-upstream-v140.sqlite', 'tool-task-upstream-jsonl-v140'],
    'nested-tool-records': ['nested-tool-upstream-v140.sqlite', 'nested-tool-upstream-jsonl-v140'],
    'restart-records': ['restart-upstream-v140.sqlite', 'restart-upstream-jsonl-v140'],
    'lifecycle-records': ['lifecycle-upstream-v140.sqlite', 'lifecycle-upstream-jsonl-v140'],
  };
  const steps = dataset => [{ reads: dataset.reads }, ...dataset.checkpoints];
  const pathFor = (producer, dataset, step) => join(directory, `${producer}-v140`, backend,
    dataset.name + (step.seq === undefined ? '' : `.checkpoint-${step.seq}`));
  const replay = async (storage, batches, through) => {
    for (const batch of batches) {
      if (through !== undefined && batch.seq > through) break;
      equal(await storage.commit(batch.writes, context), batch.seq, 'Commit sequence');
    }
  };
  if (mode === 'prepare-v140') {
    const datasets = [];
    for (const name of ['tool-task-records', 'nested-tool-records', 'restart-records', 'closeout-documents', 'codemode', 'lifecycle-records']) {
      const fixture = await load(`${name}-v140.json`);
      datasets.push({ name, ...fixture });
      if (name === 'codemode') datasets.push({ name: 'codemode-checkpoints', tag: fixture.tag,
        provenance: fixture.provenance, batches: fixture.checkpointEvidence.batches, reads: [], checkpoints: [
          { seq: fixture.checkpointEvidence.baseBatch.seq - 1, reads: [] },
          { seq: fixture.checkpointEvidence.baseBatch.seq, reads: [] },
        ] });
    }
    for (const dataset of datasets) {
      equal(dataset.tag, 'v1.4.0', `${dataset.name} tag`);
      dataset.checkpoints ??= [];
      if (dataset.name === 'codemode') dataset.checkpoints = dataset.snapshots.map(({ seq }) => ({ seq, reads: [] }));
      const memory = new MemoryStorage();
      try {
        await replay(memory, dataset.batches);
        if (dataset.reads) compareRecordedReads(await readRecordedCalls(memory, dataset.reads, context), dataset.reads, dataset.name);
        dataset.reads = await readAll(memory, dataset.batches, dataset.reads);
      } finally { await memory.close(context); }
      for (const step of dataset.checkpoints) {
        const partial = new MemoryStorage();
        const batches = dataset.batches.filter(batch => batch.seq <= step.seq);
        try {
          await replay(partial, batches);
          compareRecordedReads(await readRecordedCalls(partial, step.reads, context), step.reads, `${dataset.name} checkpoint`);
          step.reads = await readAll(partial, batches, step.reads);
        } finally { await partial.close(context); }
      }
      await mkdir(join(directory, 'node-v140', backend), { recursive: true });
      for (const step of steps(dataset)) {
        const existing = step.seq === undefined && backend !== 'prefix' ? existingFiles[dataset.name] : undefined;
        const path = pathFor('node', dataset, step);
        if (existing) await cp(join(fixtures, existing[backend === 'jsonl' ? 1 : 0]), path, { recursive: true });
        const storage = await open(path);
        try {
          if (!existing) await replay(storage, dataset.batches, step.seq);
          compareRecordedReads(await readRecordedCalls(storage, step.reads, context), step.reads, `${backend}/${dataset.name}`);
        } finally { await storage.close(context); }
      }
    }
    await writeFile(manifestPath, JSON.stringify(datasets));
    console.log(`Matrix prepared v1.4.0 ${backend}: ${datasets.length} datasets with all records and checkpoints.`);
  } else if (mode === 'verify-v140') {
    const datasets = JSON.parse(await readFile(manifestPath, 'utf8'));
    let count = 0;
    for (const dataset of datasets) for (const step of steps(dataset)) {
      const storage = await open(pathFor('swift', dataset, step));
      try { compareRecordedReads(await readRecordedCalls(storage, step.reads, context), step.reads, `${backend}/${dataset.name}`); }
      finally { await storage.close(context); }
      count += step.reads.length;
    }
    console.log(`Mirror verified Swift v1.4.0 ${backend}: ${datasets.length} datasets, ${count} exact reads.`);
  } else if (mode === 'prepare-resume') {
    const fixture = await load('lifecycle-records-v140.json');
    const cases = [];
    await mkdir(join(directory, 'node-resume', backend), { recursive: true });
    for (const [name, value] of Object.entries(fixture.cases)) {
      if (!value.seedBatches?.length) throw new Error(`No isolated upstream seed batches for ${name}`);
      const path = join(directory, 'node-resume', backend, name);
      const storage = await open(path);
      try {
        await replay(storage, value.seedBatches);
        if (value.seedReads) compareRecordedReads(await readRecordedCalls(storage, value.seedReads, context), value.seedReads, `${name} seed`);
        const reads = await readAll(storage, value.seedBatches, value.seedReads);
        const record = reads.find(call => call.method === 'task' && call.arguments[0] === value.taskId)?.result;
        cases.push({ name, ...value, record, reads });
      } finally { await storage.close(context); }
    }
    await writeFile(join(directory, `manifest-resume-${backend}.json`), JSON.stringify(cases));
    console.log(`Matrix prepared resume ${backend}: ${cases.length} isolated upstream lifecycle files.`);
  } else if (mode === 'verify-resume') {
    const cases = JSON.parse(await readFile(join(directory, `expected-resume-${backend}.json`), 'utf8'));
    let count = 0;
    for (const item of cases) {
      if (!item.reads?.length) throw new Error(`No expected post-resume reads for ${item.name}`);
      const storage = await open(join(directory, 'node-resume', backend, item.name));
      try { compareRecordedReads(await readRecordedCalls(storage, item.reads, context), item.reads, `${backend}/${item.name} resumed`); }
      finally { await storage.close(context); }
      count += item.reads.length;
    }
    console.log(`Mirror verified Swift resume ${backend}: ${cases.length} lifecycle cases, ${count} exact reads.`);
  } else if (mode === 'prepare-migration') {
    if (backend === 'jsonl') throw new Error('JSONL has no schema migration');
    const fixture = backend === 'prefix' ? 'prefix-upstream-v130.sqlite' : 'tool-task-upstream-v130.sqlite';
    await mkdir(directory, { recursive: true });
    // Copy the closed schema-1 fixture before opening any database handle.
    for (const name of ['migrate-swift.sqlite', 'migrate-node.sqlite']) await cp(join(fixtures, fixture), join(directory, name));
    const before = snapshot(join(directory, 'migrate-swift.sqlite'));
    equal(before.version, 1, 'Frozen schema version');
    const path = join(directory, 'migrate-node.sqlite');
    const storage = await open(path);
    try { for (const row of before.rows.tasks) equal(await storage.task(row.id, context), JSON.parse(row.record), 'TS migrated task'); }
    finally { await storage.close(context); }
    const after = snapshot(path);
    equal(after.version, 2, 'Migrated schema version');
    equal(after.rows, before.rows, 'Every stored row and raw record text');
    equal(after.indexes, before.indexes, 'All task indexes');
    equal(after.temporary, [], 'Temporary rebuild table');
    const lifecycle = await load('lifecycle-records-v140.json');
    const sleeping = lifecycle.batches.flatMap(batch => batch.writes).find(write => write.type === 'task' && write.value.state.status === 'sleeping');
    if (!sleeping) throw new Error('No upstream sleeping task fixture');
    const sleepingWrite = { type: 'task', value: { ...JSON.parse(before.rows.tasks[0].record), state: sleeping.value.state } };
    const sleepPath = join(directory, 'migrate-node-sleep.sqlite');
    await cp(path, sleepPath);
    const sleepStorage = await open(sleepPath);
    let sleepingSeq;
    try { sleepingSeq = await sleepStorage.commit([sleepingWrite], context); }
    finally { await sleepStorage.close(context); }
    await writeFile(join(directory, 'migration.json'), JSON.stringify({ fixture, before, after, sleepingWrite, sleepingSeq, sleepAfter: snapshot(sleepPath) }));
    console.log(`Matrix prepared migration ${backend}: frozen schema 1; TS v1.4.0 preserves all rows, raw text, indexes and metadata.`);
  } else if (mode === 'verify-migration') {
    const manifest = JSON.parse(await readFile(join(directory, 'migration.json'), 'utf8'));
    const old = await mirror({ tag: 'v1.3.0' });
    try {
      const { openNodeSqliteStorage: openOld } = await old.import('packages/durable/src/storage/sqlite/node.ts');
      for (const producer of ['swift', 'node']) for (const sleeping of [false, true]) {
        const path = join(directory, `migrate-${producer}${sleeping ? '-sleep' : ''}.sqlite`);
        const migrated = snapshot(path);
        if (!sleeping) equal(migrated, manifest.after, `${producer} migration all rows/raw text/indexes/metadata`);
        else {
          const normalized = structuredClone(migrated);
          const expected = structuredClone(manifest.sleepAfter);
          for (const image of [normalized, expected]) for (const row of image.rows.tasks) {
            if (row.id === manifest.sleepingWrite.value.id) row.record = JSON.parse(row.record);
          }
          equal(normalized, expected, `${producer} sleeping write and unchanged raw rows/indexes/metadata`);
        }
        const storage = await open(path);
        try {
          for (const row of manifest.before.rows.tasks) {
            const expected = sleeping && row.id === manifest.sleepingWrite.value.id ? manifest.sleepingWrite.value : JSON.parse(row.record);
            equal(await storage.task(row.id, context), expected, `${producer} migrated full task`);
          }
        } finally { await storage.close(context); }
        let rejected = false;
        try { const accepted = await openOld(path, prefix ? { prefix } : {}); await accepted.close(context); }
        catch (error) {
          if (!String(error).includes('newer than supported version')) throw error;
          rejected = true;
        }
        if (!rejected) throw new Error('v1.3.0 accepted schema 2');
        equal(snapshot(path), migrated, 'Rejected v1.3.0 open changed the file');
      }
    } finally { await old.close(); }
    console.log(`Mirror verified Swift migration ${backend}: both migrations, all raw rows and indexes; v1.3.0 rejects schema 2 with and without sleeping.`);
  } else { throw new Error(`Unknown v1.4.0 matrix mode ${mode}`); }
} finally { await source.close(); }
