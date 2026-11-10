#!/usr/bin/env node
// Evaluate format strings with the code at the local pi-mono v1.5.2 tag.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractTaggedSchema } from './tagged-schema.mjs';

// Node 22.23.1's optimized URL.canParse changes its answer for some Unicode
// hosts after repeated calls. new URL applies the same validity algorithm and
// stays stable. The tagged checks still call URL.canParse through this shim.
URL.canParse = (value, base) => {
  try { new URL(value, base); return true; }
  catch { return false; }
};

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const repo = resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono');
const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/formats-v1.5.2.jsonl');
const fuzzOutput = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/formats-fuzz-v1.5.2.jsonl');
const input = JSON.parse(readFileSync(resolve(root, 'Scripts/schema-fixtures/extra-format-vectors.json'), 'utf8'));

// xorshift32 gives a repeatable stream on every Node version. No Math.random is used.
const fuzzSeed = 0x05eed152;
let randomState = fuzzSeed;
function nextRandom() {
  randomState ^= randomState << 13;
  randomState ^= randomState >>> 17;
  randomState ^= randomState << 5;
  return randomState >>> 0;
}
function pick(values) { return values[nextRandom() % values.length]; }
function chance(divisor) { return nextRandom() % divisor === 0; }

const mutationChars = ['a', 'Z', '0', '9', '.', ':', '/', '?', '#', '%', '@', '[', ']', '{', '}',
  '-', '_', '\\', ' ', '\t', '\n', '\r', '\u0000', '٣', '５', 'K', 'ſ', '\u0301', '\u200d',
  'é', '😀', '\u2028', '\uD800'];
function hasLoneSurrogate(value) {
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i === value.length || value.charCodeAt(i) < 0xdc00 || value.charCodeAt(i) > 0xdfff) return true;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return true;
  }
  return false;
}
function mutate(value) {
  const chars = Array.from(value);
  const at = nextRandom() % (chars.length + 1);
  const symbol = pick(mutationChars);
  switch (nextRandom() % 7) {
    case 0: if (at < chars.length) chars.splice(at, 1); else chars.push(symbol); break;
    case 1: chars.splice(at, 0, symbol); break;
    case 2: if (at < chars.length) chars[at] = symbol; else chars.push(symbol); break;
    case 3: if (at < chars.length) chars.splice(at, 0, chars[at]); else chars.push(symbol); break;
    case 4: if (at < chars.length) chars[at] = chars[at] === chars[at].toUpperCase() ? chars[at].toLowerCase() : chars[at].toUpperCase(); break;
    case 5: if (at + 1 < chars.length) [chars[at], chars[at + 1]] = [chars[at + 1], chars[at]]; break;
    default: chars.splice(at, 0, pick(['\n', '\u2028', '\u0000', '\u0301', '\u200d']));
  }
  return chars.join('');
}

const schemes = ['http', 'https', 'ws', 'wss', 'ftp', 'file', 'mailto', 'data', 'urn', 'foo', 'a+b-c.d', 'h', '1bad', 'ht^tp'];
const hosts = ['a', 'A.', 'a..b', 'localhost', '1', '0x7f.1', '1.2.3', '256.1.1.1', '1.2.3.4.5',
  '127.0.0.1', '0177.1', '0xffffffff', '[::]', '[::1]', '[::ffff:1.2.3.4]', '[fe80::1%25en0]',
  '[v1.x]', '[::1', '::1]', 'xn--bcher-kva', 'xn--', 'bücher', 'a．b', 'a。b', '%41', '%2e', '%00', 'a b', 'a#b'];
