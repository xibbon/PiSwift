#!/usr/bin/env node
// Record ECMAScript Number(string) and String(number) on Node 22.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const repo = resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono');
const commit = execFileSync('git', ['-C', repo, 'rev-parse', 'v1.5.2^{commit}'], { encoding: 'utf8' }).trim();
const numberInputs = new Set([
  '', ' ', '\t\n\r', '\u00a0', '\ufeff', '\u2000', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000',
  '\u0085', '\u180e', '\u200b', '\uff10', '\u0661', '\u22121', 'Infinity', '+Infinity', '-Infinity', 'infinity',
  'NaN', '+NaN', '-NaN', 'nan', 'Inf', '1_000', '1,000', '0x', '+0x10', '-0x10', '+0b10', '-0o10', '0o8', '0b2',
  '.', '+', '-', '1e', '1e+', '--1', '++1', '1 2', '12n', '-12n', '0x1p2', '1.2.3', '1\0', '\0', '1e309', '-1e309',
  '1e-324', '-1e-324', '5e-324', '-5e-324', '9007199254740993', '18446744073709551615',
]);
const numericForms = ['0','-0','+0','00','01','42','-42','+42','3.5','-3.5','.5','-.5','1.','1e3','1E+3','1e-3','0x10','0XfF','0b10','0B101','0o10','0O77','1e21','1e-7'];
for (const value of numericForms) for (const whitespace of ['', ' ', '\t', '\n', '\u00a0', '\ufeff', '\u2028', '\u2009']) {
  numberInputs.add(whitespace + value + whitespace);
  numberInputs.add(value + 'x' + whitespace);
}
for (let i = 0; i < 40; i++) {
  numberInputs.add(`${i % 2 ? '-' : ''}${i + 1}.1234567890123456789e${i - 20}`);
  numberInputs.add('0x' + 'fedcba9876543210'.repeat(1 + i % 4).slice(0, 1 + i));
}
const buffer = new ArrayBuffer(8);
const view = new DataView(buffer);
function bits(value) { view.setFloat64(0, value, false); return view.getBigUint64(0, false).toString(16).padStart(16, '0'); }
const number = [...numberInputs].map(input => {
  const value = Number(input);
  return { input, ...(Number.isNaN(value) ? { nan: true } : { bits: bits(value) }) };
});
const stringInputs = new Map();
function add(value) { stringInputs.set(bits(value), { bits: bits(value), expected: String(value) }); }
for (const value of [0, -0, NaN, Infinity, -Infinity, Number.MAX_VALUE, Number.MIN_VALUE, Number.MAX_SAFE_INTEGER,
  Number.MIN_SAFE_INTEGER, 1e20, 1e21, 1e-6, 1e-7, 0.1, 0.10000000000000002, 1.2345678901234567]) add(value);
for (let exponent = -323; exponent <= 308; exponent += 7) for (const coefficient of [1, -1, 1.2345678901234567, 9.999999999999998]) add(coefficient * 10 ** exponent);
// Include adjacent binary64 values around the decimal notation boundaries.
for (const value of [1e-7, 1e-6, 1e20, 1e21, 1, 0.1, 9007199254740992]) {
  const base = BigInt('0x' + bits(value));
  for (let offset = -6n; offset <= 6n; offset++) { view.setBigUint64(0, base + offset, false); add(view.getFloat64(0, false)); }
}
const string = [...stringInputs.values()];
const bigintInputs = new Set([...numberInputs, '0', '-0', '+0', '0x10', '0b10', '0o10',
  '9007199254740991', '9007199254740992', '9007199254740993', '18446744073709551615']);
const bigint = [...bigintInputs].map(input => {
  try { return { input, expected: BigInt(input).toString() }; }
  catch { return { input, invalid: true }; }
});
const trim = [...numberInputs].map(input => ({ input, expected: input.trim() }));
const numeric = string.map(row => {
  view.setBigUint64(0, BigInt('0x' + row.bits), false);
  const n = view.getFloat64(0, false);
  return { bits: row.bits, trunc: bits(Math.trunc(n)), integer: Number.isInteger(n), safeInteger: Number.isSafeInteger(n) };
});
const strictValues = [null, true, false, 0, 1, -1, 3.5, '', '0', '1', 'true', 'null'];
const strict = strictValues.flatMap(a => strictValues.map(b => ({ a, b, expected: a === b })));
if (number.length < 200 || string.length < 200) throw new Error('Expected at least 200 inputs for each helper');
const fixture = { tag: 'v1.5.2', commit, nodeMajor: Number(process.versions.node.split('.')[0]),
  generator: 'Scripts/schema-fixtures/generate-js-value-fixtures.mjs', number, string, bigint, trim, numeric, strict };
if (fixture.nodeMajor !== 22) throw new Error('Use Node 22 for this fixture');
const bytes = JSON.stringify(fixture) + '\n';
const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/js-values-v1.5.2.json');
if (process.argv.includes('--check')) {
  if (readFileSync(output, 'utf8') !== bytes) throw new Error('Generated JS value fixture differs');
} else writeFileSync(output, bytes);
console.log(`${number.length} number inputs, ${string.length} string inputs, ${Buffer.byteLength(bytes)} bytes`);
