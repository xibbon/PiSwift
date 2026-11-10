// Read schema source from the pinned local Git tag. Never use the working tree.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

export function extractTaggedSchema(repo) {
  const temp = mkdtempSync(resolve(tmpdir(), 'pi-schema-'));
  try {
    const commit = execFileSync('git', ['-C', repo, 'rev-parse', 'v1.5.2^{commit}'], { encoding: 'utf8' }).trim();
    const archive = execFileSync('git', ['-C', repo, 'archive', 'v1.5.2', 'packages/schema'], { maxBuffer: 64 * 1024 * 1024 });
    execFileSync('tar', ['-x', '-C', temp], { input: archive });
    return { commit, base: resolve(temp, 'packages/schema'), dispose: () => rmSync(temp, { recursive: true, force: true }) };
  } catch (error) {
    rmSync(temp, { recursive: true, force: true });
    throw error;
  }
}
