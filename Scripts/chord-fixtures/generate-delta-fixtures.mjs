import { assertFixtureBudget } from './fixture-budget.mjs';
// Node 22 reference cases for the PiSwiftChord delta tests.
import { readFileSync, writeFileSync, unlinkSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const result = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

// Write one case per line. Keep each case and its nested arrays compact.
function fixtureJSON(value) {
  if (Array.isArray(value)) return '[' + (value.length ? '\n' + value.map(entry => JSON.stringify(entry)).join(',\n') + '\n' : '') + ']';
  return '{' + Object.entries(value).map(([key, entry]) => JSON.stringify(key) + ':' + (entry && typeof entry === 'object' ? fixtureJSON(entry) : JSON.stringify(entry))).join(',') + '}';
}

// Digest only expected output. Inputs remain available for replay.
function expectedText(text) {
  const length = Buffer.byteLength(text, 'utf8');
  return length > 2048 ? { sha256: createHash('sha256').update(text, 'utf8').digest('hex'), length } : text;
}

const fixturePath = fileURLToPath(new URL('../../Tests/PiSwiftChordTests/Fixtures/overlap-fixtures.json', import.meta.url));

// Import the full tag source. No copied algorithm is an oracle.
const temporary = mkdtempSync(join(tmpdir(), 'chord-delta-'));
try {
const archive = execFileSync('git', ['-C', '/Users/miguel/cvs/pi/pi-mono', 'archive', 'v1.4.0', 'packages/chord/src'], { maxBuffer: 16 * 1024 * 1024 });
execFileSync('tar', ['-x', '-C', temporary], { input: archive });
const { overlap, apply: applyOps, applyImmutable } = await import(pathToFileURL(join(temporary, 'packages/chord/src/delta/index.ts')).href);
const isObj = value => value !== null && typeof value === 'object';
const RESERVED_SEGMENTS = new Set(['__proto__', 'constructor', 'prototype']);
let seed = 0x3c71a5d9;
function randomWord() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return seed >>> 0;
}
const integer = limit => randomWord() % limit;
const pick = values => values[integer(values.length)];
const clone = value => value === undefined ? undefined : structuredClone(value);
const scans = [0, 1, 7, 64, 65536];
const probes = [0, 1, 2, 7, 64];
const candidateLimits = [0, 1, 2, 8, 16];
const overlapCases = [];
function addOverlap(name, a, b, scan, probe = 64, maxCandidates = 8) {
  // Input strings contain only complete Unicode scalars. The oracle itself
  // uses UTF-16 offsets, including offsets inside supplementary characters.
  if (!a.isWellFormed() || !b.isWellFormed()) throw new Error('Invalid UTF-16 input');
  overlapCases.push({ name, a, b, scan, probe, maxCandidates, expected: overlap(a, b, scan, probe, maxCandidates) });
}
function randomString(alphabet, length) {
  return Array.from({ length }, () => pick(alphabet)).join('');
}
const alphabets = [['a', 'b'], ['a', 'b', 'c', '\n'], ['😀', '🦀', 'a', 'e', '\u0301'], ['é', 'e', '\u0301', 'x']];
for (let i = 0; i < 2200; i++) {
  const alphabet = alphabets[i % alphabets.length];
  const a = randomString(alphabet, integer(140));
  // Array.from slices scalars and never makes an unpaired surrogate input.
  const scalars = Array.from(a);
  const prefix = i % 3 === 0 ? scalars.slice(integer(scalars.length + 1)).join('') : '';
  const b = prefix + randomString(alphabet, integer(100));
  addOverlap(`random-${i}`, a, b, scans[i % scans.length], pick(probes), pick(candidateLimits));
}
for (const line of ['build succeeded\n', 'aaaab\n', '😀 e\u0301\n', 'error: x\n']) {
  for (const scan of scans) {
    for (const probe of [1, 7, 64]) {
      for (const maxCandidates of [1, 8, 32]) {
        addOverlap('repetitive-log', line.repeat(100), line.repeat(20) + 'next\n', scan, probe, maxCandidates);
      }
    }
  }
}
addOverlap('give-up', 'a'.repeat(100) + 'b', 'a'.repeat(50) + 'bX', 65536);
addOverlap('UTF-16-overlap', 'head😀e\u0301', '😀e\u0301tail', 65536);
addOverlap('bounded-tail', 'abcdef', 'defghi', 2);
addOverlap('full-tail', 'abcdef', 'defghi', 3);
addOverlap('empty-a', '', 'a', 64);
addOverlap('empty-b', 'a', '', 64);
addOverlap('negative-scan', 'abcdef', 'defghi', -1);
addOverlap('negative-probe', 'abcdef', 'defghi', 64, -1);
addOverlap('negative-probe-past-length', 'abcdef', 'defghi', 64, -100);
addOverlap('negative-candidate-limit', 'abcdef', 'defghi', 64, 64, -1);


const applyCases = [];
function addApply(name, initial, ops) {
  const entry = { name, initialText: initial === undefined ? null : JSON.stringify(initial), ops };
  try {
    const result = applyOps(clone(initial), clone(ops));
    entry.resultText = result === undefined ? null : expectedText(JSON.stringify(result));
  } catch (error) {
    entry.errorKind = error.name;
    entry.errorText = error.message;
  }
  applyCases.push(entry);
}
const ordinaryKeys = ['b', '10', 'a', '9', '0', '01', '-1', 'é', 'e\u0301', '😀'];
function randomJSON(depth = 0) {
  const kind = integer(depth >= 3 ? 4 : 6);
  if (kind === 0) return null;
  if (kind === 1) return integer(2) === 0;
  if (kind === 2) return integer(200) - 100;
  if (kind === 3) return randomString(pick(alphabets), integer(10));
  if (kind === 4) return Array.from({ length: integer(6) }, () => randomJSON(depth + 1));
  const result = {};
  for (let i = 0, count = integer(8); i < count; i++) {
    Object.defineProperty(result, pick(ordinaryKeys), { value: randomJSON(depth + 1), writable: true, enumerable: true, configurable: true });
  }
  return result;
}
function nodes(root) {
  const result = [];
  function walk(value, path) {
    result.push({ value, path });
    if (Array.isArray(value)) value.forEach((child, index) => walk(child, [...path, index]));
    else if (isObj(value)) {
      for (const key of Object.keys(value)) {
        if (RESERVED_SEGMENTS.has(key)) continue;
        // JavaScript converts an object index segment to its decimal key.
        const segment = /^(0|[1-9][0-9]*)$/.test(key) && integer(2) === 0 ? Number(key) : key;
        walk(value[key], [...path, segment]);
      }
    }
  }
  walk(root, []);
  return result;
}
function validOp(root) {
  if (root === undefined || integer(12) === 0) return ['r', randomJSON()];
  const available = nodes(root);
  const arrays = available.filter(entry => Array.isArray(entry.value));
  const containers = available.filter(entry => isObj(entry.value));
  const strings = available.filter(entry => typeof entry.value === 'string' && entry.path.length !== 0);
  const verbs = ['r'];
  if (arrays.length !== 0) verbs.push('p', 'm');
  if (containers.length !== 0) verbs.push('s', 'd');
  if (strings.length !== 0) verbs.push('a', 't');
  const verb = pick(verbs);
  if (verb === 'r') return ['r', randomJSON()];
  if (verb === 'p') {
    const { value, path } = pick(arrays);
    return ['p', path, integer(value.length + 8), integer(value.length + 8), Array.from({ length: integer(5) }, () => randomJSON())];
  }
  if (verb === 'm') {
    const { value, path } = pick(arrays);
    const permutation = Array.from({ length: value.length }, (_, index) => index);
    for (let i = permutation.length - 1; i > 0; i--) {
      const j = integer(i + 1);
      [permutation[i], permutation[j]] = [permutation[j], permutation[i]];
    }
    return ['m', path, permutation];
  }
  if (verb === 'a' || verb === 't') {
    const { value, path } = pick(strings);
    if (verb === 'a') return ['a', path, randomString(pick(alphabets), integer(10))];
    const scalars = Array.from(value);
    const count = integer(scalars.length + 3);
    const units = count <= scalars.length ? scalars.slice(0, count).join('').length : value.length + count;
    return ['t', path, units];
  }
  let chosen = pick(containers);
  // Empty arrays cannot support d. Use s if no other container is present.
  if (verb === 'd' && Array.isArray(chosen.value) && chosen.value.length === 0) {
    const removable = containers.filter(entry => !Array.isArray(entry.value) || entry.value.length !== 0);
    if (removable.length === 0) return ['s', [...chosen.path, 0], randomJSON()];
    chosen = pick(removable);
  }
  const { value, path } = chosen;
  const key = Array.isArray(value) ? integer(value.length + (verb === 's' ? 1 : 0)) : pick([...Object.keys(value).filter(key => !RESERVED_SEGMENTS.has(key)), 'new', ...ordinaryKeys]);
  return verb === 's' ? ['s', [...path, key], randomJSON()] : ['d', [...path, key]];
}
for (let i = 0; i < 800; i++) {
  const initial = i % 9 === 0 ? undefined : randomJSON();
  let current = clone(initial);
  const ops = [];
  for (let j = 0, count = integer(20) + 1; j < count; j++) {
    const op = validOp(current);
    ops.push(op);
    current = applyOps(current, clone([op]));
  }
  addApply(`random-valid-${i}`, initial, ops);
}
addApply('undefined-no-ops', undefined, []);
addApply('null-no-ops', null, []);
addApply('root-splice-clamps', [1, 2, 3], [['p', [], 10, 5, [4, 5]]]);
addApply('root-splice-large-chunks', [0], [['p', [], 50, 9, Array.from({ length: 20003 }, (_, i) => i + 1)]]);
addApply('object-number-index', { '0': { '1': 'a' } }, [['a', [0, 1], '😀'], ['s', [0, 2], true]]);
addApply('large-exact-number-object-key', {}, [['s', [1000000000000000256], 'a'], ['a', [1000000000000000256], 'b']]);
addApply('reserved-value-keys', {}, [['s', ['safe'], JSON.parse('{"__proto__":{"safe":true},"constructor":1,"prototype":2}')]]);
addApply('key-order-on-delete-reinsert', { b: 1, '10': 2, a: 3, '9': 4 }, [['d', ['b']], ['s', ['b'], 5], ['s', [0], 6], ['s', ['01'], 7]]);
addApply('trim-scalar-boundaries', { s: '😀e\u0301🦀' }, [['t', ['s'], 2], ['a', ['s'], '😀'], ['t', ['s'], 2]]);
addApply('replacement-then-write', null, [['r', { nested: { xs: [1, 2, 3] } }], ['s', ['nested', 'xs', 1], 9]]);
const malformedOps = [null, [], ['r'], ['s', ['a']], ['d'], ['a', ['a'], 0], ['t', ['a'], -1], ['t', ['a'], 1.5], ['p', [], 1, 0], ['p', [], -1, 0, []], ['p', [], 0, -1, []], ['p', [], 0, 0, null], ['m', [], null], ['m', [], [0, 0]], ['m', [], [1]], ['x', []], ['s', [], 1], ['d', []], ['a', [], 'a'], ['t', [], 1], ['s', 0, 1], ['s', ['constructor'], 1], ['s', ['__proto__', 'x'], 1], ['s', ['prototype'], 1], ['s', [-1], 1], ['s', [1.5], 1], ['s', [null], 1], ['s', [true], 1], ['s', [{}], 1], ['#', 0, []]];
for (let i = 0; i < malformedOps.length; i++) addApply(`malformed-${i}`, {}, [['s', ['prefix'], i], malformedOps[i]]);
for (let i = 0; i < 120; i++) {
  const initial = { xs: [randomJSON(), randomJSON()], child: { text: '😀abc' }, scalar: 1 };
  const invalid = pick([
    ['d', ['xs', 2]], ['d', ['xs', 3]], ['s', ['xs', 3], randomJSON()],
    ['a', ['xs', 3], 'x'], ['t', ['xs', 3], 0], ['s', ['xs', '0'], 1],
    ['s', ['missing', 'x'], 1], ['s', ['scalar', 'x'], 1],
    ['p', ['missing'], 0, 1, []], ['m', ['xs'], [0]], ['a', ['scalar'], 'x'],
    ['t', ['missing'], 0], ['p', ['scalar'], 0, 0, []], ['s', ['xs', '0', 'x'], 1],
  ]);
  addApply(`random-invalid-${i}`, initial, [['s', ['prefix'], i], invalid]);
}
addApply('delete-at-length', [1, 2, 3], [['d', [3]]]);
addApply('delete-after-length', [1, 2, 3], [['d', [4]]]);
addApply('segment-object-blocks-string-conversion', {}, [['s', [{ toString: 1 }], 1]]);
addApply('segment-array-blocks-string-conversion', {}, [['s', [[{ toString: null }]], 1]]);
addApply('verb-object-blocks-string-conversion', {}, [[{ toString: 1 }]]);
addApply('verb-object-valueOf-keeps-default-string', {}, [[{ valueOf: 1 }]]);


const additions = [];
function addImmutable(name, initial, ops) {
  const entry = { name, initialText: JSON.stringify(initial), ops };
  try { entry.resultText = expectedText(JSON.stringify(applyImmutable(initial, ops))); }
  catch (error) { entry.errorKind = error.name; entry.errorText = error.message; }
  additions.push(entry);
}
addImmutable('nested-two-appends', { log: { entries: Array.from({ length: 1000 }, (_, index) => ({ index })), meta: { count: 1000 } }, other: { value: 1 } }, [
  ['p', ['log', 'entries'], 1000, 0, [{ index: 1000 }]], ['p', ['log', 'entries'], 1001, 0, [{ index: 1001 }]],
]);
addImmutable('root-append', [1,2], [['p', [], 2, 0, [3]]]);
addImmutable('root-array-item-append', [1,2], [['p', [], 2, 0, [[3,4]]]]);
addImmutable('non-append-general-path', [1,2], [['p', [], 1, 0, [9]]]);
for (const [index, path] of [['values','missing'], ['missing'], ['values',0], ['__proto__'], ['list','x'], ['text'], ['list',-1], ['list',1.5], ['list',0,'constructor']].entries()) {
  addImmutable(`invalid-append-path-${index}`, { values: [], list: [[1]], text: 'a' }, [['p', path, 0, 0, []]]);
}
const additionsPath = fileURLToPath(new URL('../../Tests/PiSwiftChordTests/Fixtures/delta-v140-fixtures.json', import.meta.url));
const additionsOutput = fixtureJSON({ upstream: 'pi-mono v1.4.0', source: 'packages/chord/test/delta-apply-immutable.test.ts', frozenFixture: 'delta-v130-fixtures', payload: 'apply', count: additions.length, sha256: createHash('sha256').update(JSON.stringify(additions)).digest('hex') }) + '\n';

const output = fixtureJSON({ upstream: 'pi-mono v1.4.0', seed: '0x3c71a5d9', overlap: overlapCases, apply: applyCases }) + '\n';
assertFixtureBudget({ 'overlap-fixtures.json': output, 'delta-v140-fixtures.json': additionsOutput });
if (process.argv.includes('--check')) {
  if (readFileSync(additionsPath, 'utf8') !== additionsOutput) throw new Error('v1.4 delta fixtures differ');
} else writeFileSync(additionsPath, additionsOutput);

const counts = `${overlapCases.length} overlap cases, ${applyCases.length} apply cases (${applyCases.filter(entry => entry.errorKind).length} invalid)`;
if (process.argv.includes('--check')) {
  const temporaryPath = fileURLToPath(new URL(`.delta-fixtures-${process.pid}.tmp`, import.meta.url));
  try {
    writeFileSync(temporaryPath, output);
    if (readFileSync(temporaryPath, 'utf8') !== readFileSync(fixturePath, 'utf8')) {
      console.error('Delta fixture differs from the Node reference.');
      process.exitCode = 1;
    } else console.log(`Delta fixture check passed: ${counts}.`);
  } finally { unlinkSync(temporaryPath); }
} else {
  writeFileSync(fixturePath, output);
  console.log(`Wrote ${counts}.`);
}

} finally { rmSync(temporary, { recursive: true, force: true }); }
