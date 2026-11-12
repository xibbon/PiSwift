// Compare exact tagged key identities and live Writer gate lookups with Swift.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirrorV152 } from './mirror-v152.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const child = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const fixturePath = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/session-keys-v152.json', import.meta.url));
const source = await mirrorV152();
try {
  const key = await source.import('packages/durable/src/session/keys.ts');
  const { Writer } = await source.import('packages/durable/src/session/writer.ts');
  let seed = 0x5a17c0de;
  const next = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0);
  function spec() {
    const kind = next() % 12;
    const id = 1 + next() % 80;
    const extra = 1 + next() % 12;
    return { kind, id, extra };
  }
  function make({ kind, id, extra }) {
    switch (kind) {
      case 0: return key.taskKey(id);
      case 1: return key.conversationKey(id);
      case 2: return key.entryKey(id);
      case 3: return key.appendKey(id);
      case 4: return key.submissionKey(id);
      case 5: return key.requestKey(id, `r:${extra}`);
      case 6: return key.documentKey(`["kind:${extra}","conversation",${id},null]`);
      case 7: return key.incarnationKey(id);
      case 8: return key.scopeKey({ kind: 'session' });
      case 9: return key.scopeKey({ kind: 'conversation', conversationId: id });
      case 10: return key.scopeKey({ kind: 'task', taskId: id });
      default: return key.ownedKey(`c${id}`);
    }
  }
  const pairs = [];
  for (let i = 0; i < 1_200; i++) {
    const left = spec();
    const right = i % 7 === 0 ? left : spec();
    const leftKey = make(left), rightKey = make(right);
    const host = {
      commit: () => new Promise(() => {}), stored() {}, publishing(publish) { publish(); },
      failure: () => undefined, fail() {}, report() {},
    };
    const writer = new Writer(host);
    writer.admit({ index: i, writes: [{ type: 'conversation', value: { id: 1 } }],
      keys: [leftKey], context: {}, publish: () => undefined, discard() {} });
    pairs.push({ left, leftKey, right, rightKey,
      gated: writer.gate(rightKey) !== undefined, drained: writer.drained() !== undefined });
  }
  const tables = [];
  for (let i = 0; i < 200; i++) {
    const id = 1 + next() % 80;
    const requestId = i % 2 ? `request:${i}` : undefined;
    const writes = [
      { type: 'conversation', value: { id } },
      { type: 'entry', value: { id: 100 + i, conversationId: id, kind: 'key' } },
      { type: 'task', value: { id: 400 + i } },
      { type: 'submission', value: { id: 700 + i, conversationId: id, requestId } },
    ];
    const values = [];
    key.tableKeys(writes, values);
    tables.push({ id, entry: 100 + i, task: 400 + i, submission: 700 + i,
      requestId: requestId ?? null, keys: values });
  }
  const output = JSON.stringify({ tag: 'v1.5.2', seed: '0x5a17c0de', pairs, tables }) + '\n';
  if (process.argv.includes('--check')) {
    if (await readFile(fixturePath, 'utf8') !== output) throw new Error('Session key fixture differs from the tag');
  } else await writeFile(fixturePath, output);
  console.log(`Tagged session keys: ${pairs.length} key pairs and gate scenarios, ${tables.length} table sets match fixture.`);
} finally { await source.close(); }
