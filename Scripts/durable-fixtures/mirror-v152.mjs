// Build a disposable source-only mirror of the unmodified v1.5.2 tag.
// Keep this separate from mirror.mjs so v1.4.0 fixtures remain reproducible.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const upstreamRepository = '/Users/miguel/cvs/pi/pi-mono';
export const upstreamTag = 'v1.5.2';

function completion(child) {
  return new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`Mirror command exited ${code}`)));
  });
}

export async function mirrorV152({ dependencies = [] } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'piswift-durable-v152-'));
  try {
    const names = ['chord', 'durable', 'ai', 'telemetry', 'schema', 'codemode'];
    const archive = spawn('git', ['-C', upstreamRepository, 'archive', upstreamTag,
      ...names.map(name => `packages/${name}/src`)], { stdio: ['ignore', 'pipe', 'inherit'] });
    const extract = spawn('tar', ['-x', '-C', directory], { stdio: ['pipe', 'inherit', 'inherit'] });
    archive.stdout.pipe(extract.stdin);
    await Promise.all([completion(archive), completion(extract)]);
    // Install first: npm prunes links absent from its manifest.
    if (dependencies.length) execFileSync('npm', ['install', '--prefix', directory,
      '--no-audit', '--no-fund', '--ignore-scripts', ...dependencies], { stdio: 'ignore' });
    await mkdir(join(directory, 'node_modules/@earendil-works'), { recursive: true });
    for (const name of names) {
      const manifest = JSON.parse(execFileSync('git', ['-C', upstreamRepository, 'show',
        `${upstreamTag}:packages/${name}/package.json`], { encoding: 'utf8' }));
      const exports = {};
      for (const [key, value] of Object.entries(manifest.exports ?? {})) {
        if (value.source) exports[key] = value.source;
      }
      // pi-ai has no source conditions in its published manifest.
      if (name === 'ai') Object.assign(exports, {
        '.': './src/index.ts', './models': './src/models.ts', './providers/*': './src/providers/*.ts',
        './api/*': './src/api/*.ts', './utils/*': './src/utils/*.ts',
      });
      await writeFile(join(directory, `packages/${name}/package.json`), JSON.stringify({ type: 'module', exports }));
      const packageName = name === 'chord' ? 'chord' : `pi-${name}`;
      await symlink(join(directory, `packages/${name}`), join(directory, 'node_modules/@earendil-works', packageName));
    }
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
