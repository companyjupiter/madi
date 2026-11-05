// InterimDedupe and TranscriptView.syncInterim from the shipping Swift UI.
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const characters = (text: string) => Array.from(segmenter.segment(text), value => value.segment);
const tokens = (text: string) => characters(text).reduce<string[]>((result, character) => {
  if (character === ' ') result.push(''); else result[result.length - 1] += character;
  return result;
}, ['']).filter(Boolean);
const norm = (text: string) => text.toLowerCase().replace(/^\p{P}+|\p{P}+$/gu, '').normalize('NFC');

export function interimContinuation(committedTail: string, hypothesis: string, minAnchor = 3): string {
  const tail = tokens(committedTail).map(norm).filter(Boolean);
  const raw = tokens(hypothesis), hyp = raw.map(norm);
  if (!tail.length || !hyp.length) return hypothesis;
  let best: { length: number; tailEnd: number; hypEnd: number } | undefined;
  let previous = new Array<number>(hyp.length + 1).fill(0);
  for (let i = 0; i < tail.length; i++) {
    const current = new Array<number>(hyp.length + 1).fill(0);
    for (let j = 0; j < hyp.length; j++) {
      if (tail[i] === hyp[j]) {
        const length = previous[j] + 1; current[j + 1] = length;
        if (!best || length > best.length || (length === best.length && i > best.tailEnd)) best = { length, tailEnd: i, hypEnd: j };
      }
    }
    previous = current;
  }
  let start = 0;
  if (best && best.length >= minAnchor) {
    const remaining = tail.length - best.tailEnd - 1;
    if (remaining <= Math.min(6, best.length)) start = Math.min(hyp.length, best.hypEnd + 1 + remaining);
  }
  const rest = hyp.slice(start);
  for (let count = Math.min(tail.length, rest.length); count > 0; count--) {
    if (tail.slice(-count).every((word, index) => word === rest[index])) { start += count; break; }
  }
  return raw.slice(start).join(' ');
}

/** One immediate step followed by 24ms steps; revisions and long jumps snap. */
export function interimStep(shown: string, target: string): string {
  if (!target || !target.normalize('NFC').startsWith(shown.normalize('NFC'))) return target;
  if (target.normalize('NFC') === shown.normalize('NFC')) return shown;
  const before = characters(shown), after = characters(target), pending = after.length - before.length;
  if (pending <= 0 || pending > 120) return target;
  return after.slice(0, before.length + (pending > 40 ? 5 : 2)).join('');
}
