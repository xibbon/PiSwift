#!/usr/bin/env node
// Run with Node 22.19 or later. The source comes only from the local Git tag.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { extractTaggedSchema } from './tagged-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const repo = resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono');
const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/check-v1.5.2.jsonl');
const source = extractTaggedSchema(repo);
try {
  const { commit, base } = source;
  const { compile } = await import(pathToFileURL(resolve(base, 'src/index.ts')));
  const { formats } = await import(pathToFileURL(resolve(base, 'src/formats/index.ts')));
  const { suiteFiles, suiteSchemas } = await import(pathToFileURL(resolve(base, 'test/suite.ts')));
  const schemas = suiteSchemas();
  const lines = [JSON.stringify({ tag: 'v1.5.2', commit, generator: 'Scripts/schema-fixtures/generate-check-fixtures.mjs' })];
  function add(input, options, id) {
    let result;
    try {
      const data = input.dataKind === 'undefined' ? undefined : input.dataKind === 'bigint' ? 1n : input.data;
      result = { expected: compile(input.schema, options).check(data) };
    }
    catch (error) { result = { thrown: String(error.message) }; }
    lines.push(JSON.stringify({ id, ...input, ...result }));
  }
  for (const file of suiteFiles()) {
    for (const group of file.groups) for (const test of group.tests) {
      const format = file.name.includes('/optional/format/');
      const input = { draft: file.draft, format, schema: group.schema, data: test.data };
      add(input, { draft: file.draft, schemas, formats: format ? formats : undefined }, `${file.name} > ${group.description} > ${test.description}`);
    }
  }
  const extras = JSON.parse(readFileSync(resolve(root, 'Scripts/schema-fixtures/extra-check-vectors.json'), 'utf8'));
  for (const [index, input] of extras.entries()) {
    const options = { draft: input.draft ?? '2020-12', schemas, unresolvedRefs: input.unresolvedRefs };
    add(input, options, `extra/${index}`);
  }
  const numberOutput = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/number-text-v1.5.2.json');
  const numberInputs = ['-0', '1.0', '1e21', '1e-7', '1e-6', '100000000000000000000', '9007199254740993', '0.1', '1.2345678901234567', '5e-324'];
  const numberBytes = JSON.stringify(numberInputs.map(input => ({ input, expected: JSON.stringify(JSON.parse(input)) }))) + '\n';
  if (process.argv.includes('--check')) {
    if (readFileSync(numberOutput, 'utf8') !== numberBytes) throw new Error('Number text fixture differs');
  } else writeFileSync(numberOutput, numberBytes);
  const objectOutput = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/object-text-v1.5.2.json');
  const objectInputs = [
    '{"b":1,"2":2,"1":3,"a":4,"0":5}',
    '{"4294967295":1,"4294967294":2,"01":3,"1":4,"0":5}',
    '{"z":0,"42":1,"3":2,"a":3,"42":4}',
    '{"outer":{"c":1,"10":2,"2":3},"2":4,"a":5,"1":6}',
    '{"-1":1,"1.0":2,"000":3,"0":4,"10":5}',
    '{"9":1,"5":2,"9":3,"x":4,"2":5}',
  ];
  const objectBytes = JSON.stringify(objectInputs.map(input => ({ input, expected: JSON.stringify(JSON.parse(input)) }))) + '\n';
  if (process.argv.includes('--check')) {
    if (readFileSync(objectOutput, 'utf8') !== objectBytes) throw new Error('Object text fixture differs');
  } else writeFileSync(objectOutput, objectBytes);
  const bytes = lines.join('\n') + '\n';
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== bytes) throw new Error('Generated fixture differs');
  } else writeFileSync(output, bytes);
  console.log(`${lines.length - 1} cases, ${Buffer.byteLength(bytes)} bytes`);
} finally { source.dispose(); }
