// Read the unmodified v1.4.0 context implementation. Never write to pi-mono.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const source = await mirror();
try {
  const { deriveContext } = await source.import('packages/durable/src/harness/context.ts');
  const user = text => ({ role: 'user', content: text, timestamp: 1 });
  const system = text => ({ role: 'system', content: text, timestamp: 1 });
  const answer = { role: 'assistant', content: [{ type: 'text', text: 'kept answer' }],
    api: 'openai-responses', provider: 'fixture', model: 'fixture',
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: 'stop', timestamp: 1 };
  const cases = [];
  const add = async (name, values) => {
    // ID 1 is the reserved root conversation. Entry IDs start at 2.
    const entries = values.map((value, index) => ({ id: index + 2, conversationId: 1, ...value,
      ...(value.head === undefined ? {} : { head: value.head + 1 }),
      ...(value.edits === undefined ? {} : { edits: value.edits.map(edit => ({ ...edit, target: edit.target + 1 })) }),
    }));
    // deriveContext reads a descending page, as the Storage contract requires.
    const storage = { scanEntries: async query => ({ items: entries.filter(entry =>
      (query.minEntryId === undefined || entry.id >= query.minEntryId) && entry.id <= query.maxEntryId).toReversed() }) };
    const historical = [];
    for (const tail of entries) {
      const head = entries.findLast(entry => entry.id <= tail.id && entry.head !== undefined);
      const view = await deriveContext(storage, 1, { head, tail: tail.id }, undefined);
      historical.push({ at: tail.id, ids: view.entries.map(entry => entry.id),
        contributions: view.contributions, messages: view.messages });
    }
    const expected = historical.at(-1);
    cases.push({ name, entries, expected: { ids: expected.ids,
      contributions: expected.contributions, messages: expected.messages }, historical });
  };
  const kept = [{ kind: 'pi.user', model: [user('question')] }, { kind: 'pi.assistant', model: [answer] }];
  const summary = { kind: 'pi.compaction', head: 2, model: [user('summary')] };
  const baseline = { kind: 'pi.system', model: [system('baseline')] };
  await add('late baseline after assistant', [...kept, baseline]);
  await add('baseline after kept assistant and head', [...kept, summary, baseline]);
  await add('retained system before head is not baseline', [baseline, kept[1], { ...summary, head: 1 },
    { kind: 'pi.system', model: [system('new baseline')] }]);
  await add('first positional system prevents later baseline moving', [...kept, summary,
    { kind: 'app.system', model: [system('positional')] }, baseline]);
  await add('earlier application system disqualifies baseline without head', [...kept,
    { kind: 'app.system', model: [system('positional')] }, baseline]);
  await add('only users before first system permits move', [kept[0],
    { kind: 'app.system', model: [system('positional')] }, kept[1], baseline]);
  await add('omitted baseline does not select later system', [...kept, baseline,
    { kind: 'edit', edits: [{ action: 'omit', target: 3 }] },
    { kind: 'pi.system', model: [system('later')] }]);
  await add('equal replacement is not the original baseline', [...kept, baseline,
    { kind: 'edit', edits: [{ action: 'replace', target: 3, messages: [system('baseline')] }] }]);
  await add('replacement baseline stays after assistant', [...kept, baseline,
    { kind: 'edit', edits: [{ action: 'replace', target: 3, messages: [system('replacement')] }] }]);
  await add('omitted application system still disqualifies baseline', [...kept,
    { kind: 'app.system', model: [system('positional')] },
    { kind: 'edit', edits: [{ action: 'omit', target: 3 }] }, baseline]);
  await add('earlier replacement system disqualifies baseline', [...kept,
    { kind: 'edit', edits: [{ action: 'replace', target: 1, messages: [system('replacement')] }] }, baseline]);
  await add('edited away earlier replacement still disqualifies baseline', [...kept,
    { kind: 'edit', edits: [{ action: 'replace', target: 1, messages: [system('replacement')] }] },
    { kind: 'edit', edits: [{ action: 'replace', target: 1, messages: [user('restored')] }] }, baseline]);
  await add('first system in multi-message baseline', [...kept,
    { kind: 'pi.system', model: [user('prefix'), system('baseline'), system('second')] }]);
  await add('baseline kind without system prevents later substitution', [...kept,
    { kind: 'pi.system', model: [user('no system')] }, baseline]);
  await add('head ignores earlier edited application system', [...kept,
    { kind: 'edit', edits: [{ action: 'replace', target: 1, messages: [system('replacement')] }] },
    { ...summary, head: 2 }, baseline]);
  const result = JSON.stringify({ tag: upstreamTag, provenance: {
    source: 'unmodified packages/durable/src/harness/context.ts at v1.4.0',
    construction: 'Constructed immutable transcript records; a read-only scan supplies each range. No Session or scheduler runs.',
  }, cases }, null, 2) + '\n';
  const path = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/context-baseline-v140.json', import.meta.url));
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== result) throw new Error('Context baseline fixtures differ');
  } else await writeFile(path, result);
  console.log(`Context baseline fixtures ${process.argv.includes('--check') ? 'match' : 'written'}: ${cases.length} cases.`);
} finally {
  await source.close();
}
