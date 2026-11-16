// Differential fixtures for the v1.5.2 grep/find ignore behavior.
// grep argv: packages/coding-agent/src/core/tools/grep.ts:161-173.
// find argv: packages/coding-agent/src/core/tools/find.ts:186-202, 233-239.
// Run: node Scripts/tool-fixtures/ignore-matrix.mjs [--check]
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const destination = resolve(directory, "../../Tests/PiSwiftCodingAgentTests/fixtures/ignore-matrix.json");
const check = process.argv.includes("--check");

function version(binary) {
  const result = spawnSync(binary, ["--version"], { encoding: "utf8" });
  if (result.error?.code === "ENOENT" || result.error?.code === "EACCES") return null;
  if (result.status !== 0) throw new Error(`${binary} --version failed: ${result.stderr}`);
  return result.stdout.split("\n")[0];
}

// Builds of the same release print different suffixes ("ripgrep 15.2.0" from Homebrew,
// "ripgrep 15.2.0 (rev ...)" from a vendored binary): pin the release only.
const rgVersion = version("rg")?.match(/^ripgrep \d+\.\d+\.\d+/)?.[0] ?? null;
if (rgVersion !== "ripgrep 15.2.0") {
  throw new Error(`Expected ripgrep 15.2.0; got ${rgVersion ?? "missing"}`);
}
const fdBinary = version("fd") ? "fd" : version("fdfind") ? "fdfind" : null;
const fdVersion = fdBinary ? version(fdBinary) : null;

const baseFiles = {
  "root.txt": "needle\n",
  "drop.txt": "needle\n",
  "keep.txt": "needle\n",
  "sub/drop.txt": "needle\n",
  "sub/keep.txt": "needle\n",
  "sub/deep/drop.txt": "needle\n",
  "sub/deep/keep.txt": "needle\n",
  "sibling/drop.txt": "needle\n",
  "sibling/keep.txt": "needle\n",
  ".hidden/drop.txt": "needle\n",
};

const scenarios = [
  ["plain", {}],
  ["root-wildcard", { ".gitignore": "drop.txt\n" }],
  ["root-negation", { ".gitignore": "*.txt\n!keep.txt\n" }],
  ["root-directory", { ".gitignore": "sub/\n" }],
  ["root-directory-negation", { ".gitignore": "sub/\n!sub/keep.txt\n" }],
  ["root-anchored", { ".gitignore": "/drop.txt\n" }],
  ["root-path", { ".gitignore": "sub/drop.txt\n" }],
  ["nested-scope", { "sub/.gitignore": "drop.txt\n" }],
  ["nested-negation", { ".gitignore": "*.txt\n", "sub/.gitignore": "!keep.txt\n" }],
  ["deep-scope", { "sub/.gitignore": "drop.txt\n", "sub/deep/.gitignore": "keep.txt\n" }],
  ["ignore-source", { ".ignore": "drop.txt\n" }],
  ["rgignore-source", { ".rgignore": "drop.txt\n" }],
  ["fdignore-source", { ".fdignore": "drop.txt\n" }],
  ["escaped-hash", { ".gitignore": "\\#literal.txt\n", "#literal.txt": "needle\n" }],
];

function environment(root, globalConfig) {
  const home = join(root, "home");
  const xdg = join(root, "xdg");
  mkdirSync(home, { recursive: true });
  mkdirSync(xdg, { recursive: true });
  return {
    PATH: process.env.PATH ?? "",
    HOME: home,
    XDG_CONFIG_HOME: xdg,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: globalConfig === "core" ? join(home, ".gitconfig") : join(root, "absent-global-config"),
    GIT_CONFIG_SYSTEM: join(root, "absent-system-config"),
    RIPGREP_CONFIG_PATH: join(root, "absent-rg-config"),
  };
}

