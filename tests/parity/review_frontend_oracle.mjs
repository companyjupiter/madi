import { readFileSync } from 'node:fs';
import { afterApply, wrapped } from '../../apps/desktop/src/reviewNavigation.ts';
const cases = JSON.parse(readFileSync(0, 'utf8')).navigation;
const output = cases.map(c => {
  const next = c.index === null ? null : afterApply(c.words, c.index);
  const moved = c.index === null || !c.words.length ? c.index : wrapped(c.index, c.delta, c.words.length);
  return { apply: { index: next?.index ?? null, draft: next?.draft ?? c.draft }, move: { index: moved, draft: moved === null || !c.words.length ? c.draft : c.words[moved].text } };
});
process.stdout.write(JSON.stringify(output));
