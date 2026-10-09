// Node 22 oracle. Load the tag's complete tracker; never load the working tree.
import { mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const result = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

// Write one case per line. Keep each case and its nested arrays compact.
function fixtureJSON(value) {
  if (Array.isArray(value)) return '[' + (value.length ? '\n' + value.map(entry => JSON.stringify(entry)).join(',\n') + '\n' : '') + ']';
  return '{' + Object.entries(value).map(([key, entry]) => JSON.stringify(key) + ':' + (entry && typeof entry === 'object' ? fixtureJSON(entry) : JSON.stringify(entry))).join(',') + '}';
}

// Digest only expected output. Inputs remain available for replay.
function expectedText(text) {
  const length = Buffer.byteLength(text, 'utf8');
  return length > 4096 ? { sha256: createHash('sha256').update(text, 'utf8').digest('hex'), length } : text;
}

const fixturePath = fileURLToPath(new URL('../../Tests/PiSwiftChordTests/Fixtures/tracker-fixtures.json', import.meta.url));
const temporary = mkdtempSync(join(tmpdir(), 'chord-tracker-'));
try {
  const archive = execFileSync('git', ['-C', '/Users/miguel/cvs/pi/pi-mono', 'archive', 'v1.1.0', 'packages/chord/src'], { maxBuffer: 16 * 1024 * 1024 });
  execFileSync('tar', ['-x', '-C', temporary], { input: archive });
  const { track } = await import(pathToFileURL(join(temporary, 'packages/chord/src/delta/tracker.ts')).href);
  let seed = 0x43a71e29;
  function word() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; }
  const integer = limit => word() % limit;
  const pick = values => values[integer(values.length)];
  const clone = value => JSON.parse(JSON.stringify(value));
  const cases = [];
  const counts = {};
  // Keep the full PRNG loops below, so each retained seeded case is unchanged.
  // Named cases and all emission categories remain. Only redundant cases shrink.
  const retainedCounts = { objects: 300, arrays: 350, 'handles-and-placements': 80,
    'strings-and-numbers': 80, 'reserved-keys': 60, lifecycle: 30, 'dense-regions': 6 };
  const finish = [{ op: 'prepare', name: 'p' }, { op: 'adopt', name: 'p' }];
  // A repeat expands set/push draft steps. Index markers may occur in paths,
  // keys and nested values. One event records the whole range operation.
  function substitute(value, index) {
    if (Array.isArray(value)) return value.map(entry => substitute(entry, index));
    if (value && typeof value === 'object') {
      if (value.$index === true) {
        const number = index * (value.scale ?? 1) + (value.offset ?? 0);
        return value.prefix === undefined ? number : value.prefix + number;
      }
      return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, substitute(entry, index)]));
    }
    return value;
  }
  const ix = (scale = 1, offset = 0, prefix) => ({ $index: true, ...(scale === 1 ? {} : { scale }), ...(offset === 0 ? {} : { offset }), ...(prefix === undefined ? {} : { prefix }) });
  const repeat = (count, step, from = 0, stride = 1) => ({ op: 'repeat', count, step, ...(from === 0 ? {} : { from }), ...(stride === 1 ? {} : { stride }) });
  function add(name, category, base, steps) {
    if ((counts[category] ?? 0) >= (retainedCounts[category] ?? Infinity)) return;
    const tracker = track(clone(base));
    const changes = new Map([['main', tracker.beginChange()]]);
    const prepared = new Map();
    const handles = new Map();
    const events = [];
    for (const [index, step] of steps.entries()) {
      const event = { step: index };
      let target;
      let before;
      try {
        const change = changes.get(step.change ?? 'main');
        // Resolve the target only for draft operations. This also checks settled
        // state at exactly the same step as an explicit Swift handle lookup.
        if (!['begin', 'prepare', 'adopt', 'abort', 'abortPrepared', 'replace', 'repeat'].includes(step.op)) {
          target = step.handle === undefined ? change.state : handles.get(step.handle);
          for (const segment of step.path ?? []) target = target[segment];
          if ((step.op === 'length' && step.count < 0) || (step.op === 'set' && Array.isArray(target) && step.key > target.length)) before = JSON.stringify(target);
        }
        switch (step.op) {
          case 'repeat': {
            for (let offset = 0; offset < step.count; offset++) {
              const expanded = substitute(step.step, (step.from ?? 0) + offset * (step.stride ?? 1));
              for (const item of Array.isArray(expanded) ? expanded : [expanded]) {
              let draft = item.handle === undefined ? changes.get(item.change ?? 'main').state : handles.get(item.handle);
              for (const segment of item.path ?? []) draft = draft[segment];
              if (item.op === 'set') draft[item.key] = clone(item.value);
              else if (item.op === 'push') draft.push(...clone(item.values));
              else throw new Error(`Unsupported repeat step: ${item.op}`);
              }
            }
            break;
          }
          case 'set': target[step.key] = clone(step.value); break;
          case 'delete': delete target[step.key]; break;
          case 'addString': target[step.key] += step.value; break;
          case 'addNumber': target[step.key] += step.value; break;
          case 'push': target.push(...clone(step.values)); break;
          case 'pop': target.pop(); break;
          case 'shift': target.shift(); break;
          case 'unshift': target.unshift(...clone(step.values)); break;
          case 'splice': {
            if (step.noArguments) target.splice();
            else if (step.deleteCount === undefined) target.splice(step.start);
            else target.splice(step.start, step.deleteCount, ...clone(step.values ?? []));
            break;
          }
          case 'reverse': target.reverse(); break;
          case 'length': target.length = step.count; break;
          case 'hold': handles.set(step.name, target); break;
          case 'snapshot': event.valueText = expectedText(JSON.stringify(target)); break;
          case 'begin': changes.set(step.name, tracker.beginChange()); break;
          case 'prepare': {
            const value = change.prepare(); prepared.set(step.name, value);
            event.ops = Buffer.byteLength(JSON.stringify(value.ops), 'utf8') > 4096 ? expectedText(JSON.stringify(value.ops)) : clone(value.ops); event.valueText = expectedText(JSON.stringify(value.value)); event.baseRevision = value.baseRevision;
            break;
          }
          case 'replace': {
            const value = tracker.prepareReplace(clone(step.value)); prepared.set(step.name, value);
            event.ops = Buffer.byteLength(JSON.stringify(value.ops), 'utf8') > 4096 ? expectedText(JSON.stringify(value.ops)) : clone(value.ops); event.valueText = expectedText(JSON.stringify(value.value)); event.baseRevision = value.baseRevision;
            break;
          }
          case 'adopt': tracker.adopt(prepared.get(step.name)); event.valueText = expectedText(JSON.stringify(tracker.value)); event.revision = tracker.revision; break;
          case 'abort': change.abort(); break;
          case 'abortPrepared': prepared.get(step.name).abort(); break;
          default: throw new Error(`Unknown step: ${step.op}`);
        }
      } catch (error) {
        event.error = error.message;
        // Placement/range failures must be atomic. A settled handle cannot be
        // inspected, but it cannot have reached the mutator either.
        if (before !== undefined && JSON.stringify(target) !== before) throw new Error(`${name}, step ${index}: failed draft operation changed its target`);
      }
      events.push(event);
    }
    cases.push({ name, category, base, steps, events });
    counts[category] = (counts[category] ?? 0) + 1;
  }
  const set = (key, value, path = []) => ({ op: 'set', key, value, path });
  const del = (key, path = []) => ({ op: 'delete', key, path });
  const text = () => Array.from({ length: integer(12) }, () => pick(['a', 'b', '😀', '🦀', 'é', 'e', '\u0301', '\n'])).join('');
  const value = () => pick([null, true, false, integer(40) - 20, text(), { v: integer(40) }, [integer(8), null]]);
  const keys = ['b', 'a', '0', '10', '9', '01', '-1', '4294967294', '4294967295', 'é', 'e\u0301', '😀'];
  for (let index = 0; index < 1000; index++) {
    const base = { b: 1, a: 2, '10': 'x', '01': false, nested: { x: 0, y: 'text' } };
    const steps = [];
    for (let i = 0, count = 5 + integer(20); i < count; i++) {
      const key = pick(keys); const path = integer(4) === 0 ? ['nested'] : [];
      if (integer(4) === 0) steps.push(del(key, path));
      else steps.push(set(key, value(), path));
    }
    if (index % 5 === 0) steps.push(del('b'), set('b', 1));
    if (index % 7 === 0) steps.push(set('a', 99), set('a', 2));
    add(`object-${index}`, 'objects', base, [...steps, ...finish]);
  }
  for (let index = 0; index < 1100; index++) {
    const base = Array.from({ length: integer(14) }, (_, i) => i);
    const steps = [];
    for (let i = 0, count = 5 + integer(16); i < count; i++) {
      switch (integer(10)) {
        case 0: steps.push(set(integer(20), value())); break;
        case 1: steps.push({ op: 'push', values: [value(), value()] }); break;
        case 2: steps.push({ op: 'pop' }); break;
        case 3: steps.push({ op: 'shift' }); break;
        case 4: steps.push({ op: 'unshift', values: [value(), value()] }); break;
        case 5: steps.push({ op: 'splice', start: integer(35) - 17, deleteCount: integer(12) - 3, values: [value()] }); break;
        case 6: steps.push({ op: 'splice', start: integer(35) - 17 }); break;
        case 7: steps.push({ op: 'reverse' }); break;
        case 8: steps.push({ op: 'length', count: integer(18) }); break;
        case 9: steps.push({ op: 'length', count: -1 }); break;
      }
    }
    add(`array-${index}`, 'arrays', base, [...steps, ...finish]);
  }
  for (let index = 0; index < 300; index++) {
    const base = { xs: [{ x: 0, nested: { n: 1 } }, { x: 1 }, { x: 2 }] };
    const steps = [
      { op: 'hold', path: ['xs', 1], name: 'slot' },
      { op: 'unshift', path: ['xs'], values: [{ x: -1 }] },
      { op: 'reverse', path: ['xs'] },
      { op: 'set', handle: 'slot', key: 'x', value: index },
      { op: 'splice', path: ['xs'], start: 1, deleteCount: 1, values: [] },
      { op: 'set', handle: 'slot', key: 'detached', value: true },
      set('introduced', { xs: [{ text: '' }] }),
      { op: 'addString', path: ['introduced', 'xs', 0], key: 'text', value: text() },
      ...finish,
    ];
    add(`held-${index}`, 'handles-and-placements', base, steps);
  }
  for (let index = 0; index < 300; index++) {
    const initial = text() + '😀e\u0301tail';
    const scalars = Array.from(initial);
    const rolled = scalars.slice(integer(scalars.length + 1)).join('') + text();
    const steps = index % 2 === 0
      ? [{ op: 'addString', key: 's', value: text() }]
      : [set('s', rolled)];
    steps.push({ op: 'addNumber', key: 'n', value: integer(30) - 15 });
    add(`strings-${index}`, 'strings-and-numbers', { s: initial, n: index }, [...steps, ...finish]);
  }
  for (let index = 0; index < 200; index++) {
    const reserved = pick(['__proto__', 'constructor', 'prototype']);
    const base = JSON.parse(`{"safe":{"${reserved}":{"x":0},"other":1},"outside":2}`);
    const steps = [set('x', index + 1, ['safe', reserved]), set('y', { z: index }, ['safe', reserved]), set('z', index + 2, ['safe', reserved, 'y']), set('outside', index)];
    if (index % 3 === 0) steps.push(set(reserved, { deep: 1 }), set('deep', 2, [reserved]));
    add(`reserved-${index}`, 'reserved-keys', base, [...steps, ...finish]);
  }
  for (let index = 0; index < 100; index++) {
    const steps = [
      { op: 'hold', name: 'held' }, { op: 'begin', name: 'other' },
      set('x', index), { op: 'set', change: 'other', key: 'x', value: index + 1 },
      { op: 'prepare', name: 'p' },
      { op: 'set', handle: 'held', key: 'x', value: -1 },
      { op: 'snapshot' }, { op: 'prepare', name: 'again' },
    ];
    if (index % 4 === 0) steps.push({ op: 'abort' }, { op: 'adopt', name: 'p' }, { op: 'abort' }, { op: 'prepare', change: 'other', name: 'q' }, { op: 'adopt', name: 'q' });
    else if (index % 4 === 1) steps.push({ op: 'prepare', change: 'other', name: 'q' }, { op: 'adopt', name: 'p' }, { op: 'adopt', name: 'q' }, { op: 'adopt', name: 'p' });
    else if (index % 4 === 2) steps.push({ op: 'adopt', name: 'p' }, { op: 'prepare', change: 'other', name: 'q' }, { op: 'snapshot', change: 'other' });
    else steps.push({ op: 'abortPrepared', name: 'p' }, { op: 'adopt', name: 'p' }, { op: 'abort', change: 'other' }, { op: 'snapshot', change: 'other' });
    steps.push({ op: 'replace', name: 'r', value: { x: index + 5 } }, { op: 'adopt', name: 'r' }, { op: 'replace', name: 'equal', value: { x: index + 5 } }, { op: 'adopt', name: 'equal' });
    add(`lifecycle-${index}`, 'lifecycle', { x: 0 }, steps);
  }
  for (let index = 0; index < 12; index++) {
    const base = { xs: Array.from({ length: 900 }, (_, i) => ({ n: i, nested: { count: 0 } })), outside: 1 };
    const steps = [repeat(300, index % 2 === 0
      ? set(ix(1, (index % 3) * 200), { n: ix(-1) }, ['xs'])
      : set('count', ix(1, 1), ['xs', ix(1, (index % 3) * 200), 'nested'])), set('outside', 2)];
    add(`dense-${index}`, 'dense-regions', base, [...steps, ...finish]);
  }
  for (let index = 0; index < 2; index++) {
    const base = {};
    const steps = [repeat(4100 + index, set(ix(1, 0, 'key'), ix()))];
    add(`operation-fallback-${index}`, 'operation-fallback', base, [...steps, ...finish]);
  }
  add('durable-inbox-all-writes-and-first-followup-leave', 'durable-patterns', { items: [
    { id: 'w1', mode: 'write', entry: { kind: 'note' } }, { id: 'f1', mode: 'followUp', content: 'f1' },
    { id: 'w2', mode: 'write', entry: { kind: 'note' } }, { id: 'f2', mode: 'followUp', content: 'f2' },
    { id: 'w3', mode: 'write', entry: { kind: 'note' } },
  ] }, [
    { op: 'splice', path: ['items'], start: 4, deleteCount: 1, values: [] },
    { op: 'splice', path: ['items'], start: 0, deleteCount: 3, values: [] }, ...finish,
  ]);
  add('durable-session-documents-push-pop-no-ops', 'durable-patterns', { items: [{ n: 1 }, { n: 2 }] }, [
    { op: 'push', path: ['items'], values: [{ n: 3 }] }, { op: 'pop', path: ['items'] }, ...finish,
  ]);
  add('durable-session-documents-shift-unshift-nonempty', 'durable-patterns', { items: [{ n: 1 }, { n: 2 }] }, [
    { op: 'shift', path: ['items'] }, { op: 'unshift', path: ['items'], values: [{ n: 1 }] }, ...finish,
  ]);
  add('durable-live-toolSlot-finishSlot', 'durable-patterns', { slots: [{ type: 'tool', toolCallId: 't', status: 'running', input: {} }] }, [
    { op: 'hold', path: ['slots', 0], name: 'toolSlot' },
    { op: 'unshift', path: ['slots'], values: [{ type: 'text', text: 'prefix' }] },
    { op: 'delete', handle: 'toolSlot', key: 'status' },
    { op: 'set', handle: 'toolSlot', key: 'type', value: 'toolResult' },
    { op: 'set', handle: 'toolSlot', key: 'output', value: { done: true } }, ...finish,
  ]);
  add('durable-live-exact-toolSlot-finishSlot-clearProgress', 'durable-patterns', { tools: [{
    taskId: 'tool-1', status: 'running', output: 'partial output', droppedBytes: 10, droppedLines: 2,
    details: { progress: 0.5 }, diagnostics: [{ message: 'partial diagnostic' }],
  }] }, [
    { op: 'hold', path: ['tools', 0], name: 'toolSlot' },
    { op: 'set', handle: 'toolSlot', key: 'status', value: 'done' },
    { op: 'set', handle: 'toolSlot', key: 'entry', value: 'entry-1' },
    ...['output', 'droppedBytes', 'droppedLines', 'details', 'diagnostics'].map(key => ({ op: 'delete', handle: 'toolSlot', key })),
    ...finish,
  ]);
  // Targeted source cases complement the randomized categories above.
  add('detaches-old-handles-for-deeply-equal-assignments', 'source-cases', { object: { x: 1 }, array: [{ x: 1 }] }, [
    { op: 'hold', path: ['object'], name: 'object' }, { op: 'hold', path: ['array', 0], name: 'array' },
    set('object', { x: 1 }), set('array', [{ x: 1 }]),
    { op: 'set', handle: 'object', key: 'x', value: 2 }, { op: 'set', handle: 'array', key: 'x', value: 2 }, ...finish,
  ]);
  add('normalizes-restored-overrides-and-cancelled-structural-edits', 'source-cases', { xs: [1, 2, 3], x: 1 }, [
    set('x', 2), set('x', 1), set(0, 99, ['xs']), set(0, 1, ['xs']),
    { op: 'reverse', path: ['xs'] }, { op: 'reverse', path: ['xs'] }, ...finish,
  ]);
  add('handles-null-sparse-overrides-without-confusing-absence', 'source-cases', [null, 1, null], [
    set(1, null), { op: 'length', count: 7 }, set(5, { x: 1 }), { op: 'length', count: 6 }, ...finish,
  ]);
  add('read-only-traversals-do-not-dirty', 'source-cases', { a: [{ nested: { x: 1 } }] }, [
    { op: 'hold', path: ['a', 0, 'nested'], name: 'leaf' }, { op: 'snapshot', handle: 'leaf' }, ...finish,
  ]);
  add('integer-and-string-order-across-delete-readd', 'source-cases', { b: 1, '10': 10, a: 2, '9': 9 }, [
    del('b'), del('9'), set('b', 3), set('9', 90), set('0', 0), set('01', 1), ...finish,
  ]);
  add('replays-introduced-moved-edited-descendants', 'source-cases', { xs: [{ n: 0 }, { n: 1 }] }, [
    { op: 'push', path: ['xs'], values: [{ n: 2, child: { x: 0 } }] },
    { op: 'hold', path: ['xs', 2], name: 'insert' }, { op: 'reverse', path: ['xs'] },
    { op: 'set', handle: 'insert', path: ['child'], key: 'x', value: 7 }, ...finish,
  ]);
  add('matches-native-splice-with-zero-or-one-argument', 'source-cases', { xs: [0, 1, 2, 3] }, [
    { op: 'splice', path: ['xs'], noArguments: true }, { op: 'snapshot', path: ['xs'] },
    { op: 'splice', path: ['xs'], start: 2 }, { op: 'snapshot', path: ['xs'] }, ...finish,
  ]);
  add('restored-primitive-array-override-leaves-write-order', 'source-cases', [0, 1], [
    set(0, 9), set(1, 8), set(0, 0), set(0, 7), ...finish,
  ]);
  {
    const base = Array.from({ length: 300 }, (_, i) => i);
    const steps = [repeat(300, set(ix(), ix(-1, -1))), repeat(300, set(ix(), ix()))];
    add('dense-primitive-array-overrides-restored-no-ops', 'source-cases', base, [...steps, ...finish]);
  }
  {
    const base = Array.from({ length: 300 }, (_, i) => ({ n: i }));
    const steps = [repeat(300, set(ix(), { n: ix() }))];
    add('dense-deep-equal-container-array-overrides-retained', 'source-cases', base, [...steps, ...finish]);
  }
  {
    const base = { deep: { xs: Array.from({ length: 600 }, (_, i) => ({ constructor: { n: i }, xs: [0, 1] })) }, outside: 'a' };
    const steps = [repeat(75, [set('n', ix(1, 1), ['deep', 'xs', ix(), 'constructor']),
      { op: 'push', path: ['deep', 'xs', ix(), 'xs'], values: [2] },
      ...[1, 2, 3].map(offset => set('n', ix(1, offset + 1), ['deep', 'xs', ix(1, offset), 'constructor']))], 0, 4),
      { op: 'addString', key: 'outside', value: 'b' }];
    add('nested-reserved-folds-and-structural-edits-covered-by-dense-region', 'source-cases', base, [...steps, ...finish]);
  }
  {
    const base = { xs: Array.from({ length: 1600 }, (_, i) => ({ n: i })), outside: 0 };
    const steps = [repeat(300, [set('n', ix(-1, -1), ['xs', ix()]), set('n', ix(-1, -1), ['xs', ix(1, 1100)])]),
      set('n', 999, ['xs', 800]), set('outside', 1)];
    add('multiple-disjoint-dense-regions-preserve-outside-operations', 'source-cases', base, [...steps, ...finish]);
  }
  const output = fixtureJSON({ upstream: 'pi-mono v1.1.0', seed: '0x43a71e29', counts, cases }) + '\n';
  const fixtureDirectory = new URL('../../Tests/PiSwiftChordTests/Fixtures/', import.meta.url);
  const fixtureBytes = Buffer.byteLength(output, 'utf8') + readdirSync(fixtureDirectory)
    .filter(name => name !== 'tracker-fixtures.json' && statSync(new URL(name, fixtureDirectory)).isFile())
    .reduce((sum, name) => sum + statSync(new URL(name, fixtureDirectory)).size, 0);
  if (fixtureBytes > 3_000_000) throw new Error(`Fixture budget exceeded: ${fixtureBytes} bytes`);
  if (process.argv.includes('--check')) {
    if (readFileSync(fixturePath, 'utf8') !== output) {
      console.error('Tracker fixture differs from the upstream Node tracker.'); process.exitCode = 1;
    } else console.log(`Tracker fixture check passed: ${cases.length} cases; ${JSON.stringify(counts)}.`);
  } else {
    writeFileSync(fixturePath, output);
    console.log(`Wrote ${cases.length} tracker cases; ${JSON.stringify(counts)}.`);
  }
} finally { rmSync(temporary, { recursive: true, force: true }); }
