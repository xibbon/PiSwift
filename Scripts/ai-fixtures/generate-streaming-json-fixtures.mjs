import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const upstream = '/Users/miguel/cvs/pi/pi-mono';
const directory = mkdtempSync(join(tmpdir(), 'piswift-ai-fixtures-'));
try {
  mkdirSync(join(directory, 'packages/ai/src/utils'), { recursive: true });
  writeFileSync(join(directory, 'package.json'), '{"type":"module"}');
  for (const name of ['streaming-json.ts', 'json-parse.ts']) {
    const source = execFileSync('git', ['-C', upstream, 'show', `v1.5.2:packages/ai/src/utils/${name}`], { encoding: 'utf8' });
    writeFileSync(join(directory, 'packages/ai/src/utils', name), source);
  }
  execFileSync('npm', ['install', '--prefix', directory, '--no-audit', '--no-fund', '--ignore-scripts', 'partial-json@0.1.7'], { stdio: 'ignore' });
  const { StreamingJsonParser } = await import(pathToFileURL(join(directory, 'packages/ai/src/utils/streaming-json.ts')).href);
  const texts = [
    '{}', '[]', 'null', 'true', 'false', '0', '-0', '1', '-1', '0.25', '1e3', '1E-3',
    '{"a":1}', '{"a":true,"b":false,"c":null}', '{"a":[1,2,{"x":"y"}]}',
    '{"a":1,"a":2}', '{"__proto__":{"x":1}}', '{"a":"\\n\\t\\u00e9"}',
    '{"emoji":"😀"}', '{"emoji":"\\ud83d\\ude00"}', '{"a":"x\\q"}',
    '{"a":"x\\u12q"}', '{"a":}', '{"a" 1}', '{"a":1 "b":2}',
    '{"a":tru}', '{"a":fal}', '{"a":nul}', '{"a":1,}', '{"a":[1,]}',
    '{"a":1}garbage', '{"a":"unterminated', '{"a":"\\u12',
    '{"a":1', '[1,2', '1e', '1e+', '00', '-.', 'NaN', 'Infinity',
  ];
  let seed = 0x9265;
  const next = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; };
  const atom = () => ['null', 'true', 'false', '0', '-0', String(next() % 100000), `${next() % 1000}.${next() % 10000}`, `"s${next() % 1000}\\n😀"`, '[]', '{}'][next() % 10];
  while (texts.length < 300) {
    const i = texts.length;
    const key = `k${i}`;
    const value = atom();
    const nested = i % 4 === 0 ? `[${value},{"inner":${atom()}}]` : value;
    const text = `{ "${key}": ${nested}, "z": ${atom()} }`;
    texts.push(i % 9 === 0 ? text.slice(0, -(i % 7 + 1)) : i % 13 === 0 ? text + ' extra' : text);
  }
  texts[45] = '{"a":'.repeat(40) + '"deep"' + '}'.repeat(40);
  texts[46] = JSON.stringify({ content: 'quote " slash \\ newline \n astral 😀 '.repeat(14) });
  texts[47] = '{"n":1e+25}';
  texts[48] = '{"n":-1.25e-8}';
  texts[49] = '{"n":9007199254740993}';
  texts[50] = '{"n":1.23456789012345678}';
  texts[51] = '{"n":1e--3}';
  texts[52] = '{"n":01}';
  const numberForms = [
    '0', '-0', '1', '-1', '0.1', '0.2', '0.3', '0.30000000000000004',
    '1.', '1e', '1e+', '1e-', '-', '1E+2', '1e-2', '-1.25e+4',
    '9007199254740991', '9007199254740992', '9007199254740993',
    '1e21', '1e-7', '5e-324', '1.7976931348623157e308', '1e309', '-1e309',
    '12345678901234567890123456789012345678901234567890',
    '0.000001', '0.0000001', '10e+0', '-2.5E-3', '1e0007',
  ];
  for (const number of numberForms) texts.push(`{"number":${number}}`);
  const corpus = JSON.parse(execFileSync('git', ['-C', upstream, 'show', 'v1.5.2:packages/ai/test/data/json-test-suite.json'], { encoding: 'utf8' }));
  const corpusTexts = Object.entries(corpus.files).map(([name, base64]) => ({ name, text: Buffer.from(base64, 'base64').toString('utf8') }));
  const lines = [];
  const vectors = [...texts.map((text, index) => ({ text, index, name: undefined })), ...corpusTexts.map(({ text, name }, index) => ({ text, index: texts.length + index, name }))];
  for (const { text, index, name } of vectors) {
    const chars = Array.from(text);
    const patterns = [chars, Array.from({ length: Math.ceil(chars.length / 7) }, (_, i) => chars.slice(i * 7, i * 7 + 7).join(''))];
    const random = [];
    for (let i = 0; i < chars.length;) { const size = 1 + next() % 11; random.push(chars.slice(i, i + size).join('')); i += size; }
    patterns.push(random);
    for (const [split, chunks] of patterns.entries()) {
      const parser = new StreamingJsonParser();
      const hash = createHash('sha256');
      const sequence = [];
      for (const chunk of chunks) {
        const changes = parser.append(chunk);
        const snapshot = parser.snapshot() ?? null;
        const record = JSON.stringify([snapshot, changes]);
        hash.update(record + '\n');
        if (index % 10 === 0) sequence.push(record);
      }
      let final;
      try { final = JSON.stringify(JSON.parse(text)); } catch { final = null; }
      lines.push(JSON.stringify({ text, name, split, chunks, digest: hash.digest('hex'), final, sequence: index % 10 === 0 ? sequence : undefined }));
    }
  }
  const testSource = execFileSync('git', ['-C', upstream, 'show', 'v1.5.2:packages/ai/test/streaming-json.test.ts'], { encoding: 'utf8' });
  const table = (name) => {
    const declaration = testSource.indexOf(`const ${name}: readonly Vector[] = [`);
    if (declaration < 0) throw new Error(`missing ${name}`);
    const begin = testSource.indexOf('[', declaration + name.length);
    const end = testSource.indexOf('\n];', begin);
    if (end < 0) throw new Error(`unterminated ${name}`);
    return Function(`return ${testSource.slice(begin, end + 2)}`)();
  };
  const portedVectors = [...table('PARTIAL_JSON_VECTORS'), ...table('FIX_JSON_VECTORS')];
  const portedOutput = portedVectors.map(([input, expected]) => JSON.stringify({ input, hasValue: expected !== undefined, expectedJSON: expected === undefined ? null : JSON.stringify(expected) })).join('\n') + '\n';
  const portedFixture = join(root, 'Tests/PiSwiftAITests/Resources/streaming-json-ported-vectors-v1.5.2.jsonl');
  const output = lines.join('\n') + '\n';
  const fixture = join(root, 'Tests/PiSwiftAITests/Resources/streaming-json-v1.5.2.jsonl');
  if (process.argv.includes('--check')) {
    if (readFileSync(fixture, 'utf8') !== output) { console.error('streaming JSON fixture is stale'); process.exitCode = 1; }
    else if (readFileSync(portedFixture, 'utf8') !== portedOutput) { console.error('ported JSON vectors fixture is stale'); process.exitCode = 1; }
    else console.log(`streaming JSON fixture current: ${lines.length} vectors, ${Buffer.byteLength(output)} bytes; ${portedVectors.length} ported table vectors`);
  } else {
    writeFileSync(fixture, output);
    writeFileSync(portedFixture, portedOutput);
    console.log(`wrote ${lines.length} vectors, ${Buffer.byteLength(output)} bytes`);
  }
} finally { rmSync(directory, { recursive: true, force: true }); }
