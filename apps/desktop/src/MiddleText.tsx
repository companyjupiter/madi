import { useLayoutEffect, useRef, useState } from 'react';

// Swift uses .truncationMode(.middle), retaining the extension/device suffix.
// Keep complete graphemes (including emoji sequences and Korean combining text).
export function MiddleText({ children, className = '' }: { children: string; className?: string }) {
  const span = useRef<HTMLSpanElement>(null);
  const [label, setLabel] = useState(children);
  useLayoutEffect(() => {
    const element = span.current!;
    const segments = Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(children), part => part.segment);
    const canvas = document.createElement('canvas');
    const context = canvas.getContext('2d')!;
    const fit = () => {
      context.font = getComputedStyle(element).font;
      const width = element.clientWidth;
      if (context.measureText(children).width <= width) { setLabel(children); return; }
      const candidate = (count: number) => segments.slice(0, Math.ceil(count / 2)).join('') + '…'
        + (count > 1 ? segments.slice(-Math.floor(count / 2)).join('') : '');
      let low = 0, high = segments.length;
      while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        if (context.measureText(candidate(middle)).width <= width) low = middle;
        else high = middle - 1;
      }
      setLabel(candidate(low));
    };
    const observer = new ResizeObserver(fit);
    observer.observe(element); fit();
    let active = true;
    void document.fonts.ready.then(() => { if (active) fit(); });
    return () => { active = false; observer.disconnect(); };
  }, [children]);
  return <span ref={span} className={`middle-text ${className}`} aria-label={children}>{label}</span>;
}