const ports = ['', ':', ':0', ':80', ':00080', ':65535', ':65536', ':x'];
const paths = ['', '/', '/a', '/.', '/..', '/%2e', '/a b', '/a%20b', '/a%xx', '/a\\b'];
const tails = ['', '?q', '#f', '?#', '?a#b', '?%', '#%', '?é', '#😀'];
const urlEdges = [
  '', '..', '//a', '/a', '?q', '#f', '\\a', 'http:a', 'http:/a', 'http://a',
  'http://u:p@a:80/a?q#f', 'http://a:65536', 'http://a:0', 'http://[::1]',
  'http://[v1.x]', 'http://0x7f.1', 'http://0177.1', 'http://256.1.1.1',
  'http://a．b', 'http://a。b', 'http://xn--bcher-kva', 'http://xn--',
  'file:///C:/a', 'file://server/C:/a', 'file:C:\\a', 'mailto:x@y', 'data:text/plain,x',
  '\u0000http://a', 'http://a\n', 'http://a\tb', 'http://a%00', 'http://%2e',
  'http://a:80:90', 'http://u@v@a', 'http://a/./b', 'http://a/%2e%2e/b',
  'http://a?' + 'q'.repeat(4087),
];
function urlGrammar() {
  const scheme = chance(4) ? pick(schemes) : pick(['h', 'a', 'f']);
  const slash = pick(['://', ':', ':/', ':\\\\', ':///', ':/\\']);
  const credential = chance(12) ? pick(['u@', 'u:p@', '@', 'u@@']) : '';
  const host = chance(5) ? pick(hosts) : pick(['a', 'b', '1', '[::1]', 'x.y']);
  const port = chance(5) ? pick(ports) : '';
  const path = chance(4) ? pick(paths) : '';
  const tail = chance(4) ? pick(tails) : '';
  return scheme + slash + credential + host + port + path + tail;
}

const regexAtoms = ['a', '.', '^', '$', '\\d', '\\D', '\\w', '\\W', '\\s', '\\S', '\\b', '\\B',
  '[a-z]', '[^a-z]', '[z-a]', '[\\d-a]', '[a-\\w]', '[]', '[^]', '[', ']', '{', '}',
  '\\p{L}', '\\P{Script=Greek}', '\\p{Bad}', '\\p{Script=NoSuch}',
  '\\u{10ffff}', '\\u{110000}', '\\uD800', '\\uDC00', '\\x41', '\\xG0', '\\cA', '\\c1',
  '\\1', '\\2', '\\8', '\\07', '\\a', '\\-', '\\q', '٣', 'K', '😀'];
const regexGroups = ['(a)', '(?:a)', '(?=a)', '(?!a)', '(?<=a)', '(?<!a)', '(?<n>a)',
  '(?<n>a)(?<n>b)', '(?<a-b>x)', '(?<n>a)\\k<n>', '\\k<missing>', '(?i)', '(?i:a)',
  '(a|)', '(|a)', '()', '(', ')', '(?', '(?>a)', '(?=a)+', '(?<=a{1,2})'];
const regexQuantifiers = ['', '?', '*', '+', '{0}', '{1,}', '{1,2}', '{2,1}', '{999999999999}',
  '??', '*?', '+?', '{1,2}?', '{', '}'];
function regexGrammar() {
  let value = pick(regexGroups.concat(regexAtoms));
  if (chance(2)) value += pick(regexQuantifiers);
  if (chance(3)) value = pick(regexAtoms) + value;
  if (chance(3)) value += pick(regexAtoms);
  return value;
}

function makeFuzzValues(name, count, curated, check, skipped) {
  const values = [];
  const seen = new Set();
  function add(value) {
    if (hasLoneSurrogate(value)) { skipped.count++; return; }
    if (seen.has(value)) return;
    seen.add(value); values.push(value);
  }
  const urlFamily = ['url', 'iri', 'iri-reference', 'uri', 'uri-reference'].includes(name);
  const base = curated.filter(value => value.length <= 24);
  const validBase = base.filter(check);
  for (const value of (urlFamily ? urlEdges : name === 'regex' ? regexAtoms.concat(regexGroups) : base)) add(value);
  let attempts = 0;
  while (values.length < count && attempts++ < count * 200) {
    let value;
    if (urlFamily) value = chance(2) ? urlGrammar() : mutate(pick(urlEdges.filter(v => v.length < 100)));
    else if (name === 'regex') value = chance(2) ? regexGrammar() : mutate(pick(regexAtoms.concat(regexGroups)));
    else value = mutate(pick(validBase.length && !chance(4) ? validBase : base));
    if (value.length <= 4096) add(value);
  }
  if (values.length < count) throw new Error(`Could not generate ${count} distinct strings for ${name}`);
  return values.slice(0, count);
}