function run(binary, args, cwd, env) {
  const result = spawnSync(binary, args, { cwd, env, encoding: "utf8", maxBuffer: 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0 && result.status !== 1) {
    throw new Error(`${binary} ${JSON.stringify(args)} failed (${result.status}): ${result.stderr}`);
  }
  return result.stdout;
}

function makeCase(specification) {
  const {
    name, files, gitRepository = true, searchPath = ".", directories = [], symlinks = {},
    grepGlob = null, findPattern = "*.txt", globalConfig = "none", fileSearch = false,
  } = specification;
  const root = mkdtempSync(join(tmpdir(), "pi-ignore-matrix-"));
  try {
    if (gitRepository) mkdirSync(join(root, ".git"));
    for (const path of directories) mkdirSync(join(root, path), { recursive: true });
    for (const [path, content] of Object.entries(files)) {
      const absolute = join(root, path);
      mkdirSync(dirname(absolute), { recursive: true });
      writeFileSync(absolute, content.replaceAll("<ROOT>", root));
    }
    for (const [path, target] of Object.entries(symlinks)) {
      const absolute = join(root, path);
      mkdirSync(dirname(absolute), { recursive: true });
      symlinkSync(target, absolute);
    }
    const env = environment(root, globalConfig);
    const searchRoot = join(root, searchPath);
    const rgArgs = ["--no-config", "--json", "--line-number", "--color=never", "--hidden"];
    if (grepGlob !== null) rgArgs.push("--glob", grepGlob.replace(/^(!?)(?:\.\/)+/, "$1"));
    rgArgs.push("--", "needle", fileSearch ? searchRoot : ".");
    const rgOutput = run("rg", rgArgs, fileSearch ? root : searchRoot, env);
    const grepPaths = [...new Set(rgOutput.split("\n").filter(Boolean).map((line) => JSON.parse(line))
      .filter((event) => event.type === "match")
      .map((event) => fileSearch ? searchRoot.split("/").at(-1) : event.data.path.text.replace(/^\.\//, "")))].sort();
    const fdArgs = ["--color=never", "--hidden"];
    if (!gitRepository) fdArgs.push("--no-require-git");
    fdArgs.push("--glob", "--max-results", "1001", "--", findPattern, searchRoot);
    let findPaths = null;
    if (fdBinary && !fileSearch) {
      findPaths = run(fdBinary, fdArgs, root, env).split("\n").filter(Boolean)
        .map((path) => (isAbsolute(path) ? relative(searchRoot, path) : path.replace(/^\.\//, "")))
        .map((path) => path.replaceAll("\\", "/")).sort();
    }
    return { name, gitRepository, searchPath, directories, symlinks, files, grepGlob, findPattern, globalConfig,
      fileSearch, grep: { args: rgArgs.map((arg) => arg === searchRoot ? "<SEARCH_ROOT>" : arg), paths: grepPaths },
      find: fileSearch ? null : { args: fdArgs.map((arg) => arg === searchRoot ? "<SEARCH_ROOT>" : arg), paths: findPaths } };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const cases = [];
for (const [name, additions] of scenarios) {
  const files = Object.fromEntries(Object.entries({ ...baseFiles, ...additions }).sort(([a], [b]) => a.localeCompare(b)));
  for (const gitRepository of [false, true]) {
    for (const searchPath of [".", "sub"]) {
      cases.push(makeCase({ name: `${name}-${gitRepository ? "repo" : "no-repo"}-${searchPath === "." ? "root" : "sub"}`,
        files, gitRepository, searchPath }));
    }
  }
}

// These rows exercise the sources and command-line interactions that the broad
// root/child matrix above cannot express. Every grep result comes from rg.
const extra = [
  { name: "info-exclude", files: { "root.txt": "needle\n", "drop.txt": "needle\n", ".git/info/exclude": "drop.txt\n" } },
  { name: "global-core-excludes", globalConfig: "core", files: { "root.txt": "needle\n", "drop.txt": "needle\n", "home/.gitconfig": "[core]\n  excludesFile = <ROOT>/home/ignore\n", "home/ignore": "drop.txt\n" } },
  { name: "global-xdg-fallback", globalConfig: "xdg", files: { "root.txt": "needle\n", "drop.txt": "needle\n", "xdg/git/ignore": "drop.txt\n" } },
  { name: "global-core-no-repo", gitRepository: false, globalConfig: "core", files: { "root.txt": "needle\n", "drop.txt": "needle\n", "home/.gitconfig": "[core]\n  excludesFile = <ROOT>/home/ignore\n", "home/ignore": "drop.txt\n" } },
  { name: "global-xdg-no-repo", gitRepository: false, globalConfig: "xdg", files: { "root.txt": "needle\n", "drop.txt": "needle\n", "xdg/git/ignore": "drop.txt\n" } },
  { name: "nested-repository-from-parent", directories: ["nested/.git"], files: { ".gitignore": "drop.txt\n", "nested/drop.txt": "needle\n", "nested/keep.txt": "needle\n", "root.txt": "needle\n" } },
  { name: "nested-repository-search-root", searchPath: "nested", directories: ["nested/.git"], files: { ".gitignore": "drop.txt\n", "nested/drop.txt": "needle\n", "nested/keep.txt": "needle\n" } },
  { name: "explicit-ignored-file", searchPath: "drop.txt", fileSearch: true, files: { ".gitignore": "drop.txt\n", "drop.txt": "needle\n" } },
  { name: "explicit-file-inside-ignored-directory", searchPath: "blocked/drop.txt", fileSearch: true, files: { ".gitignore": "blocked/\n", "blocked/drop.txt": "needle\n" } },
  { name: "explicit-ignored-directory", searchPath: "blocked", files: { ".gitignore": "blocked/\n", "blocked/drop.txt": "needle\n", "blocked/keep.txt": "needle\n" } },
  { name: "positive-glob-ignored-file", grepGlob: "drop.txt", files: { ".gitignore": "drop.txt\n", "drop.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "positive-glob-in-ignored-directory", grepGlob: "drop.txt", files: { ".gitignore": "blocked/\n", "blocked/drop.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "negative-glob", grepGlob: "!drop.txt", files: { "drop.txt": "needle\n", "keep.txt": "needle\n", "sub/drop.txt": "needle\n", "sub/keep.txt": "needle\n" } },
  { name: "negative-glob-leading-dot", grepGlob: "!./drop.txt", files: { "drop.txt": "needle\n", "keep.txt": "needle\n", "sub/drop.txt": "needle\n", "sub/keep.txt": "needle\n" } },
  { name: "symlink-to-file", symlinks: { "link.txt": "target.txt" }, files: { "target.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "explicit-symlink-file", searchPath: "link.txt", fileSearch: true, symlinks: { "link.txt": "target.txt" }, files: { "target.txt": "needle\n" } },
  { name: "symlink-to-ignored-directory", symlinks: { alias: "blocked" }, files: { ".gitignore": "blocked/\n", "blocked/drop.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "escaped-hash-and-bang", files: { ".gitignore": "\\#hash.txt\n\\!bang.txt\n", "#hash.txt": "needle\n", "!bang.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "character-class", files: { ".gitignore": "[ab].txt\n", "a.txt": "needle\n", "b.txt": "needle\n", "c.txt": "needle\n" } },
  { name: "trailing-spaces", files: { ".gitignore": "space  \n", space: "needle\n", "space ": "needle\n", "keep.txt": "needle\n" } },
  { name: "double-star", files: { ".gitignore": "**/drop.txt\n", "drop.txt": "needle\n", "sub/drop.txt": "needle\n", "sub/keep.txt": "needle\n" } },
  { name: "git-metadata-content", files: { ".git/marker.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "package-xcodeproj", files: { "Foo.xcodeproj/project.pbxproj": "needle\n", "keep.txt": "needle\n" } },
  { name: "package-xcworkspace", files: { "Foo.xcworkspace/contents.xcworkspacedata": "needle\n", "keep.txt": "needle\n" } },
  { name: "package-playground", files: { "Foo.playground/Contents.swift": "needle\n", "keep.txt": "needle\n" } },
  { name: "package-bundle", files: { "Foo.bundle/Contents/Resources/data.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "package-framework", files: { "Foo.framework/Resources/data.txt": "needle\n", "keep.txt": "needle\n" } },
  { name: "package-app", files: { "Foo.app/Contents/Resources/data.txt": "needle\n", "keep.txt": "needle\n" } },
];
const manyDirectories = { ".gitignore": "d299/drop.txt\n", "d299/drop.txt": "needle\n", "d299/keep.txt": "needle\n" };
for (let index = 0; index < 300; index++) {
  manyDirectories[`d${String(index).padStart(3, "0")}/.ignore`] = "drop.txt\n";
}
extra.push({ name: "three-hundred-rule-directories", files: manyDirectories });
for (const specification of extra) {
  cases.push(makeCase({ ...specification, files: Object.fromEntries(Object.entries(specification.files).sort(([a], [b]) => a.localeCompare(b))) }));
}

const generated = JSON.stringify({ schemaVersion: 2, versions: { rg: rgVersion, fd: fdVersion }, cases }, null, 2) + "\n";
if (check) {
  if (generated !== readFileSync(destination, "utf8")) throw new Error("Ignore matrix differs from the saved fixture.");
  console.log(`Ignore matrix matches: ${cases.length} cases.`);
} else {
  writeFileSync(destination, generated);
  console.log(`Wrote ${cases.length} cases to ${destination}.`);
}
