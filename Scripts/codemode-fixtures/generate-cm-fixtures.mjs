// Generate C-CM expectations from the unmodified pi-mono v1.5.2 tag.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-strip-types')) {
  const run = spawnSync(process.execPath, ['--experimental-strip-types', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(run.status ?? 1);
}

const repo = '/Users/miguel/cvs/pi/pi-mono';
const root = fileURLToPath(new URL('../..', import.meta.url));
const destination = join(root, 'Tests/PiSwiftCodingAgentTests/fixtures/codemode-cm-v152.json');
const directory = await mkdtemp(join(tmpdir(), 'piswift-cm-v152-'));
try {
  const archive = execFileSync('git', ['-C', repo, 'archive', 'v1.5.2', 'packages/codemode/src', 'packages/coding-agent/src/extensions/tool-search/tool.ts'], { maxBuffer: 32 * 1024 * 1024 });
  execFileSync('tar', ['-x', '-C', directory], { input: archive });
  execFileSync('npm', ['install', '--prefix', directory, '--no-audit', '--no-fund', '--ignore-scripts', 'typebox@1.3.27'], { stdio: 'ignore' });
  const codemode = join(directory, 'packages/codemode');
  await writeFile(join(codemode, 'package.json'), JSON.stringify({ type: 'module', exports: { './declarations': './src/declarations.ts' } }));
  await mkdir(join(directory, 'node_modules/@earendil-works'), { recursive: true });
  await symlink(codemode, join(directory, 'node_modules/@earendil-works/pi-codemode'));
  const declarations = await import(pathToFileURL(join(codemode, 'src/declarations.ts')).href);
  const search = await import(pathToFileURL(join(directory, 'packages/coding-agent/src/extensions/tool-search/tool.ts')).href);

  const primitives = [{ type: 'string' }, { type: 'integer' }, { type: 'number' }, { type: 'boolean' }, { type: 'null' }, true, false];
  const schemas = [];
  const add = (name, schema) => schemas.push({ name, schema });
  for (let i = 0; i < 28; i++) {
    const a = primitives[i % primitives.length];
    const b = primitives[(i + 2) % primitives.length];
    add(`union_${i}`, i % 3 === 0 ? { anyOf: [a, b] } : i % 3 === 1 ? { oneOf: [a, b] } : { allOf: [a, b] });
    add(`object_${i}`, { type: 'object', properties: { [`item_${i}`]: { ...a, description: `Field ${i}` }, other: b }, required: i % 2 ? ['other'] : [`item_${i}`] });
    add(`array_${i}`, i % 2 ? { type: 'array', items: a } : { type: 'array', prefixItems: [a, b] });
    add(`enum_${i}`, { enum: [`value_${i}`, i, null] });
  }
  const refKeys = ['plain', 'a/b', 'a~b', 'space key', '%E0', '東京'];
  const refs = ['#', '#/$defs/plain', '#/$defs/a~1b', '#/$defs/a~0b', '#/$defs/space%20key', '#/$defs/%E0', '#/$defs/%ZZ', 'https://example.org/x', '#/$defs/missing', '#/definitions/old'];
  for (let i = 0; i < 24; i++) {
    const defs = Object.fromEntries(refKeys.map(key => [key, { type: 'object', properties: { value: { type: 'string' } } }]));
    add(`reference_${i}`, { $ref: refs[i % refs.length], $defs: defs, definitions: { old: { type: 'number' } } });
  }
  add('recursive', { $ref: '#/$defs/Node', $defs: { Node: { type: 'object', properties: { next: { $ref: '#/$defs/Node' } } } } });
  add('shared', { type: 'object', properties: { first: { $ref: '#/$defs/Item' }, second: { $ref: '#/$defs/Item' } }, $defs: { Item: { type: 'integer' } } });
  const declarationsRows = schemas.map(({ name, schema }) => {
    const tool = { name, description: `Tool ${name}`, inputSchema: schema, outputSchema: { type: 'string' } };
    return { name, schema, type: declarations.schemaToType(schema), signature: declarations.renderToolSignature(tool), sample: declarations.renderToolSample(tool), declaration: declarations.renderDeclarations({ tools: [tool] }) };
  });

  const words = ['screenshot', 'window', 'weather', 'forecast', 'file', 'read', 'issue', 'search', '東京', '工具', 'привет', 'café', 'naïve', 'alpha', 'beta', 'gamma'];
  const tools = Array.from({ length: 84 }, (_, i) => {
    const w = words[i % words.length];
    const next = words[(i * 5 + 3) % words.length];
    const name = i % 4 === 0 ? `mcp__group${i % 7}__${w}_${next}` : i % 4 === 1 ? `${w}${next[0].toUpperCase()}${next.slice(1)}${i}` : i % 4 === 2 ? `${w}_${next}_${i}` : `${w}-${next}-${i}`;
    return { name, description: `${w} ${next} tool ${i}.\nSecond line ${i}`, parameters: { type: 'object', properties: { [next]: { type: 'string', description: `Find ${w} ${next}` }, linked: { $ref: '#/$defs/Linked' } }, $defs: { Linked: { type: 'object', properties: { token: { type: 'string', description: `Linked ${w}` } } } } }, exposure: 'deferred', namespace: { name: `group${i % 7}`, description: `${w} operations`, instructions: `Use ${next} carefully.` } };
  });
  const queryWords = ['screenshot', 'window', 'weather forecast', 'file read', 'issue search', '東京', '工具', 'привет', 'café', 'naïve', 'alpha beta', 'gamma', 'linked', 'token', 'group1', 'find weather', 'screenshot window', 'tool 12'];
  const queries = Array.from({ length: 64 }, (_, i) => i % 8 === 0 ? tools[i].name : queryWords[i % queryWords.length]);
  const documents = tools.map(tool => search.createToolSearchDocument(tool, tool.namespace));
  const rankingRows = [];
  for (const [i, query] of queries.entries()) {
    const limit = i % 5 === 0 ? 3 : 8;
    const ranked = new search.Bm25Ranker().rank(query, documents, limit).map(row => row.name);
    let active = [];
    const api = { getAllTools: () => tools, getActiveTools: () => active, setActiveTools: names => { active = names; } };
    const output = await search.createToolSearchToolDefinition({ tools: api }).execute('fixture', { query, limit });
    rankingRows.push({ query, limit, names: ranked, text: output.content[0].text });
  }
  const fixture = { tag: 'v1.5.2', declarations: declarationsRows, tools, ranking: rankingRows };
  const encoded = JSON.stringify(fixture) + '\n';
  if (Buffer.byteLength(encoded) > 400_000) throw new Error('Fixture exceeds 400 KB');
  if (process.argv.includes('--check')) {
    if (await readFile(destination, 'utf8') !== encoded) throw new Error('C-CM fixture differs');
  } else await writeFile(destination, encoded);
  console.log(`C-CM fixture ${process.argv.includes('--check') ? 'matches' : 'written'}: ${declarationsRows.length} schemas, ${tools.length} tools, ${rankingRows.length} queries, ${Buffer.byteLength(encoded)} bytes.`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
