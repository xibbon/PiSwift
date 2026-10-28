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
const source = await mirror({ dependencies: ['typebox@1.3.27'] });
const cwd = await mkdtemp(join(tmpdir(), 'piswift-read-oracle-'));
try {
    // Only the isolated mirror receives this dependency. Upstream source remains unchanged.
    const upstream = execFileSync('git', ['-C', upstreamRepository, 'show', `${upstreamTag}:packages/durable/test/tools-read-differential.test.ts`], { encoding: 'utf8' });
    const reference = stripTypeScriptTypes(upstream.slice(upstream.indexOf('function referenceRead('), upstream.indexOf('function apiFor(')));
    const url = path => pathToFileURL(join(source.directory, path)).href;
    const modulePath = join(source.directory, 'read-reference.mjs');
    await writeFile(modulePath, `import { detectSupportedImageMimeType } from '${url('packages/durable/src/tools/image.ts')}';\nimport { DEFAULT_MAX_BYTES, formatSize, truncateHead } from '${url('packages/durable/src/truncate.ts')}';\nimport { characterEnd } from '${url('packages/chord/src/output.ts')}';\n${reference}\nexport { referenceRead, random, randomFile, OFFSETS, LIMITS };\n`);
    const { referenceRead, random, randomFile, OFFSETS, LIMITS } = await import(pathToFileURL(modulePath).href);
    const { NodeExecutionEnv } = await source.import('packages/durable/src/env/node.ts');
    const { createReadTool } = await source.import('packages/durable/src/tools/read.ts');
    const { BACKGROUND_CONTEXT } = await source.import('packages/chord/src/context/index.ts');
    const env = new NodeExecutionEnv({ cwd });
    const api = { env, output() {}, diagnostic() {}, async details() {}, async agent() { return {}; } };
    const tool = createReadTool();
    const outcome = async run => { try { return JSON.parse(JSON.stringify(await run())); } catch (error) { return { error: error.message }; } };
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
    // Read results come from the tag's tool. Use the tag's GIF and BMP builders without changes.
    const imageTests = execFileSync('git', ['-C', upstreamRepository, 'show', `${upstreamTag}:packages/durable/test/tools-images.test.ts`], { encoding: 'utf8' });
    const builders = stripTypeScriptTypes(imageTests.slice(imageTests.indexOf('function bmp('), imageTests.indexOf('/** A TIFF header')));
    const webpStart = imageTests.indexOf('const webp =', imageTests.indexOf('describe("imageDimensions"'));
    const webpBuilder = stripTypeScriptTypes(imageTests.slice(webpStart, imageTests.indexOf('// VP8:', webpStart)));
    const builderPath = join(source.directory, 'image-builders.mjs');
    await writeFile(builderPath, `${builders}\n${webpBuilder}\nexport { bmp, gif, webp };\n`);
    const { bmp, gif, webp } = await import(pathToFileURL(builderPath).href);
    // A fixed PNG header fixture; read checks dimensions and does not decode pixels.
    const png = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg==', 'base64'));
    // Keep the differential test's APNG bytes and its whole-file reference.
    const apngStart = upstream.indexOf('const chunk =', upstream.indexOf('detects animated PNGs'));
    const apngSource = stripTypeScriptTypes(upstream.slice(apngStart, upstream.indexOf('writeFileSync', apngStart)));
    const apngPath = join(source.directory, 'apng-builder.mjs');
    await writeFile(apngPath, `${apngSource}\nexport { png };\n`);
    const { png: apng } = await import(pathToFileURL(apngPath).href);
    const prepared = { data: 'AQID', mimeType: 'image/png' };
    const specs = [
        { name: 'apng-beyond-header', path: 'a.png', bytes: apng, wholeFileReference: true },
        { name: 'png-inline', path: 'a.png', bytes: png },
        { name: 'jpeg-inline', path: 'a.jpg', bytes: Uint8Array.from([255, 216, 255, 192, 0, 17, 8, 0, 5, 0, 7]) },
        { name: 'webp-vp8-inline', path: 'a.webp', bytes: webp('VP8 ', [0, 0, 0, 0x9d, 0x01, 0x2a, 0x2c, 0x01, 0xc8, 0x00]) },
        { name: 'webp-vp8l-inline', path: 'a.webp', bytes: webp('VP8L', [0x2f, 43, 193, 49, 0]) },
        { name: 'webp-vp8x-inline', path: 'a.webp', bytes: webp('VP8X', [0, 0, 0, 0, 0x2b, 0x01, 0, 0xc7, 0, 0]) },
        { name: 'gif-inline', path: 'a.gif', bytes: gif() },
        { name: 'gif-wide', path: 'wide.gif', bytes: gif(2001, 2) },
        { name: 'gif-tall', path: 'tall.gif', bytes: gif(1, 3000) },
        { name: 'bmp-needs-conversion', path: 'a.bmp', bytes: bmp(4, 4) },
        { name: 'jpeg-size-unreadable', path: 'broken.jpg', bytes: Uint8Array.from([255, 216, 255]) },
        { name: 'model-width-limit', path: 'a.gif', bytes: gif(8, 6), model: { resize: { maxWidth: 4 } } },
        { name: 'model-height-limit', path: 'a.gif', bytes: gif(8, 6), model: { resize: { maxHeight: 4 } } },
        { name: 'model-byte-limit', path: 'a.png', bytes: png, model: { resize: { maxBytes: 8 } } },
        { name: 'model-byte-boundary', path: 'a.gif', bytes: gif(), model: { resize: { maxBytes: Buffer.from(gif()).toString('base64').length } } },
        { name: 'text-only-model', path: 'a.png', bytes: png, model: { input: ['text'] } },
        { name: 'unresolved-model', path: 'a.png', bytes: png, model: null },
        { name: 'processor-pass-through', path: 'a.gif', bytes: gif(), processor: { result: { data: Buffer.from(gif()).toString('base64'), mimeType: 'image/gif' } } },
        { name: 'processor-conversion', path: 'a.bmp', bytes: bmp(4, 4), processor: { result: { ...prepared, convertedFrom: 'image/bmp' } } },
        { name: 'processor-resize', path: 'wide.gif', bytes: gif(4000, 1000), processor: { result: { ...prepared, resized: { from: { width: 4000, height: 1000 }, to: { width: 2000, height: 500 } } } } },
        { name: 'processor-resize-half-up', path: 'a.gif', bytes: gif(9, 6), processor: { result: { ...prepared, resized: { from: { width: 9, height: 6 }, to: { width: 8, height: 5 } } } } },
        { name: 'processor-model-limits', path: 'a.gif', bytes: gif(8, 6), model: { resize: { maxWidth: 4, maxHeight: 3, maxBytes: 64 } }, processor: { result: prepared } },
        { name: 'processor-conversion-resize-placeholder', path: 'a.bmp', bytes: bmp(4, 4), model: { input: ['text'] }, processor: { result: { ...prepared, convertedFrom: 'image/bmp', resized: { from: { width: 4, height: 4 }, to: { width: 3, height: 3 } } } } },
        { name: 'processor-refuses', path: 'a.png', bytes: png, processor: { result: null } },
        { name: 'processor-throws', path: 'a.png', bytes: png, processor: { error: 'processor failed' } },
    ];
    const imageCases = [];
    for (const spec of specs) {
        await writeFile(join(cwd, spec.path), spec.bytes);
        const calls = [];
        const images = spec.processor === undefined ? undefined : { async prepare(bytes, mimeType, limits) {
            calls.push({ base64: Buffer.from(bytes).toString('base64'), mimeType, limits });
            if (spec.processor.error) throw new Error(spec.processor.error);
            return spec.processor.result ?? undefined;
        } };
        const imageApi = { ...api, async agent() { return spec.model === undefined ? {} : { model: { provider: 'test', modelId: 'test' } }; },
            models: { getModel() { return spec.model === null ? undefined : { input: spec.model?.input ?? ['text', 'image'], inputLimits: { images: { resize: spec.model?.resize } } }; } } };
        const actual = await outcome(() => createReadTool({ images }).execute({ path: spec.path }, imageApi, BACKGROUND_CONTEXT));
        const { bytes, ...parameters } = spec;
        const expected = spec.wholeFileReference ? await outcome(() => referenceRead(bytes, spec.path, undefined, undefined)) : undefined;
        imageCases.push({ ...parameters, ...(expected === undefined ? {} : { expected }), base64: Buffer.from(bytes).toString('base64'), actual, calls });
    }
    const descriptions = { withoutProcessor: createReadTool().description, withProcessor: createReadTool({ images: { async prepare() {} } }).description };
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
    const fixture = JSON.stringify(pack({ tag: upstreamTag, provenance: { source: 'unmodified isolated git archive', resultEnvelope: 'unmodified top-level output', images: { source: 'packages/durable/src/tools/read.ts', tests: 'packages/durable/test/tools-images.test.ts', builders: 'unmodified bmp and gif functions, webp builder; unmodified APNG chunk and png declarations from tools-read-differential.test.ts', png: 'fixed one-pixel header fixture', jpeg: 'synthetic SOF header; dimensions from image.ts', processor: 'scripted ImageProcessor; calls and results recorded from the tag tool' } }, seeds: 400, trialsPerSeed: 4, differences, files, imageCases, descriptions })).replaceAll('\uFEFF', '\\uFEFF') + '\n';
    const path = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/read-differential-v140.json', import.meta.url));
    if (process.argv.includes('--check')) {
        if (await readFile(path, 'utf8') !== fixture) throw new Error('Read fixtures differ. Run without --check.');
    } else { await writeFile(path, fixture); }
    console.log(`Read fixtures: 400 seeds, 1600 trials, ${differences} upstream reference differences, ${imageCases.length} image cases.`);
} finally { await rm(cwd, { recursive: true, force: true }); await source.close(); }
