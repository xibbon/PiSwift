// Replay the existing structured-output inputs against pi-schema at the v1.5.2 tag.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const inputURL = new URL('../../Tests/PiSwiftDurableTests/Fixtures/structured-tool-schema-v130.json', import.meta.url);
const outputURL = new URL('../../Tests/PiSwiftDurableTests/Fixtures/structured-tool-schema-v152.json', import.meta.url);
const source = await mirror({ tag: 'v1.5.2' });
try {
  const { compile } = await source.import('packages/schema/src/index.ts');
  const { formats } = await source.import('packages/schema/src/formats/index.ts');
  const previous = JSON.parse(await readFile(inputURL, 'utf8'));
  const cases = previous.cases.map(({ name, schema, value }) => {
    try {
      const validator = compile(schema, { formats, unresolvedRefs: 'reject' });
      const accepted = validator.check(value);
      const first = accepted ? undefined : validator.errors(value)[0];
      const path = first?.path?.slice(1).split('/').map(x => x.replaceAll('~1', '/').replaceAll('~0', '~')).join('.') || 'root';
      return { name, schema, value, accepted, error: accepted ? null : `${path}: ${first?.message ?? 'invalid'}` };
    } catch (error) { return { name, schema, value, accepted: false, error: String(error.message ?? error) }; }
  });
  const output = JSON.stringify({ tag: 'v1.5.2', source: 'packages/schema/src, durable/src/harness/tool.ts:778-801', cases }, null, 2) + '\n';
  if (process.argv.includes('--check')) {
    if (await readFile(outputURL, 'utf8') !== output) throw new Error('v1.5.2 structured output fixture differs');
  } else await writeFile(outputURL, output);
  console.log(`D8 structured fixture ${process.argv.includes('--check') ? 'matches' : 'written'}: ${cases.length} cases, ${Buffer.byteLength(output)} bytes`);
} finally { await source.close(); }
