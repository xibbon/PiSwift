// Extract the v1.6.0 TypeBox declarations without importing the working tree.
// Only the Type constructors used by the seven built-in tools are accepted.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire('/Users/miguel/cvs/pi/pi-mono/package.json');
const ts = require('typescript');
const repo = '/Users/miguel/cvs/pi/pi-mono';
const destination = fileURLToPath(new URL('../../Tests/PiSwiftCodingAgentTests/fixtures/builtin-tool-schemas.json', import.meta.url));
const names = ['bash', 'edit', 'find', 'grep', 'ls', 'read', 'write'];

function key(node) {
  if (ts.isIdentifier(node) || ts.isStringLiteral(node)) return node.text;
  throw new Error(`Unsupported property key: ${node.getText()}`);
}

function literal(node) {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
  if (ts.isNumericLiteral(node)) return Number(node.text);
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (ts.isObjectLiteralExpression(node)) return Object.fromEntries(node.properties.map(property => {
    if (!ts.isPropertyAssignment(property)) throw new Error(`Unsupported option: ${property.getText()}`);
    return [key(property.name), literal(property.initializer)];
  }));
  throw new Error(`Unsupported literal: ${node.getText()}`);
}

function schema(node, declarations) {
  if (ts.isIdentifier(node)) {
    const value = declarations.get(node.text);
    if (!value) throw new Error(`Missing schema declaration: ${node.text}`);
    return schema(value, declarations);
  }
  if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression) ||
      node.expression.expression.getText() !== 'Type') throw new Error(`Unsupported schema: ${node.getText()}`);
  const kind = node.expression.name.text;
  const [first, second] = node.arguments;
  if (kind === 'Optional') return { ...schema(first, declarations), __optional: true };
  if (kind === 'Object') {
    if (!ts.isObjectLiteralExpression(first)) throw new Error('Expected object properties');
    const properties = {};
    const required = [];
    for (const property of first.properties) {
      if (!ts.isPropertyAssignment(property)) throw new Error(`Unsupported property: ${property.getText()}`);
      const child = schema(property.initializer, declarations);
      if (child.__optional) delete child.__optional;
      else required.push(key(property.name));
      properties[key(property.name)] = child;
    }
    const result = { type: 'object', properties };
    if (required.length) result.required = required;
    return { ...result, ...(second ? literal(second) : {}) };
  }
  if (kind === 'Array') return { type: 'array', items: schema(first, declarations), ...(second ? literal(second) : {}) };
  const types = { String: 'string', Number: 'number', Boolean: 'boolean' };
  if (types[kind]) return { type: types[kind], ...(first ? literal(first) : {}) };
  throw new Error(`Unsupported Type.${kind}`);
}

const result = { tag: 'v1.6.0', source: 'packages/coding-agent/src/core/tools/{bash,edit,find,grep,ls,read,write}.ts', schemas: {} };
for (const name of names) {
  const source = execFileSync('git', ['-C', repo, 'show', `v1.6.0:packages/coding-agent/src/core/tools/${name}.ts`], { encoding: 'utf8' });
  const file = ts.createSourceFile(`${name}.ts`, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const declarations = new Map();
  for (const statement of file.statements) {
    if (!ts.isVariableStatement(statement)) continue;
    for (const declaration of statement.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.initializer) declarations.set(declaration.name.text, declaration.initializer);
    }
  }
  result.schemas[name] = schema(ts.factory.createIdentifier(`${name}Schema`), declarations);
}
const encoded = `${JSON.stringify(result, null, 2)}\n`;
if (process.argv.includes('--check')) {
  if (readFileSync(destination, 'utf8') !== encoded) throw new Error('Built-in schema fixture differs from v1.6.0');
  console.log('Built-in schema fixture matches v1.6.0 (7 tools).');
} else {
  writeFileSync(destination, encoded);
  console.log('Built-in schema fixture written for v1.6.0 (7 tools).');
}
