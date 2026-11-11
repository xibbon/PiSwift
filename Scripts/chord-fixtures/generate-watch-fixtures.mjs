// Replay the complete v1.5.2 watch, context, delta, and telemetry source from Git.
// Explicit listener gates and event-loop turns make these traces deterministic.
import { assertFixtureBudget } from './fixture-budget.mjs';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const result = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

const tag = 'v1.5.2';
const repository = process.env.PI_MONO_ROOT ?? '/Users/miguel/cvs/pi/pi-mono';
const directory = mkdtempSync(join(tmpdir(), 'chord-watch-v152-'));
const fixturePath = fileURLToPath(new URL('../../Tests/PiSwiftChordTests/Fixtures/watch-v152-fixtures.json', import.meta.url));
const clone = value => JSON.parse(JSON.stringify(value));
const errorText = value => value instanceof Error ? value.message : String(value);
const turn = () => new Promise(resolve => setImmediate(resolve));
try {
  const files = ['chord/src/watch.ts', 'chord/src/context/index.ts', 'chord/src/json.ts',
    ...['index', 'diff', 'tracker', 'draft', 'apply-immutable-trusted', 'pending'].map(name => `chord/src/delta/${name}.ts`),
    ...['index', 'noop', 'memory', 'metrics'].map(name => `telemetry/src/${name}.ts`)];
  for (const name of files) {
    const path = join(directory, 'packages', name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, execFileSync('git', ['-C', repository, 'show', `${tag}:packages/${name}`]));
  }
  writeFileSync(join(directory, 'packages/telemetry/package.json'), JSON.stringify({ name: '@earendil-works/pi-telemetry', type: 'module', exports: './src/index.ts' }));
  mkdirSync(join(directory, 'node_modules/@earendil-works'), { recursive: true });
  symlinkSync(join(directory, 'packages/telemetry'), join(directory, 'node_modules/@earendil-works/pi-telemetry'));
  const { Watch, NativeWatch } = await import(pathToFileURL(join(directory, 'packages/chord/src/watch.ts')).href);
  const { BACKGROUND_CONTEXT, createContextKey, withContextValue, withAbortSignal } = await import(pathToFileURL(join(directory, 'packages/chord/src/context/index.ts')).href);
  const key = createContextKey('fixture');
  const cases = [];
  const counts = {};
  async function add(name, category, kind, initial, steps, replacement) {
    const calls = [];
    const reports = [];
    let detached = 0;
    let closed = null;
    let release;
    let listenerBlock = false;
    let listenerThrow;
    const watch = kind === 'json'
      ? new Watch(clone(initial), () => detached++, error => reports.push(errorText(error)))
      : new NativeWatch(clone(initial), () => detached++, error => reports.push(errorText(error)), replacement === undefined ? undefined : () => clone(replacement));
    void watch.closed.then(value => { closed = { kind: value.kind, ...('error' in value ? { error: errorText(value.error) } : {}) }; });
    const controller = new AbortController();
    const events = [];
    for (const [index, step] of steps.entries()) {
      const callOffset = calls.length;
      let error;
      const context = () => withAbortSignal(controller.signal, withContextValue(key, step.context ?? 'frame', BACKGROUND_CONTEXT));
      try {
        switch (step.op) {
          case 'advance':
            if (kind === 'json') watch.advance({ kind: 'value', value: clone(step.value), ops: clone(step.ops ?? []), retired: step.retired ?? false }, context());
            else watch.advance(clone(step.value), context());
            break;
          // Compact input for overflow tests. It has the same effect as count advances.
          case 'burst':
            for (let i = 0; i < step.count; i++) {
              const value = { n: step.from + i };
              if (kind === 'json') watch.advance({ kind: 'value', value, ops: step.increment ? [['t', ['n'], 1]] : [['s', ['n'], value.n]], retired: i === step.retiredAt }, context());
              else watch.advance(value, context());
            }
            break;
          case 'fail': watch.fail(step.error, context()); break;
          case 'start':
            listenerBlock = step.block ?? false;
            listenerThrow = step.throw;
            watch.start(async (call, frameContext) => {
              calls.push({ call: call.kind === 'failed' ? { kind: 'failed', error: errorText(call.error) } : clone(call), context: frameContext.value(key), abortRemoved: frameContext.abortSignal === undefined });
              if (listenerBlock) {
                listenerBlock = false;
                await new Promise(resolve => { release = resolve; });
              }
              if (listenerThrow !== undefined) throw new Error(listenerThrow);
            });
            break;
          case 'release': release?.(); release = undefined; break;
          case 'flush': await turn(); break;
          case 'stop': await watch.stop(); break;
          case 'abort': watch.abort(); break;
          case 'observeAbort':
            if (step.aborted) controller.abort();
            watch.observeAbort(controller.signal);
            break;
          case 'cancel': controller.abort(); break;
          case 'endAfterDelivery': watch.endAfterDelivery(); break;
          case 'end': watch.end({ kind: step.kind, ...(['failed', 'listener_error'].includes(step.kind) && step.error !== undefined ? { error: step.error } : {}) }); break;
          default: throw new Error(`Unknown operation: ${step.op}`);
        }
      } catch (caught) { error = errorText(caught); }
      // Omit empty fields. All counts and values are cumulative; calls are per step.
      events.push({ step: index, value: clone(watch.value), ...(calls.length === callOffset ? {} : { calls: calls.slice(callOffset) }),
        ...(detached ? { detached } : {}), ...(reports.length ? { reports: [...reports] } : {}), ...(closed === null ? {} : { closed: clone(closed) }), ...(error === undefined ? {} : { error }) });
    }
    // Every case ends its watch and releases any caller-owned callback.
    release?.();
    await watch.stop();
    await turn();
    cases.push({ name, category, kind, initial, ...(replacement === undefined ? {} : { replacement }), steps, events });
    counts[category] = (counts[category] ?? 0) + 1;
  }
  let seed = 0x7a15c032;
  const next = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; };
  const start = { op: 'start' }, flush = { op: 'flush' }, stop = { op: 'stop' };
  for (let index = 0; index < 160; index++) {
    const n = next() % 1000;
    const initial = { n: 0 };
    const value = number => ({ op: 'advance', value: { n: number }, ops: [['s', ['n'], number]], context: `c${number % 7}` });
    const fail = { op: 'fail', error: `failure-${n}`, context: 'failure' };
    const retired = { ...value(n + 1), ops: [], retired: true, context: 'retired' };
    const pattern = index % 16;
    const category = ['prestart-fold', 'busy-fold', 'failure-delivered', 'failure-superseded', 'retirement', 'drain-before-start', 'stop-running', 'abort-running', 'source-end-running', 'listener-error', 'double-start', 'abort-registration', 'first-terminal-wins', 'no-frame-end', 'multiple-failures', 'overflow'][pattern];
    let steps;
    switch (pattern) {
      case 0: steps = [value(n), value(n + 1), start, flush, stop]; break;
      case 1: steps = [value(n), { op: 'start', block: true }, flush, value(n + 1), value(n + 2), flush, { op: 'release' }, flush, stop]; break;
      case 2: steps = [value(n), start, flush, fail, flush, value(n + 1), flush, stop]; break;
      case 3: steps = [value(n), fail, value(n + 1), value(n + 2), start, flush, stop]; break;
      case 4: steps = [retired, fail, value(n + 2), start, flush, stop]; break;
      case 5: steps = [value(n), { op: 'endAfterDelivery' }, value(n + 1), start, flush]; break;
      case 6: steps = [value(n), { op: 'start', block: true }, flush, value(n + 1), stop, { op: 'release' }, flush]; break;
      case 7: steps = [{ op: 'observeAbort' }, value(n), { op: 'start', block: true }, flush, { op: 'cancel' }, { op: 'release' }, flush, stop]; break;
      case 8: steps = [value(n), { op: 'start', block: true }, flush, value(n + 1), { op: 'end', kind: index % 32 < 16 ? 'failed' : 'ended', ...(index % 32 < 16 ? { error: 'source' } : {}) }, { op: 'release' }, flush]; break;
      case 9: steps = [value(n), { op: 'start', throw: `listener-${n}` }, flush, value(n + 1), stop]; break;
      case 10: steps = [start, start, value(n), flush, stop, start]; break;
      case 11: steps = [{ op: 'observeAbort', aborted: true }, start, value(n), flush, stop]; break;
      case 12: steps = [value(n), { op: 'end', kind: 'failed', error: `terminal-${n}` }, { op: 'abort' }, stop, start]; break;
      case 13: steps = [start, flush, { op: 'endAfterDelivery' }, flush, value(n), stop]; break;
      case 14: steps = [value(n), fail, { ...fail, error: `latest-${n}`, context: 'latest' }, start, flush, value(n + 1), flush, stop]; break;
      case 15: steps = [{ op: 'burst', count: 102, from: n, context: 'overflow', retiredAt: 1 }, start, flush, stop]; break;
    }
    // Identical scripts expose JSON folding and native frame preservation.
    for (const kind of ['json', 'native']) await add(`${kind}-${index}`, category, kind, initial, steps, kind === 'native' && pattern === 15 && index % 32 === 15 ? { n: -n } : undefined);
  }
  await add('json-pending-operation-overflow', 'json-operation-overflow', 'json', { n: 0 }, [
    { op: 'burst', count: 10_001, from: 1, increment: true, context: 'overflow', retiredAt: 5000 }, start, flush, stop,
  ]);
  for (const kind of ['json', 'native']) {
    const frame = n => ({ op: 'advance', value: { n }, ops: [['s', ['n'], n]], context: `tail-${n}` });
    await add(`${kind}-drain-while-running`, 'drain-while-running', kind, { n: 0 }, [
      frame(1), { op: 'start', block: true }, flush, frame(2), { op: 'endAfterDelivery' }, frame(3), flush, { op: 'release' }, flush,
    ]);
    await add(`${kind}-stop-wins-listener-error`, 'stop-wins-listener-error', kind, { n: 0 }, [
      frame(1), { op: 'start', block: true, throw: 'late-listener-error' }, flush, stop, { op: 'release' }, flush,
    ]);
    await add(`${kind}-duplicate-abort-registration`, 'duplicate-abort-registration', kind, { n: 0 }, [
      { op: 'observeAbort' }, { op: 'observeAbort' }, frame(1), start, flush, { op: 'cancel' }, flush,
    ]);
  }
  const header = JSON.stringify({ upstream: 'pi-mono v1.5.2', source: 'packages/chord/src/watch.ts', seed: '0x7a15c032', counts });
  const output = header.slice(0, -1) + ',"cases":[\n' + cases.map(value => JSON.stringify(value)).join(',\n') + '\n]}\n';
  const bytes = assertFixtureBudget({ 'watch-v152-fixtures.json': output });
  if (process.argv.includes('--check')) {
    if (readFileSync(fixturePath, 'utf8') !== output) throw new Error('Watch v1.5.2 fixture differs from the upstream oracle');
    console.log(`Watch v1.5.2 fixture check passed: ${cases.length} cases; ${Buffer.byteLength(output)} bytes; all chord fixtures ${bytes} bytes.`);
  } else {
    writeFileSync(fixturePath, output);
    console.log(`Wrote ${cases.length} watch cases; ${Buffer.byteLength(output)} bytes; all chord fixtures ${bytes} bytes.`);
  }
} finally { rmSync(directory, { recursive: true, force: true }); }
