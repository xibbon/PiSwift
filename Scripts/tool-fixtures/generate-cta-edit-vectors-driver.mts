// Cases use d448c51e2 test/edit-diff-window.test.ts:55-84 and test/tools.test.ts:1723-1830.
import { pathToFileURL } from "node:url";
const { generateEditDiff, applyEditsToNormalizedContent, applyReplacementsToOriginal, normalizeToLF } = await import(pathToFileURL(process.argv[2]).href);
import {writeFileSync} from "node:fs";
const cases = [];
const add = (name, original, edits) => {
  const applied = applyEditsToNormalizedContent(normalizeToLF(original), edits, "f.txt");
  const result = generateEditDiff("f.txt", applied.baseContent, applied.newContent, applied.replacements);
  cases.push({name, original, edits, ...applied, written: applyReplacementsToOriginal(original, applied.replacements), ...result});
};
add("BOM diff snapshot without the BOM", "header\nold line\ntail\n", [{oldText:"old line\n",newText:"new line\n"}]);
add("no final newline", "a\nb", [{oldText:"b",newText:"B"}]);
add("delete all", "a\n", [{oldText:"a\n",newText:""}]);
add("empty leading line", "\na\nb\n", [{oldText:"a",newText:"A\nB"}]);
add("fuzzy lines retain original neighbors", "a\r\nfoo   \r\nb\n", [{oldText:"foo\n",newText:"FOO\n"}]);
add("kept CR insertion seam", "a\rb\nc", [{oldText:"b",newText:"\nB"}]);
add("kept CR deletion seam", "a\rb\nc", [{oldText:"b",newText:""}]);
add("two distant windows", Array.from({length:200}, (_,i) => `line ${i}`).join("\n") + "\n", [{oldText:"line 7\n",newText:"first\nextra\n"},{oldText:"line 180\n",newText:"last\n"}]);
let state=3;
const rand = max => { state = (Math.imul(state,1664525)+1013904223) >>> 0; return Math.floor(state / 4294967296 * max); };
for (let run=0;run<32;run++) {
 const lines=Array.from({length:60+rand(120)},(_,i)=>`line ${i} [end]`);
 const i=rand(lines.length), j=rand(lines.length);
 const indexes=[...new Set([i,j])].sort((a,b)=>a-b);
 add(`distinct ${run}`,lines.join("\n")+(rand(2)?"\n":""),indexes.map((i,k)=>({oldText:lines[i],newText:`new ${k}\ninsert ${run}`})));
}
writeFileSync(process.argv[3],JSON.stringify(cases,null,2)+"\n");
console.log(`Generated ${cases.length} edit vectors from v1.5.2 (d448c51e2).`);
