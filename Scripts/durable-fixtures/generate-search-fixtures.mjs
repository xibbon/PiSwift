// Generate expected values from the unmodified upstream tag.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const path = new URL('../../Tests/PiSwiftDurableTests/Fixtures/search-v130.json', import.meta.url);
const source = await mirror();
try {
  const { tokenize, rankDocuments } = await source.import('packages/durable/src/search.ts');
  const inputs = [
    '', '   -- 💡 ', 'a an and are as at be by for from in is it of on or that the this to with',
    'getIssue HTTPServer XMLHTTPRequest readJSON2File issue42Count',
    'github_get_issue foo-bar.baz/QUX 123 1A aB ABCd',
    'issues searches churches wishes classes boxes quizzes parties cities ties gas bus news glass',
    'İ K İssue Kelvin fooKBar FOOİBar Straße CAFÉ naïve 東京',
    'I\u0307 i\u0307 K\u212A ABCKTest \u{10400} Foo\u{10428}Bar',
    'THE Issues WITH repositories and SearchTools',
  ];
  const documentSets = {
    empty: [],
    blank: [{ name: 'empty', text: '' }, { name: 'stop', text: 'the and with' }],
    tools: [
      { name: 'issue', text: 'github_get_issue Get a GitHub issue by number' },
      { name: 'repos', text: 'github_list_repos List repositories of a user' },
      { name: 'weather', text: 'weather forecast rain temperature' },
    ],
    scoring: [
      { name: 'short', text: 'alpha' }, { name: 'frequency', text: 'alpha alpha alpha' },
      { name: 'long', text: 'alpha beta gamma delta epsilon zeta eta theta' },
      { name: 'rare', text: 'beta unique' }, { name: 'none', text: '' },
    ],
    ties: [{ name: 'z', text: 'same token' }, { name: 'a', text: 'same token' }, { name: 'm', text: 'same token' }],
    unicode: [{ name: 'kelvin', text: 'Kelvin' }, { name: 'dotted', text: 'İssue' }, { name: 'ascii', text: 'issue' }],
  };
  const probes = [
    ['empty', 'alpha', 8], ['blank', 'alpha', 8], ['tools', '', 8], ['tools', 'the and', 8],
    ['tools', 'github issue', 1], ['tools', 'repositories', 8], ['tools', 'weather forecast', 8],
    ['tools', 'unknown', 8], ['tools', 'issue issue issue github', 8], ['tools', 'issue github', 8],
    ['tools', 'github', 0], ['tools', 'github', -1], ['tools', 'github', 99],
    ['scoring', 'alpha', 8], ['scoring', 'beta unique', 8], ['scoring', 'alpha beta', 2],
    ['ties', 'same', 8], ['ties', 'same', 2], ['unicode', 'kelvin', 8], ['unicode', 'İssue', 8],
  ];
  const fixture = {
    tag: upstreamTag,
    tokens: inputs.map(text => ({ text, expected: tokenize(text) })),
    rankings: probes.map(([set, query, limit]) => ({ set, query, limit, documents: documentSets[set], expected: rankDocuments(query, documentSets[set], limit) })),
  };
  const encoded = JSON.stringify(fixture, null, 2) + '\n';
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== encoded) throw new Error('Search fixture differs from upstream');
  } else await writeFile(path, encoded);
  console.log(`Search fixture: ${fixture.tokens.length} token cases, ${fixture.rankings.length} ranking cases, ${upstreamTag}.`);
} finally { await source.close(); }
