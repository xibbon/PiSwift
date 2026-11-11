// The oracle loads unmodified source with git show. The upstream checkout is never used.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const result = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}
const tag = 'v1.5.2';
const repository = fileURLToPath(new URL('../../../pi-mono', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'piswift-partial-changes-'));
const show = path => execFileSync('git', ['-C', repository, 'show', `${tag}:${path}`], { encoding: 'utf8' });
async function copy(path) {
  const text = show(path);
  if (text.startsWith('tree ')) {
    for (const name of text.trim().split('\n').slice(2)) await copy(`${path}/${name.replace(/\/$/, '')}`);
  } else {
    await mkdir(dirname(join(directory, path)), { recursive: true });
    await writeFile(join(directory, path), text);
  }
}
try {
  for (const path of ['packages/chord/src/delta', 'packages/chord/src/json.ts',
    'packages/durable/src/harness/json.ts', 'packages/durable/src/harness/partial-changes.ts',
    'packages/ai/src/utils/streaming-json.ts', 'packages/ai/src/utils/json-parse.ts']) await copy(path);
  const aiPackage = JSON.parse(show('packages/ai/package.json'));
  execFileSync('npm', ['install', '--prefix', directory, '--ignore-scripts', '--no-audit', '--no-fund', `partial-json@${aiPackage.dependencies['partial-json']}`], { stdio: 'ignore' });
  await mkdir(join(directory, 'node_modules/@earendil-works'), { recursive: true });
  for (const [name, exports] of Object.entries({ chord: { './delta': './src/delta/index.ts', './json': './src/json.ts' }, ai: { './utils/streaming-json': './src/utils/streaming-json.ts' } })) {
    await writeFile(join(directory, `packages/${name}/package.json`), JSON.stringify({ type: 'module', exports }));
    await symlink(join(directory, `packages/${name}`), join(directory, 'node_modules/@earendil-works', name === 'ai' ? 'pi-ai' : name));
  }
  await writeFile(join(directory, 'packages/durable/package.json'), '{"type":"module"}');
  const load = path => import(pathToFileURL(join(directory, path)));
  const { PartialChanges } = await load('packages/durable/src/harness/partial-changes.ts');
  const { ToolCallArgumentsStream } = await load('packages/ai/src/utils/streaming-json.ts');
  const { track, applyImmutable } = await load('packages/chord/src/delta/index.ts');
  // Swift String stores Unicode scalars. A split escaped surrogate pair is
  // outside this fixture's boundary: Swift's parser emits a transient U+FFFD.
  // Use literal astral scalars and keep them intact when splitting tokens.
  const scalarJSON = value => typeof value === 'string' ? value.isWellFormed()
    : value !== null && typeof value === 'object' ? Object.entries(value).every(([key, child]) => key.isWellFormed() && scalarJSON(child)) : true;
  const sequences = [];
  for (let seed = 1; seed <= 50; seed++) {
    let randomState = seed;
    const random = n => { randomState = (Math.imul(randomState, 1664525) + 1013904223) >>> 0; return randomState % n; };
    const partial = { role: 'assistant', content: [{ type: 'text', text: '' }, { type: 'thinking', thinking: '' }], api: 'openai-completions', provider: 'test', model: 'test', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop', timestamp: 0 };
    const changes = new PartialChanges();
    const initial = { generation: { attempt: 1 } };
    const tracker = track(initial);
    const steps = [];
    const emit = event => { changes.observe({ ...event, partial }); steps.push({ event: structuredClone(event) }); };
    const commit = fail => {
      if (!scalarJSON(partial)) return;
      const message = structuredClone(partial);
      const taken = changes.take(message);
      const change = tracker.beginChange();
      changes.commit(change.state.generation, message, taken);
      if (fail) { change.abort(); changes.restore(taken); steps.push({ fail: true, message: structuredClone(partial) }); return; }
      const prepared = change.prepare();
      const ops = structuredClone(prepared.ops);
      if (!scalarJSON(ops)) throw new Error('An operation contains a lone surrogate');
      if (JSON.stringify(applyImmutable(tracker.value, ops)) !== JSON.stringify(prepared.value)) throw new Error('Oracle replay differs');
      tracker.adopt(prepared);
      steps.push({ message: structuredClone(partial), ops, value: structuredClone(tracker.value) });
    };
    const args = [new ToolCallArgumentsStream(), new ToolCallArgumentsStream()];
    const argumentTexts = [JSON.stringify({ path: `a${seed}.swift`, content: 'a😀é\\\n"' + 'x'.repeat(15 + random(40)), array: ['q😀', 1234, true, null], nested: { deep: { value: 'end' } } }), '{"astral":"😀","n":-12.25e2,"ok":true}'];
    const pieces = argumentTexts.map(text => {
      // Split by scalar so every event can be stored in Swift String.
      const scalars = Array.from(text), result = [];
      while (scalars.length) result.push(scalars.splice(0, 1 + random(9)).join(''));
      return result;
    });
    commit(false);
    for (let call = 0; call < 2; call++) {
      partial.content.push({ type: 'toolCall', id: `c${call}`, name: 'write', arguments: {} });
      emit({ type: 'toolcall_start', contentIndex: 2 + call });
    }
    let iteration = 0;
    while (pieces.some(p => p.length)) {
      const call = pieces[0].length && pieces[1].length ? random(2) : pieces[0].length ? 0 : 1;
      const delta = pieces[call].shift();
      partial.content[2 + call].arguments = args[call].append(delta);
      emit({ type: 'toolcall_delta', contentIndex: 2 + call, delta });
      const index = random(2), field = index ? 'thinking' : 'text', text = ['A', '😀', 'é', 'e\u0301', '\n'][random(5)];
      partial.content[index][field] += text;
      emit({ type: index ? 'thinking_delta' : 'text_delta', contentIndex: index, delta: text });
      if (iteration++ % (1 + seed % 4) === 0) commit((seed % 7 === 0 && iteration === 1) || (seed % 9 === 0 && iteration === 1 + 3 * (1 + seed % 4)));
    }
    commit(false);
    if (seed % 5 === 0) {
      const reset = tracker.beginChange(); reset.state.generation = { attempt: 1 }; tracker.adopt(reset.prepare());
      steps.push({ reset: true });
      commit(false);
    }
    partial.content[0].text = `replacement 😀 ${seed}`;
    emit({ type: 'text_end', contentIndex: 0, content: partial.content[0].text });
    emit({ type: 'thinking_end', contentIndex: 1, content: partial.content[1].thinking });
    for (let call = 0; call < 2; call++) {
      partial.content[2 + call].arguments = { final: seed + call, text: 'done😀' };
      emit({ type: 'toolcall_end', contentIndex: 2 + call, toolCall: partial.content[2 + call] });
    }
    commit(false);
    sequences.push({ seed, initial, steps });
  }
  const fixture = JSON.stringify({ tag, seeds: 50, sequences }) + '\n';
  const destination = new URL('../../Tests/PiSwiftDurableTests/Fixtures/partial-changes-v152.json', import.meta.url);
  if (process.argv.includes('--check')) {
    if (await readFile(destination, 'utf8') !== fixture) throw new Error('Partial changes fixture differs');
  } else await writeFile(destination, fixture);
  console.log(`Partial changes: ${sequences.length} seeded sequences verified from ${tag}`);
} finally { await rm(directory, { recursive: true, force: true }); }
