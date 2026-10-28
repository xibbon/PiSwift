// Read the upstream tag without changing the pi-mono work tree. No npm dependencies.
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const upstreamTag = 'v1.4.0';
const upstreamSource = 'packages/coding-agent/src/core/model-resolver.ts';
const repository = fileURLToPath(new URL('../../', import.meta.url));
const fixturePath = resolve(repository, 'Tests/PiSwiftCodingAgentTests/fixtures/upstream-default-models.json');

// Parse only string properties. Do not execute the upstream TypeScript.
export function extractDefaultModels(source) {
  let offset = 0;
  function fail(message) {
    const line = source.slice(0, offset).split('\n').length;
    throw new Error(`${upstreamSource}:${line}: ${message}`);
  }
  function string() {
    const quote = source[offset++];
    let value = '';
    while (offset < source.length) {
      const character = source[offset++];
      if (character === quote) return value;
      if (character === '\n' || character === '\r') fail('Newline in string literal');
      if (character !== '\\') { value += character; continue; }
      if (offset === source.length) fail('Unterminated string escape');
      const escape = source[offset++];
      const escapes = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', 0: '\0' };
      if (escape === '\n') continue;
      if (escape === '\r') { if (source[offset] === '\n') offset++; continue; }
      if (escape === 'x' || escape === 'u') {
        const braced = escape === 'u' && source[offset] === '{';
        if (braced) offset++;
        const length = braced ? source.indexOf('}', offset) - offset : escape === 'x' ? 2 : 4;
        const digits = source.slice(offset, offset + length);
        if (length <= 0 || digits.length !== length || !/^[0-9a-f]+$/i.test(digits)) fail('Invalid string escape');
        const codePoint = Number.parseInt(digits, 16);
        if (codePoint > 0x10ffff) fail('Invalid Unicode code point');
        value += String.fromCodePoint(codePoint);
        offset += length + (braced ? 1 : 0);
      } else {
        if (/[0-9]/.test(escape) && (escape !== '0' || /[0-9]/.test(source[offset] ?? ''))) {
          fail('Legacy numeric string escape is not supported');
        }
        value += escapes[escape] ?? escape;
      }
    }
    fail('Unterminated string literal');
  }
  function next() {
    while (offset < source.length) {
      if (/\s/.test(source[offset])) { offset++; continue; }
      if (source.startsWith('//', offset)) {
        const end = source.indexOf('\n', offset + 2);
        offset = end < 0 ? source.length : end + 1;
        continue;
      }
      if (source.startsWith('/*', offset)) {
        const end = source.indexOf('*/', offset + 2);
        if (end < 0) fail('Unterminated comment');
        offset = end + 2;
        continue;
      }
      break;
    }
    if (offset === source.length) return { kind: 'end', value: '' };
    if (source[offset] === '"' || source[offset] === "'") return { kind: 'string', value: string() };
    if (source[offset] === '`' || source[offset] === '/') fail('Unsupported template or regular expression before the end of the table');
    const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(source.slice(offset));
    if (identifier) {
      offset += identifier[0].length;
      return { kind: 'identifier', value: identifier[0] };
    }
    return { kind: 'symbol', value: source[offset++] };
  }
  function expect(value) {
    const token = next();
    if (token.kind !== 'symbol' || token.value !== value) fail(`Expected '${value}', got '${token.value}'`);
  }

  let previous;
  let token;
  do {
    token = next();
    if (previous?.kind === 'identifier' && previous.value === 'const'
        && token.kind === 'identifier' && token.value === 'defaultModelPerProvider') break;
    previous = token;
  } while (token.kind !== 'end');
  if (token.kind === 'end') fail('Cannot find the defaultModelPerProvider declaration');
  token = next();
  if (token.kind === 'symbol' && token.value === ':') {
    do {
      token = next();
      if (token.kind === 'end' || [';', '{', '}'].includes(token.value)) fail('Cannot find the table initializer');
    } while (token.kind !== 'symbol' || token.value !== '=');
  }
  if (token.kind !== 'symbol' || token.value !== '=') fail('Expected a table initializer');
  expect('{');
  const entries = [];
  const providers = new Set();
  token = next();
  while (token.kind !== 'symbol' || token.value !== '}') {
    if (!['identifier', 'string'].includes(token.kind) || !token.value) fail('Expected a provider key');
    const provider = token.value;
    if (providers.has(provider)) fail(`Duplicate provider '${provider}'`);
    providers.add(provider);
    expect(':');
    const model = next();
    if (model.kind !== 'string' || !model.value) fail(`Expected a model id string for '${provider}'`);
    entries.push([provider, model.value]);
    token = next();
    if (token.kind === 'symbol' && token.value === '}') break;
    if (token.kind !== 'symbol' || token.value !== ',') fail('Expected a comma or the end of the table');
    token = next();
  }
  expect(';');
  if (!entries.length) fail('The default model table is empty');
  return entries;
}

function main() {
  let tag = upstreamTag;
  let path = fixturePath;
  let check = false;
  const args = process.argv.slice(2);
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (argument === '--check') check = true;
    else if (argument === '--tag' || argument === '--fixture') {
      const value = args[++index];
      if (!value || value.startsWith('-')) throw new Error(`Missing value for ${argument}`);
      if (argument === '--tag') tag = value;
      else path = resolve(value);
    } else if (argument === '--help') {
      console.log('Usage: node Scripts/default-models/generate-default-models-fixture.mjs [--tag TAG] [--fixture PATH] [--check]');
      console.log('PI_MONO_PATH overrides the upstream repository path (default: ../pi-mono from PiSwift).');
      return;
    } else throw new Error(`Unknown argument: ${argument}`);
  }
  const upstream = resolve(process.env.PI_MONO_PATH ?? resolve(repository, '../pi-mono'));
  const source = execFileSync('git', ['-C', upstream, 'show', `${tag}:${upstreamSource}`], { encoding: 'utf8' });
  const entries = extractDefaultModels(source);
  const output = JSON.stringify({ tag, source: upstreamSource, entries }, null, 2) + '\n';
  if (check) {
    let current;
    try { current = readFileSync(path, 'utf8'); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (current !== output) {
      console.error(`Default model fixture differs from ${tag}: ${path}`);
      if (current === undefined) {
        console.error(`--- ${path} (missing)\n+++ generated\n${output.split('\n').map(line => '+' + line).join('\n')}`);
      } else {
        const diff = spawnSync('git', ['diff', '--no-index', '--', path, '-'], { input: output, encoding: 'utf8' });
        if (diff.error) throw diff.error;
        if (diff.status !== 1) throw new Error(`Cannot show the fixture diff: ${diff.stderr}`);
        process.stdout.write(diff.stdout);
      }
      process.exitCode = 1;
      return;
    }
    console.log(`Default model fixture check passed: ${entries.length} entries from ${tag}.`);
  } else {
    writeFileSync(path, output);
    console.log(`Wrote ${entries.length} default models from ${tag}: ${path}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(); } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
