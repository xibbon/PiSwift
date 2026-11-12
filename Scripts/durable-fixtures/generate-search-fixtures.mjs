// Generate expected values from the unmodified upstream tag.
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}
const tag = process.argv.includes('--v152') ? 'v1.5.2' : upstreamTag;
const path = new URL(`../../Tests/PiSwiftDurableTests/Fixtures/search-${tag === 'v1.5.2' ? 'v152' : 'v140'}.json`, import.meta.url);
const source = await mirror({ tag });
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
    ...(tag === 'v1.5.2' ? ['搜索仓库问题', '文書を検索', 'ค้นหาเอกสาร', 'CAFÉ cafe\u0301', '搜索GitHub_repoIssues', '工具Screenshot9',
      '문서 검색', 'Поиск документов', 'البحث عن الملفات', 'फ़ाइल खोजें', ' \t，。!? 😀 '] : []),
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
    ...(tag === 'v1.5.2' ? { namespace: [
      { name: 'mcp__window__screenshot', text: 'capture image', namespaceText: 'window display controls' },
      { name: 'mcp__files__read', text: 'read file', namespaceText: 'files document controls' },
    ] } : {}),
  };
  const probes = [
    ['empty', 'alpha', 8], ['blank', 'alpha', 8], ['tools', '', 8], ['tools', 'the and', 8],
    ['tools', 'github issue', 1], ['tools', 'repositories', 8], ['tools', 'weather forecast', 8],
    ['tools', 'unknown', 8], ['tools', 'issue issue issue github', 8], ['tools', 'issue github', 8],
    ['tools', 'github', 0], ['tools', 'github', -1], ['tools', 'github', 99],
    ['scoring', 'alpha', 8], ['scoring', 'beta unique', 8], ['scoring', 'alpha beta', 2],
    ['ties', 'same', 8], ['ties', 'same', 2], ['unicode', 'kelvin', 8], ['unicode', 'İssue', 8],
    ...(tag === 'v1.5.2' ? [['namespace', 'window screenshot', 8], ['namespace', 'document read', 8]] : []),
  ];
  if (tag === 'v1.5.2') {
    const base = [
      { name: 'mcp__github__list_issues', text: 'List issues in a repository. state open or closed' },
      { name: 'mcp__github__create_pull_request', text: 'Open a pull request.' },
      { name: 'mcp__linear__search_issues', text: 'Search Linear issues by text.' },
      { name: 'mcp__docs__search', text: 'Search the documentation.' },
    ];
    documentSets.upstream = base;
    for (const query of ['issue', 'pull requests', 'search', 'closed', 'kubernetes', 'the', '未知']) probes.push(['upstream', query, 8]);
    const languages = [
      ['搜索仓库问题', '问题'], ['文書を検索', '検索'], ['문서 검색', '검색'],
      ['ค้นหาเอกสาร', 'เอกสาร'], ['Поиск документов', 'документов'],
      ['البحث عن الملفات', 'الملفات'], ['फ़ाइल खोजें', 'खोजें'],
      ['Rechercher un café', 'cafe\u0301'],
    ];
    languages.forEach(([text, query], i) => {
      documentSets[`language${i}`] = [...base, { name: 'localized', text }];
      probes.push([`language${i}`, query, 8]);
    });
    documentSets.exact = [
      { name: 'mcp__app__queue_read', text: 'Read a queued message of this thread.' },
      { name: 'mcp__dev-app__thread_read', text: 'Read durable state and a paginated timeline from any thread. The default view returns user messages, assistant messages and plans. Continue with afterPosition until hasMore is false.' },
    ];
    for (const query of ['thread_read', 'dev_app__thread_read', 'mcp__dev-app__thread_read', 'Thread_Read', 'read']) probes.push(['exact', query, 1]);
    documentSets.nameWeight = [
      { name: 'mcp__ci__status', text: 'Deploy status: last deploy, deploy log, deploy errors.' },
      { name: 'mcp__ci__deploy_release', text: 'Start a release of the current branch to an environment, run the migrations, switch traffic over, and wait until the new version is live and healthy.' },
    ];
    probes.push(['nameWeight', 'deploy', 1]);
    const peekaboo = 'mcp__peekaboo Peekaboo controls macOS apps by app name.';
    documentSets.wholeName = [
      { name: 'mcp__peekaboo__see', text: 'Capture the app window of the peekaboo app and describe the app.', namespaceText: peekaboo },
      { name: 'mcp__peekaboo__menu', text: 'Click a menu item of an app.', namespaceText: peekaboo },
      { name: 'mcp__peekaboo__app', text: 'Launch, quit, relaunch, focus, hide, or switch applications. Targets an application by name, bundle identifier, or process ID, and can wait until it is ready.', namespaceText: peekaboo },
      ...documentSets.exact,
    ];
    for (const query of ['peekaboo app', 'open the peekaboo app tool', 'read thread_read state', 'describe window']) probes.push(['wholeName', query, 1]);
    documentSets.coverage = [
      { name: 'mcp__peekaboo__app', text: 'Launch, quit, focus, or switch applications by name or bundle identifier.' },
      { name: 'mcp__peekaboo__see', text: 'Capture the app window and describe the UI elements of the app.' },
      { name: 'mcp__peekaboo__window', text: 'Move, resize, or close a window of an app.' },
      { name: 'mcp__peekaboo__image', text: 'Take a screenshot of the screen, an app, or a window.' },
    ];
    for (const query of ['screenshot window', 'describe app', 'window']) probes.push(['coverage', query, 1]);
  }
  const fixture = {
    tag,
    tokens: inputs.map(text => ({ text, expected: tokenize(text) })),
    rankings: probes.map(([set, query, limit]) => ({ set, query, limit, documents: documentSets[set], expected: rankDocuments(query, documentSets[set], limit) })),
  };
  const encoded = JSON.stringify(fixture, null, 2) + '\n';
  if (process.argv.includes('--check')) {
    if (await readFile(path, 'utf8') !== encoded) throw new Error('Search fixture differs from upstream');
  } else await writeFile(path, encoded);
  console.log(`Search fixture: ${fixture.tokens.length} token cases, ${fixture.rankings.length} ranking cases, ${tag}.`);
} finally { await source.close(); }
