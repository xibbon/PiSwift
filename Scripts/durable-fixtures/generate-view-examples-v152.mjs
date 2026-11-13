// Run the unmodified tagged transcript and Durable view examples.
// Keep stdout and console.log argument snapshots for line-by-line Swift checks.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirrorV152, upstreamRepository, upstreamTag } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
process.env.npm_config_offline = 'true';
const source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'], mutable: true });
try {
  const directory = join(source.directory, 'packages/durable/test/examples');
  await mkdir(directory, { recursive: true });
  const capturePath = join(source.directory, 'capture-view-examples.mjs');
  await writeFile(capturePath, `import { writeFileSync } from 'node:fs';
const calls = [];
const log = console.log;
console.log = (...args) => { calls.push(JSON.parse(JSON.stringify(args))); log(...args); };
process.on('exit', () => writeFileSync(process.env.PI_DURABLE_EXAMPLE_TRACE, JSON.stringify(calls)));
`);
  const examples = [];
  for (const name of ['31-transcript', '36-durable-views']) {
    const path = `packages/durable/test/examples/${name}.ts`;
    const contents = execFileSync('git', ['-C', upstreamRepository, 'show', `${upstreamTag}:${path}`], { encoding: 'utf8' });
    const target = join(directory, `${name}.ts`);
    await writeFile(target, contents);
    const trace = join(source.directory, `${name}.json`);
    const run = spawnSync(process.execPath, ['--conditions=source', '--experimental-strip-types', '--import', capturePath, target], {
      cwd: join(source.directory, 'packages/durable'), encoding: 'utf8', timeout: 120_000,
      env: { ...process.env, PI_DURABLE_EXAMPLE_TRACE: trace },
    });
    if (run.error || run.status !== 0) {
      if (run.stderr) process.stderr.write(run.stderr);
      throw run.error ?? new Error(`Example ${name} exited ${run.status}`);
    }
    const calls = JSON.parse(await readFile(trace, 'utf8'));
    examples.push({ name, source: path, stdout: run.stdout, lines: run.stdout.trimEnd().split('\n'), calls });
    console.log(`Example ${name}: ${calls.length} console calls`);
  }
  const output = JSON.stringify({
    tag: upstreamTag,
    provenance: {
      source: 'Unmodified tagged examples and tagged library source from mirror-v152.mjs',
      dependencies: 'typebox@1.3.27, partial-json@0.1.7, diff@8.0.4 from the offline npm cache',
      capture: 'Original stdout and JSON snapshots of console.log arguments; no example edits',
    },
    swiftLimitations: {
      '36-durable-views': 'PiSwiftChord has no local, defineFacet, createHost, openStore, sqliteBackend, self.open, self.follow, self.derive, or member watch API. PiSwiftDurable has no StoreStorage adapter. The Swift test checks Durable observer values and commit counts only; it does not claim host member, derive batching, host close, or host-store adoption parity.',
    },
    examples,
  }, null, 2) + '\n';
  const path = new URL('view-examples-v152.json', import.meta.url);
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== output) throw new Error('View example output differs');
  } else await writeFile(path, output);
  console.log(`View example evidence ${process.argv.includes('--check') ? 'matches' : 'written'}: ${Buffer.byteLength(output)} bytes`);
} finally {
  await source.close();
}
