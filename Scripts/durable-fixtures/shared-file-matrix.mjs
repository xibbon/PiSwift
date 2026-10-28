// Runtime fixture bridge for SharedFileCloseoutTests. Missing file combinations are
// made in the test's temporary directory. Existing checked-in Node files are reused.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, cp } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror } from './mirror.mjs';
import { jsonResult, readRecordedCalls, compareRecordedReads } from './sqlite-fixtures.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const [mode, directory, backend] = process.argv.slice(2);
if (['prepare-v140', 'verify-v140', 'prepare-migration', 'verify-migration', 'prepare-resume', 'verify-resume'].includes(mode)) {
  await import('./shared-file-v140.mjs');
  process.exit(0);
}
if (!['prepare', 'verify'].includes(mode) || !directory || !['sqlite', 'prefix', 'jsonl'].includes(backend)) {
  throw new Error('Usage: node shared-file-matrix.mjs prepare|verify DIRECTORY sqlite|prefix|jsonl');
}
const fixtures = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url));
const load = async name => JSON.parse(await readFile(join(fixtures, name), 'utf8'));
const source = await mirror({ tag: 'v1.4.0' });
try {
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const open = path => backend === 'jsonl' ? openNodeJsonlStorage(path, context) :
    openNodeSqliteStorage(path, backend === 'prefix' ? { prefix: 'pi_' } : {});
  const manifestPath = join(directory, `manifest-${backend}.json`);
  if (mode === 'verify') {
    const datasets = JSON.parse(await readFile(manifestPath, 'utf8'));
    let count = 0;
    for (const dataset of datasets) {
      for (const step of [{ reads: dataset.reads }, ...dataset.checkpoints]) {
        const path = join(directory, 'swift', backend, dataset.name + (step.seq ? `.checkpoint-${step.seq}` : ''));
        const storage = await open(path);
        try { compareRecordedReads(await readRecordedCalls(storage, step.reads, context), step.reads, `${backend}/${dataset.name}`); }
        finally { await storage.close(context); }
        count += step.reads.length;
      }
    }
    console.log(`Mirror verified Swift ${backend}: ${datasets.length} datasets, ${count} reads including checkpoints.`);
  } else {
    const tools = await load('tool-task-records-v130.json');
    const nested = await load('nested-tool-records-v130.json');
    const restart = await load('restart-records-v130.json');
    const documents = await load('closeout-documents-v130.json');
    const codemode = await load('codemode-v130.json');
    const datasets = [
      { name: 'tools', ...tools, existing: ['tool-task-upstream-v130.sqlite', 'tool-task-upstream-jsonl-v130'] },
      { name: 'migrated', batches: structuredClone(tools.batches), migrations: tools.migrations },
      { name: 'nested', ...nested, existing: ['nested-tool-upstream-v130.sqlite', 'nested-tool-upstream-jsonl-v130'] },
      { name: 'restart', ...restart, existing: ['restart-upstream-v130.sqlite', 'restart-upstream-jsonl-v130'] },
      { name: 'documents', ...documents },
      { name: 'codemode', ...codemode },
    ];
    const { MemoryStorage } = await source.import('packages/durable/src/storage/memory.ts');
    for (const dataset of datasets) {
      dataset.checkpoints ??= [];
      const memory = new MemoryStorage();
      try {
        for (const batch of dataset.batches) await memory.commit(batch.writes, context);
        if (dataset.name === 'migrated') {
          const writes = [];
          for (const migration of tools.migrations) {
            const task = await memory.task(migration.taskId, context);
            writes.push({ type: 'task', value: { ...task, version: 2, input: migration.input,
              state: { ...task.state, checkpoint: migration.checkpoint } } });
          }
          const seq = await memory.commit(writes, context);
          dataset.batches.push({ seq, writes });
          // Use every original read, with results from the migrated upstream storage.
          dataset.reads = await readRecordedCalls(memory, tools.reads, context);
        }
        if (dataset.name === 'codemode') {
          dataset.reads = [];
          const items = [];
          for (const scope of [{ kind: 'task', taskId: dataset.taskId },
            { kind: 'conversation', conversationId: dataset.conversationId },
            { kind: 'conversation', conversationId: dataset.forkId }]) {
            items.push(...(await memory.scanDocuments({ scope, at: 'current' }, 100, undefined, context)).items);
          }
          const page = { items };
          for (const record of page.items) {
            const address = { kind: record.kind, scope: record.scope };
            dataset.reads.push({ method: 'findDocument', arguments: [address, 'current'], result: jsonResult(await memory.findDocument(address, 'current', context)) });
            dataset.reads.push({ method: 'document', arguments: [record.id, 'current'], result: jsonResult(await memory.document(record.id, 'current', context)) });
          }
          // Latest/task documents have no history; save each upstream snapshot as a file.
          const partial = new MemoryStorage();
          try {
            for (const batch of dataset.batches) {
              await partial.commit(batch.writes, context);
              if (dataset.snapshots.some(snapshot => snapshot.seq === batch.seq)) {
                const calls = dataset.reads.filter(call => call.result?.record?.scope?.conversationId !== dataset.forkId &&
                  call.result?.scope?.conversationId !== dataset.forkId);
                dataset.checkpoints.push({ seq: batch.seq, reads: await readRecordedCalls(partial, calls, context) });
              }
            }
          } finally { await partial.close(context); }
        }
      } finally { await memory.close(context); }
      const destination = join(directory, 'node', backend, dataset.name);
      await mkdir(join(directory, 'node', backend), { recursive: true });
      const reused = dataset.existing && backend !== 'prefix';
      if (reused) await cp(join(fixtures, dataset.existing[backend === 'jsonl' ? 1 : 0]), destination, { recursive: true });
      for (const step of [{ reads: dataset.reads }, ...dataset.checkpoints]) {
        const path = destination + (step.seq ? `.checkpoint-${step.seq}` : '');
        const storage = await open(path);
        try {
          if (!reused || step.seq) {
            for (const batch of dataset.batches) {
              if (step.seq && batch.seq > step.seq) break;
              const seq = await storage.commit(batch.writes, context);
              if (seq !== batch.seq) throw new Error(`Commit sequence differs in ${dataset.name}`);
            }
          }
          compareRecordedReads(await readRecordedCalls(storage, step.reads, context), step.reads, `${backend}/${dataset.name}`);
        } finally { await storage.close(context); }
      }
      // Keep manifest small and independent of the upstream object implementations.
      delete dataset.existing;
    }
    await writeFile(manifestPath, JSON.stringify(datasets));
    console.log(`Matrix prepared ${backend}: ${datasets.length} datasets; existing Node files reused where available.`);
  }
} finally { await source.close(); }
