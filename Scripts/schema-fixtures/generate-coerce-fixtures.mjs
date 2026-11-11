#!/usr/bin/env node
// Use Node 22.19 or later. Read upstream code only from the local v1.5.2 tag.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractTaggedSchema } from './tagged-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const source = extractTaggedSchema(resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono'));
try {
  const load = name => import(pathToFileURL(resolve(source.base, name)));
  const { compile } = await load('src/index.ts');
  const { Coercer } = await load('src/coerce.ts');
  const { Compiler, RESTART } = await load('src/compiler.ts');
  const { formats } = await load('src/formats/index.ts');
  const { suiteFiles, suiteSchemas } = await load('test/suite.ts');
  const schemas = suiteSchemas();
  const rows = [];
  const counts = { suiteCases: 0, checkExtraCases: 0, errorExtraCases: 0, extraCases: 0, skippedNonJSON: 0, skippedCompile: 0 };
  function add(input, id, category, location) {
    if (input.dataKind !== undefined || input.data === undefined) { counts.skippedNonJSON++; return; }
    const options = { ...input.options, draft: input.options?.draft ?? input.draft ?? '2020-12',
      unresolvedRefs: input.options?.unresolvedRefs ?? input.unresolvedRefs,
      schemas: { ...schemas, ...input.options?.schemas }, formats: input.format ? formats : undefined, coerce: true };
    let validator;
    try { validator = compile(input.schema, options); }
    catch { counts.skippedCompile++; return; }
    let compiler = new Compiler(input.schema, options, false);
    try { compiler.root(); }
    catch (error) { if (error !== RESTART) throw error; compiler = new Compiler(input.schema, options, true); }
    const coercer = new Coercer(compiler, input.schema);
    const results = [validator.coerce(input.data), validator.parse(input.data), coercer.convertOnly(input.data)];
    function jsonValue(value) {
      if (value === undefined || typeof value === 'bigint' || typeof value === 'symbol' || typeof value === 'function') return false;
      if (typeof value === 'number' && !Number.isFinite(value)) return false;
      return value === null || typeof value !== 'object' || Object.values(value).every(jsonValue);
    }
    if (!results.every(jsonValue)) { counts.skippedNonJSON++; return; }
    const [coerce, parse, convertOnly] = results.map(value => JSON.stringify(value));
    const record = location ?? { id, schema: input.schema, data: input.data,
      ...(Object.keys(input.options ?? {}).length ? { options: input.options } : {}),
      ...(input.draft ? { draft: input.draft } : {}), ...(input.unresolvedRefs ? { unresolvedRefs: input.unresolvedRefs } : {}) };
    rows.push({ ...record, coerce, parse, convertOnly });
    counts[category]++;
  }
  for (const file of suiteFiles()) for (const [g, group] of file.groups.entries()) for (const [t, test] of group.tests.entries()) {
    add({ schema: group.schema, data: test.data, draft: file.draft, format: file.name.includes('/optional/format/') },
      `${file.name}/${g}/${t}`, 'suiteCases', { file: file.name, group: g, test: t });
  }
  for (const [name, category] of [['check', 'checkExtraCases'], ['errors', 'errorExtraCases'], ['coerce', 'extraCases']]) {
    const inputs = JSON.parse(readFileSync(resolve(root, `Scripts/schema-fixtures/extra-${name}-vectors.json`), 'utf8'));
    if (name === 'coerce' && (inputs.length < 400 || new Set(inputs.map(row => row.id)).size !== inputs.length)) throw new Error('Invalid extra coerce vectors');
    for (const [i, input] of inputs.entries()) add({ ...input, id: undefined }, `${name}-extra/${input.id ?? i}`, category);
  }
  const header = { tag: 'v1.5.2', commit: source.commit, generator: 'Scripts/schema-fixtures/generate-coerce-fixtures.mjs', ...counts };
  const bytes = [header, ...rows].map(row => JSON.stringify(row)).join('\n') + '\n';
  if (Buffer.byteLength(bytes) > 2_000_000) throw new Error(`Coerce fixture exceeds 2 MB: ${Buffer.byteLength(bytes)}`);
  const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/coerce-v1.5.2.jsonl');
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== bytes) throw new Error('Generated coerce fixture differs');
  } else writeFileSync(output, bytes);
  console.log(JSON.stringify({ ...counts, cases: rows.length, bytes: Buffer.byteLength(bytes) }));
} finally { source.dispose(); }
