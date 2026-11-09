import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import type { FileArtwork, FileEdit, ReviewWord } from './files';
import { NativeSymbol } from './LiveControls';
import { afterApply, wrapped } from './reviewNavigation';

type Localize = (ko: string, en: string, ja?: string) => string;
export function useWordReview(words: ReviewWord[], generation: number, edit: (value: FileEdit) => void, scroll: (id: string) => void) {
  const [index, setIndex] = useState<number | null>(null);
  const [draft, setDraft] = useState('');
  const latest = useRef({ words, scroll });
  useLayoutEffect(() => { latest.current = { words, scroll }; });
  useLayoutEffect(() => { setIndex(null); }, [generation]);
  useLayoutEffect(() => {
    if (index !== null && latest.current.words[index]) latest.current.scroll(latest.current.words[index].lineId);
  }, [index]);
  const current = index === null ? undefined : words[index];
  useEffect(() => {
    if (!current) return;
    const outside = (event: PointerEvent) => { if (!(event.target instanceof Element) || !event.target.closest('.word-review-popover, .review-word')) setIndex(null); };
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); setIndex(null); } };
    document.addEventListener('pointerdown', outside, true); document.addEventListener('keydown', escape, true);
    return () => { document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', escape, true); };
  }, [Boolean(current)]);
  function open(lineId: string, wordIndex: number) {
    const index = words.findIndex(word => word.lineId === lineId && word.wordIndex === wordIndex);
    if (index >= 0) { setIndex(index); setDraft(words[index].text); }
  }
  function move(delta: number) {
    if (index === null || !words.length) return;
    const next = wrapped(index, delta, words.length); setIndex(next); setDraft(words[next].text);
  }
  function apply() {
    if (index === null || !current) return;
    edit({ type: 'word', id: current.lineId, index: current.wordIndex, text: draft });
    const next = afterApply(words, index);
    setIndex(next?.index ?? null); if (next) setDraft(next.draft);
  }
  return { index, draft, setDraft, current, open, move, apply };
}

export function WordReviewPopover({ review, total, artwork, l }: { review: ReturnType<typeof useWordReview>; total: number; artwork: FileArtwork | null; l: Localize }) {
  const root = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ left: number; top: number; arrow: number; above: boolean } | null>(null);
  const lineId = review.current?.lineId;
  useLayoutEffect(() => {
    if (!lineId) { setPosition(null); return; }
    const position = () => {
      const anchor = document.querySelector<HTMLElement>(`[data-line-id="${CSS.escape(lineId)}"]`);
      if (!anchor) { setPosition(null); return; }
      const rect = anchor.getBoundingClientRect(); const height = root.current?.offsetHeight ?? 134;
      const left = Math.min(window.innerWidth - 276, Math.max(8, rect.left + rect.width / 2 - 134));
      const above = rect.bottom + height + 16 > window.innerHeight && rect.top > height + 16;
      const top = above ? rect.top - height - 8 : Math.min(window.innerHeight - height - 8, rect.bottom + 8);
      setPosition({ left, top: Math.max(8, top), arrow: Math.max(16, Math.min(252, rect.left + rect.width / 2 - left)), above });
    };
    position(); window.addEventListener('resize', position); document.addEventListener('scroll', position, true);
    return () => { window.removeEventListener('resize', position); document.removeEventListener('scroll', position, true); };
  }, [lineId, review.index]);
  if (!review.current || review.index === null) return null;
  return createPortal(<div ref={root} className={`word-review-popover${position?.above ? ' above' : ''}`} role="dialog" aria-label={l('단어 검토', 'Word review')} style={{ left: position?.left ?? 0, top: position?.top ?? 0, visibility: position ? 'visible' : 'hidden' }}>
    <i className="word-review-arrow" style={{ left: position?.arrow ?? 134 }} />
    <span className="word-review-title">{l(`검토 ${review.index + 1} / ${total}`, `Review ${review.index + 1} / ${total}`, `確認 ${review.index + 1} / ${total}`)}</span>
    <input autoFocus aria-label={l('수정할 단어', 'Word to fix')} placeholder={l('수정할 단어', 'Word to fix')} value={review.draft} onChange={event => review.setDraft(event.target.value)} onKeyDown={event => { if (event.key === 'Enter' && !event.nativeEvent.isComposing) { event.preventDefault(); review.apply(); } }} />
    <div className="word-review-buttons"><button title={l('이전', 'Previous')} onClick={() => review.move(-1)}><NativeSymbol artwork={artwork} name="reviewPrevious" /></button><button title={l('다음', 'Next')} onClick={() => review.move(1)}><NativeSymbol artwork={artwork} name="reviewNext" /></button><span /><button className="primary" onClick={review.apply}>{l('적용 후 다음', 'Apply & next')}</button></div>
  </div>, document.body);
}
