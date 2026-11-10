#!/usr/bin/env node
// Probe the Unicode property spellings accepted by Node 22's ECMAScript u-mode RegExp.
// Candidate aliases are extracted from Unicode 17 PropertyAliases.txt and PropertyValueAliases.txt.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const input = JSON.parse(readFileSync(resolve(root, 'Scripts/schema-fixtures/regex-property-candidates-v17.json'), 'utf8'));
const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/regex-properties-node22.json');
const groups = {
  bare: [...input.propertyAliases, ...input.generalCategoryValues, ...input.special],
  generalCategory: input.generalCategoryValues.flatMap(value => [`gc=${value}`, `General_Category=${value}`]),
  script: input.scriptValues.flatMap(value => [`sc=${value}`, `Script=${value}`]),
  scriptExtensions: input.scriptValues.flatMap(value => [`scx=${value}`, `Script_Extensions=${value}`]),
  casing: input.propertyAliases.flatMap(value => [value.toLowerCase(), value.toUpperCase()]),
};
function accepted(expression) {
  try { new RegExp(`\\p{${expression}}`, 'u'); return true; }
  catch { return false; }
}
const decisions = Object.fromEntries(Object.entries(groups).map(([name, values]) => {
  const unique = [...new Set(values)];
  return [name, {
    accepted: unique.filter(accepted),
    rejected: unique.filter(value => !accepted(value)),
  }];
}));
const fixture = {
  tag: 'v1.5.2', nodeMajor: Number(process.versions.node.split('.')[0]),
  unicodeVersion: process.versions.unicode,
  generator: 'Scripts/schema-fixtures/generate-regex-property-fixtures.mjs',
  candidateSources: input.sources,
  decisions,
};
if (fixture.nodeMajor !== 22) throw new Error(`Expected Node 22, got ${process.version}`);
const bytes = JSON.stringify(fixture) + '\n';
if (process.argv.includes('--check')) {
  if (readFileSync(output, 'utf8') !== bytes) throw new Error('Regex property fixture differs');
} else writeFileSync(output, bytes);
const acceptedCount = Object.values(decisions).reduce((count, group) => count + group.accepted.length, 0);
console.log(`${acceptedCount} accepted Unicode property expressions, ${Buffer.byteLength(bytes)} bytes, Unicode ${fixture.unicodeVersion}`);
