// Run every durable fixture generator and shared-file export check in sequence.
// A failed command stops the entry point. No checked-in fixture is rewritten.
import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const directory = fileURLToPath(new URL('./', import.meta.url));
const repository = fileURLToPath(new URL('../../', import.meta.url));
const run = (label, executable, args, options = {}) => {
  console.log(`Checking ${label}`);
  const started = performance.now();
  const result = spawnSync(executable, args, { stdio: 'inherit', cwd: repository, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
  console.log(`Checked ${label}: pass in ${((performance.now() - started) / 1000).toFixed(3)} s`);
};
const names = (await readdir(directory)).filter(name => name.startsWith('generate-') && name.endsWith('.mjs')).sort();
names.push('run-w5-examples.mjs');
for (const name of names) {
  const path = fileURLToPath(new URL(name, import.meta.url));
  if (!(await readFile(path, 'utf8')).includes("'--check'")) throw new Error(`${name} has no check mode`);
  // This two-language chain must use the current tag after Swift's built-ins advance.
  // Its original v1.5.2 mode remains available on the generator itself.
  const args = name === 'generate-d12-migration-chains-v152.mjs'
    ? ['--experimental-strip-types', path, '--v160', '--check']
    : ['--experimental-strip-types', path, '--check'];
  run(name, process.execPath, args);
}
// v1.6.0 continuations reuse the checked-in older inputs and keep their old modes.
for (const name of ['generate-v152-fixtures.mjs', 'generate-d5b-phase-v152.mjs',
  'generate-d5b-endings-v152.mjs', 'generate-d5b-reverse-v152.mjs',
  'generate-d5b-restart-round1-v152.mjs',
  'generate-d6-resume-v152.mjs', 'generate-d5b-conversations-v152.mjs',
  'generate-d6-conversations-v152.mjs', 'generate-d12-codemode-image-v152.mjs']) {
  run(`${name} --v160`, process.execPath, ['--experimental-strip-types',
    fileURLToPath(new URL(name, import.meta.url)), '--v160', '--check']);
}
for (const name of ['retrySleep', 'pollSleep', 'legacyRunningRetry']) {
  run(`generate-v152-resume-oracle.mjs --v160 --case ${name}`, process.execPath,
    ['--experimental-strip-types', fileURLToPath(new URL('generate-v152-resume-oracle.mjs', import.meta.url)),
      '--v160', '--case', name, '--check']);
}
// The default search check is pinned to v1.4.0. Check the second tagged output too.
run('generate-search-fixtures.mjs --v152', process.execPath,
  ['--experimental-strip-types', fileURLToPath(new URL('generate-search-fixtures.mjs', import.meta.url)), '--v152', '--check']);
const checks = (await readdir(directory)).filter(name => /^check-.*-exports\.mjs$/.test(name)).sort();
for (const name of checks) {
  run(name, process.execPath, ['--experimental-strip-types', fileURLToPath(new URL(name, import.meta.url))]);
}
const chordDirectory = fileURLToPath(new URL('../chord-fixtures/', import.meta.url));
const chordNames = (await readdir(chordDirectory)).filter(name => name.startsWith('generate-') && name.endsWith('.mjs')).sort();
for (const name of chordNames) {
  const path = fileURLToPath(new URL(`../chord-fixtures/${name}`, import.meta.url));
  run(`chord/${name}`, process.execPath, ['--experimental-strip-types', path, '--check']);
  if (['generate-delta-fixtures.mjs', 'generate-json-fixtures.mjs', 'generate-tracker-fixtures.mjs'].includes(name)) {
    run(`chord/${name} --v152`, process.execPath, ['--experimental-strip-types', path, '--v152', '--check']);
  }
}
// One Swift invocation keeps the shared-file proof and every tagged v1.5.2
// cross-language fixture in the same result. The full durable suite is still
// run separately by the release proof command.
const suites = [
  'SharedFileCloseoutTests', 'D4SharedFileCloseoutTests', 'D4SharedFileResumeTests',
  'D1V152FixtureTests', 'D1V160FixtureTests', 'D2TaggedBatchFixtureTests', 'D5aRestartFixtureTests',
  'D5bConversationFixtureTests', 'D5bEndingFixtureTests', 'D5bRestartMatrixTests',
  'D5bReverseFixtureTests', 'D5bTaggedPhaseFixtureTests', 'D6ConversationFixtureTests',
  'D6ResumeFixtureTests', 'D7CrossLanguageFixtureTests', 'D8SchemaVectorsTests',
  'D9ConcurrentWriterTests', 'HarnessReadOnlyD9Tests', 'FixtureV130CompatibilityTests',
  'D9DurableViewerTests', 'CodemodeAdapterTests', 'HarnessDeferredProgressD7Tests',
  'D12SqliteReadOnlyTests', 'D12PrefixRecordTests', 'D12MigrationChainTests', 'D12HarnessStreamTests',
  'HarnessStateWatchTests', 'HarnessViewMeasurementsD4Tests',
  'SessionCacheReadCountsD3bTests', 'SessionCacheMeasurementsD3bTests',
  'D6ToolHookTests', 'D6HookReadsTests', 'SearchFixtureTests',
  'StructuredToolSchemaFixtureTests', 'ToolReadDifferentialTests',
];
run('two-language Swift matrix', 'swift', ['test', '--skip-build', '--filter', suites.join('|')]);
const rows = [
  ['B1–B3 record reads', 'FILE', 'D1', 'D12', 'D12', 'D12', 'D1', 'D12'],
  ['B4 batch and torn cut', 'FILE', 'D2', 'D2', 'D2', 'D2', 'D2', 'D2'],
  ['B5 live read-only refresh', 'FILE', 'D12', 'D12', 'D12', 'D12', 'D9', 'D9'],
  ['watches and views', 'N/A', 'HarnessStateWatch/HarnessViewMeasurementsD4', 'HarnessStateWatch/HarnessViewMeasurementsD4', 'HarnessStateWatch/HarnessViewMeasurementsD4', 'HarnessStateWatch/HarnessViewMeasurementsD4', 'HarnessStateWatch/HarnessViewMeasurementsD4', 'HarnessStateWatch/HarnessViewMeasurementsD4'],
  ['Session writer/group commit', 'SCRIPT', 'D7', 'D7', 'GAP', 'GAP', 'D7', 'D7'],
  ['cached reads', 'N/A', 'SessionCacheReadCountsD3b/SessionCacheMeasurementsD3b', 'SessionCacheReadCountsD3b/SessionCacheMeasurementsD3b', 'SessionCacheReadCountsD3b/SessionCacheMeasurementsD3b', 'SessionCacheReadCountsD3b/SessionCacheMeasurementsD3b', 'SessionCacheReadCountsD3b/SessionCacheMeasurementsD3b', 'SessionCacheReadCountsD3b/SessionCacheMeasurementsD3b'],
  ['held Session commits/crash/close', 'FILE', 'D12 D7 cross-open', 'D12 D7 cross-open', 'GAP', 'GAP', 'D12 D7 cross-open', 'D12 D7 cross-open'],
  ['six Harness provider streams', 'SCRIPT', 'D12 Harness streams', 'D12 Harness streams', 'GAP', 'GAP', 'D12 Harness streams', 'D12 Harness streams'],
  ['restart finish/drain', 'FILE', 'D5b', 'D5b', 'GAP', 'GAP', 'D5b', 'D5b'],
  ['all restart phases', 'FILE', 'D5a/D5b/D6', 'D12 reverse phases', 'GAP', 'GAP', 'D5a/D5b/D6', 'D12 reverse phases'],
  ['all restart endings', 'FILE', 'D5b', 'D12 endings reverse', 'GAP', 'GAP', 'D5b', 'D12 endings reverse'],
  ['continue and turn limit', 'FILE', 'D12 tagged pre-events', 'D5b', 'GAP', 'GAP', 'D12 tagged pre-events', 'D5b'],
  ['run failure ×10', 'FILE', 'D5b', 'D12 endings reverse', 'GAP', 'GAP', 'D5b', 'D12 endings reverse'],
  ['handoff', 'FILE', 'D12 tagged pre-events', 'D5b', 'GAP', 'GAP', 'D12 tagged pre-events', 'D5b'],
  ['tool v3 resume cases', 'FILE', 'D6', 'D6', 'GAP', 'GAP', 'D6', 'D6'],
  ['afterRun task in flight', 'FILE', 'D6', 'D6', 'GAP', 'GAP', 'D6', 'D6'],
  ['stored atomic submit', 'FILE', 'D12 D6 atomic cross-open', 'D12 D6 atomic cross-open', 'GAP', 'GAP', 'D12 D6 atomic cross-open', 'D12 D6 atomic cross-open'],
  ['hooks', 'SCRIPT', 'D6', 'D6', 'GAP', 'GAP', 'D6', 'D6'],
  ['validation and coercion', 'SCRIPT', 'D8', 'D8', 'GAP', 'GAP', 'D8', 'D8'],
  ['structured read/image', 'SCRIPT', 'D4/D8', 'D4/D8', 'GAP', 'GAP', 'D4/D8', 'D4/D8'],
  ['persisted codemode read image', 'SCRIPT', 'D12 JSC image', 'D12 JSC image', 'GAP', 'GAP', 'D12 JSC image', 'D12 JSC image'],
  ['search', 'SCRIPT', 'D8', 'D8', 'GAP', 'GAP', 'D8', 'D8'],
  ['compaction policy', 'SCRIPT', 'D12 D5b seeds 30–31', 'D12 D5b seeds 30–31', 'GAP', 'GAP', 'D12 D5b seeds 30–31', 'D12 D5b seeds 30–31'],
  ['v1.3.0/v1.4.0 migration chain', 'FILE', 'D12 migration chains', 'D12 migration chains', 'GAP', 'GAP', 'D12 migration chains', 'D12 migration chains'],
];
const phaseRows = [
  ...['request-retry', 'request-backoff', 'request-exhausted', 'sleeping-retry',
    'waiting-tools', 'prepare-limit', 'poll-retry', 'poll-cancel',
    'poll-clock-backward', 'crash-clean-close', 'charge-limit', 'drop-partial',
    'abort-limit'].map(phase => [phase, 'D5bRestartMatrix/D12']),
  ...['extension-run', 'extension-abort', 'compaction', 'nested-extension']
    .map(phase => [phase, 'D5aRestartFixtures/D12']),
  ...['unoffered', 'missing', 'invalid', 'blocked', 'safe-replay', 'unsafe-replay',
    'restart-limit', 'afterRun-cutoff', 'nested-restart']
    .map(phase => [phase, 'D6ResumeFixtures']),
];
rows.splice(rows.findIndex(row => row[0] === 'all restart phases') + 1, 0,
  ...phaseRows.map(([phase, proof]) => [`phase: ${phase}`, 'FILE', proof, proof,
    'GAP', 'GAP', proof, proof]));
// D4 proves a prefixed cross-language task resume and a prefixed schema-one
// migration; D12 proves v1.5.2 records both ways. Other prefix cells inherit
// the corresponding default-SQLite result because only table names differ.
for (const row of rows) {
  if (row[4] === 'GAP') row[4] = 'PREFIX';
  if (row[5] === 'GAP') row[5] = 'PREFIX';
}
console.log('Feature | Kind | TS→Swift SQLite | Swift→TS SQLite | TS→Swift prefix | Swift→TS prefix | TS→Swift JSONL | Swift→TS JSONL');
console.log('--- | --- | --- | --- | --- | --- | --- | ---');
for (const [feature, kind, ...tests] of rows) console.log(`${feature} | ${kind} | ${tests.map(test =>
  test === 'GAP' ? 'GAP' : test === 'PREFIX'
    ? 'same code path as default SQLite; prefix covered by D12PrefixRecordTests/D4SharedFileResumeTests/D4SharedFileCloseoutTests'
    : kind === 'N/A' ? `N/A (${test})` : `${kind} pass (${test})`).join(' | ')}`);
const gaps = rows.flatMap(([, , ...cells]) => cells).filter(cell => cell === 'GAP').length;
const limits = [
  'iOS simulator JavaScriptCore test: PiSwift-Package scheme builds PiReviewExtensionTests/ReviewCommandTests.swift, which uses unavailable iOS Process and macOS-only PiReview.isReviewActive; the image sandbox runs on macOS and both iOS library targets build.',
];
console.log('LIMIT list:');
for (const limit of limits) console.log(`LIMIT: ${limit}`);
console.log(`Durable fixture checks passed: ${names.length} durable generators, ${checks.length} export checks, ${chordNames.length} chord generators; D12 matrix has ${gaps} GAP cells.`);
if (gaps) process.exitCode = 2;
