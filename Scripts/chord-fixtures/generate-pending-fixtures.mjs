import { assertFixtureBudget } from './fixture-budget.mjs';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const result = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

const directory = mkdtempSync(join(tmpdir(), 'chord-pending-v152-'));
try {
  for (const name of ['pending.ts', 'apply-immutable-trusted.ts']) {
    const source = execFileSync('git', ['-C', '/Users/miguel/cvs/pi/pi-mono', 'show', `v1.5.2:packages/chord/src/delta/${name}`], { encoding: 'utf8' });
    writeFileSync(join(directory, name), source);
  }
  const { PendingOps } = await import(pathToFileURL(join(directory, 'pending.ts')).href);
  const { applyImmutableTrusted } = await import(pathToFileURL(join(directory, 'apply-immutable-trusted.ts')).href);
  const base = () => ({ text: '', n: 0, arr: [0, 1, 2], nested: { v: 0 }, flag: true, map: {} });
  const hash = createHash('sha256');
  const scalarHash = createHash('sha256');
  let operations = 0;
  let replacements = 0;
  let splitPairs = 0;
  for (let seed = 0; seed < 2_000; seed++) {
    let word = seed >>> 0;
    const next = () => (word = (Math.imul(word, 1664525) + 1013904223) >>> 0);
    const batches = [];
    for (let index = 0, count = 4 + (next() % 9); index < count; index++) {
      const number = next() % 8;
      const digit = next() % 10;
      let batch;
      switch (number) {
        case 0: batch = [['a', ['text'], ['a', '😀', 'é'][digit % 3]]]; break;
        case 1: batch = [['s', ['n'], digit]]; break;
        case 2:
          if (seed < 1_000) batch = [['a', ['text'], '😀']];
          else { batch = [['a', ['text'], '\ud83d'], ['a', ['text'], '\ude00']]; splitPairs++; }
          break;
        case 3: batch = [['a', ['text'], 'x'], ['t', ['text'], 1]]; break;
        case 4: batch = [['p', ['arr'], 1, 1, [digit]]]; break;
        case 5: batch = [['m', ['arr'], [2, 0, 1]]]; break;
        case 6: batch = [['s', ['nested'], { v: digit }], ['s', ['nested', 'v'], digit + 1]]; break;
        default: batch = [['s', ['flag'], true], ['d', ['flag']], ['s', ['flag'], false]];
      }
      batches.push(batch);
      operations += batch.length;
    }
    if (seed % 19 === 0) batches.splice(2, 0, [['r', base()]]);
    const queue = new PendingOps();
    for (const batch of batches) queue.push(batch);
    const taken = queue.take();
    const original = applyImmutableTrusted(base(), batches.flat());
    const folded = taken.kind === 'replace' ? original : applyImmutableTrusted(base(), taken.ops);
    if (JSON.stringify(original) !== JSON.stringify(folded)) throw new Error(`PendingOps result differs at seed ${seed}`);
    if (taken.kind === 'replace') replacements++;
    const record = JSON.stringify([seed, taken, original, folded]) + '\n';
    hash.update(record);
    if (seed < 1_000) scalarHash.update(record);
  }
  // An oversized first batch stays whole; a second batch crosses the folded cap.
  for (const count of [10_000, 10_001]) {
    const batch = Array.from({ length: count }, (_, index) => ['s', ['map', String(index)], index]);
    const queue = new PendingOps();
    queue.push(batch);
    if (queue.size !== count) throw new Error('Single-batch size changed');
    queue.push([['s', ['n'], 1]]);
    const taken = queue.take();
    const original = applyImmutableTrusted(base(), [...batch, ['s', ['n'], 1]]);
    const folded = taken.kind === 'replace' ? original : applyImmutableTrusted(base(), taken.ops);
    if (JSON.stringify(original) !== JSON.stringify(folded)) throw new Error(`Cap result differs at ${count}`);
    if (taken.kind === 'replace') replacements++;
    hash.update(JSON.stringify([count, taken.kind, original.n, Object.keys(original.map).length]));
    hash.update('\n');
  }
  const manifest = JSON.stringify({ upstream: 'pi-mono v1.5.2', source: 'packages/chord/src/delta/pending.ts',
    seeds: 2_000, scalarSeeds: 1_000, operations, splitPairs, replacements,
    scalarSha256: scalarHash.digest('hex'), sha256: hash.digest('hex') }) + '\n';
  const path = fileURLToPath(new URL('../../Tests/PiSwiftChordTests/Fixtures/pending-v152-fixtures.json', import.meta.url));
  assertFixtureBudget({ 'pending-v152-fixtures.json': manifest });
  if (process.argv.includes('--check')) {
    if (readFileSync(path, 'utf8') !== manifest) throw new Error('PendingOps v1.5.2 fixture differs');
    console.log(`PendingOps v1.5.2 fixture check passed: 2000 seeds, ${operations} ops, ${splitPairs} split pairs.`);
  } else { writeFileSync(path, manifest); console.log('Wrote PendingOps v1.5.2 fixture.'); }
} finally { rmSync(directory, { recursive: true, force: true }); }
