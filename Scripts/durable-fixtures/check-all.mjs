// Run every durable fixture generator and shared-file export check in sequence.
// A failed command stops the entry point. No checked-in fixture is rewritten.
import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const directory = fileURLToPath(new URL('./', import.meta.url));
const names = (await readdir(directory)).filter(name => name.startsWith('generate-') && name.endsWith('.mjs')).sort();
names.push('run-w5-examples.mjs');
for (const name of names) {
  const path = fileURLToPath(new URL(name, import.meta.url));
  if (!(await readFile(path, 'utf8')).includes("'--check'")) throw new Error(`${name} has no check mode`);
  console.log(`Checking ${name}`);
  const result = spawnSync(process.execPath, ['--experimental-strip-types', path, '--check'], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
const checks = (await readdir(directory)).filter(name => /^check-.*-exports\.mjs$/.test(name)).sort();
for (const name of checks) {
  console.log(`Checking ${name}`);
  const result = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(new URL(name, import.meta.url))], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
console.log('Checking SharedFileCloseoutTests (all backends, both directions)');
const matrix = spawnSync('swift', ['test', '--skip-build', '--filter', 'SharedFileCloseoutTests'], {
  cwd: fileURLToPath(new URL('../../', import.meta.url)), stdio: 'inherit',
});
if (matrix.error) throw matrix.error;
if (matrix.status !== 0) process.exit(matrix.status ?? 1);
console.log(`Durable closeout checks passed: ${names.length} generators in --check mode, ${checks.length} export checks, shared-file matrix.`);
