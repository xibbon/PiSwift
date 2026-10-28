// Run the unmodified v1.4.0 examples with their faux providers and no network.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamRepository, upstreamTag } from './mirror.mjs';

// npm may use its local cache only. The examples use no remote model provider.
process.env.npm_config_offline = 'true';
const source = await mirror({ dependencies: ['typebox@1.3.27'] });
try {
  // Add the real package subpath exports needed by the example imports.
  const manifestPath = join(source.directory, 'packages/ai/package.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  manifest.exports['./models'] = './src/models.ts';
  manifest.exports['./providers/faux'] = './src/providers/faux.ts';
  await writeFile(manifestPath, JSON.stringify(manifest));
  const directory = join(source.directory, 'packages/durable/test/examples');
  await mkdir(directory, { recursive: true });
  const capturePath = join(source.directory, 'capture.mjs');
  await writeFile(capturePath, `import { writeFileSync } from 'node:fs';
const calls = [];
const log = console.log;
console.log = (...args) => { calls.push(JSON.parse(JSON.stringify(args))); log(...args); };
process.on('exit', () => writeFileSync(process.env.PI_DURABLE_EXAMPLE_TRACE, JSON.stringify(calls)));
`);
  const examples = [];
  for (const name of ['09-context', '20-inbox', '25-compaction']) {
    const path = `packages/durable/test/examples/${name}.ts`;
    const contents = execFileSync('git', ['-C', upstreamRepository, 'show', `${upstreamTag}:${path}`], { encoding: 'utf8' });
    const target = join(directory, `${name}.ts`);
    await writeFile(target, contents);
    const trace = join(source.directory, `${name}.json`);
    const run = spawnSync(process.execPath, ['--conditions=source', '--experimental-strip-types', '--import', capturePath, target], {
      cwd: join(source.directory, 'packages/durable'), encoding: 'utf8', timeout: 120_000,
      env: { ...process.env, PI_DURABLE_EXAMPLE_TRACE: trace },
    });
    process.stdout.write(`Example ${name}, exit ${run.status}:\n${run.stdout ?? ''}`);
    if (run.stderr) process.stderr.write(run.stderr);
    if (run.error || run.status !== 0) throw run.error ?? new Error(`Example ${name} exited ${run.status}`);
    examples.push({ name, source: path, stdout: run.stdout, calls: JSON.parse(await readFile(trace, 'utf8')) });
  }
  const result = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'unmodified tagged examples and library source in mirror.mjs',
    dependencies: 'typebox@1.3.27 from the offline npm cache',
    capture: 'console.log argument snapshots and original stdout; example code and setup are unchanged',
  }, examples }, null, 2) + '\n';
  const output = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/w5-examples-v140.json', import.meta.url));
  if (process.argv.includes('--check')) {
    if (await readFile(output, 'utf8') !== result) throw new Error('W5 example evidence differs');
  } else await writeFile(output, result);
  console.log(`W5 example evidence ${process.argv.includes('--check') ? 'matches' : 'written'}: ${examples.length} examples.`);
} finally {
  await source.close();
}
