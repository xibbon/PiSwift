// Share an immutable tagged source mirror across Node fixture cases. The
// cache lives in the system test temporary directory, never in pi-mono.
import { createHash } from 'node:crypto';
import { access, cp, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = join(tmpdir(), 'piswift-durable-test-mirrors');
const readyFile = '.mirror-ready';
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const exists = async path => { try { await access(path); return true; } catch { return false; } };

export async function cachedMirror({ tag, generatorURL, dependencies, build, mutable = false }) {
  const generator = await readFile(new URL(generatorURL));
  const key = createHash('sha256').update(JSON.stringify({
    tag, dependencies, node: process.versions.node, format: 2,
  })).update(generator).digest('hex').slice(0, 24);
  await mkdir(root, { recursive: true });
  const directory = join(root, key);
  const lock = join(root, `${key}.lock`);
  const ready = join(directory, readyFile);
  const started = Date.now();
  while (!(await exists(ready))) {
    try {
      await mkdir(lock);
      let staging;
      try {
        if (!(await exists(ready))) {
          staging = await mkdtemp(join(root, 'building-'));
          await build(staging);
          await writeFile(join(staging, readyFile), key);
          if (await exists(directory)) await rm(directory, { recursive: true, force: true });
          await rename(staging, directory);
          staging = undefined;
        }
      } finally {
        if (staging) await rm(staging, { recursive: true, force: true });
        await rm(lock, { recursive: true, force: true });
      }
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      // A killed builder must not leave every later test waiting forever.
      const age = Date.now() - (await stat(lock).catch(() => ({ mtimeMs: Date.now() }))).mtimeMs;
      if (age > 300_000) { await rm(lock, { recursive: true, force: true }); continue; }
      if (Date.now() - started > 300_000) throw new Error(`Timed out waiting for mirror ${tag}`);
      await pause(100);
    }
  }
  if (mutable) {
    // Some fixture generators add files or package links. Give them a private
    // copy so a later case always starts with the immutable tagged mirror.
    const scratch = await mkdtemp(join(root, 'mutable-'));
    const copy = join(scratch, 'mirror');
    try { await cp(directory, copy, { recursive: true, verbatimSymlinks: true }); }
    catch (error) { await rm(scratch, { recursive: true, force: true }); throw error; }
    return {
      directory: copy,
      import: path => import(pathToFileURL(join(copy, path)).href),
      close: async () => { await rm(scratch, { recursive: true, force: true }); },
    };
  }
  return { directory, import: path => import(pathToFileURL(join(directory, path)).href), close: async () => {} };
}
