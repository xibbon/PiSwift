#!/usr/bin/env node
// Run the naming code from the tag. Do not use the upstream worktree.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const directory = dirname(fileURLToPath(import.meta.url));
const repo = resolve(directory, '../../../pi-mono');
const tag = 'v1.5.2';
const sourcePath = 'packages/mcp/src/naming.ts';
const source = execFileSync('git', ['-C', repo, 'show', `${tag}:${sourcePath}`], { encoding: 'utf8' });
const commit = execFileSync('git', ['-C', repo, 'rev-parse', `${tag}^{commit}`], { encoding: 'utf8' }).trim();
const temp = mkdtempSync(join(tmpdir(), 'pi-mcp-naming-'));
try {
  const module = join(temp, 'naming.ts');
  writeFileSync(module, source);
  const { createMcpToolName, mcpNamespace } = await import(pathToFileURL(module));
  const vectors = [];
  const add = (id, server, tool, taken = false) => vectors.push({ id, server, tool, taken });
  for (const [server, tool] of [['docs','search'], ['my-server','get.item/v2'], ['my_server','a_b'],
    ['s','a-b'], ['s','a_b'], ['s','a.b'], ['s','a/b'], ['s','a b'], ['s','a:b'],
    ['S_09','T_09'], ['',''], ['','search'], ['docs',''], ['123','456'],
    ['é','café'], ['docs','😀'], ['docs','👩‍💻'], ['docs','e\u0301'], ['日本','検索'],
    ['docs','\n\t'], ['docs','\\quote"'], ['a__b','c__d'], ['a-b','c-d']]) {
    add(`plain-${vectors.length}`, server, tool);
    add(`taken-${vectors.length}`, server, tool, true);
  }
  for (const length of [0, 1, 51, 52, 53, 54, 55, 63, 64, 65, 100]) {
    add(`boundary-${length}`, 's', 'x'.repeat(length));
  }
  add('long-server', 's'.repeat(100), 'read');
  add('same-head-a', 'server', 'x'.repeat(100) + 'a');
  add('same-head-b', 'server', 'x'.repeat(100) + 'b');
  add('raw-hash-hyphen', 'ser-ver', 'x'.repeat(100));
  add('raw-hash-underscore', 'ser_ver', 'x'.repeat(100));
  add('astral-boundary', 's', 'x'.repeat(54) + '😀');
  const cases = vectors.map(row => ({ ...row,
    name: createMcpToolName(row.server, row.tool, () => row.taken), namespace: mcpNamespace(row.server) }));
  if (cases.length < 40) throw Error('Need at least 40 cases');
  const output = JSON.stringify({ tag, commit, sourcePath, cases }, null, 2) + '\n';
  const destination = join(directory, 'naming-v1.5.2.json');
  if (process.argv.includes('--check')) {
    if (readFileSync(destination, 'utf8') !== output) throw Error('Naming fixture differs');
  } else writeFileSync(destination, output);
  console.log(`Checked ${cases.length} naming cases from ${tag}`);
} finally { rmSync(temp, { recursive: true, force: true }); }
