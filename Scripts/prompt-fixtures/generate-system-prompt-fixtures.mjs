// Run the v1.5.2 system-prompt and skill formatter directly from the tag.
// The path placeholders are replaced by the Swift test at run time.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const tag = 'v1.5.2';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const upstream = resolve(process.env.PI_MONO_PATH ?? join(root, '../pi-mono'));
const destination = join(root, 'Tests/PiSwiftCodingAgentTests/fixtures/system-prompt-v152.json');
const requireFromUpstream = createRequire(join(upstream, 'package.json'));
const ts = requireFromUpstream('typescript');
const source = path => execFileSync('git', ['-C', upstream, 'show', `${tag}:${path}`], { encoding: 'utf8' });

const skillsSource = source('packages/coding-agent/src/core/skills.ts');
const skillsStart = skillsSource.indexOf('export function formatSkillsForPrompt(');
const skillsEnd = skillsSource.indexOf('export interface LoadSkillsOptions', skillsStart);
if (skillsStart < 0 || skillsEnd < 0) throw new Error('Cannot extract the tagged skill formatter');
const skillsExports = {};
vm.runInNewContext(ts.transpileModule(skillsSource.slice(skillsStart, skillsEnd), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText, { exports: skillsExports });

const promptExports = {};
const taggedPrompt = source('packages/coding-agent/src/core/system-prompt.ts');
const js = ts.transpileModule(taggedPrompt, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;
const moduleStubs = {
  '@earendil-works/pi-ai': {
    getSystemMessageText: message => [message.content, ...Object.values(message.sections ?? {})]
      .filter(value => value !== null && value.length > 0).join('\n\n'),
  },
  '../config.ts': {
    getReadmePath: () => '{{PACKAGE_DIR}}/README.md',
    getDocsPath: () => '{{PACKAGE_DIR}}/docs',
    getExamplesPath: () => '{{PACKAGE_DIR}}/examples',
  },
  './skills.ts': { formatSkillsForPrompt: skillsExports.formatSkillsForPrompt },
};
vm.runInNewContext(js, {
  exports: promptExports,
  require: name => {
    if (!(name in moduleStubs)) throw new Error(`Unexpected tagged import: ${name}`);
    return moduleStubs[name];
  },
});

const skill = {
  name: 'sample', description: 'Sample skill', filePath: '/skills/sample/SKILL.md',
  disableModelInvocation: false,
};
const snippets = {
  read: 'Read file contents', bash: 'Execute bash commands (ls, grep, find, etc.)',
  edit: 'Make precise file edits with exact text replacement, including multiple disjoint edits in one call',
  write: 'Create or overwrite files', codemode: 'Run a script',
};
const guidelines = {
  read: ['Use read to examine files instead of cat or sed.'],
  bash: ['You can inspect PI_* environment variables for current model and session details.'],
  edit: [
    'Use edit for targeted changes. Batch changes to one file in a single call.',
    'Each edits[].oldText must exactly and uniquely match the original file. Keep matches short and non-overlapping; merge nearby changes without including large unchanged regions.',
  ],
  write: ['Use write only for new files or complete rewrites.'],
};
const cases = [
  { name: 'default tools', options: { cwd: '/fixture/work', toolSnippets: snippets, toolGuidelines: guidelines } },
  { name: 'no tools', options: { cwd: '/fixture/work', selectedTools: [], toolSnippets: snippets, toolGuidelines: guidelines } },
  { name: 'custom prompt', options: { cwd: '/fixture/work', customPrompt: 'You are Exact.' } },
  { name: 'appended prompt', options: { cwd: '/fixture/work', appendSystemPrompt: 'Extra instructions', toolSnippets: snippets, toolGuidelines: guidelines } },
  { name: 'skills', options: { cwd: '/fixture/work', selectedTools: ['read'], skills: [skill], toolSnippets: snippets, toolGuidelines: guidelines } },
  { name: 'project context files', options: { cwd: '/fixture/work', contextFiles: [{ path: '/fixture/work/AGENTS.md', content: 'Project instructions' }], toolSnippets: snippets, toolGuidelines: guidelines } },
  { name: 'codemode active', options: { cwd: '/fixture/work', selectedTools: ['codemode'], toolSnippets: snippets, toolGuidelines: { codemode: ['Use codemode when needed.'] } } },
];
for (const entry of cases) entry.expected = promptExports.buildSystemPrompt(entry.options);
const encoded = JSON.stringify({ tag, source: 'packages/coding-agent/src/core/system-prompt.ts', cases }, null, 2) + '\n';
if (process.argv.includes('--check')) {
  if (readFileSync(destination, 'utf8') !== encoded) throw new Error(`Prompt fixture differs from ${tag}`);
  console.log(`System prompt fixture check passed: ${cases.length} configurations from ${tag}.`);
} else {
  writeFileSync(destination, encoded);
  console.log(`Wrote ${cases.length} system prompt configurations from ${tag}.`);
}
