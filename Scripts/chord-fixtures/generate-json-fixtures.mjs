// Node 22 reference values for the PiSwiftChord JSON tests.
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';


// Write one case per line. Keep each case and its nested arrays compact.
function fixtureJSON(value) {
  if (Array.isArray(value)) return '[' + (value.length ? '\n' + value.map(entry => JSON.stringify(entry)).join(',\n') + '\n' : '') + ']';
  return '{' + Object.entries(value).map(([key, entry]) => JSON.stringify(key) + ':' + (entry && typeof entry === 'object' ? fixtureJSON(entry) : JSON.stringify(entry))).join(',') + '}';
}

const fixturePath = fileURLToPath(new URL('../../Tests/PiSwiftChordTests/Fixtures/json-fixtures.json', import.meta.url));
let seed = 0x6d2b79f5;
function randomWord() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return seed >>> 0;
}
const buffer = new ArrayBuffer(8);
const view = new DataView(buffer);
function bits(x) {
  view.setFloat64(0, x, false);
  return view.getBigUint64(0, false).toString(16).padStart(16, '0');
}
const inputs = [0, -0, 1, -1, 0.1, 0.1 + 0.2, 1 / 3, 100, 1.5, 12345.6789,
  1e16, 1e20, 1e21, 1.5e21, 123456789012345680000, 1e-6, 1e-7, 1.5e-7,
  -1.25e-10, 2 ** 53, 2 ** 53 + 2, Number.MAX_SAFE_INTEGER, Number.MIN_VALUE,
  Number.MAX_VALUE, Number.EPSILON];
let finiteCount = 0;
while (finiteCount < 1000) {
  view.setUint32(0, randomWord(), false);
  view.setUint32(4, randomWord(), false);
  const x = view.getFloat64(0, false);
  if (Number.isFinite(x)) { inputs.push(x); finiteCount++; }
}
for (let i = 0; i < 1000; i++) {
  const magnitude = -30 + 60 * (randomWord() / 0x100000000);
  const sign = (randomWord() & 1) === 0 ? 1 : -1;
  inputs.push(sign * 10 ** magnitude);
}
const numbers = inputs.map(x => ({ bits: bits(x), text: JSON.stringify(x) }));
const allKeys = ['b', '10', 'a', '9', '0', '01', '-1', '1.5', '4294967294',
  '4294967295', '__proto__', 'é', 'e\u0301', '😀'];
const set = (key, value) => ({ op: 'set', key, value });
const remove = key => ({ op: 'remove', key });
function keyCase(name, operations) {
  const object = {};
  for (const operation of operations) {
    if (operation.op === 'remove') delete object[operation.key];
    else Object.defineProperty(object, operation.key, {
      value: operation.value, writable: true, enumerable: true, configurable: true,
    });
  }
  return { name, operations, keys: Object.keys(object), text: JSON.stringify(object) };
}
const initial = allKeys.map((key, index) => set(key, index + 1));
const keyOrders = [
  keyCase('all key forms', initial),
  keyCase('reverse insertion', [...initial].reverse()),
  keyCase('replacement keeps position', [...initial, set('b', 99), set('9', 90), set('__proto__', null)]),
  keyCase('delete and add moves ordinary keys', [...initial, remove('b'), set('b', 99), remove('9'), set('9', 90), remove('é'), set('é', 88)]),
  keyCase('array index boundaries', ['000', '00', '0000000000', '00000000000', '1', '999999999', '1000000000', '4294967294', '4294967295', '4294967296', '9999999999', '10000000000', '-0'].map((key, index) => set(key, index))),
  keyCase('scalar key identity', [set('é', 1), set('e\u0301', 2), set('é', 3), set('😀', 4)]),
];
const stringInputs = [...Array.from({ length: 32 }, (_, index) => String.fromCodePoint(index)),
  '"', '\\', '/', '\u007f', '\u2028', '\u2029', '😀', 'e\u0301', 'é',
  Array.from({ length: 32 }, (_, index) => String.fromCodePoint(index)).join('') + '"\\/\u007f\u2028\u2029😀e\u0301'];
const strings = stringInputs.map(value => ({ value, text: JSON.stringify(value) }));
const validInputs = ['null', 'true', 'false', ' \t\r\n [1,true,null,"x"] \n',
  '{"a":1,"b":2,"a":3}', '{"10":1,"b":2,"9":3,"0":4}',
  '{"__proto__":{"safe":true}}', '{"é":1,"e\\u0301":2}',
  '"\\ud83d\\ude00"', '"\\u0065\\u0301"', '"\\b\\t\\n\\f\\r\\u0000\\/\\\\\\\""',
  '-0', '1.0', '1e+20', '1E-7', '5e-324', '1e-400',
  '{"a":1,"b":2,"a":3,"9":4,"01":5}', '{}', '[]',
  '"text\u2028\u2029😀"'];
const invalidInputs = ['[1,]', '{"a":1,}', "{'a':1}", '01', '+1', '.5', '1.', 'NaN',
  'Infinity', '/* comment */ 1', '"unterminated', '"raw\ncontrol"', '', 'true false',
  '[,1]', '{a:1}', '1e', '1e+', '--1', '"\\x00"', '\u000b1', '"\\uZZZZ"'];
for (const input of invalidInputs) {
  let rejected = false;
  try { JSON.parse(input); } catch { rejected = true; }
  if (!rejected) throw new Error(`Invalid input was accepted by Node: ${input}`);
}
const parse = { valid: validInputs.map(input => ({ input, text: JSON.stringify(JSON.parse(input)) })), invalid: invalidInputs };
const output = fixtureJSON({ numbers, keyOrders, strings, parse }) + '\n';
if (process.argv.includes('--check')) {
  const temporaryPath = fileURLToPath(new URL(`.json-fixtures-${process.pid}.tmp`, import.meta.url));
  try {
    writeFileSync(temporaryPath, output);
    if (readFileSync(temporaryPath, 'utf8') !== readFileSync(fixturePath, 'utf8')) {
      console.error('JSON fixture differs from the Node reference.');
      process.exitCode = 1;
    } else console.log(`JSON fixture check passed: ${numbers.length} numbers, ${keyOrders.length} key orders, ${strings.length} strings, ${parse.valid.length} valid parses, ${parse.invalid.length} invalid parses.`);
  } finally { unlinkSync(temporaryPath); }
} else {
  writeFileSync(fixturePath, output);
  console.log(`Wrote ${numbers.length} numbers, ${keyOrders.length} key orders, ${strings.length} strings, ${parse.valid.length} valid parses, ${parse.invalid.length} invalid parses.`);
}
