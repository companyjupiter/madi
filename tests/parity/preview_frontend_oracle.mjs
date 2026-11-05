import { readFileSync } from 'node:fs';
import { interimContinuation, interimStep } from '../../apps/desktop/src/previewText.ts';
const cases = JSON.parse(readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(cases.map(c => {
  if (c.kind === 'dedupe') return interimContinuation(c.tail, c.hypothesis, c.minAnchor);
  if (c.kind === 'typing') {
    let shown = c.shown;
    const frames = [];
    while (true) {
      const next = interimStep(shown, c.target);
      if (next === shown) break;
      frames.push(next); shown = next;
      if (shown === c.target) break;
    }
    return frames;
  }
  return null;
})));
