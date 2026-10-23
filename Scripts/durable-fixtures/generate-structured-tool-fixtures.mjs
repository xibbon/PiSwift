// Record schema acceptance and diagnostics from the pinned upstream validator.
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mirror, upstreamTag } from './mirror.mjs';

const fixturePath = fileURLToPath(new URL('../../Tests/PiSwiftDurableTests/Fixtures/structured-tool-schema-v130.json', import.meta.url));
const checking = process.argv.includes('--check');
const source = await mirror({ dependencies: ['typebox@1.3.27'] });
try {
 await writeFile(join(source.directory,'schema-oracle.mjs'), `import { Compile } from 'typebox/compile';
export function check(schema,value) {
 try {
  const validator=Compile(schema);
  const check=validator.Check(value);
  const errors=[...validator.Errors(value)];
  return {check, first: errors[0] ?? null, errors};
 } catch(error) { return {thrown: {name:error.name,message:error.message}}; }
}`);
 const { check }=await source.import('schema-oracle.mjs');
 const cases=[];
 const add = (name, schema, value) => {
  const result = check(schema, value);
  if (result.thrown) throw new Error(`Schema case ${name} threw: ${result.thrown.message}`);
  cases.push({ name, schema, value, ...result });
 };
 const count={type:'object',properties:{count:{type:'integer'}},required:['count']};
 for(const [name,value] of [['broken',{count:'broken'}],['missing',{}],['null',null],['null-member',{count:null}],['large-integer',{count:1e20}],['fraction',{count:1.5}]]) add('count-'+name,count,value);
 for(const [type,values] of Object.entries({boolean:[true,false,0,1,'true',null],string:['',true,1,[],null],array:[[],{},'x',null]})) for(let i=0;i<values.length;i++) add('type-'+type+'-'+i,{type},values[i]);
 for(const [name,schema,values] of [
 ['minimum',{type:'number',minimum:2},[1,2]],['maximum',{type:'number',maximum:2},[3,2]],
 ['exclusiveMinimum',{type:'number',exclusiveMinimum:2},[2,3]],['exclusiveMaximum',{type:'number',exclusiveMaximum:2},[2,1]],
 ['multipleOf',{type:'number',multipleOf:0.1},[0.3,0.31]],
 ['enum',{enum:['a',2,null,{x:1}]},['b','a',{x:1}]],['const',{const:{x:1}},[{x:2},{x:1}]],
 ['anyOf',{anyOf:[{type:'string'},{type:'integer'}]},[true,'x',1]],
 ['allOf',{allOf:[{type:'number',minimum:1},{type:'number',maximum:3}]},[0,4,2]],
 ['unknown-format',{type:'string',format:'unknown-fixture-format'},['text','']],
 ['known-format-email',{type:'string',format:'email'},['broken','a@b.example']],
 ['if-then-else',{type:'object',properties:{flag:{type:'boolean'},count:{type:'integer'}},if:{properties:{flag:{const:true}},required:['flag']},then:{required:['count']},else:{properties:{count:{maximum:0}}}},[{flag:true},{flag:true,count:1},{flag:false,count:1},{flag:false,count:0}]],
 ['dependentRequired',{type:'object',properties:{credit:{type:'string'},billing:{type:'string'}},dependentRequired:{credit:['billing']}},[{credit:'x'},{credit:'x',billing:'y'},{}]],
 ['dependentSchemas',{type:'object',dependentSchemas:{credit:{required:['billing']}}},[{credit:'x'},{credit:'x',billing:'y'}]],
 ['unevaluatedProperties',{type:'object',properties:{x:{type:'number'}},unevaluatedProperties:false},[{x:1},{x:1,y:2}]],
 ['unevaluatedProperties-allOf',{type:'object',allOf:[{properties:{x:{type:'number'}}}],unevaluatedProperties:false},[{x:1},{x:1,y:2}]],
 ['unevaluatedItems',{type:'array',prefixItems:[{type:'number'}],unevaluatedItems:false},[[1],[1,2]]],
 ['additionalProperties',{type:'object',properties:{x:{type:'number'}},additionalProperties:false},[{x:1},{x:1,y:2}]],
 ['pattern',{type:'string',pattern:'^a+$'},['aaa','b']],
 ['minItems',{type:'array',minItems:2},[[1],[1,2]]],['maxItems',{type:'array',maxItems:1},[[1],[1,2]]],
 ['uniqueItems',{type:'array',uniqueItems:true},[[1,1],[1,2]]],
 ['contains',{type:'array',contains:{type:'integer'}},[['x'],['x',1]]],
 ]) for(let i=0;i<values.length;i++) add(name+'-'+i,schema,values[i]);
 const rows={type:'object',properties:{rows:{type:'array',items:{type:'object',properties:{id:{type:'integer'}},required:['id']}}}};
 add('nested-array-valid',rows,{rows:[{id:1}]});
 add('nested-array-invalid',rows,{rows:[{id:'broken'}]});
 add('root-array-invalid',{type:'array',items:{type:'integer'}},['broken']);
 for(const [name,value] of [['emoji','😀'],['combining','e\u0301']]) for(const length of [1,2,3]) for(const bound of ['minLength','maxLength']) add('unicode-'+name+'-'+bound+'-'+length,{type:'string',[bound]:length},value);
 const result = { tag: upstreamTag, dependency: 'typebox@1.3.27',
  provenance: { source: 'unmodified pinned typebox Compile, Check, and Errors in an isolated mirror',
   purpose: 'schema acceptance and first-error oracle for tool structured output' }, cases };
 const fixture = JSON.stringify(result, null, 2) + '\n';
 if (checking) {
  if (await readFile(fixturePath, 'utf8') !== fixture) throw new Error('Structured tool schema fixtures differ');
 } else await writeFile(fixturePath, fixture);
 console.log(`Structured tool schema fixtures ${checking ? 'match' : 'written'}: ${cases.length} cases, ${cases.filter(item => item.check).length} accepted, ${cases.filter(item => !item.check).length} rejected.`);
} finally { await source.close(); }
