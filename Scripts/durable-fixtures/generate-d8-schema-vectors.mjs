// D8: seeded durable validation vectors from the unmodified v1.5.2 pi-schema and pi-ai source.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirrorV152 } from './mirror-v152.mjs';
if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const outputURL = new URL('../../Tests/PiSwiftDurableTests/Fixtures/d8-schema-v152.json', import.meta.url);
const oldURL = new URL('../schema-fixtures/tool-validation-vectors.json', import.meta.url);
const source = await mirrorV152({ dependencies: ['diff@8.0.4', 'partial-json@0.1.7', 'typebox@1.3.27'] });
try {
  const { validateToolArguments } = await source.import('packages/ai/src/utils/validation.ts');
  const { compile } = await source.import('packages/schema/src/index.ts');
  const { formats } = await source.import('packages/schema/src/formats/index.ts');
  const old = JSON.parse(await readFile(oldURL, 'utf8'));
  const schemas = [];
  const index = new Map();
  function schemaIndex(schema) {
    const key = JSON.stringify(schema);
    if (!index.has(key)) { index.set(key, schemas.length); schemas.push(schema); }
    return index.get(key);
  }
  const raw = old.map(row => ({ id: row.id, name: row.name ?? 'echo', schema: row.schema, args: row.arguments,
    argumentsError: row.argumentsError, structured: false }));
  const builtinCreators = [
    ['read', 'packages/durable/src/tools/read.ts', 'createReadTool'],
    ['write', 'packages/durable/src/tools/write.ts', 'createWriteTool'],
    ['edit', 'packages/durable/src/tools/edit.ts', 'createEditTool'],
    ['bash', 'packages/durable/src/tools/bash.ts', 'createBashTool'],
    ['tool_search', 'packages/durable/src/tool-search/tool-search.ts', 'createToolSearchTool'],
  ];
  const builtinArguments = [{ path: null }, {}, { path: 'note.txt' }, { path: 7 },
    { path: 'note.txt', offset: '3.5', limit: '2' },
    { path: 'note.txt', content: 12 }, { path: 'note.txt', content: 'hello' },
    { path: 'note.txt', edits: { oldText: 'a', newText: 'b' } },
    { path: 'note.txt', edits: [{ oldText: 1, newText: 'b' }] },
    { command: 'printf ok', timeout: '3.5' }, { query: 'issue', limit: '2' },
    { query: 'issue', limit: 0 },
  ];
  for (const [name, path, creator] of builtinCreators) {
    const tool = (await source.import(path))[creator]();
    for (const [index, args] of builtinArguments.entries()) {
      raw.push({ id: `builtin-${name}-${index}`, name, schema: tool.parameters, args,
        structured: true, output: args });
    }
    if (name === 'read') {
      for (const [index, output] of ['hello', { type: 'image', data: 'AAAA', mimeType: 'image/png' },
        { type: 'image', data: 1, mimeType: 'image/png' }, null, { type: 'text', text: 'hello' }].entries()) {
        raw.push({ id: `builtin-read-output-${index}`, name, schema: tool.structuredOutputSchema,
          args: {}, structured: true, output });
      }
    }
  }
  const values = [null, '1', '3.5', 'yes', 'true', 'false', '0', 0, 1, 3.5, true, false,
    [], {}, ['1'], ['bad'], { count: '3.5' }, { count: 'bad' }, 'foo@example.com', 'bad', ''];
  let seed = 0xD8A152;
  function next() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; }
  for (let i = 0; i < 50; i++) {
    const key = `p${i}`;
    const property = [
      { type: 'number' }, { type: 'integer' }, { type: 'boolean' },
      { type: 'array', items: { type: 'number' } }, { type: 'string', format: 'email' },
      { type: 'object', properties: { count: { type: 'integer' } }, required: ['count'] },
      { $ref: '#/$defs/item' }, { type: 'string' }, { anyOf: [{ type: 'number' }, { type: 'boolean' }] },
      { type: 'array', items: { $ref: '#/$defs/item' } },
    ][i % 10];
    const schema = { type: 'object', properties: { [key]: property },
      ...(i % 3 === 0 ? { required: [key] } : {}),
      ...(i % 4 === 0 ? { additionalProperties: false } : {}),
      ...(i % 10 === 6 || i % 10 === 9 ? { $defs: { item: { type: 'integer' } } } : {}),
      description: `seeded ${i}` };
    for (let j = 0; j < 60; j++) {
      const value = j < values.length ? values[j] : values[next() % values.length];
      const args = j % 13 === 0 ? {} : j % 7 === 0 ? { [key]: value, extra: 'x' } : { [key]: value };
      raw.push({ id: `seed-${i}-${j}`, name: 'echo', schema, args, structured: true, output: j % 5 === 0 ? value : args });
    }
  }
  function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
    if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
    return JSON.stringify(value);
  }
  function hash(value) {
    let h = 0xcbf29ce484222325n;
    for (const byte of new TextEncoder().encode(canonical(value))) h = BigInt.asUintN(64, (h ^ BigInt(byte)) * 0x100000001b3n);
    return h.toString(16).padStart(16, '0');
  }
  const cases = raw.map(row => {
    const name = row.name ?? 'echo', schema = schemaIndex(row.schema);
    const tool = { name, description: '', parameters: row.schema };
    const call = { type: 'toolCall', id: row.id, name, arguments: row.args, argumentsError: row.argumentsError };
    let resultHash, error;
    try { resultHash = hash(validateToolArguments(tool, call)); } catch (caught) { error = String(caught.message ?? caught); }
    let outputError;
    if (row.structured) {
      const validator = compile(row.schema, { formats, unresolvedRefs: 'reject' });
      if (validator.check(row.output)) outputError = null;
      else {
        const first = validator.errors(row.output)[0];
        const path = first?.path?.slice(1).split('/').map(x => x.replaceAll('~1', '/').replaceAll('~0', '~')).join('.') || 'root';
        outputError = `${path}: ${first?.message ?? 'invalid'}`;
      }
    }
    return { id: row.id, name, schema, args: row.args, ...(row.argumentsError ? { argumentsError: row.argumentsError } : {}),
      ...(resultHash ? { resultHash } : { error }), ...(row.structured ? { output: row.output, outputError } : {}) };
  });
  const json = JSON.stringify({ tag: 'v1.5.2', seed: '0xD8A152', schemas, cases }, null, 0) + '\n';
  if (Buffer.byteLength(json) > 1_500_000) throw new Error(`Fixture budget exceeded: ${Buffer.byteLength(json)}`);
  if (process.argv.includes('--check')) {
    if (await readFile(outputURL, 'utf8') !== json) throw new Error('D8 schema vectors differ');
  } else await writeFile(outputURL, json);
  console.log(`D8 schema fixture ${process.argv.includes('--check') ? 'matches' : 'written'}: ${cases.length} cases, ${schemas.length} schemas, ${Buffer.byteLength(json)} bytes`);
} finally { await source.close(); }
