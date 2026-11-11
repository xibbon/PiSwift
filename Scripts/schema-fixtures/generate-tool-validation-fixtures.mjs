#!/usr/bin/env node
// Tag v1.5.2. Ordered vectors keep each argument object's own key order.
// Unordered vectors have sorted keys and exercise the Swift dictionary fallback.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, symlinkSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractTaggedSchema } from './tagged-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const repo = resolve(root, '../pi-mono');
const source = extractTaggedSchema(repo);
const temp = mkdtempSync(join(tmpdir(), 'pi-tool-validation-'));
try {
  execFileSync('npm', ['install', '--prefix', temp, '--ignore-scripts', '--no-audit', '--no-fund',
    '--package-lock=false', '--save-exact', 'typebox@1.3.27'], { stdio: 'pipe' });
  writeFileSync(join(temp, 'package.json'), JSON.stringify({ type: 'module' }));
  const ai = join(temp, 'packages/ai/src/utils');
  mkdirSync(ai, { recursive: true });
  mkdirSync(join(temp, 'node_modules/@earendil-works'), { recursive: true });
  const schema = join(temp, 'packages/schema');
  symlinkSync(source.base, schema);
  symlinkSync(schema, join(temp, 'node_modules/@earendil-works/pi-schema'));
  writeFileSync(join(schema, 'package.json'), JSON.stringify({ type: 'module', exports: { '.': './src/index.ts', './formats': './src/formats/index.ts' } }));
  const validation = execFileSync('git', ['-C', repo, 'show', 'v1.5.2:packages/ai/src/utils/validation.ts'], { encoding: 'utf8' });
  writeFileSync(join(ai, 'validation.ts'), validation);
  const { validateToolArguments } = await import(pathToFileURL(join(ai, 'validation.ts')));
  const vectors = JSON.parse(readFileSync(join(root, 'Scripts/schema-fixtures/tool-validation-vectors.json'), 'utf8'));
  if (vectors.length < 300 || new Set(vectors.map(x => x.id)).size !== vectors.length) throw Error('Need 300 unique vectors');
  const rows = vectors.map(vector => {
    const args = vector.arguments;
    const tool = { name: vector.name ?? 'echo', description: '', parameters: vector.schema };
    const call = { type: 'toolCall', id: vector.id, name: vector.name ?? 'echo', arguments: args, argumentsError: vector.argumentsError };
    try { return { ...vector, argumentsJSON: JSON.stringify(args), result: JSON.stringify(validateToolArguments(tool, call)) }; }
    catch (error) { return { ...vector, argumentsJSON: JSON.stringify(args), error: error.message }; }
  });
  // Run the named upstream reviewer probes in a temporary copy with a minimal Vitest shim.
  const testDir = join(temp, 'packages/ai/test');
  mkdirSync(testDir, { recursive: true });
  const vitestDir = join(temp, 'node_modules/vitest');
  mkdirSync(vitestDir, { recursive: true });
  writeFileSync(join(vitestDir, 'package.json'), JSON.stringify({ type: 'module', exports: './index.mjs' }));
  writeFileSync(join(vitestDir, 'index.mjs'), `
import { strictEqual } from 'node:assert';
export function describe(_name, body) { body(); }
export function it(name, body) { if (!name.startsWith('accepts the last member of a 10,000-value enum') &&
  !name.startsWith('keeps the validator of a schema object')) { globalThis.__probeName = name; body(); } }
export function expect(actual) { return { toBe(expected) { strictEqual(actual, expected); } }; }
`);
  const probeSource = execFileSync('git', ['-C', repo, 'show', 'v1.5.2:packages/ai/test/validation-probes.test.ts'], { encoding: 'utf8' });
  const probePattern = /function outcome\(name: string, schema: object, args: unknown\): string \{[\s\S]*?\n\}\n\ntype Case/;
  if (!probePattern.test(probeSource)) throw Error('Upstream probe hook changed');
  writeFileSync(join(testDir, 'validation-probes.test.ts'), probeSource.replace(probePattern,
    'function outcome(name: string, schema: object, args: unknown): string { return globalThis.__probeOutcome(name, schema, args); }\n\ntype Case'));
  const jsonSafe = value => value === null || (typeof value !== 'undefined' && typeof value !== 'function'
    && typeof value !== 'bigint' && typeof value !== 'symbol' && (typeof value !== 'object'
      || Object.values(value).every(jsonSafe)));
  globalThis.__probeOutcome = (name, schema, args) => {
    const call = { type: 'toolCall', id: 'probe', name, arguments: args };
    let result, error, outcome;
    try {
      result = validateToolArguments({ name, description: '', parameters: schema }, call);
      outcome = `ok ${JSON.stringify(result, (_key, value) => typeof value === 'bigint' ? `${value}n` : value)}`;
    } catch (caught) {
      error = caught.message;
      outcome = error.startsWith('Validation failed') ? `REJECT ${error.split('\n')[1]?.trim()}` : `THROW ${error.split('\n')[0]}`;
    }
    const inputText = JSON.stringify(args);
    const hasSurrogateEscape = /\\u[dD][89a-fA-F][0-9a-fA-F]{2}/.test(inputText);
    if (jsonSafe(schema) && jsonSafe(args) && (error || jsonSafe(result)) &&
        JSON.stringify(schema).length < 15_000 && !hasSurrogateEscape) {
      const id = `upstream-probe/${globalThis.__probeName}/${rows.length}`;
      rows.push({ id, name, schema: JSON.parse(JSON.stringify(schema)), arguments: args,
        argumentsJSON: JSON.stringify(args), ...(error ? { error } : { result: JSON.stringify(result) }) });
    }
    return outcome;
  };
  await import(pathToFileURL(join(testDir, 'validation-probes.test.ts')));
  delete globalThis.__probeOutcome;
  delete globalThis.__probeName;
  const header = { tag: 'v1.5.2', commit: source.commit, generator: 'generate-tool-validation-fixtures.mjs', cases: rows.length,
    argumentOrder: 'source order; no-order vectors are already UTF-16 sorted' };
  const text = [header, ...rows].map(JSON.stringify).join('\n') + '\n';
  if (Buffer.byteLength(text) > 400_000) throw Error('Fixture exceeds 400 KB');
  const output = join(root, 'Tests/PiSwiftAITests/Resources/tool-validation-v1.5.2.jsonl');
  mkdirSync(dirname(output), { recursive: true });
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== text) throw Error('Fixture differs');
  } else writeFileSync(output, text);
  console.log(`${rows.length} vectors, ${Buffer.byteLength(text)} bytes`);
} finally {
  source.dispose();
  rmSync(temp, { recursive: true, force: true });
}
