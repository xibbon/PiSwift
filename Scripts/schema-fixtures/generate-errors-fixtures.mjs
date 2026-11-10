#!/usr/bin/env node
// Run with Node 22.19 or later. The source comes only from the local Git tag.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractTaggedSchema } from './tagged-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const repo = resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono');
const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/errors-v1.5.2.jsonl');
const source = extractTaggedSchema(repo);
try {
  const { compile } = await import(pathToFileURL(resolve(source.base, 'src/index.ts')));
  const { formats } = await import(pathToFileURL(resolve(source.base, 'src/formats/index.ts')));
  const { suiteFiles, suiteSchemas } = await import(pathToFileURL(resolve(source.base, 'test/suite.ts')));
  const schemas = suiteSchemas();
  const rows = [];
  function result(schema, data, options) {
    try { return { expected: compile(schema, options).errors(data) }; }
    catch (error) { return { thrown: String(error.message) }; }
  }
  for (const file of suiteFiles()) {
    for (const [groupIndex, group] of file.groups.entries()) {
      for (const [testIndex, test] of group.tests.entries()) {
        const useFormats = file.name.includes('/optional/format/');
        rows.push({ file: file.name, group: groupIndex, test: testIndex,
          ...result(group.schema, test.data, { draft: file.draft, schemas, formats: useFormats ? formats : undefined }) });
      }
    }
  }
  const checkExtras = JSON.parse(readFileSync(resolve(root, 'Scripts/schema-fixtures/extra-check-vectors.json'), 'utf8'));
  let skippedNonJSON = 0;
  let skippedCompile = 0;
  let checkExtraCases = 0;
  for (const [index, input] of checkExtras.entries()) {
    if (input.dataKind !== undefined || input.data === undefined) { skippedNonJSON++; continue; }
    const options = { draft: input.draft ?? '2020-12', unresolvedRefs: input.unresolvedRefs };
    const outcome = result(input.schema, input.data, { schemas, ...options });
    if (outcome.thrown !== undefined) { skippedCompile++; continue; }
    rows.push({ id: `check-extra/${index}`, schema: input.schema, data: input.data, options, ...outcome });
    checkExtraCases++;
  }
  const extras = JSON.parse(readFileSync(resolve(root, 'Scripts/schema-fixtures/extra-errors-vectors.json'), 'utf8'));
  if (extras.length < 250) throw new Error('Expected at least 250 extra error vectors');
  if (new Set(extras.map(input => input.id)).size !== extras.length) throw new Error('Duplicate extra vector id');
  for (const input of extras) {
    rows.push({ ...input, ...result(input.schema, input.data, { schemas, ...input.options }) });
  }
  const header = { tag: 'v1.5.2', commit: source.commit,
    generator: 'Scripts/schema-fixtures/generate-errors-fixtures.mjs',
    suiteCases: rows.length - extras.length - checkExtraCases, checkExtraCases, extraCases: extras.length,
    skippedNonJSON, skippedCompile };
  const bytes = [header, ...rows].map(row => JSON.stringify(row)).join('\n') + '\n';
  if (Buffer.byteLength(bytes) > 1_500_000) throw new Error('Error fixture exceeds 1.5 MB');
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== bytes) throw new Error('Generated error fixture differs');
  } else writeFileSync(output, bytes);
  console.log(`${rows.length} cases, ${skippedNonJSON} non-JSON skips, ${skippedCompile} compile skips, ${Buffer.byteLength(bytes)} bytes`);
} finally { source.dispose(); }
