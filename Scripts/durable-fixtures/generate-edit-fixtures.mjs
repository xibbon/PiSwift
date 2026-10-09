// Expected values come from unmodified v1.1.0 code and pinned npm diff releases.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { mirror, upstreamTag, upstreamRepository } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr}`);
}
const directory = await mkdtemp(join(tmpdir(), 'piswift-edit-oracle-'));
const source = await mirror();
try {
  for (const version of ['8.0.3', '8.0.4']) {
    const target = join(directory, version);
    await mkdir(target);
    run('npm', ['pack', `diff@${version}`, '--pack-destination', target, '--silent']);
    run('tar', ['-xzf', join(target, `diff-${version}.tgz`), '-C', target]);
    const manifest = JSON.parse(await readFile(join(target, 'package/package.json'), 'utf8'));
    if (manifest.version !== version) throw new Error('Unexpected npm diff version');
  }
  // These are all the implementation files used by this oracle. 8.0.4 changes
  // diffWords only; line diffs, path selection, and patch formatting are identical.
  for (const file of ['libesm/diff/base.js', 'libesm/diff/line.js', 'libesm/patch/create.js']) {
    if (await readFile(join(directory, '8.0.3/package', file), 'utf8') !== await readFile(join(directory, '8.0.4/package', file), 'utf8')) {
      throw new Error(`diff 8.0.3 and 8.0.4 differ in ${file}`);
    }
  }
  const checkoutDiff = join(upstreamRepository, 'node_modules/diff');
  const checkoutManifest = JSON.parse(await readFile(join(checkoutDiff, 'package.json'), 'utf8'));
  if (checkoutManifest.version !== '8.0.3') throw new Error('The upstream checkout must supply diff 8.0.3');
  await symlink(checkoutDiff, join(source.directory, 'node_modules/diff'));
  const upstream = await source.import('packages/durable/src/tools/edit-diff.ts');
  const compatible = await import(pathToFileURL(join(directory, '8.0.4/package/libesm/index.js')).href);
  const edits = [];
  function edit(name, content, replacements) {
    const normalized = upstream.normalizeToLF(content);
    try {
      edits.push({ name, content, replacements, result: upstream.applyEditsToNormalizedContent(normalized, replacements, 'fixture.txt') });
    } catch (error) { edits.push({ name, content, replacements, error: error.message }); }
  }
  const one = (oldText, newText) => [{ oldText, newText }];
  edit('disjoint', 'alpha\nbeta\ngamma\ndelta\n', [{ oldText: 'alpha\n', newText: 'ALPHA\n' }, { oldText: 'gamma\n', newText: 'GAMMA\n' }]);
  edit('reverse-order', 'alpha\nbeta\ngamma\n', [{ oldText: 'gamma', newText: 'GAMMA' }, { oldText: 'alpha', newText: 'ALPHA' }]);
  edit('original-not-incremental', 'one\ntwo\n', [{ oldText: 'one', newText: 'three' }, { oldText: 'three', newText: 'four' }]);
  edit('overlap', 'one\ntwo\nthree\n', [{ oldText: 'one\ntwo\n', newText: 'ONE' }, { oldText: 'two\nthree\n', newText: 'TWO' }]);
  edit('nested', 'abcdef', [{ oldText: 'abcdef', newText: 'X' }, { oldText: 'cd', newText: 'Y' }]);
  edit('same-start', 'abcdef', [{ oldText: 'abc', newText: 'X' }, { oldText: 'ab', newText: 'Y' }]);
  edit('adjacent', 'abcdef', [{ oldText: 'abc', newText: 'X' }, { oldText: 'def', newText: 'Y' }]);
  edit('missing', 'foo foo foo', one('bar', 'baz'));
  edit('duplicate', 'foo foo foo', one('foo', 'bar'));
  edit('non-overlapping-occurrences', 'aaa', one('aa', 'b'));
  edit('multi-missing', 'alpha', [{ oldText: 'alpha', newText: 'A' }, { oldText: 'beta', newText: 'B' }]);
  edit('multi-duplicate', 'alpha beta beta', [{ oldText: 'alpha', newText: 'A' }, { oldText: 'beta', newText: 'B' }]);
  edit('empty', 'alpha', one('', 'A'));
  edit('multi-empty', 'alpha', [{ oldText: 'alpha', newText: 'A' }, { oldText: '', newText: 'B' }]);
  edit('no-change', 'alpha', one('alpha', 'alpha'));
  edit('multi-no-change', 'alpha beta', [{ oldText: 'alpha', newText: 'alpha' }, { oldText: 'beta', newText: 'beta' }]);
  edit('delete', 'alpha\nbeta\n', one('alpha\n', ''));
  edit('line-endings', 'alpha\r\nbeta\rgamma\n', one('alpha\r\nbeta\r', 'ALPHA\r\nBETA\r'));
  edit('utf16-emoji', '😀 start\n👩🏽‍💻 middle\n終 end\n', [{ oldText: '👩🏽‍💻', newText: '🚀' }, { oldText: '終', newText: 'finish' }]);
  edit('combining-exact', 'before e\u0301 after\n', one('e\u0301', 'x'));
  edit('combining-fuzzy', 'before e\u0301 after\n', one('é', 'x'));
  edit('canonical-no-change-is-byte-change', 'é\n', one('é', 'e\u0301'));
  edit('nfkc-ligature', 'keep ﬀ  \nﬃ target\nkeep  \n', one('ffi target', 'changed'));
  edit('fuzzy-quotes', '“alpha”\nuntouched ‘quote’  \n', one('"alpha"', '"ALPHA"'));
  edit('fuzzy-dashes', 'a—b\nuntouched – dash\n', one('a-b', 'a+B'));
  edit('fuzzy-spaces', 'a\u2002b\nkeep\u00a0 \n', one('a b', 'A B'));
  edit('fuzzy-trailing', 'alpha  \nbeta\t\nkeep  \n', one('alpha\nbeta', 'A\nB'));
  edit('fuzzy-preserve-duplicate-lines', 'same “quote”  \ntarget—one\nsame "quote"\n', one('target-one', 'target+one'));
  edit('mixed-exact-fuzzy', 'alpha\n“beta”\nkeep ﬃ  \n', [{ oldText: 'alpha', newText: 'ALPHA' }, { oldText: '"beta"', newText: 'BETA' }]);
  edit('normalized-duplicates', '“alpha”\n"alpha"\n', one('“alpha”', 'beta'));
  edit('same-line-fuzzy', 'x—y and a—b\nkeep  \n', [{ oldText: 'x-y', newText: 'X' }, { oldText: 'a-b', newText: 'A' }]);
  edit('fuzzy-no-change', '“alpha”\n', one('"alpha"', '“alpha”'));
  edit('js-trim-whitespace', 'alpha\uFEFF\u2028\u2029\t\nkeep\u0085\n', one('alpha\n', 'A\n'));
  edit('fuzzy-empty-target', 'a b\n', one('\t', 'X'));
  const diffs = [];
  function diff(name, oldContent, newContent, contextLines = 4, path = 'fixture.txt') {
    const display = upstream.generateDiffString(oldContent, newContent, contextLines);
    const patch = upstream.generateUnifiedPatch(path, oldContent, newContent, contextLines);
    const patch804 = compatible.createTwoFilesPatch(path, path, oldContent, newContent, undefined, undefined,
      { context: contextLines, headerOptions: compatible.FILE_HEADERS_ONLY });
    if (patch !== patch804) throw new Error(`diff release patch change: ${name}`);
    diffs.push({ name, path, oldContent, newContent, contextLines, diff: display.diff,
      firstChangedLine: display.firstChangedLine ?? null, patch });
  }
  for (const row of edits) if (row.result) diff(`edit-${row.name}`, row.result.baseContent, row.result.newContent);
  for (const [name, oldContent, newContent] of [
    ['empty', '', ''], ['add-empty', '', 'a\n'], ['remove-empty', 'a\n', ''], ['same', 'a\nb\n', 'a\nb\n'],
    ['eof-replace', 'a', 'b'], ['eof-add', 'a\n', 'a'], ['eof-remove', 'a', 'a\n'],
    ['blank-lines', '\n\n\na\n', '\n\nb\n'], ['duplicate-tie', 'a\nb\na\nb\n', 'b\na\nb\na\n'],
    ['crlf', 'a\r\nb\r\n', 'a\r\nc\r\n'], ['cr', 'a\rb\r', 'a\rc\r'],
    ['combining', 'é\n', 'e\u0301\n'], ['unicode', '😀\n👩🏽‍💻\n', '😀\n🚀\n'],
    ['line-width', Array.from({ length: 18 }, (_, i) => `${i}\n`).join(''), Array.from({ length: 18 }, (_, i) => `${i === 8 ? 'changed' : i}\n`).join('')],
    ['separate-hunks', Array.from({ length: 35 }, (_, i) => `${i}\n`).join(''), Array.from({ length: 35 }, (_, i) => `${[2, 30].includes(i) ? 'changed' : i}\n`).join('')],
    ['join-hunks', Array.from({ length: 20 }, (_, i) => `${i}\n`).join(''), Array.from({ length: 20 }, (_, i) => `${[2, 9].includes(i) ? 'changed' : i}\n`).join('')],
  ]) for (const context of [0, 1, 4]) diff(`${name}-context-${context}`, oldContent, newContent, context);
  for (const path of ['space name.txt', 'tab\tname.txt', '日本😀.txt', 'line\nname.txt']) diff(`path-${JSON.stringify(path)}`, 'a\n', 'b\n', 4, path);
  // A fixed seed exercises repeated lines and Myers path ties. No clocks or random IDs.
  let seed = 0x1a2b3c4d;
  function next() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed; }
  const tokens = ['a\n', 'b\n', '\n', 'é\n', 'e\u0301\n', '😀\n', 'x\r\n'];
  for (let index = 0; index < 256; index++) {
    const text = () => Array.from({ length: next() % 15 }, () => tokens[next() % tokens.length]).join('') + (next() % 3 === 0 ? 'tail' : '');
    diff(`seeded-${index}`, text(), text(), [0, 1, 4][index % 3]);
  }
  const normalization = ['a\r\nb\rc\n', 'ﬃ “x”—y\u00a0 \nkeep\t\n', '\uFEFFalpha\r\n', 'alpha\nsecond\r\n', '', 'x\u0085\n', 'x\uFEFF\u2028\u2029\t\n'].map(content => {
    const stripped = upstream.stripBom(content);
    const ending = upstream.detectLineEnding(stripped.text);
    return { content, bom: stripped.bom, text: stripped.text, ending, normalized: upstream.normalizeToLF(stripped.text),
      fuzzy: upstream.normalizeForFuzzyMatch(stripped.text), restored: upstream.restoreLineEndings(upstream.normalizeToLF(stripped.text), ending) };
  });
  const fixture = JSON.stringify({ tag: upstreamTag, diffVersion: '8.0.3', compatibleDiffVersion: '8.0.4', edits, diffs, normalization,
    counts: { edits: edits.length, diffs: diffs.length, normalization: normalization.length } }, null, 2) + '\n';
  const path = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/edit-fixtures.json', import.meta.url));
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== fixture) throw new Error('Edit fixtures differ. Run this script without --check.');
    console.log(`Edit fixtures match: ${edits.length} edit cases, ${diffs.length} diff cases, ${normalization.length} normalization cases. diff 8.0.3 and 8.0.4 outputs match.`);
  } else {
    await mkdir(fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/', import.meta.url)), { recursive: true });
    await writeFile(path, fixture);
    console.log(`Wrote edit fixtures: ${edits.length} edit cases, ${diffs.length} diff cases, ${normalization.length} normalization cases.`);
  }
} finally { await source.close(); await rm(directory, { recursive: true, force: true }); }
