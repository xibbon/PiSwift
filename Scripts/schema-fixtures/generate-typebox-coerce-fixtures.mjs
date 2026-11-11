#!/usr/bin/env node
// Use the pinned upstream tests and install TypeBox only in the temporary extraction.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractTaggedSchema } from './tagged-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const source = extractTaggedSchema(resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono'));
try {
  const temp = resolve(source.base, '../..');
  execFileSync('npm', ['install', '--prefix', temp, '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false', '--save-exact', 'typebox@1.3.27'], { stdio: 'pipe' });
  const installed = JSON.parse(readFileSync(resolve(temp, 'node_modules/typebox/package.json'), 'utf8'));
  if (installed.version !== '1.3.27') throw new Error('Incorrect TypeBox version');
  const shim = resolve(temp, 'node_modules/vitest');
  mkdirSync(shim, { recursive: true });
  writeFileSync(resolve(shim, 'package.json'), JSON.stringify({ type: 'module', exports: './index.mjs' }));
  writeFileSync(resolve(shim, 'index.mjs'), `
import { deepStrictEqual, strictEqual } from 'node:assert';
const groups = [];
export function describe(name, body) { groups.push(name); try { body(); } finally { groups.pop(); } }
export function it(name, body) { globalThis.__fixtureTest = [...groups, name].join(' > '); body(); }
it.skip = () => { globalThis.__fixtureSkippedTests++; };
export function expect(actual) { return { toEqual(expected) { deepStrictEqual(actual, expected); }, toBe(expected) { strictEqual(actual, expected); } }; }
`);
  const rows = [];
  let skippedNonJSON = 0;
  globalThis.__fixtureSkippedTests = 0;
  function jsonForm(value) {
    if (value === undefined || typeof value === 'bigint' || typeof value === 'symbol' || typeof value === 'function') return false;
    if (typeof value === 'number' && !Number.isFinite(value)) return false;
    return value === null || typeof value !== 'object' || Object.values(value).every(jsonForm);
  }
  globalThis.__fixtureRecord = (operation, schema, data, expected) => {
    if (![schema, data, expected].every(jsonForm)) { skippedNonJSON++; return expected; }
    rows.push({ id: `${globalThis.__fixtureTest}/${rows.length}`, operation,
      schema: JSON.parse(JSON.stringify(schema)), data, expected: JSON.stringify(expected) });
    return expected;
  };
  const testPath = resolve(source.base, 'test/coerce-typebox.test.ts');
  let test = readFileSync(testPath, 'utf8');
  const convertLine = 'return new Coercer(new Compiler(schema as object, { formats }, false), schema).convertOnly(value);';
  const checkLine = 'Check: (schema: unknown, value: unknown) => compile(schema as object, { formats }).check(value),';
  if (!test.includes(convertLine) || !test.includes(checkLine)) throw new Error('Upstream test hooks changed');
  test = test.replace(convertLine, `return globalThis.__fixtureRecord('convertOnly', schema, value, new Coercer(new Compiler(schema as object, { formats }, false), schema).convertOnly(value));`)
    .replace(checkLine, `Check: (schema: unknown, value: unknown) => globalThis.__fixtureRecord('check', schema, value, compile(schema as object, { formats }).check(value)),`);
  // Change only the extracted temporary copy. The upstream repository stays read-only.
  writeFileSync(testPath, test);
  await import(pathToFileURL(testPath));
  const header = { tag: 'v1.5.2', commit: source.commit, typebox: installed.version,
    generator: 'Scripts/schema-fixtures/generate-typebox-coerce-fixtures.mjs', cases: rows.length,
    skippedNonJSON, skippedTests: globalThis.__fixtureSkippedTests };
  const bytes = [header, ...rows].map(row => JSON.stringify(row)).join('\n') + '\n';
  if (Buffer.byteLength(bytes) > 600_000) throw new Error('TypeBox fixture exceeds 600 KB');
  const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/coerce-typebox-v1.5.2.jsonl');
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== bytes) throw new Error('Generated TypeBox fixture differs');
  } else writeFileSync(output, bytes);
  console.log(JSON.stringify({ ...header, bytes: Buffer.byteLength(bytes) }));
} finally {
  for (const key of ['__fixtureRecord', '__fixtureTest', '__fixtureSkippedTests']) delete globalThis[key];
  source.dispose();
}
