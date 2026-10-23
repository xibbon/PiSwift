// Keep every chord fixture within the shared decimal 3 MB limit.
import { readdirSync, readFileSync } from 'node:fs';

export function assertFixtureBudget(replacements) {
  const directory = new URL('../../Tests/PiSwiftChordTests/Fixtures/', import.meta.url);
  const names = new Set([...readdirSync(directory), ...Object.keys(replacements)]);
  let bytes = 0;
  for (const name of names) bytes += Object.hasOwn(replacements, name)
    ? Buffer.byteLength(replacements[name], 'utf8') : readFileSync(new URL(name, directory)).length;
  if (bytes > 3_000_000) throw new Error(`Fixture budget exceeded: ${bytes} bytes`);
  return bytes;
}
