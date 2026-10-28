import assert from 'node:assert/strict';
import { test } from 'node:test';
import { extractDefaultModels } from './generate-default-models-fixture.mjs';

test('keeps source order with quoted keys, comments, escapes, and a trailing comma', () => {
  const source = String.raw`
    // const defaultModelPerProvider = { fake: "comment" };
    const other = 'const defaultModelPerProvider = { fake: "string" };';
    export const defaultModelPerProvider: Partial<Record<KnownProvider, string>> = {
      "amazon-bedrock": "model//one", // a line comment
      /* a block comment with } and , */ openai: 'model\u002dtwo',
      'quoted-provider': "model\"three", radius: "balanced",
    };
  `;
  assert.deepEqual(extractDefaultModels(source), [
    ['amazon-bedrock', 'model//one'], ['openai', 'model-two'],
    ['quoted-provider', 'model"three'], ['radius', 'balanced'],
  ]);
  assert.deepEqual(extractDefaultModels('const defaultModelPerProvider = { openai: "id" };'), [['openai', 'id']]);
});

test('rejects a missing table and unsupported or incomplete table shapes', () => {
  for (const source of [
    'const other = {};',
    'const defaultModelPerProvider = defaults;',
    'const defaultModelPerProvider = {};',
    'const defaultModelPerProvider = { openai: getDefault() };',
    'const defaultModelPerProvider = { openai: "a", openai: "b" };',
    'const defaultModelPerProvider = { ...defaults };',
    'const defaultModelPerProvider = { [provider]: "id" };',
    'const defaultModelPerProvider = { openai: "a" + "b" };',
    'const defaultModelPerProvider = { openai: "a" anthropic: "b" };',
    'const defaultModelPerProvider = { openai: "a",',
    'const defaultModelPerProvider = { openai: "unterminated',
    'const defaultModelPerProvider = { /* unterminated',
    'const note = `const defaultModelPerProvider = { fake: "wrong" };`; const defaultModelPerProvider = { openai: "right" };',
    'const note = /const defaultModelPerProvider = { fake: "wrong" };/; const defaultModelPerProvider = { openai: "right" };',
  ]) assert.throws(() => extractDefaultModels(source), /model-resolver\.ts:\d+:/, source);
});
