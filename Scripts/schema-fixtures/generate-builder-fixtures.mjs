#!/usr/bin/env node
// Run with Node 22.19 or later. Read builders only from the local v1.5.2 tag.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractTaggedSchema } from './tagged-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const repo = resolve(root, process.env.PI_MONO_PATH ?? '../pi-mono');
const output = resolve(root, 'Tests/PiSwiftSchemaTests/Fixtures/generated/builders-v1.5.2.jsonl');
const source = extractTaggedSchema(repo);
try {
  const b = await import(pathToFileURL(resolve(source.base, 'src/builders.ts')));
  const call = (builder, argument, options = {}) => ({ builder, ...(argument === undefined ? {} : { argument }), options });
  const str = (options = {}) => call('str', undefined, options);
  const num = (options = {}) => call('num', undefined, options);
  const int = (options = {}) => call('int', undefined, options);
  const lit = value => call('lit', value);
  const obj = (properties, options = {}) => call('obj', properties, options);
  const arr = item => call('arr', item);
  const nullable = item => call('nullable', item);
  function evaluate(input, self) {
    const { builder, argument, options = {} } = input;
    if (builder === 'self') return self;
    if (builder === 'obj') {
      // defineProperty retains an own __proto__ input, unlike a JavaScript object literal.
      const properties = {};
      for (const { name, schema, optional } of argument) Object.defineProperty(properties, name, {
        value: optional ? b.opt(evaluate(schema, self)) : evaluate(schema, self),
        enumerable: true, configurable: true, writable: true,
      });
      return b.obj(properties, options);
    }
    if (builder === 'recursive') return b.recursive(argument.id, ref => evaluate(argument.schema, ref));
    if (['arr', 'map', 'nullable'].includes(builder)) return b[builder](evaluate(argument, self), options);
    if (['tuple', 'union'].includes(builder)) return b[builder](argument.map(item => evaluate(item, self)), options);
    if (['lit', 'oneOf'].includes(builder)) return b[builder](argument, options);
    if (builder === 'unsafe') return argument === undefined ? b.unsafe() : b.unsafe(argument);
    return b[builder](options);
  }
  const lines = [JSON.stringify({ tag: 'v1.5.2', commit: source.commit, generator: 'Scripts/schema-fixtures/generate-builder-fixtures.mjs' })];
  function add(id, input) {
    lines.push(JSON.stringify({ id, call: input, expectedJSON: JSON.stringify(evaluate(input)) }));
  }
  const annotations = [
    {}, { title: 'Title' }, { description: 'Description' }, { examples: [] },
    { deprecated: false }, { deprecated: true }, { default: null },
    { title: 'T', description: 'D', examples: ['a', 1, true, null], deprecated: false, default: 'x' },
  ];
  for (const name of ['str', 'num', 'int', 'bigint', 'bool', 'nul', 'unknown', 'bytes']) {
    for (const [index, options] of annotations.entries()) add(`${name}/annotations/${index}`, call(name, undefined, options));
  }
  for (const [index, options] of [
    { minLength: 0 }, { maxLength: 8 }, { minLength: 1, maxLength: 5 },
    { pattern: '^a+$' }, { format: 'email' },
    { description: 'Text', minLength: 1, pattern: 'é', format: 'unknown' },
  ].entries()) add(`str/bounds/${index}`, str(options));
  for (const name of ['num', 'int']) {
    for (const [index, options] of [
      { minimum: -1 }, { maximum: 2 }, { exclusiveMinimum: 0 }, { exclusiveMaximum: 3 },
      { multipleOf: 0.5 }, { minimum: 1, maximum: 10, multipleOf: 2 },
    ].entries()) add(`${name}/bounds/${index}`, call(name, undefined, options));
  }
  for (const value of ['x', '', 0, -1, 0.25, true, false, null]) add(`lit/${JSON.stringify(value)}`, lit(value));
  add('oneOf/mixed', call('oneOf', ['read', 'write', 1, true, null]));
  add('oneOf/empty', call('oneOf', [], { description: 'Empty' }));
  add('union/empty', call('union', []));
  add('union/leaves', call('union', [str(), num(), call('nul')]));
  add('nullable/str', nullable(str()));
  add('nullable/nullable', nullable(nullable(str())));
  add('arr/bounds', call('arr', str(), { minItems: 1, maxItems: 3, uniqueItems: true, title: 'Array' }));
  add('arr/nested', arr(arr(num())));
  add('tuple/empty', call('tuple', []));
  add('tuple/pair', call('tuple', [str(), arr(int())], { description: 'Pair' }));
  add('map/number', call('map', num()));
  add('map/nested', call('map', call('map', str()), { title: 'Map' }));
  add('obj/empty', obj([]));
  add('obj/plain', obj([
    { name: 'path', schema: str({ description: 'File path', minLength: 1 }) },
    { name: 'offset', schema: int({ minimum: 1 }), optional: true },
    { name: 'mode', schema: call('oneOf', ['read', 'write']) },
  ]));
  add('obj/allOptional', obj([{ name: 'x', schema: str(), optional: true }]));
  for (const open of [true, false, null, 1, 'true']) {
    add(`obj/open/${JSON.stringify(open)}`, obj([{ name: 'a', schema: str() }], { title: 'Object', open, description: 'D' }));
  }
  add('obj/numericOrder', obj(['b', '2', '1', '01', '4294967295', '0'].map(name => ({ name, schema: str() }))));
  add('obj/duplicate', obj([{ name: 'a', schema: str() }, { name: 'b', schema: num() }, { name: 'a', schema: int(), optional: true }]));
  add('obj/unicodeKeys', obj(['é', 'e\u0301', 'a/b~c', '', '😀'].map(name => ({ name, schema: str() }))));
  add('obj/prototypeNames', obj(['constructor', 'toString', '__proto__', 'hasOwnProperty'].map(name => ({ name, schema: str() }))));
  add('obj/optionalPrototype', obj([{ name: '__proto__', schema: num(), optional: true }]));
  add('unsafe/default', call('unsafe'));
  add('unsafe/schema', call('unsafe', { type: 'string', enum: ['low', 'high'] }));
  add('recursive/tree', call('recursive', { id: 'Tree', schema: obj([
    { name: 'name', schema: str() }, { name: 'children', schema: arr(call('self')) },
  ]) }));
  add('recursive/overwriteID', call('recursive', { id: 'New', schema: call('unknown', undefined, { title: 'T', $id: 'Old', description: 'D' }) }));
  // Options are data at run time. Spread replaces a keyword without moving its position.
  add('str/override', str({ description: 'D', type: 'number', title: 'T' }));
  add('tuple/override', call('tuple', [str()], { minItems: 0, items: true }));
  add('obj/override', obj([{ name: 'a', schema: str() }], { required: [], additionalProperties: true }));
  add('bytes/bounds', call('bytes', undefined, { minLength: 1, maxLength: 8 }));
  const bytes = lines.join('\n') + '\n';
  if (Buffer.byteLength(bytes) > 100_000) throw new Error('Builder fixture exceeds 100 KB');
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== bytes) throw new Error('Builder fixture differs');
  } else writeFileSync(output, bytes);
  console.log(`${lines.length - 1} builder calls, ${Buffer.byteLength(bytes)} bytes`);
} finally { source.dispose(); }
