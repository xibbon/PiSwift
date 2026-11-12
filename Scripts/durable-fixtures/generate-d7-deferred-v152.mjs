// Compare six fake-clock deferred streams, by stored seq and document content,
// between Swift and the unmodified v1.5.2 Session on SQLite and JSONL.
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { mirrorV152 } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath,
    ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const check = process.argv.includes('--check');
const root = fileURLToPath(new URL('../../', import.meta.url));
const output = fileURLToPath(new URL('./d7-deferred-v152/', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'piswift-d7-deferred-'));
let source;
const json = value => JSON.parse(JSON.stringify(value));
function difference(actual, expected, path = '$') {
  if (isDeepStrictEqual(actual, expected)) return undefined;
  if (actual && expected && typeof actual === 'object' && typeof expected === 'object') {
    for (const key of new Set([...Object.keys(actual), ...Object.keys(expected)])) {
      const result = difference(actual[key], expected[key], `${path}.${key}`);
      if (result) return result;
    }
  }
  return `${path}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`;
}
try {
  const swift = join(temporary, 'swift');
  await mkdir(swift);
  const exported = spawnSync('swift', ['test', '--filter', 'D7CrossLanguageFixtureTests'], {
    cwd: root, env: { ...process.env, PISWIFT_D7_FIXTURE_EXPORT: swift }, stdio: 'inherit', timeout: 180_000,
  });
  if (exported.error) throw exported.error;
  if (exported.status !== 0) throw new Error(`Swift D7 export exited ${exported.status}`);
  const manifest = JSON.parse(await readFile(join(swift, 'manifest.json'), 'utf8'));
  const expected = ['text', 'thinking', 'arguments', 'output', 'crash', 'close']
    .flatMap(name => ['sqlite', 'jsonl'].map(backend => `${name}-${backend}`)).sort();
  if (manifest.tag !== 'v1.5.2' || !isDeepStrictEqual(Object.keys(manifest.cases).sort(), expected)) {
    throw new Error('Expected six Swift scripts on SQLite and JSONL');
  }
  source = await mirrorV152({ dependencies: ['typebox@1.3.27', 'partial-json@0.1.7', 'diff@8.0.4'] });
  const { BACKGROUND_CONTEXT: context } = await source.import('packages/chord/src/context/index.ts');
  const { SessionImpl } = await source.import('packages/durable/src/session/session.ts');
  const { defineDoc } = await source.import('packages/durable/src/documents.ts');
  const { openNodeSqliteStorage } = await source.import('packages/durable/src/storage/sqlite/node.ts');
  const { openNodeJsonlStorage } = await source.import('packages/durable/src/storage/jsonl/node.ts');
  const Doc = defineDoc({ kind: 'pi.live', version: 3, scope: 'conversation', history: 'latest', fork: 'initial',
    initial: () => ({ text: '', thinking: '', tools: [{ arguments: '', output: '' }] }),
    checkpointWhen: value => value.base === true });
  const openStorage = (backend, path) => backend === 'sqlite'
    ? openNodeSqliteStorage(path) : openNodeJsonlStorage(path, context);
  async function run(scenario, backend) {
    const path = join(temporary, `${scenario}-${backend}${backend === 'sqlite' ? '.sqlite' : ''}`);
    const batches = [], publications = [], timers = [];
    let clock = 1_000;
    const setTimer = (callback, delayMs, { background }) => {
      if (background) return undefined;
      const timer = { callback, at: clock + delayMs, armed: true };
      timers.push(timer);
      return () => { timer.armed = false; };
    };
    async function reopen() {
      const backendStorage = await openStorage(backend, path);
      const recording = new Proxy(backendStorage, { get(target, property) {
        if (property === 'commit') return async (parts, receive, commitContext) => {
          for (const part of parts) batches.push(json(part));
          return target.commit(parts, receive, commitContext);
        };
        const value = target[property];
        return typeof value === 'function' ? value.bind(target) : value;
      } });
      const session = new SessionImpl(recording, () => clock, () => 600_000, setTimer, false, () => 100);
      session.observeCommits({ advance: publication => { publications.push(json(publication)); }, end: () => {} });
      return session;
    }
    async function storedValue(id) {
      const reader = await openStorage(backend, path);
      const record = await reader.findDocument({ kind: Doc.definition.kind,
        scope: { kind: 'conversation', conversationId: id } }, 'current', context);
      if (!record) throw new Error(`Missing ${scenario}-${backend} document`);
      const value = (await reader.document(record.id, 'current', context)).value;
      await reader.close(context);
      return json(value);
    }
    async function advance(ms, session) {
      clock += ms;
      for (const timer of timers) {
        if (!timer.armed || timer.at > clock) continue;
        timer.armed = false;
        timer.callback();
      }
      await session.readOnLine(async () => {});
    }
    let session = await reopen();
    const id = await session.commit(async tx => (await tx.createConversation({ ownership: { kind: 'ownerless' } })).id, context);
    await session.commit(async tx => { await tx.doc(Doc, id); }, context);
    const baselineBatches = batches.length, baselinePublications = publications.length;
    const reopens = [];
    async function append(field, part, withinMs) {
      await session.commit(async tx => {
        const live = await tx.doc(Doc, id);
        if (field === 'text' || field === 'thinking') live[field] += part;
        else live.tools[0][field] += part;
      }, context, { persistence: { kind: 'deferred', ...(withinMs === undefined ? {} : { withinMs }) } });
    }
    switch (scenario) {
      case 'text':
        await append('text', 'abcd', 100);
        await append('text', 'efgh', 200);
        await advance(100, session);
        await append('text', 'ijkl', Infinity);
        await session.commit(async tx => { (await tx.doc(Doc, id)).text; await tx.appendEntry(id, { kind: 'derived' }); }, context);
        break;
      case 'thinking':
        await append('thinking', 'why ');
        await append('thinking', 'now');
        await session.commit(async tx => { (await tx.doc(Doc, id)).base = true; }, context);
        break;
      case 'arguments':
        await append('arguments', '{"x":');
        await append('arguments', '1}');
        break;
      case 'output':
        await append('output', 'one\n', 50);
        await append('output', 'two\n', 200);
        await advance(50, session);
        break;
      case 'crash':
        await append('text', 'lost', Infinity);
        session.fail(new Error('fixture crash'));
        await session.closed;
        reopens.push(await storedValue(id));
        session = await reopen();
        await append('text', 'kept', 25);
        await advance(25, session);
        await append('text', 'lost-again', Infinity);
        session.fail(new Error('fixture crash'));
        await session.closed;
        reopens.push(await storedValue(id));
        session = await reopen();
        await append('text', '-resumed', Infinity);
        break;
      case 'close':
        await append('text', 'closed', Infinity);
        break;
      default: throw new Error(`Unknown scenario ${scenario}`);
    }
    await session.close(context);
    const final = await storedValue(id);
    const stored = publications.slice(baselinePublications), written = batches.slice(baselineBatches);
    if (stored.length !== written.length) throw new Error(`${scenario}-${backend}: ${stored.length} publications, ${written.length} batches`);
    const commits = stored.map((publication, index) => ({ seq: publication.seq,
      documents: written[index].filter(write => write.type === 'document.change')
        .map(write => ({ id: write.id, content: write.content })) }));
    return { commits, reopens, final };
  }
  for (const [name, expectedCase] of Object.entries(manifest.cases)) {
    const [scenario, backend] = name.split('-');
    const actual = await run(scenario, backend);
    const mismatch = difference(actual, expectedCase);
    if (mismatch) throw new Error(`${name}: ${mismatch}`);
  }
  if (check) {
    const saved = JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8'));
    const mismatch = difference(manifest, saved);
    if (mismatch) throw new Error(`Saved D7 fixture: ${mismatch}`);
  } else {
    await mkdir(output, { recursive: true });
    await writeFile(join(output, 'manifest.json'), JSON.stringify(manifest) + '\n');
  }
  console.log(`D7 deferred fixtures ${check ? 'match' : 'written'}: six streams, SQLite and JSONL, fake clock.`);
} finally {
  await source?.close();
  await rm(temporary, { recursive: true, force: true });
}
