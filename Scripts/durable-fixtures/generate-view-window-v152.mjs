// Run the tagged window loader and advance functions without copying their algorithm.
// Storage paging is a deterministic adapter; this oracle does not run Harness or fork storage.
import { execFileSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { readFile, writeFile } from 'node:fs/promises';
const tag = 'v1.5.2';
const source = execFileSync('git', ['-C', process.env.PI_MONO ?? '/Users/miguel/cvs/pi/pi-mono', 'show', `${tag}:packages/durable/src/harness/view.ts`], { encoding: 'utf8' });
function section(start, end) { return source.slice(source.indexOf(start), source.indexOf(end)); }
const code = section('function resolveWindow(', '/**\n * The Harness') + section('function view(', '/**\n * Derive the mount') + section('function advance(', '/** `op` moved') + source.slice(source.indexOf('function prefixed('));
const oracle = runInNewContext(stripTypeScriptTypes(code) + '\n({resolveWindow, loadWindow, advance})', {
  DEFAULT_WINDOW_MIN: 50, SCAN_PAGE_SIZE: 256, idFromNumber: n => n,
  withoutAbortSignal: c => c, contained: f => f(), MOUNTED_KINDS: new Set(['pi.inbox']),
  // Local Delta adapter for this fixture's set-only document publications.
  applyImmutable: (root, ops) => {
    const copy = structuredClone(root);
    for (const [kind, path, value] of ops) {
      if (kind !== 's') throw Error(`Unexpected document adapter operation ${kind}`);
      let target = copy; for (const key of path.slice(0, -1)) target = target[key];
      target[path.at(-1)] = structuredClone(value);
    }
    return copy;
  },
});
const transcriptSource = execFileSync('git', ['-C', process.env.PI_MONO ?? '/Users/miguel/cvs/pi/pi-mono', 'show', `${tag}:packages/durable/src/harness/transcript.ts`], { encoding: 'utf8' });
const Transcript = runInNewContext(stripTypeScriptTypes(transcriptSource.replace(/^import .*;$/gm, '').replace(/^export /gm, '')) + '\nConversationTranscript', { idFromNumber: n => n });
let seed = 0x152d4;
const random = n => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % n; };
const cases = [];
for (let index = 0; index < 30; index++) {
  const min = 1 + random(55), max = min + random(60), pageSize = 1 + random(17);
  const from = [undefined, 1, 300 - max + 1, 299, 1300][index % 5];
  let entries = Array.from({ length: 300 }, (_, i) => ({ id: i + 1, conversationId: 1, kind: i === 100 ? 'summary' : i === 200 ? 'pi.reset' : 'note', ...(i === 100 ? { head: 51 } : {}), data: i }));
  let scans = 0;
  const storage = { async scanEntries(q, limit, cursor) {
    scans++;
    let selected = entries.filter(e => (q.minEntryId === undefined || e.id >= q.minEntryId) && (q.maxEntryId === undefined || e.id <= q.maxEntryId));
    if (q.order !== 'ascending') selected.reverse();
    const offset = cursor ?? 0, count = Math.min(limit, pageSize), items = selected.slice(offset, offset + count);
    return { items, ...(offset + count < selected.length ? { next: offset + count } : {}) };
  } };
  const loaded = await oracle.loadWindow(storage, 1, oracle.resolveWindow({ min, max, from }), {});
  const project = v => ({ entries: v.entries.map(e => e.data), kinds: v.entries.map(e => e.kind), inbox: v.docs['pi.inbox'], before: v.before === undefined ? null : v.before - 1 });
  const frames = [], revisions = [], value = { conversation: { id: 1 }, docs: { 'pi.inbox': { items: [] } }, ...loaded };
  const windowed = { min, max, value, observer: { advance: call => { frames.push(project(call.value)); revisions.push(call.value); } } };
  const mount = { conversation: value.conversation, docs: value.docs, incarnations: new Map([['pi.inbox', { id: 7, version: 1 }]]), observers: new Set([windowed]) };
  const bursts = [1, max + 3, 1, 2, 7];
  const inboxChanges = [
    [{ id: 900001, mode: 'followUp', content: 'queued a' }, { id: 900002, mode: 'steer', content: 'queued b' }],
    [{ id: 900002, mode: 'steer', content: 'queued b' }], [],
    [{ id: 900003, mode: 'followUp', content: 'queued c' }], [],
  ];
  for (const [step, count] of bursts.entries()) {
    const added = Array.from({ length: count }, (_, i) => ({ id: entries.length + i + 1, conversationId: 1, kind: 'note', data: entries.length + i }));
    entries = entries.concat(added);
    oracle.advance(1, mount, { changes: [...added.map(value => ({ type: 'entry', value })), { type: 'document', conversationId: 1, kind: 'change', record: { id: 7, kind: 'pi.inbox' }, version: 1, ops: [['s', ['items'], inboxChanges[step]]], value: { items: inboxChanges[step] } }] }, {}, e => { throw e; });
  }
  const transcript = new Transcript((q, limit) => storage.scanEntries(q, limit), { pageSize });
  const transcriptSteps = [];
  const snapshot = (action, view, frame = null) => transcriptSteps.push({ action, frame, inbox: view.docs['pi.inbox'], items: view.items.map(item => item.kind === 'entry' ? [0, item.entry.data] : item.kind === 'gap' ? [1, item.after - 1, item.upTo - 1] : [2]) });
  let transcriptView = transcript.merge(value);
  snapshot('initial', transcriptView);
  transcriptView = await transcript.loadEarlier({}); snapshot('earlier', transcriptView);
  for (let frame = 0; frame < revisions.length; frame++) {
    if (frame === 1) continue; // Simulate a stalled client across a trim.
    transcriptView = transcript.merge(revisions[frame]); snapshot('merge', transcriptView, frame);
    if (frame === 2) {
      const gap = transcriptView.items.find(item => item.kind === 'gap');
      if (gap) { transcriptView = await transcript.fillGap(gap, {}); snapshot('fill', transcriptView); }
    }
  }
  cases.push({ inboxChanges, transcriptSteps, index, fork: index % 2 === 1, min, max, pageSize, from: from ?? null, scans, initial: project(value), bursts, frames });
}
const output = JSON.stringify({ tag, seed: 0x152d4, scope: 'Tagged ConversationTranscript and resolveWindow/loadWindow/scanUpTo/advance; deterministic short-page storage adapter; synthetic inherited transcript with summary/reset markers; tagged inbox prefix/set propagation with local set-only Delta adapter', cases }) + '\n';
if (Buffer.byteLength(output) > 1_000_000) throw Error('Fixture exceeds 1 MB');
const path = new URL('view-window-v152.json', import.meta.url);
if (process.argv.includes('--check')) { if (await readFile(path, 'utf8') !== output) throw Error('View fixture differs'); }
else await writeFile(path, output);
console.log(`View oracle: 30 conversations, 300 initial entries each, ${Buffer.byteLength(output)} bytes`);
