// Generate the same 400 seeds and four trials as the upstream differential test.
// Store the real tool result and the whole-file reference result. Keep their differences visible.
import { execFileSync, spawnSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { mirror, upstreamRepository, upstreamTag } from './mirror.mjs';

if (!process.execArgv.includes('--experimental-strip-types')) {
    const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
    process.exit(run.status ?? 1);
}
const source = await mirror();
const cwd = await mkdtemp(join(tmpdir(), 'piswift-read-oracle-'));
try {
    // Only the isolated mirror receives this dependency. Upstream source remains unchanged.
    execFileSync('npm', ['install', '--prefix', source.directory, '--no-audit', '--no-fund', '--ignore-scripts', 'typebox@1.3.27'], { stdio: 'ignore' });
    const upstream = execFileSync('git', ['-C', upstreamRepository, 'show', `${upstreamTag}:packages/durable/test/tools-read-differential.test.ts`], { encoding: 'utf8' });
    const reference = stripTypeScriptTypes(upstream.slice(upstream.indexOf('function referenceRead('), upstream.indexOf('function apiFor(')));
    const url = path => pathToFileURL(join(source.directory, path)).href;
    const modulePath = join(source.directory, 'read-reference.mjs');
    await writeFile(modulePath, `import { detectSupportedImageMimeType } from '${url('packages/durable/src/tools/image.ts')}';\nimport { DEFAULT_MAX_BYTES, formatSize, truncateHead } from '${url('packages/durable/src/truncate.ts')}';\nimport { characterEnd } from '${url('packages/durable/src/harness/output.ts')}';\n${reference}\nexport { referenceRead, random, randomFile, OFFSETS, LIMITS };\n`);
    const { referenceRead, random, randomFile, OFFSETS, LIMITS } = await import(pathToFileURL(modulePath).href);
    const { NodeExecutionEnv } = await source.import('packages/durable/src/env/node.ts');
    const { createReadTool } = await source.import('packages/durable/src/tools/read.ts');
    const { BACKGROUND_CONTEXT } = await source.import('packages/chord/src/context/index.ts');
    const env = new NodeExecutionEnv({ cwd });
    const api = { env, output() {}, diagnostic() {}, async details() {} };
    const tool = createReadTool();
    const normalize = value => JSON.parse(JSON.stringify(value));
    const outcome = async run => { try { return normalize(await run()); } catch (error) { return { error: error.message }; } };
    const argument = value => value === undefined ? null : Number.isNaN(value) ? 'NaN' : value;
    const files = [];
    let differences = 0;
    for (let seed = 1; seed <= 400; seed++) {
        const next = random(seed);
        const bytes = randomFile(next);
        await writeFile(join(cwd, 'f.txt'), bytes);
        const trials = [];
        for (let trial = 0; trial < 4; trial++) {
            const offset = OFFSETS[Math.floor(next() * OFFSETS.length)];
            const limit = LIMITS[Math.floor(next() * LIMITS.length)];
            const actual = await outcome(() => tool.execute({ path: 'f.txt', ...(offset === undefined ? {} : { offset }), ...(limit === undefined ? {} : { limit }) }, api, BACKGROUND_CONTEXT));
            const expected = await outcome(() => referenceRead(bytes, 'f.txt', offset, limit));
            if (JSON.stringify(actual) !== JSON.stringify(expected)) differences++;
            trials.push({ offset: argument(offset), limit: argument(limit), actual, expected });
        }
        files.push({ seed, base64: Buffer.from(bytes).toString('base64'), trials });
    }
    function pack(value) {
        if (Array.isArray(value)) return value.map(pack);
        if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, pack(child)]));
        if (typeof value !== 'string' || value.length < 512) return value;
        const parts = [];
        let start = 0;
        for (const match of value.matchAll(/([\s\S]{1,512}?)\1{3,}/g)) {
            if (match.index > start) parts.push(value.slice(start, match.index));
            parts.push([match[0].length / match[1].length, match[1]]);
            start = match.index + match[0].length;
        }
        if (start < value.length) parts.push(value.slice(start));
        const packed = { $text: parts };
        return JSON.stringify(packed).length < value.length ? packed : value;
    }
    // Escape FEFF so parsers cannot treat a raw string segment as a byte-order mark.
    const fixture = JSON.stringify(pack({ tag: upstreamTag, seeds: 400, trialsPerSeed: 4, differences, files })).replaceAll('\uFEFF', '\\uFEFF') + '\n';
    const path = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/read-differential.json', import.meta.url));
    if (process.argv.includes('--check')) {
        if (await readFile(path, 'utf8') !== fixture) throw new Error('Read fixtures differ. Run without --check.');
    } else { await writeFile(path, fixture); }
    console.log(`Read fixtures: 400 seeds, 1600 trials, ${differences} upstream reference differences.`);
} finally { await rm(cwd, { recursive: true, force: true }); await source.close(); }
