// v1.5.2 D9: run the unmodified tagged JSONL backend as a concurrent writer or viewer.
import { readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { mirrorV152 } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}

const [mode, directory, signalFile, countText, paceText, progressFile, readerOpensText] = process.argv.slice(2);
if (!['write', 'read'].includes(mode) || !directory) throw new Error('Expected write|read and directory');
const mirror = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
async function fingerprints() {
  const values = [];
  for (const name of (await readdir(directory)).sort()) {
    const path = join(directory, name);
    const [metadata, bytes] = await Promise.all([stat(path), readFile(path)]);
    values.push([name, metadata.size, metadata.mtimeMs,
      createHash('sha256').update(bytes).digest('hex')]);
  }
  return JSON.stringify(values);
}
try {
  const { BACKGROUND_CONTEXT: context } = await mirror.import('packages/chord/src/context/index.ts');
  const { openNodeJsonlStorage } = await mirror.import('packages/durable/src/storage/jsonl/node.ts');
  if (mode === 'read') {
    const count = Number(countText ?? 1);
    let lastPhase = 0;
    let whileWriting = 0;
    let stableByteChecks = 0;
    let seed = 0xD9A152;
    if (signalFile) await writeFile(signalFile, 'ready');
    for (let i = 0; i < count; i++) {
      if (signalFile && !existsSync(`${signalFile}.done`)) whileWriting++;
      const before = await fingerprints();
      const storage = await openNodeJsonlStorage(directory, context, { readOnly: true });
      try {
        const root = await storage.conversation(1, context);
        if (!root) throw new Error('Tagged reader cannot see Swift root');
        const task = await storage.task(2, context);
        if (!task) throw new Error('Tagged reader cannot see Swift task');
        const phase = Number(String(task.state.checkpoint.phase).split('.')[0]) || 0;
        if (phase < lastPhase) throw new Error(`Snapshot moved backward: ${phase} < ${lastPhase}`);
        lastPhase = phase;
        let rejected = false;
        try { await storage.commit([[{ type: 'conversation', value: { id: 999999 } }]], () => {}, context); }
        catch (error) { rejected = error?.name === 'JsonlStorageReadOnlyError' && error?.message === 'JSONL storage is open read-only'; }
        if (!rejected) throw new Error('Tagged reader did not reject commit');
      } finally { await storage.close(context); }
      if (before === await fingerprints()) stableByteChecks++;
      if (signalFile) await writeFile(`${signalFile}.progress`, String(i + 1));
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      if (count > 1) await new Promise(resolve => setTimeout(resolve, seed % 3));
    }
    if (count > 1 && whileWriting < count / 2) throw new Error(`Only ${whileWriting}/${count} opens overlapped Swift writes`);
    console.log(`d9 node viewer opens=${count} whileWriting=${whileWriting} stableByteChecks=${stableByteChecks} read-only root=1 commitRejected=${count} lastPhase=${lastPhase}`);
  } else {
    const storage = await openNodeJsonlStorage(directory, context);
    try {
      const count = Number(countText ?? 400);
      const readerOpens = Number(readerOpensText ?? 0);
      const commit = async batches => {
        const result = await storage.commit(batches, () => {}, context);
        if (result.stored !== batches.length || result.refused) throw new Error(`Commit refused: ${JSON.stringify(result)}`);
      };
      await commit([[{ type: 'conversation', value: { id: 1 } }]]);
      const taskId = await storage.mintId();
      const task = phase => ({ id: taskId, conversationId: 1, kind: 'd9.writer', version: 1,
        input: null, state: { status: 'pending', checkpoint: { phase } }, background: false,
        abortRequested: false });
      await commit([[{ type: 'task', value: task('initial') }]]);
      if (signalFile) await writeFile(signalFile, 'ready');
      for (let i = 1; i <= count; i++) {
        await commit([[{ type: 'task', value: task(`${i}.a`) }],
          [{ type: 'task', value: task(`${i}.b`) }]]);
        if (progressFile && progressFile !== '-') {
          const target = Math.floor(i * readerOpens / count);
          while (true) {
            const progress = Number(await readFile(progressFile, 'utf8').catch(() => '0')) || 0;
            if (progress >= target) break;
            await new Promise(resolve => setTimeout(resolve, 2));
          }
        }
        await new Promise(resolve => setTimeout(resolve, Number(paceText ?? 2)));
      }
      console.log(`d9 node writer commits=${count * 2 + 2} refused=0`);
    } finally { await storage.close(context); }
  }
} finally { await mirror.close(); }