const source = extractTaggedSchema(repo);
try {
  const { formats } = await import(pathToFileURL(resolve(source.base, 'src/formats/index.ts')));
  const names = Object.keys(formats);
  if (names.length !== 21 || JSON.stringify(names) !== JSON.stringify(Object.keys(input.vectors))) {
    throw new Error('Format names or order differ from the tagged entry point');
  }
  const differences = new Set(input.knownRegexDifferences);
  const rows = [{ tag: 'v1.5.2', commit: source.commit,
    generator: 'Scripts/schema-fixtures/generate-format-fixtures.mjs',
    source: 'packages/schema/src/formats/index.ts', formatCount: names.length }];
  for (const name of names) {
    const values = input.vectors[name];
    if (!Array.isArray(values) || values.length < 60 || values.some(value => typeof value !== 'string')) {
      throw new Error(`Expected at least 60 strings for ${name}`);
    }
    if (new Set(values).size !== values.length) throw new Error(`Duplicate format string in ${name}`);
    const knownRegexDifferences = [];
    const vectors = [];
    for (const value of values) {
      const item = { value, expected: Boolean(formats[name](value)) };
      if (name === 'regex' && differences.has(value)) knownRegexDifferences.push(item);
      else vectors.push(item);
    }
    rows.push({ format: name, vectors, knownRegexDifferences });
  }
  const regexValues = new Set(input.vectors.regex);
  for (const value of differences) {
    if (!regexValues.has(value)) throw new Error(`Unknown regex difference vector: ${value}`);
  }
  const bytes = rows.map(row => JSON.stringify(row)).join('\n') + '\n';
  if (Buffer.byteLength(bytes) > 300_000) throw new Error('Format fixture exceeds 300 KB');
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== bytes) throw new Error('Generated format fixture differs');
  } else writeFileSync(output, bytes);
  console.log(`${names.length} formats, ${rows.slice(1).reduce((n, row) => n + row.vectors.length + row.knownRegexDifferences.length, 0)} strings, ${differences.size} known regex differences, ${Buffer.byteLength(bytes)} bytes`);

  const skipped = { count: 0 };
  const fuzzRows = [{ tag: 'v1.5.2', commit: source.commit, seed: fuzzSeed,
    generator: 'Scripts/schema-fixtures/generate-format-fixtures.mjs',
    skippedLoneSurrogates: 0, formatCount: names.length }];
  for (const name of names) {
    const count = ['url', 'iri', 'iri-reference', 'uri', 'uri-reference', 'regex'].includes(name) ? 4000 : 1500;
    const strings = makeFuzzValues(name, count, input.vectors[name], formats[name], skipped);
    const results = strings.map(value => formats[name](value) ? '1' : '0').join('');
    fuzzRows.push({ format: name, strings, results });
  }
  fuzzRows[0].skippedLoneSurrogates = skipped.count;
  const fuzzBytes = fuzzRows.map(row => JSON.stringify(row)).join('\n') + '\n';
  if (Buffer.byteLength(fuzzBytes) > 700_000) throw new Error(`Fuzz fixture exceeds 700 KB: ${Buffer.byteLength(fuzzBytes)}`);
  if (process.argv.includes('--check')) {
    if (readFileSync(fuzzOutput, 'utf8') !== fuzzBytes) throw new Error('Generated fuzz fixture differs');
  } else writeFileSync(fuzzOutput, fuzzBytes);
  console.log(`${fuzzRows.slice(1).reduce((n, row) => n + row.strings.length, 0)} fuzz strings, ${skipped.count} lone surrogate skips, ${Buffer.byteLength(fuzzBytes)} bytes`);
} finally { source.dispose(); }
