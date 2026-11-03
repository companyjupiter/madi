import { useLayoutEffect, useRef, useState } from 'react';
import { TranscriptFollow, type LineRef } from './transcriptFollow';

// Swift's 250 ms ease-out jump, with a 400 ms corrective-pin exclusion window.
function easeOut(progress: number) {
  let low = 0, high = 1;
  for (let i = 0; i < 20; i++) {
    const t = (low + high) / 2;
    const x = 3 * (1 - t) * t * t * .58 + t * t * t;
    if (x < progress) low = t; else high = t;
  }
  const t = (low + high) / 2;
  return 3 * (1 - t) * t * t + t * t * t;
}

export function useTranscriptFollow(lines: LineRef[], generation: number, isLive: boolean, editing: boolean) {
  const viewport = useRef<HTMLDivElement>(null);
  const contents = useRef<HTMLDivElement>(null);
  const model = useRef(new TranscriptFollow());
  const latest = useRef({ lines, isLive, editing });
  // Event/resize callbacks must observe the committed DOM's inputs, including
  // when React starts and abandons a concurrent render.
  useLayoutEffect(() => { latest.current = { lines, isLive, editing }; }, [lines, isLive, editing]);
  const priorLines = useRef<LineRef[] | null>(null);
  const jumpUntil = useRef(0);
  const animation = useRef<number | null>(null);
  const [badge, setBadge] = useState({ atBottom: true, unseen: 0, scrolled: false });

  function publish() {
    const next = { atBottom: model.current.atBottom, unseen: model.current.unseen, scrolled: (viewport.current?.scrollTop ?? 0) > 2 };
    setBadge(old => old.atBottom === next.atBottom && old.unseen === next.unseen && old.scrolled === next.scrolled ? old : next);
  }
  function gap() {
    const view = viewport.current;
    return view ? view.scrollHeight - view.clientHeight - view.scrollTop : 0;
  }
  function measure() {
    const view = viewport.current;
    if (!view) return;
    const current = latest.current;
    const action = model.current.geometry(gap(), current.isLive, current.lines);
    if (action === 'pinToTail' && performance.now() >= jumpUntil.current && !current.editing) {
      view.scrollTop = view.scrollHeight;
      model.current.geometry(gap(), current.isLive, current.lines);
    }
    publish();
  }
  function cancelAnimation() {
    if (animation.current !== null) cancelAnimationFrame(animation.current);
    animation.current = null;
  }
  function jumpToTail() {
    const view = viewport.current;
    if (!view) return;
    cancelAnimation();
    model.current.pillTapped(latest.current.lines);
    const began = performance.now();
    jumpUntil.current = began + 400;
    const start = view.scrollTop;
    const tick = (now: number) => {
      const progress = Math.min(1, (now - began) / 250);
      const end = Math.max(0, view.scrollHeight - view.clientHeight);
      view.scrollTop = start + (end - start) * easeOut(progress);
      measure();
      animation.current = progress < 1 ? requestAnimationFrame(tick) : null;
    };
    animation.current = requestAnimationFrame(tick);
    publish();
  }

  useLayoutEffect(() => {
    cancelAnimation();
    model.current.reset(); priorLines.current = null; jumpUntil.current = 0;
    if (viewport.current) viewport.current.scrollTop = latest.current.isLive ? viewport.current.scrollHeight : 0;
    measure();
  }, [generation]);
  useLayoutEffect(() => {
    const previous = priorLines.current;
    const changed = previous && (previous.length !== lines.length || previous.some((line, i) => line.id !== lines[i].id || line.end !== lines[i].end));
    // Swift mounts a fresh TranscriptView when the first line replaces its empty
    // state; onChange(lineRefs) does not run for that initial value.
    if (!previous?.length && lines.length) {
      model.current.reset();
      if (viewport.current) viewport.current.scrollTop = isLive ? viewport.current.scrollHeight : 0;
    } else if (changed) model.current.linesChanged(lines);
    priorLines.current = lines.map(({ id, end }) => ({ id, end }));
    measure();
  }, [lines, isLive, editing]);
  useLayoutEffect(() => {
    const view = viewport.current, body = contents.current;
    if (!view || !body) return;
    const wheel = (event: WheelEvent) => {
      cancelAnimation();
      let delta = event.deltaY;
      if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) delta *= parseFloat(getComputedStyle(view).lineHeight) || 16;
      else if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) delta *= view.clientHeight;
      model.current.userScrolled(-delta, gap());
    };
    // Observe both content and viewport: late translations and resizing can move
    // geometry without a scroll event. Such changes never release follow.
    const observer = new ResizeObserver(measure);
    observer.observe(view); observer.observe(body);
    view.addEventListener('scroll', measure, { passive: true });
    view.addEventListener('wheel', wheel, { passive: true });
    return () => {
      observer.disconnect(); cancelAnimation();
      view.removeEventListener('scroll', measure); view.removeEventListener('wheel', wheel);
    };
  }, []);
  return { viewport, contents, badge, jumpToTail };
}
