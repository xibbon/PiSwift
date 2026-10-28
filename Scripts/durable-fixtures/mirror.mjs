// Use unmodified source files from the upstream tag. Never write to pi-mono.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const upstreamRepository = '/Users/miguel/cvs/pi/pi-mono';
export const upstreamTag = 'v1.3.0';

function completion(child) {
  return new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`Mirror command exited ${code}`)));
  });
}

export async function mirror({ dependencies = [], tag = upstreamTag } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'piswift-durable-fixtures-'));
  try {
    const archive = spawn('git', ['-C', upstreamRepository, 'archive', tag,
      'packages/chord/src', 'packages/durable/src', 'packages/ai/src', 'packages/telemetry/src'], { stdio: ['ignore', 'pipe', 'inherit'] });
    const extract = spawn('tar', ['-x', '-C', directory], { stdio: ['pipe', 'inherit', 'inherit'] });
    archive.stdout.pipe(extract.stdin);
    await Promise.all([completion(archive), completion(extract)]);
    // Install first: npm prunes package links that are not in its manifest.
    if (dependencies.length) execFileSync('npm', ['install', '--prefix', directory, '--no-audit', '--no-fund', '--ignore-scripts', ...dependencies], { stdio: 'ignore' });
    const packages = {
      chord: { '.': './src/index.ts', './delta': './src/delta/index.ts', './context': './src/context/index.ts', './output': './src/output.ts' },
      ai: { '.': './src/index.ts', './utils/*': './src/utils/*.ts' },
      telemetry: { '.': './src/index.ts', './testing': './src/testing/index.ts' },
    };
    // SQLite moved to Chord in v1.4.0. Keep older tags' export maps unchanged.
    const chord = JSON.parse(execFileSync('git', ['-C', upstreamRepository, 'show', `${tag}:packages/chord/package.json`], { encoding: 'utf8' }));
    for (const subpath of ['./sqlite', './sqlite/node', './sqlite/cloudflare']) {
      const source = chord.exports[subpath]?.source;
      if (source) packages.chord[subpath] = source;
    }
    await mkdir(join(directory, 'node_modules/@earendil-works'), { recursive: true });
    for (const [name, exports] of Object.entries(packages)) {
      await writeFile(join(directory, `packages/${name}/package.json`), JSON.stringify({ type: 'module', exports }));
      await symlink(join(directory, `packages/${name}`), join(directory, 'node_modules/@earendil-works', name === 'chord' ? name : `pi-${name}`));
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
