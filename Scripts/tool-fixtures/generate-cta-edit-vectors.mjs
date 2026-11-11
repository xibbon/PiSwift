// v1.5.2 C-TA: d448c51e2, edit-diff-window.test.ts:55-84.
// Read the tag with git show. Use an installed diff module. Do not write upstream.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir, homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const upstream = process.env.PI_MONO_ROOT ?? join(homedir(), "cvs/pi/pi-mono");
const scripts = dirname(fileURLToPath(import.meta.url));
const repo = resolve(scripts, "../..");
const target = join(repo, "Tests/PiSwiftCodingAgentTests/fixtures/cta-edit-vectors.json");
const scratch = mkdtempSync(join(tmpdir(), "cta-edit-vectors-"));
try {
  // The tag pins diff@8.0.4. Use the local npm cache, never the mutable upstream install.
  execFileSync("npm", ["install", "--offline", "--prefix", scratch, "--ignore-scripts", "--no-audit", "--no-fund", "diff@8.0.4"], {stdio: "ignore"});
  const require = createRequire(join(scratch, "package.json"));
  const diffURL = pathToFileURL(require.resolve("diff")).href;
  let source = execFileSync("git", ["show", "v1.5.2:packages/coding-agent/src/core/tools/edit-diff.ts"], {cwd: upstream, encoding: "utf8"});
  source = source.replace('import * as Diff from "diff";', `import * as Diff from ${JSON.stringify(diffURL)};`)
    .replace('import { splitBom } from "../../utils/text.ts";', 'const splitBom = (text: string) => ({text: text.startsWith("\uFEFF") ? text.slice(1) : text});')
    .replace('import { resolveToCwd } from "./path-utils.ts";', 'const resolveToCwd = (path: string, _cwd: string) => path;');
  const modulePath = join(scratch, "edit-diff.mts");
  const outputPath = join(scratch, "vectors.json");
  writeFileSync(modulePath, source);
  process.stdout.write(execFileSync(process.execPath, ["--experimental-strip-types", join(scripts, "generate-cta-edit-vectors-driver.mts"), modulePath, outputPath], {encoding: "utf8"}));
  const generated = readFileSync(outputPath);
  if (process.argv.includes("--check")) {
    if (!generated.equals(readFileSync(target))) throw new Error("Edit fixture differs from v1.5.2 output.");
    console.log("Edit fixture matches v1.5.2 byte for byte.");
  } else {
    writeFileSync(target, generated);
  }
} finally {
  rmSync(scratch, {recursive: true, force: true});
}
