// Use unmodified source files from the upstream tag. Never write to pi-mono.
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const upstreamRepository = '/Users/miguel/cvs/pi/pi-mono';
export const upstreamTag = 'v1.1.0';

function completion(child) {
  return new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`Mirror command exited ${code}`)));
  });
}

export async function mirror() {
  const directory = await mkdtemp(join(tmpdir(), 'piswift-durable-fixtures-'));
  try {
    const archive = spawn('git', ['-C', upstreamRepository, 'archive', upstreamTag,
      'packages/chord/src', 'packages/durable/src', 'packages/ai/src'], { stdio: ['ignore', 'pipe', 'inherit'] });
    const extract = spawn('tar', ['-x', '-C', directory], { stdio: ['pipe', 'inherit', 'inherit'] });
    archive.stdout.pipe(extract.stdin);
    await Promise.all([completion(archive), completion(extract)]);
    const packages = {
      chord: { '.': './src/index.ts', './delta': './src/delta/index.ts', './context': './src/context/index.ts' },
      ai: { '.': './src/index.ts', './utils/*': './src/utils/*.ts' },
    };
    await mkdir(join(directory, 'node_modules/@earendil-works'), { recursive: true });
    for (const [name, exports] of Object.entries(packages)) {
      await writeFile(join(directory, `packages/${name}/package.json`), JSON.stringify({ type: 'module', exports }));
      await symlink(join(directory, `packages/${name}`), join(directory, 'node_modules/@earendil-works', name === 'ai' ? 'pi-ai' : name));
    }
    await writeFile(join(directory, 'packages/durable/package.json'), JSON.stringify({ type: 'module' }));
    return {
      directory,
      import: path => import(pathToFileURL(join(directory, path)).href),
      close: () => rm(directory, { recursive: true, force: true }),
    };
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
}
