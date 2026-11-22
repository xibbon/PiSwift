// Migrate the frozen v1.5.2 task inputs and checkpoints with the v1.6.0 definitions.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirrorV160 } from './mirror-v160.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const frozenPath = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/migration-records-v152.json', import.meta.url));
const target = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/task-migration-oracle-v160.json', import.meta.url));
const frozen = JSON.parse(await readFile(frozenPath, 'utf8'));
if (frozen.tag !== 'v1.5.2') throw new Error('Frozen task migration tag differs');
const source = await mirrorV160({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
try {
  const { ToolTask } = await source.import('packages/durable/src/harness/tool.ts');
  const { GenerationTask } = await source.import('packages/durable/src/harness/generation.ts');
  const definitions = new Map([['pi.tool', ToolTask.definition], ['pi.generation', GenerationTask.definition]]);
  const migrations = frozen.taskMigrations.map(item => {
    const raw = frozen.reads.find(read => read.method === 'task' && read.arguments[0] === item.recordId)?.result;
    if (!raw) throw new Error(`Missing frozen task ${item.recordId}`);
    const definition = definitions.get(item.kind);
    if (!definition) throw new Error(`Unknown task ${item.kind}`);
    return { kind: item.kind, fromVersion: item.fromVersion, toVersion: definition.version,
      recordId: item.recordId, result: definition.migrate(raw.input, raw.state.checkpoint, item.fromVersion) };
  });
  const text = JSON.stringify({ sourceTag: 'v1.5.2', targetTag: 'v1.6.0', migrations }) + '\n';
  if (check) {
    if (await readFile(target, 'utf8') !== text) throw new Error('v1.6.0 task migration oracle differs');
  } else await writeFile(target, text);
  console.log(`v1.6.0 task migration oracle ${check ? 'matches' : 'written'}: ${migrations.length} frozen inputs.`);
} finally { await source.close(); }
